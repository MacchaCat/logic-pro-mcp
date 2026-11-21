import Foundation
import LogicBridge
import MCP
import MIDICore

/// Phase 4 tools: `write_midi` (real-time recording through `LogicMCP Notes`).
struct NoteTools: ToolModule {
    let writer: NoteWriter

    /// Uses the mixer controller of an already registered `MixerTools`, so the surface's bank
    /// position and scan state are tracked in one place.
    static func make(runtime: LogicRuntime, sharing modules: [any ToolModule]) async -> NoteTools {
        let mixer = modules.compactMap { ($0 as? MixerTools)?.mixer }.first ?? makeMixerController(runtime: runtime)
        return NoteTools(writer: makeNoteWriter(runtime: runtime, mixer: mixer))
    }

    var tools: [Tool] { [NoteToolSchemas.writeMIDI] }

    func call(_ name: String, _ arguments: [String: Value], context: ToolContext) async -> CallTool.Result? {
        guard name == "write_midi" else { return nil }
        switch NoteArguments.request(arguments) {
        case .failure(let problem):
            return context.encode(NoteWriter.Result(status: .failed, summary: problem.message + " Nothing was sent."))
        case .success(let request):
            let action = NoteWriter.confirmationAction(for: request)
            if let token = arguments["confirmation_token"]?.stringValue {
                guard await context.consumeToken(token, for: action) else {
                    return context.encode(NoteWriter.Result(status: .failed, summary: "The confirmation token is invalid, already used, expired (5 min) or was issued for different notes, track or bar. Call again without a token to get a new one. Nothing was sent."))
                }
                return context.encode(await writer.write(request, replaceConfirmed: true))
            }
            let result = await writer.write(request, replaceConfirmed: false)
            guard result.status == .needsConfirmation else { return context.encode(result) }
            let confirmed = await context.confirm(result.summary, action: action, pending: result) {
                await writer.write(request, replaceConfirmed: true)
            }
            return context.encode(confirmed)
        }
    }
}

extension LogicRuntime {
    /// Where notes for recording go: the `LogicMCP Notes` port, or the fake's recorder.
    var notesOutput: (any MIDIOutput)? {
        if let ports { return ports.notesOut }
        return fakeHost?.noteRecorder
    }
}

/// A note writer on the runtime's ports (also used by the console).
func makeNoteWriter(runtime: LogicRuntime, mixer: MixerController, notes: (any MIDIOutput)? = nil) -> NoteWriter {
    NoteWriter(mcu: runtime.mcu, sync: runtime.sync, transport: runtime.transport, mixer: mixer,
               notes: notes ?? runtime.notesOutput ?? DiscardingOutput())
}

/// Never used in practice (a runtime has ports or a fake); keeps the writer total.
private struct DiscardingOutput: MIDIOutput {
    func send(_ messages: [MIDIMessage]) throws {
        throw RuntimeError("No LogicMCP Notes port is available.")
    }
}

/// Parsing of `write_midi` arguments.
enum NoteArguments {
    struct Problem: Error { let message: String }

    static let fields: Set<String> = ["track", "expected_name", "start_bar", "notes", "confirmation_token"]
    static let noteFields: Set<String> = ["pitch", "start_beat", "duration_beats", "velocity"]

    static func request(_ arguments: [String: Value]) -> Result<NoteWriteRequest, Problem> {
        if let unknown = arguments.keys.sorted().first(where: { !fields.contains($0) }) {
            return .failure(Problem(message: unknown == "quantize"
                ? "\"quantize\" is not supported (Logic's quantize cannot be verified over Mackie Control); quantize the region in Logic afterwards."
                : "Unknown field \"\(unknown)\"."))
        }
        guard let trackValue = arguments["track"], let track = MixerArguments.integer(trackValue), track >= 1 else {
            return .failure(Problem(message: "\"track\" (a track number, 1 = first) is required."))
        }
        guard let name = arguments["expected_name"]?.stringValue,
              !name.trimmingCharacters(in: .whitespaces).isEmpty else {
            return .failure(Problem(message: "\"expected_name\" (the target track's name) is required: it is checked before anything is armed or recorded."))
        }
        guard let barValue = arguments["start_bar"], let bar = MixerArguments.integer(barValue) else {
            return .failure(Problem(message: "\"start_bar\" (a whole number, 2–999) is required."))
        }
        guard let items = arguments["notes"]?.arrayValue, !items.isEmpty else {
            return .failure(Problem(message: "\"notes\" must be a non-empty array."))
        }
        guard items.count <= NoteWriteRequest.maxNotes else {
            return .failure(Problem(message: "At most \(NoteWriteRequest.maxNotes) notes per call (got \(items.count))."))
        }
        var notes: [NoteSpec] = []
        for (index, item) in items.enumerated() {
            switch note(item) {
            case .success(let note): notes.append(note)
            case .failure(let problem): return .failure(Problem(message: "notes[\(index)]: \(problem.message)"))
            }
        }
        return .success(NoteWriteRequest(track: track, expectedName: name, startBar: bar, notes: notes))
    }

