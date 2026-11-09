import Foundation
import Testing
@testable import GSUSBKit

// MARK: - Request codes

/// The numbering is positional in `enum gs_usb_breq`, so an accidental
/// reordering would silently send `BITTIMING` where `MODE` was meant. Pinning
/// every value is the only way that shows up as a test failure instead of a
/// confused adapter.
@Test func breqValuesMatchTheCandleLightHeader() {
    #expect(GsUsbBreq.hostFormat.rawValue == 0)
    #expect(GsUsbBreq.bittiming.rawValue == 1)
    #expect(GsUsbBreq.mode.rawValue == 2)
    #expect(GsUsbBreq.berr.rawValue == 3)
    #expect(GsUsbBreq.btConst.rawValue == 4)
    #expect(GsUsbBreq.deviceConfig.rawValue == 5)
    #expect(GsUsbBreq.timestamp.rawValue == 6)
    #expect(GsUsbBreq.identify.rawValue == 7)
    #expect(GsUsbBreq.getUserID.rawValue == 8)
    #expect(GsUsbBreq.setUserID.rawValue == 9)
    #expect(GsUsbBreq.dataBittiming.rawValue == 10)
    #expect(GsUsbBreq.btConstExt.rawValue == 11)
    #expect(GsUsbBreq.setTermination.rawValue == 12)
    #expect(GsUsbBreq.getTermination.rawValue == 13)
    #expect(GsUsbBreq.getState.rawValue == 14)
}

// MARK: - Feature bits

@Test func featureBitsMatchTheCandleLightHeader() {
    #expect(GsCanFeature.listenOnly.rawValue == 1 << 0)
    #expect(GsCanFeature.loopBack.rawValue == 1 << 1)
    #expect(GsCanFeature.tripleSample.rawValue == 1 << 2)
    #expect(GsCanFeature.oneShot.rawValue == 1 << 3)
    #expect(GsCanFeature.hardwareTimestamp.rawValue == 1 << 4)
    #expect(GsCanFeature.identify.rawValue == 1 << 5)
    #expect(GsCanFeature.userID.rawValue == 1 << 6)
    #expect(GsCanFeature.padPacketsToMaxPacketSize.rawValue == 1 << 7)
    #expect(GsCanFeature.canFD.rawValue == 1 << 8)
    #expect(GsCanFeature.requiresUsbQuirkLpc546xx.rawValue == 1 << 9)
    #expect(GsCanFeature.btConstExt.rawValue == 1 << 10)
    #expect(GsCanFeature.termination.rawValue == 1 << 11)
    #expect(GsCanFeature.berrReporting.rawValue == 1 << 12)
    #expect(GsCanFeature.getState.rawValue == 1 << 13)
}

/// The mode flags the driver actually requests at `MODE`, per design §6.2 and
/// §7.1: one-shot so an unACKed frame is dropped rather than retried to
/// bus-off, hardware timestamps so bursts keep their intra-burst resolution.
@Test func featureSetReportsMembershipForTheFlagsTheDriverRequests() {
    let candleLight: GsCanFeature = [
        .listenOnly, .loopBack, .tripleSample, .oneShot,
        .hardwareTimestamp, .identify, .userID, .berrReporting, .getState,
    ]
    #expect(candleLight.contains(.hardwareTimestamp))
    #expect(candleLight.contains(.oneShot))
    #expect(!candleLight.contains(.canFD))
    #expect(!candleLight.contains(.termination))
}

// MARK: - Mode and state

@Test func modeValuesMatchTheCandleLightHeader() {
    #expect(GsCanMode.reset.rawValue == 0)
    #expect(GsCanMode.start.rawValue == 1)
}

@Test func stateValuesMatchTheCandleLightHeader() {
    #expect(GsCanState.errorActive.rawValue == 0)
    #expect(GsCanState.errorWarning.rawValue == 1)
    #expect(GsCanState.errorPassive.rawValue == 2)
    #expect(GsCanState.busOff.rawValue == 3)
    #expect(GsCanState.stopped.rawValue == 4)
    #expect(GsCanState.sleeping.rawValue == 5)
}

/// §7.2 raises a marker on transitions into these three and drives
/// `ConnectionState.disconnected` from bus-off, so "is this state a problem"
/// is a property of the state rather than a condition repeated at each call.
@Test func stateKnowsWhichValuesAreDegraded() {
    #expect(!GsCanState.errorActive.isDegraded)
    #expect(GsCanState.errorWarning.isDegraded)
    #expect(GsCanState.errorPassive.isDegraded)
    #expect(GsCanState.busOff.isDegraded)
}

@Test func unknownStateValueDecodesToNilRatherThanTrapping() {
    #expect(GsCanState(rawValue: 99) == nil)
}

// MARK: - Fixture helpers

