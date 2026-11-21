import Foundation
import MIDICore

/// One note for `write_midi`. Beats are quarter notes (24 MIDI clocks), counted from the first
/// beat of the start bar, whatever the project's meter.
public struct NoteSpec: Sendable, Equatable {
    public var pitch: UInt8
    public var startBeat: Double
    public var durationBeats: Double
    public var velocity: UInt8

    public init(pitch: UInt8, startBeat: Double, durationBeats: Double, velocity: UInt8 = 100) {
        self.pitch = pitch
        self.startBeat = startBeat
        self.durationBeats = durationBeats
        self.velocity = velocity
    }
}

/// One controller change for `write_midi`: a Control Change or pitch bend at a beat, or a
/// straight ramp from `value` to `toValue` over `durationBeats`. Sent on MIDI channel 1 with the
/// notes, so Logic records it into the same region.
public struct ControllerSpec: Sendable, Equatable {
    public enum Kind: Sendable, Equatable, Hashable {
        /// Controller number 0–119, minus `reservedControllers`.
        case controlChange(UInt8)
        case pitchBend
    }

    public var kind: Kind
    public var startBeat: Double
    /// Control Change: 0–127. Pitch bend: −8192…8191, 0 = centre.
    public var value: Int
    /// End value of a ramp; nil for a single change.
    public var toValue: Int?
    /// Length of a ramp in quarter notes; required (more than 0) with `toValue`.
    public var durationBeats: Double?

    public init(kind: Kind, startBeat: Double, value: Int, toValue: Int? = nil, durationBeats: Double? = nil) {
        self.kind = kind
        self.startBeat = startBeat
        self.value = value
        self.toValue = toValue
        self.durationBeats = durationBeats
    }

    public static func controlChange(_ controller: UInt8, at beat: Double, _ value: Int) -> ControllerSpec {
        ControllerSpec(kind: .controlChange(controller), startBeat: beat, value: value)
    }

    public static func pitchBend(at beat: Double, _ value: Int) -> ControllerSpec {
        ControllerSpec(kind: .pitchBend, startBeat: beat, value: value)
    }

    var endBeat: Double { startBeat + (durationBeats ?? 0) }

    var valueRange: ClosedRange<Int> {
        switch kind {
        case .controlChange: return 0...127
        case .pitchBend: return -8192...8191
        }
    }

    var label: String {
        switch kind {
        case let .controlChange(number): return "CC \(number)"
        case .pitchBend: return "pitch bend"
        }
    }

    func message(_ value: Int) -> MIDIMessage {
        switch kind {
        case let .controlChange(number): return .controlChange(channel: 0, controller: number, value: UInt8(value))
        case .pitchBend: return .pitchBend(channel: 0, value: UInt16(value + 8192))
        }
    }

    /// CC 120–127 are channel mode messages (All Sound Off, Reset All Controllers, All Notes
    /// Off, …), not controllers; the server sends CC 123 itself after an aborted recording.
    public static let channelModeControllers: ClosedRange<UInt8> = 120...127
    /// CC 20–39 trigger the learned key commands on `LogicMCP Keys` (channel 16). Logic's
    /// controller assignments are expected to match port and channel, so the same numbers on
    /// channel 1 of `LogicMCP Notes` should not trigger them, but that is not yet checked on
    /// real Logic, and CC 29 deletes a track: refused until it is.
    public static let reservedControllers: ClosedRange<UInt8> = 20...39
    /// Controllers that Logic may apply to the channel strip (volume, pan) instead of, or as
    /// well as, recording them.
    public static let channelStripControllers: Set<UInt8> = [7, 10]
    /// Ramps are sent in steps of at most this many MIDI clocks (1/48 quarter note), and only
    /// when the value changes.
    public static let rampStepTicks = 0.5
}

