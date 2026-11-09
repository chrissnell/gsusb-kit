import Foundation
import IOKit
import IOKit.usb
// `@preconcurrency` because `IOUSBHostInterface`, `IOUSBHostPipe` and the
// `NSMutableData` buffers are all non-`Sendable` and are all deliberately
// captured by the completion handlers below. That capture is the design, not an
// oversight: those objects are confined to `queue`, which is serial, and the
// confinement is what Swift cannot see. Without this, every enqueue site warns
// about exactly the thing the `@unchecked Sendable` box documents.
@preconcurrency import IOUSBHost

// The only file in this target that touches hardware, and the only one no test
// on this machine can execute. `swift build` compiles it; `swift test` links it
// and never calls it. Everything it is asked to verify is verified by a human
// running `gsusbprobe` with an adapter plugged in.
//
// That is why it is as thin as the `UsbDeviceTransport` protocol allows. It
// knows about registry iteration, endpoint descriptors, pipes and in-flight
// request pools; it knows nothing about CAN frames or the gs_usb handshake.
// Any `if` about CAN semantics written here would be an untestable `if`, and
// `GsUsbDevice` is where it belongs instead.

/// `UsbDeviceTransport` over `IOUSBHost`.
///
/// **Concurrency.** `@unchecked Sendable` rather than an actor, for the reason
/// `ResumeGuard` in `CanCore/Sources/Transport/ByteStream.swift` gives: the
/// objects being protected are non-`Sendable` Objective-C instances reached
/// from `IOUSBHostCompletionHandler`, a synchronous callback delivered on a
/// dispatch queue with nowhere to `await`. So the mutable state lives in one
/// box, every read-modify-write holds `lock` for its whole duration, and the
/// Objective-C objects are only ever touched on `queue` — serial and
/// `.userInitiated`, per design §5.3.
public final class IOUSBHostTransport: UsbDeviceTransport, @unchecked Sendable {
    /// `1d50:606f` — OpenMoko's vendor ID and candleLight's product ID.
    public static let gsUsbVendorID: UInt16 = 0x1D50
    public static let gsUsbProductID: UInt16 = 0x606F

    /// Design §5.3's floor. Below this the read loop serialises on the USB
    /// 1 ms frame interval and caps near 1,000 frames/s; the frames it misses
    /// are dropped in the adapter's FIFO with no notification to anyone. A
    /// silent data-loss mode is not something to leave to a caller's judgement,
    /// so the initialiser clamps rather than trusting its argument.
    public static let minimumPoolDepth = 8
    public static let defaultPoolDepth = 16

    private let vendorID: UInt16
    private let productID: UInt16
    private let poolDepth: Int
    private let controlTimeout: TimeInterval
    private let writeTimeout: TimeInterval

    private let queue = DispatchQueue(label: "canopener.gsusb.usb", qos: .userInitiated)
    private let lock = NSLock()
    private let state = State()

    /// Everything mutable, in one place, so "held the lock for the whole
    /// read-modify-write" is checkable by reading one type.
    private final class State {
        var interface: IOUSBHostInterface?
        var inPipe: IOUSBHostPipe?
        var outPipe: IOUSBHostPipe?
        /// The pool. Held so the buffers outlive their in-flight requests.
        var readBuffers: [NSMutableData] = []
        /// Transfers that completed with nobody waiting.
        var completed: [[UInt8]] = []
        var waiters: [CheckedContinuation<[UInt8], Error>] = []
        /// Sticky: the first failure that ended the read pool. Reported to
        /// every subsequent reader, because one aborted pipe produces
        /// `poolDepth` aborted completions and they all mean the same thing.
        var failure: UsbTransportError?
        var isOpen = false
    }

