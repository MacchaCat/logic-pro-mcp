import CommandMap
import FakeLogic
import Foundation
import LogicBridge
import MCP

/// Phase 3 tools: the key-command catalog, running commands, and teaching them to Logic.
struct CommandTools: ToolModule {
    let commands: CommandController

    /// Uses the mixer controller of `MixerTools` when it is registered, so both modules share one
    /// track-list cache (a command that adds or removes tracks drops it for both).
    static func make(runtime: LogicRuntime, sharing modules: [any ToolModule]) async -> CommandTools {
        let mixer = modules.lazy.compactMap { ($0 as? MixerTools)?.mixer }.first ?? makeMixerController(runtime: runtime)
        return CommandTools(commands: makeCommandController(runtime: runtime, mixer: mixer))
    }

    var tools: [Tool] { CommandToolSchemas.all }

    func call(_ name: String, _ arguments: [String: Value], context: ToolContext) async -> CallTool.Result? {
        switch name {
        case "list_commands":
            switch CommandArguments.listFilter(arguments) {
            case .failure(let problem):
                return context.encode(OperationResult<CommandList>(status: .failed, summary: problem.message))
            case .success(let filter):
                return context.encode(await CommandList.make(filter: filter, controller: commands), isError: false)
            }
        case "run_command":
            return context.encode(await run(arguments, context))
        case "learn_command":
            return context.encode(await learn(arguments, context))
        default:
            return nil
        }
    }

    /// run_command. A token is redeemed (and used up) before anything else, and only for the
    /// action "run_command:<id>", so a token from learn_command or for another command never
    /// runs this one.
    func run(_ arguments: [String: Value], _ context: ToolContext) async -> CommandController.RunResult {
        let request: CommandArguments.Request
        switch CommandArguments.request(arguments) {
        case .failure(let problem): return .init(status: .failed, summary: problem.message + " Nothing was sent.")
        case .success(let parsed): request = parsed
        }
        let command = request.command
        let action = "run_command:\(command.id)"
        if let token = request.token {
            guard await context.consumeToken(token, for: action) else {
                return .init(status: .failed, summary: CommandArguments.badToken)
            }
            return await commands.run(command, confirmed: true)
        }
        let result = await commands.run(command, confirmed: false)
        guard result.status == .needsConfirmation else { return result }
        let commands = self.commands
        return await context.confirm(result.summary, action: action, pending: result) {
            await commands.run(command, confirmed: true)
        }
    }

    /// learn_command; tokens are bound to "learn_command:<id>".
    func learn(_ arguments: [String: Value], _ context: ToolContext) async -> CommandController.LearnResult {
        let request: CommandArguments.Request
        switch CommandArguments.request(arguments) {
        case .failure(let problem): return .init(status: .failed, summary: problem.message + " Nothing was sent.")
        case .success(let parsed): request = parsed
        }
        let command = request.command
        let action = "learn_command:\(command.id)"
        if let token = request.token {
            guard await context.consumeToken(token, for: action) else {
                return .init(status: .failed, summary: CommandArguments.badToken)
            }
            return await commands.learn(command, confirmed: true)
        }
        let result = await commands.learn(command, confirmed: false)
        guard result.status == .needsConfirmation else { return result }
        let commands = self.commands
        return await context.confirm(result.summary, action: action, pending: result) {
            await commands.learn(command, confirmed: true)
        }
    }
}

/// The command controller for the server and the console.
func makeCommandController(runtime: LogicRuntime, mixer: MixerController?) -> CommandController {
    CommandController(mcu: runtime.mcu, sync: runtime.sync, mixer: mixer, keys: runtime.keys, limits: runtime.limits)
}

