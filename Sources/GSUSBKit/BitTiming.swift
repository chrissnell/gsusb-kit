import Foundation

// MARK: - Errors

/// Why a requested bitrate could not become a `BREQ_BITTIMING` payload.
public enum BitTimingError: Error, Equatable, Sendable, CustomStringConvertible {
    /// A zero bitrate. Divides by zero in the search, and means nothing.
    case invalidBitrate(UInt32)
    /// `BREQ_BT_CONST` reported limits that no search can run inside — a zero
    /// clock, a zero `brp_inc`, or a minimum above its maximum. These come off
    /// the wire, so they are rejected rather than divided by.
    case unusableConstants(GsDeviceBtConst)
    /// The reported limits exclude every prescaler at this bitrate, so there
    /// is no achieved rate to report. Distinct from `bitrateErrorTooHigh`,
    /// where a candidate exists and is merely too far off.
    case noSolution(requestedBitrate: UInt32)
    /// The closest reachable rate is further than `BitTiming.maxBitrateError`
    /// from the request. Carries the rate the bus *would* have run at, because
    /// that number is what makes the refusal actionable (§5.2).
    case bitrateErrorTooHigh(requestedBitrate: UInt32, achievedBitrate: Double, error: Double)

    public var description: String {
        switch self {
        case let .invalidBitrate(bitrate):
            return "\(bitrate) is not a usable CAN bitrate"
        case let .unusableConstants(constants):
            return """
                the adapter reported unusable bit-timing limits \
                (fclk_can \(constants.canClockHz), \
                tseg1 \(constants.tseg1Min)–\(constants.tseg1Max), \
                tseg2 \(constants.tseg2Min)–\(constants.tseg2Max), \
                brp \(constants.brpMin)–\(constants.brpMax) step \(constants.brpInc))
                """
        case let .noSolution(requested):
            return """
                \(requested) bit/s is outside the range this adapter's \
                prescaler and segment limits can express
                """
        case let .bitrateErrorTooHigh(requested, achieved, error):
            return """
                \(requested) bit/s is not reachable on this adapter: the \
                closest it can run is \(Self.rate(achieved)) bit/s, \
                \(Self.percent(error)) off, and the ceiling is \
                \(Self.percent(BitTiming.maxBitrateError))
                """
        }
    }

    private static func rate(_ value: Double) -> String {
        String(format: value == value.rounded() ? "%.0f" : "%.2f", value)
    }

    private static func percent(_ fraction: Double) -> String {
        String(format: "%.3g%%", fraction * 100)
    }
}

// MARK: - BitTiming

/// Design §5.2. Turns a target bitrate plus the device's own
/// `gs_device_bt_const` into the `gs_device_bittiming` the `BREQ_BITTIMING`
/// control transfer carries, and reports how far the result lands from the
/// request.
///
/// The search is the Linux kernel's `can_calc_bittiming`
/// (`drivers/net/can/dev/calc_bittiming.c`), transcribed rather than
/// reinvented. That is the point: `canagent` brings its bus up through
/// SocketCAN, which runs exactly this algorithm, so matching it means a
/// capture taken natively and a capture taken through the agent were taken off
/// identically configured controllers. A different-but-reasonable search would
/// make §10's cross-check measure a timing difference instead of the
/// timestamp path it exists to test.
///
/// Two things deliberately differ from the kernel:
///
/// - **The error ceiling is 0.5%, not `CAN_CALC_MAX_ERROR`'s 5%.** The kernel
///   is a general-purpose driver that must come up on whatever it is handed.
///   This is a diagnostic tool whose entire output is suspect if the link is
///   marginal, so it refuses (§5.2).
/// - **The ceiling is checked in exact integer arithmetic**, not against the
///   kernel's tenths-of-a-percent integer, so a rate 0.5001% off is refused
///   rather than rounding into the allowed band.
public struct BitTiming: Sendable, Equatable {
    /// The `BREQ_BITTIMING` payload: this is the whole deliverable.
    public let bittiming: GsDeviceBittiming
    /// What was asked for, carried alongside so a caller holding only the
    /// solution can still report the delta.
    public let requestedBitrate: UInt32
    /// Time quanta per bit — `1 + prop_seg + phase_seg1 + phase_seg2`, the
    /// leading 1 being the sync segment.
    public let quantaPerBit: UInt32
    /// `fclk_can / (brp · quantaPerBit)`, in bit/s.
    public let achievedBitrate: Double
    /// `|achieved − requested| / requested`, as a fraction.
    public let bitrateError: Double
    /// Where in the bit the controller samples, in tenths of a percent.
    public let samplePoint: UInt32
    /// The CiA-recommended target `samplePoint` was solved towards, in tenths
    /// of a percent. Equal to `samplePoint` on every rate the SH-C30A offers.
    public let nominalSamplePoint: UInt32

