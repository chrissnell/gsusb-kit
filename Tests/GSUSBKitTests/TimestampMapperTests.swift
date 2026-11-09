import Foundation
import Testing
@testable import GSUSBKit

/// An arbitrary but realistic `CLOCK_REALTIME` anchor, in nanoseconds.
private let anchorNs: Int64 = 1_762_000_000_000_000_000

// MARK: - Anchor arithmetic

@Test func theFrameAtTheAnchorMapsToTheAnchorRealtime() {
    var mapper = TimestampMapper(anchorRealtimeNs: anchorNs, anchorDeviceMicroseconds: 5_000)
    #expect(mapper.timestampNs(forDeviceMicroseconds: 5_000) == anchorNs)
}

/// The device counter is microseconds and `Frame.timestampNs` is nanoseconds,
/// so the scale factor is the whole mapping. Getting it wrong by 1000x would
/// still look monotonic, which is why it gets an explicit test.
@Test func elapsedDeviceMicrosecondsScaleToNanoseconds() {
    var mapper = TimestampMapper(anchorRealtimeNs: anchorNs, anchorDeviceMicroseconds: 1_000)
    #expect(mapper.timestampNs(forDeviceMicroseconds: 1_250) == anchorNs + 250_000)
    #expect(mapper.timestampNs(forDeviceMicroseconds: 2_000) == anchorNs + 1_000_000)
}

@Test func timestampsAdvanceWithTheDeviceCounterNotWithWallClockReads() {
    var mapper = TimestampMapper(anchorRealtimeNs: anchorNs, anchorDeviceMicroseconds: 0)
    let first = mapper.timestampNs(forDeviceMicroseconds: 100)
    let second = mapper.timestampNs(forDeviceMicroseconds: 100)
    // Two frames stamped by the device at the same microsecond get the same
    // host timestamp. Intra-burst resolution is the device's to give (§7.1).
    #expect(first == second)
}

// MARK: - The 2^32 microsecond wrap

/// The counter wraps every 2^32 µs ≈ 71.6 minutes, so a long session *will*
/// hit it. A decoder that compared raw values would emit a 71-minute jump
/// backwards in the middle of a recording.
@Test func timestampsStayMonotonicAcrossTheWrapBoundary() {
    let justBeforeWrap: UInt32 = 0xFFFF_F000
    var mapper = TimestampMapper(
        anchorRealtimeNs: anchorNs, anchorDeviceMicroseconds: justBeforeWrap
    )

    let before = mapper.timestampNs(forDeviceMicroseconds: 0xFFFF_FFFF)
    let after = mapper.timestampNs(forDeviceMicroseconds: 0x0000_0FFF)

    #expect(before == anchorNs + 0xFFF * 1_000)
    #expect(after > before)
    // 0xFFFFF000 → 0x00000FFF is 0x1FFF µs of real elapsed time.
    #expect(after == anchorNs + 0x1FFF * 1_000)
}

@Test func aSyntheticSeventyOneMinuteSequenceStaysMonotonic() {
    var mapper = TimestampMapper(anchorRealtimeNs: anchorNs, anchorDeviceMicroseconds: 0)

    // One frame per millisecond for a little over 71.6 minutes, which carries
    // the counter past 2^32 µs and well into the second epoch. The loop keeps
    // its assertions out of the hot path and reports the worst step once, so
    // the whole 4.4 million frames stay cheap enough to run on every build.
    let stepMicroseconds: UInt32 = 1_000
    let steps = 4_400_000
    var previous = mapper.timestampNs(forDeviceMicroseconds: 0)
    var raw: UInt32 = 0
    var wrapped = false
    var smallestStepNs = Int64.max

    for _ in 1...steps {
        let next = raw &+ stepMicroseconds
        if next < raw { wrapped = true }
        raw = next
        let timestamp = mapper.timestampNs(forDeviceMicroseconds: raw)
        smallestStepNs = min(smallestStepNs, timestamp - previous)
        previous = timestamp
    }

    #expect(wrapped)
    #expect(smallestStepNs == 1_000_000)
    #expect(previous == anchorNs + Int64(steps) * Int64(stepMicroseconds) * 1_000)
}

