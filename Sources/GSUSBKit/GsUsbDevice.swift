import Foundation

// MARK: - Options

/// How a `GsUsbDevice` should bring the controller up.
///
/// The one rule this type exists to enforce: **a default-constructed
/// `GsUsbOptions` cannot put a bit on the bus.** `busAccess` is an enum
/// rather than a `Bool` precisely so that bus-active operation has to be
/// spelled out at the call site — `busAccess: .busActive` reads as a decision,
/// where `listenOnly: false` reads as a parameter somebody forgot to set, and
/// a positional `Bool` reads as nothing at all. Design §6.4.
public struct GsUsbOptions: Sendable, Equatable {
    /// Silent receiver, or a node that acknowledges. There is no third state
    /// and no default-to-active path.
    public enum BusAccess: Sendable, Equatable {
        /// `GS_CAN_FEATURE_LISTEN_ONLY`: the controller holds its TX pin
        /// recessive, sends no acknowledgements, no error frames and no
        /// retransmissions. The only configuration safe against a live
        /// vehicle bus.
        case listenOnly
        /// A full CAN node. Acknowledges every frame it receives, which is
        /// observable by every other controller on the bus.
        case busActive
    }

    /// Classical CAN, or CAN FD with the rate its data phase runs at.
    ///
    /// An enum with the data bitrate *inside* the CAN FD case, rather than a
    /// `canFD: Bool` beside an optional `dataBitrate`, because those two
    /// spellings admit two states that do not exist: CAN FD with no data rate
    /// to switch to, and a data rate on a link that will never leave the
    /// arbitration phase. Neither can be constructed here.
    ///
    /// The data bitrate is a second, independent bit-timing solution against
    /// the device's data-phase limits (`BREQ_BT_CONST_EXT`), so it is subject
    /// to the same 0.5% ceiling as `bitrate` and refused the same way.
    public enum FrameFormat: Sendable, Equatable {
        case classical
        /// `dataBitrate` is the rate the payload and CRC run at once the
        /// bit-rate switch happens — 2 Mbit/s is the common automotive choice.
        case canFD(dataBitrate: UInt32)

        public var isCanFD: Bool { self != .classical }

        public var dataBitrate: UInt32? {
            if case let .canFD(dataBitrate) = self { return dataBitrate }
            return nil
        }
    }

    /// The arbitration-phase bitrate, and the only one on a classical link.
    public var bitrate: UInt32
    public var busAccess: BusAccess
    /// Classical CAN by default. Requesting CAN FD from an adapter that does
    /// not report `GS_CAN_FEATURE_FD` is refused at connect rather than
    /// quietly downgraded — see `GsUsbDeviceError.canFDNotSupported`.
    public var frameFormat: FrameFormat
    /// `GS_CAN_FEATURE_ONE_SHOT`, requested when the device offers it. Silent
    /// in listen-only — there is nothing to retransmit — but requested anyway
    /// so the flag word does not change meaning when phase 7 adds transmit.
    public var oneShot: Bool
    /// Prefer the adapter's own microsecond counter over host completion time
    /// (§7.1). Ignored when the device does not report the feature, which is
    /// the degraded case `GsUsbDevice.timestampMode` then reports.
    public var hardwareTimestamps: Bool
    /// Which adapter to open when several are attached. `nil` takes the first
    /// the transport enumerates.
    public var serialNumber: String?

    public init(
        bitrate: UInt32 = 500_000,
        busAccess: BusAccess = .listenOnly,
        frameFormat: FrameFormat = .classical,
        oneShot: Bool = true,
        hardwareTimestamps: Bool = true,
        serialNumber: String? = nil
    ) {
        self.bitrate = bitrate
        self.busAccess = busAccess
        self.frameFormat = frameFormat
        self.oneShot = oneShot
        self.hardwareTimestamps = hardwareTimestamps
        self.serialNumber = serialNumber
    }

    public var listenOnly: Bool { busAccess == .listenOnly }
    public var canFD: Bool { frameFormat.isCanFD }
}

// MARK: - Timestamp mode

/// Which of design §7.1's two timestamp sources a connection ended up using.
public enum GsUsbTimestampMode: String, Sendable, Equatable, CaseIterable {
    /// The adapter's 32-bit microsecond counter, stamped at frame receipt.
    case hardware
    /// Host USB-completion time. Every frame in one bulk transfer lands within
    /// microseconds of its neighbours, so intra-burst ordering information is
    /// smeared away — which is exactly what the analysis layer reads.
    case hostCompletion

    /// True when a session recorded in this mode must be labelled as such, in
    /// the status strip and in the manifest. §7.1: a smeared capture has to be
    /// identifiable afterwards, not filed alongside good ones.
    public var isDegraded: Bool { self == .hostCompletion }

    /// The suffix in a source description (§8.4).
    public var shortLabel: String {
        switch self {
        case .hardware: return "hw-ts"
        case .hostCompletion: return "host-ts"
        }
    }
}

// MARK: - Errors

/// Refusals that belong to the gs_usb driver rather than to the USB stack.
///
/// The split that matters is `isFatal`: a refusal is a decision the device
/// will repeat verbatim on the next attempt, so retrying it on the backoff
/// ladder would be an infinite loop that hides the reason. Only
/// `noDeviceFound` is retryable, because hotplug genuinely cures it.
public enum GsUsbDeviceError: Error, Equatable, Sendable, CustomStringConvertible {
    /// No attached adapter matched. Ordinary before the cable is plugged in.
    case noDeviceFound(serialNumber: String?)
    /// CAN FD was requested and the device does not report
    /// `GS_CAN_FEATURE_FD`.
    ///
    /// Refused rather than brought up classical, for the same reason
    /// `listenOnlyNotSupported` is: the caller asked for a link that carries
    /// 64-byte frames, and a classical link silently substituted would drop
    /// every FD frame on the bus while reporting a healthy connection.
    case canFDNotSupported(reportedFeatures: UInt32)
    /// CAN FD was requested and the device reports `GS_CAN_FEATURE_FD` but not
    /// `GS_CAN_FEATURE_BT_CONST_EXT`, so its data-phase segment and prescaler
    /// limits cannot be read and the data bitrate cannot be solved.
    ///
    /// The arbitration limits are not a substitute: an FDCAN peripheral's data
    /// phase has its own, differently shaped ranges, and solving against the
    /// wrong ones would configure a data bitrate that is not the one reported.
    case dataBitTimingConstantsUnavailable(reportedFeatures: UInt32)
    /// Listen-only was asked for and the device cannot do it. The one case
    /// where failing to connect is the correct outcome: a device that cannot
    /// be silent must not be opened when silence was the requirement.
    case listenOnlyNotSupported(reportedFeatures: UInt32)
    /// A decoded frame carried a non-zero `gs_host_frame.channel`. Multi-channel
    /// adapters are out of scope (§11) and merging their channels into one
    /// stream would silently mislabel every frame (§7.3).
    case multiChannelDevice(channel: UInt8)