/// `--fake` only: which catalog commands the fake Logic has learned. All of them, except the ids
/// listed (comma-separated) in `LOGIC_MCP_FAKE_UNLEARNED`, for end-to-end tests of the failure paths.
func fakeKeyCommandBehavior() -> FakeKeyCommandHost.Behavior {
    var behavior = FakeKeyCommandHost.Behavior()
    if let list = ProcessInfo.processInfo.environment["LOGIC_MCP_FAKE_UNLEARNED"] {
        behavior.unlearn(list.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
    }
    return behavior
}

/// Argument parsing of the command tools (also used by tests).
enum CommandArguments {
    struct Problem: Error { let message: String }

    struct Request {
        var command: LogicCommand
        var token: String?
    }

    static let badToken = "The confirmation token is invalid, already used, for a different command, or expired (5 min). Call again without a token to get a new one. Nothing was sent."

    static func request(_ arguments: [String: Value]) -> Result<Request, Problem> {
        if let unknown = arguments.keys.sorted().first(where: { !["command", "confirmation_token"].contains($0) }) {
            return .failure(Problem(message: "Unknown field \"\(unknown)\"."))
        }
        guard let value = arguments["command"] else {
            return .failure(Problem(message: "\"command\" (a command id from list_commands) is required."))
        }
        guard let id = value.stringValue else {
            return .failure(Problem(message: "\"command\" must be a string."))
        }
        guard let command = CommandCatalog.command(id: id) else {
            return .failure(Problem(message: "Unknown command \"\(id)\". Call list_commands for the ids."))
        }
        var request = Request(command: command)
        if let token = arguments["confirmation_token"] {
            guard let text = token.stringValue else {
                return .failure(Problem(message: "\"confirmation_token\" must be a string."))
            }
            request.token = text
        }
        return .success(request)
    }

    /// nil = every command.
    static func listFilter(_ arguments: [String: Value]) -> Result<LogicCommand?, Problem> {
        if let unknown = arguments.keys.sorted().first(where: { $0 != "command" }) {
            return .failure(Problem(message: "Unknown field \"\(unknown)\"."))
        }
        guard let value = arguments["command"] else { return .success(nil) }
        guard let id = value.stringValue else { return .failure(Problem(message: "\"command\" must be a string.")) }
        guard let command = CommandCatalog.command(id: id) else {
            return .failure(Problem(message: "Unknown command \"\(id)\". Call list_commands without arguments for the ids."))
        }
        return .success(command)
    }
}

/// Payload of `list_commands`.
struct CommandList: Codable, Sendable {
    struct Entry: Codable, Sendable {
        var id: String
        var englishName: String
        /// nil until the Japanese name has been seen on Logic 13.
        var japaneseName: String?
        var japaneseSearchKeywordsUnverified: [String]
        var cc: Int
        var message: String
        var destructive: Bool
        var confirmationReason: String?
        var runnable: Bool
        var verification: String
        var canVerify: Bool
        var verificationNote: String
        var whilePlaying: String
        var description: String
        var notes: [String]
        /// Result of the last run_command in this server session that sent the trigger.
        var lastRun: CommandRunRecord?
        /// Only when one command was asked for: what the user does in Logic.
        var learnSteps: [String]?
    }

    var commands: [Entry]
    var learned: String
    var howToLearn: [String]
    var port: String

    static func make(filter: LogicCommand?, controller: CommandController) async -> CommandList {
        let runs = await controller.lastRuns
        let selected = filter.map { [$0] } ?? CommandCatalog.all
        let entries = selected.map { command in
            Entry(
                id: command.id, englishName: command.englishName, japaneseName: command.verifiedJapaneseName,
                japaneseSearchKeywordsUnverified: command.japaneseKeywords, cc: Int(command.controller),
                message: command.message.bytes.hexString, destructive: command.destructive,
                confirmationReason: command.confirmationReason, runnable: command.runnable,
                verification: command.verification.kind, canVerify: command.verification.canVerify,
                verificationNote: verificationNote(command), whilePlaying: command.whilePlaying.rawValue,
                description: command.summary, notes: command.notes, lastRun: runs[command.id],
                learnSteps: filter == nil ? nil : LearnGuide.steps(command, sendStep: "Tell Claude the button is armed; Claude calls learn_command (command: \(command.id)), which sends CC \(command.controller) once."))
        }
        return CommandList(
            commands: entries,
            learned: CommandList.learnedNote,
            howToLearn: [
                "In Logic, open \(LearnGuide.keyCommandsMenu) and find the command's row with the search field at the top right (english_name; with Logic's Japanese UI, japanese_name, or search with japanese_search_keywords_unverified and check the row's english_name).",
                "Click the row to select it, then click \(LearnGuide.learnButton) under “Control Surface” on the right (it looks the same armed and unarmed).",
                "Call learn_command only after the button is armed; call no other Logic tool in between.",
                "After sending, the row's “Control Surface” column should show CC <cc> (127). Full steps: list_commands with command, or docs/setup/03-phase3-commands.md.",
            ],
            port: "LogicMCP Keys, MIDI channel 16, value 127")
    }

    static let learnedNote = """
        Logic does not report which commands it has learned. last_run is the last run_command in \
        this session that sent the command's trigger; runs that sent nothing (refused while \
        recording, needs_confirmation, "already at 1 1 1 1", not runnable) are not recorded. \
        A "verified" last_run shows the command is learned. "failed" means the expected change \
        did not appear: often the command is not learned yet, but check Logic before running a \
        toggle or a new-track command again. "unverified" says nothing about learning.
        """

    static func verificationNote(_ command: LogicCommand) -> String {
        switch command.verification {
        case .trackCount(let change):
            return "Verified when a full track scan before and after shows the count \(change > 0 ? "rising" : "falling") by \(abs(change)). Each scan pages the control surface through all tracks (about 0.3 s per track), so a run takes about 0.6 s per track (e.g. 7 s for 11 tracks, 1 min for 100)."
        case .surfaceLED(let led):
            return "Verified when the \(led.rawValue.capitalized) LED of the Mackie Control surface changes. Logic 13 reports this LED at connect; that it follows the key command is not yet confirmed on real Logic, so an unchanged LED gives \"unverified\" until the LED has followed a run in this session (then \"failed\")."
        case .playhead:
            return "Verified on the time display (Beats mode) while Logic is stopped; unverified while playing."
        case .none:
            return "Logic gives no feedback for this command: always unverified."
        case .notRunnable(let reason):
            return "run_command refuses it: \(reason) It can still be learned."
        }
    }
}

enum CommandToolSchemas {
    static let commandIDs: Value = .array(CommandCatalog.all.map { .string($0.id) })

    static let list = Tool(
        name: "list_commands",
        title: "List Logic key commands",
        description: """
            Lists the Logic key commands the server can run (run_command) or help the user teach \
            Logic (learn_command): id, Logic's English name and (when confirmed) Japanese name, the \
            CC that triggers it, whether it is destructive (needs the user's confirmation), how its \
            effect is verified (track_count, cycle_led, click_led, time_display, or none = always \
            "unverified"), and last_run: the last run in this session that sent its trigger. \
            Logic does not report which commands it has learned; a "verified" last_run proves \
            one. With "command", also returns the learning steps for the user (with Logic's \
            English menu names).
            """,
        inputSchema: .object([
            "type": "object",
            "properties": .object([
                "command": .object(["type": "string", "enum": commandIDs, "description": "Only this command, with learning steps."]),
            ]),
            "additionalProperties": false,
        ]),
        annotations: .init(title: "List Logic key commands", readOnlyHint: true, idempotentHint: true, openWorldHint: false)
    )

    static let run = Tool(
        name: "run_command",
        title: "Run a Logic key command",
        description: """
            Runs one key command from list_commands in Logic Pro by sending its controller-assignment \
            trigger on the LogicMCP Keys port. Logic never acknowledges key commands, so the result \
            is "verified" only when Logic's control surface shows the change: the track count for \
            new-audio-track, new-software-instrument-track, duplicate-track and delete-track (the \
            whole track list is scanned before and after: about 0.6 s per track in all, e.g. 7 s \
            for 11 tracks, a minute for 100), the Cycle or Click LED for toggle-cycle and \
            toggle-metronome, or the time display while stopped for go-to-beginning, \
            forward-one-bar and rewind-one-bar. All other commands return "unverified": tell the \
            user to check in Logic. "failed" with "Nothing was sent" is a refusal (recording, \
            unreadable track list), not a learning problem. Any other "failed" means the expected \
            change did not appear: often the command has not been learned yet (learn_command), \
            but a toggle or new-track command may still have run (e.g. a track created inside a \
            collapsed folder): never re-run it after "failed" or "unverified"; ask the user to \
            check Logic (or read the LEDs with logic_status) first. Key commands act on the Logic \
            window with key focus (e.g. select-all, quantize-selection). Refused while Logic is \
            recording or its record state is unknown. Destructive commands \
            (delete-track, save, quantize-selection) return "needs_confirmation" with a \
            confirmation_token: ask the user in chat and repeat the call with that token only after \
            they explicitly agree (tokens expire after 5 minutes). go-to-position cannot be run \
            (it opens a dialog); use transport locate instead.
            """,
        inputSchema: .object([
            "type": "object",
            "properties": .object([
                "command": .object(["type": "string", "enum": commandIDs, "description": "Command id from list_commands."]),
                "confirmation_token": .object(["type": "string", "description": "Token from a previous needs_confirmation result for the same command, after the user agreed in chat."]),
            ]),
            "required": .array(["command"]),
            "additionalProperties": false,
        ]),
        annotations: .init(title: "Run a Logic key command", readOnlyHint: false, destructiveHint: true, idempotentHint: false, openWorldHint: false)
    )

    static let learn = Tool(
        name: "learn_command",
        title: "Teach Logic a key command",
        description: """
            Helps the user teach Logic one command from list_commands: sends the command's trigger \
            (its CC, value 127, MIDI channel 16 on LogicMCP Keys) once, for Logic's Key Commands \
            window to capture while its "Learn New Assignment" button is armed. \
            Before calling, give the user the steps (list_commands with this command returns them): \
            open Logic Pro > Key Commands > Edit Assignments…, select the command's row, then click \
            Learn New Assignment; wait until they say it is armed. Do not call any other \
            Logic tool in between (in learn mode Logic captures control-surface traffic: a Bank Left was learned as Note 46). Logic \
            gives no feedback for learning, so the result is always "unverified" and lists what \
            the user should check. If the command is already learned and learn mode is not armed, \
            Logic runs it, so destructive commands need confirmation as in run_command; for \
            go-to-position Logic then opens its Go to Position dialog, which the user must close \
            in Logic before any other Logic tool is used. Refused while Logic is recording; when \
            Logic has not reported its record state the trigger is still sent, with a warning.
            """,
        inputSchema: .object([
            "type": "object",
            "properties": .object([
                "command": .object(["type": "string", "enum": commandIDs, "description": "Command id from list_commands."]),
                "confirmation_token": .object(["type": "string", "description": "Token from a previous needs_confirmation result for the same command, after the user agreed in chat."]),
            ]),
            "required": .array(["command"]),
            "additionalProperties": false,
        ]),
        annotations: .init(title: "Teach Logic a key command", readOnlyHint: false, destructiveHint: true, idempotentHint: false, openWorldHint: false)
    )

    static let all = [list, run, learn]
}