/// One little-endian `u32`, written out by hand rather than by the codec under
/// test. A fixture built with the encoder it is meant to check would pass
/// against a consistently byte-swapped implementation.
private func le32(_ value: UInt32) -> [UInt8] {
    [
        UInt8(value & 0xFF),
        UInt8((value >> 8) & 0xFF),
        UInt8((value >> 16) & 0xFF),
        UInt8((value >> 24) & 0xFF),
    ]
}

// MARK: - gs_host_config

@Test func hostConfigEncodesTheByteOrderMagicLittleEndian() {
    #expect(GsHostConfig.littleEndian.encoded() == [0xEF, 0xBE, 0x00, 0x00])
}

@Test func hostConfigIsFourBytes() {
    #expect(GsHostConfig.byteCount == 4)
    #expect(GsHostConfig.littleEndian.byteOrder == 0x0000_BEEF)
}

// MARK: - gs_device_config

@Test func deviceConfigDecodesTheHeaderLayout() throws {
    // reserved1..3, icount, then sw_version and hw_version as u32 LE.
    let bytes: [UInt8] = [0x01, 0x02, 0x03, 0x00] + le32(2) + le32(1)
    let config = try GsDeviceConfig(decoding: bytes)
    #expect(config.interfaceCountMinusOne == 0)
    #expect(config.softwareVersion == 2)
    #expect(config.hardwareVersion == 1)
}

/// `icount` is "number of interfaces minus one", so the off-by-one belongs in
/// the decoder once rather than at every call site that wants a count.
@Test func deviceConfigReportsChannelCountNotTheRawIcount() throws {
    let single = try GsDeviceConfig(decoding: [0, 0, 0, 0] + le32(2) + le32(1))
    #expect(single.channelCount == 1)

    let dual = try GsDeviceConfig(decoding: [0, 0, 0, 1] + le32(2) + le32(1))
    #expect(dual.channelCount == 2)
}

@Test func deviceConfigRoundTripsThroughItsOwnEncoder() throws {
    let bytes: [UInt8] = [0, 0, 0, 0] + le32(0x0000_0002) + le32(0x0000_0001)
    let config = try GsDeviceConfig(decoding: bytes)
    #expect(config.encoded() == bytes)
}

@Test func deviceConfigRejectsAShortBufferRatherThanReadingPastTheEnd() {
    #expect(throws: GsUsbProtocolError.truncated(expected: 12, actual: 11)) {
        _ = try GsDeviceConfig(decoding: [UInt8](repeating: 0, count: 11))
    }
}

/// The device may answer with more bytes than this struct version knows about
/// — a newer firmware appending fields. Reading the prefix is correct and
/// forward-compatible; refusing would break on a firmware upgrade.
@Test func deviceConfigAcceptsALongerBufferAndReadsThePrefix() throws {
    let bytes: [UInt8] = [0, 0, 0, 0] + le32(7) + le32(3) + [0xAA, 0xBB]
    let config = try GsDeviceConfig(decoding: bytes)
    #expect(config.softwareVersion == 7)
    #expect(config.hardwareVersion == 3)
}

// MARK: - gs_device_mode

@Test func deviceModeEncodesModeThenFlags() {
    let mode = GsDeviceMode(mode: .start, flags: [.hardwareTimestamp, .oneShot])
    #expect(mode.encoded() == le32(1) + le32((1 << 4) | (1 << 3)))
}

@Test func deviceModeResetEncodesZeroFlags() {
    #expect(GsDeviceMode(mode: .reset, flags: []).encoded() == le32(0) + le32(0))
}

@Test func deviceModeRoundTrips() throws {
    let bytes = le32(1) + le32((1 << 0) | (1 << 12))
    let mode = try GsDeviceMode(decoding: bytes)
    #expect(mode.mode == .start)
    #expect(mode.flags == [.listenOnly, .berrReporting])
    #expect(mode.encoded() == bytes)
}

@Test func deviceModeRejectsAShortBuffer() {
    #expect(throws: GsUsbProtocolError.truncated(expected: 8, actual: 4)) {
        _ = try GsDeviceMode(decoding: le32(1))
    }
}

@Test func deviceModeRejectsAnUnknownModeValue() {
    #expect(throws: GsUsbProtocolError.unknownMode(9)) {
        _ = try GsDeviceMode(decoding: le32(9) + le32(0))
    }
}

// MARK: - gs_device_bittiming

@Test func bittimingEncodesFiveWordsInHeaderOrder() {
    let timing = GsDeviceBittiming(propSeg: 1, phaseSeg1: 12, phaseSeg2: 2, sjw: 1, brp: 6)
    #expect(timing.encoded() == le32(1) + le32(12) + le32(2) + le32(1) + le32(6))
}

@Test func bittimingRoundTrips() throws {
    let bytes = le32(1) + le32(13) + le32(2) + le32(1) + le32(3)
    let timing = try GsDeviceBittiming(decoding: bytes)
    #expect(timing.propSeg == 1)
    #expect(timing.phaseSeg1 == 13)
    #expect(timing.phaseSeg2 == 2)
    #expect(timing.sjw == 1)
    #expect(timing.brp == 3)
    #expect(timing.encoded() == bytes)
}