    public init(
        vendorID: UInt16 = IOUSBHostTransport.gsUsbVendorID,
        productID: UInt16 = IOUSBHostTransport.gsUsbProductID,
        poolDepth: Int = IOUSBHostTransport.defaultPoolDepth,
        controlTimeout: TimeInterval = 1.0,
        writeTimeout: TimeInterval = 1.0
    ) {
        self.vendorID = vendorID
        self.productID = productID
        self.poolDepth = max(poolDepth, Self.minimumPoolDepth)
        self.controlTimeout = controlTimeout
        self.writeTimeout = writeTimeout
    }

    // MARK: - Enumerate

    public func enumerate() async throws -> [UsbDeviceRef] {
        let vendorID = vendorID
        let productID = productID
        return try await onQueue {
            Self.matchingServices(vendorID: vendorID, productID: productID).map(\.ref)
        }
    }

    // MARK: - Open

    public func open(_ device: UsbDeviceRef) async throws -> UsbInterfaceInfo {
        await close()

        let vendorID = vendorID
        let productID = productID
        let poolDepth = poolDepth

        return try await onQueue { [self] in
            let candidates = Self.matchingServices(vendorID: vendorID, productID: productID)
            guard let match = candidates.first(where: { $0.ref.locationID == device.locationID }) else {
                candidates.forEach { IOObjectRelease($0.service) }
                throw UsbTransportError.deviceNotFound
            }
            defer { candidates.forEach { IOObjectRelease($0.service) } }

            guard let interfaceService = Self.firstInterfaceService(of: match.service) else {
                throw UsbTransportError.openFailed("device has no IOUSBHostInterface child")
            }
            defer { IOObjectRelease(interfaceService) }

            // The design §3.1 moment. If an unentitled, hardened-runtime
            // process cannot claim an unclaimed vendor-specific interface,
            // this is the line that says so — which is why the underlying
            // message is carried up verbatim instead of flattened to a flag.
            let interface: IOUSBHostInterface
            do {
                interface = try IOUSBHostInterface(
                    __ioService: interfaceService,
                    options: [],
                    queue: queue,
                    interestHandler: nil
                )
            } catch {
                throw UsbTransportError.openFailed(error.localizedDescription)
            }

            let endpoints = Self.bulkEndpoints(of: interface, speed: Self.connectionSpeed(of: interfaceService))
            guard let inEndpoint = endpoints.input else {
                interface.destroy()
                throw UsbTransportError.pipeNotFound("no bulk IN endpoint")
            }
            guard let outEndpoint = endpoints.output else {
                interface.destroy()
                throw UsbTransportError.pipeNotFound("no bulk OUT endpoint")
            }

            let inPipe: IOUSBHostPipe
            let outPipe: IOUSBHostPipe
            do {
                inPipe = try interface.copyPipe(withAddress: Int(inEndpoint.address))
                outPipe = try interface.copyPipe(withAddress: Int(outEndpoint.address))
            } catch {
                interface.destroy()
                throw UsbTransportError.pipeNotFound(error.localizedDescription)
            }

            let bufferSize = max(inEndpoint.maxPacketSize, 64)
            var buffers: [NSMutableData] = []
            buffers.reserveCapacity(poolDepth)
            for _ in 0..<poolDepth {
                guard let buffer = try? interface.ioData(withCapacity: bufferSize) else {
                    interface.destroy()
                    throw UsbTransportError.openFailed("could not allocate a \(bufferSize)-byte IO buffer")
                }
                buffers.append(buffer)
            }

            lock.withLock {
                state.interface = interface
                state.inPipe = inPipe
                state.outPipe = outPipe
                state.readBuffers = buffers
                state.completed = []
                state.failure = nil
                state.isOpen = true
            }

            // Fill the pool before returning, so the caller's first `bulkRead`
            // already has `poolDepth` transfers outstanding rather than
            // starting a ramp-up it would pay for at exactly the frame rates
            // where §5.3 matters.
            for buffer in buffers {
                enqueueRead(buffer, on: inPipe)
            }

            return UsbInterfaceInfo(
                interfaceNumber: interface.interfaceDescriptor.pointee.bInterfaceNumber,
                bulkInMaxPacketSize: inEndpoint.maxPacketSize,
                bulkOutMaxPacketSize: outEndpoint.maxPacketSize
            )
        }
    }

