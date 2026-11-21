import CommandMap
import Foundation
import LogicBridge
import Synchronization

/// The console's command controller, made on first use and kept for the whole console session
/// (as in the server), so runs are serialised and what earlier runs showed about Logic (an LED
/// that follows key commands) holds for later ones.
final class ConsoleCommandSlot: Sendable {
    private let controller = Mutex<CommandController?>(nil)

    func get(orMake make: () -> CommandController) -> CommandController {
        controller.withLock { stored in
            if let stored { return stored }
            let made = make()
            stored = made
            return made
        }
    }
}

/// Console commands for the Phase 3 key-command catalog: list, run (verified, like run_command),
/// send a trigger, and learn with a countdown. Destructive commands need a trailing "!".
extension Console {
    static var commandIDs: String { CommandCatalog.all.map(\.id).joined(separator: ", ") }

    var commandController: CommandController {
        commandSlot.get { makeCommandController(runtime: runtime, mixer: mixer) }
    }

    static let commandHelp = """
          commands                   list the key-command catalog: id, CC, Logic names, how each is verified
          run <command>              run a catalog command and verify its effect, same as run_command
                                     (destructive ones need "run!", e.g. "run! delete-track")
          key <command>              send a command's trigger on LogicMCP Keys right away, unchecked; refused while
                                     recording ("key!" if destructive)
          learn <command>            print the learning steps, then send the trigger after a 5-second countdown
                                     (time to click Learn New Assignment in Logic; "learn!" if destructive)
        """

    func commandConsole(_ word: String, _ arguments: [String]) async {
        let confirmed = word.hasSuffix("!")
        let verb = confirmed ? String(word.dropLast()) : word
        if verb == "commands" {
            listCommands()
            return
        }
        guard let id = arguments.first, let command = CommandCatalog.command(id: id) else {
            say("Usage: \(word) <command>. Commands: \(Self.commandIDs)")
            return
        }
        if command.destructive, !confirmed {
            say("\(command.id) is destructive. \(command.confirmationReason ?? "") Type \"\(verb)! \(command.id)\" to go ahead.")
            return
        }
        let controller = commandController
        switch verb {
        case "run":
            say(Self.commandJSON(await controller.run(command, confirmed: confirmed)))
        case "key":
            // Same recording check as learn; also drops the mixer's cached track list.
            let result = await controller.trigger(command, confirmed: confirmed)
            if result.status == .unverified {
                say("sent \(command.id): \(command.message.bytes.hexString) on LogicMCP Keys")
            } else {
                say(result.summary)
            }
            for warning in result.warnings { say("  ! " + warning) }
        default:  // learn
            say("Learn \(command.englishName) (CC \(command.controller)):")
            for step in LearnGuide.beforeSending(command) { say("  - " + Self.plain(step)) }
            say("Sending in 5 s…")
            try? await Task.sleep(for: .seconds(5))
            let result = await controller.learn(command, confirmed: confirmed)
            say(result.summary)
            for warning in result.warnings { say("  ! " + warning) }
            for step in result.after?.check ?? [] { say("  - " + Self.plain(step)) }
        }
    }

    private func listCommands() {
        var lines = ["id                              CC  verified by     destructive  Logic name (English / Japanese)"]
        for command in CommandCatalog.all {
            let id = command.id.padding(toLength: 31, withPad: " ", startingAt: 0)
            let cc = String(command.controller).padding(toLength: 3, withPad: " ", startingAt: 0)
            let kind = command.verification.kind.padding(toLength: 15, withPad: " ", startingAt: 0)
            let destructive = (command.destructive ? "yes" : "").padding(toLength: 12, withPad: " ", startingAt: 0)
            let japanese = command.verifiedJapaneseName ?? "(Japanese name not confirmed)"
            lines.append("\(id) \(cc) \(kind) \(destructive) \(command.englishName) / \(japanese)")
        }
        lines.append("All triggers: CC <n> value 127 on MIDI channel 16, port LogicMCP Keys.")
        say(lines.joined(separator: "\n"))
    }

    /// Markdown emphasis is for chat; the terminal shows plain text.
    static func plain(_ text: String) -> String {
        text.replacingOccurrences(of: "**", with: "")
    }

    static func commandJSON<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "(encoding failed)"
    }
}