@Test func bittimingRejectsAShortBuffer() {
    #expect(throws: GsUsbProtocolError.truncated(expected: 20, actual: 16)) {
        _ = try GsDeviceBittiming(decoding: [UInt8](repeating: 0, count: 16))
    }
}

// MARK: - gs_device_bt_const

/// Values as candleLight reports them on an STM32F072 — 48 MHz bxCAN clock,
/// the bxCAN segment limits. Phase 3 solves against exactly this shape.
@Test func btConstDecodesTheTenWordLayout() throws {
    let bytes = le32((1 << 0) | (1 << 3) | (1 << 4))
        + le32(48_000_000)
        + le32(1) + le32(16)
        + le32(1) + le32(8)
        + le32(4)
        + le32(1) + le32(1024) + le32(1)
    let btConst = try GsDeviceBtConst(decoding: bytes)
    #expect(btConst.feature == [.listenOnly, .oneShot, .hardwareTimestamp])
    #expect(btConst.canClockHz == 48_000_000)
    #expect(btConst.tseg1Min == 1)
    #expect(btConst.tseg1Max == 16)
    #expect(btConst.tseg2Min == 1)
    #expect(btConst.tseg2Max == 8)
    #expect(btConst.sjwMax == 4)
    #expect(btConst.brpMin == 1)
    #expect(btConst.brpMax == 1024)
    #expect(btConst.brpInc == 1)
    #expect(btConst.encoded() == bytes)
}

@Test func btConstRejectsAShortBuffer() {
    #expect(throws: GsUsbProtocolError.truncated(expected: 40, actual: 36)) {
        _ = try GsDeviceBtConst(decoding: [UInt8](repeating: 0, count: 36))
    }
}

/// An unrecognised high bit must survive the round trip. Masking the feature
/// word down to the bits this version knows would discard a newer firmware's
/// capabilities and silently under-report the device.
@Test func btConstPreservesUnknownFeatureBits() throws {
    let bytes = le32(0x8000_0010) + le32(48_000_000)
        + le32(1) + le32(16) + le32(1) + le32(8)
        + le32(4) + le32(1) + le32(1024) + le32(1)
    let btConst = try GsDeviceBtConst(decoding: bytes)
    #expect(btConst.feature.contains(.hardwareTimestamp))
    #expect(btConst.feature.rawValue == 0x8000_0010)
    #expect(btConst.encoded() == bytes)
}

// MARK: - gs_device_bt_const_extended

/// Values in the shape an FDCAN peripheral reports: one `fclk_can`, two sets
/// of segment limits, and the data phase's are not the arbitration phase's.
@Test func btConstExtendedDecodesBothPhasesOfTheEighteenWordLayout() throws {
    let bytes = le32((1 << 0) | (1 << 8) | (1 << 10))
        + le32(80_000_000)
        + le32(1) + le32(256) + le32(1) + le32(128)
        + le32(128) + le32(1) + le32(512) + le32(1)
        + le32(1) + le32(32) + le32(1) + le32(16)
        + le32(16) + le32(1) + le32(32) + le32(1)
    #expect(bytes.count == GsDeviceBtConstExtended.byteCount)
    #expect(GsDeviceBtConstExtended.byteCount == 72)

    let extended = try GsDeviceBtConstExtended(decoding: bytes)
    #expect(extended.feature == [.listenOnly, .canFD, .btConstExt])
    #expect(extended.canClockHz == 80_000_000)

    // The first 40 bytes are a `gs_device_bt_const` verbatim.
    #expect(extended.arbitration.tseg1Max == 256)
    #expect(extended.arbitration.tseg2Max == 128)
    #expect(extended.arbitration.sjwMax == 128)
    #expect(extended.arbitration.brpMax == 512)
    let arbitrationAlone = try GsDeviceBtConst(decoding: bytes.prefix(40))
    #expect(extended.arbitration == arbitrationAlone)

    // The data phase's own limits, carrying the same feature word and clock so
    // `BitTiming.solve` takes it with no adaptation.
    #expect(extended.dataPhase.feature == extended.feature)
    #expect(extended.dataPhase.canClockHz == 80_000_000)
    #expect(extended.dataPhase.tseg1Min == 1)
    #expect(extended.dataPhase.tseg1Max == 32)
    #expect(extended.dataPhase.tseg2Min == 1)
    #expect(extended.dataPhase.tseg2Max == 16)
    #expect(extended.dataPhase.sjwMax == 16)
    #expect(extended.dataPhase.brpMin == 1)
    #expect(extended.dataPhase.brpMax == 32)
    #expect(extended.dataPhase.brpInc == 1)

    #expect(extended.encoded() == bytes)
}

