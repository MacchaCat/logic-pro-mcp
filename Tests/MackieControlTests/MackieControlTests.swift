import Foundation
import Testing
@testable import MackieControl
import MIDICore

/// Loads the decoded Logic 12.3 capture, skipping comments and the first message
/// (which the capturing tool sent itself).
private func loadLogic123Capture() throws -> [MIDIMessage] {
    let url = try #require(Bundle.module.url(forResource: "logic-12.3-connect", withExtension: "txt", subdirectory: "Fixtures"))
    let text = try String(contentsOf: url, encoding: .utf8)
    var parser = MIDIByteParser()
    var messages: [MIDIMessage] = []
    for line in text.split(separator: "\n") where !line.hasPrefix("#") {
        let bytes = try #require(parseHexBytes(String(line)), "bad fixture line: \(line)")
        messages.append(contentsOf: parser.feed(bytes))
    }
    return Array(messages.dropFirst())
}

@Suite("Logic 12.3 capture replay")
struct CaptureReplayTests {
    @Test func reconstructsSurfaceState() throws {
        let codec = MCUCodec()
        var state = SurfaceState()
        for message in try loadLogic123Capture() {
            state.apply(codec.decode(message))
        }

        // LCD: 6-character names plus a separator, values on the lower line (Pan mode).
        #expect((0..<8).map { state.lcdCell(strip: $0) } ==
                ["DelCls", "DelCls", "DelCls", "StdGrn", "StdGrn", "StdGrn", "StdGrn", "StdGrn"])
        #expect((0..<8).map { state.lcdCell(strip: $0, lower: true) } == Array(repeating: "0", count: 8))

        // LEDs: Pan assignment, Read automation and Stop lit; Play and Record off.
        #expect(state.led(.assignPan) == .on)
        #expect(state.led(.automationRead) == .on)
        #expect(state.led(.stop) == .on)
        #expect(state.led(.play) == .off)
        #expect(state.led(.record) == .off)
        #expect(state.led(.replace) == .off)
        #expect(state.led(MCUButton.mute(0)) == .off)

        // Faders: all at 12443 at connect, then strip 1 moved to 8192 by the final "E0 00 40".
        #expect(state.faders[0] == 8192)
        #expect(Array(state.faders[1...8]) == Array(repeating: UInt16(12443), count: 8))

        // V-Pot rings: centre LED, boost/cut mode, position 6 = pan centred.
        #expect(state.vPotRings.allSatisfy { $0 == 0x56 })

        // Assignment display "PN" (Pan). Time-code digits were all 0x00 (blank).
        #expect(state.assignmentText == "PN")
        #expect(state.timecodeText == "          ")
        #expect(state.beatsPosition == nil)
    }

    @Test func logicProbesOtherModelsWhichWeIgnore() throws {
        let codec = MCUCodec()
        let decoded = try loadLogic123Capture().map(codec.decode)
        let otherModels = Set(decoded.compactMap { message -> UInt8? in
            if case let .otherModel(model, _) = message { return model }
            return nil
        })
        #expect(otherModels == [0x10, 0x11, 0x15, 0x17])
        #expect(decoded.filter { $0 == .deviceQuery }.count == 3)
        #expect(decoded.filter { $0 == .firmwareVersionRequest }.count == 3)
    }

    @Test func handshakeRepliesToOurModelOnly() throws {
        let codec = MCUCodec()
        var responder = HandshakeResponder()
        var replies: [MIDIMessage] = []
        for message in try loadLogic123Capture() {
            replies += responder.respond(to: codec.decode(message)).map(codec.encode)
        }
        let query = MIDIMessage.sysEx([0x00, 0x00, 0x66, 0x14, 0x01] + Array("LMCP001".utf8) + [0x01, 0x02, 0x03, 0x04])
        let version = MIDIMessage.sysEx([0x00, 0x00, 0x66, 0x14, 0x14] + Array("V1.00".utf8))
        #expect(replies == [query, version, query, version, query, version])
        #expect(responder.phase == .queried)
    }
}

@Suite("Mackie Control codec")
struct MCUCodecTests {
    let codec = MCUCodec()

    @Test func transportButtons() {
        #expect(codec.encode(.button(note: MCUButton.play.rawValue, pressed: true)).bytes == [0x90, 0x5E, 0x7F])
        #expect(codec.encode(.button(note: MCUButton.play.rawValue, pressed: false)).bytes == [0x90, 0x5E, 0x00])
        #expect(MCUButton.stop.rawValue == 0x5D)
        #expect(MCUButton.record.rawValue == 0x5F)
        #expect(MCUButton.replace.rawValue == 0x58)
    }

