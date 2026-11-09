import Foundation
import Testing
import GSUSBKitTestSupport
@testable import GSUSBKit

// `ScriptedUsbTransport` is the only thing standing between the gs_usb driver
// and an adapter, so every later phase's correctness is conditional on this
// double behaving as scripted. That makes the double itself worth testing: a
// bug here does not fail, it passes, in phase 5's tests and phase 7's.

// MARK: - Fixtures

private let btConstBytes = GsDeviceBtConst(
    feature: [.listenOnly, .loopBack, .oneShot, .hardwareTimestamp, .identify],
    canClockHz: 48_000_000,
    tseg1Min: 1, tseg1Max: 16,
    tseg2Min: 1, tseg2Max: 8,
    sjwMax: 4, brpMin: 1, brpMax: 1024, brpInc: 1
).encoded()

private let deviceConfigBytes = GsDeviceConfig(
    interfaceCountMinusOne: 0,
    softwareVersion: 2,
    hardwareVersion: 1
).encoded()

private func btConstRequest(interface: UInt8 = 0) -> UsbControlRequest {
    .vendorInterfaceIn(
        request: GsUsbBreq.btConst.rawValue,
        value: 0,
        interface: interface,
        length: GsDeviceBtConst.byteCount
    )
}

private func modeRequest(interface: UInt8 = 0) -> UsbControlRequest {
    .vendorInterfaceOut(
        request: GsUsbBreq.mode.rawValue,
        value: 0,
        interface: interface,
        length: GsDeviceMode.byteCount
    )
}

private func openedTransport(_ session: ScriptedUsbTransport.Session) async throws -> ScriptedUsbTransport {
    let transport = ScriptedUsbTransport(sessions: [session])
    _ = try await transport.open(ScriptedUsbTransport.defaultDevice)
    return transport
}

// MARK: - enumerate

@Test func enumerateReturnsTheScriptedDevicesAndCountsTheCall() async throws {
    let extra = UsbDeviceRef(vendorID: 0x1D50, productID: 0x606F, locationID: 0x1400_0000)
    let transport = ScriptedUsbTransport(devices: [ScriptedUsbTransport.defaultDevice, extra])

    let found = try await transport.enumerate()

    #expect(found == [ScriptedUsbTransport.defaultDevice, extra])
    #expect(await transport.enumerateCount == 1)
}

@Test func enumerateCanBeScriptedToReturnNothing() async throws {
    let transport = ScriptedUsbTransport(devices: [])
    #expect(try await transport.enumerate().isEmpty)
}

@Test func enumerateFailureThrows() async throws {
    let transport = ScriptedUsbTransport(enumerateFailure: .deviceNotFound)

    await #expect(throws: UsbTransportError.deviceNotFound) {
        _ = try await transport.enumerate()
    }
}

// MARK: - open

@Test func openRecordsTheDeviceAndReturnsTheSessionsInterfaceInfo() async throws {
    let info = UsbInterfaceInfo(interfaceNumber: 2, bulkInMaxPacketSize: 64, bulkOutMaxPacketSize: 32)
    let transport = ScriptedUsbTransport(sessions: [.init(interfaceInfo: info)])

    let returned = try await transport.open(ScriptedUsbTransport.defaultDevice)

    #expect(returned == info)
    #expect(await transport.openedDevices == [ScriptedUsbTransport.defaultDevice])
    #expect(await transport.openAttempts == 1)
}

/// The §3.1 gate's unhappy path, which is the reason `openFailed` carries a
/// message rather than being a bare case.
@Test func scriptedOpenFailuresAreConsumedInOrderThenOpenSucceeds() async throws {
    let transport = ScriptedUsbTransport(
        openFailures: [.openFailed("no entitlement"), nil, .deviceNotFound]
    )

    await #expect(throws: UsbTransportError.openFailed("no entitlement")) {
        _ = try await transport.open(ScriptedUsbTransport.defaultDevice)
    }
    _ = try await transport.open(ScriptedUsbTransport.defaultDevice)
    await #expect(throws: UsbTransportError.deviceNotFound) {
        _ = try await transport.open(ScriptedUsbTransport.defaultDevice)
    }
    // Past the end of the script, opens succeed.
    _ = try await transport.open(ScriptedUsbTransport.defaultDevice)

    #expect(await transport.openAttempts == 4)
    #expect(await transport.openedDevices.count == 2)
}