// MARK: - Re-anchoring

/// §7.1 re-anchors periodically to track crystal drift. Drift correction can
/// pull the host side *backwards*; the recording still may not go backwards,
/// because every consumer above this — trial windows, lag measurement,
/// cross-correlation — assumes a non-decreasing timeline.
@Test func reanchoringToAnEarlierHostTimeDoesNotMoveTimestampsBackwards() {
    var mapper = TimestampMapper(anchorRealtimeNs: anchorNs, anchorDeviceMicroseconds: 0)
    let issued = mapper.timestampNs(forDeviceMicroseconds: 10_000_000)
    #expect(issued == anchorNs + 10_000_000_000)

    // A re-anchor that claims the frame above happened 5 ms in the past.
    mapper.reanchor(realtimeNs: issued - 5_000_000, deviceMicroseconds: 10_000_000)

    let next = mapper.timestampNs(forDeviceMicroseconds: 10_001_000)
    #expect(next >= issued)
    #expect(next == issued + 1_000_000)
}

@Test func reanchoringForwardAdoptsTheNewCorrespondence() {
    var mapper = TimestampMapper(anchorRealtimeNs: anchorNs, anchorDeviceMicroseconds: 0)
    _ = mapper.timestampNs(forDeviceMicroseconds: 1_000)

    let laterNs = anchorNs + 60_000_000_000
    mapper.reanchor(realtimeNs: laterNs, deviceMicroseconds: 60_000_000)

    #expect(mapper.timestampNs(forDeviceMicroseconds: 60_000_000) == laterNs)
    #expect(mapper.timestampNs(forDeviceMicroseconds: 60_500_000) == laterNs + 500_000_000)
}

/// A frame captured by the device just *before* the `BREQ_TIMESTAMP` read can
/// be processed just *after* it. Unsigned wrapping subtraction would read that
/// one-microsecond step back as 2^32 - 1 µs forward and jump the recording 71
/// minutes into the future.
@Test func aFrameStampedBeforeTheReanchorDoesNotJumpAnEntireEpoch() {
    var mapper = TimestampMapper(anchorRealtimeNs: anchorNs, anchorDeviceMicroseconds: 0)
    let issued = mapper.timestampNs(forDeviceMicroseconds: 1_000_000)
    mapper.reanchor(realtimeNs: issued, deviceMicroseconds: 1_000_000)

    let straggler = mapper.timestampNs(forDeviceMicroseconds: 999_999)
    #expect(straggler == issued)

    // And the mapping recovers: the next in-order frame is still correct.
    #expect(mapper.timestampNs(forDeviceMicroseconds: 1_002_000) == issued + 2_000_000)
}

@Test func reanchoringResetsTheWrapAccountingRatherThanAccumulatingIt() {
    var mapper = TimestampMapper(
        anchorRealtimeNs: anchorNs, anchorDeviceMicroseconds: 0xFFFF_0000
    )
    _ = mapper.timestampNs(forDeviceMicroseconds: 0x0001_0000 &+ 0xFFFF_0000)

    let newAnchor = anchorNs + 500_000_000
    mapper.reanchor(realtimeNs: newAnchor, deviceMicroseconds: 0x0000_1000)
    #expect(mapper.timestampNs(forDeviceMicroseconds: 0x0000_2000) == newAnchor + 4_096_000)
}

// MARK: - Out-of-order and duplicate input

@Test func aSmallBackwardStepIsClampedRatherThanTreatedAsAWrap() {
    var mapper = TimestampMapper(anchorRealtimeNs: anchorNs, anchorDeviceMicroseconds: 0)
    let forward = mapper.timestampNs(forDeviceMicroseconds: 5_000)
    let backward = mapper.timestampNs(forDeviceMicroseconds: 4_000)
    #expect(backward == forward)
    #expect(mapper.timestampNs(forDeviceMicroseconds: 6_000) == forward + 1_000_000)
}
