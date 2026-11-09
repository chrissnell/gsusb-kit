import Foundation
import GSUSBKit

// The instrument for design §6's decision gate, and the only way any line of
// `IOUSBHostTransport` gets executed — no test on any machine can reach that
// file, so this executable is the verification step that replaces one.
//
// It answers four questions a human needs answered before phase 5 can be
// written, and it answers them by doing the least that can produce an answer:
// enumerate, open, two control reads, print, close. It never sets a mode, never
// writes to the bus, and never puts the adapter into a state that outlives it.
//
//   1. Does an unentitled, hardened-runtime process get an `IOUSBHostInterface`
//      open? That is the §3.1 go/no-go; a failure here sends the project to
//      §4.3's `IOUSBLib` fallback behind the same protocol.
//   2. Is `GS_CAN_FEATURE_HW_TIMESTAMP` present? Phase 6's `TimestampMapper`
//      is only reachable if it is.
//   3. Is `GS_CAN_FEATURE_ONE_SHOT` present? It decides what TX retry means.
//   4. What are `fclk_can` and the segment limits? Phase 7 computes bit timing
//      from exactly those numbers, and guessing them is how you get an adapter
//      that joins the bus and corrupts every frame on it.

// MARK: - Output helpers

func heading(_ text: String) {
    print("")
    print(text)
    print(String(repeating: "─", count: text.count))
}

func field(_ label: String, _ value: String) {
    print("  \(label.padding(toLength: 22, withPad: " ", startingAt: 0)) \(value)")
}

/// gs_usb packs version numbers as a plain integer, but every other tool that
/// talks to these adapters prints them as `major.minor`, so this one does too.
func version(_ raw: UInt32) -> String {
    "\(raw >> 16).\(raw & 0xFFFF) (0x\(String(format: "%08x", raw)))"
}

func megahertz(_ hz: UInt32) -> String {
    String(format: "%.3f MHz", Double(hz) / 1_000_000)
}

// MARK: - Feature table
//
// Every bit, named, with present/absent shown for all of them rather than only
// the ones that are set. An absent feature is as much of a finding as a present
// one — "no HW_TIMESTAMP" is the answer that deletes a phase — and a list that
// only prints what is set cannot say the difference between "absent" and "I did
// not check".

let featureBits: [(GsCanFeature, String)] = [
    (.listenOnly, "LISTEN_ONLY"),
    (.loopBack, "LOOP_BACK"),
    (.tripleSample, "TRIPLE_SAMPLE"),
    (.oneShot, "ONE_SHOT"),
    (.hardwareTimestamp, "HW_TIMESTAMP"),
    (.identify, "IDENTIFY"),
    (.userID, "USER_ID"),
    (.padPacketsToMaxPacketSize, "PAD_PKTS_TO_MAX_PKT_SIZE"),
    (.canFD, "FD"),
    (.requiresUsbQuirkLpc546xx, "REQ_USB_QUIRK_LPC546XX"),
    (.btConstExt, "BT_CONST_EXT"),
    (.termination, "TERMINATION"),
    (.berrReporting, "BERR_REPORTING"),
    (.getState, "GET_STATE"),
]

// MARK: - Probe