    public var isFatal: Bool {
        switch self {
        case .noDeviceFound:
            return false
        case .canFDNotSupported, .dataBitTimingConstantsUnavailable,
             .listenOnlyNotSupported, .multiChannelDevice:
            return true
        }
    }

    public var description: String {
        switch self {
        case .noDeviceFound(let serial):
            if let serial {
                return "no gs_usb adapter with serial \(serial) is attached"
            }
            return "no gs_usb adapter is attached"
        case .canFDNotSupported(let features):
            return String(
                format: "CAN FD was requested and this adapter does not support "
                    + "it (features 0x%08x); refusing to open it as classical CAN",
                features
            )
        case .dataBitTimingConstantsUnavailable(let features):
            return String(
                format: "CAN FD was requested and this adapter does not report "
                    + "its data-phase bit-timing limits (features 0x%08x), so the "
                    + "data bitrate cannot be solved",
                features
            )
        case .listenOnlyNotSupported(let features):
            return String(
                format: "listen-only was requested and this adapter does not "
                    + "support it (features 0x%08x); refusing to open it bus-active",
                features
            )
        case .multiChannelDevice(let channel):
            return "this adapter reported a frame on channel \(channel); "
                + "multi-channel adapters are not supported"
        }
    }
}

// MARK: - Transmit errors

/// Why a `send` did not put a frame on the wire.
///
/// A separate type from `GsUsbDeviceError` because that enum's `isFatal` is a
/// statement about the *reconnect ladder*, and none of these ever reach it: a
/// refused, unacknowledged or cancelled transmit leaves the connection
/// perfectly healthy and the read loop untouched.
public enum GsUsbTransmitError: Error, Equatable, Sendable, CustomStringConvertible {
    /// `send` was called on a listen-only connection.
    ///
    /// The controller is physically unable to transmit in silent mode, and the
    /// only thing that changes that is reconnecting with `busAccess:
    /// .busActive`. Doing that implicitly, to honour a `send`, would put a
    /// frame on a vehicle bus the operator never armed for — so this is a
    /// refusal, permanently, and not a condition `send` tries to fix.
    case listenOnly
    /// A CAN FD frame was handed to a connection brought up as classical CAN.
    ///
    /// Same shape of refusal as `listenOnly`, and for the same reason: the
    /// controller's frame format was fixed at `MODE`, so the only way to
    /// honour this would be to send the payload as a classical frame — a
    /// different frame, truncated to 8 bytes, that the caller did not ask for.
    case canFDNotEnabled
    /// No connection is up, so there is no endpoint to write to.
    case notConnected
    /// The echo never came back inside the timeout. Design §6.2: with
    /// retransmission in force and nothing on the bus to acknowledge the
    /// frame, the controller retries until it goes bus-off and the echo never
    /// arrives, so without this the UI would hang on a mystery.
    case notAcknowledged
    /// The frame could not be built — a payload longer than eight bytes.
    case invalidFrame(String)
    /// The bulk-OUT write itself failed.
    case writeFailed(String)

    public var description: String {
        switch self {
        case .listenOnly:
            return "this connection is listen-only, so it cannot transmit; "
                + "reconnect with bus access enabled to send frames"
        case .canFDNotEnabled:
            return "this connection is classical CAN, so it cannot transmit a "
                + "CAN FD frame; reconnect with frameFormat: "
                + ".canFD(dataBitrate:) to send one"
        case .notConnected:
            return "no adapter is connected"
        case .notAcknowledged:
            return "no node acknowledged the frame — is anything else on the "
                + "bus, and is termination switched in?"
        case .invalidFrame(let message):
            return message
        case .writeFailed(let message):
            return message
        }
    }
}

// MARK: - Capability box

/// Carries the transmit facts a host reads synchronously.
///
/// `oneShotActive` is read while drawing a status strip on the main thread and
/// written during the handshake on the connect task, so it cannot live in
/// `GsUsbDevice`'s actor-isolated storage without making every reader `async`.
/// That is exactly the shape an explicit lock is for.
final class TransmitCapabilityBox: @unchecked Sendable {
    private let lock = NSLock()
    private var oneShot = false

    /// Whether the live connection negotiated `GS_CAN_FEATURE_ONE_SHOT`.
    /// §6.2 requires the UI to say which retransmission mode is in force,
    /// because it decides whether `send`'s timeout is the only backstop.
    var oneShotActive: Bool {
        get { lock.withLock { oneShot } }
        set { lock.withLock { oneShot = newValue } }
    }
}

// MARK: - GsUsbDevice

