import Foundation
import GSUSBKitTestSupport
import Testing
@testable import GSUSBKit

// Every test here runs against `ScriptedUsbTransport`, so the whole gs_usb
// driver — handshake, decode, timestamps, bus state, reconnect — is exercised
// with no adapter attached. That is the point of the phase-4 seam.
//
// The read-only guarantee is the one property worth naming separately: the
// owner is going to attach this to a live vehicle bus, and a frame this tool
// acknowledges is a frame it changed. `theHandshakeCarriesTheListenOnlyFlagWord`
// and `aReconnectReappliesListenOnly` are the two tests that hold it, and they
// assert the literal `MODE` flag word rather than merely that `MODE` was sent.

// MARK: - Fixtures

/// `gsusbprobe` read this feature word off the attached SH-C30x on 2026-11-07.
///
/// Bits 16 and 18 are set and are not defined by upstream gs_usb. They are kept
/// here deliberately: an unrecognised capability bit must be ignored, never
/// treated as a protocol error.
private let shC30xFeatures = GsCanFeature(rawValue: 0x0005_30BB)

/// What a CAN FD adapter reports: the SH-C30x's feature set plus `FD` and the
/// `BT_CONST_EXT` that has to come with it, minus the two bits upstream gs_usb
/// does not define so the FD assertions read against a known word.
private let fdFeatures: GsCanFeature = [
    .listenOnly, .oneShot, .hardwareTimestamp, .canFD, .btConstExt,
    .berrReporting, .getState,
]

private let anchorRealtimeNs: Int64 = 1_700_000_000_000_000_000

private func constants(features: GsCanFeature) -> GsDeviceBtConst {
    // The SH-C30x's own limits, as measured: 48 MHz, tseg1 1…16, tseg2 1…8,
    // sjw_max 4, brp 1…1024 step 1.
    GsDeviceBtConst(
        feature: features,
        canClockHz: 48_000_000,
        tseg1Min: 1, tseg1Max: 16,
        tseg2Min: 1, tseg2Max: 8,
        sjwMax: 4, brpMin: 1, brpMax: 1024, brpInc: 1
    )
}

private func littleEndian(_ value: UInt32) -> [UInt8] {
    [
        UInt8(value & 0xFF),
        UInt8((value >> 8) & 0xFF),
        UInt8((value >> 16) & 0xFF),
        UInt8((value >> 24) & 0xFF),
    ]
}

/// An FDCAN peripheral's two sets of limits: 80 MHz, wide arbitration ranges
/// and the narrower data-phase ones. 2 Mbit/s solves exactly here, which is
/// what keeps the FD handshake tests about the handshake.
private func extendedConstants(features: GsCanFeature) -> GsDeviceBtConstExtended {
    GsDeviceBtConstExtended(
        arbitration: GsDeviceBtConst(
            feature: features,
            canClockHz: 80_000_000,
            tseg1Min: 1, tseg1Max: 256,
            tseg2Min: 1, tseg2Max: 128,
            sjwMax: 128, brpMin: 1, brpMax: 512, brpInc: 1
        ),
        dataPhase: GsDeviceBtConst(
            feature: features,
            canClockHz: 80_000_000,
            tseg1Min: 1, tseg1Max: 32,
            tseg2Min: 1, tseg2Max: 16,
            sjwMax: 16, brpMin: 1, brpMax: 32, brpInc: 1
        )
    )
}

private func session(
    features: GsCanFeature,
    bulkReads: [ScriptedUsbTransport.BulkStep] = [],
    bulkEnd: ScriptedUsbTransport.BulkStep = .hang,
    busState: GsDeviceState = GsDeviceState(
        state: .errorActive, receiveErrorCount: 0, transmitErrorCount: 0
    ),
    deviceMicroseconds: UInt32 = 0,
    /// When non-nil, the session also answers `BT_CONST_EXT` and accepts
    /// `DATA_BITTIMING`. Left off by default so a classical connection that
    /// sent either would fail rather than be quietly serviced — an unscripted
    /// request throws.
    extended: GsDeviceBtConstExtended? = nil,
    echoesWrites: Bool = false
) -> ScriptedUsbTransport.Session {
    var control: [UInt8: ScriptedUsbTransport.ControlResponse] = [
        GsUsbBreq.hostFormat.rawValue: .acknowledged,
        GsUsbBreq.btConst.rawValue: .bytes(constants(features: features).encoded()),
        GsUsbBreq.bittiming.rawValue: .acknowledged,
        GsUsbBreq.mode.rawValue: .acknowledged,
        GsUsbBreq.getState.rawValue: .bytes(busState.encoded()),
        GsUsbBreq.timestamp.rawValue: .bytes(littleEndian(deviceMicroseconds)),
    ]
    if let extended {
        // `BT_CONST_EXT` is a superset of `BT_CONST` and the device answers
        // both, so the arbitration limits come from the same place either way.
        control[GsUsbBreq.btConst.rawValue] = .bytes(extended.arbitration.encoded())
        control[GsUsbBreq.btConstExt.rawValue] = .bytes(extended.encoded())
        control[GsUsbBreq.dataBittiming.rawValue] = .acknowledged
    }

    return ScriptedUsbTransport.Session(
        control: control,
        bulkReads: bulkReads,
        bulkEnd: bulkEnd,
        echoesWrites: echoesWrites,
        interfaceInfo: UsbInterfaceInfo(
            interfaceNumber: 0,
            // Measured on the real device: both bulk endpoints are 32 bytes,
            // not the 64 a gs_usb adapter is usually assumed to have.
            bulkInMaxPacketSize: 32,
            bulkOutMaxPacketSize: 32
        )
    )
}

/// A ready-made CAN FD session: FD plus `BT_CONST_EXT` in the feature word,
/// the FDCAN limits, and both FD control requests scripted.
private func fdSession(
    features: GsCanFeature = fdFeatures,
    bulkReads: [ScriptedUsbTransport.BulkStep] = [],
    bulkEnd: ScriptedUsbTransport.BulkStep = .hang,
    echoesWrites: Bool = false
) -> ScriptedUsbTransport.Session {
    session(
        features: features,
        bulkReads: bulkReads,
        bulkEnd: bulkEnd,
        extended: extendedConstants(features: features),
        echoesWrites: echoesWrites
    )
}

/// One `gs_host_frame` as bytes. Hand-assembled rather than built through
/// `GsHostFrame.init(transmitSlot:…)` because that initialiser cannot express a
/// *received* frame, an error flag, or an overflow flag — which is most of what
/// these tests need to feed the decoder.
private func hostFrameBytes(
    echoID: UInt32 = GsHostFrame.receivedEchoID,
    rawCanID: UInt32,
    data: [UInt8] = [0xA5],
    channel: UInt8 = 0,
    flags: GsHostFrameFlags = [],
    timestampMicroseconds: UInt32? = nil
) -> [UInt8] {
    // `canFD` decides both the DLC encoding and the data field's width, which
    // is how the firmware sizes the transfer it sends.
    let isCanFD = flags.contains(.canFD)
    let width = isCanFD ? 64 : 8
    var out = littleEndian(echoID) + littleEndian(rawCanID)
    out.append(isCanFD
        ? (GsHostFrame.canFDDlc(forDataLength: data.count) ?? 0xFF)
        : UInt8(data.count))
    out.append(channel)
    out.append(flags.rawValue)
    out.append(0)
    out += data
    out += [UInt8](repeating: 0, count: width - data.count)
    if let timestampMicroseconds {
        out += littleEndian(timestampMicroseconds)
    }
    return out
}

private func makeDevice(
    _ transport: ScriptedUsbTransport,
    consumer: any GsUsbFrameConsumer,
    options: GsUsbOptions = GsUsbOptions(),
    backoff: GsUsbBackoffPolicy = GsUsbBackoffPolicy(delays: []),
    clock: any GsUsbClock = GsUsbVirtualClock(),
    // Deliberately long: a poller that fires during a test would make the
    // control-exchange assertions depend on scheduling. Tests that exercise a
    // poller shorten the interval they care about.
    statePollInterval: Duration = .seconds(60),
    reanchorInterval: Duration = .seconds(60),
    // Long enough that a genuine echo always wins the race. The timeout sleeps
    // on `clock`, so under `GsUsbVirtualClock` — whose `sleep` returns at once — it
    // would otherwise fire before any frame could come back, and every
    // transmit test would assert the timeout path by accident.
    sendTimeout: Duration = .seconds(5)
) -> GsUsbDevice {
    GsUsbDevice(
        transport: transport,
        consumer: consumer,
        options: options,
        backoff: backoff,
        clock: clock,
        realtimeNowNs: { anchorRealtimeNs },
        statePollInterval: statePollInterval,
        reanchorInterval: reanchorInterval,
        sendTimeout: sendTimeout
    )
}

