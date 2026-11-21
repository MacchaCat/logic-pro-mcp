import AudioAnalysis
import Foundation
import Synchronization
import Testing
@testable import AnalysisLink

/// A host clock that plays from beat 0 at `tempo`, `rate` times faster than wall time.
private final class ScriptedHost: Sendable {
    private let start = ContinuousClock.now
    let tempo: Double
    let rate: Double
    private let playing = Mutex(true)

    init(tempo: Double, rate: Double) {
        self.tempo = tempo
        self.rate = rate
    }

    func stop() { playing.withLock { $0 = false } }

    func state() -> FakeHostState {
        let (seconds, attoseconds) = start.duration(to: .now).components
        let elapsed = Double(seconds) + Double(attoseconds) / 1e18
        return FakeHostState(playing: playing.withLock { $0 }, beats: elapsed * tempo / 60 * rate, tempoBPM: tempo)
    }
}

@Suite("Frame builder and fake plug-in")
struct FakePluginTests {
    @Test func builderProducesValidFramesFromKernelOutput() throws {
        let kernel = try #require(MeterKernel(.init(sampleRate: 48000, channels: 2, tapCapacity: 1 << 16)))
        let builder = FrameBuilder(instanceID: "00000000-0000-4000-8000-000000000abc", contextName: "Stereo Out", role: "main_output", sampleRate: 48000, channels: 2)
        var frames: [AnalysisFrame] = []
        var beat = 0.0
        TestSignals.render([ToneSegment(seconds: 1, dBFS: -20, channels: 2)], sampleRate: 48000, channels: 2, chunk: 512) { buffers in
            kernel.process(planar: buffers, context: HostContext(beatPosition: beat, tempoBPM: 120, meter: Meter(3, 4), measureDownbeat: 0, playing: true))
            beat += Double(buffers[0].count) * 2 / 48000
            frames += builder.frames(for: kernel.drain(), tap: kernel.drainTap())
        }
        #expect(frames.count == 10)
        #expect(frames.map(\.sequence) == Array(1...10))
        for frame in frames { try frame.validate() }
        #expect(frames.last?.host.meterNumerator == 3)
        #expect(frames.contains { $0.spectrum != nil })
        // Calibrated: 1 kHz stereo at -20 dBFS is -20 LUFS once the filters settled.
        let lufs = try #require(Loudness.lufs(meanSquare: frames[9].subBlocks[0].meanSquare))
        #expect(abs(lufs - -20) < 0.05)
    }

    @Test func builderKeepsNamesWithinTheProtocolLimits() throws {
        let block = SubBlock(index: 0, frames: 4800, flags: [.playing], weightedMeanSquare: 0.01)
        // 200 Japanese characters with a bidi mark and a BEL: reduced to the first 40 characters
        // (120 UTF-8 bytes), still a valid frame.
        let long = "\u{200F}" + String(repeating: "オーディオ", count: 40) + "\u{7}"
        let builder = FrameBuilder(instanceID: "00000000-0000-4000-8000-000000000abc", contextName: long, role: "drums", pluginVersion: "1.0\u{1}",
                                   sampleRate: 48000, channels: 2, spectrum: false)
        let frame = try #require(builder.frames(for: [block]).first)
        try frame.validate()
        let name = try #require(frame.contextName)
        #expect(name.count == 40 && name.utf8.count == 120)
        #expect(name.hasPrefix("オーディオ"))
        #expect(frame.role == nil)  // not a protocol role
        #expect(frame.pluginVersion == nil)

        // Emoji (with tag and joiner sequences), quotes and brackets are dropped.
        builder.contextName = "Gtr \u{1F3F4}\u{E0067}\u{E0062}\u{E0073}\u{E0063}\u{E0074}\u{E007F} \"[x]\" \u{1F468}\u{200D}\u{1F469}"
        let flagged = try #require(builder.frames(for: [SubBlock(index: 1, frames: 4800, flags: [.playing], weightedMeanSquare: 0.01)]).first)
        try flagged.validate()
        #expect(flagged.contextName == "Gtr x")
        builder.contextName = String(repeating: "a", count: 300)
        #expect(builder.contextName?.count == 40)
        builder.contextName = "\u{200E}\u{0}"
        #expect(builder.contextName == nil)
        #expect(FrameBuilder.sanitizedContextName("Stereo Out") == "Stereo Out")
        #expect(FrameBuilder(instanceID: "00000000-0000-4000-8000-000000000abc", pluginVersion: "1.2.0-beta", sampleRate: 48000, channels: 1).pluginVersion == "1.2.0-beta")
    }

    @Test func builderSplitsLargeBacklogs() throws {
        let builder = FrameBuilder(instanceID: "00000000-0000-4000-8000-000000000abc", sampleRate: 48000, channels: 1, spectrum: false)
        let blocks = (0..<150).map { SubBlock(index: UInt64($0), frames: 4800, flags: [.playing], weightedMeanSquare: .infinity) }
        let frames = builder.frames(for: blocks)
        #expect(frames.map(\.subBlocks.count) == [64, 64, 22])
        for frame in frames { try frame.validate() }
        #expect(frames[0].subBlocks[0].meanSquare == 1e4)  // clamped into the protocol's range
        #expect(builder.frames(for: []).isEmpty)
    }