    // MARK: - Control

    public func controlTransfer(_ request: UsbControlRequest, payload: [UInt8]) async throws -> [UInt8] {
        let interface = try lock.withLock { () throws -> IOUSBHostInterface in
            guard state.isOpen, let interface = state.interface else { throw UsbTransportError.notOpen }
            return interface
        }

        let deviceRequest: IOUSBDeviceRequest = {
            var r = IOUSBDeviceRequest()
            r.bmRequestType = request.bmRequestType
            r.bRequest = request.request
            r.wValue = request.value
            r.wIndex = request.index
            r.wLength = request.length
            return r
        }()

        let expected = Int(request.length)
        // `nonisolated(unsafe)` for the reason the whole class is
        // `@unchecked Sendable`: this buffer is created here, handed to one
        // enqueue, and read once from that enqueue's completion. Nothing else
        // can reach it, so the compiler's inability to see single ownership
        // across a dispatch hop is the only thing being overridden.
        nonisolated(unsafe) let data: NSMutableData? = {
            guard expected > 0 else { return nil }
            switch request.direction {
            case .hostToDevice: return NSMutableData(bytes: payload, length: min(payload.count, expected))
            case .deviceToHost: return NSMutableData(length: expected)
            }
        }()

        let timeout = controlTimeout
        let direction = request.direction

        return try await withCheckedThrowingContinuation { continuation in
            let guarded = ResumeOnce()
            queue.async {
                do {
                    // The *asynchronous* device-request variant, deliberately.
                    // `__send` is synchronous and would block this serial queue
                    // for the length of the transfer — and this queue is also
                    // where bulk-read completions land, so a 1 ms control
                    // transfer would stall the whole read pool. One extra
                    // continuation removes the interaction entirely.
                    try interface.__enqueue(deviceRequest, data: data, completionTimeout: timeout) { status, transferred in
                        guard guarded.claim() else { return }
                        guard status == kIOReturnSuccess else {
                            continuation.resume(throwing: UsbTransportError(ioReturn: status))
                            return
                        }
                        guard direction == .deviceToHost, let data, expected > 0 else {
                            continuation.resume(returning: [])
                            return
                        }
                        guard transferred >= expected else {
                            continuation.resume(
                                throwing: UsbTransportError.shortTransfer(expected: expected, actual: transferred)
                            )
                            return
                        }
                        continuation.resume(returning: Self.bytes(of: data, count: expected))
                    }
                } catch {
                    if guarded.claim() {
                        continuation.resume(throwing: UsbTransportError.transferFailed(error.localizedDescription))
                    }
                }
            }
        }
    }

    // MARK: - Bulk read