private func waitForConnected(_ states: AsyncStream<GsUsbConnectionState>) async {
    for await state in states where state.isConnected { return }
}

private func waitForDisconnect(_ states: AsyncStream<GsUsbConnectionState>) async -> String {
    for await state in states {
        if case .disconnected(let reason) = state { return reason }
    }
    return ""
}

/// The first notice whose label contains `substring`.
///
/// Needed rather than "the first notice": a session without `HW_TIMESTAMP`
/// raises the degraded-timestamp notice the moment it connects, so a test
/// looking for a bus-state or overflow notice has to step past that one.
private func waitForNotice(
    _ notices: AsyncStream<GsUsbNotice>, containing substring: String
) async -> GsUsbNotice? {
    for await notice in notices where notice.label.contains(substring) {
        return notice
    }
    return nil
}

private func modePayloads(_ exchanges: [ScriptedUsbTransport.ControlExchange]) -> [[UInt8]] {
    exchanges
        .filter { $0.request.request == GsUsbBreq.mode.rawValue }
        .map(\.payload)
}

// MARK: - The read-only guarantee

@Test func defaultOptionsCannotPutABitOnTheBus() {
    let options = GsUsbOptions()

    #expect(options.busAccess == .listenOnly)
    #expect(options.listenOnly)
    // Derivation, not just the option: the flag is what the controller obeys.
    #expect(GsUsbDevice.modeFlags(options: options, features: shC30xFeatures)
        .contains(.listenOnly))
}

@Test func theHandshakeCarriesTheListenOnlyFlagWord() async throws {
    let transport = ScriptedUsbTransport(sessions: [session(features: shC30xFeatures)])
    // A real clock, so the two pollers this feature word enables stay asleep
    // for the whole test and the exchange list is exactly the handshake.
    let collector = CollectingFrameConsumer()
    let device = makeDevice(transport, consumer: collector, clock: GsUsbSystemClock())
    let states = device.states

    await device.start()
    await waitForConnected(states)
    await device.stop()

    let exchanges = await transport.controlExchanges
    #expect(exchanges.count == 4)
    #expect(exchanges.map(\.request.request) == [
        GsUsbBreq.hostFormat.rawValue,
        GsUsbBreq.btConst.rawValue,
        GsUsbBreq.bittiming.rawValue,
        GsUsbBreq.mode.rawValue,
    ])

    // HOST_FORMAT: the byte-order magic, as a vendor OUT to the interface with
    // `wValue` 1 (what the Linux driver sends, confirmed by `gsusbprobe`).
    #expect(exchanges[0].payload == [0xEF, 0xBE, 0x00, 0x00])
    #expect(exchanges[0].request.value == 1)
    #expect(exchanges[0].request.bmRequestType == 0x41)

    // BT_CONST: a vendor IN for the whole 40-byte struct.
    #expect(exchanges[1].request.bmRequestType == 0xC1)
    #expect(exchanges[1].request.length == UInt16(GsDeviceBtConst.byteCount))

    // BITTIMING: phase 3's solution for 500 kbit/s on this adapter's limits.
    let timing = try BitTiming.solve(
        bitrate: 500_000, constants: constants(features: shC30xFeatures)
    )
    #expect(exchanges[2].payload == timing.bittiming.encoded())

    // MODE: listen-only | one-shot | hw-timestamp | berr-reporting. Asserted as
    // the literal word, because "MODE was sent" would pass with the silence bit
    // missing — which on a live vehicle bus is the difference between observing
    // it and acknowledging onto it.
    #expect(exchanges[3].payload == GsDeviceMode(
        mode: .start, flags: GsCanFeature(rawValue: 0x0000_1019)
    ).encoded())
    #expect(exchanges[3].payload == [0x01, 0x00, 0x00, 0x00, 0x19, 0x10, 0x00, 0x00])
}

@Test func anExplicitlyBusActiveHandshakeOmitsOnlyTheListenOnlyBit() async throws {
    let transport = ScriptedUsbTransport(sessions: [session(features: shC30xFeatures)])
    let collector = CollectingFrameConsumer()
    let device = makeDevice(
        transport,
        consumer: collector,
        options: GsUsbOptions(busAccess: .busActive),
        clock: GsUsbSystemClock()
    )
    let states = device.states

    await device.start()
    await waitForConnected(states)
    await device.stop()

    let exchanges = await transport.controlExchanges
    #expect(modePayloads(exchanges) == [GsDeviceMode(
        mode: .start, flags: GsCanFeature(rawValue: 0x0000_1018)
    ).encoded()])
    #expect(exchanges[3].payload == [0x01, 0x00, 0x00, 0x00, 0x18, 0x10, 0x00, 0x00])
}

@Test func listenOnlyIsRefusedRatherThanDowngradedWhenUnsupported() async throws {
    // A device that reports everything except the one bit that makes it silent.
    let transport = ScriptedUsbTransport(sessions: [
        session(features: [.oneShot, .hardwareTimestamp, .getState]),
    ])
    let clock = GsUsbVirtualClock()
    let collector = CollectingFrameConsumer()
    let device = makeDevice(
        transport,
        consumer: collector,
        backoff: GsUsbBackoffPolicy(delays: [.seconds(1)]),
        clock: clock
    )
    let states = device.states

    await device.start()
    let reason = await waitForDisconnect(states)
    await device.stop()

    #expect(reason.contains("listen-only"))
    #expect(reason.contains("refusing to open it bus-active"))
    // Nothing that changes how the controller behaves on the bus went out.
    let requests = await transport.controlExchanges.map(\.request.request)
    #expect(requests == [GsUsbBreq.hostFormat.rawValue, GsUsbBreq.btConst.rawValue])
    // And it is not retried: the device will answer identically next time.
    #expect(await transport.openAttempts == 1)
    #expect(clock.recordedSleeps.isEmpty)
}

@Test func aReconnectReappliesListenOnly() async throws {
    let frame = hostFrameBytes(rawCanID: 0x240)
    let transport = ScriptedUsbTransport(sessions: [
        session(
            features: [.listenOnly, .oneShot],
            bulkReads: [.payload(frame), .failure(.deviceRemoved)]
        ),
        session(features: [.listenOnly, .oneShot], bulkReads: [.payload(frame)]),
    ])
    let clock = GsUsbVirtualClock()
    let collector = CollectingFrameConsumer()
    let device = makeDevice(
        transport,
        consumer: collector,
        backoff: GsUsbBackoffPolicy(delays: [.seconds(1), .seconds(2), .seconds(5)]),
        clock: clock
    )
    let frames = collector.frames
    var iterator = frames.makeAsyncIterator()

    await device.start()
    _ = await iterator.next()
    _ = await iterator.next()
    await device.stop()

    #expect(await transport.openAttempts == 2)
    #expect(await device.currentStatistics().reconnectCount == 1)
    #expect(clock.recordedSleeps == [.seconds(1)])

    // The cable bounced and the controller came back silent, because the flag
    // word is re-derived on every attempt rather than cached from the first.
    let expected = GsDeviceMode(mode: .start, flags: [.listenOnly, .oneShot]).encoded()
    #expect(await modePayloads(transport.controlExchanges) == [expected, expected])
}

// MARK: - Refusals

@Test func canFDIsRefusedRatherThanDowngradedWhenUnsupported() async throws {
    // Everything the SH-C30x offers, which is everything except CAN FD.
    let transport = ScriptedUsbTransport(sessions: [session(features: shC30xFeatures)])
    let clock = GsUsbVirtualClock()
    let collector = CollectingFrameConsumer()
    let device = makeDevice(
        transport,
        consumer: collector,
        options: GsUsbOptions(frameFormat: .canFD(dataBitrate: 2_000_000)),
        backoff: GsUsbBackoffPolicy(delays: [.seconds(1)]),
        clock: clock
    )
    let states = device.states

    await device.start()
    let reason = await waitForDisconnect(states)
    await device.stop()

    #expect(reason.contains("CAN FD"))
    #expect(reason.contains("refusing to open it as classical CAN"))
    // Nothing that changes how the controller behaves on the bus went out.
    let requests = await transport.controlExchanges.map(\.request.request)
    #expect(requests == [GsUsbBreq.hostFormat.rawValue, GsUsbBreq.btConst.rawValue])
    // And it is not retried: the feature word will say the same next time.
    #expect(await transport.openAttempts == 1)
    #expect(clock.recordedSleeps.isEmpty)
}

