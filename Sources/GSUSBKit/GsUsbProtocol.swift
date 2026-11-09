import Foundation

// Wire-level value types and byte codecs for the gs_usb protocol as spoken by
// candleLight firmware. Transcribed from `candleLight_fw/include/gs_usb.h`.
//
// This file is deliberately I/O-free: no `IOUSBHost`, no `IOKit`, no sockets,
// no concurrency. That is what lets CI exercise every byte layout here on a
// runner with no USB stack and no adapter attached. Hardware access lives
// behind the `UsbDeviceTransport` seam instead.
//
// Every multi-byte field on the wire is little-endian, because the host sets
// `gs_host_config.byteOrder` to `0x0000beef` at connect and candleLight runs
// on a little-endian STM32. The codecs below encode that explicitly rather
// than relying on the host's native order.

// MARK: - Errors

public enum GsUsbProtocolError: Error, Equatable, Sendable {
    /// The device returned fewer bytes than the struct needs. Thrown before
    /// any indexing happens, so a short control-transfer reply can never be
    /// read past its end.
    case truncated(expected: Int, actual: Int)
    /// `gs_device_mode.mode` carried a value outside `enum gs_can_mode`.
    case unknownMode(UInt32)
    /// `gs_device_state.state` carried a value outside `enum gs_can_state`.
    case unknownState(UInt32)
    /// A bulk-IN buffer whose length matches none of `GsHostFrame.Layout`'s
    /// four sizes — 20 and 24 classical, 76 and 80 for CAN FD.
    case unsupportedFrameLength(Int)
    /// `can_dlc` outside what the frame's own `GS_CAN_FLAG_FD` bit permits:
    /// above 8 on a classical frame, above 15 on a CAN FD one. Rejected rather
    /// than clamped silently, because a DLC that cannot be honoured means the
    /// layout assumption is wrong and the payload would be invented.
    case invalidDataLength(UInt8)
    /// `GS_CAN_FLAG_FD` and the buffer length disagree: the flag set on a
    /// buffer only wide enough for the classical 8-byte data field, or clear on
    /// one wide enough for CAN FD's 64.
    ///
    /// The two always agree on the wire — candleLight sizes each transfer from
    /// that very flag — so a disagreement means the bytes are not the frame
    /// they claim to be, and there is no payload that can be read out of them.
    case frameFormatDisagreesWithLength(flags: UInt8, byteCount: Int)
    /// A transmit payload whose length no CAN FD DLC can express. CAN FD's
    /// lengths are 0–8, 12, 16, 20, 24, 32, 48 and 64; a 9-byte frame does not
    /// exist on the wire, and the only way to send those nine bytes is as a
    /// 12-byte frame whose last three the caller chose.
    case unrepresentableDataLength(Int)
    /// Transmit flags that contradict each other, with the rule they broke.
    case contradictoryFrameFlags(String)
}

// MARK: - Little-endian cursor

/// Sequential little-endian reader over a validated buffer.
///
/// The length check happens once in `init`, which is what lets the accessors
/// index without bounds-checking arithmetic repeated at every field.
private struct LittleEndianCursor {
    private let bytes: [UInt8]
    private var offset = 0

    init(_ source: some Sequence<UInt8>, requiring required: Int) throws {
        let array = Array(source)
        guard array.count >= required else {
            throw GsUsbProtocolError.truncated(expected: required, actual: array.count)
        }
        bytes = array
    }