/// Note names with C4 = 60 (Logic's default octave numbering): "C4", "F#3", "Bb-1", "G9".
public enum NoteName {
    public static func parse(_ text: String) -> UInt8? {
        var rest = Substring(text.trimmingCharacters(in: .whitespaces))
        guard let letter = rest.first?.uppercased().first,
              let base = ["C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11][String(letter)] else { return nil }
        rest = rest.dropFirst()
        var semitone = base
        while let accidental = rest.first, "#♯b♭".contains(accidental) {
            semitone += (accidental == "#" || accidental == "♯") ? 1 : -1
            rest = rest.dropFirst()
        }
        guard !rest.isEmpty, let octave = Int(rest), (-1...9).contains(octave) else { return nil }
        let value = (octave + 1) * 12 + semitone
        guard (0...127).contains(value) else { return nil }
        return UInt8(value)
    }

    public static func name(_ pitch: UInt8) -> String {
        let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
        return names[Int(pitch) % 12] + String(Int(pitch) / 12 - 1)
    }
}

/// Input of `write_midi`.
public struct NoteWriteRequest: Sendable, Equatable {
    public var track: Int
    /// Checked against the track's name before anything is changed (full name when
    /// Accessibility supplies one, otherwise the LCD abbreviation).
    public var expectedName: String?
    /// Bar whose first beat is beat 0 of the notes. At least 2: Logic pre-rolls one bar.
    public var startBar: Int
    public var notes: [NoteSpec]
    /// Control Changes and pitch bends recorded along with the notes.
    public var controllers: [ControllerSpec]
    /// Calibration: added to every send time (positive = later). No note is sent before Logic's
    /// clock has reached the first tick of the start bar (the record-in point), whatever the
    /// offset: notes that a negative offset would move earlier than that are sent there.
    public var timingOffsetMs: Double

    /// Measured on Logic 13 (2026-11-21, 120 BPM, this Mac): without an offset every note was
    /// recorded 5–6 ticks (about 3 ms) before its grid position; with +3 ms all 16 sixteenths of
    /// a test bar landed exactly on the grid (docs/checklists/phase-4-results.md). Not yet
    /// measured at other tempos or buffer sizes.
    public static let defaultTimingOffsetMs = 3.0

    public init(track: Int, expectedName: String? = nil, startBar: Int, notes: [NoteSpec],
                controllers: [ControllerSpec] = [],
                timingOffsetMs: Double = NoteWriteRequest.defaultTimingOffsetMs) {
        self.track = track
        self.expectedName = expectedName
        self.startBar = startBar
        self.notes = notes
        self.controllers = controllers
        self.timingOffsetMs = timingOffsetMs
    }

    public static let maxNotes = 2000
    public static let maxControllers = 2000
    /// Messages after ramps are expanded: each one costs the note thread a wake-up and a short
    /// busy-wait, so long ramps must not turn it into a busy loop.
    public static let maxControllerMessages = 4000
    public static let maxBars = 64
    /// Absolute bound checked before anything is sent (64 bars of 16/4); the 64-bar limit itself
    /// is checked against the bar length Logic reports at the start bar.
    public static let maxBeats = 1024.0
}

/// The notes and controller changes of a request as timed MIDI events, validated.
struct NotePlan: Sendable {
    struct Event: Sendable, Equatable {
        /// Ticks (24 per quarter note) after the first beat of the start bar.
        var tick: Double
        var pitch: UInt8
        var velocity: UInt8
        var isOn: Bool
        /// Index into the request's notes.
        var note: Int

        var message: MIDIMessage {
            isOn ? .noteOn(channel: 0, note: pitch, velocity: velocity) : .noteOff(channel: 0, note: pitch, velocity: 0)
        }
    }

    /// One Control Change or pitch bend message (one step of a ramp, or a single change).
    struct ControlEvent: Sendable, Equatable {
        /// Ticks (24 per quarter note) after the first beat of the start bar.
        var tick: Double
        var message: MIDIMessage
        /// Index into the request's controllers.
        var controller: Int
    }