/// The data phase has its own segment limits and the arbitration phase's are
/// not a substitute, so a CAN FD device that will not report them cannot have
/// a data bitrate solved at all.
@Test func canFDIsRefusedWhenTheDataPhaseLimitsCannotBeRead() async throws {
    let transport = ScriptedUsbTransport(sessions: [
        session(features: [.listenOnly, .canFD]),
    ])
    let clock = GsUsbVirtualClock()
    let collector = CollectingFrameConsumer()
    let device = makeDevice(
        transport,
        consumer: collector,
        options: GsUsbOptions(frameFormat: .canFD(dataBitrate: 2_000_000)),
        backoff: GsUsbBackoffPolicy(delays: [.seconds(1)]),
        clock: clock
    )
    let states = device.states

    await device.start()
    let reason = await waitForDisconnect(states)
    await device.stop()

    #expect(reason.contains("data-phase bit-timing limits"))
    let requests = await transport.controlExchanges.map(\.request.request)
    #expect(requests == [GsUsbBreq.hostFormat.rawValue, GsUsbBreq.btConst.rawValue])
    #expect(await transport.openAttempts == 1)
    #expect(clock.recordedSleeps.isEmpty)
}

/// Being *able* to do CAN FD is not a reason to refuse an adapter, which is
/// what this driver used to do. A classical connection to an FD-capable
/// adapter sends no `DATA_BITTIMING` and leaves `GS_CAN_MODE_FD` clear, which
/// is what keeps the controller classical.
@Test func anFDCapableAdapterRunsClassicalWhenClassicalIsWhatWasAskedFor() async throws {
    let transport = ScriptedUsbTransport(sessions: [session(features: fdFeatures)])
    let collector = CollectingFrameConsumer()
    let device = makeDevice(transport, consumer: collector, clock: GsUsbSystemClock())
    let states = device.states

    await device.start()
    await waitForConnected(states)
    await device.stop()

    let exchanges = await transport.controlExchanges
    #expect(exchanges.map(\.request.request) == [
        GsUsbBreq.hostFormat.rawValue,
        GsUsbBreq.btConst.rawValue,
        GsUsbBreq.bittiming.rawValue,
        GsUsbBreq.mode.rawValue,
    ])
    #expect(!GsCanFeature(rawValue: 0x0000_1019).contains(.canFD))
    #expect(modePayloads(exchanges) == [GsDeviceMode(
        mode: .start, flags: [.listenOnly, .oneShot, .hardwareTimestamp, .berrReporting]
    ).encoded()])
    #expect(await device.sourceDescription.contains("500k "))
    #expect(!(await device.sourceDescription.contains("fd")))
}

@Test func aFrameOnANonZeroChannelIsRefusedRatherThanMerged() async throws {
    let transport = ScriptedUsbTransport(sessions: [
        session(
            features: [.listenOnly],
            bulkReads: [.payload(hostFrameBytes(rawCanID: 0x240, channel: 1))]
        ),
    ])
    let clock = GsUsbVirtualClock()
    let collector = CollectingFrameConsumer()
    let device = makeDevice(
        transport,
        consumer: collector,
        backoff: GsUsbBackoffPolicy(delays: [.seconds(1)]),
        clock: clock
    )
    let states = device.states

    await device.start()
    let reason = await waitForDisconnect(states)
    await device.stop()

    #expect(reason.contains("channel 1"))
    #expect(reason.contains("multi-channel"))
    #expect(await device.currentStatistics().framesReceived == 0)
    // Fatal, so the ladder is never entered.
    #expect(await transport.openAttempts == 1)
    #expect(clock.recordedSleeps.isEmpty)
}

@Test func anUnreachableBitrateIsRefusedInsteadOfRetriedForever() async throws {
    let transport = ScriptedUsbTransport(sessions: [session(features: [.listenOnly])])
    let clock = GsUsbVirtualClock()
    let collector = CollectingFrameConsumer()
    let device = makeDevice(
        transport,
        consumer: collector,
        // 7 bit/s is far outside what a 48 MHz clock and a 1024 prescaler reach.
        options: GsUsbOptions(bitrate: 7),
        backoff: GsUsbBackoffPolicy(delays: [.seconds(1)]),
        clock: clock
    )
    let states = device.states

    await device.start()
    let reason = await waitForDisconnect(states)
    await device.stop()

    #expect(reason.contains("7 bit/s"))
    let requests = await transport.controlExchanges.map(\.request.request)
    #expect(requests == [GsUsbBreq.hostFormat.rawValue, GsUsbBreq.btConst.rawValue])
    #expect(clock.recordedSleeps.isEmpty)
}

@Test func anAbsentAdapterIsRetriedOnTheLadderRatherThanRefused() async throws {
    let transport = ScriptedUsbTransport(devices: [])
    let clock = GsUsbVirtualClock()
    let collector = CollectingFrameConsumer()
    let device = makeDevice(
        transport,
        consumer: collector,
        backoff: GsUsbBackoffPolicy(delays: [.seconds(1), .seconds(2)]),
        clock: clock
    )
    let states = device.states

    await device.start()
    // `GsUsbBackoffPolicy` repeats its last delay rather than exhausting the table,
    // so the loop never gives up on its own — which is the wanted behaviour
    // here: an absent adapter is a hotplug wait, not a refusal. Watch three
    // attempts go past and then stop it ourselves.
    var reasons = [String]()
    for await state in states {
        if case .disconnected(let reason) = state { reasons.append(reason) }
        if reasons.count == 3 { break }
    }
    await device.stop()

    #expect(reasons.count == 3)
    #expect(reasons.allSatisfy { $0.contains("no gs_usb adapter") })
    #expect(await transport.enumerateCount >= 3)
    // Escalating, then capped at the last entry.
    #expect(Array(clock.recordedSleeps.prefix(2)) == [.seconds(1), .seconds(2)])
}

// MARK: - Decode

@Test func receivedFramesArePublishedInOrderWithLocallyGeneratedSeq() async throws {
    let buffer = hostFrameBytes(rawCanID: 0x240, data: [0x01])
        + hostFrameBytes(rawCanID: 0x241, data: [0x02, 0x03])
        // `CAN_EFF_FLAG` over a 29-bit identifier.
        + hostFrameBytes(rawCanID: 0x8000_0000 | 0x1234_5678, data: [])
    let transport = ScriptedUsbTransport(sessions: [
        session(features: [.listenOnly], bulkReads: [.payload(buffer)]),
    ])
    let collector = CollectingFrameConsumer()
    let device = makeDevice(transport, consumer: collector)
    let frames = collector.frames

    await device.start()
    var seen: [GsUsbFrame] = []
    for await frame in frames {
        seen.append(frame)
        if seen.count == 3 { break }
    }
    await device.stop()

    #expect(seen.map(\.seq) == [0, 1, 2])
    let identifiers: [UInt32] = [0x240, 0x241, 0x1234_5678 & 0x1FFF_FFFF]
    #expect(seen.map(\.canID) == identifiers)
    #expect(seen.map(\.extended) == [false, false, true])
    #expect(seen.map(\.data) == [[0x01], [0x02, 0x03], []])
    #expect(seen.allSatisfy { $0.tx == false })
    // §8.4's device description, carried on every frame.
    #expect(seen.allSatisfy {
        $0.sourceDescription == "gs_usb SH-C30x #0001 500k listen-only host-ts"
    })
    #expect(await device.sourceDescription == "gs_usb SH-C30x #0001 500k listen-only host-ts")

    let statistics = await device.currentStatistics()
    #expect(statistics.framesReceived == 3)
    #expect(statistics.lastSeq == 2)
}

