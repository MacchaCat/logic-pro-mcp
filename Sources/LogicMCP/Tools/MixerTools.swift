import Foundation
import LogicAX
import LogicBridge
import MCP

/// Phase 2 tools: session state with the track list, and mixer changes.
struct MixerTools: ToolModule {
    let mixer: MixerController

    static func make(runtime: LogicRuntime) async -> MixerTools {
        MixerTools(mixer: makeMixerController(runtime: runtime))
    }

    var tools: [Tool] { [MixerToolSchemas.sessionState, MixerToolSchemas.mixerSet] }

    func call(_ name: String, _ arguments: [String: Value], context: ToolContext) async -> CallTool.Result? {
        switch name {
        case "get_session_state":
            let state = await sessionState(arguments, runtime: context.runtime)
            return context.encode(state, isError: false)
        case "mixer_set":
            switch MixerArguments.changes(arguments) {
            case .failure(let problem):
                return context.encode(OperationResult<[TrackInfo]>(status: .failed, summary: problem.message + " Nothing was sent."))
            case .success(let changes):
                return context.encode(await mixer.set(changes))
            }
        default:
            return nil
        }
    }

    private func sessionState(_ arguments: [String: Value], runtime: LogicRuntime) async -> SessionState {
        let include = Set(arguments["include"]?.arrayValue?.compactMap(\.stringValue) ?? ["transport", "tempo"])
        let transport = await runtime.transport.snapshot()
        var tempo: SessionState.Tempo?
        if include.contains("tempo") {
            if let bpm = transport.sync.tempoBPM {
                tempo = .init(bpm: bpm, source: "midi_clock", note: "Estimated from Logic's MIDI clock while playing.")
            } else {
                tempo = .init(bpm: nil, source: nil, note: "Unavailable: Logic is stopped, has only just started playing (the estimate needs about one beat of clock), or is not sending MIDI clock to LogicMCP Sync. Mackie Control does not carry tempo (research §2.2); the analysis plug-in (Phase 5) will provide it while stopped.")
            }
        }
        var state = SessionState(
            transport: include.contains("transport") ? transport : nil,
            tempo: tempo,
            asOf: OperationResult<TransportSnapshot>(status: .verified, summary: "").asOf
        )
        if include.contains("tracks") {
            let scan = await mixer.tracks(refresh: arguments["refresh"]?.boolValue ?? false)
            state.tracks = scan.after?.tracks
            state.trackCount = scan.after?.trackCount
            state.tracksAsOf = scan.after?.asOf
            state.tracksCached = scan.after?.cached
            state.tracksStatus = scan.status.rawValue
            if scan.status != .verified { state.warnings.append(scan.summary) }
            state.warnings += scan.warnings
        }
        return state
    }
}

/// Wires a mixer controller to the runtime: the fake's names in `--fake` mode (never real
/// Accessibility, so tests do not read the user's Logic), Logic's track headers otherwise.
func makeMixerController(runtime: LogicRuntime) -> MixerController {
    let names: any TrackNameSource
    if let host = runtime.fakeHost {
        names = ClosureTrackNameSource { TrackNameList(names: await host.trackNames) }
    } else {
        let reader = LogicTrackNameReader()
        names = ClosureTrackNameSource {
            let reading = await reader.read()
            return TrackNameList(names: reading.names, failure: reading.failure, notes: reading.notes)
        }
    }
    return MixerController(mcu: runtime.mcu, sync: runtime.sync, names: names)
}

/// Parsing of `mixer_set` arguments (also used by the console).
enum MixerArguments {
    struct Problem: Error { let message: String }

    static let changeFields: Set<String> = ["track", "expected_name", "volume_db", "pan", "mute", "solo"]