/// Drives a gs_usb (candleLight-class) CAN adapter over USB: enumerate, open,
/// handshake, read, decode, timestamp, transmit, reconnect.
///
/// Frames go to the `GsUsbFrameConsumer` supplied at init, state to `states`
/// and annotations to `notices`. Nothing here knows what the host does with
/// them.
///
/// **A default-constructed device cannot put a bit on the bus.** It is
/// listen-only, and `send` on a listen-only connection throws
/// `GsUsbTransmitError.listenOnly` rather than reconfiguring the controller to
/// honour it. Transmitting requires having asked for `busAccess: .busActive`
/// at connect time, which is a deliberate act with a visible consequence
/// (§6.4).
public actor GsUsbDevice {
    // MARK: Collaborators

    /// Where each decoded frame goes, awaited in arrival order. See
    /// `GsUsbFrameConsumer` for why this is not a stream.
    private let consumer: any GsUsbFrameConsumer

    /// One transport instance, not a factory, because a reconnect re-enumerates
    /// through the same transport: `enumerate()` is what re-finds the device
    /// after a cable bounce, and a fresh transport per attempt would discard the
    /// identity bookkeeping below the seam that makes that possible.
    private let transport: any UsbDeviceTransport
    private let options: GsUsbOptions
    private let backoff: GsUsbBackoffPolicy
    private let clock: any GsUsbClock
    /// `CLOCK_REALTIME` in nanoseconds, injected so `TimestampMapper`'s anchor
    /// is testable. `Frame.timestampNs` is on this timebase, not `clock`'s.
    private let realtimeNowNs: @Sendable () -> Int64
    private let statePollInterval: Duration
    private let reanchorInterval: Duration
    /// How long `send` waits for its echo before reporting §6.2's message.
    private let sendTimeout: Duration
    /// Read without actor isolation, so `oneShotActive` stays synchronous.
    private let transmitCapability = TransmitCapabilityBox()

    // MARK: Streams

    private let stateContinuation: AsyncStream<GsUsbConnectionState>.Continuation
    /// `nonisolated` so a host can subscribe without an actor hop — and, more
    /// to the point, so it can subscribe from inside its own initialiser,
    /// before anything is `async`.
    public nonisolated let states: AsyncStream<GsUsbConnectionState>
    private let noticeContinuation: AsyncStream<GsUsbNotice>.Continuation
    public nonisolated let notices: AsyncStream<GsUsbNotice>

    // MARK: Observable state

    public private(set) var statistics = GsUsbStatistics()
    public private(set) var isRunning = false
    /// Which of the two timestamp sources the live connection ended up using.
    /// A host that records frames should record this answer alongside them.
    public private(set) var timestampMode = GsUsbTimestampMode.hostCompletion
    /// §8.4's free-text source description — `"gs_usb SH-C30x #0001 500k
    /// listen-only hw-ts"`. Also what every published frame carries as
    /// `GsUsbFrame.sourceDescription`.
    public private(set) var sourceDescription: String

    // MARK: Per-connection state

    private var loop: Task<Void, Never>?
    /// `seq` is generated here and restarts at 0 for each connection (§7.2),
    /// which is the only scope in which frames are compared or diffed.
    private var nextSeq: UInt64 = 0
    private var mapper: TimestampMapper?
    /// Whether this connection's frames carry the trailing `timestamp_us`
    /// word, in both directions. Half of what sizes a frame; the other half is
    /// the frame's own `GS_CAN_FLAG_FD`, which is why there is no single
    /// stored layout any more.
    private var framesAreTimestamped = false
    private var lastBusState = GsCanState.errorActive
    /// Set by the state poller when it decides the connection is over, so the
    /// reason the read loop reports (an aborted transfer) does not mask the
    /// reason that actually matters (bus-off).
    private var pendingDisconnectReason: String?
    /// A refusal discovered mid-connection. Checked by `runForever` so the
    /// ladder is not spun against a device that will answer identically.
    private var refusal: GsUsbDeviceError?

    // MARK: Transmit state

    /// `GS_MAX_TX_URBS` — what the protocol allows in flight per channel, and
    /// what `maxFramesInFlight` reports rather than leaving the call site to
    /// guess.
    static let transmitSlotCount = 10

    /// How many frames may be awaiting their echo at once. The eleventh
    /// concurrent `send` parks until a slot is released, which is where the
    /// driver's backpressure comes from.
    public static var maxFramesInFlight: Int { transmitSlotCount }

    /// Slot indices nobody is using, lowest first. `echo_id` is the slot index,
    /// and 0 is a real slot — `0xFFFFFFFF` is what marks a *received* frame.
    private var freeSlots: [UInt32] = []
    /// Slots with a frame written and no echo back yet. An echo quoting a slot
    /// absent from this set is not ours, which is what stops a stray device
    /// frame from resolving a send or entering the recording as a transmission.
    private var claimedSlots: Set<UInt32> = []
    /// Sends parked on their echo, keyed by slot.
    private var echoWaiters: [UInt32: TransmitWaiter] = [:]
    /// Identifies a send within its slot's history. Slots are reused the moment
    /// they are released, so "the send parked on slot 3" is not a stable
    /// reference — see `resolveTransmit`.
    private var nextTransmitTicket: UInt64 = 0
    /// Echoes that arrived while `send` was still inside `bulkWrite` and had
    /// not registered its waiter yet. Without this the frame would be
    /// confirmed, the record correct, and `send` would still time out.
    private var earlyEchoes: Set<UInt32> = []
    /// Sends waiting for any slot at all. This is where §6.2's free
    /// backpressure comes from: the eleventh concurrent send parks here.
    private var slotWaiters: [CheckedContinuation<UInt32, Error>] = []
    /// False outside a live connection, so `send` refuses instead of writing
    /// to a closed interface.
    private var isConnected = false

    // MARK: Init

    public init(
        transport: any UsbDeviceTransport,
        consumer: any GsUsbFrameConsumer,
        options: GsUsbOptions = GsUsbOptions(),
        backoff: GsUsbBackoffPolicy = .default,
        clock: any GsUsbClock = GsUsbSystemClock(),
        realtimeNowNs: @escaping @Sendable () -> Int64 = {
            Int64(Date().timeIntervalSince1970 * 1_000_000_000)
        },
        statePollInterval: Duration = .milliseconds(250),
        reanchorInterval: Duration = .seconds(30),
        sendTimeout: Duration = .milliseconds(500)
    ) {
        self.sendTimeout = sendTimeout
        self.transport = transport
        self.options = options
        self.backoff = backoff
        self.clock = clock
        self.consumer = consumer
        self.realtimeNowNs = realtimeNowNs
        self.statePollInterval = statePollInterval
        self.reanchorInterval = reanchorInterval
        sourceDescription = Self.describeSource(device: nil, options: options, timestampMode: nil)
        (states, stateContinuation) = AsyncStream<GsUsbConnectionState>.makeStream(
            bufferingPolicy: .bufferingNewest(16)
        )
        (notices, noticeContinuation) = AsyncStream<GsUsbNotice>.makeStream(
            bufferingPolicy: .bufferingNewest(256)
        )
    }

    /// Ends `states` and `notices`. An `AsyncStream` whose continuation is
    /// discarded without finishing never terminates, so without this a consumer
    /// iterating either stream after the source goes away awaits forever.
    deinit {
        stateContinuation.finish()
        noticeContinuation.finish()
    }

    // MARK: - Lifecycle

    /// Starts the connect/read loop. Idempotent.
    ///
    /// A started device keeps itself alive: the loop task holds `self`
    /// strongly while `runForever()` runs, so `stop()` is mandatory — dropping
    /// the last external reference to a running device leaks the device, the
    /// claimed USB interface, and the loop.
    public func start() {
        guard loop == nil else { return }
        isRunning = true
        loop = Task { [weak self] in
            await self?.runForever()
        }
    }

    /// Stops the loop and releases the interface. Returns only once the loop
    /// has actually finished, so the device is left restartable.
    public func stop() async {
        isRunning = false
        let loop = self.loop
        self.loop = nil
        loop?.cancel()
        // Closing first is what unblocks a `bulkRead` parked on an idle bus;
        // cancellation alone does not retire an enqueued USB transfer. Reversing
        // these two lines is a defect: the loop would still be winding down
        // when `stop()` returned, free to tear down state a subsequent
        // `start()` had already installed.
        await transport.close()
        await loop?.value
        stateContinuation.yield(.disconnected(reason: "stopped"))
    }

    public func currentStatistics() -> GsUsbStatistics {
        statistics
    }

    // MARK: - Transmit

    /// Whether the live connection negotiated `GS_CAN_FEATURE_ONE_SHOT`, so
    /// the controller will abandon a frame nobody acknowledges instead of
    /// retransmitting it until it goes bus-off.
    ///
    /// False outside a connection, because nothing has been negotiated yet —
    /// a host must not promise a mode the controller never entered. It decides
    /// whether `send`'s timeout is the only backstop, which is why it is
    /// reported rather than assumed.
    ///
    /// `nonisolated` so a status strip can read it synchronously; it comes
    /// from lock-guarded storage, not from actor state.
    public nonisolated var oneShotActive: Bool {
        transmitCapability.oneShotActive
    }

    /// Writes `frame` and returns once the device echoes it back (§6.2).
    ///
    /// The echo is the only transmit confirmation the protocol offers, so
    /// awaiting it is what makes a successful return mean "this frame was on
    /// the wire" rather than "this frame was handed to USB". Returning early
    /// would make the recording's `tx` frames and the UI's send confirmations
    /// both claims nobody checked.
    ///
    /// Three refusals, and none of them is a condition `send` tries to fix: a
    /// listen-only connection, a `fd` frame on a connection brought up as
    /// classical CAN, and a payload the frame's own format cannot express —
    /// above 8 bytes classical, or a CAN FD length no DLC stands for.
    public func send(_ frame: GsUsbOutboundFrame) async throws {
        // First, before any state is touched and any byte is written. A
        // listen-only controller holds its TX pin recessive, so this is a
        // statement about the hardware, not a policy that could be relaxed.
        guard !options.listenOnly else { throw GsUsbTransmitError.listenOnly }
        // Before the payload is looked at: which format the controller is in
        // decides what "too long" even means.
        if frame.fd {
            guard options.canFD else { throw GsUsbTransmitError.canFDNotEnabled }
        } else if frame.data.count > 8 {
            throw GsUsbTransmitError.invalidFrame(
                "a classical CAN frame carries at most 8 bytes; this one has "
                    + "\(frame.data.count)"
            )
        }
        guard isConnected else { throw GsUsbTransmitError.notConnected }

        let slot = try await claimSlot()

        let bytes: [UInt8]
        do {
            bytes = try GsHostFrame(
                transmitSlot: slot,
                canID: frame.canID,
                extended: frame.extended,
                remoteRequest: frame.rtr,
                canFD: frame.fd,
                bitRateSwitch: frame.bitRateSwitch,
                data: frame.data
            ).encoded(as: GsHostFrame.Layout(
                // The frame's own format, not the connection's: the device
                // sizes the transfer it is being handed from the FD flag in
                // these very bytes, so a classical frame on a CAN FD link goes
                // out as the 24-byte struct and is echoed back as one.
                canFD: frame.fd, timestamped: framesAreTimestamped
            ))
        } catch {
            releaseSlot(slot)
            throw GsUsbTransmitError.invalidFrame(Self.describe(error))
        }

        do {
            try await transport.bulkWrite(bytes)
        } catch {
            releaseSlot(slot)
            throw GsUsbTransmitError.writeFailed(Self.describe(error))
        }

        // `bulkWrite` suspends, so the read loop may already have delivered
        // this slot's echo. Checked here, where nothing suspends between the
        // check and the registration below, so the echo cannot slip through
        // the gap between them.
        if earlyEchoes.remove(slot) != nil {
            releaseSlot(slot)
            return
        }

        let ticket = nextTransmitTicket
        nextTransmitTicket += 1

        let timeout = Task { [weak self] in
            guard let self else { return }
            try? await self.clock.sleep(for: self.sendTimeout)
            await self.resolveTransmit(
                slot: slot, ticket: ticket, with: .failure(GsUsbTransmitError.notAcknowledged)
            )
        }
        defer { timeout.cancel() }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                echoWaiters[slot] = TransmitWaiter(ticket: ticket, continuation: continuation)
            }
        } onCancel: {
            // A checked continuation that is never resumed traps, and
            // `PeriodicTransmitter` cancels streams that may be parked right
            // here, so cancellation has to resolve the waiter rather than
            // merely unwind around it.
            Task {
                await self.resolveTransmit(
                    slot: slot, ticket: ticket, with: .failure(CancellationError())
                )
            }
        }
    }

    private struct TransmitWaiter {
        let ticket: UInt64
        let continuation: CheckedContinuation<Void, Error>
    }

    // MARK: - TX slots

    /// Takes a free slot, parking until one is released if all ten are in use.
    private func claimSlot() async throws -> UInt32 {
        if !freeSlots.isEmpty {
            let slot = freeSlots.removeFirst()
            claimedSlots.insert(slot)
            return slot
        }
        let slot = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<UInt32, Error>) in
                slotWaiters.append(continuation)
            }
        } onCancel: {
            Task { await self.cancelLongestWaitingSlotClaim() }
        }
        claimedSlots.insert(slot)
        return slot
    }

    /// Hands the slot to whoever has been waiting longest, or returns it to the
    /// pool. Handing it over directly rather than via the pool is what keeps
    /// the queue fair: a slot pushed back could be taken by a fresh `send`
    /// that arrived after the parked one.
    private func releaseSlot(_ slot: UInt32) {
        claimedSlots.remove(slot)
        earlyEchoes.remove(slot)
        if !slotWaiters.isEmpty {
            slotWaiters.removeFirst().resume(returning: slot)
        } else {
            freeSlots.append(slot)
            freeSlots.sort()
        }
    }

    private func cancelLongestWaitingSlotClaim() {
        guard !slotWaiters.isEmpty else { return }
        slotWaiters.removeFirst().resume(throwing: CancellationError())
    }

    /// Resolves the send parked on `slot`, exactly once.
    ///
    /// Taking the waiter out of the dictionary is the arbiter: the echo and the
    /// timeout race, and whichever reaches this first takes the continuation
    /// and the other finds nothing. Both outcomes release the slot, so a
    /// timed-out send does not retire one of the ten permanently.
    ///
    /// `ticket` identifies *which* send is being resolved and must be supplied
    /// by everything except the echo. A slot is released the instant its send
    /// returns and is handed straight to the next one, so a timeout or
    /// cancellation that lands a moment late would otherwise fail a completely
    /// different frame — the symptom being one `send` throwing the previous
    /// send's timeout the moment it registered.
    private func resolveTransmit(
        slot: UInt32, ticket: UInt64? = nil, with result: Result<Void, Error>
    ) {
        guard let waiter = echoWaiters[slot] else { return }
        if let ticket, waiter.ticket != ticket { return }
        echoWaiters[slot] = nil
        waiter.continuation.resume(with: result)
        releaseSlot(slot)
    }

    /// Clears the pool for a fresh connection. Slot indices are meaningless
    /// across connections — the device forgets them when the interface closes.
    private func resetTransmitSlots() {
        failPendingTransmits(with: .notConnected)
        freeSlots = (0..<UInt32(Self.transmitSlotCount)).map { $0 }
        claimedSlots = []
        earlyEchoes = []
    }

    /// Fails every parked send and slot claim. Called when a connection ends,
    /// so a `send` awaiting an echo from an interface that just closed gets an
    /// answer instead of waiting out its timeout.
    private func failPendingTransmits(with error: GsUsbTransmitError) {
        let waiters = echoWaiters
        echoWaiters = [:]
        for (_, waiter) in waiters {
            waiter.continuation.resume(throwing: error)
        }
        let claims = slotWaiters
        slotWaiters = []
        for continuation in claims {
            continuation.resume(throwing: error)
        }
    }

    // MARK: - Connect loop

    private func runForever() async {
        // 1-based position in the backoff ladder for the *next* connect.
        var attempt = 0

        while isRunning, !Task.isCancelled {
            attempt += 1
            stateContinuation.yield(.connecting(attempt: attempt))

            let configuration: Configuration
            do {
                configuration = try await connectAndConfigure()
            } catch {
                await transport.close()
                stateContinuation.yield(.disconnected(reason: Self.describe(error)))
                if Self.isUnretryable(error) {
                    isRunning = false
                    return
                }
                guard let delay = backoff.delay(forAttempt: attempt) else { return }
                statistics.reconnectCount += 1
                try? await clock.sleep(for: delay)
                continue
            }

            stateContinuation.yield(.connected)

            let reason = await runConnection(configuration)

            await transport.close()
            stateContinuation.yield(.disconnected(reason: reason))

            if let refusal, refusal.isFatal {
                isRunning = false
                return
            }
            guard isRunning, !Task.isCancelled else { return }

            // A connection that actually came up resets the ladder, exactly as
            // a link that worked once is likely to work again.
            attempt = 1
            guard let delay = backoff.delay(forAttempt: attempt) else { return }
            statistics.reconnectCount += 1
            try? await clock.sleep(for: delay)
        }
    }

    /// Everything a live connection needs that was discovered while bringing
    /// it up. Passed to the read loop and the pollers so none of them has to
    /// re-read the device to find out what was negotiated.
    private struct Configuration: Sendable {
        let interface: UsbInterfaceInfo
        let features: GsCanFeature
        let modeFlags: GsCanFeature
        let timestampMode: GsUsbTimestampMode
        /// Whether `gs_host_frame` carries its trailing timestamp word on this
        /// connection. Not a full layout, because CAN FD makes the data field
        /// a property of each frame rather than of the connection.
        let timestamped: Bool
    }

    // MARK: - Handshake

    /// Enumerate, open, and run design §9's configuring transfers:
    /// `HOST_FORMAT` → `BT_CONST` → (`BT_CONST_EXT`) → `BITTIMING` →
    /// (`DATA_BITTIMING`) → `MODE(START, flags)`, the bracketed two only on a
    /// CAN FD connection.
    ///
    /// The order is not cosmetic. `HOST_FORMAT` declares the host's byte order
    /// and so must precede the first multi-byte struct read back. `BT_CONST`
    /// must precede `BITTIMING` because it carries the clock and segment limits
    /// the solution is computed from, and it must precede `MODE` because it
    /// carries the feature word the flags are derived from. Every refusal
    /// happens in the window between `BT_CONST` and `BITTIMING` — after the
    /// device has told us what it is, and before a single transfer that would
    /// change how it behaves on the bus.
    ///
    /// `BT_CONST_EXT` is an IN transfer and both bit-timing solutions are
    /// computed before either is sent, which keeps that window intact for CAN
    /// FD too: an unreachable data bitrate is refused with the arbitration
    /// phase still unconfigured, rather than leaving the controller half set
    /// up at a rate nobody asked to run at.
    private func connectAndConfigure() async throws -> Configuration {
        let devices = try await transport.enumerate()
        let device: UsbDeviceRef
        if let wanted = options.serialNumber {
            guard let match = devices.first(where: { $0.serialNumber == wanted }) else {
                throw GsUsbDeviceError.noDeviceFound(serialNumber: wanted)
            }
            device = match
        } else {
            guard let first = devices.first else {
                throw GsUsbDeviceError.noDeviceFound(serialNumber: nil)
            }
            device = first
        }

        let interface = try await transport.open(device)

        // 1. HOST_FORMAT. `wValue` is 1 rather than the channel index, which is
        // what the Linux driver sends and what `gsusbprobe` confirmed works.
        _ = try await transport.controlTransfer(
            .vendorInterfaceOut(
                request: GsUsbBreq.hostFormat.rawValue,
                value: 1,
                interface: interface.interfaceNumber,
                length: GsHostConfig.byteCount
            ),
            payload: GsHostConfig.littleEndian.encoded()
        )

        // 2. BT_CONST.
        let constantBytes = try await transport.controlTransfer(
            .vendorInterfaceIn(
                request: GsUsbBreq.btConst.rawValue,
                value: 0,
                interface: interface.interfaceNumber,
                length: GsDeviceBtConst.byteCount
            ),
            payload: []
        )
        let constants = try GsDeviceBtConst(decoding: constantBytes)
        let features = constants.feature

        // 3. The refusals, before anything is configured. An FD-capable
        // adapter is *not* refused for being FD-capable: it runs classical
        // unless CAN FD was asked for, which is what the device does too when
        // `GS_CAN_MODE_FD` is absent from the flag word.
        if options.canFD {
            if !features.contains(.canFD) {
                throw GsUsbDeviceError.canFDNotSupported(reportedFeatures: features.rawValue)
            }
            if !features.contains(.btConstExt) {
                throw GsUsbDeviceError.dataBitTimingConstantsUnavailable(
                    reportedFeatures: features.rawValue
                )
            }
        }
        if options.listenOnly, !features.contains(.listenOnly) {
            throw GsUsbDeviceError.listenOnlyNotSupported(reportedFeatures: features.rawValue)
        }

        // 4. BT_CONST_EXT, for the data phase's own limits. An IN, so the
        // refusal window above is still open behind it.
        var dataConstants: GsDeviceBtConst?
        if options.canFD {
            let extendedBytes = try await transport.controlTransfer(
                .vendorInterfaceIn(
                    request: GsUsbBreq.btConstExt.rawValue,
                    value: 0,
                    interface: interface.interfaceNumber,
                    length: GsDeviceBtConstExtended.byteCount
                ),
                payload: []
            )
            dataConstants = try GsDeviceBtConstExtended(decoding: extendedBytes).dataPhase
        }

        // 5. Both phases solved before either is sent.
        let timing = try BitTiming.solve(bitrate: options.bitrate, constants: constants)
        var dataTiming: BitTiming?
        if let dataConstants, let dataBitrate = options.frameFormat.dataBitrate {
            dataTiming = try BitTiming.solve(bitrate: dataBitrate, constants: dataConstants)
        }

        // 6. BITTIMING.
        _ = try await transport.controlTransfer(
            .vendorInterfaceOut(
                request: GsUsbBreq.bittiming.rawValue,
                value: 0,
                interface: interface.interfaceNumber,
                length: GsDeviceBittiming.byteCount
            ),
            payload: timing.bittiming.encoded()
        )

        // 7. DATA_BITTIMING. Same 20-byte `gs_device_bittiming` struct as the
        // arbitration phase; only the request code and the limits it was
        // solved against differ.
        if let dataTiming {
            _ = try await transport.controlTransfer(
                .vendorInterfaceOut(
                    request: GsUsbBreq.dataBittiming.rawValue,
                    value: 0,
                    interface: interface.interfaceNumber,
                    length: GsDeviceBittiming.byteCount
                ),
                payload: dataTiming.bittiming.encoded()
            )
        }

        // 8. MODE(START, flags). The flag word is the read-only guarantee: it
        // is what makes the controller silent, and it is re-derived here on
        // every attempt so a reconnect cannot come back bus-active.
        let flags = Self.modeFlags(options: options, features: features)
        _ = try await transport.controlTransfer(
            .vendorInterfaceOut(
                request: GsUsbBreq.mode.rawValue,
                value: 0,
                interface: interface.interfaceNumber,
                length: GsDeviceMode.byteCount
            ),
            payload: GsDeviceMode(mode: .start, flags: flags).encoded()
        )

        // §6.2: the UI has to be able to say which retransmission mode is in
        // force, because it decides whether `send`'s timeout is the only thing
        // standing between an unacknowledged frame and the controller retrying
        // it until bus-off.
        transmitCapability.oneShotActive = flags.contains(.oneShot)

        let mode: GsUsbTimestampMode =
            flags.contains(.hardwareTimestamp) ? .hardware : .hostCompletion
        sourceDescription = Self.describeSource(
            device: device, options: options, timestampMode: mode
        )

        return Configuration(
            interface: interface,
            features: features,
            modeFlags: flags,
            timestampMode: mode,
            // The device appends the timestamp word only when the feature was
            // negotiated, so what we asked for is what decides this half of
            // the layout.
            timestamped: mode == .hardware
        )
    }

    /// The `MODE` flag word.
    ///
    /// `listenOnly` is taken from the options and is *not* conditioned on the
    /// feature word: a device that does not report it has already been refused
    /// in `connectAndConfigure`, so there is no path here that drops the bit
    /// because the device looked unable to honour it. The other three are
    /// requested only when offered, and an unrecognised bit in `features` is
    /// ignored rather than treated as a protocol error — the SH-C30x sets two
    /// bits upstream gs_usb does not define.
    static func modeFlags(options: GsUsbOptions, features: GsCanFeature) -> GsCanFeature {
        var flags: GsCanFeature = []
        if options.listenOnly {
            flags.insert(.listenOnly)
        }
        if options.oneShot, features.contains(.oneShot) {
            flags.insert(.oneShot)
        }
        if options.hardwareTimestamps, features.contains(.hardwareTimestamp) {
            flags.insert(.hardwareTimestamp)
        }
        // `GS_CAN_MODE_FD` shares bit 8 with `GS_CAN_FEATURE_FD`. Taken from
        // the options and not conditioned on the feature word, exactly like
        // `listenOnly`: a device that cannot do it has already been refused,
        // so there is no path here that drops the bit and brings the link up
        // as classical CAN instead.
        if options.canFD {
            flags.insert(.canFD)
        }
        // Requested whenever offered (§7.2): BERR reporting is half of what
        // replaced gap detection, and it costs nothing on a silent controller.
        if features.contains(.berrReporting) {
            flags.insert(.berrReporting)
        }
        return flags
    }

    // MARK: - One connection

    /// Runs the read loop plus the two pollers until the read loop ends, and
    /// returns the reason for the status strip.
    ///
    /// The three children are a task group rather than three stored tasks so
    /// that cancelling the loop cancels them structurally, and so that
    /// `cancelAll()` cannot be forgotten on an early return. Only the read loop
    /// produces a reason; the pollers yield `nil` and the group waits past them.
    private func runConnection(_ configuration: Configuration) async -> String {
        nextSeq = 0
        mapper = nil
        refusal = nil
        pendingDisconnectReason = nil
        lastBusState = .errorActive
        framesAreTimestamped = configuration.timestamped
        timestampMode = configuration.timestampMode
        resetTransmitSlots()
        isConnected = true
        defer {
            isConnected = false
            // A send parked on an echo from an interface that has just closed
            // would otherwise sit out its whole timeout before being told what
            // the status strip already says.
            failPendingTransmits(with: .notConnected)
            transmitCapability.oneShotActive = false
        }

        if configuration.timestampMode.isDegraded {
            noticeContinuation.yield(
                GsUsbNotice(
                    label: "host-completion timestamps: this adapter reports no "
                        + "hardware timestamp counter, so intra-burst ordering is smeared",
                    canTimestampNs: nil,
                    localTimestampNs: clock.nowNs()
                )
            )
        }

        let interface = configuration.interface
        let pollsState = configuration.features.contains(.getState)
        let reanchors = configuration.timestampMode == .hardware

        let reason = await withTaskGroup(of: String?.self, returning: String.self) { group in
            group.addTask { await self.readUntilFailure() }
            if pollsState {
                group.addTask {
                    await self.pollBusState(interface: interface)
                    return nil
                }
            }
            if reanchors {
                group.addTask {
                    await self.reanchorTimestamps(interface: interface)
                    return nil
                }
            }

            var outcome = "stopped"
            for await result in group {
                if let result {
                    outcome = result
                    break
                }
            }
            group.cancelAll()
            return outcome
        }

        // The poller's reason wins: it saw *why*, where the read loop only saw
        // its transfer get aborted by the close the poller performed.
        return pendingDisconnectReason ?? reason
    }

    // MARK: - Read loop and decode

    /// Reads bulk-IN transfers until one fails. Returns the status-strip reason.
    private func readUntilFailure() async -> String {
        while isRunning, !Task.isCancelled {
            let buffer: [UInt8]
            do {
                buffer = try await transport.bulkRead()
            } catch {
                // `stop()` closes the interface to unblock this very read, so an
                // error arriving after the run flag dropped is the teardown
                // rather than a fault to show the user.
                if !isRunning || Task.isCancelled { return "stopped" }
                return Self.describe(error)
            }

            // A zero-length bulk transfer is USB framing, not data.
            if buffer.isEmpty { continue }

            // Frames are self-describing rather than a fixed stride, because
            // on a CAN FD connection they are not all the same size: the
            // firmware sizes each one from its own `GS_CAN_FLAG_FD`, so a
            // 24-byte classical frame and an 80-byte CAN FD frame can sit back
            // to back in one transfer and the only way to find the second is
            // to read the first one's flags.
            var offset = 0
            while offset + GsHostFrame.headerByteCount <= buffer.count {
                let flags = GsHostFrameFlags(
                    rawValue: buffer[offset + GsHostFrame.flagsByteOffset]
                )
                // A classical connection never asked for `GS_CAN_MODE_FD`, so
                // the controller cannot have received a CAN FD frame: the bit
                // set here is one corrupt byte or a firmware fault, not an
                // 80-byte frame. Believing it would consume the real frames
                // behind it in the same transfer as payload — four 24-byte
                // frames become one 80-byte "frame" and sixteen trailing
                // bytes, so three of them vanish without being counted. The
                // flag is refused instead and the fixed classical stride, which
                // is the only stride this connection can produce, carries the
                // walk to the next frame.
                //
                // Dropped rather than masked, which costs a TX echo that lands
                // here its `sendTimeout` before `send` reports
                // `notAcknowledged`. That is the safe direction: a frame with
                // one byte known corrupt has no trustworthy `echo_id` either,
                // and `handleEcho` admits any claimed slot — every claimed slot
                // has a frame genuinely in flight, so a corrupt id that happens
                // to name one would confirm a transmit that may never have
                // reached the bus. A late "don't know" beats a prompt "sent".
                if flags.contains(.canFD), !options.canFD {
                    let classical = GsHostFrame.Layout(
                        canFD: false, timestamped: framesAreTimestamped
                    )
                    guard offset + classical.byteCount <= buffer.count else { break }
                    offset += classical.byteCount
                    statistics.decodeFailures += 1
                    continue
                }
                let layout = GsHostFrame.Layout(
                    canFD: flags.contains(.canFD), timestamped: framesAreTimestamped
                )
                // Short of what its own header says it is. Stopping here rather
                // than hunting for the next plausible header: there is no
                // offset at which a following frame is *known* to start, and
                // the trailing-bytes count below records it.
                guard offset + layout.byteCount <= buffer.count else { break }

                let slice = Array(buffer[offset..<(offset + layout.byteCount)])
                offset += layout.byteCount

                guard let hostFrame = try? GsHostFrame(decoding: slice) else {
                    statistics.decodeFailures += 1
                    continue
                }
                guard hostFrame.channel == 0 else {
                    let error = GsUsbDeviceError.multiChannelDevice(channel: hostFrame.channel)
                    refusal = error
                    return error.description
                }
                // A TX echo is this host's own frame coming back as transmit
                // confirmation (§6.2). It both releases the slot and enters the
                // recording marked `tx` (§6.3), because a session that mixed
                // our injections in unmarked would be a trap.
                guard hostFrame.isReceived else {
                    await handleEcho(hostFrame)
                    continue
                }

                await publish(hostFrame, tx: false)
            }

            // Bytes left over that are not a whole frame mean the negotiated
            // layout and the firmware's disagree. Counting it is the only
            // honest option; the frames already cut out of this buffer were
            // each described by their own header and stand.
            if offset != buffer.count {
                statistics.decodeFailures += 1
            }
        }
        return "stopped"
    }

    /// Resolves a TX echo and records it.
    ///
    /// Two filters stand in front of that, and both are load-bearing for
    /// §6.4's guarantee that a listen-only session contains no frame this host
    /// put on the bus:
    ///
    /// 1. **Listen-only drops it.** A silent controller cannot have
    ///    transmitted, so whatever this frame is, it is not ours; publishing it
    ///    with `tx == true` would file a frame we never sent as one we did.
    /// 2. **An unclaimed slot drops it.** Only slots with a frame genuinely in
    ///    flight can be echoed, so a stray frame cannot resolve a send that is
    ///    still legitimately waiting.
    private func handleEcho(_ hostFrame: GsHostFrame) async {
        guard let slot = hostFrame.transmitSlot else { return }
        guard !options.listenOnly else { return }
        guard claimedSlots.contains(slot) else { return }

        statistics.framesTransmitted += 1
        // Published before the slot is resolved so the frame is in the stream
        // by the time `send` returns. A caller that sends and then reads the
        // recording must not be able to race its own frame.
        await publish(hostFrame, tx: true)
        completeTransmit(slot: slot)
    }

    /// Confirms `slot`, whether or not its `send` has parked yet.
    private func completeTransmit(slot: UInt32) {
        guard echoWaiters[slot] == nil else {
            resolveTransmit(slot: slot, with: .success(()))
            return
        }
        // The echo beat `send` to the waiter registration — `bulkWrite`
        // suspends, and the read loop runs during it. Recorded rather than
        // dropped, so the check `send` performs on the other side of the write
        // finds it instead of parking on an echo that has already been and
        // gone. The slot stays claimed until that check releases it.
        earlyEchoes.insert(slot)
    }

    private func publish(_ hostFrame: GsHostFrame, tx: Bool) async {
        // One mapping path for both §7.1 modes. The fallback feeds the monotonic
        // clock through the same 32-bit microsecond field the device would have
        // used, so the mapper's wrap-unwinding covers the truncation and the
        // host path inherits its monotonicity-across-NTP-steps guarantee for
        // free rather than reimplementing it.
        let microseconds = hostFrame.timestampMicroseconds
            ?? UInt32(truncatingIfNeeded: clock.nowNs() / 1_000)

        // Anchored on the first frame of the connection rather than at connect,
        // so the anchor pairs a host reading with a device reading taken at the
        // same instant instead of one taken a handshake earlier.
        var active = mapper ?? TimestampMapper(
            anchorRealtimeNs: realtimeNowNs(),
            anchorDeviceMicroseconds: microseconds
        )
        let timestampNs = active.timestampNs(forDeviceMicroseconds: microseconds)
        mapper = active

        let frame = GsUsbFrame(
            timestampNs: timestampNs,
            seq: nextSeq,
            canID: hostFrame.canID,
            extended: hostFrame.isExtended,
            rtr: hostFrame.isRemoteRequest,
            // gs_usb delivers CAN error frames as host frames with the error
            // flag set, which lands on the existing field with no model change.
            err: hostFrame.isError,
            fd: hostFrame.isCanFD,
            bitRateSwitch: hostFrame.isBitRateSwitch,
            errorStateIndicator: hostFrame.isErrorStateIndicator,
            data: hostFrame.data,
            tx: tx,
            sourceDescription: sourceDescription
        )
        nextSeq += 1

        statistics.framesReceived += 1
        statistics.lastSeq = frame.seq
        statistics.lastFrameLocalNs = clock.nowNs()
        statistics.lastFrameCanTsNs = frame.timestampNs

        if hostFrame.isOverflow {
            // The adapter's own report that its receive FIFO overran. Since
            // `seq` is generated here, this flag is the *only* upward signal
            // that frames were lost — §7.2's replacement for gap detection.
            statistics.readStarvationEvents += 1
            noticeContinuation.yield(
                GsUsbNotice(
                    label: "adapter reported a receive overflow: frames were lost "
                        + "before the host saw them",
                    canTimestampNs: frame.timestampNs,
                    localTimestampNs: statistics.lastFrameLocalNs
                )
            )
        }

        // Awaited, not fired off in a detached `Task`, because consumers must
        // see frames in arrival order and separate tasks awaiting the same
        // actor are *not* serviced in creation order — they race to enqueue on
        // it. A consumer is expected to enqueue and return, so this costs one
        // hop and never blocks on how fast the host drains.
        await consumer.consume(frame)
    }

    // MARK: - Bus state polling

    /// Polls `BREQ_GET_STATE` and raises a notice on each transition into a
    /// degraded controller state. Returns once bus-off has been handled, or on
    /// cancellation.
    private func pollBusState(interface: UsbInterfaceInfo) async {
        while !Task.isCancelled {
            do {
                try await clock.sleep(for: statePollInterval)
            } catch {
                return
            }
            guard isRunning, !Task.isCancelled else { return }

            let bytes: [UInt8]
            do {
                bytes = try await transport.controlTransfer(
                    .vendorInterfaceIn(
                        request: GsUsbBreq.getState.rawValue,
                        value: 0,
                        interface: interface.interfaceNumber,
                        length: GsDeviceState.byteCount
                    ),
                    payload: []
                )
            } catch {
                // A failed poll is a diagnostic gap, not a reason to drop a
                // connection the read loop is still happily using. If the
                // device really is gone, the read loop's own failure says so.
                continue
            }
            guard let state = try? GsDeviceState(decoding: bytes) else { continue }
            if await observe(state) { return }
        }
    }

    /// Returns true when the connection is over.
    private func observe(_ state: GsDeviceState) async -> Bool {
        guard state.state != lastBusState else { return false }
        lastBusState = state.state
        guard state.state.isDegraded else { return false }

        noticeContinuation.yield(
            GsUsbNotice(
                label: "controller entered \(state.state) "
                    + "(rx errors \(state.receiveErrorCount), "
                    + "tx errors \(state.transmitErrorCount))",
                canTimestampNs: statistics.lastFrameCanTsNs == 0
                    ? nil
                    : statistics.lastFrameCanTsNs,
                localTimestampNs: clock.nowNs()
            )
        )

        guard state.state == .busOff else { return false }

        // Bus-off is terminal for the controller: it will not receive another
        // frame until it is reconfigured, and the reconnect ladder's
        // `MODE(START)` is what reconfigures it. Recorded before closing so the
        // read loop's aborted-transfer reason cannot win the race to report.
        pendingDisconnectReason = "controller went bus-off"
        // Closing is what unblocks the read loop, which is otherwise parked on
        // an endpoint that can no longer deliver anything.
        await transport.close()
        return true
    }

    // MARK: - Timestamp re-anchoring

    /// Re-reads `BREQ_TIMESTAMP` periodically so `TimestampMapper` tracks the
    /// adapter's crystal drift (§7.1). Hardware mode only — there is nothing to
    /// drift against when the counter is the host's own clock.
    private func reanchorTimestamps(interface: UsbInterfaceInfo) async {
        while !Task.isCancelled {
            do {
                try await clock.sleep(for: reanchorInterval)
            } catch {
                return
            }
            guard isRunning, !Task.isCancelled else { return }

            let bytes: [UInt8]
            do {
                bytes = try await transport.controlTransfer(
                    .vendorInterfaceIn(
                        request: GsUsbBreq.timestamp.rawValue,
                        value: 0,
                        interface: interface.interfaceNumber,
                        length: 4
                    ),
                    payload: []
                )
            } catch {
                // Same reasoning as the state poller: a diagnostic refresh must
                // not be able to drop a working connection.
                continue
            }
            guard bytes.count >= 4 else { continue }

            let deviceMicroseconds = UInt32(bytes[0])
                | UInt32(bytes[1]) << 8
                | UInt32(bytes[2]) << 16
                | UInt32(bytes[3]) << 24
            // Re-read `mapper` *after* the transfer: the read loop may have
            // published frames while it was in flight, and writing back a copy
            // taken before it would discard their progress.
            guard var active = mapper else { continue }
            active.reanchor(realtimeNs: realtimeNowNs(), deviceMicroseconds: deviceMicroseconds)
            mapper = active
        }
    }

    // MARK: - Description

    /// §8.4's free-text source description. `device` and `timestampMode` are
    /// `nil` before a connection has been configured, which is the form the
    /// status strip shows while connecting.
    ///
    /// A CAN FD connection shows both rates and the `fd` marker — `"gs_usb
    /// CANable2 #0001 500k/2M fd bus-active hw-ts"`. The data rate is part of
    /// the label rather than an aside because two captures taken at the same
    /// arbitration rate and different data rates are not the same capture.
    static func describeSource(
        device: UsbDeviceRef?,
        options: GsUsbOptions,
        timestampMode: GsUsbTimestampMode?
    ) -> String {
        var parts = ["gs_usb"]
        if let device {
            parts.append(device.productName ?? device.identity)
            if let serial = device.serialNumber, !serial.isEmpty {
                parts.append("#\(serial)")
            }
        }
        if let dataBitrate = options.frameFormat.dataBitrate {
            parts.append("\(bitrateLabel(options.bitrate))/\(bitrateLabel(dataBitrate))")
            parts.append("fd")
        } else {
            parts.append(bitrateLabel(options.bitrate))
        }
        parts.append(options.listenOnly ? "listen-only" : "bus-active")
        if let timestampMode {
            parts.append(timestampMode.shortLabel)
        }
        return parts.joined(separator: " ")
    }

    /// `500000` → `"500k"`, `1000000` → `"1M"`. Exact divisions only, so an
    /// unusual rate is shown at full precision rather than rounded into a lie.
    static func bitrateLabel(_ bitrate: UInt32) -> String {
        if bitrate >= 1_000_000, bitrate % 1_000_000 == 0 {
            return "\(bitrate / 1_000_000)M"
        }
        if bitrate >= 1_000, bitrate % 1_000 == 0 {
            return "\(bitrate / 1_000)k"
        }
        return String(format: "%.3fk", Double(bitrate) / 1_000)
    }

    // MARK: - Error reporting

    /// True when retrying would only reproduce the same answer.
    private static func isUnretryable(_ error: Error) -> Bool {
        switch error {
        case let error as GsUsbDeviceError:
            return error.isFatal
        case is BitTimingError:
            // The requested bitrate is not reachable on this adapter's reported
            // limits. Those limits are firmware constants (§5.2), so the ladder
            // would ask the same impossible question forever.
            return true
        default:
            return false
        }
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case UsbTransportError.notOpen:
            return "the interface is not open"
        case UsbTransportError.deviceNotFound:
            return "the adapter is no longer present"
        case UsbTransportError.openFailed(let message):
            return message
        case UsbTransportError.pipeNotFound(let message):
            return message
        case UsbTransportError.stalled(let message):
            return "endpoint stalled: \(message)"
        case UsbTransportError.timedOut:
            return "the adapter stopped responding"
        case UsbTransportError.deviceRemoved:
            return "the adapter was unplugged"
        case UsbTransportError.transferFailed(let message):
            return message
        case UsbTransportError.shortTransfer(let expected, let actual):
            return "the adapter returned \(actual) bytes where \(expected) were asked for"
        case let error as GsUsbDeviceError:
            return error.description
        case let error as BitTimingError:
            return error.description
        case GsUsbProtocolError.truncated(let expected, let actual):
            return "the adapter returned \(actual) bytes where \(expected) were needed"
        case GsUsbProtocolError.unknownMode(let raw):
            return "the adapter reported an unknown mode (\(raw))"
        case GsUsbProtocolError.unknownState(let raw):
            return "the adapter reported an unknown controller state (\(raw))"
        case GsUsbProtocolError.unsupportedFrameLength(let count):
            return "the adapter delivered a \(count)-byte frame"
        case GsUsbProtocolError.invalidDataLength(let dlc):
            return "the adapter delivered a frame with DLC \(dlc)"
        case GsUsbProtocolError.frameFormatDisagreesWithLength(let flags, let count):
            return String(
                format: "the adapter delivered a %d-byte frame whose flags "
                    + "(0x%02x) describe a different size",
                count, flags
            )
        case GsUsbProtocolError.unrepresentableDataLength(let count):
            return "CAN FD carries 0–8, 12, 16, 20, 24, 32, 48 or 64 bytes; "
                + "this frame has \(count)"
        case GsUsbProtocolError.contradictoryFrameFlags(let message):
            return message
        case is CancellationError:
            // `stop()` cancels the loop, which surfaces here from whatever was
            // being awaited. Not a fault — don't show it as one.
            return "stopped"
        default:
            return error.localizedDescription
        }
    }
}