@Test func btConstExtendedRejectsABufferShortOfItsSecondPhase() {
    #expect(throws: GsUsbProtocolError.truncated(expected: 72, actual: 40)) {
        _ = try GsDeviceBtConstExtended(decoding: [UInt8](repeating: 0, count: 40))
    }
}

// MARK: - gs_host_frame fixtures

/// A `gs_host_frame` built byte by byte:
/// `[echo_id 4][can_id 4][dlc 1][channel 1][flags 1][reserved 1][data 8]`
/// optionally followed by `[timestamp_us 4]`.
private func hostFrameBytes(
    echoID: UInt32 = 0xFFFF_FFFF,
    rawCanID: UInt32,
    dlc: UInt8,
    channel: UInt8 = 0,
    flags: UInt8 = 0,
    reserved: UInt8 = 0,
    data: [UInt8],
    timestampMicroseconds: UInt32? = nil
) -> [UInt8] {
    // The data field's width comes from the FD flag, exactly as it does in the
    // firmware — a fixture that always padded to 8 could not express a CAN FD
    // frame at all.
    let width = flags & (1 << 1) != 0 ? 64 : 8
    var padded = data
    padded.append(contentsOf: [UInt8](repeating: 0, count: max(0, width - padded.count)))
    var out = le32(echoID) + le32(rawCanID) + [dlc, channel, flags, reserved] + padded
    if let timestampMicroseconds {
        out += le32(timestampMicroseconds)
    }
    return out
}

private let fdFlag: UInt8 = 1 << 1
private let brsFlag: UInt8 = 1 << 2
private let esiFlag: UInt8 = 1 << 3

// MARK: - gs_host_frame layout

@Test func hostFrameLayoutByteCountsMatchTheUnionMembers() {
    #expect(GsHostFrame.Layout.classical.byteCount == 20)
    #expect(GsHostFrame.Layout.classicalWithTimestamp.byteCount == 24)
    #expect(GsHostFrame.Layout.canFD.byteCount == 76)
    #expect(GsHostFrame.Layout.canFDWithTimestamp.byteCount == 80)

    // 12 header bytes plus the union member, which is what the firmware's
    // `struct_size(frame, …)` computes.
    for layout in GsHostFrame.Layout.allCases {
        #expect(layout.byteCount
            == GsHostFrame.headerByteCount
                + layout.dataFieldByteCount
                + (layout.carriesTimestamp ? 4 : 0))
    }
}

/// The two facts that pick a layout are independent: the FD flag is the
/// frame's, the timestamp word is the connection's.
@Test func layoutIsTheProductOfTheFrameFormatAndTheTimestampFeature() {
    #expect(GsHostFrame.Layout(canFD: false, timestamped: false) == .classical)
    #expect(GsHostFrame.Layout(canFD: false, timestamped: true) == .classicalWithTimestamp)
    #expect(GsHostFrame.Layout(canFD: true, timestamped: false) == .canFD)
    #expect(GsHostFrame.Layout(canFD: true, timestamped: true) == .canFDWithTimestamp)
}

/// `flags` has to be readable before the frame's length is known, because that
/// length is derived from it. The read loop indexes straight at this offset.
@Test func theFlagsByteSitsWhereTheReadLoopLooksForIt() {
    let bytes = hostFrameBytes(rawCanID: 0x100, dlc: 0, flags: fdFlag, data: [])
    #expect(GsHostFrame.flagsByteOffset == 10)
    #expect(GsHostFrame.headerByteCount == 12)
    #expect(bytes[GsHostFrame.flagsByteOffset] == fdFlag)
}

// MARK: - CAN FD data lengths

/// `can_fd_dlc2len`. Above 8 the steps are coarse, which is the whole reason a
/// CAN FD frame's payload length is not its DLC.
@Test func theCanFDDlcTableMatchesTheStandard() {
    #expect(GsHostFrame.canFDDataLengths
        == [0, 1, 2, 3, 4, 5, 6, 7, 8, 12, 16, 20, 24, 32, 48, 64])

    for (dlc, length) in GsHostFrame.canFDDataLengths.enumerated() {
        #expect(GsHostFrame.dataLength(forCanFDDlc: UInt8(dlc)) == length)
        #expect(GsHostFrame.canFDDlc(forDataLength: length) == UInt8(dlc))
    }

    // A DLC is four bits; there is no 16th code.
    #expect(GsHostFrame.dataLength(forCanFDDlc: 16) == nil)
    #expect(GsHostFrame.dataLength(forCanFDDlc: 255) == nil)
}

/// Deliberately not the kernel's round-up-to-the-next-size behaviour: padding
/// to a representable length transmits bytes the caller never wrote.
@Test func anUnrepresentableCanFDLengthHasNoDlcRatherThanTheNextOneUp() {
    for length in [9, 10, 11, 13, 17, 25, 33, 49, 63, 65] {
        #expect(GsHostFrame.canFDDlc(forDataLength: length) == nil)
    }
}

