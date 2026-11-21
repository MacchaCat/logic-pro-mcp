import CommandMap
import FakeLogic
import Foundation
import LogicBridge
import MIDICore
import MIDIPorts

let serverVersion = "0.1.0"

/// Writes a line to stderr. stdout belongs to the MCP transport and must stay clean.
func logError(_ text: String) {
    FileHandle.standardError.write(Data((text + "\n").utf8))
}

enum ConfirmMode: String, Sendable {
    case chat
    case dialog
}

struct RuntimeError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

struct Options {
    var command = "serve"
    var varDirectory: URL
    /// Where the instance lock lives: one place per user whatever `varDirectory` is, so that a
    /// plugin install and a checkout, or servers started in different folders, never both own
    /// the LogicMCP ports.
    var lockDirectory: URL = Options.defaultLockDirectory()
    var sysExPath: SysExPath = .ump
    var script: String?
    var verbose = false
    /// Use an in-memory FakeLogic instead of CoreMIDI ports (development and tests only).
    var fake = false
    var fakeReplaceOn = false
    /// console: read commands from the named pipe `<var>/console.fifo` instead of stdin, so the
    /// console can run in the background and be driven by `echo "status" > var/console.fifo`.
    var fifo = false
    /// How destructive steps are confirmed. `chat` (default): a one-time token the user approves
    /// in chat. `dialog`: MCP elicitation. Claude Code 2.1.326's desktop app advertises
    /// elicitation but auto-declines without showing a dialog (2026-11-21), so `dialog` is opt-in.
    var confirm: ConfirmMode = .chat

    static func parse(_ arguments: [String]) throws -> Options {
        var options = Options(varDirectory: defaultVarDirectory())
        var rest = arguments[...]
        if let first = rest.first, !first.hasPrefix("-") {
            options.command = first
            rest = rest.dropFirst()
        }
        while let argument = rest.popFirst() {
            switch argument {
            case "--var-dir":
                guard let value = rest.popFirst() else { throw RuntimeError("--var-dir needs a path") }
                options.varDirectory = URL(fileURLWithPath: (value as NSString).expandingTildeInPath)
            case "--lock-dir":
                guard let value = rest.popFirst() else { throw RuntimeError("--lock-dir needs a path") }
                options.lockDirectory = URL(fileURLWithPath: (value as NSString).expandingTildeInPath)
            case "--sysex":
                guard let value = rest.popFirst(), let path = SysExPath(rawValue: value) else {
                    throw RuntimeError("--sysex must be ump or legacy")
                }
                options.sysExPath = path
            case "--run":
                guard let value = rest.popFirst() else { throw RuntimeError("--run needs a command list") }
                options.script = value
            case "--verbose", "-v":
                options.verbose = true
            case "--fifo":
                options.fifo = true
            case "--confirm":
                guard let value = rest.popFirst(), let mode = ConfirmMode(rawValue: value) else {
                    throw RuntimeError("--confirm must be chat or dialog")
                }
                options.confirm = mode
            case "--fake":
                options.fake = true
            case "--fake-replace-on":
                options.fake = true
                options.fakeReplaceOn = true
            default:
                throw RuntimeError("Unknown argument \(argument)")
            }
        }
        return options
    }

    /// `LOGIC_MCP_VAR_DIR`; `<repo>/var` when running from `<repo>/.build/...`; otherwise
    /// `~/Library/Application Support/logic-mcp`.
    static func defaultVarDirectory() -> URL {
        if let override = ProcessInfo.processInfo.environment["LOGIC_MCP_VAR_DIR"] {
            return URL(fileURLWithPath: override)
        }
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().path
        if let range = executable.range(of: "/.build/") {
            return URL(fileURLWithPath: String(executable[..<range.lowerBound])).appendingPathComponent("var")
        }
        // Not ./var: a plugin's server starts in whatever folder Claude Code was opened in.
        return applicationSupport
    }

    /// `LOGIC_MCP_LOCK_DIR`, otherwise `~/Library/Application Support/logic-mcp`.
    static func defaultLockDirectory() -> URL {
        if let override = ProcessInfo.processInfo.environment["LOGIC_MCP_LOCK_DIR"] {
            return URL(fileURLWithPath: override)
        }
        return applicationSupport
    }

    static var applicationSupport: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/logic-mcp", isDirectory: true)
    }
}

/// Everything that talks to Logic, wired together.
final class LogicRuntime: Sendable {
    /// nil in `--fake` mode.
    let ports: VirtualPortSet?
    let fakeHost: FakeLogicHost?
    let mcu: MCUSession
    let sync: SyncMonitor
    let transport: TransportController
    let keys: OutputScheduler
    let limits: RateLimits
    let startedAt = Date()

    var endpoints: [EndpointInfo] { ports?.endpoints ?? [] }

    init(options: Options, limits: RateLimits = RateLimits()) async throws {
        self.limits = limits
        sync = SyncMonitor()
        if options.fake {
            let toHost = MIDIPipe(), toSurface = MIDIPipe(), toSync = MIDIPipe(), keysSink = MIDIPipe()
            var behavior = FakeLogicHost.Behavior()
            behavior.replaceOn = options.fakeReplaceOn
            let host = FakeLogicHost(behavior: behavior, toSurface: toSurface, toSync: toSync)
            ports = nil
            fakeHost = host
            mcu = MCUSession(output: toHost, limits: limits)
            keys = OutputScheduler(output: keysSink)
            await mcu.start(input: toSurface.stream)
            await sync.start(input: toSync.stream)
            await host.connect(surfaceInput: toHost.stream)
            await FakeKeyCommandHost.attach(host: host, surface: toSurface, keys: keysSink.stream, behavior: fakeKeyCommandBehavior())
        } else {
            let ports = try Self.makePorts(options.sysExPath)
            self.ports = ports
            fakeHost = nil
            mcu = MCUSession(output: ports.mcuOut, limits: limits)
            keys = OutputScheduler(output: ports.keysOut)
            await mcu.start(input: ports.mcuIn)
            await sync.start(input: ports.syncIn)
        }
        transport = TransportController(mcu: mcu, sync: sync)
    }

    /// Kept out of any actor-isolated context: CoreMIDI calls the receive blocks created
    /// here on its own thread (research §8.2).
    private nonisolated static func makePorts(_ sysExPath: SysExPath) throws -> VirtualPortSet {
        try VirtualPortSet.create(sysExPath: sysExPath)
    }

    func send(_ command: LogicCommand) async {
        await keys.sendKeyCommand(command, limits: limits)
    }

    func shutdown() {
        ports?.dispose()
    }
}
