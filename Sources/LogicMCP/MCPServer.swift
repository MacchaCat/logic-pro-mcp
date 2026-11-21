import Foundation
import LogicBridge
import MCP
import Synchronization

/// Runs tool calls strictly one after another (design §4.2: one tool call at a time).
actor CallQueue {
    private var tail: Task<Void, Never>?

    func run<T: Sendable>(_ operation: @escaping @Sendable () async -> T) async -> T {
        let previous = tail
        let task = Task { () -> T in
            _ = await previous?.value
            return await operation()
        }
        tail = Task { _ = await task.value }
        return await task.value
    }
}

/// One-time tokens for confirming destructive steps in chat when the client has no
/// confirmation dialog (design §4.1, second layer).
actor ConfirmationStore {
    private var tokens: [String: (action: String, expires: ContinuousClock.Instant)] = [:]
    private let clock = ContinuousClock()

    func issue(for action: String) -> String {
        let token = UUID().uuidString.prefix(8).lowercased()
        tokens[String(token)] = (action, clock.now.advanced(by: Self.lifetime))
        return String(token)
    }

    /// Long enough for the user to read the question and answer in chat.
    static let lifetime: Duration = .seconds(300)

    /// Valid once, for the same action, within `lifetime`.
    func consume(_ token: String, for action: String) -> Bool {
        guard let entry = tokens.removeValue(forKey: token) else { return false }
        return entry.action == action && clock.now < entry.expires
    }
}

/// How long to wait for the user to answer a confirmation dialog (env override for tests).
let elicitationTimeoutSeconds = Int(ProcessInfo.processInfo.environment["LOGIC_MCP_ELICITATION_TIMEOUT"] ?? "") ?? 60

struct TimeoutError: Error, CustomStringConvertible {
    let description = "timed out"
}

/// Resumes a continuation at most once, from whichever side finishes first.
private final class ResumeOnce<T: Sendable>: Sendable {
    private let continuation: Mutex<CheckedContinuation<T, any Error>?>
    init(_ continuation: CheckedContinuation<T, any Error>) { self.continuation = Mutex(continuation) }
    func resume(with result: Result<T, any Error>) {
        continuation.withLock { $0.take()?.resume(with: result) }
    }
}

/// Returns the operation's result, or throws `TimeoutError` after `limit` even if the operation
/// never finishes (a late result is discarded).
func withTimeout<T: Sendable>(_ limit: Duration, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        let once = ResumeOnce(continuation)
        let work = Task {
            do { once.resume(with: .success(try await operation())) } catch { once.resume(with: .failure(error)) }
        }
        Task {
            try? await Task.sleep(for: limit)
            once.resume(with: .failure(TimeoutError()))
            work.cancel()
        }
    }
}

actor ClientState {
    var name: String?
    var supportsElicitation = false

    func update(name: String, elicitation: Bool) {
        self.name = name
        supportsElicitation = elicitation
    }
}

struct MCPFrontEnd {
    let context: ToolContext
    let modules: [any ToolModule]
    let queue = CallQueue()

    func register() async {
        let tools = modules.flatMap(\.tools)
        await context.server.withMethodHandler(ListTools.self) { _ in
            .init(tools: tools)
        }
        await context.server.withMethodHandler(CallTool.self) { params in
            await queue.run { await call(params.name, params.arguments ?? [:]) }
        }
    }

    func call(_ name: String, _ arguments: [String: Value]) async -> CallTool.Result {
        for module in modules {
            if let result = await module.call(name, arguments, context: context) { return result }
        }
        return CallTool.Result(content: [.text(text: "Unknown tool \(name)", annotations: nil, _meta: nil)], isError: true)
    }
}

func runServer(_ options: Options) async throws {
    // Fake mode creates no ports, so it needs no lock and can run next to a real server.
    let lock = options.fake ? nil : try InstanceLock(directory: options.varDirectory)
    let runtime = try await LogicRuntime(options: options)
    let server = Server(
        name: "logic-mcp",
        version: serverVersion,
        title: "Logic Pro (Mackie Control)",
        instructions: """
            Controls Logic Pro through an emulated Mackie Control surface. Results report what \
            Logic actually showed afterwards; treat "unverified" and "failed" literally. Never \
            confirm a destructive step for the user: ask them in chat.
            """,
        capabilities: .init(tools: .init(listChanged: true))
    )
    let context = ToolContext(runtime: runtime, server: server, confirmMode: options.confirm)
    let front = MCPFrontEnd(context: context, modules: await ToolRegistry.modules(runtime: runtime))
    await front.register()
    // A client that reconnects to a restarted (possibly upgraded) server keeps its old tool
    // list unless told otherwise; ask it to fetch the list again once it is initialized.
    _ = await server.onNotification(InitializedNotification.self) { _ in
        try? await server.notify(ToolListChangedNotification.message())
    }
    try await server.start(transport: StdioTransport()) { info, capabilities in
        await context.client.update(name: "\(info.name) \(info.version)", elicitation: capabilities.elicitation != nil)
    }
    await server.waitUntilCompleted()
    runtime.shutdown()
    withExtendedLifetime(lock) {}
}