    /// Events sharing one tick, sent together: note-offs, then controller changes, then
    /// note-ons, so a note starts with the bend and controller values meant for it.
    struct Group: Sendable, Equatable {
        var tick: Double
        var events: [Event]
        var controls: [ControlEvent] = []

        var messages: [MIDIMessage] {
            events.filter { !$0.isOn }.map(\.message) + controls.map(\.message) + events.filter(\.isOn).map(\.message)
        }
    }

    var groups: [Group]
    /// End of the material in quarter notes (last note-off or controller change).
    var endBeats: Double
    var noteCount: Int
    /// Controller messages after ramps are expanded.
    var controlCount: Int
    /// The material bends pitch or uses the sustain pedal: both are reset after Stop.
    var usesPitchBend: Bool
    var usesSustain: Bool
    var warnings: [String]

    static func make(_ request: NoteWriteRequest) -> Result<NotePlan, Problem> {
        guard request.track >= 1 else { return .failure(Problem("Track numbers start at 1 (got \(request.track)).")) }
        guard request.startBar >= 2 else {
            return .failure(Problem("start_bar must be 2 or later (got \(request.startBar)): Logic pre-rolls one bar before the start, and MIDI Song Position cannot describe positions before bar 1."))
        }
        guard request.startBar <= 999 else { return .failure(Problem("start_bar must be at most 999 (the time display has three bar digits).")) }
        guard !request.notes.isEmpty || !request.controllers.isEmpty else {
            return .failure(Problem("Give at least one note or controller change."))
        }
        guard request.notes.count <= NoteWriteRequest.maxNotes else {
            return .failure(Problem("At most \(NoteWriteRequest.maxNotes) notes per call (got \(request.notes.count))."))
        }
        guard request.controllers.count <= NoteWriteRequest.maxControllers else {
            return .failure(Problem("At most \(NoteWriteRequest.maxControllers) controller changes per call (got \(request.controllers.count))."))
        }
        guard request.timingOffsetMs.isFinite, abs(request.timingOffsetMs) <= 200 else {
            return .failure(Problem("The timing offset must be between -200 and +200 ms."))
        }
        for (index, note) in request.notes.enumerated() {
            guard note.pitch <= 127 else { return .failure(Problem("notes[\(index)]: pitch must be 0–127.")) }
            guard (1...127).contains(note.velocity) else { return .failure(Problem("notes[\(index)]: velocity must be 1–127.")) }
            guard note.startBeat.isFinite, note.startBeat >= 0 else { return .failure(Problem("notes[\(index)]: start_beat must be 0 or more.")) }
            guard note.durationBeats.isFinite, note.durationBeats > 0 else { return .failure(Problem("notes[\(index)]: duration_beats must be more than 0.")) }
            guard note.startBeat + note.durationBeats <= NoteWriteRequest.maxBeats else {
                return .failure(Problem("notes[\(index)] ends after \(NoteWriteRequest.maxBeats) quarter notes; the material must fit in \(NoteWriteRequest.maxBars) bars."))
            }
        }
        for (index, spec) in request.controllers.enumerated() {
            if let problem = check(spec) { return .failure(Problem("controllers[\(index)]: \(problem)")) }
        }

        // Same pitch: a later note-on must not be cut by an earlier note's note-off.
        var ends = request.notes.map { $0.startBeat + $0.durationBeats }
        var warnings: [String] = []
        let byPitch = Dictionary(grouping: request.notes.indices, by: { request.notes[$0].pitch })
        for (pitch, indices) in byPitch.sorted(by: { $0.key < $1.key }) {
            let ordered = indices.sorted { (request.notes[$0].startBeat, $0) < (request.notes[$1].startBeat, $1) }
            for (earlier, later) in zip(ordered, ordered.dropFirst()) {
                let laterStart = request.notes[later].startBeat
                if request.notes[earlier].startBeat == laterStart {
                    return .failure(Problem("notes[\(earlier)] and notes[\(later)] are the same pitch (\(NoteName.name(pitch))) at the same start_beat \(format(laterStart))."))
                }
                if ends[earlier] > laterStart {
                    warnings.append("notes[\(earlier)] (\(NoteName.name(pitch)) at beat \(format(request.notes[earlier].startBeat))) overlaps the next \(NoteName.name(pitch)) and was shortened to end at beat \(format(laterStart)): one MIDI channel cannot hold the same pitch twice.")
                    ends[earlier] = laterStart
                }
            }
        }

        // Same controller: changes must not overlap, or two ramps would fight over one value.
        // A ramp may start where the previous one ends (the later value wins at that tick).
        let specs = request.controllers
        let byKind = Dictionary(grouping: specs.indices, by: { specs[$0].kind })
        var lastValues: [ControllerSpec.Kind: Int] = [:]
        for (kind, indices) in byKind.sorted(by: { specs[$0.value[0]].label < specs[$1.value[0]].label }) {
            let ordered = indices.sorted { (specs[$0].startBeat, $0) < (specs[$1].startBeat, $1) }
            for (earlier, later) in zip(ordered, ordered.dropFirst()) {
                let a = specs[earlier], b = specs[later]
                // Beats such as 0.1 + 0.2 do not add up exactly: compare within `beatTolerance`.
                if b.startBeat < a.endBeat - beatTolerance || abs(b.startBeat - a.startBeat) <= beatTolerance {
                    return .failure(Problem("controllers[\(earlier)] and controllers[\(later)] both change \(a.label) at beat \(format(b.startBeat)): changes of one controller must not overlap."))
                }
            }
            if let last = ordered.last { lastValues[kind] = specs[last].toValue ?? specs[last].value }
        }

        var events: [Event] = []
        for (index, note) in request.notes.enumerated() {
            events.append(Event(tick: snap(note.startBeat * 24), pitch: note.pitch, velocity: note.velocity, isOn: true, note: index))
            events.append(Event(tick: snap(ends[index] * 24), pitch: note.pitch, velocity: 0, isOn: false, note: index))
        }
        events.sort { a, b in
            if a.tick != b.tick { return a.tick < b.tick }
            if a.isOn != b.isOn { return !a.isOn }
            return (a.pitch, a.note) < (b.pitch, b.note)
        }

        let controls = expand(specs)
        guard controls.count <= NoteWriteRequest.maxControllerMessages else {
            return .failure(Problem("The controller changes come to \(controls.count) MIDI messages (ramps are sent every 1/48 quarter note where the value changes); at most \(NoteWriteRequest.maxControllerMessages) per call. Use fewer or shorter ramps."))
        }

        var byTick: [Double: Group] = [:]
        for event in events { byTick[event.tick, default: Group(tick: event.tick, events: [])].events.append(event) }
        for control in controls { byTick[control.tick, default: Group(tick: control.tick, events: [])].controls.append(control) }
        let groups = byTick.keys.sorted().map { byTick[$0]! }

        warnings += controllerWarnings(specs, lastValues: lastValues)
        let endBeats = max(ends.max() ?? 0, specs.map(\.endBeat).max() ?? 0)
        return .success(NotePlan(
            groups: groups, endBeats: endBeats, noteCount: request.notes.count, controlCount: controls.count,
            usesPitchBend: byKind[.pitchBend] != nil, usesSustain: byKind[.controlChange(64)] != nil,
            warnings: warnings))
    }

