import Foundation
import LogicBridge
import MIDICore

/// Console command `write` (Phase 4): the same recording as the `write_midi` tool, for checks
/// against real Logic. Notes sent are written to the traffic log.
extension Console {
    static let writeUsage = """
        Usage: write <track> <start_bar> <pitch:start:dur[:vel],...|-> [cc=...] [bend=...] [offset=<ms>] [expected name]
          beats are quarter notes from the first beat of start_bar; pitch is 0-127 or a name (C4 = 60)
          e.g. write 2 9 C4:0:1:100,E4:1:1,G4:2:2 Inst 2
          cc=<controller>:<start>:<value>[>to:dur],...   Control Changes, e.g. cc=64:0:127,64:4:0 (sustain)
                                                         or cc=1:0:0>127:4 (modulation ramp over 4 beats)
          bend=<start>:<value>[>to:dur],...              pitch bend, -8192..8191, 0 = centre, e.g. bend=1:0>8191:1,3:0
          "-" instead of the notes records controllers only
          offset=<ms> shifts every send (calibration; nothing is sent before Logic's clock reaches start_bar)
          write! confirms recording in Replace mode
        """

    func writeNotes(_ arguments: [String], replaceConfirmed: Bool) async {
        guard let request = Self.parseWrite(arguments) else {
            say(Self.writeUsage)
            return
        }
        guard let output = runtime.notesOutput else {
            say("No LogicMCP Notes port is available.")
            return
        }
        let log = self.log
        let logged = LoggedNotes(base: output, start: .now) { log.write($0) }
        let writer = makeNoteWriter(runtime: runtime, mixer: mixer, notes: logged)
        let controllers = request.controllers.isEmpty ? "" : " and \(request.controllers.count) controller change(s)"
        say("Recording \(request.notes.count) note(s)\(controllers) on track \(request.track) from bar \(request.startBar) in real time. Press Stop in Logic to abort.")
        let result = await writer.write(request, replaceConfirmed: replaceConfirmed)
        await logged.finish()
        say(Self.encodeJSON(result))
    }

    static func parseWrite(_ arguments: [String]) -> NoteWriteRequest? {
        guard arguments.count >= 3, let track = Int(arguments[0]), let bar = Int(arguments[1]) else { return nil }
        var notes: [NoteSpec] = []
        for item in arguments[2] == "-" ? [] : arguments[2].split(separator: ",") {
            let parts = item.split(separator: ":").map(String.init)
            guard (3...4).contains(parts.count),
                  let pitch = UInt8(parts[0]).flatMap({ $0 <= 127 ? $0 : nil }) ?? NoteName.parse(parts[0]),
                  let start = Double(parts[1]), let duration = Double(parts[2]) else { return nil }
            var velocity: UInt8 = 100
            if parts.count == 4 {
                guard let value = UInt8(parts[3]) else { return nil }
                velocity = value
            }
            notes.append(NoteSpec(pitch: pitch, startBeat: start, durationBeats: duration, velocity: velocity))
        }
        var offset = NoteWriteRequest.defaultTimingOffsetMs
        var controllers: [ControllerSpec] = []
        var nameWords: [String] = []
        for word in arguments.dropFirst(3) {
            let lower = word.lowercased()
            if lower.hasPrefix("offset=") {
                guard let value = Double(word.dropFirst("offset=".count)) else { return nil }
                offset = value
            } else if lower.hasPrefix("cc=") || lower.hasPrefix("bend=") {
                let isBend = lower.hasPrefix("bend=")
                for item in word.drop(while: { $0 != "=" }).dropFirst().split(separator: ",") {
                    guard let change = parseController(String(item), bend: isBend) else { return nil }
                    controllers.append(change)
                }
            } else {
                nameWords.append(word)
            }
        }
        let name = nameWords.joined(separator: " ")
        guard !notes.isEmpty || !controllers.isEmpty else { return nil }
        return NoteWriteRequest(track: track, expectedName: name.isEmpty ? nil : name, startBar: bar,
                                notes: notes, controllers: controllers, timingOffsetMs: offset)
    }

    /// `<controller>:<start>:<value>[>to:dur]` for Control Changes, `<start>:<value>[>to:dur]`
    /// for pitch bend. Range checks are left to `write_midi`'s own validation.
    static func parseController(_ item: String, bend: Bool) -> ControllerSpec? {
        var parts = item.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        let kind: ControllerSpec.Kind
        if bend {
            kind = .pitchBend
        } else {
            guard let first = parts.first, let number = UInt8(first) else { return nil }
            kind = .controlChange(number)
            parts.removeFirst()
        }
        guard (2...3).contains(parts.count), let start = Double(parts[0]) else { return nil }
        let values = parts[1].split(separator: ">", omittingEmptySubsequences: false).map(String.init)
        guard let value = Int(values[0]) else { return nil }
        switch (values.count, parts.count) {
        case (1, 2):
            return ControllerSpec(kind: kind, startBeat: start, value: value)
        case (2, 3):
            guard let to = Int(values[1]), let duration = Double(parts[2]) else { return nil }
            return ControllerSpec(kind: kind, startBeat: start, value: value, toValue: to, durationBeats: duration)
        default:
            return nil
        }
    }

    static func encodeJSON<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "(encoding failed)"
    }
}

/// Sends on `LogicMCP Notes`, then hands the messages and the send time to a background task
/// that writes them to the traffic log (time since the command started). The sender is the
/// real-time note thread, so it only takes the time and queues: formatting and file I/O happen
/// off that thread.
final class LoggedNotes: MIDIOutput, Sendable {
    struct Entry: Sendable {
        var time: ContinuousClock.Instant
        var messages: [MIDIMessage]
    }

    private let base: any MIDIOutput
    private let queue: AsyncStream<Entry>.Continuation
    private let drain: Task<Void, Never>

    init(base: any MIDIOutput, start: ContinuousClock.Instant, write: @escaping @Sendable (String) -> Void) {
        self.base = base
        let (stream, queue) = AsyncStream.makeStream(of: Entry.self, bufferingPolicy: .unbounded)
        self.queue = queue
        drain = Task.detached(priority: .utility) {
            for await entry in stream { write(Self.line(entry, start: start)) }
        }
    }

    func send(_ messages: [MIDIMessage]) throws {
        try base.send(messages)
        queue.yield(Entry(time: .now, messages: messages))
    }

    /// Writes what is still queued; call once sending is over.
    func finish() async {
        queue.finish()
        await drain.value
    }

    static func line(_ entry: Entry, start: ContinuousClock.Instant) -> String {
        let elapsed = String(format: "%+9.3f", start.duration(to: entry.time).seconds)
        return "\(elapsed) NOTES " + entry.messages.map(\.bytes.hexString).joined(separator: " | ")
    }
}
