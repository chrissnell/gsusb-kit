import Foundation
import GSUSBKit

/// A `UsbDeviceTransport` that replays a scripted conversation, so the whole
/// gs_usb driver can be tested with no adapter attached.
///
/// Successive `open()` calls replay successive sessions and the last one
/// repeats, which is what lets a reconnect test script "removed mid-read, then
/// healthy".
///
/// Shipped as part of the package rather than kept in its test target so a
/// host application can test its own adapter layer — the thing that maps
/// `GsUsbFrame` onto its model and `GsUsbNotice` onto its annotations —
/// against a scripted device instead of against hardware.
public actor ScriptedUsbTransport: UsbDeviceTransport {
    // MARK: Script types

    /// What `controlTransfer` does for one `bRequest`.
    public enum ControlResponse: Sendable, Equatable {
        /// An IN that returns these bytes.
        case bytes([UInt8])
        /// An OUT the device accepted. No data phase comes back.
        case acknowledged
        case failure(UsbTransportError)
    }

    /// One step of the bulk-IN script.
    ///
    /// The three injectable failures the plan asks for — surprise removal, a
    /// stalled pipe, a timeout — are one mechanism rather than three flags:
    /// `.failure(.deviceRemoved)`, `.failure(.stalled)`, `.failure(.timedOut)`.
    public enum BulkStep: Sendable, Equatable {
        case payload([UInt8])
        case failure(UsbTransportError)
        /// Park until `close()`. Models an idle bus, which is the state in
        /// which `stop()`'s promptness actually matters.
        case hang
    }

    /// One connection's worth of script.
    public struct Session: Sendable {
        /// Keyed on `bRequest`, not a positional queue: the handshake is a
        /// fixed sequence but `GET_STATE` is polled an unpredictable number of
        /// times, and a queue would make those tests depend on timing. The
        /// ordered `controlExchanges` recording is what sequence assertions
        /// read instead.
        public var control: [UInt8: ControlResponse]
        public var bulkReads: [BulkStep]
        /// What `bulkRead()` does once `bulkReads` is spent.
        public var bulkEnd: BulkStep
        /// Consumed one per `bulkWrite`; `nil` entries succeed. Runs off the
        /// end as success.
        public var writeFailures: [UsbTransportError?]
        /// Hand every accepted `bulkWrite` back as a bulk-IN transfer, which is
        /// what the device does to confirm a transmission (§6.2).
        ///
        /// Modelled rather than scripted because the ordering is the whole
        /// point: an echo has to arrive *after* its write, and a positional
        /// `bulkReads` list cannot express that — it would deliver the echo on
        /// the read loop's first call, before `send` had claimed a slot, and
        /// the transmit tests would then pass or fail on scheduling luck.
        public var echoesWrites: Bool
        public var interfaceInfo: UsbInterfaceInfo

        public init(
            control: [UInt8: ControlResponse] = [:],
            bulkReads: [BulkStep] = [],
            bulkEnd: BulkStep = .hang,
            writeFailures: [UsbTransportError?] = [],
            echoesWrites: Bool = false,
            interfaceInfo: UsbInterfaceInfo = UsbInterfaceInfo(
                interfaceNumber: 0,
                bulkInMaxPacketSize: 64,
                bulkOutMaxPacketSize: 64
            )
        ) {
            self.control = control
            self.bulkReads = bulkReads
            self.bulkEnd = bulkEnd
            self.writeFailures = writeFailures
            self.echoesWrites = echoesWrites
            self.interfaceInfo = interfaceInfo
        }
    }

    /// One recorded control transfer, for sequence assertions.
    public struct ControlExchange: Sendable, Equatable {
        public let request: UsbControlRequest
        public let payload: [UInt8]

        public init(request: UsbControlRequest, payload: [UInt8]) {
            self.request = request
            self.payload = payload
        }
    }

    // MARK: Script

    private let devices: [UsbDeviceRef]
    private let enumerateFailure: UsbTransportError?
    /// Consumed one per `open`; `nil` entries succeed. Runs off the end as
    /// success, so "fail twice then connect" is `[err, err]`.
    private var openFailures: [UsbTransportError?]
    private let sessions: [Session]

    // MARK: State

    private var sessionIndex = -1
    private var readCursor = 0
    private var writeCursor = 0
    private var isOpen = false
    /// Readers parked on `.hang`. `close()` resumes them, and modelling that
    /// faithfully is the whole reason this double parks on real continuations
    /// instead of returning `.notOpen`: a double that never blocked would make
    /// phase 5's `stop()`-during-read test pass whether or not the property
    /// held.
    private var parkedReaders: [CheckedContinuation<[UInt8], Error>] = []
    /// Echoes produced by `bulkWrite` that no reader was parked for yet.
    /// Delivered ahead of the scripted steps, because an echo the device has
    /// already put on the bulk-IN endpoint arrives before anything the script
    /// says comes next.
    private var pendingEchoes: [[UInt8]] = []

    // MARK: Recordings

    public private(set) var enumerateCount = 0
    public private(set) var openAttempts = 0
    public private(set) var closeCount = 0
    public private(set) var openedDevices: [UsbDeviceRef] = []
    public private(set) var controlExchanges: [ControlExchange] = []
    public private(set) var bulkWrites: [[UInt8]] = []

    public init(
        devices: [UsbDeviceRef] = [ScriptedUsbTransport.defaultDevice],
        enumerateFailure: UsbTransportError? = nil,
        openFailures: [UsbTransportError?] = [],
        sessions: [Session] = [Session()]
    ) {
        self.devices = devices
        self.enumerateFailure = enumerateFailure
        self.openFailures = openFailures
        self.sessions = sessions.isEmpty ? [Session()] : sessions
    }

    public static let defaultDevice = UsbDeviceRef(
        vendorID: 0x1D50,
        productID: 0x606F,
        locationID: 0x0210_0000,
        productName: "SH-C30x",
        serialNumber: "0001"
    )

    // MARK: UsbDeviceTransport

    public func enumerate() async throws -> [UsbDeviceRef] {
        enumerateCount += 1
        if let enumerateFailure { throw enumerateFailure }
        return devices
    }

    public func open(_ device: UsbDeviceRef) async throws -> UsbInterfaceInfo {
        openAttempts += 1
        if !openFailures.isEmpty, let failure = openFailures.removeFirst() {
            throw failure
        }
        openedDevices.append(device)
        sessionIndex = min(sessionIndex + 1, sessions.count - 1)
        readCursor = 0
        writeCursor = 0
        pendingEchoes = []
        isOpen = true
        return sessions[sessionIndex].interfaceInfo
    }

    public func controlTransfer(_ request: UsbControlRequest, payload: [UInt8]) async throws -> [UInt8] {
        guard isOpen else { throw UsbTransportError.notOpen }
        controlExchanges.append(ControlExchange(request: request, payload: payload))

        // An unscripted request throws rather than returning empty. A double
        // that silently answers a request the test author never considered is
        // a double that lets a wrong handshake pass.
        guard let response = sessions[sessionIndex].control[request.request] else {
            throw UsbTransportError.transferFailed(
                "ScriptedUsbTransport: no response scripted for bRequest \(request.request)"
            )
        }

        switch response {
        case .bytes(let bytes):
            guard bytes.count >= Int(request.length) else {
                throw UsbTransportError.shortTransfer(expected: Int(request.length), actual: bytes.count)
            }
            return Array(bytes.prefix(Int(request.length)))
        case .acknowledged:
            return []
        case .failure(let error):
            throw error
        }
    }

    public func bulkRead() async throws -> [UInt8] {
        guard isOpen else { throw UsbTransportError.notOpen }

        if !pendingEchoes.isEmpty {
            return pendingEchoes.removeFirst()
        }

        let session = sessions[sessionIndex]
        let step: BulkStep
        if readCursor < session.bulkReads.count {
            step = session.bulkReads[readCursor]
            readCursor += 1
        } else {
            step = session.bulkEnd
        }

        switch step {
        case .payload(let bytes):
            return bytes
        case .failure(let error):
            throw error
        case .hang:
            return try await park()
        }
    }

    public func bulkWrite(_ bytes: [UInt8]) async throws {
        guard isOpen else { throw UsbTransportError.notOpen }
        let failures = sessions[sessionIndex].writeFailures
        let failure = writeCursor < failures.count ? failures[writeCursor] : nil
        writeCursor += 1
        if let failure { throw failure }
        bulkWrites.append(bytes)

        guard sessions[sessionIndex].echoesWrites else { return }
        // A reader parked on `.hang` is the common case: the read loop is idle
        // on an empty bus when `send` runs. Resuming it directly is what makes
        // the echo arrive *after* the write.
        if !parkedReaders.isEmpty {
            parkedReaders.removeFirst().resume(returning: bytes)
        } else {
            pendingEchoes.append(bytes)
        }
    }

    public func close() async {
        isOpen = false

        let parked = parkedReaders
        parkedReaders = []
        for continuation in parked {
            continuation.resume(throwing: UsbTransportError.deviceRemoved)
        }

        // Closing real hardware is not instantaneous, and modelling that is
        // what makes a caller's close-then-await-the-loop ordering observable.
        // With an immediate close, a `stop()` that does *not* wait for its read
        // loop still sees the loop finish first, purely because its own
        // suspension points hand the loop enough slices — so the guarantee
        // looks held whether or not it is. `ScriptedByteStream.close()` yields
        // for the same reason.
        for _ in 0..<64 { await Task.yield() }
        closeCount += 1
    }

    // MARK: Parking

    private func park() async throws -> [UInt8] {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // Re-check under actor isolation: `close()` may have run
                // between the guard in `bulkRead` and here, in which case
                // parking would wait for a resume that already happened.
                if isOpen {
                    parkedReaders.append(continuation)
                } else {
                    continuation.resume(throwing: UsbTransportError.deviceRemoved)
                }
            }
        } onCancel: {
            Task { await self.cancelParkedReaders() }
        }
    }

    private func cancelParkedReaders() {
        let parked = parkedReaders
        parkedReaders = []
        for continuation in parked {
            continuation.resume(throwing: CancellationError())
        }
    }
}