    /// Positions closer than this (in quarter notes) count as the same.
    static let beatTolerance = 1e-9

    /// Ticks rounded to a millionth of a MIDI clock, so that positions that are equal in beats
    /// (a ramp ending at 0.1 + 0.2, a note at 0.3) land in one group and keep its order.
    static func snap(_ tick: Double) -> Double {
        (tick * 1_000_000).rounded() / 1_000_000
    }

    /// Why a controller change cannot be sent; nil when it can.
    static func check(_ spec: ControllerSpec) -> String? {
        if case let .controlChange(number) = spec.kind {
            guard number <= 127 else { return "controller must be 0–119." }
            if ControllerSpec.channelModeControllers.contains(number) {
                return "CC 120–127 are channel mode messages (All Sound Off, Reset All Controllers, All Notes Off, …), not controllers."
            }
            if ControllerSpec.reservedControllers.contains(number) {
                return "CC 20–39 are refused for now: the same numbers trigger the learned key commands on LogicMCP Keys (channel 16), and it is not yet checked on real Logic that they leave them alone when sent on LogicMCP Notes (CC 29 deletes a track)."
            }
        }
        guard spec.startBeat.isFinite, spec.startBeat >= 0 else { return "start_beat must be 0 or more." }
        let range = spec.valueRange
        let rangeText = spec.kind == .pitchBend ? "−8192…8191 for pitch bend (0 = centre)" : "0–127 for a Control Change"
        guard range.contains(spec.value) else { return "value must be \(rangeText) (got \(spec.value))." }
        if let to = spec.toValue {
            guard range.contains(to) else { return "to_value must be \(rangeText) (got \(to))." }
            guard let duration = spec.durationBeats, duration.isFinite, duration > 0 else {
                return "duration_beats (quarter notes, more than 0) is required with to_value."
            }
        } else if spec.durationBeats != nil {
            return "duration_beats makes a ramp and needs to_value (the value the ramp ends at)."
        }
        guard spec.endBeat <= NoteWriteRequest.maxBeats else {
            return "it ends after \(NoteWriteRequest.maxBeats) quarter notes; the material must fit in \(NoteWriteRequest.maxBars) bars."
        }
        return nil
    }

