# GSUSBKit

Talk to a CAN bus from your Mac in Swift, using a cheap USB adapter and no
kernel extension.

Pulled out of [canopener](https://github.com/chrissnell/canopener), where it
runs against a live vehicle bus.

## If you've never touched CAN before

CAN is the network inside your car. Also most motorcycles, boats, tractors and
factory equipment. It's two wires, and everything on it — engine controller,
dashboard, ABS — broadcasts short messages called *frames*. A frame is an ID
(up to 29 bits, says what the message is) plus up to 8 bytes of data. There's
no addressing and no master. Everyone shouts, everyone hears everything.

The adapters below are small USB dongles that bridge that bus to your Mac. They
all speak the same open USB protocol, `gs_usb`, which comes from the
[candleLight](https://github.com/candle-usb/candleLight_fw) firmware project —
that's why a handful of differently-branded dongles are interchangeable here.

This library handles the USB side and hands you decoded, timestamped frames.

## Adapters

| Adapter | Status |
|---|---|
| DSD TECH SH-C30A | Tested — this is what development ran against |
| DSD TECH SH-C31A | Same firmware, should be identical |
| CANable / CANable 2.0 | Expected to work, flashed with candleLight firmware (not the stock slcan firmware) |
| candleLight | Expected to work |
| CANtact / CANtact Pro | Expected to work |
| budgetcan | Expected to work |

Only the SH-C30A has actually been on the end of a cable here. The rest run the
same firmware and should behave the same, but I haven't verified them — if you
try one, let me know how it goes.

Got an adapter that isn't listed? Open System Information → USB. If it shows up
with vendor ID `0x1D50` and product ID `0x606F`, it's running candleLight
firmware and this library will drive it.

**Classical CAN only.** CAN FD — the faster, 64-byte-payload successor — isn't
supported, and neither are adapters with more than one CAN port. Both are
refused during the connect handshake rather than half-configured and hoped for.

## Requirements

macOS 15 or later, Swift 6. Nothing to install on the system side: no kext, no
driver package, no special entitlement. It talks to the adapter through
`IOUSBHost`, which is plain user-space API.

```swift
.package(url: "https://github.com/chrissnell/gsusb-kit.git", from: "0.1.0")
```

## Reading frames

You give the device something to hand frames to, then start it.

```swift
import GSUSBKit

struct Printer: GsUsbFrameConsumer {
    func consume(_ frame: GsUsbFrame) async {
        print(frame.timestampNs, String(frame.canID, radix: 16), frame.data)
    }
}

let device = GsUsbDevice(
    transport: IOUSBHostTransport(),
    consumer: Printer(),
    options: GsUsbOptions(bitrate: 500_000)
)

// Connection state: idle, connecting, connected, disconnected.
Task { for await state in device.states { print(state) } }

// Things worth telling the user about — degraded timestamps, dropped frames.
Task { for await notice in device.notices { print(notice.label) } }

await device.start()
```

500 kbit/s is the common vehicle rate and the default. The device finds the
adapter, connects, and reconnects by itself if the cable is pulled.

**Call `stop()` when you're done.** A running device's background task holds a
strong reference to it, so just dropping your reference doesn't shut it down —
you'd leak the device, the claimed USB interface and the read loop.

```swift
await device.stop()
```

## It can't transmit unless you ask it to

By default this library sets the adapter up so it is *physically incapable* of
affecting the bus. That's worth explaining, because it's not just a safety flag
somebody added.

On CAN, acknowledgement is part of the wire protocol. Every controller that
hears a valid frame yanks the bus low to say "got it" — that's not optional
politeness, it's how the protocol works. And if a controller doesn't like what
it sees, it transmits an error flag that deliberately corrupts that frame for
*everyone* on the bus. So a CAN adapter that comes up in normal mode is already
participating the instant you plug it in. On a car that's actually running,
that's a real way to cause trouble.

Listen-only mode puts the controller in a state where it never drives the wires
at all. No acknowledgements, no error frames, no retransmissions. You see
everything; the bus can't see you.

That's the default:

```swift
GsUsbOptions(bitrate: 500_000)              // listen-only, silent
GsUsbOptions(bitrate: 500_000, busAccess: .busActive)   // a real node
```

It's an enum and not a `Bool` so that going live has to be written out at the
call site. `busAccess: .busActive` reads like a decision. `listenOnly: false`
reads like a parameter somebody forgot.

A few consequences:

- `send` on a listen-only connection throws `GsUsbTransmitError.listenOnly`. It
  will not quietly reconfigure the controller to do what you asked.
- An adapter that claims it can't do listen-only is refused, rather than opened
  bus-active as a fallback.
- The mode is re-applied on every reconnect, so a cable bounce can't bring the
  adapter back up live.

## Sending frames

Once you're bus-active:

```swift
try await device.send(GsUsbOutboundFrame(canID: 0x123, data: [0x01, 0x02]))
```

## How frames get to you

You implement `GsUsbFrameConsumer` and the device calls `consume(_:)` once per
frame, in arrival order. That's instead of handing you an `AsyncStream` to
iterate, which is the more obvious Swift choice — here's why it isn't the one.

When you transmit, the adapter echoes your frame back to you, and that echo is
how you know it really went out on the wire. `send` waits for it. The useful
part is the ordering: your consumer is handed the echo *before* `send` returns.
So after this line,

```swift
try await device.send(frame)
```

your consumer has already seen that frame. If you're recording, it's in the
recording. With a stream, you'd be pulling frames off on your own schedule, so
`send` could return while the echo was still sitting in the buffer unread — and
code that sends something and then checks its own recording could miss it.

One rule: `consume` is awaited by the read loop, so whatever you do in there
holds up reading. Append to a buffer and return. Don't do real work inside it.

Frames arrive with the flag bits already sorted out — `canID` is the plain ID,
with `extended`, `rtr` and `err` as separate properties. `tx` tells you whether
a frame is one you sent (echoed back) or one you observed from another device
on the bus, so a recording never confuses your own injection with a reply.

## Timestamps

Every frame carries `timestampNs`: Unix epoch nanoseconds. Two things can
produce it, and `device.timestampMode` tells you which you got.

**`.hardware`** — the adapter stamps each frame itself, the moment it arrives,
off its own microsecond clock. This is the good one. The counter is 32 bits so
it rolls over about every 71 minutes; the driver unwraps that for you and
re-syncs against your Mac's clock periodically so the adapter's crystal drift
doesn't pile up over a long capture.

**`.hostCompletion`** — the adapter has no clock, so the best available answer
is "when USB handed this to us." The catch is that USB delivers frames in
batches, so everything in one batch gets nearly the same timestamp. You still
know what arrived and roughly when, but the fine spacing and ordering *within*
a batch is gone.

If you land in `.hostCompletion`, `timestampMode.isDegraded` is true and a
notice fires when you connect. If you're saving captures, save which mode
produced them. The two aren't interchangeable, and months later you'll want to
know which kind you're looking at.

## Knowing whether you missed anything

`seq` counts the frames the driver handed you, restarting at 0 each connection.
It never skips — which means **an unbroken `seq` does not mean you got
everything.** It can't tell you about frames that never made it off the
adapter.

What does tell you is the adapter's own report that its receive buffer
overflowed. That shows up in two places: `GsUsbStatistics.readStarvationEvents`
and a `GsUsbNotice`. Those are your only real signal that frames were lost.

## Testing without an adapter

Everything except the `IOUSBHostTransport` file is byte and integer arithmetic
sitting behind the `UsbDeviceTransport` protocol. So the whole driver —
handshake, decoding, timestamps, bus state, reconnect, transmit — can be tested
with nothing plugged in. Add `GSUSBKitTestSupport` for the pieces that takes:

| Type | What it's for |
|---|---|
| `ScriptedUsbTransport` | A fake adapter that replays a conversation you write, including surprise unplugs, stalled pipes, timeouts and write echoes. Each `open()` replays the next session, so you can script "dies mid-read, then comes back healthy" and test reconnect. |
| `CollectingFrameConsumer` | Buffers frames and republishes them as an `AsyncStream`, for when you do want to iterate in a test. |
| `GsUsbVirtualClock` | Returns from sleeps instantly and records what it was asked to wait for, so you can assert on the retry *schedule* without the test actually taking that long. |

```swift
.testTarget(name: "MyTests", dependencies: ["MyKit", .product(
    name: "GSUSBKitTestSupport", package: "gsusb-kit"
)])
```

## gsusbprobe

```
swift run gsusbprobe
```

Prints what's plugged in: identity, feature bits, bit-timing limits. Good first
thing to run when an adapter isn't behaving, or to check whether an unlisted
one is supported.

It's strictly read-only — never sets a mode, never writes to the bus, never
leaves the adapter in a state that outlives it. It also exists for a second
reason: `IOUSBHostTransport` is the one file no test can execute, so building
this tool is what keeps it from quietly rotting.

## Modules

| Module | What's in it |
|---|---|
| `GSUSBKit` | The driver. Wire format (`GsUsbProtocol`), bit-timing solver (`BitTiming`), timestamp mapping (`TimestampMapper`), the USB layer (`UsbDeviceTransport`, `IOUSBHostTransport`) and `GsUsbDevice` itself. No third-party dependencies. |
| `GSUSBKitTestSupport` | The test doubles above, for your own tests as well as this package's. |

## About the `§` references in the comments

Doc comments here cite section numbers from canopener's design document, which
is where the behaviour was originally argued out and which doesn't live in this
repo. Wherever the reasoning matters it's written out inline too, so you're not
missing anything — the citations are just provenance.
