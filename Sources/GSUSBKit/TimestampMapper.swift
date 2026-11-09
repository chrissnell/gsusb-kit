import Foundation

/// Turns the adapter's 32-bit microsecond counter into `Frame.timestampNs` on
/// the host's `CLOCK_REALTIME` timebase, per design §7.1:
///
/// ```
/// timestampNs = realtimeAtAnchorNs + (unwrap(timestamp_us) - anchorDeviceUs) * 1000
/// ```
///
/// Pure: no clock reads, no I/O. Both the anchor host time and every device
/// reading are supplied by the caller, which is what makes the 71.6-minute
/// wrap and the re-anchor behaviour testable in microseconds instead of hours.
///
/// Two properties are load-bearing for everything above this layer — trial
/// windows, lag measurement, cross-correlation all assume a non-decreasing
/// timeline — and both are guaranteed by construction rather than by the
/// caller behaving well:
///
/// 1. **The counter wraps every 2^32 µs ≈ 71.6 minutes** and a long session
///    will hit it. Elapsed time is accumulated from wrapping deltas, so a wrap
///    is just a small positive step and needs no special case.
/// 2. **A re-anchor never moves time backwards.** Drift correction can pull
///    the host side behind where the previous mapping had reached; the new
///    anchor is clamped forward so already-issued timestamps stay valid.
public struct TimestampMapper: Sendable {
    /// A wrapping delta larger than this is read as a small step *backwards*
    /// rather than an enormous step forwards. Both readings are 32-bit, so the
    /// two are indistinguishable without a rule, and backwards-by-a-little is
    /// the case that actually happens: a frame the device stamped just before
    /// a `BREQ_TIMESTAMP` read can be decoded just after it.
    ///
    /// The cost is that a genuine silence longer than 2^31 µs ≈ 35.8 minutes
    /// between two frames under-measures. A bus that quiet is not a bus this
    /// tool is recording.
    private static let forwardDeltaLimit: UInt32 = 1 << 31

    private var anchorRealtimeNs: Int64
    /// High-water mark of the raw counter. It never regresses, so a late or
    /// duplicated frame cannot rewind the mapping for the frames after it.
    private var highWaterMicroseconds: UInt32
    /// Microseconds elapsed since the anchor, wrap already unwound.
    private var elapsedMicroseconds: UInt64

    public init(anchorRealtimeNs: Int64, anchorDeviceMicroseconds: UInt32) {
        self.anchorRealtimeNs = anchorRealtimeNs
        highWaterMicroseconds = anchorDeviceMicroseconds
        elapsedMicroseconds = 0
    }

    /// Host timestamp for a frame the device stamped at `deviceMicroseconds`.
    ///
    /// Non-decreasing across calls for any input whatsoever, including a wrap,
    /// a duplicate, or a reading from before the current anchor.
    public mutating func timestampNs(forDeviceMicroseconds deviceMicroseconds: UInt32) -> Int64 {
        let delta = deviceMicroseconds &- highWaterMicroseconds
        if delta < Self.forwardDeltaLimit {
            elapsedMicroseconds += UInt64(delta)
            highWaterMicroseconds = deviceMicroseconds
        }
        return anchorRealtimeNs + Int64(elapsedMicroseconds) * 1_000
    }

    /// Adopt a fresh host/device correspondence, read together through
    /// `BREQ_TIMESTAMP`, to track crystal drift.
    ///
    /// The new host time is clamped to the last timestamp already issued, so a
    /// correction that points backwards flattens the timeline briefly instead
    /// of reversing it.
    public mutating func reanchor(realtimeNs: Int64, deviceMicroseconds: UInt32) {
        anchorRealtimeNs = max(realtimeNs, lastIssuedNs)
        highWaterMicroseconds = deviceMicroseconds
        elapsedMicroseconds = 0
    }

    /// The most recent value `timestampNs(forDeviceMicroseconds:)` returned —
    /// or the anchor, if it has not been called since the last re-anchor.
    public var lastIssuedNs: Int64 {
        anchorRealtimeNs + Int64(elapsedMicroseconds) * 1_000
    }
}