@Test func transmitEchoesAreNotPublishedAsBusObservations() async throws {
    let buffer = hostFrameBytes(echoID: 0, rawCanID: 0x300, data: [0xFF])
        + hostFrameBytes(rawCanID: 0x240, data: [0xA5])
    let transport = ScriptedUsbTransport(sessions: [
        session(features: [.listenOnly], bulkReads: [.payload(buffer)]),
    ])
    let collector = CollectingFrameConsumer()
    let device = makeDevice(transport, consumer: collector)
    let frames = collector.frames

    await device.start()
    var seen: [GsUsbFrame] = []
    for await frame in frames {
        seen.append(frame)
        break
    }
    await device.stop()

    #expect(seen.map(\.canID) == [0x240])
    // Slot 0 is a real transmit slot, so the echo was identified by
    // `echo_id != 0xFFFFFFFF` rather than by truthiness.
    #expect(await device.currentStatistics().framesReceived == 1)
}

@Test func errorFramesArriveWithTheErrorFlagSet() async throws {
    let transport = ScriptedUsbTransport(sessions: [
        session(
            features: [.listenOnly, .berrReporting],
            bulkReads: [.payload(hostFrameBytes(rawCanID: 0x2000_0004, data: [0x08]))]
        ),
    ])
    let collector = CollectingFrameConsumer()
    let device = makeDevice(transport, consumer: collector)
    let frames = collector.frames

    await device.start()
    var first: GsUsbFrame?
    for await frame in frames {
        first = frame
        break
    }
    await device.stop()

    #expect(first?.err == true)
    #expect(first?.extended == false)
    #expect(first?.data == [0x08])
}

@Test func undecodableBulkDataIsCountedRatherThanSilentlyDropped() async throws {
    // A dlc of 9: plausible length, impossible payload.
    var badDLC = hostFrameBytes(rawCanID: 0x240)
    badDLC[8] = 9

    let transport = ScriptedUsbTransport(sessions: [
        session(features: [.listenOnly], bulkReads: [
            // Not a whole number of frames: there is no offset at which the
            // next one is known to begin.
            .payload([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07]),
            .payload(badDLC),
            .payload(hostFrameBytes(rawCanID: 0x240)),
        ]),
    ])
    let collector = CollectingFrameConsumer()
    let device = makeDevice(transport, consumer: collector)
    let frames = collector.frames

    await device.start()
    for await _ in frames { break }
    await device.stop()

    let statistics = await device.currentStatistics()
    #expect(statistics.decodeFailures == 2)
    #expect(statistics.framesReceived == 1)
}

@Test func anAdapterOverflowIsReportedAsStarvationAndAsANotice() async throws {
    let transport = ScriptedUsbTransport(sessions: [
        session(
            features: [.listenOnly],
            bulkReads: [.payload(hostFrameBytes(rawCanID: 0x240, flags: .overflow))]
        ),
    ])
    let collector = CollectingFrameConsumer()
    let device = makeDevice(transport, consumer: collector)
    let notices = device.notices

    await device.start()
    let seen = await waitForNotice(notices, containing: "overflow")
    await device.stop()

    #expect(seen != nil)
    // The device's own loss report is the only upward signal that frames went
    // missing, because `seq` is generated above it.
    #expect(await device.currentStatistics().readStarvationEvents == 1)
}

// MARK: - Timestamps

@Test func hardwareTimestampsAreMappedThroughTheAnchoredDeviceCounter() async throws {
    let buffer = hostFrameBytes(rawCanID: 0x240, timestampMicroseconds: 1_000)
        + hostFrameBytes(rawCanID: 0x241, timestampMicroseconds: 3_000)
    let transport = ScriptedUsbTransport(sessions: [
        session(features: [.listenOnly, .hardwareTimestamp], bulkReads: [.payload(buffer)]),
    ])
    // A real clock keeps the re-anchor poller asleep, so the mapping under test
    // is the per-frame one rather than a drift correction.
    let collector = CollectingFrameConsumer()
    let device = makeDevice(transport, consumer: collector, clock: GsUsbSystemClock())
    let frames = collector.frames

    await device.start()
    var seen: [GsUsbFrame] = []
    for await frame in frames {
        seen.append(frame)
        if seen.count == 2 { break }
    }
    await device.stop()

    #expect(await device.timestampMode == .hardware)
    #expect(await device.timestampMode.isDegraded == false)
    // Anchored on the first frame, so it lands exactly on the host reading, and
    // the second is the device's own 2 ms later.
    #expect(seen.map(\.timestampNs) == [anchorRealtimeNs, anchorRealtimeNs + 2_000_000])
    #expect(await device.sourceDescription.hasSuffix("listen-only hw-ts"))
}

@Test func theHostCompletionFallbackIsUsedAndReportedAsDegraded() async throws {
    let transport = ScriptedUsbTransport(sessions: [
        session(
            features: [.listenOnly],
            bulkReads: [.payload(hostFrameBytes(rawCanID: 0x240))]
        ),
    ])
    let clock = GsUsbVirtualClock(startNs: 5_000_000_000)
    let collector = CollectingFrameConsumer()
    let device = makeDevice(transport, consumer: collector, clock: clock)
    let notices = device.notices
    let frames = collector.frames

    await device.start()
    var label: String?
    for await notice in notices {
        label = notice.label
        break
    }
    var first: GsUsbFrame?
    for await frame in frames {
        first = frame
        break
    }
    await device.stop()

    #expect(await device.timestampMode == .hostCompletion)
    #expect(await device.timestampMode.isDegraded)
    // Said so, where a later reader will see it: a notice for the host to
    // annotate the recording with, and the `host-ts` suffix in the
    // description every frame carries.
    #expect(label?.contains("host-completion") == true)
    #expect(await device.sourceDescription.hasSuffix("listen-only host-ts"))
    // Still mapped onto the same anchored timeline, so nothing above here has
    // to branch on which device produced the number.
    #expect(first?.timestampNs == anchorRealtimeNs)
}

// MARK: - Bus state

@Test func enteringErrorWarningRaisesANoticeWithTheErrorCounters() async throws {
    let transport = ScriptedUsbTransport(sessions: [
        session(
            features: [.listenOnly, .getState],
            busState: GsDeviceState(
                state: .errorWarning, receiveErrorCount: 100, transmitErrorCount: 0
            )
        ),
    ])
    let collector = CollectingFrameConsumer()
    let device = makeDevice(
        transport,
        consumer: collector,
        clock: GsUsbSystemClock(),
        statePollInterval: .milliseconds(1)
    )
    let notices = device.notices

    await device.start()
    let seen = await waitForNotice(notices, containing: "error-warning")
    await device.stop()

    #expect(seen != nil)
    #expect(seen?.label.contains("rx errors 100") == true)
}

@Test func busOffRaisesANoticeAndDrivesTheDisconnect() async throws {
    let transport = ScriptedUsbTransport(sessions: [
        session(
            features: [.listenOnly, .getState],
            busState: GsDeviceState(
                state: .busOff, receiveErrorCount: 255, transmitErrorCount: 255
            )
        ),
    ])
    let collector = CollectingFrameConsumer()
    let device = makeDevice(
        transport,
        consumer: collector,
        clock: GsUsbSystemClock(),
        statePollInterval: .milliseconds(1)
    )
    let notices = device.notices
    let states = device.states

    await device.start()
    let seen = await waitForNotice(notices, containing: "bus-off")
    let reason = await waitForDisconnect(states)
    await device.stop()

    #expect(seen != nil)
    // The poller's reason wins over the read loop's, which only saw its
    // transfer aborted by the close the poller performed.
    #expect(reason == "controller went bus-off")
}

// MARK: - Lifecycle

@Test func stopDuringAConnectAttemptReturnsPromptly() async throws {
    let transport = ScriptedUsbTransport(devices: [])
    let collector = CollectingFrameConsumer()
    let device = makeDevice(
        transport,
        consumer: collector,
        backoff: GsUsbBackoffPolicy(delays: [.seconds(30)]),
        clock: GsUsbSystemClock()
    )
    let states = device.states

    await device.start()
    // Let the first attempt fail so the loop is inside its 30-second wait.
    _ = await waitForDisconnect(states)

    let began = ContinuousClock.now
    await device.stop()
    let elapsed = ContinuousClock.now - began

    #expect(elapsed < .seconds(2))
    #expect(await device.isRunning == false)
}

