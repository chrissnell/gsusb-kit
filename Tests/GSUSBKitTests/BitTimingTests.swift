import Foundation
import Testing
@testable import GSUSBKit

// MARK: - Fixtures

/// The candleLight / STM32F072 `gs_device_bt_const`, as phase 2's table
/// documents it. Every vector below is computed against these numbers.
private let stm32f072 = GsDeviceBtConst(
    feature: [],
    canClockHz: 48_000_000,
    tseg1Min: 1,
    tseg1Max: 16,
    tseg2Min: 1,
    tseg2Max: 8,
    sjwMax: 4,
    brpMin: 1,
    brpMax: 1024,
    brpInc: 1
)

private func btConst(
    clockHz: UInt32 = 48_000_000,
    tseg1Min: UInt32 = 1,
    tseg1Max: UInt32 = 16,
    tseg2Min: UInt32 = 1,
    tseg2Max: UInt32 = 8,
    sjwMax: UInt32 = 4,
    brpMin: UInt32 = 1,
    brpMax: UInt32 = 1024,
    brpInc: UInt32 = 1
) -> GsDeviceBtConst {
    GsDeviceBtConst(
        feature: [], canClockHz: clockHz,
        tseg1Min: tseg1Min, tseg1Max: tseg1Max,
        tseg2Min: tseg2Min, tseg2Max: tseg2Max,
        sjwMax: sjwMax, brpMin: brpMin, brpMax: brpMax, brpInc: brpInc
    )
}

// MARK: - Sample-point targets

/// `can_calc_sample_point_nrz` is a three-armed cascade on the *requested*
/// bitrate, and the arms are `>` not `>=`, so 500k and 800k each land in the
/// arm below the one their name suggests. Both boundaries are pinned because
/// an off-by-one here shifts the sample point of exactly the two rates the
/// design calls out, and nothing else.
@Test func nominalSamplePointMatchesTheKernelsThreeBands() {
    #expect(BitTiming.nominalSamplePoint(for: 10_000) == 875)
    #expect(BitTiming.nominalSamplePoint(for: 125_000) == 875)
    #expect(BitTiming.nominalSamplePoint(for: 500_000) == 875)

    #expect(BitTiming.nominalSamplePoint(for: 500_001) == 800)
    #expect(BitTiming.nominalSamplePoint(for: 800_000) == 800)

    #expect(BitTiming.nominalSamplePoint(for: 800_001) == 750)
    #expect(BitTiming.nominalSamplePoint(for: 1_000_000) == 750)
    #expect(BitTiming.nominalSamplePoint(for: 5_000_000) == 750)
}

// MARK: - The vector table

/// One expected solution, computed outside this implementation.
///
/// Source: a transcription of the kernel's `can_calc_bittiming` run at
/// `fclk_can == 48_000_000` against `stm32f072`, cross-checked two ways —
/// `can.BitTiming` from python-can 4.6.1 recomputes the bitrate and sample
/// point from `(brp, tseg1, tseg2)` alone, and an exhaustive sweep of every
/// legal `(brp, tseg1, tseg2)` confirms each pick is the lexicographic best on
/// (bitrate error, sample-point error). See `docs/.../phase-03-bit-timing.md`.
private struct Vector: Sendable, CustomStringConvertible {
    let bitrate: UInt32
    let brp: UInt32
    let propSeg: UInt32
    let phaseSeg1: UInt32
    let phaseSeg2: UInt32
    let quantaPerBit: UInt32
    let achieved: Double
    let nominalSamplePoint: UInt32

    var description: String { "\(bitrate) bit/s" }
}

