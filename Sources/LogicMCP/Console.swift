import Foundation
import LogicBridge
import MackieControl
import MIDICore
import Synchronization

/// Appends the Mackie Control traffic to `var/logs/console-<time>.log` and, filtered, to stderr.
final class TrafficLog: Sendable {
    private let handle: Mutex<FileHandle?>
    let path: String
    private let start = ContinuousClock.now
    private let verbose: Bool

    init(directory: URL, verbose: Bool) throws {
        let logs = directory.appendingPathComponent("logs")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let url = logs.appendingPathComponent("console-\(formatter.string(from: Date())).log")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        path = url.path
        handle = Mutex(try FileHandle(forWritingTo: url))
        self.verbose = verbose
    }

    /// Sync-port traffic. Clock ticks (24 per quarter note) are only written to the file.
    func recordSync(_ message: MIDIMessage) {
        let elapsed = String(format: "%9.3f", start.duration(to: .now).seconds)
        let line = "\(elapsed) SYNC \(message.bytes.hexString)"
        write(line)
        if message != .timingClock || verbose { logError(line) }
    }

    func record(_ event: TrafficEvent) {
        let elapsed = String(format: "%9.3f", start.duration(to: .now).seconds)
        let detail = event.decoded.map { " \(Self.describe($0))" } ?? ""
        let line = "\(elapsed) \(event.direction.rawValue) \(event.message.bytes.hexString)\(detail)"
        write(line)
        if verbose || !Self.isNoisy(event) { logError(line) }
    }

    func write(_ line: String) {
        handle.withLock { $0?.write(Data((line + "\n").utf8)) }
    }

    /// Meters and time-code digits stream continuously during playback.
    private static func isNoisy(_ event: TrafficEvent) -> Bool {
        switch event.decoded {
        case .meter?, .timecodeDigit?: return true
        default: return false
        }
    }

    private static func describe(_ message: MCUHostMessage) -> String {
        switch message {
        case let .led(note, state): return "led \(mcuNoteName(note))=\(state)"
        case let .lcd(offset, text): return "lcd @\(offset) \"\(String(decoding: text, as: UTF8.self))\""
        case let .timecodeDigit(position, code):
            let (character, dot) = SurfaceState.sevenSegment(code)
            return "time digit[\(position)]='\(character)'\(dot ? "." : "")"
        case let .otherModel(model, payload): return "probe for model \([model].hexString): \(payload.hexString)"
        default: return "\(message)"
        }
    }
}

private let consoleHelp = """
    Commands (separate several with ';'):
      status                     what Logic currently shows on the emulated surface
      press <button>...          press and release buttons, e.g. "press play", "press f1 enter", "press 0x5E"
      play | stop | record       verified transport, same as the MCP tool ("record!" skips the Replace check)
      locate <bar>               verified locate with the jog wheel, same as the MCP tool
      tracks [cached]            scan all tracks (names, volume, pan, mute, solo, rec), like get_session_state
      mixer <track> <volume|pan|mute|solo> <value> [expected name]
                                 verified mixer change, same as mixer_set, e.g. "mixer 3 volume -6.5",
                                 "mixer 3 volume -inf", "mixer 2 pan -20", "mixer 1 mute on"
      write <track> <start_bar> <pitch:start:dur[:vel],...> [offset=<ms>] [expected name]
                                 record notes in real time, same as write_midi ("write!" confirms Replace)
    \(Console.commandHelp)
      jog <ticks>                turn the jog wheel, negative = backwards
      chord <mod>... <button>    hold modifiers while pressing a button, e.g. "chord option bankLeft"
      fader <1-8|master> <value> [notouch]   move a fader (with touch unless notouch)
      vpot <1-8> <delta>         turn a V-Pot one tick at a time
      send <hex>                 send raw bytes on LogicMCP MCU
      lcd                        print the LCD and displays
      dialog <bar>               test locate method A: Go to Position dialog + F-key digits + Enter
      step <bar>                 test locate method B: Go to Beginning + Forward (one bar) repeatedly
      wait <seconds>
      help | quit
    Key commands: \(Console.commandIDs)
    """

struct Console {
    let runtime: LogicRuntime
    let log: TrafficLog
    let mixer: MixerController
    let commandSlot = ConsoleCommandSlot()

    func say(_ text: String) {
        print(text)
        log.write("# " + text.replacingOccurrences(of: "\n", with: "\n# "))
    }