    static func changes(_ arguments: [String: Value]) -> Result<[MixerChange], Problem> {
        if let list = arguments["changes"] {
            // Fields of a single change next to "changes" would be silently dropped.
            if let other = arguments.keys.filter({ $0 != "changes" }).sorted().first {
                return .failure(Problem(message: changeFields.contains(other)
                    ? "Give either \"changes\" or the fields of a single change, not both (\"\(other)\" given next to \"changes\")."
                    : "Unknown field \"\(other)\"."))
            }
            guard let items = list.arrayValue, !items.isEmpty else {
                return .failure(Problem(message: "\"changes\" must be a non-empty array."))
            }
            guard items.count <= 64 else {
                return .failure(Problem(message: "At most 64 changes per call."))
            }
            var changes: [MixerChange] = []
            for (index, item) in items.enumerated() {
                guard let object = item.objectValue else {
                    return .failure(Problem(message: "changes[\(index)] must be an object."))
                }
                switch change(object) {
                case .success(let change): changes.append(change)
                case .failure(let problem): return .failure(Problem(message: "changes[\(index)]: \(problem.message)"))
                }
            }
            return .success(changes)
        }
        return change(arguments).map { [$0] }
    }

    static func change(_ object: [String: Value]) -> Result<MixerChange, Problem> {
        if let unknown = object.keys.sorted().first(where: { !changeFields.contains($0) }) {
            return .failure(Problem(message: "Unknown field \"\(unknown)\"."))
        }
        guard let trackValue = object["track"], let track = integer(trackValue) else {
            return .failure(Problem(message: "\"track\" (a track number, 1 = first) is required."))
        }
        var change = MixerChange(track: track)
        if let name = object["expected_name"] {
            guard let text = name.stringValue else { return .failure(Problem(message: "\"expected_name\" must be a string.")) }
            change.expectedName = text
        }
        if let volume = object["volume_db"] {
            if let number = number(volume) {
                change.volume = .db(number)
            } else if let text = volume.stringValue, let level = VolumeLevel.parse(text) {
                change.volume = level
            } else {
                return .failure(Problem(message: "\"volume_db\" must be a number (dB) or \"-inf\"."))
            }
        }
        if let pan = object["pan"] {
            guard let value = integer(pan) else { return .failure(Problem(message: "\"pan\" must be a whole number from -64 to 63.")) }
            change.pan = value
        }
        if let mute = object["mute"] {
            guard let value = mute.boolValue else { return .failure(Problem(message: "\"mute\" must be true or false.")) }
            change.mute = value
        }
        if let solo = object["solo"] {
            guard let value = solo.boolValue else { return .failure(Problem(message: "\"solo\" must be true or false.")) }
            change.solo = value
        }
        return .success(change)
    }

    static func number(_ value: Value) -> Double? {
        if let int = value.intValue { return Double(int) }
        if let double = value.doubleValue, double.isFinite { return double }
        return nil
    }

    /// Accepts 3 and 3.0, not 3.5.
    static func integer(_ value: Value) -> Int? {
        if let int = value.intValue { return int }
        if let double = value.doubleValue, double.isFinite, double.rounded() == double, abs(double) < 1e9 { return Int(double) }
        return nil
    }
}

enum MixerToolSchemas {
    static let sessionState = Tool(
        name: "get_session_state",
        title: "Logic session state",
        description: """
            Reads Logic Pro's current state without changing the project: transport (playing, \
            recording, Replace/Cycle, position from the time display), tempo (estimated from \
            Logic's MIDI clock while playing; null otherwise) and, with "tracks" in include, every \
            track: number, name, name_source ("accessibility" = full name from Logic's track \
            headers, "lcd" = the 6-character Mackie abbreviation), lcd_name, volume_db (number, or \
            "-inf"), fader_position, pan (-64..63), mute, solo (record arm is not listed: one look at Logic's \
            Rec LEDs cannot tell it). Reading tracks pages the \
            emulated control surface through the whole track list (about 0.1 s per track beyond \
            8, plus about 0.5 s; about 0.5 s per track where 8 neighbouring tracks look the same \
            on the 6-character LCD, e.g. "Audio 1", "Audio 2" … all show "Audio"), then returns \
            it to where it was; a scan younger than 30 s is \
            reused unless refresh is true. null means Logic did not show the value; check warnings. \
            tracks_status is "unverified" when the end of the track list could not be confirmed \
            (track_count may be too low) and "failed" when Logic did not react to the surface.
            """,
        inputSchema: .object([
            "type": "object",
            "properties": .object([
                "include": .object([
                    "type": "array",
                    "items": .object(["type": "string", "enum": .array(["transport", "tempo", "tracks"])]),
                    "description": "Default: transport and tempo.",
                ]),
                "refresh": .object(["type": "boolean", "description": "Rescan the tracks even if a recent scan exists."]),
            ]),
            "additionalProperties": false,
        ]),
        annotations: .init(title: "Logic session state", readOnlyHint: true, idempotentHint: true, openWorldHint: false)
    )