    mutating func readUInt8() -> UInt8 {
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func readUInt32() -> UInt32 {
        let value = UInt32(bytes[offset])
            | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16
            | UInt32(bytes[offset + 3]) << 24
        offset += 4
        return value
    }

    mutating func readBytes(_ count: Int) -> [UInt8] {
        defer { offset += count }
        return Array(bytes[offset..<(offset + count)])
    }
}

private extension Array where Element == UInt8 {
    mutating func appendLittleEndian(_ value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
    }
}

// MARK: - Control requests

/// `bRequest` values for the vendor control transfers. Values are positional
/// in `enum gs_usb_breq`, so they are pinned by test.
public enum GsUsbBreq: UInt8, Sendable, CaseIterable {
    case hostFormat = 0
    case bittiming = 1
    case mode = 2
    case berr = 3
    case btConst = 4
    case deviceConfig = 5
    case timestamp = 6
    case identify = 7
    case getUserID = 8
    case setUserID = 9
    case dataBittiming = 10
    case btConstExt = 11
    case setTermination = 12
    case getTermination = 13
    case getState = 14
}

// MARK: - Feature bits

/// `GS_CAN_FEATURE_*`, as reported in `gs_device_bt_const.feature` and
/// requested back in `gs_device_mode.flags`. The two share one bit numbering,
/// which is why a single option set covers both directions.
public struct GsCanFeature: OptionSet, Sendable, Hashable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public static let listenOnly = GsCanFeature(rawValue: 1 << 0)
    public static let loopBack = GsCanFeature(rawValue: 1 << 1)
    public static let tripleSample = GsCanFeature(rawValue: 1 << 2)
    public static let oneShot = GsCanFeature(rawValue: 1 << 3)
    public static let hardwareTimestamp = GsCanFeature(rawValue: 1 << 4)
    public static let identify = GsCanFeature(rawValue: 1 << 5)
    public static let userID = GsCanFeature(rawValue: 1 << 6)
    public static let padPacketsToMaxPacketSize = GsCanFeature(rawValue: 1 << 7)
    public static let canFD = GsCanFeature(rawValue: 1 << 8)
    public static let requiresUsbQuirkLpc546xx = GsCanFeature(rawValue: 1 << 9)
    public static let btConstExt = GsCanFeature(rawValue: 1 << 10)
    public static let termination = GsCanFeature(rawValue: 1 << 11)
    public static let berrReporting = GsCanFeature(rawValue: 1 << 12)
    public static let getState = GsCanFeature(rawValue: 1 << 13)
}

// MARK: - Mode and state

/// `gs_device_mode.mode`: start or stop the channel.
public enum GsCanMode: UInt32, Sendable {
    case reset = 0
    case start = 1
}

/// Controller error state, read through `BREQ_GET_STATE` when the device
/// reports `GS_CAN_FEATURE_GET_STATE`.
public enum GsCanState: UInt32, Sendable, CaseIterable, CustomStringConvertible {
    case errorActive = 0
    case errorWarning = 1
    case errorPassive = 2
    case busOff = 3
    case stopped = 4
    case sleeping = 5

    /// True for the three states worth a marker in the recording. `stopped`
    /// and `sleeping` are excluded because they are the result of the host
    /// asking, not of the bus misbehaving.
    public var isDegraded: Bool {
        switch self {
        case .errorWarning, .errorPassive, .busOff:
            return true
        case .errorActive, .stopped, .sleeping:
            return false
        }
    }

    /// The name used in markers and in the status strip. Hyphenated to match
    /// how the CAN literature and `ip -details link show` spell these.
    public var description: String {
        switch self {
        case .errorActive: return "error-active"
        case .errorWarning: return "error-warning"
        case .errorPassive: return "error-passive"
        case .busOff: return "bus-off"
        case .stopped: return "stopped"
        case .sleeping: return "sleeping"
        }
    }
}

// MARK: - gs_host_config

/// `BREQ_HOST_FORMAT` payload. The magic tells the device which byte order the
/// host will use for every later transfer; `0x0000beef` selects little-endian.
public struct GsHostConfig: Sendable, Equatable {
    public static let byteCount = 4

    public let byteOrder: UInt32

    public static let littleEndian = GsHostConfig(byteOrder: 0x0000_BEEF)

    public init(byteOrder: UInt32) {
        self.byteOrder = byteOrder
    }

    public func encoded() -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(Self.byteCount)
        out.appendLittleEndian(byteOrder)
        return out
    }
}

// MARK: - gs_device_config