/// The shape phase 5's hotplug test needs: one session dies, the next is well.
@Test func successiveOpensAdvanceSessionsAndTheLastOneRepeats() async throws {
    let transport = ScriptedUsbTransport(sessions: [
        .init(bulkReads: [.payload([0x01])], bulkEnd: .failure(.deviceRemoved)),
        .init(bulkReads: [.payload([0x02])], bulkEnd: .failure(.timedOut)),
    ])

    _ = try await transport.open(ScriptedUsbTransport.defaultDevice)
    #expect(try await transport.bulkRead() == [0x01])
    await #expect(throws: UsbTransportError.deviceRemoved) { _ = try await transport.bulkRead() }

    _ = try await transport.open(ScriptedUsbTransport.defaultDevice)
    #expect(try await transport.bulkRead() == [0x02])

    // Third open has no third session, so the second repeats from the top.
    _ = try await transport.open(ScriptedUsbTransport.defaultDevice)
    #expect(try await transport.bulkRead() == [0x02])
    await #expect(throws: UsbTransportError.timedOut) { _ = try await transport.bulkRead() }
}

// MARK: - controlTransfer

@Test func controlTransferReturnsTheBytesScriptedForItsRequestCode() async throws {
    let transport = try await openedTransport(.init(control: [
        GsUsbBreq.btConst.rawValue: .bytes(btConstBytes),
        GsUsbBreq.deviceConfig.rawValue: .bytes(deviceConfigBytes),
    ]))

    let returned = try await transport.controlTransfer(btConstRequest(), payload: [])

    #expect(returned == btConstBytes)
    #expect(try GsDeviceBtConst(decoding: returned).canClockHz == 48_000_000)
}

/// Responses are keyed on `bRequest` rather than position, so interleaving a
/// poll between two handshake steps does not disturb either.
@Test func controlResponsesAreKeyedOnRequestCodeNotCallOrder() async throws {
    let transport = try await openedTransport(.init(control: [
        GsUsbBreq.btConst.rawValue: .bytes(btConstBytes),
        GsUsbBreq.deviceConfig.rawValue: .bytes(deviceConfigBytes),
    ]))

    _ = try await transport.controlTransfer(btConstRequest(), payload: [])
    let config = try await transport.controlTransfer(
        .vendorInterfaceIn(
            request: GsUsbBreq.deviceConfig.rawValue,
            value: 1,
            interface: 0,
            length: GsDeviceConfig.byteCount
        ),
        payload: []
    )
    let again = try await transport.controlTransfer(btConstRequest(), payload: [])

    #expect(config == deviceConfigBytes)
    #expect(again == btConstBytes)
}

/// This recording is what phase 5 asserts its handshake against, so the order
/// and the payload bytes both have to survive.
@Test func everyControlTransferIsRecordedInOrderWithItsPayload() async throws {
    let transport = try await openedTransport(.init(control: [
        GsUsbBreq.btConst.rawValue: .bytes(btConstBytes),
        GsUsbBreq.mode.rawValue: .acknowledged,
    ]))
    let modePayload = GsDeviceMode(mode: .start, flags: [.hardwareTimestamp]).encoded()

    _ = try await transport.controlTransfer(btConstRequest(), payload: [])
    _ = try await transport.controlTransfer(modeRequest(), payload: modePayload)

    let exchanges = await transport.controlExchanges
    #expect(exchanges.count == 2)
    #expect(exchanges[0].request == btConstRequest())
    #expect(exchanges[0].payload.isEmpty)
    #expect(exchanges[1].request == modeRequest())
    #expect(exchanges[1].payload == modePayload)
}

@Test func anAcknowledgedOutReturnsNoDataPhase() async throws {
    let transport = try await openedTransport(.init(control: [
        GsUsbBreq.mode.rawValue: .acknowledged,
    ]))

    #expect(try await transport.controlTransfer(modeRequest(), payload: [1, 2, 3]).isEmpty)
}

/// Returning empty here instead of throwing would let a phase-5 test pass
/// against a handshake step nobody scripted, which is the exact failure this
/// double exists to prevent.
@Test func anUnscriptedControlRequestThrows() async throws {
    let transport = try await openedTransport(.init(control: [:]))

    await #expect(throws: UsbTransportError.self) {
        _ = try await transport.controlTransfer(btConstRequest(), payload: [])
    }
}

@Test func aScriptedControlFailureThrows() async throws {
    let transport = try await openedTransport(.init(control: [
        GsUsbBreq.mode.rawValue: .failure(.stalled("endpoint halted")),
    ]))

    await #expect(throws: UsbTransportError.stalled("endpoint halted")) {
        _ = try await transport.controlTransfer(modeRequest(), payload: [])
    }
}

/// Firmware older than the struct being read: the short reply is its own case
/// so a caller can say so rather than reporting a generic transfer failure.
@Test func aReplyShorterThanWLengthIsAShortTransfer() async throws {
    let transport = try await openedTransport(.init(control: [
        GsUsbBreq.btConst.rawValue: .bytes(Array(btConstBytes.prefix(24))),
    ]))

    await #expect(throws: UsbTransportError.shortTransfer(expected: 40, actual: 24)) {
        _ = try await transport.controlTransfer(btConstRequest(), payload: [])
    }
}

@Test func controlTransferBeforeOpenIsNotOpen() async throws {
    let transport = ScriptedUsbTransport()

    await #expect(throws: UsbTransportError.notOpen) {
        _ = try await transport.controlTransfer(btConstRequest(), payload: [])
    }
}