    /// Returns false when the console should exit.
    func execute(_ line: String) async -> Bool {
        let words = line.split(separator: " ").map(String.init)
        guard let command = words.first?.lowercased() else { return true }
        let arguments = Array(words.dropFirst())
        log.write("> \(line)")
        switch command {
        case "quit", "exit": return false
        case "help", "?": say(consoleHelp)
        case "status": await status()
        case "press":
            for name in arguments {
                guard let note = Self.buttonNote(name) else { say("Unknown button \(name)"); continue }
                await runtime.mcu.press(note)
                say("pressed \(mcuNoteName(note))")
            }
        case "play": say(json(await runtime.transport.play()))
        case "locate":
            guard let bar = arguments.first.flatMap(Int.init) else { say("Usage: locate <bar>"); return true }
            say(json(await runtime.transport.locate(bar: bar, beat: 1)))
        case "stop": say(json(await runtime.transport.stop()))
        case "tracks": say(json(await mixer.tracks(refresh: arguments.first != "cached")))
        case "mixer":
            guard arguments.count >= 3, let track = Int(arguments[0]) else {
                say("Usage: mixer <track> <volume|pan|mute|solo> <value> [expected name]")
                return true
            }
            var change = MixerChange(track: track)
            let value = arguments[2].lowercased()
            switch arguments[1].lowercased() {
            case "volume", "vol":
                guard let level = VolumeLevel.parse(value) else { say("Volume must be dB or -inf"); return true }
                change.volume = level
            case "pan":
                guard let pan = Int(value) else { say("Pan must be -64...63"); return true }
                change.pan = pan
            case "mute", "solo":
                guard let on = ["on": true, "true": true, "1": true, "off": false, "false": false, "0": false][value] else {
                    say("Use on or off"); return true
                }
                if arguments[1].lowercased() == "mute" { change.mute = on } else { change.solo = on }
            default:
                say("Field must be volume, pan, mute or solo"); return true
            }
            if arguments.count > 3 { change.expectedName = arguments[3...].joined(separator: " ") }
            say(json(await mixer.set([change])))
        case "record": say(json(await runtime.transport.record(confirmed: false)))
        case "record!": say(json(await runtime.transport.record(confirmed: true)))
        case "write", "write!": await writeNotes(arguments, replaceConfirmed: command == "write!")
        case "commands", "run", "run!", "key", "key!", "learn", "learn!":
            await commandConsole(command, arguments)
        case "chord":
            // Hold every button but the last, press the last, release in reverse: "chord option bankLeft".
            let notes = arguments.compactMap(Self.buttonNote)
            guard notes.count >= 2, notes.count == arguments.count else { say("Usage: chord <modifier>... <button>"); return true }
            for note in notes.dropLast() { await runtime.mcu.send([.button(note: note, pressed: true)]) }
            await runtime.mcu.press(notes.last!)
            for note in notes.dropLast().reversed() { await runtime.mcu.send([.button(note: note, pressed: false)]) }
            say("chord \(notes.map(mcuNoteName).joined(separator: "+"))")
        case "fader":
            // fader <strip 1-8|master> <0-16383> [notouch]
            guard arguments.count >= 2, let value = UInt16(arguments[1]), value <= 16383 else { say("Usage: fader <1-8|master> <0-16383> [notouch]"); return true }
            let fader = arguments[0].lowercased() == "master" ? 8 : (Int(arguments[0]) ?? 0) - 1
            guard (0...8).contains(fader) else { say("Bad fader"); return true }
            let touch = !arguments.contains("notouch")
            if touch { await runtime.mcu.send([.faderTouch(fader: fader, touched: true)]) }
            await runtime.mcu.send([.fader(fader: fader, value: value)])
            try? await Task.sleep(for: .milliseconds(300))
            if touch { await runtime.mcu.send([.faderTouch(fader: fader, touched: false)]) }
            try? await Task.sleep(for: .milliseconds(500))
            let s = await runtime.mcu.surface
            say("fader \(fader + 1) -> \(value)\(touch ? "" : " (no touch)"): reported=\(s.faders[fader].map(String.init) ?? "nil")\n  lcd1=\"\(s.lcdUpperLine)\"\n  lcd2=\"\(s.lcdLowerLine)\"")
        case "vpot":
            guard arguments.count == 2, let strip = Int(arguments[0]), (1...8).contains(strip), let delta = Int(arguments[1]), delta != 0 else { say("Usage: vpot <1-8> <delta>"); return true }
            for _ in 0..<abs(delta) {
                await runtime.mcu.send([.vPot(strip: strip - 1, delta: delta > 0 ? 1 : -1)])
                try? await Task.sleep(for: .milliseconds(40))
            }
            try? await Task.sleep(for: .milliseconds(400))
            let s = await runtime.mcu.surface
            say("vpot \(strip) \(delta): ring=\(s.vPotRings[strip - 1].map { [$0].hexString } ?? "nil")\n  lcd1=\"\(s.lcdUpperLine)\"\n  lcd2=\"\(s.lcdLowerLine)\"")
        case "send":
            guard let bytes = parseHexBytes(arguments.joined(separator: " ")), !bytes.isEmpty else { say("Usage: send <hex bytes>"); return true }
            var parser = MIDIByteParser()
            let messages = parser.feed(bytes)
            for message in messages { try? runtime.ports?.mcuOut.send([message]) }
            say("sent \(messages.count) message(s) on LogicMCP MCU")
        case "notes":
            // notes <pitch,pitch,...> <ms per note> [velocity]: plays the pitches one after another
            // on LogicMCP Notes (note on, then note off after 90% of the step).
            guard arguments.count >= 2, let step = Int(arguments[1]), step > 0 else { say("Usage: notes <p1,p2,...> <ms> [velocity]"); return true }
            let pitches = arguments[0].split(separator: ",").compactMap { UInt8($0) }.filter { $0 < 128 }
            let velocity = arguments.count > 2 ? UInt8(arguments[2]) ?? 100 : 100
            guard let notes = runtime.ports?.notesOut else { say("No Notes port in fake mode"); return true }
            let start = ContinuousClock.now
            for (index, pitch) in pitches.enumerated() {
                let due = start.advanced(by: .milliseconds(step * index))
                try? await ContinuousClock().sleep(until: due)
                try? notes.send([.noteOn(channel: 0, note: pitch, velocity: velocity)])
                log.write("\(String(format: "%9.3f", start.duration(to: .now).seconds)) NOTE on \(pitch)")
                try? await Task.sleep(for: .milliseconds(step * 9 / 10))
                try? notes.send([.noteOff(channel: 0, note: pitch, velocity: 0)])
            }
            say("played \(pitches.count) note(s) on LogicMCP Notes, \(step) ms apart")
        case "lcd":
            let s = await runtime.mcu.surface
            say("lcd1=\"\(s.lcdUpperLine)\"\nlcd2=\"\(s.lcdLowerLine)\"\nassign=\(s.assignmentText) time=\(s.timecodeText ?? "")")
        case "jog":
            guard let ticks = arguments.first.flatMap(Int.init), ticks != 0 else { say("Usage: jog <ticks>"); return true }
            for _ in 0..<abs(ticks) {
                await runtime.mcu.send([.jog(delta: ticks > 0 ? 1 : -1)])
                try? await Task.sleep(for: .milliseconds(20))
            }
            try? await Task.sleep(for: .milliseconds(300))
            say("jogged \(ticks); time display: \(await runtime.mcu.surface.timecodeText ?? "(none)")")
        case "dialog":
            guard let bar = arguments.first.flatMap(Int.init), bar >= 1 else { say("Usage: dialog <bar>"); return true }
            await probeDialog(bar: bar)
        case "step":
            guard let bar = arguments.first.flatMap(Int.init), bar >= 1 else { say("Usage: step <bar>"); return true }
            await probeStep(bar: bar)
        case "wait":
            let seconds = arguments.first.flatMap(Double.init) ?? 1
            try? await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
        default:
            say("Unknown command \(command). Type help.")
        }
        return true
    }