/// `BREQ_DEVICE_CONFIG` reply: three reserved bytes, the interface count, then
/// the firmware and hardware versions.
///
/// §7.4 reads `softwareVersion` because DSD TECH ship whatever candleLight
/// build was current at manufacture, and hardware timestamping is a later
/// addition — the version is evidence, not decoration.
public struct GsDeviceConfig: Sendable, Equatable {
    public static let byteCount = 12

    /// `icount` verbatim. Prefer `channelCount`.
    public let interfaceCountMinusOne: UInt8
    public let softwareVersion: UInt32
    public let hardwareVersion: UInt32

    /// Kept so `encoded()` is lossless for any buffer that decoded.
    private let reserved: [UInt8]

    /// `icount` counts interfaces *minus one*, so a single-channel adapter
    /// reports 0. Resolving that here keeps the off-by-one in one place.
    public var channelCount: Int { Int(interfaceCountMinusOne) + 1 }

    public init(interfaceCountMinusOne: UInt8, softwareVersion: UInt32, hardwareVersion: UInt32) {
        self.interfaceCountMinusOne = interfaceCountMinusOne
        self.softwareVersion = softwareVersion
        self.hardwareVersion = hardwareVersion
        reserved = [0, 0, 0]
    }

    public init(decoding source: some Sequence<UInt8>) throws {
        var cursor = try LittleEndianCursor(source, requiring: Self.byteCount)
        reserved = cursor.readBytes(3)
        interfaceCountMinusOne = cursor.readUInt8()
        softwareVersion = cursor.readUInt32()
        hardwareVersion = cursor.readUInt32()
    }

    public func encoded() -> [UInt8] {
        var out = reserved
        out.reserveCapacity(Self.byteCount)
        out.append(interfaceCountMinusOne)
        out.appendLittleEndian(softwareVersion)
        out.appendLittleEndian(hardwareVersion)
        return out
    }
}

// MARK: - gs_device_mode

/// `BREQ_MODE` payload: start or stop the channel, with the feature bits the
/// host wants enabled while it runs.
public struct GsDeviceMode: Sendable, Equatable {
    public static let byteCount = 8

    public let mode: GsCanMode
    public let flags: GsCanFeature

    public init(mode: GsCanMode, flags: GsCanFeature) {
        self.mode = mode
        self.flags = flags
    }

    public init(decoding source: some Sequence<UInt8>) throws {
        var cursor = try LittleEndianCursor(source, requiring: Self.byteCount)
        let rawMode = cursor.readUInt32()
        guard let mode = GsCanMode(rawValue: rawMode) else {
            throw GsUsbProtocolError.unknownMode(rawMode)
        }
        self.mode = mode
        flags = GsCanFeature(rawValue: cursor.readUInt32())
    }

    public func encoded() -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(Self.byteCount)
        out.appendLittleEndian(mode.rawValue)
        out.appendLittleEndian(flags.rawValue)
        return out
    }
}

// MARK: - gs_device_bittiming

/// `BREQ_BITTIMING` payload — bxCAN segment counts in time quanta, plus the
/// prescaler. Phase 3's `BitTiming` is what computes these from a bitrate.
public struct GsDeviceBittiming: Sendable, Equatable {
    public static let byteCount = 20

    public let propSeg: UInt32
    public let phaseSeg1: UInt32
    public let phaseSeg2: UInt32
    public let sjw: UInt32
    public let brp: UInt32

    public init(propSeg: UInt32, phaseSeg1: UInt32, phaseSeg2: UInt32, sjw: UInt32, brp: UInt32) {
        self.propSeg = propSeg
        self.phaseSeg1 = phaseSeg1
        self.phaseSeg2 = phaseSeg2
        self.sjw = sjw
        self.brp = brp
    }

    public init(decoding source: some Sequence<UInt8>) throws {
        var cursor = try LittleEndianCursor(source, requiring: Self.byteCount)
        propSeg = cursor.readUInt32()
        phaseSeg1 = cursor.readUInt32()
        phaseSeg2 = cursor.readUInt32()
        sjw = cursor.readUInt32()
        brp = cursor.readUInt32()
    }

