import SwiftUI

/// The container app. It only exists so that macOS registers the LogicMCP Meter audio unit
/// extension it carries: open it once after building, then Logic Pro lists the plug-in.
@main
struct LogicMCPMeterApp: App {
    var body: some Scene {
        WindowGroup("LogicMCP Meter") {
            VStack(alignment: .leading, spacing: 12) {
                Text("LogicMCP Meter").font(.title2.bold())
                Text("This app carries the LogicMCP Meter audio unit. In Logic Pro, insert Audio FX > Audio Units > LogicMCP > Meter on the Stereo Out channel strip; it sends loudness, peaks and the spectrum to the logic-mcp server on this Mac (127.0.0.1 only).")
                    .fixedSize(horizontal: false, vertical: true)
                Text("You can quit this app; the plug-in does not need it to run.")
                    .foregroundStyle(.secondary)
            }
            .padding(24)
            .frame(width: 460)
        }
        .windowResizability(.contentSize)
    }
}
