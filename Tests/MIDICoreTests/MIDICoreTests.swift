import Testing
@testable import MIDICore

@Suite("MIDI byte parser")
struct MIDIByteParserTests {
    @Test func parsesChannelMessagesWithRunningStatus() {
        var parser = MIDIByteParser()
        let messages = parser.feed([0x90, 0x3C, 0x7F, 0x3E, 0x40, 0xB0, 0x07, 0x64])
        #expect(messages == [
            .noteOn(channel: 0, note: 0x3C, velocity: 0x7F),
            .noteOn(channel: 0, note: 0x3E, velocity: 0x40),
            .controlChange(channel: 0, controller: 0x07, value: 0x64),
        ])
    }

    @Test func pitchBendIsLSBFirst() {
        var parser = MIDIByteParser()
        // 12443 = 0x309B → LSB 0x1B, MSB 0x61 (Logic 12.3 sends "E0 1B 61" at connect).
        #expect(parser.feed([0xE0, 0x1B, 0x61]) == [.pitchBend(channel: 0, value: 12443)])
        #expect(MIDIMessage.pitchBend(channel: 3, value: 12443).bytes == [0xE3, 0x1B, 0x61])
    }

    @Test func realTimeInsideSysExDoesNotBreakIt() {
        var parser = MIDIByteParser()
        let messages = parser.feed([0xF0, 0x00, 0xF8, 0x00, 0x66, 0xFA, 0x14, 0x00, 0xF7])
        #expect(messages == [.timingClock, .start, .sysEx([0x00, 0x00, 0x66, 0x14, 0x00])])
    }

    @Test func realTimeDoesNotCancelRunningStatus() {
        var parser = MIDIByteParser()
        let messages = parser.feed([0x90, 0x3C, 0xF8, 0x7F, 0x3E, 0x40])
        #expect(messages == [
            .timingClock,
            .noteOn(channel: 0, note: 0x3C, velocity: 0x7F),
            .noteOn(channel: 0, note: 0x3E, velocity: 0x40),
        ])
    }

    @Test func unterminatedSysExIsDroppedWhenNewStatusArrives() {
        var parser = MIDIByteParser()
        let messages = parser.feed([0xF0, 0x01, 0x02, 0x90, 0x3C, 0x7F])
        #expect(messages == [.noteOn(channel: 0, note: 0x3C, velocity: 0x7F)])
    }

    @Test func oversizedSysExIsDropped() {
        var parser = MIDIByteParser(maxSysExLength: 4)
        let messages = parser.feed([0xF0, 1, 2, 3, 4, 5, 0xF7, 0xF8])
        #expect(messages == [.timingClock])
    }

    @Test func songPositionPointer() {
        var parser = MIDIByteParser()
        // 300 sixteenths = 0x12C → LSB 0x2C, MSB 0x02.
        #expect(parser.feed([0xF2, 0x2C, 0x02]) == [.songPosition(300)])
        #expect(MIDIMessage.songPosition(300).bytes == [0xF2, 0x2C, 0x02])
    }

    @Test func strayDataBytesAreIgnored() {
        var parser = MIDIByteParser()
        #expect(parser.feed([0x10, 0x20, 0xFC]) == [.stop])
    }

    @Test func hexHelpers() {
        #expect([0x90, 0x5E, 0x7F].hexString == "90 5E 7F")
        #expect(parseHexBytes("F0 00 66 F7") == [0xF0, 0x00, 0x66, 0xF7])
        #expect(parseHexBytes("ZZ") == nil)
    }
}

@Suite("UMP codec")
struct UMPTests {
    @Test func channelVoiceIsType2() {
        let packets = UMP.encode(.noteOn(channel: 0, note: 0x5E, velocity: 0x7F))
        #expect(packets == [[0x2090_5E7F]])
        var decoder = UMPDecoder()
        #expect(decoder.decode(words: packets.flatMap { $0 }) == [.noteOn(channel: 0, note: 0x5E, velocity: 0x7F)])
    }

    @Test func systemMessagesAreType1() {
        #expect(UMP.encode(.timingClock) == [[0x10F8_0000]])
        #expect(UMP.encode(.songPosition(300)) == [[0x10F2_2C02]])
        var decoder = UMPDecoder()
        #expect(decoder.decode(words: [0x10F8_0000, 0x10F2_2C02, 0x10FA_0000]) == [.timingClock, .songPosition(300), .start])
    }

    @Test func shortSysExIsOneCompletePacket() {
        let packets = UMP.encodeSysEx([0x00, 0x00, 0x66, 0x14, 0x00])
        #expect(packets == [[0x3005_0000, 0x6614_0000]])
    }