    static func note(_ item: Value) -> Result<NoteSpec, Problem> {
        guard let object = item.objectValue else { return .failure(Problem(message: "must be an object.")) }
        if let unknown = object.keys.sorted().first(where: { !noteFields.contains($0) }) {
            return .failure(Problem(message: "unknown field \"\(unknown)\"."))
        }
        guard let pitchValue = object["pitch"] else { return .failure(Problem(message: "\"pitch\" is required.")) }
        let pitch: UInt8
        if let number = MixerArguments.integer(pitchValue) {
            guard (0...127).contains(number) else { return .failure(Problem(message: "\"pitch\" must be 0–127 (got \(number)).")) }
            pitch = UInt8(number)
        } else if let text = pitchValue.stringValue {
            guard let parsed = NoteName.parse(text) else {
                return .failure(Problem(message: "\"pitch\" \"\(text)\" is not a note name such as \"C4\" (= 60), \"F#3\" or \"Bb5\", within 0–127."))
            }
            pitch = parsed
        } else {
            return .failure(Problem(message: "\"pitch\" must be a MIDI note number or a note name such as \"C4\"."))
        }
        guard let startValue = object["start_beat"], let start = MixerArguments.number(startValue), start >= 0 else {
            return .failure(Problem(message: "\"start_beat\" (quarter notes from the start bar, 0 or more) is required."))
        }
        guard let durationValue = object["duration_beats"], let duration = MixerArguments.number(durationValue), duration > 0 else {
            return .failure(Problem(message: "\"duration_beats\" (quarter notes, more than 0) is required."))
        }
        var velocity: UInt8 = 100
        if let value = object["velocity"] {
            guard let number = MixerArguments.integer(value), (1...127).contains(number) else {
                return .failure(Problem(message: "\"velocity\" must be a whole number from 1 to 127."))
            }
            velocity = UInt8(number)
        }
        return .success(NoteSpec(pitch: pitch, startBeat: start, durationBeats: duration, velocity: velocity))
    }
}

enum NoteToolSchemas {
    static let writeMIDI = Tool(
        name: "write_midi",
        title: "Record notes into a Logic track",
        description: """
            Records notes into a Logic Pro track by playing them in REAL TIME on the LogicMCP Notes \
            port while Logic records. The call takes one bar of pre-roll plus the length of the \
            material at the project tempo, plus roughly 10–20 s to read the track list, watch \
            every track's Rec LED (about 1 s per 8 tracks before and after arming, 2.2 s per 8 \
            tracks after restoring), arm the target and place the playhead. \
            No other tool can run meanwhile; to abort, press \
            Stop in Logic (the call then stops sending, releases held notes and restores the \
            record-arm states). Before recording it requires Logic to be stopped with Cycle off, \
            makes the target the only track Logic records on (it presses Rec on the target and on \
            other armed tracks, then watches the Rec LEDs: Logic blinks armed tracks' LEDs and \
            lights the selected track's steadily while none is armed; afterwards it presses the \
            same buttons again, nothing else) and moves the playhead to start_bar. Positions follow Logic's own \
            MIDI clock (Logic must send MIDI clock to LogicMCP Sync). Beats are quarter notes \
            counted from the first beat of start_bar, whatever the meter. In Replace mode (or when \
            Logic has not reported the Replace state) recording erases existing material on the \
            target track, so the result is "needs_confirmation" with a confirmation_token: ask the \
            user in chat and repeat the identical call with that token only after they explicitly \
            agree (tokens expire after 5 minutes). The status is at most "partial": Mackie Control \
            cannot see regions, so what Logic recorded is not read back; ask the user to check the \
            region. The track type cannot be checked either: use a software instrument (or \
            external MIDI) track; on an audio track Logic would record audio. At most 2000 notes \
            and 64 bars; the same pitch cannot overlap itself (the earlier note is shortened). No \
            quantize: quantize the region in Logic afterwards if needed.
            """,
        inputSchema: .object([
            "type": "object",
            "properties": .object([
                "track": .object(["type": "integer", "minimum": 1, "description": "Track number as listed by get_session_state (1 = first)."]),
                "expected_name": .object(["type": "string", "description": "The track's name; checked before anything is armed or recorded (against the full name when available, otherwise the LCD abbreviation)."]),
                "start_bar": .object(["type": "integer", "minimum": 2, "maximum": 999, "description": "Bar whose first beat is beat 0 of the notes. At least 2 (Logic pre-rolls one bar)."]),
                "notes": .object([
                    "type": "array",
                    "minItems": 1,
                    "maxItems": 2000,
                    "items": .object([
                        "type": "object",
                        "properties": .object([
                            "pitch": .object([
                                "description": "MIDI note number 0–127, or a note name with C4 = 60 (\"C4\", \"F#3\", \"Bb5\").",
                                "anyOf": .array([.object(["type": "integer", "minimum": 0, "maximum": 127]), .object(["type": "string"])]),
                            ]),
                            "start_beat": .object(["type": "number", "minimum": 0, "description": "Quarter notes after the first beat of start_bar."]),
                            "duration_beats": .object(["type": "number", "exclusiveMinimum": 0, "description": "Length in quarter notes."]),
                            "velocity": .object(["type": "integer", "minimum": 1, "maximum": 127, "description": "Default 100."]),
                        ]),
                        "required": .array(["pitch", "start_beat", "duration_beats"]),
                        "additionalProperties": false,
                    ]),
                ]),
                "confirmation_token": .object(["type": "string", "description": "Token from a previous needs_confirmation result for the same call, after the user agreed in chat."]),
            ]),
            "required": .array(["track", "expected_name", "start_bar", "notes"]),
            "additionalProperties": false,
        ]),
        // Destructive: in Replace mode (or when its state is unknown, behind the confirmation)
        // recording erases material, and every call adds a region and changes arm states while it runs.
        annotations: .init(title: "Record notes into a Logic track", readOnlyHint: false, destructiveHint: true, idempotentHint: false, openWorldHint: false)
    )
}
