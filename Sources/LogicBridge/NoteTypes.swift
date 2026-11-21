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
                timingOffsetMs: Double = NoteWriteRequest.defaultTimingOffsetMs) {
        self.track = track
        self.expectedName = expectedName
        self.startBar = startBar
        self.notes = notes
        self.timingOffsetMs = timingOffsetMs
    }

    public static let maxNotes = 2000
    public static let maxBars = 64
    /// Absolute bound checked before anything is sent (64 bars of 16/4); the 64-bar limit itself
    /// is checked against the bar length Logic reports at the start bar.
    public static let maxBeats = 1024.0
}

/// The notes of a request as timed MIDI events, validated.
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

    /// Events sharing one tick, sent together (note-offs first).
    struct Group: Sendable, Equatable {
        var tick: Double
        var events: [Event]
    }

    var groups: [Group]
    /// End of the material in quarter notes (last note-off).
    var endBeats: Double
    var noteCount: Int
    var warnings: [String]

    static func make(_ request: NoteWriteRequest) -> Result<NotePlan, Problem> {
        guard request.track >= 1 else { return .failure(Problem("Track numbers start at 1 (got \(request.track)).")) }
        guard request.startBar >= 2 else {
            return .failure(Problem("start_bar must be 2 or later (got \(request.startBar)): Logic pre-rolls one bar before the start, and MIDI Song Position cannot describe positions before bar 1."))
        }
        guard request.startBar <= 999 else { return .failure(Problem("start_bar must be at most 999 (the time display has three bar digits).")) }
        guard !request.notes.isEmpty else { return .failure(Problem("Give at least one note.")) }
        guard request.notes.count <= NoteWriteRequest.maxNotes else {
            return .failure(Problem("At most \(NoteWriteRequest.maxNotes) notes per call (got \(request.notes.count))."))
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

        var events: [Event] = []
        for (index, note) in request.notes.enumerated() {
            events.append(Event(tick: note.startBeat * 24, pitch: note.pitch, velocity: note.velocity, isOn: true, note: index))
            events.append(Event(tick: ends[index] * 24, pitch: note.pitch, velocity: 0, isOn: false, note: index))
        }
        events.sort { a, b in
            if a.tick != b.tick { return a.tick < b.tick }
            if a.isOn != b.isOn { return !a.isOn }
            return (a.pitch, a.note) < (b.pitch, b.note)
        }
        var groups: [Group] = []
        for event in events {
            if let last = groups.last, last.tick == event.tick {
                groups[groups.count - 1].events.append(event)
            } else {
                groups.append(Group(tick: event.tick, events: [event]))
            }
        }
        return .success(NotePlan(groups: groups, endBeats: ends.max() ?? 0, noteCount: request.notes.count, warnings: warnings))
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
    public var timing: Timing
    public var armBefore: [ArmState]
    public var armAfter: [ArmState]
    public var transport: TransportSnapshot?
}