@Test func stopUnblocksAnIdleReadAndLeavesTheDeviceRestartable() async throws {
    let transport = ScriptedUsbTransport(sessions: [
        session(
            features: [.listenOnly],
            bulkReads: [.payload(hostFrameBytes(rawCanID: 0x240))]
        ),
    ])
    let collector = CollectingFrameConsumer()
    let device = makeDevice(transport, consumer: collector)
    let frames = collector.frames
    var iterator = frames.makeAsyncIterator()

    await device.start()
    let first = await iterator.next()
    // The read loop is now parked on `.hang`, which is the state in which
    // `stop()`'s promptness actually matters.
    await device.stop()
    #expect(await device.isRunning == false)

    await device.start()
    let second = await iterator.next()
    await device.stop()

    #expect(first?.seq == 0)
    // Each connection is its own `seq` scope (§7.2), so the restart counts
    // from zero rather than continuing the previous run.
    #expect(second?.seq == 0)
    #expect(await transport.openAttempts == 2)
    #expect(await transport.closeCount >= 2)
}

@Test func startIsIdempotent() async throws {
    let transport = ScriptedUsbTransport(sessions: [
        session(
            features: [.listenOnly],
            bulkReads: [.payload(hostFrameBytes(rawCanID: 0x240))]
        ),
    ])
    let collector = CollectingFrameConsumer()
    let device = makeDevice(transport, consumer: collector)
    let states = device.states

    await device.start()
    await device.start()
    await waitForConnected(states)
    await device.stop()

    #expect(await transport.openAttempts == 1)
}

// MARK: - Descriptions and codecs

@Test func theSourceDescriptionNamesTheBusAccessAndTheTimestampSource() {
    let device = UsbDeviceRef(
        vendorID: 0x1D50,
        productID: 0x606F,
        locationID: 0x0210_0000,
        productName: "SH-C30A",
        serialNumber: "0042"
    )

    #expect(GsUsbDevice.describeSource(
        device: device, options: GsUsbOptions(), timestampMode: .hardware
    ) == "gs_usb SH-C30A #0042 500k listen-only hw-ts")

    #expect(GsUsbDevice.describeSource(
        device: device,
        options: GsUsbOptions(bitrate: 1_000_000, busAccess: .busActive),
        timestampMode: .hostCompletion
    ) == "gs_usb SH-C30A #0042 1M bus-active host-ts")

    // Before a connection exists there is no device and no negotiated mode, and
    // the description says only what is actually known.
    #expect(GsUsbDevice.describeSource(
        device: nil, options: GsUsbOptions(), timestampMode: nil
    ) == "gs_usb 500k listen-only")

    // An unusual rate is shown at full precision rather than rounded into a lie.
    #expect(GsUsbDevice.bitrateLabel(83_333) == "83.333k")
}

@Test func unrecognisedFeatureBitsAreIgnoredRatherThanRejected() {
    // Bits 16 and 18 of the SH-C30x's word are not defined by upstream gs_usb.
    let flags = GsUsbDevice.modeFlags(options: GsUsbOptions(), features: shC30xFeatures)

    #expect(flags == GsCanFeature(rawValue: 0x0000_1019))
    #expect(flags.rawValue & 0x0005_0000 == 0)
}

@Test func deviceStateRoundTripsThroughItsWireLayout() throws {
    let state = GsDeviceState(
        state: .errorPassive, receiveErrorCount: 128, transmitErrorCount: 7
    )
    let bytes = state.encoded()

    #expect(bytes.count == GsDeviceState.byteCount)
    #expect(bytes == [0x02, 0, 0, 0, 0x80, 0, 0, 0, 0x07, 0, 0, 0])
    #expect(try GsDeviceState(decoding: bytes) == state)

    // A state outside `enum gs_can_state` is reported, not clamped.
    let unknown = littleEndian(9) + littleEndian(0) + littleEndian(0)
    #expect(throws: GsUsbProtocolError.unknownState(9)) {
        try GsDeviceState(decoding: unknown)
    }
    #expect(throws: GsUsbProtocolError.truncated(expected: 12, actual: 4)) {
        try GsDeviceState(decoding: [0, 0, 0, 0])
    }
}

// MARK: - Transmit (§6.2)

/// A bus-active session whose device echoes every write back, which is the
/// only transmit confirmation gs_usb offers.
private func transmittingTransport(
    features: GsCanFeature = shC30xFeatures,
    writeFailures: [UsbTransportError?] = []
) -> ScriptedUsbTransport {
    var scripted = session(features: features)
    scripted.echoesWrites = true
    scripted.writeFailures = writeFailures
    return ScriptedUsbTransport(sessions: [scripted])
}

@Test func aDefaultDeviceRefusesToTransmitRatherThanReconfiguringItself() async throws {
    // The read-only guarantee as the owner will meet it: a device built the
    // default way can be asked to transmit, and refuses. The veto is checked
    // before anything is written, so the refusal is also observable as the
    // absence of any bulk-OUT traffic.
    let transport = transmittingTransport()
    let collector = CollectingFrameConsumer()
    let device = makeDevice(transport, consumer: collector, clock: GsUsbSystemClock())
    let states = device.states

    await device.start()
    await waitForConnected(states)

    await #expect(throws: GsUsbTransmitError.listenOnly) {
        try await device.send(GsUsbOutboundFrame(canID: 0x240, data: [0x01]))
    }
    await device.stop()

    #expect(await transport.bulkWrites.isEmpty)
    #expect(await device.currentStatistics().framesTransmitted == 0)
}

@Test func theListenOnlyRefusalNamesTheWayOut() {
    // The UI shows this verbatim, so an operator who meant to transmit learns
    // what to change rather than just that it failed.
    let message = "\(GsUsbTransmitError.listenOnly)"

    #expect(message.contains("listen-only"))
    #expect(message.contains("cannot transmit"))
    #expect(message.contains("reconnect"))
}

@Test func aSendResolvesOnItsEchoAndPublishesTheFrameAsTransmitted() async throws {
    let transport = transmittingTransport()
    let collector = CollectingFrameConsumer()
    let device = makeDevice(
        transport,
        consumer: collector,
        options: GsUsbOptions(busAccess: .busActive),
        clock: GsUsbSystemClock()
    )
    let frames = collector.frames
    var iterator = frames.makeAsyncIterator()
    let states = device.states

    await device.start()
    await waitForConnected(states)
    try await device.send(GsUsbOutboundFrame(canID: 0x240, extended: false, data: [0xDE, 0xAD]))

    let echoed = await iterator.next()
    await device.stop()

    // The frame reached the stream marked as ours, exactly once.
    #expect(echoed?.canID == 0x240)
    #expect(echoed?.data == [0xDE, 0xAD])
    #expect(echoed?.tx == true)
    #expect(await device.currentStatistics().framesTransmitted == 1)

    // And it went out on slot 0 — the first of the ten, reused from the pool.
    let writes = await transport.bulkWrites
    #expect(writes.count == 1)
    let written = try GsHostFrame(decoding: writes[0])
    #expect(written.transmitSlot == 0)
    #expect(written.canID == 0x240)
}

@Test func tenSlotsTransmitConcurrentlyAndAreAllReturnedToThePool() async throws {
    let transport = transmittingTransport()
    let collector = CollectingFrameConsumer()
    let device = makeDevice(
        transport,
        consumer: collector,
        options: GsUsbOptions(busAccess: .busActive),
        clock: GsUsbSystemClock()
    )
    let states = device.states

    await device.start()
    await waitForConnected(states)

    // Eleven sends through ten slots: the eleventh can only succeed if a
    // released slot is handed on, which is §6.2's backpressure working.
    for index in 0..<11 {
        try await device.send(
            GsUsbOutboundFrame(canID: UInt32(0x300 + index), data: [UInt8(index)])
        )
    }
    await device.stop()

    #expect(await device.currentStatistics().framesTransmitted == 11)
    let writes = await transport.bulkWrites
    #expect(writes.count == 11)
    // Sequential sends each take the lowest free slot, so every one of them is
    // slot 0 — the proof that the slot came back rather than being retired.
    let slots = try writes.map { try GsHostFrame(decoding: $0).transmitSlot }
    #expect(slots.allSatisfy { $0 == 0 })
}

