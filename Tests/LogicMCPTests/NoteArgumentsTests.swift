import LogicBridge
import MCP
import MIDICore
import Synchronization
import Testing
@testable import LogicMCP

@Suite("write_midi argument parsing")
struct NoteArgumentsTests {
    func parse(_ arguments: [String: Value]) -> Result<NoteWriteRequest, NoteArguments.Problem> {
        NoteArguments.request(arguments)
    }

    func problem(_ arguments: [String: Value]) -> String? {
        if case .failure(let problem) = parse(arguments) { return problem.message }
        return nil
    }

    let base: [String: Value] = [
        "track": 2, "expected_name": "Inst 2", "start_bar": 9,
        "notes": [["pitch": "C4", "start_beat": 0, "duration_beats": 1, "velocity": 90],
                  ["pitch": 64, "start_beat": 1.5, "duration_beats": 0.5]],
    ]

    @Test func validRequest() throws {
        let request = try parse(base).get()
        #expect(request.track == 2)
        #expect(request.expectedName == "Inst 2")
        #expect(request.startBar == 9)
        #expect(request.notes == [
            NoteSpec(pitch: 60, startBeat: 0, durationBeats: 1, velocity: 90),
            NoteSpec(pitch: 64, startBeat: 1.5, durationBeats: 0.5, velocity: 100),
        ])
        #expect(request.timingOffsetMs == NoteWriteRequest.defaultTimingOffsetMs)
        #expect(NoteWriteRequest.defaultTimingOffsetMs == 3)
    }

    @Test func confirmationTokenIsAllowed() throws {
        var arguments = base
        arguments["confirmation_token"] = "abc"
        #expect(try parse(arguments).get().notes.count == 2)
    }

    @Test func requiredFields() {
        for field in ["track", "expected_name", "start_bar", "notes"] {
            var arguments = base
            arguments.removeValue(forKey: field)
            #expect(problem(arguments)?.contains(field) == true, "\(field)")
        }
        var blank = base
        blank["expected_name"] = "  "
        #expect(problem(blank) != nil)
    }

    @Test func quantizeAndUnknownFieldsAreRejected() {
        var arguments = base
        arguments["quantize"] = "1/16"
        #expect(problem(arguments)?.contains("quantize") == true)
        arguments = base
        arguments["tempo"] = 120
        #expect(problem(arguments) == "Unknown field \"tempo\".")
        arguments = base
        arguments["notes"] = [["pitch": 60, "start_beat": 0, "duration_beats": 1, "channel": 2]]
        #expect(problem(arguments)?.contains("notes[0]: unknown field \"channel\"") == true)
    }

    @Test func noteValuesAreChecked() {
        func noteProblem(_ note: [String: Value]) -> String? {
            var arguments = base
            arguments["notes"] = [.object(note)]
            return problem(arguments)
        }
        #expect(noteProblem(["pitch": 128, "start_beat": 0, "duration_beats": 1])?.contains("0–127") == true)
        #expect(noteProblem(["pitch": "H2", "start_beat": 0, "duration_beats": 1])?.contains("note name") == true)
        #expect(noteProblem(["pitch": 60, "start_beat": -1, "duration_beats": 1]) != nil)
        #expect(noteProblem(["pitch": 60, "start_beat": 0, "duration_beats": 0]) != nil)
        #expect(noteProblem(["pitch": 60, "start_beat": 0, "duration_beats": 1, "velocity": 0]) != nil)
        #expect(noteProblem(["pitch": 60, "start_beat": 0, "duration_beats": 1, "velocity": 1.5]) != nil)
        #expect(noteProblem(["pitch": 60.0, "start_beat": 0, "duration_beats": 1]) == nil)
        #expect(noteProblem(["start_beat": 0, "duration_beats": 1])?.contains("pitch") == true)
    }

    @Test func tooManyNotes() {
        var arguments = base
        arguments["notes"] = .array(Array(repeating: ["pitch": 60, "start_beat": 0, "duration_beats": 1], count: 2001))
        #expect(problem(arguments)?.contains("2000") == true)
    }

    @Test func consoleWriteCommandParses() throws {
        let request = try #require(Console.parseWrite(["2", "9", "C4:0:1:100,E4:1:1,67:2:2", "offset=-3.5", "Inst", "2"]))
        #expect(request.track == 2)
        #expect(request.startBar == 9)
        #expect(request.expectedName == "Inst 2")
        #expect(request.timingOffsetMs == -3.5)
        #expect(request.notes.map(\.pitch) == [60, 64, 67])
        #expect(request.notes.map(\.velocity) == [100, 100, 100])
        #expect(Console.parseWrite(["2", "9"]) == nil)
        #expect(Console.parseWrite(["2", "9", "C4:0"]) == nil)
        #expect(Console.parseWrite(["2", "9", "X4:0:1"]) == nil)
        #expect(Console.parseWrite(["2", "9", "C4:0:1"])?.expectedName == nil)
    }
}

@Suite("write_midi tool and console logging")
struct NoteToolTests {
    @Test func writeMIDIIsMarkedDestructive() {
        #expect(NoteToolSchemas.writeMIDI.annotations.destructiveHint == true)
        #expect(NoteToolSchemas.writeMIDI.annotations.readOnlyHint == false)
    }

