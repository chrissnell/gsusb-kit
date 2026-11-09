import Foundation

// The seam between the gs_usb driver and the USB stack.
//
// This file is I/O-free for the same reason `GsUsbProtocol.swift` is: everything
// above it — the configure handshake, the read loop, decode, TX slots, reconnect
// — is driven through this protocol by `ScriptedUsbTransport` in tests and needs
// no adapter attached. Below it sits exactly one file, `IOUSBHostTransport`,
// which CI compiles and never runs.
//
// The line is drawn deliberately low. `IOUSBHostTransport` is allowed to know
// about registry iteration, endpoint descriptors, pipes and in-flight request
// pools. It is not allowed to know what a CAN frame is, what the gs_usb
// handshake looks like, or that `1d50:606f` means anything beyond "the identity
// I was constructed with" — because every line of logic on that side of the
// seam is a line only a human with hardware can verify.

// MARK: - Errors

/// The failures a caller actually branches on.
///
/// Deliberately not a wrapper around `IOReturn`. `GsUsbDevice` reconnects on
/// `deviceRemoved`, refuses on `openFailed`, counts `timedOut` and clears a
/// `stalled` pipe — four behaviours, so four cases. Carrying the raw code up
/// would push an IOKit translation table into the testable side, which is the
/// wrong place for it; `IOUSBHostTransport` translates instead.
public enum UsbTransportError: Error, Equatable, Sendable {
    /// A transfer was attempted before `open`, or after `close`.
    case notOpen
    /// `open` was given a `UsbDeviceRef` that is no longer in the registry —
    /// ordinary after an unplug, not exceptional.
    case deviceNotFound
    /// The interface would not open. This is the design §3.1 answer, so the
    /// underlying message is carried verbatim rather than flattened to a flag.
    case openFailed(String)
    /// The interface opened but has no bulk IN or bulk OUT endpoint, which
    /// means it is not the device we think it is.
    case pipeNotFound(String)
    /// The endpoint halted. Recoverable by clearing the stall; distinct from a
    /// transfer that merely failed.
    case stalled(String)
    case timedOut
    /// Surprise removal, or a transfer aborted because the host closed.
    case deviceRemoved
    case transferFailed(String)
    /// A control-IN returned fewer bytes than asked for. Its own case because
    /// it is the signature of firmware older than the struct being read, which
    /// a caller reports differently from a cable falling out.
    case shortTransfer(expected: Int, actual: Int)
}

// MARK: - Device identity

/// One device as found by `enumerate`, and the handle `open` takes.
///
/// `locationID` is the identity that matters: it encodes the physical port path,
/// it is stable for as long as the device stays plugged into that port, and it
/// is the only thing that tells two identical adapters apart. Vendor and product
/// IDs are carried for display and for the caller's own sanity checks.
public struct UsbDeviceRef: Sendable, Equatable, Hashable {
    public let vendorID: UInt16
    public let productID: UInt16
    public let locationID: UInt32
    public let productName: String?
    public let serialNumber: String?

    public init(
        vendorID: UInt16,
        productID: UInt16,
        locationID: UInt32,
        productName: String? = nil,
        serialNumber: String? = nil
    ) {
        self.vendorID = vendorID
        self.productID = productID
        self.locationID = locationID
        self.productName = productName
        self.serialNumber = serialNumber
    }

    /// `1d50:606f`, as printed everywhere USB identities are printed.
    public var identity: String {
        String(format: "%04x:%04x", vendorID, productID)
    }
}

// MARK: - Interface facts discovered at open

/// What the caller learns by opening, and could not have known before.
///
/// Returned from `open` rather than exposed as protocol properties, which keeps
/// design §9's six-member seam intact: a `var interfaceNumber` would have to
/// mean something before `open` was called, and it does not.
public struct UsbInterfaceInfo: Sendable, Equatable {
    /// `bInterfaceNumber`. Every gs_usb control transfer is `USB_RECIP_INTERFACE`
    /// and carries this in `wIndex`. The Linux driver reads it from the
    /// descriptor rather than assuming zero, and so does this.
    public let interfaceNumber: UInt8
    public let bulkInMaxPacketSize: Int
    /// What `GS_CAN_FEATURE_PAD_PKTS_TO_MAX_PKT_SIZE` is defined in terms of,
    /// should a later phase negotiate it.
    public let bulkOutMaxPacketSize: Int

    public init(interfaceNumber: UInt8, bulkInMaxPacketSize: Int, bulkOutMaxPacketSize: Int) {
        self.interfaceNumber = interfaceNumber
        self.bulkInMaxPacketSize = bulkInMaxPacketSize
        self.bulkOutMaxPacketSize = bulkOutMaxPacketSize
    }
}

// MARK: - Control requests

/// A USB control transfer on the default endpoint, in setup-packet terms.
///
/// Generic USB, not gs_usb: nothing here knows what a `GsUsbBreq` is. The two
/// static factories exist because every gs_usb transfer is a vendor request
/// addressed to the interface, and spelling three enum cases out at every call
/// site would be noise rather than clarity.
public struct UsbControlRequest: Sendable, Equatable {
    public enum Direction: UInt8, Sendable {
        case hostToDevice = 0x00
        case deviceToHost = 0x80
    }