    @Test func faderAndTouch() {
        #expect(codec.encode(.faderTouch(fader: 0, touched: true)).bytes == [0x90, 0x68, 0x7F])
        #expect(codec.encode(.faderTouch(fader: 8, touched: false)).bytes == [0x90, 0x70, 0x00])
        #expect(codec.encode(.fader(fader: 2, value: 12000)).bytes == [0xE2, 0x60, 0x5D])
    }

    @Test func relativeEncoding() {
        // Logic Control manual examples: "B0 10 01" = V-Pot 1 one tick clockwise,
        // "B0 17 47" = V-Pot 8 seven ticks counter-clockwise.
        #expect(codec.encode(.vPot(strip: 0, delta: 1)).bytes == [0xB0, 0x10, 0x01])
        #expect(codec.encode(.vPot(strip: 7, delta: -7)).bytes == [0xB0, 0x17, 0x47])
        #expect(codec.encode(.jog(delta: 1)).bytes == [0xB0, 0x3C, 0x01])
        #expect(codec.encode(.jog(delta: -1)).bytes == [0xB0, 0x3C, 0x41])
        #expect(codec.encode(.jog(delta: 500)).bytes == [0xB0, 0x3C, 0x3F])
    }

    @Test func dialogDigits() {
        #expect(MCUButton.dialogDigit(1) == .f1)
        #expect(MCUButton.dialogDigit(8) == .f8)
        #expect(MCUButton.dialogDigit(9) == .midiTracks)
        #expect(MCUButton.dialogDigit(0) == .inputs)
        #expect(MCUButton.dialogDigit(10) == nil)
    }

    @Test func decodesHostMessages() {
        #expect(codec.decode(.noteOn(channel: 0, note: 0x5E, velocity: 0x01)) == .led(note: 0x5E, state: .flashing))
        #expect(codec.decode(.controlChange(channel: 0, controller: 0x49, value: 0x31)) == .timecodeDigit(position: 9, code: 0x31))
        #expect(codec.decode(.channelPressure(channel: 0, pressure: 0x3C)) == .meter(strip: 3, level: 0x0C))
        #expect(codec.decode(.pitchBend(channel: 9, value: 0)) == .unknown(.pitchBend(channel: 9, value: 0)))
        #expect(codec.decode(.sysEx([0x00, 0x00, 0x66, 0x14, 0x12, 0x38, 0x41])) == .lcd(offset: 0x38, text: [0x41]))
    }
}

@Suite("Surface state")
struct SurfaceStateTests {
    @Test func timecodeExampleFromLogicControlManual() {
        // Manual example: SysEx "10 36 32 31 71 30 72 30 79 30 31" (first byte = rightmost digit)
        // displays "109.02.01.126".
        var state = SurfaceState()
        state.apply(.timecodeDigits([0x36, 0x32, 0x31, 0x71, 0x30, 0x72, 0x30, 0x79, 0x30, 0x31]))
        #expect(state.timecodeText == "109.02.01.126")
        #expect(state.beatsPosition == BeatsPosition(bar: 109, beat: 2, division: 1, tick: 126))
    }

    @Test func singleDigitUpdatesAndSpacePadding() {
        var state = SurfaceState()
        // "  5. 1. 1.  1" style: bars right-aligned with leading blanks.
        let digits: [UInt8] = [0x31, 0x20, 0x20, 0x71, 0x20, 0x71, 0x20, 0x75, 0x20, 0x20]
        state.apply(.timecodeDigits(digits))
        #expect(state.beatsPosition == BeatsPosition(bar: 5, beat: 1, division: 1, tick: 1))
        state.apply(.timecodeDigit(position: 7, code: 0x76))  // bars ones digit → 6 with dot
        #expect(state.beatsPosition?.bar == 6)
    }

    @Test func lcdPartialWritesAndWrap() {
        var state = SurfaceState()
        state.apply(.lcd(offset: 0, text: Array("Bass   Drums  ".utf8)))
        state.apply(.lcd(offset: 7, text: Array("Kick".utf8)))
        #expect(state.lcdCell(strip: 0) == "Bass")
        #expect(state.lcdCell(strip: 1) == "Kicks")  // only 4 bytes overwritten: "Kick" + "s"
        // Writing past the end of the upper line continues on the lower line.
        state.apply(.lcd(offset: 54, text: Array("ABCD".utf8)))
        #expect(state.lcdUpperLine.hasSuffix("AB"))
        #expect(state.lcdLowerLine.hasPrefix("CD"))
        // Writes beyond the buffer are clipped.
        state.apply(.lcd(offset: 110, text: Array("XYZ".utf8)))
        #expect(state.lcdLowerLine.hasSuffix("XY"))
    }
}