    public func bulkRead() async throws -> [UInt8] {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                enum Outcome {
                    case ready([UInt8])
                    case failed(UsbTransportError)
                    case parked
                }

                let outcome: Outcome = lock.withLock {
                    // Drain what already landed before reporting a failure: a
                    // burst that arrived just before a surprise removal is
                    // real data, and throwing it away would lose frames the
                    // adapter successfully delivered.
                    if !state.completed.isEmpty { return .ready(state.completed.removeFirst()) }
                    if let failure = state.failure { return .failed(failure) }
                    guard state.isOpen else { return .failed(.notOpen) }
                    state.waiters.append(continuation)
                    return .parked
                }

                // Resuming outside the lock: a continuation resumed under it
                // can run the caller synchronously and re-enter this type.
                switch outcome {
                case .ready(let payload): continuation.resume(returning: payload)
                case .failed(let error): continuation.resume(throwing: error)
                case .parked: break
                }
            }
        } onCancel: {
            // An enqueued USB transfer knows nothing about Swift cancellation.
            // A cancelled task parked above would otherwise wait for a frame
            // that, on an idle bus, never comes. Aborting the pipe is what
            // turns cancellation into a completion. `NWByteStream.connect()`
            // calls `connection.cancel()` from its handler for the same reason,
            // and is equally terminal for the connection.
            abortReadPipe()
        }
    }

    private func enqueueRead(_ buffer: NSMutableData, on pipe: IOUSBHostPipe) {
        // One buffer is in exactly one transfer at a time: it leaves the pool
        // on enqueue and the completion that hands it back is the same
        // completion that re-enqueues it. Serial by construction, invisibly so
        // to the compiler.
        nonisolated(unsafe) let buffer = buffer
        nonisolated(unsafe) let pipe = pipe
        do {
            // Timeout 0 — never. A bulk-IN on an idle CAN bus is supposed to
            // wait indefinitely; a timeout here would manufacture errors out
            // of silence.
            try pipe.enqueueIORequest(with: buffer, completionTimeout: 0) { [weak self] status, transferred in
                self?.completeRead(buffer, on: pipe, status: status, transferred: transferred)
            }
        } catch {
            deliverFailure(.transferFailed(error.localizedDescription))
        }
    }

    private func completeRead(_ buffer: NSMutableData, on pipe: IOUSBHostPipe, status: IOReturn, transferred: Int) {
        guard status == kIOReturnSuccess else {
            deliverFailure(UsbTransportError(ioReturn: status))
            return
        }
        guard lock.withLock({ state.isOpen }) else { return }

        deliver(Self.bytes(of: buffer, count: min(transferred, buffer.length)))

        // Re-enqueue here, in the completion handler, and not in `bulkRead`.
        // Design §5.3 says N transfers in flight *at all times*; refilling when
        // the caller collects would instead make the in-flight count track how
        // fast the caller drains. The difference is invisible until the bus is
        // busy, which is the only time it matters.
        //
        // The queue of completed transfers is therefore unbounded, and the
        // caller is obliged to drain it or close. `GsUsbDevice`'s read loop
        // does, because a `GsUsbFrameConsumer` is documented to enqueue and
        // return rather than suspend.
        enqueueRead(buffer, on: pipe)
    }

    private func deliver(_ payload: [UInt8]) {
        let waiter: CheckedContinuation<[UInt8], Error>? = lock.withLock {
            guard !state.waiters.isEmpty else {
                state.completed.append(payload)
                return nil
            }
            return state.waiters.removeFirst()
        }
        waiter?.resume(returning: payload)
    }

    private func deliverFailure(_ error: UsbTransportError) {
        let waiters: [CheckedContinuation<[UInt8], Error>] = lock.withLock {
            if state.failure == nil { state.failure = error }
            let parked = state.waiters
            state.waiters = []
            return parked
        }
        for waiter in waiters {
            waiter.resume(throwing: error)
        }
    }

    private func abortReadPipe() {
        let pipe = lock.withLock { state.inPipe }
        guard let pipe else { return }
        queue.async { try? pipe.__abort(with: .asynchronous) }
    }

    // MARK: - Bulk write

    public func bulkWrite(_ bytes: [UInt8]) async throws {
        let pipe = try lock.withLock { () throws -> IOUSBHostPipe in
            guard state.isOpen, let pipe = state.outPipe else { throw UsbTransportError.notOpen }
            return pipe
        }

        // Same single-ownership argument as the control buffer above.
        nonisolated(unsafe) let data = NSMutableData(bytes: bytes, length: bytes.count)
        let timeout = writeTimeout
        let expected = bytes.count

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let guarded = ResumeOnce()
            queue.async {
                do {
                    try pipe.enqueueIORequest(with: data, completionTimeout: timeout) { status, transferred in
                        guard guarded.claim() else { return }
                        guard status == kIOReturnSuccess else {
                            continuation.resume(throwing: UsbTransportError(ioReturn: status))
                            return
                        }
                        guard transferred >= expected else {
                            continuation.resume(
                                throwing: UsbTransportError.shortTransfer(expected: expected, actual: transferred)
                            )
                            return
                        }
                        continuation.resume()
                    }
                } catch {
                    if guarded.claim() {
                        continuation.resume(throwing: UsbTransportError.transferFailed(error.localizedDescription))
                    }
                }
            }
        }
    }

    // MARK: - Close

    public func close() async {
        let teardown: (interface: IOUSBHostInterface?, input: IOUSBHostPipe?, output: IOUSBHostPipe?) =
            lock.withLock {
                let captured = (state.interface, state.inPipe, state.outPipe)
                state.isOpen = false
                state.interface = nil
                state.inPipe = nil
                state.outPipe = nil
                state.readBuffers = []
                state.completed = []
                return captured
            }

        guard teardown.interface != nil else { return }

        // Unblock parked readers *before* the interface is destroyed. This is
        // the USB form of the rule `NWByteStream.close()` documents: it leaves
        // `stateUpdateHandler` installed precisely so the cancellation it
        // triggers can resume a caller parked on a continuation, because
        // clearing it first orphans that caller forever. Destroying the
        // interface first would do exactly that here.
        deliverFailure(.deviceRemoved)

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                // Asynchronous aborts, not synchronous. A synchronous abort
                // does not return until its aborted requests have completed —
                // and those completions are delivered on this very queue, which
                // this block is occupying. Asking for one here is a deadlock.
                try? teardown.input?.__abort(with: .asynchronous)
                try? teardown.output?.__abort(with: .asynchronous)
                try? teardown.interface?.__abortDeviceRequests(with: .asynchronous)
                teardown.interface?.destroy()
                continuation.resume()
            }
        }
    }

    deinit {
        let interface = lock.withLock { state.interface }
        interface?.destroy()
    }

    // MARK: - Queue hop

    private func onQueue<T>(_ body: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            nonisolated(unsafe) let body = body
            queue.async {
                do {
                    continuation.resume(returning: try body())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - IOKit

    private struct ServiceMatch {
        let service: io_service_t
        let ref: UsbDeviceRef
    }

    /// Matching by registry property rather than through
    /// `+[IOUSBHostInterface createMatchingDictionaryWithVendorID:…]`, which is
    /// `NS_REFINED_FOR_SWIFT` with no Swift overlay shipped in the SDK — so it
    /// is reachable only under a double-underscore spelling, for no gain over
    /// reading two integers.
    ///
    /// Caller owns the returned `io_service_t`s and must release them.
    private static func matchingServices(vendorID: UInt16, productID: UInt16) -> [ServiceMatch] {
        guard let matching = IOServiceMatching("IOUSBHostDevice") else { return [] }

        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }

        var matches: [ServiceMatch] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            guard let vendor = numberProperty(service, "idVendor"), UInt16(truncatingIfNeeded: vendor) == vendorID,
                  let product = numberProperty(service, "idProduct"), UInt16(truncatingIfNeeded: product) == productID,
                  let location = numberProperty(service, "locationID")
            else {
                IOObjectRelease(service)
                continue
            }

            matches.append(ServiceMatch(
                service: service,
                ref: UsbDeviceRef(
                    vendorID: vendorID,
                    productID: productID,
                    locationID: location,
                    productName: stringProperty(service, "USB Product Name"),
                    serialNumber: stringProperty(service, "USB Serial Number")
                )
            ))
        }
        return matches
    }

    /// The vendor-specific interface is a child of the device in the IOService
    /// plane. gs_usb adapters publish exactly one.
    private static func firstInterfaceService(of device: io_service_t) -> io_service_t? {
        var children: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(device, kIOServicePlane, &children) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(children) }

        while case let child = IOIteratorNext(children), child != 0 {
            if IOObjectConformsTo(child, "IOUSBHostInterface") != 0 {
                return child
            }
            IOObjectRelease(child)
        }
        return nil
    }

    private struct Endpoint {
        let address: UInt8
        let maxPacketSize: Int
    }

    /// `IOUSBHostInterface` exposes no speed property, so it comes from the
    /// registry. Only `IOUSBGetEndpointMaxPacketSize` wants it — to apply the
    /// high-speed burst multiplier, which for a bulk endpoint is always 1 — so
    /// falling back to full-speed when the key is absent cannot mis-size a
    /// buffer for the device this transport is built to talk to.
    private static func connectionSpeed(of service: io_service_t) -> UInt32 {
        numberProperty(service, "USBSpeed") ?? UInt32(kIOUSBHostConnectionSpeedFull.rawValue)
    }

    private static func bulkEndpoints(
        of interface: IOUSBHostInterface,
        speed: UInt32
    ) -> (input: Endpoint?, output: Endpoint?) {
        let configuration = interface.configurationDescriptor
        let descriptor = interface.interfaceDescriptor

        var input: Endpoint?
        var output: Endpoint?
        var current = IOUSBGetNextEndpointDescriptor(configuration, descriptor, nil)

        while let endpoint = current {
            if IOUSBGetEndpointType(endpoint) == UInt8(kIOUSBEndpointTypeBulk.rawValue) {
                let candidate = Endpoint(
                    address: IOUSBGetEndpointAddress(endpoint),
                    maxPacketSize: Int(IOUSBGetEndpointMaxPacketSize(speed, endpoint))
                )
                if IOUSBGetEndpointDirection(endpoint) == UInt8(kIOUSBEndpointDirectionIn.rawValue) {
                    input = input ?? candidate
                } else {
                    output = output ?? candidate
                }
            }
            current = IOUSBGetNextEndpointDescriptor(
                configuration,
                descriptor,
                UnsafeRawPointer(endpoint).assumingMemoryBound(to: IOUSBDescriptorHeader.self)
            )
        }
        return (input, output)
    }

    private static func numberProperty(_ service: io_service_t, _ key: String) -> UInt32? {
        guard let value = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? NSNumber
        else { return nil }
        return value.uint32Value
    }

    private static func stringProperty(_ service: io_service_t, _ key: String) -> String? {
        IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String
    }

    private static func bytes(of data: NSMutableData, count: Int) -> [UInt8] {
        guard count > 0 else { return [] }
        return [UInt8](UnsafeBufferPointer(
            start: data.bytes.assumingMemoryBound(to: UInt8.self),
            count: min(count, data.length)
        ))
    }
}