    public func encoded() -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(Self.byteCount)
        for word in [propSeg, phaseSeg1, phaseSeg2, sjw, brp] {
            out.appendLittleEndian(word)
        }
        return out
    }
}

// MARK: - gs_device_bt_const

/// `BREQ_BT_CONST` reply: the feature bits plus the controller's clock and
/// segment limits. Everything phase 3 needs to solve a bitrate, and the one
/// place §7.1's hardware-timestamp decision is actually made.
public struct GsDeviceBtConst: Sendable, Equatable {
    public static let byteCount = 40

    public let feature: GsCanFeature
    public let canClockHz: UInt32
    public let tseg1Min: UInt32
    public let tseg1Max: UInt32
    public let tseg2Min: UInt32
    public let tseg2Max: UInt32
    public let sjwMax: UInt32
    public let brpMin: UInt32
    public let brpMax: UInt32
    public let brpInc: UInt32

    public init(
        feature: GsCanFeature,
        canClockHz: UInt32,
        tseg1Min: UInt32,
        tseg1Max: UInt32,
        tseg2Min: UInt32,
        tseg2Max: UInt32,
        sjwMax: UInt32,
        brpMin: UInt32,
        brpMax: UInt32,
        brpInc: UInt32
    ) {
        self.feature = feature
        self.canClockHz = canClockHz
        self.tseg1Min = tseg1Min
        self.tseg1Max = tseg1Max
        self.tseg2Min = tseg2Min
        self.tseg2Max = tseg2Max
        self.sjwMax = sjwMax
        self.brpMin = brpMin
        self.brpMax = brpMax
        self.brpInc = brpInc
    }

    public init(decoding source: some Sequence<UInt8>) throws {
        var cursor = try LittleEndianCursor(source, requiring: Self.byteCount)
        // The feature word is kept whole rather than masked to known bits, so
        // a newer firmware's capabilities survive a round trip.
        feature = GsCanFeature(rawValue: cursor.readUInt32())
        canClockHz = cursor.readUInt32()
        tseg1Min = cursor.readUInt32()
        tseg1Max = cursor.readUInt32()
        tseg2Min = cursor.readUInt32()
        tseg2Max = cursor.readUInt32()
        sjwMax = cursor.readUInt32()
        brpMin = cursor.readUInt32()
        brpMax = cursor.readUInt32()
        brpInc = cursor.readUInt32()
    }

    public func encoded() -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(Self.byteCount)
        let words = [
            feature.rawValue, canClockHz,
            tseg1Min, tseg1Max, tseg2Min, tseg2Max,
            sjwMax, brpMin, brpMax, brpInc,
        ]
        for word in words {
            out.appendLittleEndian(word)
        }
        return out
    }
}

// MARK: - gs_device_bt_const_extended

/// `BREQ_BT_CONST_EXT` reply: `gs_device_bt_const` with a second
/// `can_bittiming_const` appended for the CAN FD data phase.
///
/// Read only when the device reports both `GS_CAN_FEATURE_FD` and
/// `GS_CAN_FEATURE_BT_CONST_EXT`, which is also what the Linux driver gates it
/// on. A CAN FD device that does not offer it cannot have its data phase
/// solved at all: the two phases run on the same `fclk_can` but have their own
/// segment and prescaler limits, and the arbitration limits are not a usable
/// substitute — an FDCAN peripheral's data-phase tseg1 range is a different
/// shape from its nominal one.
public struct GsDeviceBtConstExtended: Sendable, Equatable {
    public static let byteCount = 72

    /// The arbitration-phase constants, in the exact shape `BREQ_BT_CONST`
    /// returns them. The first 40 bytes of this reply *are* a
    /// `gs_device_bt_const`, so `BitTiming.solve` takes this unchanged.
    public let arbitration: GsDeviceBtConst
    /// The data-phase constants, carrying the same `feature` word and
    /// `fclk_can` as `arbitration` so this too can be handed straight to
    /// `BitTiming.solve`. Only the eight segment and prescaler limits differ.
    public let dataPhase: GsDeviceBtConst