    @Test func fakePluginStreamsMeasuredAudioThroughTheLink() async throws {
        let core = LinkServerCore(hello: ServerHello(version: "test"))
        let log = EventLog(core)
        let host = ScriptedHost(tempo: 240, rate: 4)
        let client = AnalysisLinkClient(
            configuration: .init(helloTimeout: .milliseconds(100), backoff: [.milliseconds(10)]),
            connector: InMemoryLinkConnector(core: core))
        let plugin = FakeAnalysisPlugin(
            configuration: .init(instanceID: "00000000-0000-4000-8000-0000000fa4e1", sampleRate: 8000, channels: 1, tick: .milliseconds(10), spectrum: false),
            client: client) { host.state() }
        await plugin.start()
        // 240 bpm at 4x: one bar per 250 ms; wait for bars 1 ... 3.
        #expect(await eventually(.seconds(5)) {
            log.frames.flatMap(\.subBlocks).compactMap(\.beat).contains { $0 >= 8 }
        })
        await plugin.stop()
        let blocks = log.frames.flatMap(\.subBlocks)
        let playing = blocks.filter { $0.playing && !$0.jumpInside }
        #expect(playing.count >= 20)
        // Beats advance by 0.4 per 100 ms sub-block at 240 bpm.
        for (a, b) in zip(playing, playing.dropFirst()) where b.index == a.index + 1 && !b.jumpBefore {
            #expect(abs((b.beat ?? 0) - (a.beat ?? 0) - 0.4) < 1e-6)
        }
        // The demo song's bars 1-4: 1 kHz at -30 dBFS, mono, so -33.0 LUFS.
        let settled = playing.dropFirst(2).filter { ($0.beat ?? 99) < 15.5 }
        #expect(!settled.isEmpty)
        for block in settled {
            let lufs = try #require(Loudness.lufs(meanSquare: block.meanSquare))
            #expect(abs(lufs - -33.01) < 0.2, "beat \(block.beat ?? -1): \(lufs)")
        }
        #expect(log.frames.allSatisfy { $0.instanceID == "00000000-0000-4000-8000-0000000fa4e1" && $0.role == "main_output" })
    }

    @Test func heartbeatsOnlyWhenNoFrameWasBuilt() throws {
        let builder = FrameBuilder(instanceID: "00000000-0000-4000-8000-000000000abc", contextName: "Bass", role: "track",
                                   pluginVersion: "1.0", sampleRate: 48000, channels: 2, spectrum: false)
        let start = ContinuousClock.now
        // The first call only starts the interval.
        #expect(builder.heartbeat(now: start) == nil)
        let first = try #require(builder.heartbeat(now: start.advanced(by: .milliseconds(1000))))
        try first.validate()
        #expect(first.subBlocks.isEmpty && first.host == HostState())
        #expect(first.instanceID == builder.instanceID && first.contextName == "Bass" && first.role == "track")
        #expect(builder.heartbeat(now: start.advanced(by: .milliseconds(1500))) == nil)
        let second = try #require(builder.heartbeat(now: start.advanced(by: .milliseconds(2000))))
        #expect(second.sequence == first.sequence + 1)
        // An audio frame resets the interval.
        let block = SubBlock(index: 0, frames: 4800, flags: [.playing], weightedMeanSquare: 0.01)
        #expect(builder.frames(for: [block], now: start.advanced(by: .milliseconds(2500))).count == 1)
        #expect(builder.heartbeat(now: start.advanced(by: .milliseconds(3400))) == nil)
        #expect(builder.heartbeat(now: start.advanced(by: .milliseconds(3500))) != nil)
    }

    @Test func heartbeatsKeepAQuietPlugInConnected() async throws {
        // A strip Logic does not render while stopped: no audio frames at all. The server closes
        // connections silent for 1 s here (60 s in use); heartbeats every 100 ms keep the
        // plug-in's open for well over that. Waits poll for a frame count, not a fixed time, and
        // only a stall of 0.9 s between two heartbeats could fail it.
        var limits = LinkServerCore.Limits()
        limits.maxIdle = .seconds(1)
        limits.firstFrameTimeout = .seconds(1)
        func run(heartbeat: Duration?, until done: @escaping @Sendable (LinkServerCore, EventLog) -> Bool) async throws
            -> (LinkServerCore.Statistics, Int) {
            let core = LinkServerCore(hello: ServerHello(version: "test"), limits: limits)
            let log = EventLog(core)
            let host = ScriptedHost(tempo: 120, rate: 1)
            host.stop()
            let client = AnalysisLinkClient(
                configuration: .init(helloTimeout: .milliseconds(100), backoff: [.seconds(10)]),
                connector: InMemoryLinkConnector(core: core))
            let plugin = FakeAnalysisPlugin(
                configuration: .init(instanceID: "00000000-0000-4000-8000-0000000fa4e2", sampleRate: 8000, channels: 1,
                                     tick: .milliseconds(10), spectrum: false, rendersWhileStopped: false, heartbeat: heartbeat),
                client: client) { host.state() }
            await plugin.start()
            core.startSweeping(every: .milliseconds(20))
            #expect(await eventually(.seconds(2)) { client.isConnected })
            #expect(await eventually(.seconds(10)) { done(core, log) })
            let statistics = core.statistics
            await plugin.stop()
            core.finish()
            return (statistics, log.frames.count)
        }
        // 20 heartbeats take 2 s, twice the idle limit.
        let (kept, heartbeats) = try await run(heartbeat: .milliseconds(100)) { _, log in log.frames.count >= 20 }
        #expect(kept.timedOutConnections == 0 && kept.connections == 1, "\(kept)")
        #expect(heartbeats >= 20)
        // Without heartbeats the same plug-in is closed (and reconnects only after 10 s).
        let (closed, frames) = try await run(heartbeat: nil) { core, _ in core.statistics.timedOutConnections >= 1 }
        #expect(closed.timedOutConnections >= 1, "\(closed)")
        #expect(frames == 0)
    }
}
