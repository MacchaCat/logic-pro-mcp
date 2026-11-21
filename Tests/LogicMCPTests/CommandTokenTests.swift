import CommandMap
import Foundation
import LogicBridge
import MCP
import Testing
@testable import LogicMCP

/// The chat confirmation flow of run_command and learn_command through the real `ToolContext`
/// (chat mode, an MCP server that is never started) against the fake runtime: no ports.
@Suite("Command tools: confirmation tokens (fake runtime)")
struct CommandTokenTests {
    struct Fixture {
        let runtime: LogicRuntime
        let context: ToolContext
        let tools: CommandTools
        let directory: URL

        /// Triggers sent on LogicMCP Keys so far.
        var sent: Int { get async { await runtime.keys.sentCount } }

        func run(_ command: String, token: String? = nil) async -> CommandController.RunResult {
            await tools.run(Self.arguments(command, token), context)
        }

        func learn(_ command: String, token: String? = nil) async -> CommandController.LearnResult {
            await tools.learn(Self.arguments(command, token), context)
        }

        static func arguments(_ command: String, _ token: String?) -> [String: Value] {
            var arguments: [String: Value] = ["command": .string(command)]
            if let token { arguments["confirmation_token"] = .string(token) }
            return arguments
        }
    }

    func fixture() async throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("logic-mcp-token-test-\(UUID().uuidString)")
        let options = try Options.parse(["serve", "--fake", "--var-dir", directory.path])
        #expect(options.confirm == .chat)
        let runtime = try await LogicRuntime(options: options)
        _ = await runtime.mcu.waitUntil(timeout: .seconds(2)) { $0.led(.record) != nil && $0.led(.cycle) != nil }
        let context = ToolContext(runtime: runtime, server: Server(name: "logic-mcp-test", version: "0"), confirmMode: .chat)
        return Fixture(runtime: runtime, context: context, tools: await CommandTools.make(runtime: runtime, sharing: []),
                       directory: directory)
    }

    @Test func tokenIsIssuedRedeemedOnceAndBoundToTheCommand() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }

        let pending = await f.run("save")
        #expect(pending.status == .needsConfirmation)
        let token = try #require(pending.confirmationToken)
        #expect(pending.summary.contains("Ask the user in chat"))
        #expect(await f.sent == 0)

        // A token for save does not run another destructive command…
        let other = await f.run("quantize-selection", token: token)
        #expect(other.status == .failed)
        #expect(other.summary == CommandArguments.badToken)
        #expect(await f.sent == 0)
        // …and the failed attempt used it up.
        #expect(await f.run("save", token: token).status == .failed)
        #expect(await f.sent == 0)

        let fresh = try #require(await f.run("save").confirmationToken)
        let saved = await f.run("save", token: fresh)
        #expect(saved.status == .unverified, "\(saved.summary)")
        #expect(await f.sent == 1)
        // One use only.
        let again = await f.run("save", token: fresh)
        #expect(again.status == .failed)
        #expect(again.summary == CommandArguments.badToken)
        #expect(await f.sent == 1)
    }

    @Test func runAndLearnTokensAreNotInterchangeable() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }

        // learn_command:delete-track does not authorise run_command:delete-track…
        let learnPending = await f.learn("delete-track")
        #expect(learnPending.status == .needsConfirmation)
        let learnToken = try #require(learnPending.confirmationToken)
        let run = await f.run("delete-track", token: learnToken)
        #expect(run.status == .failed)
        #expect(run.summary == CommandArguments.badToken)
        // …nor the reverse.
        let runToken = try #require(await f.run("delete-track").confirmationToken)
        let learn = await f.learn("delete-track", token: runToken)
        #expect(learn.status == .failed)
        #expect(learn.summary == CommandArguments.badToken)
        #expect(await f.sent == 0)
        #expect(await f.runtime.fakeHost?.tracks.count == 11)

        // A learn token works for learning that command.
        let token = try #require(await f.learn("save").confirmationToken)
        let learned = await f.learn("save", token: token)
        #expect(learned.status == .unverified)
        #expect(await f.sent == 1)
    }

    @Test func tokenIsUsedUpWhenTheRunIsRefusedWhileRecording() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }

        let token = try #require(await f.run("save").confirmationToken)
        #expect(await f.runtime.transport.record(confirmed: false).status == .verified)
        let refused = await f.run("save", token: token)
        #expect(refused.status == .failed)
        #expect(refused.summary.contains("Logic is recording"))
        #expect(refused.summary.contains("Nothing was sent"))
        // While recording no token is issued at all.
        let whileRecording = await f.run("save")
        #expect(whileRecording.status == .failed)
        #expect(whileRecording.confirmationToken == nil)
        #expect(await f.runtime.transport.stop().status == .verified)
        // The token was spent on the refused run.
        let late = await f.run("save", token: token)
        #expect(late.status == .failed)
        #expect(late.summary == CommandArguments.badToken)
        #expect(await f.sent == 0)
        // Refusals are not recorded as runs.
        #expect(await f.tools.commands.lastRuns.isEmpty)
    }
}