    static let changeProperties: [String: Value] = [
        "track": .object(["type": "integer", "minimum": 1, "description": "Track number as listed by get_session_state (1 = first)."]),
        "expected_name": .object(["type": "string", "description": "Recommended. The track's name; checked before anything is changed (against the full name when available, otherwise the LCD abbreviation). Without full names, a name of only non-ASCII characters cannot be checked and the call fails."]),
        "volume_db": .object(["description": "Fader level in dB, -106 to +6, or \"-inf\" for silence.",
                              "anyOf": .array([.object(["type": "number", "minimum": -106, "maximum": 6]),
                                               .object(["type": "string", "enum": .array(["-inf"])])])]),
        "pan": .object(["type": "integer", "minimum": -64, "maximum": 63]),
        "mute": .object(["type": "boolean"]),
        "solo": .object(["type": "boolean"]),
    ]

    static let mixerSet = Tool(
        name: "mixer_set",
        title: "Set Logic mixer values",
        description: """
            Sets volume, pan, mute and/or solo of tracks in Logic Pro through the emulated Mackie \
            Control surface, each verified against Logic's own feedback (fader echo or the "x.x \
            dB" LCD text, the pan value on the LCD, the Mute/Solo LEDs). Only runs while Logic is \
            stopped (during playback a touched fader can write automation); otherwise fails and \
            sends nothing. Give one track (track plus fields) or several in "changes". Every \
            track and expected_name is checked before anything is changed. Mute/solo are pressed \
            only when the LED differs. Returns before/after per track; status "partial" lists \
            what failed in warnings. Values set while stopped are overridden on playback by \
            automation in Read mode.
            """,
        inputSchema: .object([
            "type": "object",
            "properties": .object(changeProperties.merging([
                "changes": .object([
                    "type": "array",
                    "minItems": 1,
                    "maxItems": 64,
                    "items": .object([
                        "type": "object",
                        "properties": .object(changeProperties),
                        "required": .array(["track"]),
                        "additionalProperties": false,
                    ]),
                ]),
            ]) { first, _ in first }),
            "additionalProperties": false,
        ]),
        annotations: .init(title: "Set Logic mixer values", readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false)
    )
}

struct SessionState: Codable, Sendable {
    struct Tempo: Codable, Sendable {
        var bpm: Double?
        var source: String?
        var note: String?
    }

    var transport: TransportSnapshot?
    var tempo: Tempo?
    var tracks: [TrackInfo]?
    var trackCount: Int?
    var tracksAsOf: String?
    var tracksCached: Bool?
    /// The track scan's status: "verified", "unverified" (the track count is not confirmed; see
    /// warnings) or "failed".
    var tracksStatus: String?
    var warnings: [String] = []
    var asOf: String

    enum CodingKeys: String, CodingKey {
        case transport, tempo, tracks, warnings
        case trackCount = "track_count"
        case tracksAsOf = "tracks_as_of"
        case tracksCached = "tracks_cached"
        case tracksStatus = "tracks_status"
        case asOf = "as_of"
    }
}