    /// The achieved-bitrate ceiling, as a fraction of the requested rate.
    public static let maxBitrateError = 0.005

    /// `can_calc_sample_point_nrz`, in tenths of a percent.
    ///
    /// The comparisons are strict, so 500 kbit/s samples at 87.5% and
    /// 800 kbit/s at 80% — each lands in the arm below the one its name
    /// suggests.
    public static func nominalSamplePoint(for bitrate: UInt32) -> UInt32 {
        if bitrate > 800_000 { return 750 }
        if bitrate > 500_000 { return 800 }
        return 875
    }

    /// Solves `bitrate` against the device's reported limits.
    ///
    /// `sjw` mirrors the kernel's user-settable synchronisation jump width:
    /// `nil` resolves to 1, which is what an `ip link set … bitrate N` bring-up
    /// with no explicit `sjw` produces.
    public static func solve(
        bitrate requested: UInt32,
        constants: GsDeviceBtConst,
        sjw requestedSjw: UInt32? = nil
    ) throws -> BitTiming {
        guard requested > 0 else { throw BitTimingError.invalidBitrate(requested) }
        guard constants.canClockHz > 0,
              constants.brpInc > 0,
              constants.brpMin > 0, constants.brpMin <= constants.brpMax,
              constants.tseg1Min > 0, constants.tseg1Min <= constants.tseg1Max,
              constants.tseg2Min > 0, constants.tseg2Min <= constants.tseg2Max
        else { throw BitTimingError.unusableConstants(constants) }

        let clock = UInt64(constants.canClockHz)
        let target = UInt64(requested)
        let nominal = nominalSamplePoint(for: requested)

        var bestBitrateError = UInt64.max
        var bestSamplePointError = UInt32.max
        var bestTseg: UInt32 = 0
        var bestBrp: UInt32 = 0

        // The kernel walks tseg (= tseg1 + tseg2, doubled) downwards, so the
        // half-step parity term rounds brp up on odd iterations and down on
        // even ones, and ties resolve to the largest tseg — the lowest
        // prescaler, which is the finest quantum.
        let lowest = (UInt64(constants.tseg1Min) + UInt64(constants.tseg2Min)) * 2
        var tseg = (UInt64(constants.tseg1Max) + UInt64(constants.tseg2Max)) * 2 + 1
        while tseg >= lowest {
            defer { tseg -= 1 }

            let quanta = 1 + tseg / 2
            var brp = clock / (quanta * target) + tseg % 2
            brp = (brp / UInt64(constants.brpInc)) * UInt64(constants.brpInc)
            guard brp >= UInt64(constants.brpMin), brp <= UInt64(constants.brpMax) else {
                continue
            }

            let achieved = clock / (brp * quanta)
            let bitrateError = achieved > target ? achieved - target : target - achieved
            if bitrateError > bestBitrateError { continue }
            // A better bitrate outranks any sample point found so far, so the
            // sample-point contest restarts rather than carrying its winner
            // across into a different bitrate.
            if bitrateError < bestBitrateError { bestSamplePointError = .max }

            let candidate = segments(tseg: UInt32(tseg / 2), nominal: nominal, constants: constants)
            guard candidate.samplePointError < bestSamplePointError else { continue }

            bestSamplePointError = candidate.samplePointError
            bestBitrateError = bitrateError
            bestTseg = UInt32(tseg / 2)
            bestBrp = UInt32(brp)

            if bitrateError == 0 && candidate.samplePointError == 0 { break }
        }

        guard bestBrp > 0 else { throw BitTimingError.noSolution(requestedBitrate: requested) }

        let best = segments(tseg: bestTseg, nominal: nominal, constants: constants)
        let propSeg = best.tseg1 / 2
        let phaseSeg1 = best.tseg1 - propSeg
        let phaseSeg2 = best.tseg2
        let quantaPerBit = 1 + propSeg + phaseSeg1 + phaseSeg2

        let sjw: UInt32
        if let requestedSjw, requestedSjw > 0, constants.sjwMax > 0 {
            sjw = min(min(requestedSjw, constants.sjwMax), phaseSeg2)
        } else {
            sjw = 1
        }

        // The error is compared as |clock − requested·brp·quanta| / (requested·brp·quanta),
        // which is the relative error with no division and no rounding.
        let scaled = target * UInt64(bestBrp) * UInt64(quantaPerBit)
        let residual = clock > scaled ? clock - scaled : scaled - clock
        let achievedBitrate = Double(clock) / Double(UInt64(bestBrp) * UInt64(quantaPerBit))
        let error = Double(residual) / Double(scaled)
        guard Double(residual) <= maxBitrateError * Double(scaled) else {
            throw BitTimingError.bitrateErrorTooHigh(
                requestedBitrate: requested,
                achievedBitrate: achievedBitrate,
                error: error
            )
        }

        return BitTiming(
            bittiming: GsDeviceBittiming(
                propSeg: propSeg,
                phaseSeg1: phaseSeg1,
                phaseSeg2: phaseSeg2,
                sjw: sjw,
                brp: bestBrp
            ),
            requestedBitrate: requested,
            quantaPerBit: quantaPerBit,
            achievedBitrate: achievedBitrate,
            bitrateError: error,
            samplePoint: best.samplePoint,
            nominalSamplePoint: nominal
        )
    }

