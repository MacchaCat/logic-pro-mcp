import Foundation
import LogicBridge
import MCP

/// A group of MCP tools. Each phase adds one module (its own file) and one line in
/// `ToolRegistry.modules`, so parallel work does not collide in shared files.
protocol ToolModule: Sendable {
    var tools: [Tool] { get }
    /// Handles `name` if this module owns it; returns nil otherwise.
    func call(_ name: String, _ arguments: [String: Value], context: ToolContext) async -> CallTool.Result?
}

enum ToolRegistry {
    /// The modules served by `logic-mcp serve`, in the order their tools are listed.
    /// Add one line per phase; keep module construction inside the module's own file.
    static func modules(runtime: LogicRuntime) async -> [any ToolModule] {
        var modules: [any ToolModule] = []
        modules.append(TransportTools())
        modules.append(await MixerTools.make(runtime: runtime))
        modules.append(await CommandTools.make(runtime: runtime, sharing: modules))
        modules.append(await NoteTools.make(runtime: runtime, sharing: modules))
        modules.append(await AnalysisTools.make(runtime: runtime))
        _ = runtime
        return modules
    }
}

/// Shared services for tool modules: the runtime, the confirmation flow and result encoding.
final class ToolContext: Sendable {
    let runtime: LogicRuntime
    let server: Server
    let confirmMode: ConfirmMode
    let confirmations = ConfirmationStore()
    let client = ClientState()

    init(runtime: LogicRuntime, server: Server, confirmMode: ConfirmMode) {
        self.runtime = runtime
        self.server = server
        self.confirmMode = confirmMode
    }

    /// Runs `execute` only after the user's confirmation. With `--confirm dialog` and a client
    /// that advertises elicitation, asks through a dialog (60 s timeout); otherwise returns
    /// `pending` as `needs_confirmation` with a one-time token for confirming in chat. Callers
    /// redeem the token with `consumeToken(_:for:)` on the follow-up call.
    func confirm<S>(
        _ reason: String, action: String, pending: OperationResult<S>,
        execute: () async -> OperationResult<S>
    ) async -> OperationResult<S> {
        var pending = pending
        if confirmMode == .dialog, await client.supportsElicitation {
            let schema = Elicitation.RequestSchema(
                title: "Confirm \(action)",
                properties: ["confirm": .object(["type": "boolean", "title": "Go ahead", "default": false])],
                required: ["confirm"]
            )
            do {
                // Tool calls are serialised, so an unanswered (or never shown) dialog must not
                // block every later call, including "stop".
                let server = self.server
                let answer = try await withTimeout(.seconds(elicitationTimeoutSeconds)) {
                    try await server.requestElicitation(
                        message: "\(reason)\n\nGo ahead with \(action)?", requestedSchema: schema)
                }
                if answer.action == .accept, answer.content?["confirm"]?.boolValue == true {
                    return await execute()
                }
                pending.status = .failed
                pending.summary = "The user did not confirm (\(answer.action.rawValue)). Nothing was sent."
                return pending
            } catch is TimeoutError {
                pending.warnings.append("The confirmation dialog was not answered within \(elicitationTimeoutSeconds) s; falling back to confirmation in chat. A late answer to that dialog is ignored.")
            } catch {
                pending.warnings.append("The confirmation dialog failed (\(error)); falling back to confirmation in chat.")
            }
        }
        pending.confirmationToken = await confirmations.issue(for: action)
        pending.summary += " Ask the user in chat; if they explicitly agree, call again with confirmation_token."
        return pending
    }

    /// True once for a token issued for `action` within `ConfirmationStore.lifetime` (5 min).
    func consumeToken(_ token: String, for action: String) async -> Bool {
        await confirmations.consume(token, for: action)
    }

    func encode<S>(_ result: OperationResult<S>) -> CallTool.Result {
        encode(result, isError: result.status == .failed)
    }

    func encode<T: Codable>(_ value: T, isError: Bool) -> CallTool.Result {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.keyEncodingStrategy = .convertToSnakeCase
        do {
            let data = try encoder.encode(value)
            let text = String(decoding: data, as: UTF8.self)
            // Build structuredContent from the same JSON so both carry identical snake_case keys.
            let structured = try JSONDecoder().decode(Value.self, from: data)
            return CallTool.Result(
                content: [.text(text: text, annotations: nil, _meta: nil)],
                structuredContent: Optional<Value>.some(structured), isError: isError)
        } catch {
            return CallTool.Result(content: [.text(text: "Encoding failed: \(error)", annotations: nil, _meta: nil)], isError: true)
        }
    }
}
