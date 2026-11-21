import Foundation
import Testing
@testable import LogicMCP

@Suite("Command-line options")
struct OptionsTests {
    @Test func theLockStaysInOnePlaceWhateverTheVarDirectory() throws {
        let options = try Options.parse(["serve", "--var-dir", "/tmp/somewhere-else"])
        #expect(options.varDirectory.path == "/tmp/somewhere-else")
        if ProcessInfo.processInfo.environment["LOGIC_MCP_LOCK_DIR"] == nil {
            #expect(options.lockDirectory.path.hasSuffix("/Library/Application Support/logic-mcp"))
        }
        #expect(options.lockDirectory != options.varDirectory)
    }

    @Test func lockDirectoryCanBeSet() throws {
        let options = try Options.parse(["console", "--lock-dir", "/tmp/lock-here"])
        #expect(options.lockDirectory.path == "/tmp/lock-here")
        #expect(throws: RuntimeError.self) { _ = try Options.parse(["serve", "--lock-dir"]) }
    }
}