    public var feature: GsCanFeature { arbitration.feature }
    public var canClockHz: UInt32 { arbitration.canClockHz }

    public init(arbitration: GsDeviceBtConst, dataPhase: GsDeviceBtConst) {
        self.arbitration = arbitration
        self.dataPhase = dataPhase
    }

    public init(decoding source: some Sequence<UInt8>) throws {
        let bytes = Array(source)
        guard bytes.count >= Self.byteCount else {
            throw GsUsbProtocolError.truncated(expected: Self.byteCount, actual: bytes.count)
        }
        arbitration = try GsDeviceBtConst(decoding: bytes.prefix(GsDeviceBtConst.byteCount))

        var cursor = try LittleEndianCursor(
            bytes[GsDeviceBtConst.byteCount..<Self.byteCount], requiring: 32
        )
        dataPhase = GsDeviceBtConst(
            feature: arbitration.feature,
            canClockHz: arbitration.canClockHz,
            tseg1Min: cursor.readUInt32(),
            tseg1Max: cursor.readUInt32(),
            tseg2Min: cursor.readUInt32(),
            tseg2Max: cursor.readUInt32(),
            sjwMax: cursor.readUInt32(),
            brpMin: cursor.readUInt32(),
            brpMax: cursor.readUInt32(),
            brpInc: cursor.readUInt32()
        )
    }

    /// The `feature` and `fclk_can` words come from `arbitration`; `dataPhase`'s
    /// copies of them are not on the wire and are not written back.
    public func encoded() -> [UInt8] {
        var out = arbitration.encoded()
        out.reserveCapacity(Self.byteCount)
        let words = [
            dataPhase.tseg1Min, dataPhase.tseg1Max,
            dataPhase.tseg2Min, dataPhase.tseg2Max,
            dataPhase.sjwMax,
            dataPhase.brpMin, dataPhase.brpMax, dataPhase.brpInc,
        ]
        for word in words {
            out.appendLittleEndian(word)
        }
        return out
    }
}

// MARK: - gs_device_state

/// `BREQ_GET_STATE` reply: the controller's error state and its two error
/// counters.
///
/// This is §7.2's replacement for sequence-gap detection. `GsUsbDevice`
/// generates `Frame.seq` itself, so a hole in it is impossible by construction
/// and the completeness guarantee has to come from the controller instead —
/// polling this is how a bus that has started rejecting frames becomes visible
/// rather than inferred.
public struct GsDeviceState: Sendable, Equatable {
    public static let byteCount = 12

    public let state: GsCanState
    /// `rxerr` — the receive error counter. Carried because the *number* is
    /// what distinguishes a bus degrading from one that has already failed;
    /// the state alone only says which side of 96 it is on.
    public let receiveErrorCount: UInt32
    public let transmitErrorCount: UInt32

    public init(state: GsCanState, receiveErrorCount: UInt32, transmitErrorCount: UInt32) {
        self.state = state
        self.receiveErrorCount = receiveErrorCount
        self.transmitErrorCount = transmitErrorCount
    }

    public init(decoding source: some Sequence<UInt8>) throws {
        var cursor = try LittleEndianCursor(source, requiring: Self.byteCount)
        let rawState = cursor.readUInt32()
        guard let state = GsCanState(rawValue: rawState) else {
            throw GsUsbProtocolError.unknownState(rawState)
        }
        self.state = state
        receiveErrorCount = cursor.readUInt32()
        transmitErrorCount = cursor.readUInt32()
    }

    public func encoded() -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(Self.byteCount)
        out.appendLittleEndian(state.rawValue)
        out.appendLittleEndian(receiveErrorCount)
        out.appendLittleEndian(transmitErrorCount)
        return out
    }
}

// MARK: - gs_host_frame flags