func probe() async -> Int32 {
    let transport = IOUSBHostTransport()

    heading("Enumerating")
    let devices: [UsbDeviceRef]
    do {
        devices = try await transport.enumerate()
    } catch {
        print("  FAILED: \(error)")
        return 1
    }

    guard let device = devices.first else {
        print("  No 1d50:606f device found.")
        print("")
        print("  Plug in a candleLight-class adapter and try again. If one is")
        print("  attached, check `ioreg -p IOUSB -l | grep -i idProduct` — a")
        print("  device claimed by another driver will not appear here.")
        return 1
    }

    for (index, found) in devices.enumerated() {
        let marker = index == 0 ? "→" : " "
        print("  \(marker) \(found.identity)  location 0x\(String(format: "%08x", found.locationID))"
            + "  \(found.productName ?? "<no product string>")"
            + "  serial \(found.serialNumber ?? "<none>")")
    }
    if devices.count > 1 {
        print("")
        print("  \(devices.count) adapters present; probing the first.")
    }

    // §3.1's go/no-go. Everything after this line is only reachable if the
    // answer is "yes".
    heading("Opening the vendor interface (design §3.1 gate)")
    let info: UsbInterfaceInfo
    do {
        info = try await transport.open(device)
    } catch {
        print("  DENIED: \(error)")
        print("")
        print("  This is the §3.1 no-go. An unentitled process could not claim")
        print("  the interface, so the native IOUSBHost path is not viable as")
        print("  built and §4.3's IOUSBLib transport is the fallback — behind")
        print("  this same UsbDeviceTransport protocol, so nothing above the")
        print("  seam changes.")
        return 2
    }
    print("  GRANTED — unentitled open succeeded.")
    field("bInterfaceNumber", "\(info.interfaceNumber)")
    field("bulk IN wMaxPacket", "\(info.bulkInMaxPacketSize) bytes")
    field("bulk OUT wMaxPacket", "\(info.bulkOutMaxPacketSize) bytes")

    var status: Int32 = 0

    // GET_DEVICE_CONFIG. wValue is 1, not the channel index — the Linux driver
    // does the same, and the firmware ignores it either way.
    heading("GET_DEVICE_CONFIG (bRequest \(GsUsbBreq.deviceConfig.rawValue))")
    do {
        let bytes = try await transport.controlTransfer(
            .vendorInterfaceIn(
                request: GsUsbBreq.deviceConfig.rawValue,
                value: 1,
                interface: info.interfaceNumber,
                length: GsDeviceConfig.byteCount
            ),
            payload: []
        )
        let config = try GsDeviceConfig(decoding: bytes)
        field("channels", "\(config.channelCount)")
        field("sw_version", version(config.softwareVersion))
        field("hw_version", version(config.hardwareVersion))
    } catch {
        print("  FAILED: \(error)")
        status = 3
    }

    heading("GET_BT_CONST (bRequest \(GsUsbBreq.btConst.rawValue), channel 0)")
    do {
        let bytes = try await transport.controlTransfer(
            .vendorInterfaceIn(
                request: GsUsbBreq.btConst.rawValue,
                value: 0,
                interface: info.interfaceNumber,
                length: GsDeviceBtConst.byteCount
            ),
            payload: []
        )
        let constants = try GsDeviceBtConst(decoding: bytes)

        print("  Features (raw 0x\(String(format: "%08x", constants.feature.rawValue))):")
        for (bit, name) in featureBits {
            let present = constants.feature.contains(bit)
            print("    [\(present ? "x" : " ")] \(name)")
        }

        print("")
        print("  Timing:")
        field("fclk_can", "\(constants.canClockHz) Hz (\(megahertz(constants.canClockHz)))")
        field("tseg1", "\(constants.tseg1Min) … \(constants.tseg1Max)")
        field("tseg2", "\(constants.tseg2Min) … \(constants.tseg2Max)")
        field("sjw_max", "\(constants.sjwMax)")
        field("brp", "\(constants.brpMin) … \(constants.brpMax) step \(constants.brpInc)")

        print("")
        print("  Decision gate (plan §6):")
        field("§3.1 unentitled open", "GO")
        field("HW_TIMESTAMP", constants.feature.contains(.hardwareTimestamp)
            ? "present — phase 6 TimestampMapper applies"
            : "ABSENT — host-clock timestamps only")
        field("ONE_SHOT", constants.feature.contains(.oneShot)
            ? "present — TX retry is configurable"
            : "ABSENT — the controller always retries")
        field("BT_CONST_EXT", constants.feature.contains(.btConstExt)
            ? "present — data bit timing readable"
            : "absent")
    } catch {
        print("  FAILED: \(error)")
        status = 3
    }

    heading("Closing")
    await transport.close()
    print("  Interface released.")

    return status
}

exit(await probe())