private let vectors: [Vector] = [
    .init(bitrate: 10_000, brp: 300, propSeg: 6, phaseSeg1: 7, phaseSeg2: 2,
          quantaPerBit: 16, achieved: 10_000, nominalSamplePoint: 875),
    .init(bitrate: 20_000, brp: 150, propSeg: 6, phaseSeg1: 7, phaseSeg2: 2,
          quantaPerBit: 16, achieved: 20_000, nominalSamplePoint: 875),
    .init(bitrate: 50_000, brp: 60, propSeg: 6, phaseSeg1: 7, phaseSeg2: 2,
          quantaPerBit: 16, achieved: 50_000, nominalSamplePoint: 875),
    // The one rate on the UI list with no exact solution at 48 MHz:
    // 48e6 / (36 * 16) = 83_333.33…, a residual of 0.0004%.
    .init(bitrate: 83_333, brp: 36, propSeg: 6, phaseSeg1: 7, phaseSeg2: 2,
          quantaPerBit: 16, achieved: 48_000_000.0 / 576.0, nominalSamplePoint: 875),
    .init(bitrate: 100_000, brp: 30, propSeg: 6, phaseSeg1: 7, phaseSeg2: 2,
          quantaPerBit: 16, achieved: 100_000, nominalSamplePoint: 875),
    .init(bitrate: 125_000, brp: 24, propSeg: 6, phaseSeg1: 7, phaseSeg2: 2,
          quantaPerBit: 16, achieved: 125_000, nominalSamplePoint: 875),
    .init(bitrate: 250_000, brp: 12, propSeg: 6, phaseSeg1: 7, phaseSeg2: 2,
          quantaPerBit: 16, achieved: 250_000, nominalSamplePoint: 875),
    .init(bitrate: 500_000, brp: 6, propSeg: 6, phaseSeg1: 7, phaseSeg2: 2,
          quantaPerBit: 16, achieved: 500_000, nominalSamplePoint: 875),
    // 800k sits in the 80% arm, so its segments differ from every rate below
    // it rather than just scaling by brp.
    .init(bitrate: 800_000, brp: 3, propSeg: 7, phaseSeg1: 8, phaseSeg2: 4,
          quantaPerBit: 20, achieved: 800_000, nominalSamplePoint: 800),
    .init(bitrate: 1_000_000, brp: 3, propSeg: 5, phaseSeg1: 6, phaseSeg2: 4,
          quantaPerBit: 16, achieved: 1_000_000, nominalSamplePoint: 750),
]

@Test(arguments: vectors)
private func theVectorSolvesToItsKnownGoodBittiming(vector: Vector) throws {
    let timing = try BitTiming.solve(bitrate: vector.bitrate, constants: stm32f072)

    #expect(timing.bittiming == GsDeviceBittiming(
        propSeg: vector.propSeg,
        phaseSeg1: vector.phaseSeg1,
        phaseSeg2: vector.phaseSeg2,
        sjw: 1,
        brp: vector.brp
    ))
    #expect(timing.quantaPerBit == vector.quantaPerBit)
    #expect(abs(timing.achievedBitrate - vector.achieved) < 0.000_1)
    #expect(timing.nominalSamplePoint == vector.nominalSamplePoint)
    // Every rate on the UI list reaches its nominal sample point exactly at
    // 48 MHz, which is what makes "the native path and the agent path
    // configure identical controller timing" (§5.2) true for this adapter.
    #expect(timing.samplePoint == vector.nominalSamplePoint)
}

/// The quanta count is derived twice — once by the solver, once here from the
/// segments it emitted — because `achievedBitrate` divides by it, and a bit
/// time that disagrees with the segments it came from would make the reported
/// rate a fiction while every segment still looked right.
@Test(arguments: vectors)
private func theQuantaCountAndAchievedRateAgreeWithTheSegments(vector: Vector) throws {
    let timing = try BitTiming.solve(bitrate: vector.bitrate, constants: stm32f072)
    let bt = timing.bittiming

    #expect(timing.quantaPerBit == 1 + bt.propSeg + bt.phaseSeg1 + bt.phaseSeg2)
    #expect(timing.achievedBitrate
        == 48_000_000.0 / Double(bt.brp * timing.quantaPerBit))
}

@Test func anExactSolutionReportsZeroBitrateError() throws {
    let timing = try BitTiming.solve(bitrate: 500_000, constants: stm32f072)
    #expect(timing.bitrateError == 0)
    #expect(timing.achievedBitrate == 500_000)
}

/// 83.333k is the one UI rate that cannot be hit exactly at 48 MHz, so it is
/// also the only one that proves `bitrateError` is a real measurement rather
/// than a constant zero.
@Test func theInexactRateReportsItsResidualRatherThanClaimingExactness() throws {
    let timing = try BitTiming.solve(bitrate: 83_333, constants: stm32f072)
    #expect(timing.bitrateError > 0)
    // |48e6 − 83333·576| / (83333·576) = 192/47_999_808
    #expect(abs(timing.bitrateError - 4.000_016_000_064e-6) < 1e-15)
}

// MARK: - The 0.5% ceiling

