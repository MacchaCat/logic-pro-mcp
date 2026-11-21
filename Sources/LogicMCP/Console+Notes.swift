import Foundation
import LogicBridge
import MIDICore

/// Console command `write` (Phase 4): the same recording as the `write_midi` tool, for checks
/// against real Logic. Notes sent are written to the traffic log.
extension Console {
    static let writeUsage = """
        Usage: write <track> <start_bar> <pitch:start:dur[:vel],...> [offset=<ms>] [expected name]
          beats are quarter notes from the first beat of start_bar; pitch is 0-127 or a name (C4 = 60)
          e.g. write 2 9 C4:0:1:100,E4:1:1,G4:2:2 Inst 2
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
        say("Recording \(request.notes.count) note(s) on track \(request.track) from bar \(request.startBar) in real time. Press Stop in Logic to abort.")
        let result = await writer.write(request, replaceConfirmed: replaceConfirmed)
        await logged.finish()
        say(Self.encodeJSON(result))
    }

    static func parseWrite(_ arguments: [String]) -> NoteWriteRequest? {
        guard arguments.count >= 3, let track = Int(arguments[0]), let bar = Int(arguments[1]) else { return nil }
        var notes: [NoteSpec] = []
        for item in arguments[2].split(separator: ",") {
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
        var nameWords: [String] = []
        for word in arguments.dropFirst(3) {
            if word.lowercased().hasPrefix("offset=") {
                guard let value = Double(word.dropFirst("offset=".count)) else { return nil }
                offset = value
            } else {
                nameWords.append(word)
            }
        }
        let name = nameWords.joined(separator: " ")
        return NoteWriteRequest(track: track, expectedName: name.isEmpty ? nil : name, startBar: bar,
                                notes: notes, timingOffsetMs: offset)
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