    public enum RequestType: UInt8, Sendable {
        case standard = 0x00
        case `class` = 0x20
        case vendor = 0x40
    }

    public enum Recipient: UInt8, Sendable {
        case device = 0x00
        case interface = 0x01
        case endpoint = 0x02
        case other = 0x03
    }

    public let direction: Direction
    public let type: RequestType
    public let recipient: Recipient
    /// `bRequest`.
    public let request: UInt8
    /// `wValue`. gs_usb puts the channel index here, except on `HOST_FORMAT`
    /// and `DEVICE_CONFIG` where the Linux driver sends 1.
    public let value: UInt16
    /// `wIndex`. gs_usb puts `bInterfaceNumber` here.
    public let index: UInt16
    /// `wLength` — bytes to read on an IN, bytes to write on an OUT.
    public let length: UInt16

    public init(
        direction: Direction,
        type: RequestType,
        recipient: Recipient,
        request: UInt8,
        value: UInt16,
        index: UInt16,
        length: UInt16
    ) {
        self.direction = direction
        self.type = type
        self.recipient = recipient
        self.request = request
        self.value = value
        self.index = index
        self.length = length
    }

    /// `bmRequestType`, assembled.
    public var bmRequestType: UInt8 {
        direction.rawValue | type.rawValue | recipient.rawValue
    }

    public static func vendorInterfaceIn(
        request: UInt8,
        value: UInt16,
        interface: UInt8,
        length: Int
    ) -> UsbControlRequest {
        UsbControlRequest(
            direction: .deviceToHost,
            type: .vendor,
            recipient: .interface,
            request: request,
            value: value,
            index: UInt16(interface),
            length: UInt16(length)
        )
    }

    public static func vendorInterfaceOut(
        request: UInt8,
        value: UInt16,
        interface: UInt8,
        length: Int
    ) -> UsbControlRequest {
        UsbControlRequest(
            direction: .hostToDevice,
            type: .vendor,
            recipient: .interface,
            request: request,
            value: value,
            index: UInt16(interface),
            length: UInt16(length)
        )
    }
}

// MARK: - The seam

/// Bulk and control access to one USB device.
///
/// Mirrors `ByteStream` in `CanCore/Sources/Transport/ByteStream.swift` — a
/// narrow protocol whose real implementation touches hardware and whose scripted
/// double carries every test. Two of that file's hard-won properties are part of
/// this contract rather than implementation detail, because both are invisible
/// until they are violated:
///
/// **Cancellation.** An enqueued USB transfer knows nothing about Swift task
/// cancellation. A cancelled task awaiting `bulkRead` would otherwise sit on its
/// continuation until the device sent a frame — which, on an idle bus, is never.
/// Implementations park inside `withTaskCancellationHandler` and abort the
/// underlying transfer from the handler. This is the same reasoning that puts
/// `NWByteStream.connect()` inside one.
///
/// **`close` unblocks a parked `bulkRead`, and that is its job rather than a
/// side effect.** `NWByteStream.close()` leaves its `stateUpdateHandler`
/// installed precisely so the cancellation it triggers can resume a caller
/// parked on a continuation; clearing it first orphans that caller forever. The
/// USB analogue is ordering: abort the pipes *before* dropping the interface,
/// because the abort is what delivers a completion to every outstanding request,
/// and those completions are the only thing that can resume a parked reader.
public protocol UsbDeviceTransport: Sendable {
    /// Devices currently present that match the identities this transport was
    /// constructed for. An empty array is a normal answer, not an error.
    func enumerate() async throws -> [UsbDeviceRef]

    /// Claim the device's vendor-specific interface and make its bulk endpoints
    /// usable. Returns the facts that only exist once it is open.
    func open(_ device: UsbDeviceRef) async throws -> UsbInterfaceInfo

    /// A control transfer on the default endpoint. `payload` is the OUT data
    /// phase and must be empty for an IN; the return is the IN data phase and is
    /// empty for an OUT.
    func controlTransfer(_ request: UsbControlRequest, payload: [UInt8]) async throws -> [UInt8]

    /// The next completed bulk-IN transfer, awaiting one if none has landed.
    ///
    /// Takes no length, unlike `ByteStream.read(maxBytes:)`, and the difference
    /// is load-bearing. A TCP stream is a byte river and the caller decides how
    /// much to scoop; a bulk-IN endpoint delivers discrete transfers, and design
    /// §5.3 requires a *fixed pool* of N ≥ 8 pre-allocated buffers permanently in
    /// flight. Buffer size is therefore a property of that pool, fixed when the
    /// transport is constructed. A `maxBytes` parameter would be a lie, since no
    /// pooled implementation could honour a value that differed from the pool's.
    func bulkRead() async throws -> [UInt8]

    /// One bulk-OUT transfer. Returns once the device has taken all the bytes.
    func bulkWrite(_ bytes: [UInt8]) async throws

    /// Release the interface and unblock every parked reader. Not throwing,
    /// like `ByteStream.close()`: there is nothing a caller can do about a
    /// failed close, and making it throw puts a `try?` at every teardown site.
    func close() async
}
