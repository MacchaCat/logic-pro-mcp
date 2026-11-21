import Foundation
import LogicBridge
import MackieControl
import MIDICore
import MIDIPorts

/// Payload of `logic_status`.
struct StatusReport: Codable, Sendable {
    struct Surface: Codable, Sendable {
        var lcdUpper: String
        var lcdLower: String
        var assignment: String
        var timeDisplay: String?
        /// Raw 7-segment codes, left to right, for diagnosing the display format.
        var timeDisplayCodes: [String]
        var ledsLit: [String]
        var faders: [Int?]

        enum CodingKeys: String, CodingKey {
            case assignment, faders
            case lcdUpper = "lcd_upper"
            case lcdLower = "lcd_lower"
            case timeDisplay = "time_display"
            case timeDisplayCodes = "time_display_codes"
            case ledsLit = "leds_lit"
        }
    }

    var server: String
    var client: String?
    var clientSupportsElicitation: Bool
    var uptimeSeconds: Int
    var ports: [EndpointInfo]
    var mackie: MCULinkStatus
    var sync: SyncSnapshot
    var transport: TransportSnapshot
    var surface: Surface
    var locate: String
    var notes: [String]

    enum CodingKeys: String, CodingKey {
        case server, client, ports, mackie, sync, transport, surface, locate, notes
        case clientSupportsElicitation = "client_supports_elicitation"
        case uptimeSeconds = "uptime_seconds"
    }

    static func make(runtime: LogicRuntime, client: String?, elicitation: Bool) async -> StatusReport {
        let surface = await runtime.mcu.surface
        let link = await runtime.mcu.linkStatus()
        let sync = await runtime.sync.snapshot()
        let codes = stride(from: 9, through: 0, by: -1).map { index -> String in
            surface.timecode[index].map { [$0].hexString } ?? "--"
        }
        let lit = surface.leds.filter { $0.value != .off }.keys.sorted().map { note in
            mcuNoteName(note) + (surface.led(note) == .flashing ? " (flashing)" : "")
        }
        var notes: [String] = []
        if runtime.fakeHost != nil {
            notes.append("FAKE MODE: connected to an in-memory FakeLogic, not to Logic Pro.")
        }
        if link.messagesReceived == 0 {
            notes.append("Logic has not sent anything to the LogicMCP MCU port yet. Set up a Mackie Control surface on the LogicMCP MCU input and output (docs/setup/01-phase1-logic-setup.md).")
        }
        if sync.messagesReceived == 0 {
            notes.append("No MIDI Clock / SPP received on LogicMCP Sync yet. Tempo is unavailable; the Sync port only receives while Logic is set to send clock to it.")
        }
        if runtime.endpoints.contains(where: { !$0.uniqueIDApplied }) {
            notes.append("CoreMIDI refused a stable unique ID for at least one port; Logic may not recognise it as the same port after a restart.")
        }
        notes += await StatusNotes.shared.notes()
        return StatusReport(
            server: "logic-mcp \(serverVersion)",
            client: client,
            clientSupportsElicitation: elicitation,
            uptimeSeconds: Int(Date().timeIntervalSince(runtime.startedAt)),
            ports: runtime.endpoints,
            mackie: link,
            sync: sync,
            transport: await runtime.transport.snapshot(),
            surface: Surface(
                lcdUpper: surface.lcdUpperLine,
                lcdLower: surface.lcdLowerLine,
                assignment: surface.assignmentText,
                timeDisplay: surface.timecodeText,
                timeDisplayCodes: codes,
                ledsLit: lit,
                faders: surface.faders.map { $0.map(Int.init) }
            ),
            locate: "jog wheel, one bar per tick, verified on the time display (needs Beats display and Logic stopped)",
            notes: notes
        )
    }
}