    /// Single changes as one message; ramps as steps of at most `rampStepTicks`, only where
    /// the rounded value changes, ending exactly on `toValue`. Sorted by tick, then by the
    /// change's start beat and index (at a shared tick the later change wins).
    static func expand(_ specs: [ControllerSpec]) -> [ControlEvent] {
        var keyed: [(event: ControlEvent, start: Double, index: Int, step: Int)] = []
        for (index, spec) in specs.enumerated() {
            let startTick = spec.startBeat * 24
            guard let to = spec.toValue, let duration = spec.durationBeats else {
                keyed.append((ControlEvent(tick: snap(startTick), message: spec.message(spec.value), controller: index), spec.startBeat, index, 0))
                continue
            }
            let span = duration * 24
            let steps = max(1, Int((span / ControllerSpec.rampStepTicks).rounded(.up)))
            var last: Int?
            for step in 0...steps {
                let value = step == steps
                    ? to
                    : Int((Double(spec.value) + Double(to - spec.value) * Double(step) / Double(steps)).rounded())
                if value == last { continue }
                last = value
                let tick = snap(step == steps ? spec.endBeat * 24 : startTick + span * Double(step) / Double(steps))
                keyed.append((ControlEvent(tick: tick, message: spec.message(value), controller: index), spec.startBeat, index, step))
            }
        }
        keyed.sort { ($0.event.tick, $0.start, $0.index, $0.step) < ($1.event.tick, $1.start, $1.index, $1.step) }
        return keyed.map(\.event)
    }