@Test func hostFrameDecodesTheTwentyByteClassicalLayout() throws {
    let bytes = hostFrameBytes(rawCanID: 0x123, dlc: 3, data: [0xDE, 0xAD, 0xBE])
    #expect(bytes.count == 20)

    let frame = try GsHostFrame(decoding: bytes)
    #expect(frame.canID == 0x123)
    #expect(frame.canDLC == 3)
    #expect(frame.data == [0xDE, 0xAD, 0xBE])
    #expect(frame.timestampMicroseconds == nil)
    #expect(frame.layout == .classical)
}

@Test func hostFrameDecodesTheTwentyFourByteTimestampLayout() throws {
    let bytes = hostFrameBytes(
        rawCanID: 0x7FF, dlc: 8,
        data: [1, 2, 3, 4, 5, 6, 7, 8],
        timestampMicroseconds: 0x1234_5678
    )
    #expect(bytes.count == 24)

    let frame = try GsHostFrame(decoding: bytes)
    #expect(frame.canID == 0x7FF)
    #expect(frame.data == [1, 2, 3, 4, 5, 6, 7, 8])
    #expect(frame.timestampMicroseconds == 0x1234_5678)
    #expect(frame.layout == .classicalWithTimestamp)
}

@Test func hostFrameRejectsALengthThatIsNeitherLayout() {
    #expect(throws: GsUsbProtocolError.unsupportedFrameLength(22)) {
        _ = try GsHostFrame(decoding: [UInt8](repeating: 0, count: 22))
    }
    #expect(throws: GsUsbProtocolError.unsupportedFrameLength(0)) {
        _ = try GsHostFrame(decoding: [])
    }
    // 12 header bytes plus the full classical data field *and* a timestamp is
    // not a CAN FD frame; 76 and 80 are the only FD sizes.
    #expect(throws: GsUsbProtocolError.unsupportedFrameLength(72)) {
        _ = try GsHostFrame(decoding: [UInt8](repeating: 0, count: 72))
    }
}

// MARK: - CAN FD frames

@Test func hostFrameDecodesTheSeventySixByteCanFDLayout() throws {
    let payload = (0..<64).map { UInt8($0) }
    let bytes = hostFrameBytes(rawCanID: 0x321, dlc: 15, flags: fdFlag, data: payload)
    #expect(bytes.count == 76)

    let frame = try GsHostFrame(decoding: bytes)
    #expect(frame.canID == 0x321)
    #expect(frame.isCanFD)
    #expect(frame.data == payload)
    #expect(frame.layout == .canFD)
    #expect(frame.timestampMicroseconds == nil)
}

@Test func hostFrameDecodesTheEightyByteCanFDTimestampLayout() throws {
    let bytes = hostFrameBytes(
        rawCanID: 0x1FFF_FFFF | 0x8000_0000, dlc: 9, flags: fdFlag | brsFlag,
        data: [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12],
        timestampMicroseconds: 0x0BAD_F00D
    )
    #expect(bytes.count == 80)

    let frame = try GsHostFrame(decoding: bytes)
    #expect(frame.isExtended)
    #expect(frame.canID == 0x1FFF_FFFF)
    #expect(frame.isCanFD)
    #expect(frame.isBitRateSwitch)
    #expect(!frame.isErrorStateIndicator)
    // DLC 9 means twelve bytes, which is the whole point of the table.
    #expect(frame.data == [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12])
    #expect(frame.timestampMicroseconds == 0x0BAD_F00D)
    #expect(frame.layout == .canFDWithTimestamp)
}

/// The 64-byte wire field is as stale past the declared length as the 8-byte
/// one is, and a DLC of 9 declares twelve bytes, not sixty-four.
@Test func aCanFDPayloadIsTruncatedToTheLengthItsDlcMeans() throws {
    let frame = try GsHostFrame(decoding: hostFrameBytes(
        rawCanID: 0x100, dlc: 10, flags: fdFlag,
        data: [UInt8](repeating: 0xEE, count: 64)
    ))
    #expect(frame.canDLC == 10)
    #expect(frame.data == [UInt8](repeating: 0xEE, count: 16))
}

@Test func aCanFDFrameCarriesTheErrorStateIndicatorOfItsSender() throws {
    let frame = try GsHostFrame(decoding: hostFrameBytes(
        rawCanID: 0x100, dlc: 0, flags: fdFlag | esiFlag, data: []
    ))
    #expect(frame.isErrorStateIndicator)
    #expect(frame.data.isEmpty)
}