    private func status() async {
        let report = await StatusReport.make(runtime: runtime, client: nil, elicitation: false)
        say(json(report))
    }

    /// Locate method A, as a logged experiment. Digits are only sent after the LCD changed,
    /// because outside a dialog the F keys recall screensets (research §2.5).
    private func probeDialog(bar: Int) async {
        let before = await runtime.mcu.surface
        // While playing, the LCD changes constantly, which would look like the dialog opening.
        guard before.led(.play) == .off, before.led(.record) != .on else {
            say("Refusing: stop Logic first (the Play LED must be reported off).")
            return
        }
        say("before: time=\(before.timecodeText ?? "(none)")\n  lcd1=\"\(before.lcdUpperLine)\"\n  lcd2=\"\(before.lcdLowerLine)\"")
        await runtime.send(.goToPosition)
        let changed = await runtime.mcu.waitUntil(timeout: .milliseconds(1500)) { $0.lcd != before.lcd }
        let opened = await runtime.mcu.surface
        say("after Go to Position (LCD \(changed == nil ? "unchanged" : "changed after \(changed!.milliseconds) ms")):\n  lcd1=\"\(opened.lcdUpperLine)\"\n  lcd2=\"\(opened.lcdLowerLine)\"")
        guard changed != nil else {
            say("No dialog text appeared on the LCD, so no digits were sent. If a dialog is open in Logic, close it (or run: press cancel).")
            return
        }
        for digit in String(bar).compactMap({ $0.wholeNumberValue }) {
            guard let button = MCUButton.dialogDigit(digit) else { continue }
            await runtime.mcu.press(button)
            try? await Task.sleep(for: .milliseconds(150))
            say("digit \(digit) via \(button): lcd1=\"\(await runtime.mcu.surface.lcdUpperLine)\"")
        }
        let timeBefore = await runtime.mcu.surface.timecode
        await runtime.mcu.press(.enter)
        let moved = await runtime.mcu.waitUntil(timeout: .milliseconds(1500)) { $0.timecode != timeBefore }
        let after = await runtime.mcu.surface
        say("after Enter (time display \(moved == nil ? "unchanged" : "changed")): time=\(after.timecodeText ?? "(none)") position=\(after.beatsPosition?.description ?? "unreadable")\n  lcd1=\"\(after.lcdUpperLine)\"")
        if after.lcd == opened.lcd {
            say("The LCD still shows the dialog text. If the dialog is still open in Logic, run: press cancel")
        }
    }