    @Test func loggedNotesAreWrittenOffTheSenderInOrder() async throws {
        final class Lines: Sendable {
            let state = Mutex<[String]>([])
            func add(_ line: String) { state.withLock { $0.append(line) } }
            var all: [String] { state.withLock { $0 } }
        }
        let lines = Lines()
        let sink = MIDIPipe()
        let logged = LoggedNotes(base: sink, start: .now) { lines.add($0) }
        try logged.send([.noteOn(channel: 0, note: 60, velocity: 100)])
        try logged.send([.noteOff(channel: 0, note: 60, velocity: 0), .controlChange(channel: 0, controller: 123, value: 0)])
        await logged.finish()
        #expect(lines.all.count == 2)
        #expect(lines.all[0].hasSuffix("NOTES 90 3C 64"))
        #expect(lines.all[1].hasSuffix("NOTES 80 3C 00 | B0 7B 00"))
        sink.finish()
        var sent: [MIDIMessage] = []
        for await message in sink.stream { sent.append(message) }
        #expect(sent.count == 3)
    }
}

@Suite("write_midi controller arguments")
struct ControllerArgumentsTests {
    let base: [String: Value] = ["track": 2, "expected_name": "Inst 2", "start_bar": 9]

    func parse(_ controllers: [Value], notes: [Value]? = nil) -> Result<NoteWriteRequest, NoteArguments.Problem> {
        var arguments = base
        arguments["controllers"] = .array(controllers)
        if let notes { arguments["notes"] = .array(notes) }
        return NoteArguments.request(arguments)
    }

    func problem(_ controller: [String: Value]) -> String? {
        if case .failure(let problem) = parse([.object(controller)]) { return problem.message }
        return nil
    }

    @Test func controllersParseAlongsideNotes() throws {
        let request = try parse([
            ["type": "cc", "controller": 64, "start_beat": 0, "value": 127],
            ["type": "cc", "controller": 1, "start_beat": 0.5, "value": 0, "to_value": 127, "duration_beats": 2],
            ["type": "pitch_bend", "start_beat": 1, "value": -4096],
        ], notes: [["pitch": "C4", "start_beat": 0, "duration_beats": 1]]).get()
        #expect(request.notes.count == 1)
        #expect(request.controllers == [
            .controlChange(64, at: 0, 127),
            ControllerSpec(kind: .controlChange(1), startBeat: 0.5, value: 0, toValue: 127, durationBeats: 2),
            .pitchBend(at: 1, -4096),
        ])
    }

    @Test func controllersAloneAreEnough() throws {
        let request = try parse([["type": "pitch_bend", "start_beat": 0, "value": 0]]).get()
        #expect(request.notes.isEmpty)
        #expect(request.controllers.count == 1)
        if case .failure(let problem) = NoteArguments.request(base) {
            #expect(problem.message.contains("\"notes\"") && problem.message.contains("\"controllers\""))
        } else {
            Issue.record("a request with neither notes nor controllers was accepted")
        }
        var notArray = base
        notArray["controllers"] = "cc 1"
        if case .success = NoteArguments.request(notArray) { Issue.record("controllers must be an array") }
    }

    @Test func controllerFieldsAreChecked() {
        #expect(problem(["start_beat": 0, "value": 1])?.contains("\"type\"") == true)
        #expect(problem(["type": "aftertouch", "start_beat": 0, "value": 1])?.contains("\"type\"") == true)
        #expect(problem(["type": "cc", "start_beat": 0, "value": 1])?.contains("\"controller\"") == true)
        #expect(problem(["type": "cc", "controller": 200, "start_beat": 0, "value": 1])?.contains("\"controller\"") == true)
        #expect(problem(["type": "pitch_bend", "controller": 1, "start_beat": 0, "value": 1])?.contains("only for type \"cc\"") == true)
        #expect(problem(["type": "cc", "controller": 1, "value": 1])?.contains("start_beat") == true)
        #expect(problem(["type": "cc", "controller": 1, "start_beat": 0])?.contains("\"value\"") == true)
        #expect(problem(["type": "cc", "controller": 1, "start_beat": 0, "value": 1.5])?.contains("\"value\"") == true)
        #expect(problem(["type": "cc", "controller": 1, "start_beat": 0, "value": 1, "to_value": "high"])?.contains("to_value") == true)
        #expect(problem(["type": "cc", "controller": 1, "start_beat": 0, "value": 1, "channel": 2])?.contains("controllers[0]: unknown field \"channel\"") == true)
    }

    @Test func consoleWriteTakesControllers() throws {
        let request = try #require(Console.parseWrite(["2", "9", "C4:0:1", "cc=64:0:127,1:0:0>127:4", "bend=1:0>8191:1,3:0", "Inst", "2"]))
        #expect(request.expectedName == "Inst 2")
        #expect(request.controllers == [
            .controlChange(64, at: 0, 127),
            ControllerSpec(kind: .controlChange(1), startBeat: 0, value: 0, toValue: 127, durationBeats: 4),
            ControllerSpec(kind: .pitchBend, startBeat: 1, value: 0, toValue: 8191, durationBeats: 1),
            .pitchBend(at: 3, 0),
        ])
        let only = try #require(Console.parseWrite(["2", "9", "-", "cc=11:0:100"]))
        #expect(only.notes.isEmpty && only.controllers.count == 1)
        #expect(Console.parseWrite(["2", "9", "-"]) == nil)
        #expect(Console.parseWrite(["2", "9", "C4:0:1", "cc=64:0"]) == nil)
        #expect(Console.parseWrite(["2", "9", "C4:0:1", "cc=1:0:0>127"]) == nil)
        #expect(Console.parseWrite(["2", "9", "C4:0:1", "bend=0:x"]) == nil)
    }
}