/// Design §5.2 refuses rather than connecting at a nearest match, and names
/// the rate it would have run at — a bus at slightly the wrong bitrate
/// half-works and presents as flaky hardware.
@Test func aBitrateErrorAboveTheCeilingIsRefusedAndNamesTheAchievedRate() {
    // A 13 MHz CAN clock cannot reach 800 kbit/s: the best bit time is 16
    // quanta at brp 1, which runs the bus at 812_500 — 1.5625% high.
    let constants = btConst(clockHz: 13_000_000)
    #expect(throws: BitTimingError.bitrateErrorTooHigh(
        requestedBitrate: 800_000, achievedBitrate: 812_500, error: 0.015_625
    )) {
        _ = try BitTiming.solve(bitrate: 800_000, constants: constants)
    }
}

/// The far side of the same boundary. 0.39% is a worse link than anything the
/// real adapter produces, and it still connects — the ceiling has to be a
/// ceiling, not a demand for an exact solution.
@Test func aBitrateErrorBelowTheCeilingIsAccepted() throws {
    let timing = try BitTiming.solve(bitrate: 800_000, constants: btConst(clockHz: 51_000_000))

    #expect(timing.bittiming == GsDeviceBittiming(
        propSeg: 5, phaseSeg1: 6, phaseSeg2: 4, sjw: 1, brp: 4
    ))
    #expect(timing.achievedBitrate == 796_875)
    #expect(timing.bitrateError == 0.003_906_25)
    // Not every clock reaches the nominal sample point. 51 MHz misses 80% and
    // settles for 75%, which is reported rather than silently rounded away.
    #expect(timing.nominalSamplePoint == 800)
    #expect(timing.samplePoint == 750)
}

@Test func theCeilingIsFiveTenthsOfAPercent() {
    #expect(BitTiming.maxBitrateError == 0.005)
}

@Test func theRefusalMessageNamesBothRates() {
    let error = BitTimingError.bitrateErrorTooHigh(
        requestedBitrate: 800_000, achievedBitrate: 812_500, error: 0.015_625
    )
    let message = String(describing: error)
    #expect(message.contains("800000"))
    #expect(message.contains("812500"))
    #expect(message.contains("1.56"))
}

// MARK: - No candidate at all

/// Distinct from "the best candidate is too far off": here the limits exclude
/// every prescaler, so there is no achieved rate to name.
@Test func constantsThatExcludeEveryPrescalerHaveNoSolution() {
    // brp never exceeds 17 at 48 MHz / 1 Mbit/s, so a brp_min of 32 rules out
    // the whole search space.
    #expect(throws: BitTimingError.noSolution(requestedBitrate: 1_000_000)) {
        _ = try BitTiming.solve(bitrate: 1_000_000, constants: btConst(brpMin: 32))
    }
    // The other end: 10 kbit/s needs brp ≥ 192, and brp_max is 4.
    #expect(throws: BitTimingError.noSolution(requestedBitrate: 10_000)) {
        _ = try BitTiming.solve(bitrate: 10_000, constants: btConst(brpMax: 4))
    }
    // A coarse brp_inc quantises every candidate down to 0, which is below
    // brp_min. This is the case a solver that rounded brp *up* to the next
    // increment would wrongly answer.
    #expect(throws: BitTimingError.noSolution(requestedBitrate: 1_000_000)) {
        _ = try BitTiming.solve(bitrate: 1_000_000, constants: btConst(brpInc: 32))
    }
}

// MARK: - Limits are honoured, not assumed

/// The solver must read the reported limits rather than carry the STM32's.
/// A narrower tseg2 window changes the answer at a rate that is otherwise
/// solved exactly, which a solver with hardcoded limits would get wrong.
@Test func aNarrowerSegmentWindowChangesTheAnswer() throws {
    let narrow = btConst(tseg1Max: 8, tseg2Max: 4)
    let timing = try BitTiming.solve(bitrate: 500_000, constants: narrow)

    // 8 quanta per bit instead of 16, and brp 12 instead of 6.
    #expect(timing.bittiming == GsDeviceBittiming(
        propSeg: 3, phaseSeg1: 3, phaseSeg2: 1, sjw: 1, brp: 12
    ))
    #expect(timing.quantaPerBit == 8)
    #expect(timing.achievedBitrate == 500_000)
    #expect(timing.samplePoint == 875)
}