// MARK: - IOReturn translation

private extension UsbTransportError {
    /// `kIOUSBPipeStalled` is `iokit_usb_err(0x4f)` in `IOKit/usb/USB.h`, a
    /// macro over a macro, so it does not import into Swift. Spelled out here
    /// rather than left unhandled: a halted endpoint is the one transfer
    /// failure `GsUsbDevice` recovers from instead of reconnecting.
    static let pipeStalled = IOReturn(bitPattern: 0xe000_404f)

    /// One place, below the seam. Translating `kIOReturnNotResponding` is
    /// exactly the kind of knowledge the protocol exists to keep out of
    /// `GsUsbDevice`.
    init(ioReturn: IOReturn) {
        switch ioReturn {
        case kIOReturnAborted, kIOReturnNotResponding, kIOReturnNoDevice, kIOReturnOffline:
            self = .deviceRemoved
        case Self.pipeStalled:
            self = .stalled(String(format: "pipe stalled (0x%08x)", UInt32(bitPattern: ioReturn)))
        case kIOReturnTimeout:
            self = .timedOut
        case kIOReturnNotOpen, kIOReturnNotAttached:
            self = .notOpen
        default:
            self = .transferFailed(String(format: "IOReturn 0x%08x", UInt32(bitPattern: ioReturn)))
        }
    }
}

// MARK: - Resume guard

/// Single-claim flag so a continuation driven by a callback that may also be
/// preceded by a synchronous throw is resumed exactly once.
///
/// The same shape, and the same justification, as `ResumeGuard` in
/// `ByteStream.swift`: the one piece of mutable state is reachable only through
/// `claim()`, which holds the lock across the whole read-modify-write, and it
/// cannot be an actor because the caller is a synchronous completion block.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.withLock {
            guard !claimed else { return false }
            claimed = true
            return true
        }
    }
}
