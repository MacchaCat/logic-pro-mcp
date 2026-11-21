import Foundation
import MackieControl
import Testing
@testable import LogicMCP

/// The console's catalog commands, in-process against the fake runtime (no ports are created).
@Suite("Console key commands (fake runtime)")
struct ConsoleCommandsTests {
    func console() async throws -> (Console, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("logic-mcp-console-test-\(UUID().uuidString)")
        let options = try Options.parse(["console", "--fake", "--var-dir", directory.path])
        let runtime = try await LogicRuntime(options: options)
        // The fake's connect-time output (transport and Cycle/Click LEDs) arrives asynchronously.
        _ = await runtime.mcu.waitUntil(timeout: .seconds(2)) { $0.led(.record) != nil && $0.led(.cycle) != nil }
        let log = try TrafficLog(directory: directory, verbose: false)
        let console = Console(runtime: runtime, log: log, mixer: makeMixerController(runtime: runtime))
        return (console, URL(fileURLWithPath: log.path))
    }

    func logText(_ url: URL) throws -> String {
        String(decoding: try Data(contentsOf: url), as: UTF8.self)
    }

    @Test func listRunAndKey() async throws {
        let (console, log) = try await console()
        defer { try? FileManager.default.removeItem(at: log.deletingLastPathComponent().deletingLastPathComponent()) }
        #expect(await console.execute("commands"))
        #expect(await console.execute("run toggle-cycle"))
        #expect(await console.execute("run delete-track"))
        #expect(await console.execute("key save"))
        #expect(await console.execute("key undo"))
        #expect(await console.execute("run nonsense"))
        let text = try logText(log)
        #expect(text.contains("go-to-beginning".padding(toLength: 31, withPad: " ", startingAt: 0) + " 21 "))
        #expect(text.contains("先頭に移動"))
        #expect(text.contains("\"status\" : \"verified\""))
        #expect(text.contains("delete-track is destructive"))
        #expect(text.contains("Type \"run! delete-track\""))
        #expect(text.contains("save is destructive"))
        #expect(text.contains("sent undo: BF 18 7F on LogicMCP Keys"))
        #expect(text.contains("Usage: run <command>"))
        // The destructive ones were not sent.
        let fake = try #require(console.runtime.fakeHost)
        #expect(await fake.tracks.count == 11)
        // One controller for the whole console session: it remembers the run above.
        #expect(console.commandController === console.commandController)
        #expect(await console.commandController.lastRuns["toggle-cycle"]?.status == "verified")
    }

    @Test func keyIsRefusedWhileRecording() async throws {
        let (console, log) = try await console()
        defer { try? FileManager.default.removeItem(at: log.deletingLastPathComponent().deletingLastPathComponent()) }
        #expect(await console.execute("record"))
        #expect(await console.execute("key undo"))
        #expect(await console.execute("stop"))
        let text = try logText(log)
        #expect(text.contains("Logic is recording"))
        #expect(!text.contains("sent undo"))
        #expect(await console.runtime.keys.sentCount == 0)
        // Stopped: sent as before.
        #expect(await console.execute("key undo"))
        #expect(try logText(log).contains("sent undo: BF 18 7F on LogicMCP Keys"))
        #expect(await console.runtime.keys.sentCount == 1)
    }

    @Test func confirmedDestructiveRun() async throws {
        let (console, log) = try await console()
        defer { try? FileManager.default.removeItem(at: log.deletingLastPathComponent().deletingLastPathComponent()) }
        #expect(await console.execute("run! delete-track"))
        let text = try logText(log)
        #expect(text.contains("the track count went from 11 to 10"))
        #expect(await console.runtime.fakeHost?.tracks.count == 10)
    }
}