/// The firmware sizes each transfer from this very flag, so a disagreement is
/// not a frame with an odd flag — it is bytes that are not the frame they say.
@Test func theFdFlagAndTheBufferLengthMustAgree() {
    var classicalLength = hostFrameBytes(rawCanID: 0x100, dlc: 0, data: [])
    classicalLength[GsHostFrame.flagsByteOffset] = fdFlag
    #expect(throws: GsUsbProtocolError.frameFormatDisagreesWithLength(
        flags: fdFlag, byteCount: 20
    )) {
        _ = try GsHostFrame(decoding: classicalLength)
    }

    var fdLength = hostFrameBytes(rawCanID: 0x100, dlc: 0, flags: fdFlag, data: [])
    fdLength[GsHostFrame.flagsByteOffset] = 0
    #expect(throws: GsUsbProtocolError.frameFormatDisagreesWithLength(
        flags: 0, byteCount: 76
    )) {
        _ = try GsHostFrame(decoding: fdLength)
    }
}

/// A four-bit field cannot hold 16, so this is the decoder refusing a byte the
/// firmware could not have written — not a reachable bus condition.
@Test func aCanFDFrameRejectsADlcAboveFifteen() {
    var bytes = hostFrameBytes(rawCanID: 0x100, dlc: 0, flags: fdFlag, data: [])
    bytes[8] = 16
    #expect(throws: GsUsbProtocolError.invalidDataLength(16)) {
        _ = try GsHostFrame(decoding: bytes)
    }
}

// MARK: - echo_id: received versus our own transmission

/// §6.2: the echo is the only transmit confirmation there is, and
/// `0xFFFFFFFF` is the sentinel that separates a bus observation from one.
@Test func hostFrameWithTheSentinelEchoIDIsAReceivedFrame() throws {
    let frame = try GsHostFrame(decoding: hostFrameBytes(
        echoID: 0xFFFF_FFFF, rawCanID: 0x100, dlc: 0, data: []
    ))
    #expect(frame.isReceived)
    #expect(frame.echoID == GsHostFrame.receivedEchoID)
    #expect(frame.transmitSlot == nil)
}

@Test func hostFrameWithAnyOtherEchoIDIsATransmitEcho() throws {
    let frame = try GsHostFrame(decoding: hostFrameBytes(
        echoID: 7, rawCanID: 0x100, dlc: 0, data: []
    ))
    #expect(!frame.isReceived)
    #expect(frame.transmitSlot == 7)
}

/// Slot zero is a legitimate slot index. Treating `echoID == 0` as falsy would
/// file the first frame the host ever transmits as a bus observation.
@Test func transmitSlotZeroIsATransmitEchoNotAReceivedFrame() throws {
    let frame = try GsHostFrame(decoding: hostFrameBytes(
        echoID: 0, rawCanID: 0x100, dlc: 0, data: []
    ))
    #expect(!frame.isReceived)
    #expect(frame.transmitSlot == 0)
}

// MARK: - channel

/// §7.3: a multi-channel adapter is out of scope. Detection is this phase's
/// job; phase 5 is what refuses to connect.
@Test func hostFrameSurfacesANonZeroChannel() throws {
    let frame = try GsHostFrame(decoding: hostFrameBytes(
        rawCanID: 0x100, dlc: 1, channel: 2, data: [0xFF]
    ))
    #expect(frame.channel == 2)
}

// MARK: - can_id flag decoding

@Test func hostFrameDecodesAnExtendedIdentifierAndMasksToTwentyNineBits() throws {
    // CAN_EFF_FLAG | a 29-bit identifier.
    let frame = try GsHostFrame(decoding: hostFrameBytes(
        rawCanID: 0x8000_0000 | 0x1234_5678, dlc: 0, data: []
    ))
    #expect(frame.isExtended)
    #expect(frame.canID == 0x1234_5678)
}

/// The flag bits live in the same word as the identifier, so a decoder that
/// forgets to mask hands the analysis layer an identifier of 0x80000123.
@Test func hostFrameMasksAStandardIdentifierToElevenBits() throws {
    let frame = try GsHostFrame(decoding: hostFrameBytes(
        rawCanID: 0x0000_07FF, dlc: 0, data: []
    ))
    #expect(!frame.isExtended)
    #expect(frame.canID == 0x7FF)
}

@Test func hostFrameDecodesTheRemoteRequestFlag() throws {
    let frame = try GsHostFrame(decoding: hostFrameBytes(
        rawCanID: 0x4000_0000 | 0x201, dlc: 0, data: []
    ))
    #expect(frame.isRemoteRequest)
    #expect(!frame.isError)
    #expect(frame.canID == 0x201)
}

/// §7.2 maps gs_usb error frames onto the existing `Frame.err` field, so the
/// error flag has to survive decode rather than being dropped as noise.
@Test func hostFrameDecodesTheErrorFlag() throws {
    let frame = try GsHostFrame(decoding: hostFrameBytes(
        rawCanID: 0x2000_0000 | 0x002, dlc: 1, data: [0x04]
    ))
    #expect(frame.isError)
    #expect(!frame.isRemoteRequest)
}

@Test func hostFrameDecodesTheOverflowFrameFlag() throws {
    let frame = try GsHostFrame(decoding: hostFrameBytes(
        rawCanID: 0x100, dlc: 0, flags: 1 << 0, data: []
    ))
    #expect(frame.flags.contains(.overflow))
    #expect(frame.isOverflow)
}