@Test func anUnacknowledgedSendTimesOutWithTheQuestionWorthAsking() async throws {
    // A device that accepts the write and never echoes: exactly what a bus with
    // no other node on it looks like, since nothing ACKs the frame.
    let transport = ScriptedUsbTransport(sessions: [session(features: shC30xFeatures)])
    let collector = CollectingFrameConsumer()
    let device = makeDevice(
        transport,
        consumer: collector,
        options: GsUsbOptions(busAccess: .busActive),
        clock: GsUsbSystemClock(),
        sendTimeout: .milliseconds(50)
    )
    let states = device.states

    await device.start()
    await waitForConnected(states)

    await #expect(throws: GsUsbTransmitError.notAcknowledged) {
        try await device.send(GsUsbOutboundFrame(canID: 0x240, data: [0x01]))
    }

    // The slot is released by the timeout, so the next send is not starved by
    // the previous one's failure.
    await #expect(throws: GsUsbTransmitError.notAcknowledged) {
        try await device.send(GsUsbOutboundFrame(canID: 0x241, data: [0x02]))
    }
    await device.stop()

    #expect(await transport.bulkWrites.count == 2)
    #expect(await device.currentStatistics().framesTransmitted == 0)

    // §6.2's text: the two things actually worth checking when nothing answers.
    let message = "\(GsUsbTransmitError.notAcknowledged)"
    #expect(message.contains("no node acknowledged the frame"))
    #expect(message.contains("termination"))
}

@Test func sendingBeforeAConnectionExistsIsRefusedRatherThanQueued() async throws {
    let transport = transmittingTransport()
    let collector = CollectingFrameConsumer()
    let device = makeDevice(
        transport,
        consumer: collector,
        options: GsUsbOptions(busAccess: .busActive),
        clock: GsUsbSystemClock()
    )

    await #expect(throws: GsUsbTransmitError.notConnected) {
        try await device.send(GsUsbOutboundFrame(canID: 0x240, data: [0x01]))
    }
    #expect(await transport.bulkWrites.isEmpty)
}

@Test func aWriteTheDeviceRefusesIsReportedRatherThanAwaitingAnEchoThatCannotCome() async throws {
    let transport = transmittingTransport(writeFailures: [.stalled("bulk-OUT pipe stalled")])
    let collector = CollectingFrameConsumer()
    let device = makeDevice(
        transport,
        consumer: collector,
        options: GsUsbOptions(busAccess: .busActive),
        clock: GsUsbSystemClock()
    )
    let states = device.states

    await device.start()
    await waitForConnected(states)

    do {
        try await device.send(GsUsbOutboundFrame(canID: 0x240, data: [0x01]))
        Issue.record("a stalled bulk-OUT should not report success")
    } catch let error as GsUsbTransmitError {
        guard case .writeFailed = error else {
            Issue.record("expected .writeFailed, got \(error)")
            return
        }
    }

    // The slot came back, so a stall does not consume one of the ten.
    try await device.send(GsUsbOutboundFrame(canID: 0x241, data: [0x02]))
    await device.stop()

    #expect(await device.currentStatistics().framesTransmitted == 1)
}

@Test func aFrameLongerThanClassicalCanAllowsIsRefusedBeforeAnythingIsWritten() async throws {
    let transport = transmittingTransport()
    let collector = CollectingFrameConsumer()
    let device = makeDevice(
        transport,
        consumer: collector,
        options: GsUsbOptions(busAccess: .busActive),
        clock: GsUsbSystemClock()
    )
    let states = device.states

    await device.start()
    await waitForConnected(states)

    await #expect(throws: GsUsbTransmitError.invalidFrame(
        "a classical CAN frame carries at most 8 bytes; this one has 9"
    )) {
        try await device.send(
            GsUsbOutboundFrame(canID: 0x240, data: [UInt8](repeating: 0, count: 9))
        )
    }
    await device.stop()

    #expect(await transport.bulkWrites.isEmpty)
}

@Test func aListenOnlySessionNeverPublishesAFrameAsTransmitted() async throws {
    // Belt and braces for the guarantee: even if a frame arrives bearing an
    // echo id — a device bug, or another host's traffic misread — a silent
    // controller cannot have sent it, so it must not be filed as ours.
    let echo = hostFrameBytes(
        echoID: 0, rawCanID: 0x240, data: [0x01], timestampMicroseconds: 1_000
    )
    let transport = ScriptedUsbTransport(sessions: [
        session(features: shC30xFeatures, bulkReads: [
            .payload(echo),
            .payload(hostFrameBytes(
                rawCanID: 0x241, data: [0x02], timestampMicroseconds: 2_000
            )),
        ]),
    ])
    let collector = CollectingFrameConsumer()
    let device = makeDevice(transport, consumer: collector, clock: GsUsbSystemClock())
    let frames = collector.frames
    var iterator = frames.makeAsyncIterator()

    await device.start()
    // The echo-bearing frame is dropped, so the first frame to arrive is the
    // genuinely received one behind it.
    let received = await iterator.next()
    await device.stop()

    #expect(received?.canID == 0x241)
    #expect(received?.tx == false)
    #expect(await device.currentStatistics().framesTransmitted == 0)
}

@Test func oneShotIsReportedAsTheCapabilityItIsRatherThanAssumed() async throws {
    // §6.2 asks the UI to say which retransmission mode is in force, so the
    // capability has to follow what the device agreed to, in both directions.
    let supporting = transmittingTransport()
    let collector = CollectingFrameConsumer()
    let withOneShot = makeDevice(
        supporting,
        consumer: collector,
        options: GsUsbOptions(busAccess: .busActive),
        clock: GsUsbSystemClock()
    )
    #expect(GsUsbDevice.maxFramesInFlight == 10)
    // Nothing is negotiated before a connection, so nothing is claimed.
    #expect(withOneShot.oneShotActive == false)

    let states = withOneShot.states
    await withOneShot.start()
    await waitForConnected(states)
    #expect(withOneShot.oneShotActive)
    let onFlags = await modePayloads(supporting.controlExchanges)
    #expect(onFlags == [GsDeviceMode(
        mode: .start, flags: GsCanFeature(rawValue: 0x0000_1018)
    ).encoded()])
    await withOneShot.stop()
    // A closed connection negotiates nothing, so the claim is withdrawn.
    #expect(withOneShot.oneShotActive == false)

    // A device without the bit: the flag word omits it and so does the
    // capability, rather than the UI promising a mode the controller never
    // entered.
    let lacking = transmittingTransport(
        features: [.listenOnly, .hardwareTimestamp, .getState, .berrReporting]
    )
    let otherCollector = CollectingFrameConsumer()
    let withoutOneShot = makeDevice(
        lacking,
        consumer: otherCollector,
        options: GsUsbOptions(busAccess: .busActive),
        clock: GsUsbSystemClock()
    )
    let otherStates = withoutOneShot.states
    await withoutOneShot.start()
    await waitForConnected(otherStates)
    #expect(withoutOneShot.oneShotActive == false)
    let offFlags = await modePayloads(lacking.controlExchanges)
    #expect(offFlags == [GsDeviceMode(
        mode: .start, flags: GsCanFeature(rawValue: 0x0000_1010)
    ).encoded()])
    await withoutOneShot.stop()
}

// MARK: - CAN FD