@Test(arguments: vectors)
private func everyVectorStaysInsideTheReportedLimits(vector: Vector) throws {
    let bt = try BitTiming.solve(bitrate: vector.bitrate, constants: stm32f072).bittiming
    let tseg1 = bt.propSeg + bt.phaseSeg1

    #expect(tseg1 >= stm32f072.tseg1Min)
    #expect(tseg1 <= stm32f072.tseg1Max)
    #expect(bt.phaseSeg2 >= stm32f072.tseg2Min)
    #expect(bt.phaseSeg2 <= stm32f072.tseg2Max)
    #expect(bt.sjw <= stm32f072.sjwMax)
    #expect(bt.brp >= stm32f072.brpMin)
    #expect(bt.brp <= stm32f072.brpMax)
    #expect(bt.brp % stm32f072.brpInc == 0)
}

@Test func aCoarseBrpIncrementIsRespected() throws {
    let coarse = btConst(brpInc: 4)
    let timing = try BitTiming.solve(bitrate: 125_000, constants: coarse)
    #expect(timing.bittiming == GsDeviceBittiming(
        propSeg: 6, phaseSeg1: 7, phaseSeg2: 2, sjw: 1, brp: 24
    ))
    #expect(timing.achievedBitrate == 125_000)
}

// MARK: - SJW

/// `ip link set can0 type can bitrate 500000` leaves sjw unset and the kernel
/// resolves it to 1. The native path defaults the same way so a bus brought up
/// either way is brought up identically.
@Test(arguments: vectors)
private func sjwDefaultsToOneLikeAnUnspecifiedKernelBringUp(vector: Vector) throws {
    let timing = try BitTiming.solve(bitrate: vector.bitrate, constants: stm32f072)
    #expect(timing.bittiming.sjw == 1)
}

@Test func aRequestedSjwIsClampedToSjwMax() throws {
    let timing = try BitTiming.solve(bitrate: 800_000, constants: stm32f072, sjw: 9)
    #expect(stm32f072.sjwMax == 4)
    #expect(timing.bittiming.sjw == 4)
}

/// SJW cannot exceed phase_seg2 — resynchronising by more than the segment
/// being shortened is not representable on the controller.
@Test func aRequestedSjwIsClampedToPhaseSeg2WhenThatIsSmaller() throws {
    let timing = try BitTiming.solve(bitrate: 10_000, constants: stm32f072, sjw: 4)
    #expect(timing.bittiming.phaseSeg2 == 2)
    #expect(timing.bittiming.sjw == 2)
}

@Test func aRequestedSjwInsideBothLimitsSurvives() throws {
    let timing = try BitTiming.solve(bitrate: 800_000, constants: stm32f072, sjw: 3)
    #expect(timing.bittiming.sjw == 3)
}

/// A device reporting `sjw_max == 0` is asking for no resynchronisation
/// window at all; the kernel ignores that and uses 1, because 0 is not a legal
/// value for the controller register either.
@Test func aDeviceReportingZeroSjwMaxStillGetsOne() throws {
    let timing = try BitTiming.solve(
        bitrate: 500_000, constants: btConst(sjwMax: 0), sjw: 4
    )
    #expect(timing.bittiming.sjw == 1)
}

// MARK: - Refusing nonsense input

@Test func aZeroBitrateIsRejected() {
    #expect(throws: BitTimingError.invalidBitrate(0)) {
        _ = try BitTiming.solve(bitrate: 0, constants: stm32f072)
    }
}

/// These all come off the wire in `BREQ_BT_CONST`, so they are device input,
/// not internal state. Two of them would divide by zero in the search.
@Test func unusableReportedConstantsAreRejectedRatherThanDividedBy() {
    let cases: [GsDeviceBtConst] = [
        btConst(clockHz: 0),
        btConst(brpInc: 0),
        btConst(brpMin: 0),
        btConst(brpMin: 64, brpMax: 32),
        btConst(tseg1Min: 0),
        btConst(tseg1Min: 17, tseg1Max: 16),
        btConst(tseg2Min: 0),
        btConst(tseg2Min: 9, tseg2Max: 8),
    ]
    for constants in cases {
        #expect(throws: BitTimingError.unusableConstants(constants)) {
            _ = try BitTiming.solve(bitrate: 500_000, constants: constants)
        }
    }
}

// MARK: - The solution travels over the wire unchanged

/// The solver's whole output is a `BREQ_BITTIMING` payload, so the handshake
/// in phase 5 sends exactly these 20 bytes.
@Test func theSolvedBittimingEncodesToTheWireStruct() throws {
    let timing = try BitTiming.solve(bitrate: 500_000, constants: stm32f072)
    let bytes = timing.bittiming.encoded()

    #expect(bytes.count == GsDeviceBittiming.byteCount)
    #expect(try GsDeviceBittiming(decoding: bytes) == timing.bittiming)
}