    @Test func sysExIsSplitIntoSixBytePackets() {
        let payload = (0..<14).map { UInt8($0) }
        let packets = UMP.encodeSysEx(payload)
        #expect(packets.count == 3)
        // start (status 1) with 6 bytes, continue (2) with 6, end (3) with 2.
        #expect(packets[0][0] >> 16 == 0x3016)
        #expect(packets[1][0] >> 16 == 0x3026)
        #expect(packets[2][0] >> 16 == 0x3032)
        var decoder = UMPDecoder()
        #expect(decoder.decode(words: packets.flatMap { $0 }) == [.sysEx(payload)])
    }

    @Test func lcdSizedSysExRoundTrips() {
        // A full LCD write as Logic 12.3 sent it: header + 0x12 + offset + 111 characters.
        let payload: [UInt8] = [0x00, 0x00, 0x66, 0x14, 0x12, 0x00] + Array(repeating: 0x41, count: 111)
        let packets = UMP.encodeSysEx(payload)
        #expect(packets.count == (payload.count + 5) / 6)
        var decoder = UMPDecoder()
        #expect(decoder.decode(words: packets.flatMap { $0 }) == [.sysEx(payload)])
    }

    @Test func interleavedChannelMessagesDuringSysEx() {
        let sysex = UMP.encodeSysEx(Array(0..<10))
        let words = sysex[0] + [0x2090_3C7F] + sysex[1]
        var decoder = UMPDecoder()
        #expect(decoder.decode(words: words) == [
            .noteOn(channel: 0, note: 0x3C, velocity: 0x7F),
            .sysEx(Array(0..<10)),
        ])
    }

    @Test func continueWithoutStartIsDropped() {
        var decoder = UMPDecoder()
        #expect(decoder.decode(words: [0x3032_0102, 0x0000_0000]) == [])
    }

    @Test func unknownTypesAreSkippedWithCorrectLength() {
        var decoder = UMPDecoder()
        // A 64-bit MIDI 2.0 channel voice packet (type 4) followed by a type-2 note.
        #expect(decoder.decode(words: [0x4090_3C00, 0xFFFF_0000, 0x2080_3C00]) == [.noteOff(channel: 0, note: 0x3C, velocity: 0)])
    }
}

@Suite("Timed messages and host time")
struct TimedMIDITests {
    let receivedAt = ContinuousClock.now

    @Test func hostTimestampsBecomeInstantsByDifference() {
        // Apple silicon: 125/3 ns per tick (24 MHz). 24_000 ticks = 1 ms.
        let ahead = HostTime.instant(timestamp: 1_000_024_000, receivedHost: 1_000_000_000, receivedAt: receivedAt, numer: 125, denom: 3)
        #expect(ahead == receivedAt.advanced(by: .milliseconds(1)))
        let behind = HostTime.instant(timestamp: 999_976_000, receivedHost: 1_000_000_000, receivedAt: receivedAt, numer: 125, denom: 3)
        #expect(behind == receivedAt.advanced(by: .milliseconds(-1)))
        // Intel: 1 ns per tick.
        let intel = HostTime.instant(timestamp: 5_000_000 + 40_000_000, receivedHost: 5_000_000, receivedAt: receivedAt, numer: 1, denom: 1)
        #expect(intel == receivedAt.advanced(by: .milliseconds(40)))
    }

    @Test func zeroAndImplausibleTimestampsAreMissing() {
        #expect(HostTime.instant(timestamp: 0, receivedHost: 1_000, receivedAt: receivedAt, numer: 1, denom: 1) == nil)
        // Two seconds away: more than `plausibleOffset`.
        #expect(HostTime.instant(timestamp: 3_000_000_000, receivedHost: 1_000_000_000, receivedAt: receivedAt, numer: 1, denom: 1) == nil)
        #expect(HostTime.instant(timestamp: 1, receivedHost: 2_000_000_001, receivedAt: receivedAt, numer: 1, denom: 1) == nil)
    }

    @Test func timedPipeStampsArrivalAndKeepsTimestamps() async {
        let pipe = TimedMIDIPipe()
        let before = ContinuousClock.now
        let later = before.advanced(by: .milliseconds(30))
        pipe.send([.timingClock], timestamp: later)
        pipe.send([.continue])
        pipe.finish()
        var items: [TimedMIDIMessage] = []
        for await item in pipe.stream { items.append(item) }
        #expect(items.map(\.message) == [.timingClock, .continue])
        #expect(items[0].time == later)
        #expect(items[0].receivedAt >= before)
        #expect(items[0].lead.map { $0 > .milliseconds(25) && $0 <= .milliseconds(30) } == true)
        #expect(items[1].timestamp == nil)
        #expect(items[1].lead == nil)
        #expect(items[1].time == items[1].receivedAt)
    }
}
