import Foundation
import GSUSBKit

/// A `GsUsbFrameConsumer` that buffers everything the driver hands it and
/// republishes it as an `AsyncStream`, so a test can `for await` over frames
/// the way a host application would.
///
/// The buffer is unbounded and the stream never drops: a test that loses a
/// frame to a capacity limit fails for a reason that has nothing to do with
/// what it was checking.
public final class CollectingFrameConsumer: GsUsbFrameConsumer {
    private let continuation: AsyncStream<GsUsbFrame>.Continuation
    /// Every frame delivered so far, in arrival order.
    public let frames: AsyncStream<GsUsbFrame>

    public init() {
        (frames, continuation) = AsyncStream<GsUsbFrame>.makeStream(
            bufferingPolicy: .unbounded
        )
    }

    deinit {
        continuation.finish()
    }

    public func consume(_ frame: GsUsbFrame) async {
        continuation.yield(frame)
    }

    /// Ends `frames`, so a `for await` that is waiting for a frame that will
    /// never arrive finishes instead of hanging the test.
    public func finish() {
        continuation.finish()
    }
}
