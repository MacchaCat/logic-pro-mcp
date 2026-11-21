// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "LogicProMCP",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "logic-mcp", targets: ["LogicMCP"]),
        // The analysis plug-in (Plugin/, an Xcode project from XcodeGen) links these.
        .library(name: "LogicMCPMeterSupport", targets: ["LoudnessKernel", "AudioAnalysis", "AnalysisLink"]),
    ],
    dependencies: [
        // Pinned exactly: `main` after 0.12.1 crashes on socketpair stdio (swift-sdk#327).
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", exact: "0.12.1"),
    ],
    targets: [
        // MARK: Phase 1
        // Pure MIDI 1.0 byte stream + UMP codec. No CoreMIDI.
        .target(name: "MIDICore"),
        // Pure Mackie Control protocol: codec, surface state, handshake. No CoreMIDI.
        .target(name: "MackieControl", dependencies: ["MIDICore"]),
        // The only module that imports CoreMIDI: virtual endpoints with stable unique IDs.
        .target(name: "MIDIPorts", dependencies: ["MIDICore"]),
        // Session state, transport, sync, rate limiting, result envelope. No CoreMIDI.
        .target(name: "LogicBridge", dependencies: ["MIDICore", "MackieControl", "CommandMap", "AudioAnalysis", "AnalysisLink"]),
        // Test double for Logic's Mackie Control host side.
        .target(name: "FakeLogic", dependencies: ["MIDICore", "MackieControl", "CommandMap"]),

        // MARK: Phase 2 — read-only Accessibility (full track names)
        .target(name: "LogicAX"),

        // MARK: Phase 3 — key-command catalog
        .target(name: "CommandMap", dependencies: ["MIDICore"]),

        // MARK: Phase 5 — analysis
        // C kernel: real-time safe, shared with the AU plug-in.
        .target(name: "LoudnessKernel"),
        .target(name: "AudioAnalysis", dependencies: ["LoudnessKernel"]),
        // Loopback TCP link, frame format, plug-in side frame builder (shared with the plug-in).
        .target(name: "AnalysisLink", dependencies: ["AudioAnalysis"]),

        // MARK: Executable
        .executableTarget(
            name: "LogicMCP",
            dependencies: [
                "MIDICore",
                "MackieControl",
                "MIDIPorts",
                "LogicBridge",
                "FakeLogic",
                "LogicAX",
                "CommandMap",
                "AudioAnalysis",
                "AnalysisLink",
                .product(name: "MCP", package: "swift-sdk"),
            ]
        ),

        // MARK: Tests
        .testTarget(name: "MIDICoreTests", dependencies: ["MIDICore"]),
        .testTarget(
            name: "MackieControlTests",
            dependencies: ["MackieControl", "MIDICore"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "LogicBridgeTests",
            dependencies: ["LogicBridge", "FakeLogic", "MackieControl", "MIDICore", "CommandMap", "AudioAnalysis", "AnalysisLink"]
        ),
        .testTarget(name: "MIDIPortsTests", dependencies: ["MIDIPorts"]),
        .testTarget(name: "LogicAXTests", dependencies: ["LogicAX"]),
        // Tool argument parsing of the executable (design §5.1).
        .testTarget(
            name: "LogicMCPTests",
            dependencies: ["LogicMCP", "LogicBridge", "CommandMap", .product(name: "MCP", package: "swift-sdk")]
        ),
        .testTarget(name: "CommandMapTests", dependencies: ["CommandMap", "MIDICore"]),
        .testTarget(name: "AudioAnalysisTests", dependencies: ["AudioAnalysis", "LoudnessKernel"]),
        .testTarget(name: "AnalysisLinkTests", dependencies: ["AnalysisLink", "AudioAnalysis"]),
    ]
)
