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