/// `GS_CAN_FLAG_*` from `gs_host_frame.flags`.
///
/// `canFD` is load-bearing in both directions and not merely descriptive: it
/// is what sizes the transfer. candleLight picks each frame's length from this
/// bit, so a bulk-IN buffer can hold a 24-byte classical frame and an 80-byte
/// CAN FD one back to back, and the only way to find the second is to read the
/// first one's flags.
public struct GsHostFrameFlags: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let overflow = GsHostFrameFlags(rawValue: 1 << 0)
    public static let canFD = GsHostFrameFlags(rawValue: 1 << 1)
    public static let bitRateSwitch = GsHostFrameFlags(rawValue: 1 << 2)
    public static let errorStateIndicator = GsHostFrameFlags(rawValue: 1 << 3)
}

// MARK: - gs_host_frame

/// One `gs_host_frame` — the single structure carried on both bulk endpoints.
///
/// ```
/// [echo_id 4][can_id 4][can_dlc 1][channel 1][flags 1][reserved 1]
///                                     [data 8 | 64][timestamp_us 4]
/// ```
///
/// Two things vary, and between them they give the four `Layout` cases. The
/// data field is 8 bytes on a classical frame and 64 on a CAN FD one, chosen
/// by that frame's own `GS_CAN_FLAG_FD`. The trailing timestamp word is
/// present only when `GS_CAN_FEATURE_HW_TIMESTAMP` was negotiated at `MODE`,
/// which is a property of the connection rather than of the frame.
public struct GsHostFrame: Sendable, Equatable {
    /// `echo_id` for a frame the adapter observed on the bus. Any other value
    /// is the host's own transmit slot coming back as confirmation (§6.2).
    public static let receivedEchoID: UInt32 = 0xFFFF_FFFF

    /// Bytes before the data field: the two identifier words and the four
    /// one-byte fields. Enough to read `flags`, which is what a reader needs
    /// before it knows how long the rest of the frame is.
    public static let headerByteCount = 12
    /// Where `flags` sits, so a reader can size a frame without decoding it.
    public static let flagsByteOffset = 10

    /// `can_fd_dlc2len`: CAN FD's sixteen DLC codes and the payload length
    /// each one means. Above 8 the steps are coarse, which is the whole reason
    /// a CAN FD frame's length is not its DLC and this table has to exist.
    public static let canFDDataLengths: [Int] = [
        0, 1, 2, 3, 4, 5, 6, 7, 8, 12, 16, 20, 24, 32, 48, 64,
    ]

    /// Payload length for a CAN FD `can_dlc`, or `nil` for a DLC above 15.
    public static func dataLength(forCanFDDlc dlc: UInt8) -> Int? {
        dlc < UInt8(canFDDataLengths.count) ? canFDDataLengths[Int(dlc)] : nil
    }

    /// The DLC that means exactly `length` bytes, or `nil` when no DLC does.
    ///
    /// Deliberately exact rather than rounding up to the next representable
    /// length the way the Linux driver does. Rounding up transmits padding
    /// bytes the caller never wrote, and on a bus being reverse-engineered a
    /// frame whose tail nobody chose is a frame nobody can interpret. A caller
    /// that wants a 12-byte frame says so by passing twelve bytes.
    public static func canFDDlc(forDataLength length: Int) -> UInt8? {
        canFDDataLengths.firstIndex(of: length).map(UInt8.init)
    }

    /// Which union member the firmware is using, and therefore how many bytes
    /// one frame occupies.
    public enum Layout: Sendable, Equatable, CaseIterable {
        case classical
        case classicalWithTimestamp
        case canFD
        case canFDWithTimestamp

        /// `struct classic_can` versus `struct canfd`. The wire field is this
        /// wide whatever the DLC says.
        public var dataFieldByteCount: Int { isCanFD ? 64 : 8 }

        public var isCanFD: Bool {
            self == .canFD || self == .canFDWithTimestamp
        }

        public var carriesTimestamp: Bool {
            self == .classicalWithTimestamp || self == .canFDWithTimestamp
        }

        public var byteCount: Int {
            GsHostFrame.headerByteCount + dataFieldByteCount + (carriesTimestamp ? 4 : 0)
        }

        /// The layout a frame occupies, from the two facts that decide it.
        public init(canFD: Bool, timestamped: Bool) {
            switch (canFD, timestamped) {
            case (false, false): self = .classical
            case (false, true): self = .classicalWithTimestamp
            case (true, false): self = .canFD
            case (true, true): self = .canFDWithTimestamp
            }
        }