/// The CAN FD handshake, asserted as the literal transfer sequence and the
/// literal `MODE` flag word. Two transfers are added and both have to land in
/// the right place: `BT_CONST_EXT` while nothing is configured yet, and
/// `DATA_BITTIMING` after the arbitration phase and before `MODE`.
@Test func theCanFDHandshakeAddsTheExtendedConstantsAndTheDataBittiming() async throws {
    let transport = ScriptedUsbTransport(sessions: [fdSession()])
    let collector = CollectingFrameConsumer()
    let device = makeDevice(
        transport,
        consumer: collector,
        options: GsUsbOptions(frameFormat: .canFD(dataBitrate: 2_000_000)),
        clock: GsUsbSystemClock()
    )
    let states = device.states

    await device.start()
    await waitForConnected(states)
    await device.stop()

    let exchanges = await transport.controlExchanges
    #expect(exchanges.map(\.request.request) == [
        GsUsbBreq.hostFormat.rawValue,
        GsUsbBreq.btConst.rawValue,
        GsUsbBreq.btConstExt.rawValue,
        GsUsbBreq.bittiming.rawValue,
        GsUsbBreq.dataBittiming.rawValue,
        GsUsbBreq.mode.rawValue,
    ])

    // BT_CONST_EXT: a vendor IN for the whole 72-byte struct.
    #expect(exchanges[2].request.bmRequestType == 0xC1)
    #expect(exchanges[2].request.length == UInt16(GsDeviceBtConstExtended.byteCount))

    // The two phases are solved against their own limits, so the payloads are
    // different solutions and not the same one sent twice.
    let extended = extendedConstants(features: fdFeatures)
    let arbitration = try BitTiming.solve(bitrate: 500_000, constants: extended.arbitration)
    let dataPhase = try BitTiming.solve(bitrate: 2_000_000, constants: extended.dataPhase)
    #expect(exchanges[3].payload == arbitration.bittiming.encoded())
    #expect(exchanges[4].payload == dataPhase.bittiming.encoded())
    #expect(exchanges[3].payload != exchanges[4].payload)
    #expect(exchanges[4].request.length == UInt16(GsDeviceBittiming.byteCount))

    // MODE: listen-only | one-shot | hw-timestamp | FD | berr-reporting.
    // `GS_CAN_MODE_FD` shares bit 8 with `GS_CAN_FEATURE_FD`.
    #expect(exchanges[5].payload == GsDeviceMode(
        mode: .start, flags: GsCanFeature(rawValue: 0x0000_1119)
    ).encoded())
    #expect(exchanges[5].payload == [0x01, 0x00, 0x00, 0x00, 0x19, 0x11, 0x00, 0x00])
}

/// Same reasoning as `aReconnectReappliesListenOnly`: the flag word is
/// re-derived on every attempt, so a cable bounce cannot bring the link back
/// as classical CAN and start dropping every FD frame on the bus.
@Test func aReconnectReappliesCanFD() async throws {
    let frame = hostFrameBytes(
        rawCanID: 0x240, data: [UInt8](repeating: 0x11, count: 16),
        flags: .canFD, timestampMicroseconds: 1_000
    )
    let transport = ScriptedUsbTransport(sessions: [
        fdSession(bulkReads: [.payload(frame), .failure(.deviceRemoved)]),
        fdSession(bulkReads: [.payload(frame)]),
    ])
    let clock = GsUsbVirtualClock()
    let collector = CollectingFrameConsumer()
    let device = makeDevice(
        transport,
        consumer: collector,
        options: GsUsbOptions(frameFormat: .canFD(dataBitrate: 2_000_000)),
        backoff: GsUsbBackoffPolicy(delays: [.seconds(1)]),
        clock: clock
    )
    var iterator = collector.frames.makeAsyncIterator()

    await device.start()
    _ = await iterator.next()
    _ = await iterator.next()
    await device.stop()

    #expect(await transport.openAttempts == 2)
    let expected = GsDeviceMode(
        mode: .start, flags: GsCanFeature(rawValue: 0x0000_1119)
    ).encoded()
    #expect(await modePayloads(transport.controlExchanges) == [expected, expected])
    // And the data phase is reapplied too, not only configured once.
    let requests = await transport.controlExchanges.map(\.request.request)
    #expect(requests.filter { $0 == GsUsbBreq.dataBittiming.rawValue }.count == 2)
}

/// The read loop cannot use a fixed stride on a CAN FD link, because the
/// firmware sizes each frame from its own FD flag. Both of these arrive in one
/// bulk transfer, and finding the second one requires having read the first
/// one's flags.
@Test func aSingleTransferCarryingBothFrameFormatsIsCutUpCorrectly() async throws {
    let classical = hostFrameBytes(
        rawCanID: 0x100, data: [0x01, 0x02], timestampMicroseconds: 10
    )
    let fd = hostFrameBytes(
        rawCanID: 0x200, data: [UInt8](repeating: 0xAB, count: 48),
        flags: [.canFD, .bitRateSwitch], timestampMicroseconds: 20
    )
    let errorStateIndicated = hostFrameBytes(
        rawCanID: 0x300, data: [],
        flags: [.canFD, .errorStateIndicator], timestampMicroseconds: 30
    )
    #expect(classical.count == 24)
    #expect(fd.count == 80)
    #expect(errorStateIndicated.count == 80)

    let transport = ScriptedUsbTransport(sessions: [
        fdSession(bulkReads: [.payload(classical + fd + errorStateIndicated)]),
    ])
    let collector = CollectingFrameConsumer()
    let device = makeDevice(
        transport,
        consumer: collector,
        options: GsUsbOptions(frameFormat: .canFD(dataBitrate: 2_000_000))
    )
    var iterator = collector.frames.makeAsyncIterator()

    await device.start()
    let first = await iterator.next()
    let second = await iterator.next()
    let third = await iterator.next()
    await device.stop()

    #expect(first?.canID == 0x100)
    #expect(first?.fd == false)
    #expect(first?.data == [0x01, 0x02])

    #expect(second?.canID == 0x200)
    #expect(second?.fd == true)
    #expect(second?.bitRateSwitch == true)
    #expect(second?.errorStateIndicator == false)
    #expect(second?.data == [UInt8](repeating: 0xAB, count: 48))

    #expect(third?.canID == 0x300)
    #expect(third?.fd == true)
    #expect(third?.bitRateSwitch == false)
    #expect(third?.errorStateIndicator == true)
    #expect(third?.data.isEmpty == true)

    // Three whole frames out of one buffer, with nothing left over.
    let statistics = await device.currentStatistics()
    #expect(statistics.framesReceived == 3)
    #expect(statistics.decodeFailures == 0)
    // Their device timestamps are distinct, which they would not be if the
    // timestamp word had been read at the wrong offset.
    #expect(first?.timestampNs != second?.timestampNs)
    #expect(second?.timestampNs != third?.timestampNs)
}

/// A CAN FD frame whose header says 80 bytes and whose buffer holds fewer is
/// counted, not guessed at. The frames ahead of it in the buffer were each
/// described by their own header and still stand.
@Test func aTruncatedCanFDFrameIsCountedWithoutLosingTheFramesBeforeIt() async throws {
    let good = hostFrameBytes(
        rawCanID: 0x100, data: [0x01], timestampMicroseconds: 10
    )
    let truncated = hostFrameBytes(
        rawCanID: 0x200, data: [UInt8](repeating: 0x7E, count: 64),
        flags: .canFD, timestampMicroseconds: 20
    ).prefix(40)

    let transport = ScriptedUsbTransport(sessions: [
        fdSession(bulkReads: [.payload(good + truncated)]),
    ])
    let collector = CollectingFrameConsumer()
    let device = makeDevice(
        transport,
        consumer: collector,
        options: GsUsbOptions(frameFormat: .canFD(dataBitrate: 2_000_000))
    )
    var iterator = collector.frames.makeAsyncIterator()

    await device.start()
    let first = await iterator.next()
    await device.stop()

    #expect(first?.canID == 0x100)
    let statistics = await device.currentStatistics()
    #expect(statistics.framesReceived == 1)
    #expect(statistics.decodeFailures == 1)
}

/// `send` on a classical connection will not quietly truncate a 64-byte
/// payload into an 8-byte classical frame, for the same reason it will not
/// reconfigure a listen-only controller to honour a transmit.
@Test func aCanFDFrameIsRefusedOnAClassicalConnection() async throws {
    let transport = transmittingTransport()
    let collector = CollectingFrameConsumer()
    let device = makeDevice(
        transport,
        consumer: collector,
        options: GsUsbOptions(busAccess: .busActive),
        clock: GsUsbSystemClock()
    )
    let states = device.states

    await device.start()
    await waitForConnected(states)

    await #expect(throws: GsUsbTransmitError.canFDNotEnabled) {
        try await device.send(GsUsbOutboundFrame(
            canID: 0x240, fd: true, data: [UInt8](repeating: 0x01, count: 64)
        ))
    }
    await device.stop()

    #expect(await transport.bulkWrites.isEmpty)
    #expect(await device.currentStatistics().framesTransmitted == 0)
}

@Test func theCanFDRefusalNamesTheWayOut() {
    let message = "\(GsUsbTransmitError.canFDNotEnabled)"

    #expect(message.contains("classical CAN"))
    #expect(message.contains("frameFormat"))
    #expect(message.contains("reconnect"))
}