@Test func hostFrameFlagBitsMatchTheCandleLightHeader() {
    #expect(GsHostFrameFlags.overflow.rawValue == 1 << 0)
    #expect(GsHostFrameFlags.canFD.rawValue == 1 << 1)
    #expect(GsHostFrameFlags.bitRateSwitch.rawValue == 1 << 2)
    #expect(GsHostFrameFlags.errorStateIndicator.rawValue == 1 << 3)
}

// MARK: - payload truncation

/// The data field is always 8 bytes on the wire regardless of `can_dlc`, and
/// the bytes past the DLC are whatever the firmware left there. Publishing
/// them would invent payload the bus never carried.
@Test func hostFramePayloadIsTruncatedToTheDeclaredDataLength() throws {
    let frame = try GsHostFrame(decoding: hostFrameBytes(
        rawCanID: 0x100, dlc: 2, data: [0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, 0x11, 0x22]
    ))
    #expect(frame.data == [0xAA, 0xBB])
}

@Test func hostFrameWithZeroDataLengthHasAnEmptyPayload() throws {
    let frame = try GsHostFrame(decoding: hostFrameBytes(
        rawCanID: 0x100, dlc: 0, data: [0x99, 0x99, 0x99, 0x99, 0x99, 0x99, 0x99, 0x99]
    ))
    #expect(frame.data.isEmpty)
}

/// Classical CAN's payload tops out at eight bytes, but its DLC *codes* run to
/// 15 and every code above 8 still means exactly eight bytes — the length is
/// `min(dlc, 8)`, which is what `can_cc_dlc2len` does upstream. Those codes are
/// legal on the wire and do turn up, so refusing them would count ordinary
/// traffic as a decode failure. The code itself is preserved in `canDLC`.
@Test func aClassicalDlcAboveEightMeansEightBytesRatherThanBeingRefused() throws {
    let payload: [UInt8] = [0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, 0x11, 0x22]
    for dlc: UInt8 in 9...15 {
        let frame = try GsHostFrame(decoding: hostFrameBytes(
            rawCanID: 0x100, dlc: dlc, data: payload
        ))
        #expect(frame.canDLC == dlc)
        #expect(frame.data == payload)
    }
}

/// A four-bit field cannot hold 16, so this is corruption rather than one more
/// code that means eight bytes — the classical counterpart of
/// `aCanFDFrameRejectsADlcAboveFifteen`.
@Test func aClassicalFrameRejectsADlcAboveFifteen() {
    var bytes = hostFrameBytes(rawCanID: 0x100, dlc: 0, data: [])
    bytes[8] = 16
    #expect(throws: GsUsbProtocolError.invalidDataLength(16)) {
        _ = try GsHostFrame(decoding: bytes)
    }
}

// MARK: - encode for transmit

@Test func transmitFrameEncodesToTwentyBytesInTheClassicalLayout() throws {
    let frame = try GsHostFrame(
        transmitSlot: 3, canID: 0x1A0, extended: false, data: [0x01, 0x02]
    )
    let encoded = frame.encoded(as: .classical)
    #expect(encoded == hostFrameBytes(
        echoID: 3, rawCanID: 0x1A0, dlc: 2, data: [0x01, 0x02]
    ))
    #expect(encoded.count == 20)
}

/// When hardware timestamping is negotiated the device expects the larger
/// struct in **both** directions, so transmit has to pad to 24 bytes.
@Test func transmitFrameEncodesToTwentyFourBytesWhenTimestampingIsNegotiated() throws {
    let frame = try GsHostFrame(
        transmitSlot: 0, canID: 0x1A0, extended: false, data: [0x01]
    )
    let encoded = frame.encoded(as: .classicalWithTimestamp)
    #expect(encoded.count == 24)
    #expect(Array(encoded.suffix(4)) == [0, 0, 0, 0])
}

@Test func transmitFrameSetsTheExtendedFlagInTheIdentifierWord() throws {
    let frame = try GsHostFrame(
        transmitSlot: 1, canID: 0x1234_5678, extended: true, data: []
    )
    let encoded = frame.encoded(as: .classical)
    #expect(Array(encoded[4..<8]) == le32(0x8000_0000 | 0x1234_5678))
}

@Test func transmitFrameSetsTheRemoteRequestFlagInTheIdentifierWord() throws {
    let frame = try GsHostFrame(
        transmitSlot: 1, canID: 0x100, extended: false, remoteRequest: true, data: []
    )
    let encoded = frame.encoded(as: .classical)
    #expect(Array(encoded[4..<8]) == le32(0x4000_0000 | 0x100))
}

@Test func transmitFrameRejectsAPayloadLongerThanEightBytes() {
    #expect(throws: GsUsbProtocolError.invalidDataLength(9)) {
        _ = try GsHostFrame(
            transmitSlot: 0, canID: 0x100, extended: false,
            data: [1, 2, 3, 4, 5, 6, 7, 8, 9]
        )
    }
}