        init?(byteCount: Int) {
            switch byteCount {
            case 20: self = .classical
            case 24: self = .classicalWithTimestamp
            case 76: self = .canFD
            case 80: self = .canFDWithTimestamp
            default: return nil
            }
        }
    }

    // Linux `can.h` identifier flags, which gs_usb carries verbatim.
    private static let effFlag: UInt32 = 0x8000_0000
    private static let rtrFlag: UInt32 = 0x4000_0000
    private static let errFlag: UInt32 = 0x2000_0000
    private static let sffMask: UInt32 = 0x0000_07FF
    private static let effMask: UInt32 = 0x1FFF_FFFF

    public let echoID: UInt32
    /// Identifier with the flag bits still attached, exactly as on the wire.
    public let rawCanID: UInt32
    public let canDLC: UInt8
    public let channel: UInt8
    public let flags: GsHostFrameFlags
    public let reserved: UInt8
    /// Payload truncated to the length `canDLC` means — the DLC itself on a
    /// classical frame, `canFDDataLengths[canDLC]` on a CAN FD one. The wire
    /// field is the full 8 or 64 bytes either way; what lies past the declared
    /// length is stale firmware buffer, not bus data.
    public let data: [UInt8]
    /// Device microsecond counter, or `nil` on a layout that carries none.
    /// `TimestampMapper` is what turns this into a `Frame.timestampNs`.
    public let timestampMicroseconds: UInt32?

    public var layout: Layout {
        Layout(canFD: isCanFD, timestamped: timestampMicroseconds != nil)
    }

    public var isReceived: Bool { echoID == Self.receivedEchoID }

    /// The transmit slot to release, or `nil` for a received frame. Slot `0`
    /// is a real slot, so this is deliberately not a truthiness check.
    public var transmitSlot: UInt32? { isReceived ? nil : echoID }

    /// Identifier with the flag bits stripped, ready for `Frame.canID`.
    public var canID: UInt32 {
        rawCanID & (isExtended ? Self.effMask : Self.sffMask)
    }

    public var isExtended: Bool { rawCanID & Self.effFlag != 0 }
    public var isRemoteRequest: Bool { rawCanID & Self.rtrFlag != 0 }
    public var isError: Bool { rawCanID & Self.errFlag != 0 }
    public var isOverflow: Bool { flags.contains(.overflow) }
    public var isCanFD: Bool { flags.contains(.canFD) }
    /// The data phase ran at the data bitrate. A CAN FD frame without this is
    /// a 64-byte-capable frame sent entirely at the arbitration rate, which is
    /// a different thing on the wire and worth keeping distinguishable.
    public var isBitRateSwitch: Bool { flags.contains(.bitRateSwitch) }
    /// The transmitting node was error-passive when it sent this frame. Set by
    /// the sender's controller, not by anything the host can ask for.
    public var isErrorStateIndicator: Bool { flags.contains(.errorStateIndicator) }

    // MARK: Decode

    public init(decoding source: some Sequence<UInt8>) throws {
        let bytes = Array(source)
        guard let layout = Layout(byteCount: bytes.count) else {
            throw GsUsbProtocolError.unsupportedFrameLength(bytes.count)
        }

        var cursor = try LittleEndianCursor(bytes, requiring: layout.byteCount)
        echoID = cursor.readUInt32()
        rawCanID = cursor.readUInt32()

        let dlc = cursor.readUInt8()
        channel = cursor.readUInt8()
        let frameFlags = GsHostFrameFlags(rawValue: cursor.readUInt8())
        flags = frameFlags
        reserved = cursor.readUInt8()

        // The flag and the length are two statements about the same thing and
        // the firmware derives one from the other, so a disagreement is not a
        // frame with a confusing flag — it is bytes that are not this frame.
        guard frameFlags.contains(.canFD) == layout.isCanFD else {
            throw GsUsbProtocolError.frameFormatDisagreesWithLength(
                flags: frameFlags.rawValue, byteCount: bytes.count
            )
        }

        let length: Int
        if layout.isCanFD {
            guard let resolved = Self.dataLength(forCanFDDlc: dlc) else {
                throw GsUsbProtocolError.invalidDataLength(dlc)
            }
            length = resolved
        } else {
            guard dlc <= 8 else {
                throw GsUsbProtocolError.invalidDataLength(dlc)
            }
            length = Int(dlc)
        }
        canDLC = dlc
        data = Array(cursor.readBytes(layout.dataFieldByteCount).prefix(length))
        timestampMicroseconds = layout.carriesTimestamp ? cursor.readUInt32() : nil
    }

