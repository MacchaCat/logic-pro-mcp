import CommandMap
import Foundation
import LogicBridge
import MCP
import MIDICore
import Testing
@testable import LogicMCP

@Suite("Command tool arguments")
struct CommandArgumentsTests {
    func problem(_ arguments: [String: Value]) -> String? {
        if case .failure(let problem) = CommandArguments.request(arguments) { return problem.message }
        return nil
    }

    @Test func validRequest() throws {
        let request = try CommandArguments.request(["command": "delete-track", "confirmation_token": "abc"]).get()
        #expect(request.command == .deleteTrack)
        #expect(request.token == "abc")
        #expect(try CommandArguments.request(["command": "undo"]).get().token == nil)
    }

    @Test func rejectedRequests() {
        #expect(problem([:])?.contains("\"command\"") == true)
        #expect(problem(["command": 3])?.contains("must be a string") == true)
        #expect(problem(["command": "make-coffee"])?.contains("Unknown command") == true)
        #expect(problem(["command": "undo", "track": 1])?.contains("Unknown field \"track\"") == true)
        #expect(problem(["command": "undo", "confirmation_token": 5])?.contains("confirmation_token") == true)
    }

    @Test func listFilter() throws {
        #expect(try CommandArguments.listFilter([:]).get() == nil)
        #expect(try CommandArguments.listFilter(["command": "save"]).get() == .save)
        if case .success = CommandArguments.listFilter(["command": "nope"]) { Issue.record("accepted an unknown id") }
        if case .success = CommandArguments.listFilter(["include": "x"]) { Issue.record("accepted an unknown field") }
    }

    @Test func schemasListEveryCommand() {
        #expect(CommandToolSchemas.all.map(\.name) == ["list_commands", "run_command", "learn_command"])
        #expect(CommandToolSchemas.commandIDs == .array(CommandCatalog.all.map { .string($0.id) }))
    }
}

@Suite("list_commands payload")
struct CommandListTests {
    func controller() -> CommandController {
        CommandController(mcu: MCUSession(output: MIDIPipe()), sync: SyncMonitor(), mixer: nil,
                          keys: OutputScheduler(output: MIDIPipe()), limits: .none)
    }

    @Test func listsTheWholeCatalog() async throws {
        let list = await CommandList.make(filter: nil, controller: controller())
        #expect(list.commands.map(\.id) == CommandCatalog.all.map(\.id))
        #expect(list.commands.allSatisfy { $0.learnSteps == nil })
        let beginning = try #require(list.commands.first { $0.id == "go-to-beginning" })
        #expect(beginning.japaneseName == "先頭に移動")
        #expect(beginning.cc == 21)
        #expect(beginning.message == "BF 15 7F")
        #expect(beginning.verification == "time_display")
        #expect(beginning.canVerify)
        let delete = try #require(list.commands.first { $0.id == "delete-track" })
        #expect(delete.japaneseName == "トラックを削除")
        #expect(delete.japaneseSearchKeywordsUnverified.isEmpty)
        #expect(delete.destructive)
        #expect(delete.confirmationReason != nil)
        let position = try #require(list.commands.first { $0.id == "go-to-position" })
        #expect(!position.runnable)
        #expect(list.howToLearn.joined().contains("Learn New Assignment"))
        // last_run counts only runs that sent the trigger; "failed" is no licence to retry.
        #expect(list.learned.contains("sent the command's trigger"))
        #expect(list.learned.contains("\"already at 1 1 1 1\""))
        #expect(list.learned.contains("check Logic before running a toggle or a new-track command again"))
        #expect(list.commands.allSatisfy { $0.lastRun == nil })
    }

    @Test func toolDescriptionsWarnAboutRetriesAndCost() {
        let run = CommandToolSchemas.run.description ?? ""
        #expect(run.contains("never re-run it after \"failed\" or \"unverified\""))
        #expect(run.contains("0.6 s per track"))
        #expect(run.contains("\"Nothing was sent\" is a refusal"))
        let learn = CommandToolSchemas.learn.description ?? ""
        #expect(learn.contains("Go to Position dialog"))
        #expect(learn.contains("still sent, with a warning"))
    }

    @Test func oneCommandComesWithLearningSteps() async throws {
        let list = await CommandList.make(filter: .toggleCycle, controller: controller())
        #expect(list.commands.count == 1)
        let steps = try #require(list.commands.first?.learnSteps)
        #expect(steps.joined().contains("learn_command"))
        #expect(steps.joined().contains("CC 31 (127)"))
    }

    @Test func encodesSnakeCaseKeys() async throws {
        let list = await CommandList.make(filter: .undo, controller: controller())
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let text = String(decoding: try encoder.encode(list), as: UTF8.self)
        for key in ["english_name", "japanese_search_keywords_unverified", "can_verify", "while_playing", "learn_steps", "how_to_learn"] {
            #expect(text.contains("\"\(key)\""), "\(key)")
        }
    }
}