// MARK: - bulkRead

@Test func bulkReadsArriveInScriptedOrderThenHitTheEndBehaviour() async throws {
    let transport = try await openedTransport(.init(
        bulkReads: [.payload([0xAA]), .payload([0xBB]), .payload([0xCC])],
        bulkEnd: .failure(.deviceRemoved)
    ))

    #expect(try await transport.bulkRead() == [0xAA])
    #expect(try await transport.bulkRead() == [0xBB])
    #expect(try await transport.bulkRead() == [0xCC])
    await #expect(throws: UsbTransportError.deviceRemoved) { _ = try await transport.bulkRead() }
    // The end behaviour repeats rather than being consumed.
    await #expect(throws: UsbTransportError.deviceRemoved) { _ = try await transport.bulkRead() }
}

/// Surprise removal, a halted endpoint and a timeout are the three failures
/// phase 5 has to tell apart, injected through the one `.failure` mechanism.
@Test(arguments: [
    UsbTransportError.deviceRemoved,
    UsbTransportError.stalled("halted"),
    UsbTransportError.timedOut,
])
func anInjectedBulkFailureSurfacesAsItself(_ injected: UsbTransportError) async throws {
    let transport = try await openedTransport(.init(bulkReads: [.payload([0x01]), .failure(injected)]))

    #expect(try await transport.bulkRead() == [0x01])
    await #expect(throws: injected) { _ = try await transport.bulkRead() }
}

@Test func bulkReadBeforeOpenIsNotOpen() async throws {
    let transport = ScriptedUsbTransport()

    await #expect(throws: UsbTransportError.notOpen) { _ = try await transport.bulkRead() }
}

// MARK: - bulkWrite

@Test func bulkWritesAreRecordedInOrder() async throws {
    let transport = try await openedTransport(.init())

    try await transport.bulkWrite([0x01, 0x02])
    try await transport.bulkWrite([0x03])

    #expect(await transport.bulkWrites == [[0x01, 0x02], [0x03]])
}

@Test func anInjectedWriteFailureThrowsAndIsNotRecorded() async throws {
    let transport = try await openedTransport(.init(writeFailures: [nil, .stalled("tx halted")]))

    try await transport.bulkWrite([0x01])
    await #expect(throws: UsbTransportError.stalled("tx halted")) {
        try await transport.bulkWrite([0x02])
    }
    try await transport.bulkWrite([0x03])

    #expect(await transport.bulkWrites == [[0x01], [0x03]])
}

@Test func bulkWriteBeforeOpenIsNotOpen() async throws {
    let transport = ScriptedUsbTransport()

    await #expect(throws: UsbTransportError.notOpen) { try await transport.bulkWrite([0x01]) }
}

// MARK: - close

/// The property the rest of the plan leans on. A real bulk-IN on an idle bus
/// never completes on its own; `close()` aborting the pipe is the only thing
/// that resumes the parked reader, and `IOUSBHostTransport` orders its teardown
/// specifically to preserve that. A double that returned `.notOpen` without
/// ever blocking would make phase 5's `stop()`-during-read test pass whether or
/// not the real transport got the ordering right.
@Test func closeUnblocksAParkedBulkRead() async throws {
    let transport = try await openedTransport(.init(bulkEnd: .hang))

    let reader = Task { try await transport.bulkRead() }
    // Let the reader reach the continuation before closing.
    for _ in 0..<32 { await Task.yield() }

    await transport.close()

    await #expect(throws: UsbTransportError.deviceRemoved) { _ = try await reader.value }
    #expect(await transport.closeCount == 1)
}

@Test func aReadAfterCloseIsNotOpen() async throws {
    let transport = try await openedTransport(.init(bulkReads: [.payload([0x01])]))

    #expect(try await transport.bulkRead() == [0x01])
    await transport.close()

    await #expect(throws: UsbTransportError.notOpen) { _ = try await transport.bulkRead() }
}

@Test func closeIsIdempotentAndCounted() async throws {
    let transport = try await openedTransport(.init())

    await transport.close()
    await transport.close()

    #expect(await transport.closeCount == 2)
}

/// Reopening after a close restarts the next session's read script from the
/// top, which is what makes a reconnect test's second connection observable.
@Test func reopeningAfterCloseRewindsTheReadCursor() async throws {
    let transport = ScriptedUsbTransport(sessions: [
        .init(bulkReads: [.payload([0x01]), .payload([0x02])], bulkEnd: .failure(.deviceRemoved)),
    ])

    _ = try await transport.open(ScriptedUsbTransport.defaultDevice)
    #expect(try await transport.bulkRead() == [0x01])
    await transport.close()

    _ = try await transport.open(ScriptedUsbTransport.defaultDevice)
    #expect(try await transport.bulkRead() == [0x01])
}