    private struct Segments {
        var tseg1: UInt32 = 0
        var tseg2: UInt32 = 0
        var samplePoint: UInt32 = 0
        var samplePointError: UInt32 = .max
    }

    /// `can_update_sample_point`: split `tseg` into `tseg1` / `tseg2` so the
    /// sample point lands as close below `nominal` as the limits allow.
    ///
    /// Both candidate splits are tried because integer division truncates the
    /// ideal `tseg2` and the truncated value is sometimes the worse of the two.
    /// Only sample points at or below nominal are eligible: sampling late
    /// leaves no margin for phase error, so the kernel biases early.
    private static func segments(
        tseg: UInt32, nominal: UInt32, constants: GsDeviceBtConst
    ) -> Segments {
        var best = Segments()

        for offset: UInt32 in [0, 1] {
            // Wrapping subtraction, as in C: `offset == 1` can take the ideal
            // tseg2 below zero, and the clamp that follows is what the kernel
            // relies on to catch it.
            var tseg2 = (tseg &+ 1)
                &- UInt32((UInt64(nominal) * UInt64(tseg + 1)) / 1000)
                &- offset
            tseg2 = min(max(tseg2, constants.tseg2Min), constants.tseg2Max)
            var tseg1 = tseg &- tseg2
            if tseg1 > constants.tseg1Max {
                tseg1 = constants.tseg1Max
                tseg2 = tseg - tseg1
            }

            let samplePoint = UInt32(1000 * UInt64(tseg + 1 - tseg2) / UInt64(tseg + 1))
            let samplePointError = nominal > samplePoint
                ? nominal - samplePoint
                : samplePoint - nominal

            if samplePoint <= nominal && samplePointError < best.samplePointError {
                best = Segments(
                    tseg1: tseg1,
                    tseg2: tseg2,
                    samplePoint: samplePoint,
                    samplePointError: samplePointError
                )
            }
        }

        return best
    }
}
