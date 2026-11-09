import Foundation
import GSUSBKit

/// Virtual clock for tests. `sleep` advances time instantly and records what it
/// was asked to wait for, so a test can assert on the *schedule* the driver
/// produced — the reconnect ladder's delays, the state poller's interval —
/// rather than on wall-clock behaviour.
///
/// Note that `send`'s echo timeout also sleeps on the clock, so a transmit test
/// driven by this one must pass a `sendTimeout` long enough that it is not the
/// first thing to fire, or use `GsUsbSystemClock`.
///
/// `@unchecked Sendable` with an explicit lock rather than an actor because
/// `nowNs()` must stay synchronous: the driver calls it from non-async
/// contexts.
public final class GsUsbVirtualClock: GsUsbClock, @unchecked Sendable {
    private let lock = NSLock()
    private var currentNs: Int64
    private var sleeps: [Duration] = []

    public init(startNs: Int64 = 0) {
        self.currentNs = startNs
    }

    public func nowNs() -> Int64 {
        lock.withLock { currentNs }
    }

    public func sleep(for duration: Duration) async throws {
        try Task.checkCancellation()
        lock.withLock {
            sleeps.append(duration)
            currentNs += Self.nanoseconds(duration)
        }
        // Yield so other tasks on the cooperative pool make progress, which is
        // what a real sleep would also allow, without burning wall time.
        await Task.yield()
    }

    public var recordedSleeps: [Duration] {
        lock.withLock { sleeps }
    }

    /// Move virtual time without recording a sleep. For tests that need to
    /// place events at specific instants.
    public func advance(by duration: Duration) {
        lock.withLock { currentNs += Self.nanoseconds(duration) }
    }

    /// `components.attoseconds` is 1e-18, so divide by 1e9. A free function
    /// rather than a `Duration` extension: an extension member published from
    /// a library is ambiguous at any call site that also imports a module
    /// declaring the same name.
    private static func nanoseconds(_ duration: Duration) -> Int64 {
        let (seconds, attoseconds) = duration.components
        return seconds * 1_000_000_000 + attoseconds / 1_000_000_000
    }
}