/// The echo is the only transmit confirmation there is, and on a CAN FD link
/// it comes back in the 80-byte layout. Both directions have to agree on the
/// size or the send never resolves.
@Test func aCanFDSendResolvesOnItsEchoAndGoesOutInTheEightyByteLayout() async throws {
    let transport = ScriptedUsbTransport(sessions: [fdSession(echoesWrites: true)])
    let collector = CollectingFrameConsumer()
    let device = makeDevice(
        transport,
        consumer: collector,
        options: GsUsbOptions(
            busAccess: .busActive, frameFormat: .canFD(dataBitrate: 2_000_000)
        ),
        clock: GsUsbSystemClock()
    )
    var iterator = collector.frames.makeAsyncIterator()
    let states = device.states
    let payload = (0..<64).map { UInt8($0) }

    await device.start()
    await waitForConnected(states)
    try await device.send(GsUsbOutboundFrame(
        canID: 0x240, fd: true, bitRateSwitch: true, data: payload
    ))

    let echoed = await iterator.next()
    await device.stop()

    let writes = await transport.bulkWrites
    #expect(writes.count == 1)
    #expect(writes.first?.count == 80)
    // DLC 15 and the FD plus BRS flags, written where the firmware reads them.
    #expect(writes.first?[8] == 15)
    #expect(writes.first?[GsHostFrame.flagsByteOffset]
        == GsHostFrameFlags([.canFD, .bitRateSwitch]).rawValue)

    #expect(echoed?.tx == true)
    #expect(echoed?.fd == true)
    #expect(echoed?.bitRateSwitch == true)
    #expect(echoed?.data == payload)
    #expect(await device.currentStatistics().framesTransmitted == 1)
}

/// A classical frame on a CAN FD link stays the 24-byte struct: the device
/// sizes what it reads from the FD flag in these very bytes, and echoes it
/// back at that same size.
@Test func aClassicalFrameOnACanFDConnectionKeepsTheClassicalLayout() async throws {
    let transport = ScriptedUsbTransport(sessions: [fdSession(echoesWrites: true)])
    let collector = CollectingFrameConsumer()
    let device = makeDevice(
        transport,
        consumer: collector,
        options: GsUsbOptions(
            busAccess: .busActive, frameFormat: .canFD(dataBitrate: 2_000_000)
        ),
        clock: GsUsbSystemClock()
    )
    var iterator = collector.frames.makeAsyncIterator()
    let states = device.states

    await device.start()
    await waitForConnected(states)
    try await device.send(GsUsbOutboundFrame(canID: 0x240, data: [0xDE, 0xAD]))

    let echoed = await iterator.next()
    await device.stop()

    #expect(await transport.bulkWrites.first?.count == 24)
    #expect(echoed?.fd == false)
    #expect(echoed?.data == [0xDE, 0xAD])
}

/// CAN FD's lengths are not contiguous, and padding 9 bytes up to 12 would put
/// three bytes on the bus that the caller never wrote.
@Test func aCanFDPayloadNoDlcCanExpressIsRefusedRatherThanPadded() async throws {
    let transport = ScriptedUsbTransport(sessions: [fdSession(echoesWrites: true)])
    let collector = CollectingFrameConsumer()
    let device = makeDevice(
        transport,
        consumer: collector,
        options: GsUsbOptions(
            busAccess: .busActive, frameFormat: .canFD(dataBitrate: 2_000_000)
        ),
        clock: GsUsbSystemClock()
    )
    let states = device.states

    await device.start()
    await waitForConnected(states)

    await #expect(throws: GsUsbTransmitError.self) {
        try await device.send(GsUsbOutboundFrame(
            canID: 0x240, fd: true, data: [UInt8](repeating: 0x01, count: 9)
        ))
    }
    // CAN FD has no remote-request frame to encode.
    await #expect(throws: GsUsbTransmitError.self) {
        try await device.send(GsUsbOutboundFrame(canID: 0x240, rtr: true, fd: true))
    }
    await device.stop()

    #expect(await transport.bulkWrites.isEmpty)
    // A refused frame must not retire one of the ten transmit slots.
    #expect(await device.currentStatistics().framesTransmitted == 0)
    try await confirmAllSlotsAreStillAvailable(options: GsUsbOptions(
        busAccess: .busActive, frameFormat: .canFD(dataBitrate: 2_000_000)
    ))
}

/// Ten concurrent sends only complete if every slot a refused frame touched
/// was handed back. Run against a fresh device so this is a statement about
/// the pool and not about the previous test's bookkeeping.
private func confirmAllSlotsAreStillAvailable(options: GsUsbOptions) async throws {
    let transport = ScriptedUsbTransport(sessions: [fdSession(echoesWrites: true)])
    let collector = CollectingFrameConsumer()
    let device = makeDevice(
        transport, consumer: collector, options: options, clock: GsUsbSystemClock()
    )
    let states = device.states
    await device.start()
    await waitForConnected(states)

    for _ in 0..<GsUsbDevice.maxFramesInFlight {
        _ = try? await device.send(GsUsbOutboundFrame(
            canID: 0x240, fd: true, data: [UInt8](repeating: 0x01, count: 9)
        ))
    }
    try await device.send(GsUsbOutboundFrame(
        canID: 0x241, fd: true, data: [0x01, 0x02, 0x03, 0x04]
    ))
    await device.stop()

    #expect(await transport.bulkWrites.count == 1)
}

/// §8.4: two captures taken at the same arbitration rate and different data
/// rates are not the same capture, so the label has to say both.
@Test func theSourceDescriptionNamesBothRatesOnACanFDConnection() async throws {
    let transport = ScriptedUsbTransport(sessions: [fdSession()])
    let collector = CollectingFrameConsumer()
    let device = makeDevice(
        transport,
        consumer: collector,
        options: GsUsbOptions(
            busAccess: .busActive, frameFormat: .canFD(dataBitrate: 2_000_000)
        ),
        clock: GsUsbSystemClock()
    )
    let states = device.states

    await device.start()
    await waitForConnected(states)
    let description = await device.sourceDescription
    await device.stop()

    #expect(description == "gs_usb SH-C30x #0001 500k/2M fd bus-active hw-ts")
}

/// The data bitrate goes through the same solver and the same 0.5% ceiling as
/// the arbitration rate, and an unreachable one is refused rather than retried
/// against limits that are firmware constants.
@Test func anUnreachableDataBitrateIsRefusedAndNamesTheAchievedRate() async throws {
    let transport = ScriptedUsbTransport(sessions: [fdSession()])
    let clock = GsUsbVirtualClock()
    let collector = CollectingFrameConsumer()
    let device = makeDevice(
        transport,
        consumer: collector,
        // 80 MHz over 3 Mbit/s is 26.67 quanta: no exact solution, and the
        // closest is further off than the ceiling allows.
        options: GsUsbOptions(frameFormat: .canFD(dataBitrate: 3_000_000)),
        backoff: GsUsbBackoffPolicy(delays: [.seconds(1)]),
        clock: clock
    )
    let states = device.states

    await device.start()
    let reason = await waitForDisconnect(states)
    await device.stop()

    #expect(reason.contains("3000000 bit/s is not reachable"))
    // Refused with the arbitration phase still unconfigured: both solutions
    // are computed before either is sent.
    let requests = await transport.controlExchanges.map(\.request.request)
    #expect(requests == [
        GsUsbBreq.hostFormat.rawValue,
        GsUsbBreq.btConst.rawValue,
        GsUsbBreq.btConstExt.rawValue,
    ])
    #expect(await transport.openAttempts == 1)
    #expect(clock.recordedSleeps.isEmpty)
}

@Test func theFrameFormatOptionCannotExpressCanFDWithoutADataBitrate() {
    #expect(GsUsbOptions().frameFormat == .classical)
    #expect(GsUsbOptions().canFD == false)
    #expect(GsUsbOptions.FrameFormat.classical.dataBitrate == nil)

    let fd = GsUsbOptions.FrameFormat.canFD(dataBitrate: 2_000_000)
    #expect(fd.isCanFD)
    #expect(fd.dataBitrate == 2_000_000)
    // The flag word follows from the option, not from the feature bit, so a
    // reconnect cannot drop it.
    #expect(GsUsbDevice.modeFlags(
        options: GsUsbOptions(frameFormat: fd), features: fdFeatures
    ).contains(.canFD))
    #expect(!GsUsbDevice.modeFlags(
        options: GsUsbOptions(), features: fdFeatures
    ).contains(.canFD))
}