    /// Locate method B, as a logged experiment.
    private func probeStep(bar: Int) async {
        await runtime.send(.goToBeginning)
        try? await Task.sleep(for: .milliseconds(400))
        var current = await runtime.mcu.surface
        say("after Go to Beginning: time=\(current.timecodeText ?? "(none)") position=\(current.beatsPosition?.description ?? "unreadable")")
        guard bar > 1 else { return }
        for step in 1..<bar {
            let timeBefore = current.timecode
            await runtime.send(.forwardOneBar)
            let moved = await runtime.mcu.waitUntil(timeout: .seconds(1)) { $0.timecode != timeBefore }
            current = await runtime.mcu.surface
            say("forward #\(step): time=\(current.timecodeText ?? "(none)") position=\(current.beatsPosition?.description ?? "unreadable")\(moved == nil ? " (no change within 1 s)" : "")")
            if moved == nil { say("Stopped: Logic did not move."); return }
        }
    }

    static func buttonNote(_ name: String) -> UInt8? {
        let lower = name.lowercased()
        if lower.hasPrefix("0x"), let value = UInt8(lower.dropFirst(2), radix: 16) { return value }
        return MCUButton.allCases.first { String(describing: $0).lowercased() == lower }?.rawValue
    }

    private func json<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "(encoding failed)"
    }
}

func runConsole(_ options: Options) async throws {
    // Fake mode creates no ports, so it needs no lock and can run next to a real server.
    let lock = options.fake ? nil : try InstanceLock(directory: options.varDirectory)
    let log = try TrafficLog(directory: options.varDirectory, verbose: options.verbose)
    let runtime = try await LogicRuntime(options: options)
    await runtime.mcu.addObserver { log.record($0) }
    await runtime.sync.setObserver { log.recordSync($0) }
    let console = Console(runtime: runtime, log: log, mixer: makeMixerController(runtime: runtime))
    console.say("""
        logic-mcp console \(serverVersion) — ports are open:
          \(runtime.fakeHost != nil ? "(fake mode: in-memory FakeLogic, no real ports)" : runtime.endpoints.map { "\($0.kind.rawValue) \"\($0.name)\" id=\($0.uniqueID)\($0.uniqueIDApplied ? "" : " (ID REFUSED)")" }.joined(separator: "\n  "))
        Traffic log: \(log.path)
        Type help for commands; quit (or Ctrl-D) closes the ports.
        """)
    if options.fifo {
        let path = options.varDirectory.appendingPathComponent("console.fifo").path
        unlink(path)
        guard mkfifo(path, 0o600) == 0 else { throw RuntimeError("mkfifo \(path) failed: errno \(errno)") }
        defer { unlink(path) }
        // O_RDWR keeps a writer open ourselves, so the pipe never reports end-of-file between
        // commands and opening it does not block.
        let fd = open(path, O_RDWR)
        guard fd >= 0 else { throw RuntimeError("open \(path) failed: errno \(errno)") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        console.say("Reading commands from \(path)")
        for try await line in handle.bytes.lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            console.say("> \(trimmed)")
            guard await console.execute(trimmed) else { break }
        }
    } else if let script = options.script {
        for line in script.split(separator: ";") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            console.say("> \(trimmed)")
            guard await console.execute(trimmed) else { break }
        }
    } else {
        for try await line in FileHandle.standardInput.bytes.lines {
            guard await console.execute(line.trimmingCharacters(in: .whitespaces)) else { break }
        }
    }
    runtime.shutdown()
    withExtendedLifetime(lock) {}
}