// MARK: - encode for transmit: CAN FD

@Test func aCanFDTransmitFrameEncodesTheFlagTheDlcAndTheSixtyFourByteField() throws {
    let payload = [UInt8](repeating: 0x5A, count: 24)
    let frame = try GsHostFrame(
        transmitSlot: 2, canID: 0x1A0, extended: false,
        canFD: true, bitRateSwitch: true, data: payload
    )
    // 24 bytes is DLC 12, not 11: the table is not contiguous past 8.
    #expect(frame.canDLC == 12)
    #expect(frame.isCanFD)
    #expect(frame.isBitRateSwitch)

    let encoded = frame.encoded(as: .canFD)
    #expect(encoded.count == 76)
    #expect(encoded == hostFrameBytes(
        echoID: 2, rawCanID: 0x1A0, dlc: 12, flags: fdFlag | brsFlag, data: payload
    ))
    // Only the declared 24 bytes are payload; the rest of the field is zeroed
    // rather than left as whatever was in the buffer.
    #expect(Array(encoded[(12 + 24)..<76]) == [UInt8](repeating: 0, count: 40))
}

@Test func aCanFDTransmitFramePadsToEightyBytesWhenTimestampingIsNegotiated() throws {
    let frame = try GsHostFrame(
        transmitSlot: 0, canID: 0x1A0, extended: false, canFD: true, data: [0x01]
    )
    let encoded = frame.encoded(as: .canFDWithTimestamp)
    #expect(encoded.count == 80)
    #expect(Array(encoded.suffix(4)) == [0, 0, 0, 0])
}

/// The length has to be one CAN FD can express. Rounding 9 up to 12 would put
/// three bytes on the bus that the caller never chose.
@Test func aCanFDTransmitFrameRejectsALengthNoDlcCanExpress() {
    #expect(throws: GsUsbProtocolError.unrepresentableDataLength(9)) {
        _ = try GsHostFrame(
            transmitSlot: 0, canID: 0x100, extended: false, canFD: true,
            data: [UInt8](repeating: 0, count: 9)
        )
    }
    #expect(throws: GsUsbProtocolError.unrepresentableDataLength(65)) {
        _ = try GsHostFrame(
            transmitSlot: 0, canID: 0x100, extended: false, canFD: true,
            data: [UInt8](repeating: 0, count: 65)
        )
    }
}

/// CAN FD has no remote-request frame: the RTR position is the reserved RRS
/// bit and must be dominant. There is nothing to encode here.
@Test func aCanFDTransmitFrameCannotBeARemoteRequest() throws {
    let error = #expect(throws: GsUsbProtocolError.self) {
        _ = try GsHostFrame(
            transmitSlot: 0, canID: 0x100, extended: false,
            remoteRequest: true, canFD: true, data: []
        )
    }
    guard case .contradictoryFrameFlags(let message) = error else {
        Issue.record("expected contradictoryFrameFlags, got \(String(describing: error))")
        return
    }
    #expect(message.contains("remote-request"))
}

@Test func aClassicalTransmitFrameCannotSwitchTheBitRate() throws {
    let error = #expect(throws: GsUsbProtocolError.self) {
        _ = try GsHostFrame(
            transmitSlot: 0, canID: 0x100, extended: false,
            bitRateSwitch: true, data: []
        )
    }
    guard case .contradictoryFrameFlags(let message) = error else {
        Issue.record("expected contradictoryFrameFlags, got \(String(describing: error))")
        return
    }
    #expect(message.contains("data phase"))
}

/// A decoded frame must survive re-encoding byte for byte, including the
/// timestamp word. Anything less means the decoder is discarding wire state.
@Test func decodedFrameRoundTripsBackToTheSameBytes() throws {
    let classical = hostFrameBytes(
        echoID: 5, rawCanID: 0x8000_0000 | 0x1AB_CDEF, dlc: 4,
        channel: 1, flags: 1 << 0, reserved: 0,
        data: [0x11, 0x22, 0x33, 0x44]
    )
    #expect(try GsHostFrame(decoding: classical).encoded(as: .classical) == classical)

    let timestamped = hostFrameBytes(
        rawCanID: 0x2AA, dlc: 1, data: [0x5A], timestampMicroseconds: 0xFFFF_FFF0
    )
    let frame = try GsHostFrame(decoding: timestamped)
    #expect(frame.encoded(as: .classicalWithTimestamp) == timestamped)

    let fd = hostFrameBytes(
        echoID: 7, rawCanID: 0x4FF, dlc: 13, flags: fdFlag | brsFlag | esiFlag,
        data: [UInt8](repeating: 0xC3, count: 32),
        timestampMicroseconds: 0x0001_0203
    )
    #expect(try GsHostFrame(decoding: fd).encoded(as: .canFDWithTimestamp) == fd)
}