    static func controllerWarnings(_ specs: [ControllerSpec], lastValues: [ControllerSpec.Kind: Int]) -> [String] {
        var warnings: [String] = []
        let stripControllers = Set(specs.compactMap { spec -> UInt8? in
            if case let .controlChange(number) = spec.kind, ControllerSpec.channelStripControllers.contains(number) { return number }
            return nil
        })
        if !stripControllers.isEmpty {
            let names = stripControllers.sorted().map { $0 == 7 ? "CC 7 (volume)" : "CC 10 (pan)" }.joined(separator: " and ")
            warnings.append("\(names) may also move the track's channel-strip \(stripControllers.count == 2 ? "volume and pan" : stripControllers.contains(7) ? "volume" : "pan") in Logic (a project MIDI setting decides; not yet checked on real Logic); get_session_state and mixer_set would then see the changed values.")
        }
        if let bend = lastValues[.pitchBend], bend != 0 {
            warnings.append("The pitch bend ends at \(bend), not 0 (centre): the region keeps that bend after its last change. Add a pitch bend of 0 at the end if that is not wanted. The server centres the bend after Stop, which is not recorded.")
        }
        if let sustain = lastValues[.controlChange(64)], sustain >= 64 {
            warnings.append("The sustain pedal (CC 64) ends down (\(sustain)): the region ends with the pedal held. Add CC 64 = 0 at the end if that is not wanted. The server releases the pedal after Stop, which is not recorded.")
        }
        return warnings
    }

    struct Problem: Error, Equatable {
        var message: String
        init(_ message: String) { self.message = message }
    }

    static func format(_ beats: Double) -> String {
        beats == beats.rounded() ? String(Int(beats)) : String(format: "%.3f", beats).replacingOccurrences(of: "0+$", with: "", options: .regularExpression)
    }
}

/// Result payload of `write_midi`.
public struct NoteWriteReport: Sendable, Codable, Equatable {
    public struct ArmState: Sendable, Codable, Equatable {
        public var track: Int
        public var name: String
        /// The Rec LED while it was watched: "alternating" = record-armed, "steady" = the
        /// selected track, record-enabled because no track is armed, "off"; nil = not reported.
        public var light: RecordArmLight?
    }

    /// Positions are in sixteenths (Logic's Song Position Pointer); times in ms.
    public struct Timing: Sendable, Codable, Equatable {
        /// SPP Logic sent after the playhead reached the start bar.
        public var startBarSongPosition: Int?
        /// Length of one bar at the start bar, from the SPP difference between neighbouring bars.
        public var barLengthSixteenths: Int?
        /// The song position of the first clock after Record (the pre-roll start).
        public var recordStartSongPosition: Double?
        public var preRollSixteenths: Double?
        /// SPP Logic sent after Stop.
        public var stopSongPosition: Int?
        public var displayAtStart: String?
        public var displayAtStop: String?
        /// Clock position (sixteenths after the start bar) when the time display first showed
        /// the start bar; a cross-check of the clock against the display (display lag included).
        public var displayStartBarOffsetSixteenths: Double?
        public var tempoBPM: Double?
        /// Send time minus the time Logic's clock reached the note's position (the clock's
        /// CoreMIDI timestamps, or its arrival times where it carried none).
        public var maxSchedulingErrorMs: Double?
        public var meanSchedulingErrorMs: Double?
        /// Irregularity of the clock times themselves (RMS around a fitted line).
        public var clockJitterMs: Double?
        /// How many of the run's clocks carried a CoreMIDI timestamp (0: all were timed on arrival).
        public var clocksWithTimestamp: Int?
        /// For those clocks, timestamp minus arrival at the server (positive: Logic sent the
        /// clock ahead of time and CoreMIDI delivered it early).
        public var clockTimestampLeadMaxMs: Double?
        public var clockTimestampLeadMinMs: Double?
        public var clockTimestampLeadMeanMs: Double?
        public var timingOffsetMs: Double
        public var recordedSeconds: Double?
    }

    public var track: Int
    public var trackName: String?
    public var startBar: Int
    public var notesRequested: Int
    public var noteOnsSent: Int
    public var noteOffsSent: Int
    /// Controller changes asked for, and the Control Change / pitch bend messages sent for
    /// them (a ramp is several messages).
    public var controllerChangesRequested: Int = 0
    public var controllerMessagesSent: Int = 0
    public var timing: Timing
    public var armBefore: [ArmState]
    public var armAfter: [ArmState]
    public var transport: TransportSnapshot?
}
