import Foundation
import LogicBridge
import MCP

/// Phase 1 tools: connection status and transport. (`get_session_state` is in MixerTools.)
struct TransportTools: ToolModule {
    var tools: [Tool] { TransportToolSchemas.all }

    func call(_ name: String, _ arguments: [String: Value], context: ToolContext) async -> CallTool.Result? {
        switch name {
        case "logic_status":
            let report = await StatusReport.make(
                runtime: context.runtime, client: await context.client.name,
                elicitation: await context.client.supportsElicitation)
            return context.encode(report, isError: false)
        case "transport":
            return context.encode(await transport(arguments, context))
        default:
            return nil
        }
    }

    private func transport(_ arguments: [String: Value], _ context: ToolContext) async -> TransportController.Result {
        guard let action = arguments["action"]?.stringValue else {
            return .init(status: .failed, summary: "Missing \"action\".")
        }
        switch action {
        case "play": return await context.runtime.transport.play()
        case "stop": return await context.runtime.transport.stop()
        case "locate":
            let bar = arguments["bar"]?.intValue ?? 0
            guard bar >= 1 else { return .init(status: .failed, summary: "\"bar\" must be 1 or greater.") }
            return await context.runtime.transport.locate(bar: bar, beat: max(arguments["beat"]?.intValue ?? 1, 1))
        case "record":
            if let token = arguments["confirmation_token"]?.stringValue {
                guard await context.consumeToken(token, for: "record") else {
                    return .init(status: .failed, summary: "The confirmation token is invalid, already used or expired (5 min). Call again without a token to get a new one. Nothing was sent.")
                }
                return await context.runtime.transport.record(confirmed: true)
            }
            let result = await context.runtime.transport.record(confirmed: false)
            guard result.status == .needsConfirmation else { return result }
            return await context.confirm(result.summary, action: "record", pending: result) {
                await context.runtime.transport.record(confirmed: true)
            }
        default:
            return .init(status: .failed, summary: "Unknown action \"\(action)\". Use play, stop, record or locate.")
        }
    }
}

enum TransportToolSchemas {
    static let logicStatus = Tool(
        name: "logic_status",
        title: "Logic connection status",
        description: """
            Self-check of the Logic Pro bridge: virtual MIDI ports, Mackie Control link with Logic \
            (handshake, messages received), what Logic's control surface display currently shows, \
            MIDI clock reception, and setup problems. Call this first when anything fails.
            """,
        inputSchema: .object(["type": "object", "properties": .object([:]), "additionalProperties": false]),
        annotations: .init(title: "Logic connection status", readOnlyHint: true, idempotentHint: true, openWorldHint: false)
    )

    static let transport = Tool(
        name: "transport",
        title: "Logic transport",
        description: """
            Play, stop or record in Logic Pro through the emulated Mackie Control surface. Every \
            call returns Logic's actual transport state afterwards (from Logic's own LEDs, time \
            display and MIDI clock), and status "verified" only if Logic confirmed the change. \
            "play" while already playing and "stop" while already stopped send nothing. \
            "record" in Replace mode (or when Logic has not reported the Replace state) can \
            overwrite existing material and needs the user's confirmation: the result is \
            "needs_confirmation" with a confirmation_token; ask the user in chat and repeat the \
            call with that token only after they explicitly agree (tokens expire after 5 minutes). "locate" moves the playhead to the start of "bar" \
            (beat must be 1) with the jog wheel while Logic is stopped, checking Logic's time \
            display after every step; it takes roughly 0.1 s per bar of distance.
            """,
        inputSchema: .object([
            "type": "object",
            "properties": .object([
                "action": .object(["type": "string", "enum": .array(["play", "stop", "record", "locate"])]),
                "bar": .object(["type": "integer", "minimum": 1, "maximum": 999, "description": "Target bar for locate."]),
                "beat": .object(["type": "integer", "minimum": 1, "maximum": 1, "description": "Target beat for locate; only 1 is supported."]),
                "confirmation_token": .object(["type": "string", "description": "Token from a previous needs_confirmation result, after the user agreed in chat."]),
            ]),
            "required": .array(["action"]),
            "additionalProperties": false,
        ]),
        annotations: .init(title: "Logic transport", readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false)
    )

    static let all = [logicStatus, transport]
}