    // MARK: Encode

    /// Build a frame for transmit. `transmitSlot` is the host-chosen `echo_id`
    /// the device will hand back as confirmation.
    ///
    /// `canFD` is what selects the 64-byte data field and the DLC table that
    /// goes with it, and it is also the bit the device reads to decide how long
    /// the transfer it is being handed should be.
    public init(
        transmitSlot: UInt32,
        canID: UInt32,
        extended: Bool,
        remoteRequest: Bool = false,
        canFD: Bool = false,
        bitRateSwitch: Bool = false,
        channel: UInt8 = 0,
        data: [UInt8]
    ) throws {
        var frameFlags: GsHostFrameFlags = []
        let dlc: UInt8

        if canFD {
            // CAN FD has no RTR bit: the position it occupied is the reserved
            // RRS bit, which must be dominant. There is no remote-request CAN
            // FD frame to encode, so this cannot be honoured by dropping a bit.
            guard !remoteRequest else {
                throw GsUsbProtocolError.contradictoryFrameFlags(
                    "CAN FD has no remote-request frame; the RTR position is the "
                        + "reserved RRS bit and must be dominant"
                )
            }
            guard let resolved = Self.canFDDlc(forDataLength: data.count) else {
                throw GsUsbProtocolError.unrepresentableDataLength(data.count)
            }
            dlc = resolved
            frameFlags.insert(.canFD)
            if bitRateSwitch { frameFlags.insert(.bitRateSwitch) }
        } else {
            guard !bitRateSwitch else {
                throw GsUsbProtocolError.contradictoryFrameFlags(
                    "a classical CAN frame has no data phase to switch the bit "
                        + "rate for"
                )
            }
            guard data.count <= 8 else {
                throw GsUsbProtocolError.invalidDataLength(UInt8(min(data.count, Int(UInt8.max))))
            }
            dlc = UInt8(data.count)
        }

        var identifier = canID & (extended ? Self.effMask : Self.sffMask)
        if extended { identifier |= Self.effFlag }
        if remoteRequest { identifier |= Self.rtrFlag }

        echoID = transmitSlot
        rawCanID = identifier
        canDLC = dlc
        self.channel = channel
        flags = frameFlags
        reserved = 0
        self.data = data
        timestampMicroseconds = nil
    }

    /// Serialise in the given layout.
    ///
    /// The layout is a parameter rather than being read off the frame because
    /// the timestamp half of it belongs to the *connection*: the device expects
    /// the larger struct in both directions once hardware timestamping is
    /// negotiated, even though the host has no timestamp to put there. The
    /// data-field half does come from the frame's own `canFD` flag, so passing
    /// a layout that disagrees with it pads or truncates — which is why
    /// `GsUsbDevice` derives the layout from the frame it is about to send.
    public func encoded(as layout: Layout) -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(layout.byteCount)
        out.appendLittleEndian(echoID)
        out.appendLittleEndian(rawCanID)
        out.append(canDLC)
        out.append(channel)
        out.append(flags.rawValue)
        out.append(reserved)

        let width = layout.dataFieldByteCount
        out.append(contentsOf: data.prefix(width))
        out.append(contentsOf: [UInt8](repeating: 0, count: width - min(data.count, width)))

        if layout.carriesTimestamp {
            out.appendLittleEndian(timestampMicroseconds ?? 0)
        }
        return out
    }
}
