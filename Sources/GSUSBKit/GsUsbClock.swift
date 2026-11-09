import Foundation

/// The host-side clock the driver schedules on and stamps its own readings
/// with. Separate from `GsUsbFrame.timestampNs`, which is `CLOCK_REALTIME`;
/// the two are never mixed.
///
/// A protocol so the reconnect ladder, the bus-state poller and `send`'s
/// timeout can all be driven in virtual time — see `GsUsbVirtualClock` in
/// `GSUSBKitTestSupport`.
public protocol GsUsbClock: Sendable {
    /// Nanoseconds on a monotonic, non-wall timebase.
    func nowNs() -> Int64
    func sleep(for duration: Duration) async throws
}

/// `CLOCK_UPTIME_RAW` — monotonic, unaffected by NTP steps or timezone
/// changes, and does not advance while the machine is asleep.
public struct GsUsbSystemClock: GsUsbClock {
    public init() {}

    public func nowNs() -> Int64 {
        Int64(clock_gettime_nsec_np(CLOCK_UPTIME_RAW))
    }

    public func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}
