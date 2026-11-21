import AnalysisLink
import AudioAnalysis
import FakeLogic
import Foundation
import Synchronization
import Testing
@testable import LogicBridge
import MackieControl

/// A valid instance id (hex digits and "-") for a readable test name of at most 15 bytes: the
/// name's UTF-8 bytes in hex, so ids sort and prefix-match like the names.
func testID(_ name: String) -> String {
    "00000000-" + name.utf8.map { String(format: "%02x", $0) }.joined()
}

/// Frames as a plug-in at 48 kHz would send them, one sub-block each, built directly (no audio).
private struct FrameScript {
    var instance = testID("meter-1")
    var contextName: String? = "Stereo Out"
    var role: String? = "main_output"
    var version: String? = "1.0.0"
    var tempo = 120.0
    var meter = Meter(4, 4)
    var nextIndex: UInt64 = 0
    var sequence: UInt64 = 0

    /// `count` playing sub-blocks starting at `beat` with loudness `lufs`.
    mutating func frames(fromBeat beat: Double, count: Int, lufs: Double, playing: Bool = true,
                         downbeat: Double? = nil, jumpBefore: Bool = false) -> [AnalysisFrame] {
        let step = 0.1 * tempo / 60
        return (0..<count).map { offset in
            let start = beat + Double(offset) * step
            sequence += 1
            defer { nextIndex += 1 }
            return AnalysisFrame(
                instanceID: instance, pluginVersion: version, contextName: contextName, role: role, sampleRate: 48000, channels: 2,
                sequence: sequence,
                host: HostState(tempoBPM: tempo, meterNumerator: meter.numerator, meterDenominator: meter.denominator,
                                beatPosition: start, measureDownbeat: downbeat, playing: playing),
                subBlocks: [SubBlockRecord(index: nextIndex, frames: 4800, beat: start, tempo: tempo, playing: playing,
                                           jumpBefore: jumpBefore && offset == 0,
                                           meanSquare: Loudness.meanSquare(lufs: lufs), samplePeak: 0.2, truePeak: 0.25)],
                spectrum: Array(repeating: 1e-5, count: ThirdOctaveBands.count))
        }
    }
}

private func waitUntil(_ timeout: Duration, _ condition: @Sendable () async -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if await condition() { return true }
        try? await clock.sleep(for: .milliseconds(5))
    }
    return await condition()
}

private func feed(_ controller: AnalysisController, _ frames: [AnalysisFrame], connection: UInt64 = 1) async {
    for frame in frames { await controller.handle(.frame(ConnectionID(connection), frame)) }
}

@Suite("Analysis controller (history)")
struct AnalysisControllerTests {
    @Test func noPluginConnectedFails() async {
        let controller = AnalysisController(transport: nil)
        let result = await controller.analyze(instance: nil, ranges: [AnalysisRange(fromBar: 1, toBar: 4)], capture: false)
        #expect(result.status == .failed)
        #expect(result.summary.contains("No analysis plug-in is connected"))
        let report = await controller.report()
        #expect(report.instances.isEmpty)
        #expect(report.notes.contains { $0.contains("No analysis plug-in has connected") })
    }

    @Test func measuresRangesFromHistory() async throws {
        let controller = AnalysisController(transport: nil)
        var script = FrameScript()
        // 120 bpm 4/4: 0.2 beats per sub-block, 20 sub-blocks per bar. Bars 1-4 at -26, 5-8 at -20.
        await feed(controller, script.frames(fromBeat: 0, count: 80, lufs: -26))
        await feed(controller, script.frames(fromBeat: 16, count: 80, lufs: -20))
        let result = await controller.analyze(
            instance: nil,
            ranges: [AnalysisRange(label: "verse", fromBar: 1, toBar: 4), AnalysisRange(label: "chorus", fromBar: 5, toBar: 8),
                     AnalysisRange(label: "later", fromBar: 9, toBar: 12)],
            capture: false)
        #expect(result.status == .partial)
        let ranges = try #require(result.after?.ranges)
        #expect(ranges[0].complete && ranges[1].complete && !ranges[2].complete)
        #expect(abs(try #require(ranges[0].integratedLufs) - -26) < 0.01)
        #expect(abs(try #require(ranges[1].integratedLufs) - -20) < 0.01)
        #expect(ranges[0].passes == 1)
        #expect(ranges[0].tempoBpm == 120)
        #expect(ranges[0].timeSignature == "4/4")
        #expect(ranges[0].spectrum?.count == 30)
        #expect(abs(try #require(ranges[0].truePeakDbtp) - 20 * log10(0.25)) < 0.01)
        #expect(ranges[2].coverage == 0)
        #expect(ranges[2].integratedLufs == nil)
        #expect(ranges[2].notes.contains { $0.contains("capture=true") })
        #expect(result.summary.contains("verse: -26.0 LUFS"))
        // The plug-in's channel name is only in its labelled field, not in the evidence prose.
        #expect(result.after?.pluginReportedContextName == "Stereo Out")
        #expect(!result.evidence.contains { $0.contains("Stereo Out") })
        // The JSON keeps unmeasurable values as explicit nulls.
        let json = String(decoding: try JSONEncoder().encode(ranges[2]), as: UTF8.self)
        #expect(json.contains("\"integratedLufs\":null"))
    }

    @Test func stoppedOrJumpingBlocksAreNotStoredAndPassesStaySeparate() async throws {
        let controller = AnalysisController(transport: nil)
        var script = FrameScript()
        await feed(controller, script.frames(fromBeat: 0, count: 10, lufs: -20, playing: false))
        await feed(controller, script.frames(fromBeat: 0, count: 2, lufs: -20))  // bar 1, 0.0 ... 0.4 beats
        await feed(controller, script.frames(fromBeat: 8, count: 2, lufs: -20))  // jump to bar 3 without a flag
        await feed(controller, script.frames(fromBeat: 8.4, count: 2, lufs: -20, jumpBefore: true))
        let info = try #require(await controller.report().instances.first)
        #expect(info.historySeconds == 0.6)
        #expect(info.coveredBars.count == 2)
        let result = await controller.analyze(instance: nil, ranges: [AnalysisRange(fromBar: 1, toBar: 3)], capture: false)
        let range = try #require(result.after?.ranges.first)
        #expect(range.passes == 3)
        #expect(range.integratedLufs == nil)  // no pass holds 400 ms
    }

    @Test func barsFollowTheReportedMeter() async throws {
        let controller = AnalysisController(transport: nil)
        var script = FrameScript()
        script.meter = Meter(6, 8)  // three quarter notes per bar
        await feed(controller, script.frames(fromBeat: 3, count: 15, lufs: -20, downbeat: 3))  // bar 2
        let info = try #require(await controller.report().instances.first)
        #expect(info.coveredBars.first?.first == 2)
        #expect(info.timeSignature == "6/8")
        let result = await controller.analyze(instance: nil, ranges: [AnalysisRange(fromBar: 2, toBar: 2)], capture: false)
        #expect(result.status == .verified)
    }

    @Test func downbeatThatDoesNotFitTheMeterIsReported() async throws {
        let controller = AnalysisController(transport: nil)
        var script = FrameScript()
        await feed(controller, script.frames(fromBeat: 10, count: 3, lufs: -20, downbeat: 9))
        let info = try #require(await controller.report().instances.first)
        #expect(info.warnings.contains { $0.contains("constant") })
    }

    @Test func theMeterWarningEndsWhenThatBarFitsAgain() async throws {
        let controller = AnalysisController(transport: nil)
        var script = FrameScript()
        // A change to 3/4 at beat 16 (bar 5 under 4/4): bar starts 16, 19, 22 do not fit 3/4 from bar 1.
        script.meter = Meter(3, 4)
        await feed(controller, script.frames(fromBeat: 19.5, count: 3, lufs: -20, downbeat: 19))
        var info = try #require(await controller.report().instances.first)
        #expect(info.warnings == [AnalysisController.InstanceWarning.meterChangesEarlier.rawValue])
        #expect(info.firstUnfittingDownbeatBeats == 19)
        // Playing before the change (fitting 4/4 bars) proves nothing: the warning stays.
        script.meter = Meter(4, 4)
        await feed(controller, script.frames(fromBeat: 4.5, count: 3, lufs: -20, downbeat: 4))
        // Nor does a fitting bar elsewhere after it (a later change can realign the grid).
        await feed(controller, script.frames(fromBeat: 28.5, count: 3, lufs: -20, downbeat: 28))
        info = try #require(await controller.report().instances.first)
        #expect(info.warnings.count == 1 && info.firstUnfittingDownbeatBeats == 19)
        // The change was removed: the bar holding beat 19 now starts at 16 in 4/4 and fits.
        await feed(controller, script.frames(fromBeat: 19.5, count: 3, lufs: -20, downbeat: 16))
        info = try #require(await controller.report().instances.first)
        #expect(info.warnings.isEmpty)
        #expect(info.firstUnfittingDownbeatBeats == nil)
        let result = await controller.analyze(instance: nil, ranges: [AnalysisRange(fromBar: 2, toBar: 2)], capture: false)
        #expect(!result.warnings.contains(AnalysisController.InstanceWarning.meterChangesEarlier.rawValue))
    }

    @Test func oldDataIsMentionedInTheSummary() async throws {
        var configuration = AnalysisController.Configuration()
        configuration.oldDataNoteSeconds = 1
        let controller = AnalysisController(transport: nil, configuration: configuration)
        var script = FrameScript()
        await feed(controller, script.frames(fromBeat: 0, count: 20, lufs: -20))
        let range = [AnalysisRange(fromBar: 1, toBar: 1)]
        let fresh = await controller.analyze(instance: nil, ranges: range, capture: false)
        #expect(!fresh.summary.contains("old (oldest_data_age_seconds)"), "\(fresh.summary)")
        try await Task.sleep(for: .milliseconds(1100))
        let old = await controller.analyze(instance: nil, ranges: range, capture: false)
        #expect(old.status == .verified)
        #expect(old.summary.contains(" s old (oldest_data_age_seconds)"), "\(old.summary)")
        #expect(old.summary.contains("max_age_seconds"))
        #expect(try #require(old.after?.ranges.first?.oldestDataAgeSeconds) >= 1)
    }

    @Test func instanceWarningsComeFirstInAFullList() {
        let instance = AnalysisController.InstanceWarning.allCases.map(\.rawValue)
        let other = (0..<12).map { "capture warning \($0)" } + [instance[1]]
        let merged = AnalysisController.mergeWarnings(instance: instance, other: other, limit: 8)
        #expect(merged.count == 8)
        #expect(Array(merged.prefix(instance.count)) == instance)
        #expect(Set(merged).count == merged.count)
        #expect(merged.last == "capture warning 5")
    }

    @Test func aReinsertedPlugInIsFoundByItsChannelName() async throws {
        let controller = AnalysisController(transport: nil)
        var old = FrameScript()
        old.instance = testID("old-meter")
        await feed(controller, old.frames(fromBeat: 0, count: 20, lufs: -20), connection: 1)
        await controller.handle(.disconnected(ConnectionID(1), reason: nil))
        // Deleted and inserted again on the same strip: a new id, the same channel name.
        var new = FrameScript()
        new.instance = testID("new-meter")
        await feed(controller, new.frames(fromBeat: 0, count: 20, lufs: -20), connection: 2)
        let range = [AnalysisRange(fromBar: 1, toBar: 1)]
        let byName = await controller.analyze(instance: "Stereo Out", ranges: range, capture: false)
        #expect(byName.status == .verified, "\(byName.summary)")
        #expect(byName.after?.instance == testID("new-meter"))
        // Two connected instances with that name are still ambiguous.
        var third = FrameScript()
        third.instance = testID("third-meter")
        await feed(controller, third.frames(fromBeat: 0, count: 20, lufs: -20), connection: 3)
        let ambiguous = await controller.analyze(instance: "Stereo Out", ranges: range, capture: false)
        #expect(ambiguous.status == .failed && ambiguous.summary.contains("several instances"))
        // Several disconnected ones and no connected one: ambiguous too, not "not connected".
        await controller.handle(.disconnected(ConnectionID(2), reason: nil))
        await controller.handle(.disconnected(ConnectionID(3), reason: nil))
        let gone = await controller.analyze(instance: "Stereo Out", ranges: range, capture: false)
        #expect(gone.status == .failed && gone.summary.contains("several instances"))
    }

    @Test func heartbeatsKeepTheInstanceWithoutErasingItsHostState() async throws {
        var configuration = AnalysisController.Configuration()
        configuration.ownerTakeover = .milliseconds(300)
        let controller = AnalysisController(transport: nil, configuration: configuration)
        var script = FrameScript()
        await feed(controller, script.frames(fromBeat: 0, count: 10, lufs: -20, playing: false), connection: 1)
        // Logic stops rendering the strip: only heartbeats come (no sub-blocks, no host state).
        let heartbeat = AnalysisFrame(instanceID: script.instance, pluginVersion: script.version, contextName: script.contextName,
                                      role: script.role, sampleRate: 48000, channels: 2, sequence: 100, host: HostState(),
                                      subBlocks: [])
        let clock = ContinuousClock()
        let end = clock.now.advanced(by: .milliseconds(700))
        var copyFrames = FrameScript()
        copyFrames.contextName = "Copy"
        while clock.now < end {
            await controller.handle(.frame(ConnectionID(1), heartbeat))
            // A second plug-in with the same id: the owner is not silent, so it is refused.
            await feed(controller, copyFrames.frames(fromBeat: 0, count: 1, lufs: -40), connection: 2)
            try await Task.sleep(for: .milliseconds(50))
        }
        let info = try #require(await controller.report().instances.first)
        #expect(info.connected)
        #expect(info.pluginReportedContextName == "Stereo Out")
        #expect(info.duplicateFramesRefused > 0)
        // The tempo and meter of the last audio frame are kept.
        #expect(info.tempoBpm == 120 && info.timeSignature == "4/4" && info.playing == false)
    }

    @Test func manyNonFittingDownbeatsGiveOneWarning() async throws {
        let controller = AnalysisController(transport: nil)
        var script = FrameScript()
        // 200 frames, each with a different bar start that does not fit 4/4 from bar 1.
        for offset in 0..<200 {
            await feed(controller, script.frames(fromBeat: 10 + Double(offset) * 0.2, count: 1, lufs: -20,
                                                 downbeat: 9 + Double(offset) * 4))
        }
        let info = try #require(await controller.report().instances.first)
        #expect(info.warnings.count == 1)
        // A fixed text; the value is a structured field.
        #expect(info.warnings[0] == AnalysisController.InstanceWarning.meterChangesEarlier.rawValue)
        #expect(info.firstUnfittingDownbeatBeats == 9)
        let result = await controller.analyze(instance: nil, ranges: [AnalysisRange(fromBar: 3, toBar: 4)], capture: false)
        #expect(result.warnings.filter { $0.contains("constant") }.count == 1)
    }

    @Test func twoLivePluginsWithOneIDDoNotMix() async throws {
        let controller = AnalysisController(transport: nil)
        // A copied plug-in: same saved id, other channel strip, other level.
        var first = FrameScript()
        first.instance = testID("dup")
        var copy = FrameScript()
        copy.instance = testID("dup")
        copy.contextName = "Bass"
        copy.role = nil
        let a = first.frames(fromBeat: 0, count: 80, lufs: -20)
        let b = copy.frames(fromBeat: 0, count: 80, lufs: -40)
        for (x, y) in zip(a, b) {
            await controller.handle(.frame(ConnectionID(1), x))
            await controller.handle(.frame(ConnectionID(2), y))
        }
        let info = try #require(await controller.report().instances.first)
        #expect(info.duplicateFramesRefused == 80)
        #expect(info.pluginReportedContextName == "Stereo Out")
        #expect(info.pluginReportedDuplicateContextNames == ["Bass"])
        let warning = try #require(info.warnings.first { $0.contains("same instance id") })
        #expect(!warning.contains("Bass") && !warning.contains("Stereo Out") && !warning.contains("\"dup\""))
        #expect(await controller.statusLine().contains("shares an instance id"))
        // Only the first plug-in's signal is stored, as one pass; the status says the source is in doubt.
        let result = await controller.analyze(instance: nil, ranges: [AnalysisRange(fromBar: 1, toBar: 4)], capture: false)
        let range = try #require(result.after?.ranges.first)
        #expect(abs(try #require(range.integratedLufs) - -20) < 0.01)
        #expect(range.passes == 1 && range.complete)
        #expect(result.status == .partial)
        #expect(result.warnings.contains(warning))

        // The first one is deleted: the copy takes over, and the old data (maybe the other
        // channel's) is dropped rather than continued.
        await controller.handle(.disconnected(ConnectionID(1), reason: nil))
        await feed(controller, copy.frames(fromBeat: 16, count: 20, lufs: -40), connection: 2)
        let after = try #require(await controller.report().instances.first)
        #expect(after.connected && after.warnings.isEmpty && after.pluginReportedContextName == "Bass")
        #expect(after.coveredBars.count == 1 && after.coveredBars[0][0] == 5)
        let old = await controller.analyze(instance: nil, ranges: [AnalysisRange(fromBar: 1, toBar: 4)], capture: false)
        #expect(old.after?.ranges.first?.coverage == 0)
        let new = await controller.analyze(instance: nil, ranges: [AnalysisRange(fromBar: 5, toBar: 5)], capture: false)
        #expect(new.status == .verified)
        #expect(abs(try #require(new.after?.ranges.first?.integratedLufs) - -40) < 0.01)
    }

    @Test func aReconnectKeepsTheHistory() async throws {
        let controller = AnalysisController(transport: nil)
        var script = FrameScript()
        await feed(controller, script.frames(fromBeat: 0, count: 40, lufs: -20), connection: 1)
        await controller.handle(.disconnected(ConnectionID(1), reason: nil))
        await feed(controller, script.frames(fromBeat: 8, count: 40, lufs: -20), connection: 7)
        let info = try #require(await controller.report().instances.first)
        #expect(info.warnings.isEmpty && info.duplicateFramesRefused == 0 && info.connected)
        let result = await controller.analyze(instance: nil, ranges: [AnalysisRange(fromBar: 1, toBar: 4)], capture: false)
        #expect(result.status == .verified)
        #expect(result.after?.ranges.first?.passes == 2)
    }

    @Test func aSilentOwnerIsReplacedButFlaggedAsADuplicate() async throws {
        var configuration = AnalysisController.Configuration()
        configuration.ownerTakeover = .milliseconds(200)
        let controller = AnalysisController(transport: nil, configuration: configuration)
        var script = FrameScript()
        await feed(controller, script.frames(fromBeat: 0, count: 20, lufs: -20), connection: 1)
        try await Task.sleep(for: .milliseconds(300))
        // Connection 1 is still open but silent; connection 2 reports the same id.
        var other = FrameScript()
        other.contextName = "Bass"
        await feed(controller, other.frames(fromBeat: 8, count: 20, lufs: -30), connection: 2)
        let info = try #require(await controller.report().instances.first)
        #expect(info.pluginReportedContextName == "Bass")
        #expect(info.warnings.contains { $0.contains("same instance id") })
        #expect(info.coveredBars.count == 1 && info.coveredBars[0][0] == 3)  // bar 1's data was dropped
        // The old one speaks again while the new owner is active: refused. The takeover time is
        // raised first, so a stall between the two connections' frames (parallel tests) cannot
        // make the new owner look silent.
        await controller.updateConfiguration { $0.ownerTakeover = .seconds(3600) }
        for (old, new) in zip(script.frames(fromBeat: 0, count: 5, lufs: -20), other.frames(fromBeat: 12, count: 5, lufs: -30)) {
            await controller.handle(.frame(ConnectionID(2), new))
            await controller.handle(.frame(ConnectionID(1), old))
        }
        let after = try #require(await controller.report().instances.first)
        #expect(after.duplicateFramesRefused == 5)
        #expect(after.pluginReportedContextName == "Bass")
    }

    @Test func aLostDisconnectEventLeavesNoGhost() async throws {
        let core = LinkServerCore(hello: ServerHello(version: "test"))
        let controller = AnalysisController(transport: nil)
        await controller.attach(core)
        core.finish()  // from here on no event reaches the controller
        let id = try #require(core.open(remote: "test"))
        var script = FrameScript()
        for frame in script.frames(fromBeat: 0, count: 5, lufs: -20) { await controller.handle(.frame(id, frame)) }
        #expect(try #require(await controller.report().instances.first).connected)
        core.close(id)  // its .disconnected event is lost
        #expect(try #require(await controller.report().instances.first).connected == false)
        // A late frame of the closed connection does not bring it back.
        for frame in script.frames(fromBeat: 1, count: 1, lufs: -20) { await controller.handle(.frame(id, frame)) }
        #expect(try #require(await controller.report().instances.first).connected == false)
        #expect(await controller.analyze(instance: nil, ranges: [AnalysisRange(fromBar: 1, toBar: 1)], capture: false).status == .failed)
    }

    @Test func fragmentedCoverageIsNotAMeasurement() async throws {
        let controller = AnalysisController(transport: nil)
        var script = FrameScript()
        script.tempo = 150  // 0.25 beats per sub-block: exact in binary, so passes abut exactly
        // Bars 1-2 covered by passes of three sub-blocks (300 ms) each: no 400 ms block anywhere.
        for start in stride(from: 0.0, to: 8, by: 0.75) {
            await feed(controller, script.frames(fromBeat: start, count: 3, lufs: -20, jumpBefore: true))
        }
        let result = await controller.analyze(instance: nil, ranges: [AnalysisRange(fromBar: 1, toBar: 2)], capture: false)
        let range = try #require(result.after?.ranges.first)
        #expect(range.coverage > 0.99)
        #expect(!range.complete)
        #expect(range.integratedLufs == nil)
        #expect(range.notes.contains { $0.contains("shorter than 400 ms") })
        #expect(result.status == .partial)
        #expect(result.summary.contains("fragments"))
    }

    @Test func coveredSilenceIsStillVerified() async throws {
        let controller = AnalysisController(transport: nil)
        var script = FrameScript()
        await feed(controller, script.frames(fromBeat: 0, count: 20, lufs: -200))
        let result = await controller.analyze(instance: nil, ranges: [AnalysisRange(fromBar: 1, toBar: 1)], capture: false)
        #expect(result.status == .verified)
        #expect(result.after?.ranges.first?.integratedLufs == nil)
        #expect(result.after?.ranges.first?.notes.contains { $0.contains("silence") } == true)
    }

    @Test func overlappingAndAdjacentRangesShareOnePass() {
        func passes(_ ranges: [(Int, Int)]) -> [AnalysisController.CapturePass] {
            AnalysisController.capturePasses(
                ranges.enumerated().map { ($0.offset, AnalysisRange(fromBar: $0.element.0, toBar: $0.element.1)) }, preRollBars: 1)
        }
        #expect(passes([(1, 8), (5, 6)]) == [.init(startBar: 1, fromBar: 1, toBar: 8, indices: [0, 1])])
        // Pre-roll of the second (bar 7) follows bar 6: one pass, one pre-roll.
        #expect(passes([(5, 6), (8, 9)]) == [.init(startBar: 4, fromBar: 5, toBar: 9, indices: [0, 1])])
        // A gap: two passes, in bar order.
        #expect(passes([(9, 10), (5, 6)]) == [.init(startBar: 4, fromBar: 5, toBar: 6, indices: [1]),
                                              .init(startBar: 8, fromBar: 9, toBar: 10, indices: [0])])
        #expect(passes([(2, 3), (1, 1), (3, 12)]).map(\.barCount) == [12])
    }

    @Test func captureNeedsTempoAndMeterFromThePlugIn() async throws {
        let harness = await Harness.make()
        let controller = AnalysisController(transport: harness.transport)
        let frame = AnalysisFrame(
            instanceID: testID("no-tempo"), sampleRate: 48000, channels: 2, sequence: 1, host: HostState(playing: false),
            subBlocks: [SubBlockRecord(index: 0, frames: 4800, playing: false, meanSquare: 0, samplePeak: 0, truePeak: 0)])
        await controller.handle(.frame(ConnectionID(1), frame))
        let result = await controller.analyze(instance: nil, ranges: [AnalysisRange(fromBar: 5, toBar: 6)], capture: true)
        #expect(result.status == .failed)
        #expect(result.summary.contains("tempo and time signature"))
        #expect(await harness.host.presses.isEmpty)
        #expect(await harness.host.jogTicks == 0)
    }

    @Test func captureRefusesWhenThePlugInReportsCycle() async throws {
        // Only a fallback: here Logic does not report its Cycle LED.
        var behavior = FakeLogicHost.Behavior()
        behavior.reportsCycleLED = false
        let harness = await Harness.make(behavior)
        let controller = AnalysisController(transport: harness.transport)
        let frame = AnalysisFrame(
            instanceID: testID("cycling"), sampleRate: 48000, channels: 2, sequence: 1,
            host: HostState(tempoBPM: 120, meterNumerator: 4, meterDenominator: 4, beatPosition: 0, playing: false, cycling: true),
            subBlocks: [SubBlockRecord(index: 0, frames: 4800, playing: false, meanSquare: 0, samplePeak: 0, truePeak: 0)])
        await controller.handle(.frame(ConnectionID(1), frame))
        #expect(await controller.report().instances.first?.cycling == true)
        let result = await controller.analyze(instance: nil, ranges: [AnalysisRange(fromBar: 5, toBar: 6)], capture: true)
        #expect(result.status == .failed)
        #expect(result.summary.contains("Cycle mode is on"), "\(result.summary)")
        #expect(await harness.host.presses.isEmpty)
        #expect(await harness.host.jogTicks == 0)
    }

    /// Heartbeats keep the Cycle flag of the plug-in's last audio frame; when Logic's Cycle LED
    /// says off, that stale flag must not block a capture.
    @Test func theCycleLEDOverridesAStalePlugInCycleFlag() async throws {
        let harness = await Harness.make()  // Cycle LED reported, off
        var configuration = AnalysisController.Configuration()
        configuration.dataWait = .milliseconds(200)
        let controller = AnalysisController(transport: harness.transport, configuration: configuration)
        let frame = AnalysisFrame(
            instanceID: testID("stale-cycle"), sampleRate: 48000, channels: 2, sequence: 1,
            host: HostState(tempoBPM: 120, meterNumerator: 4, meterDenominator: 4, beatPosition: 0, playing: false, cycling: true),
            subBlocks: [SubBlockRecord(index: 0, frames: 4800, playing: false, meanSquare: 0, samplePeak: 0, truePeak: 0)])
        await controller.handle(.frame(ConnectionID(1), frame))
        let result = await controller.analyze(instance: nil, ranges: [AnalysisRange(fromBar: 2, toBar: 2)], capture: true)
        #expect(!result.summary.contains("Cycle mode is on"), "\(result.summary)")
        // It went ahead and played (bar 1 is one bar before bar 2: no jog needed).
        #expect(await harness.host.presses.contains(MCUButton.play.rawValue))
    }

    @Test func instanceSelection() async throws {
        let controller = AnalysisController(transport: nil)
        var bass = FrameScript()
        bass.instance = testID("bass-meter")
        bass.contextName = "Bass"
        bass.role = "track"
        var master = FrameScript()
        master.instance = testID("out-meter")
        master.role = nil
        // The main output's plug-in was connected first (inserted first, as in setup).
        await feed(controller, master.frames(fromBeat: 0, count: 20, lufs: -18), connection: 2)
        await feed(controller, bass.frames(fromBeat: 0, count: 20, lufs: -30), connection: 1)
        let range = [AnalysisRange(fromBar: 1, toBar: 1)]
        // No role marked, but one is named like the main output.
        let byName = await controller.analyze(instance: nil, ranges: range, capture: false)
        #expect(byName.after?.instance == testID("out-meter"))
        let explicit = await controller.analyze(instance: "bass", ranges: range, capture: false)
        #expect(explicit.after?.instance == testID("bass-meter"))
        #expect(abs(try #require(explicit.after?.ranges.first?.integratedLufs) - -30) < 0.01)
        let byPrefix = await controller.analyze(instance: testID("bass-m"), ranges: range, capture: false)
        #expect(byPrefix.after?.instance == testID("bass-meter"))
        let unknown = await controller.analyze(instance: "drums", ranges: range, capture: false)
        #expect(unknown.status == .failed)
        // The failure lists the candidates in a labelled field, not in the summary.
        #expect(unknown.after?.candidates?.map(\.instance) == ["bass-meter", "out-meter"].map(testID))
        #expect(unknown.after?.candidates?.first { $0.isDefault }?.instance == testID("out-meter"))
        #expect(!unknown.summary.contains("Bass") && !unknown.summary.contains("drums") && !unknown.summary.contains("meter"))
        // Another main-output-like instance connects later: the default stays.
        var other = FrameScript()
        other.instance = testID("x-meter")
        other.contextName = "Stereo Out 2"
        other.role = nil
        await feed(controller, other.frames(fromBeat: 0, count: 2, lufs: -18), connection: 3)
        let still = await controller.analyze(instance: nil, ranges: range, capture: false)
        #expect(still.after?.instance == testID("out-meter"))
        #expect(still.warnings.contains(AnalysisController.ResultWarning.severalInstances))
        // A disconnected instance cannot be used.
        await controller.handle(.disconnected(ConnectionID(1), reason: nil))
        let gone = await controller.analyze(instance: testID("bass-meter"), ranges: range, capture: false)
        #expect(gone.status == .failed)
        #expect(gone.summary.contains("not connected"))
        #expect(await controller.statusLine().contains("2 plug-in instances connected"))
        #expect(!(await controller.statusLine()).contains("out-meter"))
    }

    @Test func severalInstancesWithoutAMainOutputAreAmbiguous() async throws {
        let controller = AnalysisController(transport: nil)
        for (index, name) in ["Bass", "Drums"].enumerated() {
            var script = FrameScript()
            script.instance = testID("meter-\(index)")
            script.contextName = name
            script.role = "track"
            await feed(controller, script.frames(fromBeat: 0, count: 2, lufs: -20), connection: UInt64(index + 1))
        }
        let result = await controller.analyze(instance: nil, ranges: [AnalysisRange(fromBar: 1, toBar: 1)], capture: false)
        #expect(result.status == .failed)
        #expect(result.summary.contains("Several"))
        #expect(result.after?.candidates?.count == 2)
        #expect(await controller.report().instances.allSatisfy { !$0.isDefault })
    }

    @Test func aNewcomerClaimingTheMainOutputDoesNotDisplaceTheDefault() async throws {
        let controller = AnalysisController(transport: nil)
        let range = [AnalysisRange(fromBar: 1, toBar: 1)]
        // The real plug-in on the Stereo Out (no role set) connects and is used once: it becomes
        // the default.
        var real = FrameScript()
        real.instance = testID("real-meter")
        real.role = nil
        await feed(controller, real.frames(fromBeat: 0, count: 20, lufs: -18), connection: 1)
        #expect(await controller.analyze(instance: nil, ranges: range, capture: false).after?.instance == testID("real-meter"))
        // Another local program connects later and declares itself the main output.
        var spoof = FrameScript()
        spoof.instance = testID("spoof-meter")
        spoof.contextName = "Main Output"
        spoof.role = "main_output"
        await feed(controller, spoof.frames(fromBeat: 0, count: 20, lufs: -40), connection: 2)
        let after = await controller.analyze(instance: nil, ranges: range, capture: false)
        #expect(after.after?.instance == testID("real-meter"))
        #expect(after.warnings.contains(AnalysisController.ResultWarning.severalInstances))
        // More frames from the newcomer change nothing.
        await feed(controller, spoof.frames(fromBeat: 4, count: 5, lufs: -40), connection: 2)
        #expect(await controller.analyze(instance: nil, ranges: range, capture: false).after?.instance == testID("real-meter"))
        let infos = await controller.report().instances
        #expect(infos.first { $0.instance == testID("real-meter") }?.isDefault == true)
        #expect(infos.first { $0.instance == testID("spoof-meter") }?.isDefault == false)
        #expect(infos.allSatisfy { $0.claimsMainOutput })
        // Asking for the other one explicitly does not move the default.
        #expect(await controller.analyze(instance: testID("spoof-meter"), ranges: range, capture: false).after?.instance == testID("spoof-meter"))
        #expect(await controller.analyze(instance: nil, ranges: range, capture: false).after?.instance == testID("real-meter"))
        // Only when the default disconnects is a new one chosen (here the only one left).
        await controller.handle(.disconnected(ConnectionID(1), reason: nil))
        #expect(await controller.analyze(instance: nil, ranges: range, capture: false).after?.instance == testID("spoof-meter"))
        // The returning real plug-in does not take the default back while the other stays.
        await feed(controller, real.frames(fromBeat: 8, count: 5, lufs: -18), connection: 3)
        #expect(await controller.analyze(instance: nil, ranges: range, capture: false).after?.instance == testID("spoof-meter"))
    }

    @Test func severalMainOutputClaimsWithoutADefaultAreAmbiguous() async throws {
        let controller = AnalysisController(transport: nil)
        var real = FrameScript()
        real.instance = testID("real-meter")
        real.role = nil  // named "Stereo Out"
        var spoof = FrameScript()
        spoof.instance = testID("spoof-meter")
        spoof.contextName = "Main Output"
        spoof.role = "main_output"
        await feed(controller, real.frames(fromBeat: 0, count: 20, lufs: -18), connection: 1)
        await feed(controller, spoof.frames(fromBeat: 0, count: 20, lufs: -40), connection: 2)
        // Claims are self-declared: neither the order nor role-versus-name decides.
        let result = await controller.analyze(instance: nil, ranges: [AnalysisRange(fromBar: 1, toBar: 1)], capture: false)
        #expect(result.status == .failed)
        #expect(result.summary.contains("several claim to be the main output"))
        #expect(result.after?.candidates?.map(\.instance) == ["real-meter", "spoof-meter"].map(testID))
        #expect(await controller.report().instances.allSatisfy { !$0.isDefault })
    }

    @Test func aLaterClaimDoesNotDisplaceAnInstanceConnectedEarlier() async throws {
        // A track meter is the only instance but has never been used without "instance"; a
        // newcomer claiming the main output is the only claimant, but it connected later: its
        // claim is not trusted, the call fails and lists both.
        let controller = AnalysisController(transport: nil)
        var track = FrameScript()
        track.instance = testID("track-meter")
        track.contextName = "Bass"
        track.role = "track"
        await feed(controller, track.frames(fromBeat: 0, count: 20, lufs: -30), connection: 1)
        var newcomer = FrameScript()
        newcomer.instance = testID("new-meter")
        newcomer.contextName = "Anything"
        newcomer.role = "main_output"
        await feed(controller, newcomer.frames(fromBeat: 0, count: 20, lufs: -18), connection: 2)
        let range = [AnalysisRange(fromBar: 1, toBar: 1)]
        let result = await controller.analyze(instance: nil, ranges: range, capture: false)
        #expect(result.status == .failed)
        #expect(result.summary.contains("connected after another one"), "\(result.summary)")
        #expect(result.after?.instance == nil)
        let candidates = try #require(result.after?.candidates)
        #expect(candidates.map(\.instance) == ["new-meter", "track-meter"].map(testID))
        #expect(candidates.map(\.claimsMainOutput) == [true, false])
        #expect(await controller.report().instances.allSatisfy { !$0.isDefault })
        // Picking one explicitly works and does not make it the default.
        #expect(await controller.analyze(instance: testID("new-meter"), ranges: range, capture: false).after?.instance == testID("new-meter"))
        #expect(await controller.analyze(instance: nil, ranges: range, capture: false).status == .failed)
        // Once the earlier instance is gone, the claimant is the only one connected.
        await controller.handle(.disconnected(ConnectionID(1), reason: nil))
        #expect(await controller.analyze(instance: nil, ranges: range, capture: false).after?.instance == testID("new-meter"))
    }

    @Test func aSpoofCannotTakeTheDefaultFromAnUnmarkedMainOutput() async throws {
        // The real plug-in on the main output reports no role and a name the server does not
        // recognise (e.g. a localized strip name). A local program connects afterwards and
        // declares itself the main output before anyone asked for a default.
        let controller = AnalysisController(transport: nil)
        var real = FrameScript()
        real.instance = testID("real-meter")
        real.contextName = "Sortie stéréo"
        real.role = nil
        await feed(controller, real.frames(fromBeat: 0, count: 20, lufs: -18), connection: 1)
        var spoof = FrameScript()
        spoof.instance = testID("spoof-meter")
        spoof.contextName = "Stereo Out"
        spoof.role = "main_output"
        await feed(controller, spoof.frames(fromBeat: 0, count: 20, lufs: -40), connection: 2)
        let range = [AnalysisRange(fromBar: 1, toBar: 1)]
        let result = await controller.analyze(instance: nil, ranges: range, capture: false)
        // Not the spoof's fabricated level with status verified: a failure with both candidates.
        #expect(result.status == .failed)
        #expect(result.after?.ranges.isEmpty == true)
        #expect(Set(try #require(result.after?.candidates).map(\.instance)) == Set(["real-meter", "spoof-meter"].map(testID)))
        // More frames from the spoof, or reconnecting it, change nothing.
        await controller.handle(.disconnected(ConnectionID(2), reason: nil))
        await feed(controller, spoof.frames(fromBeat: 4, count: 5, lufs: -40), connection: 3)
        #expect(await controller.analyze(instance: nil, ranges: range, capture: false).status == .failed)
        // The user picks the real one by name; it is measured.
        let picked = await controller.analyze(instance: "Sortie stéréo", ranges: range, capture: false)
        #expect(picked.after?.instance == testID("real-meter"))
        #expect(abs(try #require(picked.after?.ranges.first?.integratedLufs) - -18) < 0.01)
    }

    @Test func aClaimFromTheFirstConnectedInstanceIsTrusted() async throws {
        // Normal setup: the main output's plug-in is inserted first, a track meter later.
        let controller = AnalysisController(transport: nil)
        var out = FrameScript()
        out.instance = testID("out-meter")
        out.role = "main_output"
        var track = FrameScript()
        track.instance = testID("track-meter")
        track.contextName = "Bass"
        track.role = "track"
        await feed(controller, out.frames(fromBeat: 0, count: 20, lufs: -18), connection: 1)
        await feed(controller, track.frames(fromBeat: 0, count: 20, lufs: -30), connection: 2)
        let result = await controller.analyze(instance: nil, ranges: [AnalysisRange(fromBar: 1, toBar: 1)], capture: false)
        #expect(result.status == .verified, "\(result.summary)")
        #expect(result.after?.instance == testID("out-meter"))
        #expect(result.warnings.contains(AnalysisController.ResultWarning.severalInstances))
        #expect(await controller.report().instances.first { $0.instance == testID("out-meter") }?.isDefault == true)
    }

    @Test func requestsAreMatchedLikeTheStoredNames() async throws {
        let controller = AnalysisController(transport: nil)
        var guitar = FrameScript()
        guitar.instance = testID("gtr-meter")
        guitar.contextName = "Gtr \"Lead\" 🎸"
        guitar.role = "track"
        var bass = FrameScript()
        bass.instance = testID("bass-meter")
        bass.contextName = "Bass"
        bass.role = "track"
        // An instance whose id is another instance's channel name (a strip named like a hex id).
        var shadow = FrameScript()
        shadow.instance = "0000bead"
        shadow.contextName = "Keys"
        shadow.role = "track"
        var named = FrameScript()
        named.instance = testID("named-meter")
        named.contextName = "0000BEAD"
        named.role = "track"
        await feed(controller, guitar.frames(fromBeat: 0, count: 20, lufs: -20), connection: 1)
        await feed(controller, bass.frames(fromBeat: 0, count: 20, lufs: -20), connection: 2)
        await feed(controller, shadow.frames(fromBeat: 0, count: 20, lufs: -20), connection: 3)
        await feed(controller, named.frames(fromBeat: 0, count: 20, lufs: -20), connection: 4)
        let range = [AnalysisRange(fromBar: 1, toBar: 1)]
        #expect(try #require(await controller.report().instances.first { $0.instance == testID("gtr-meter") }).pluginReportedContextName == "Gtr Lead")
        // The track's real name (quotes, emoji) still selects it.
        #expect(await controller.analyze(instance: "Gtr \"Lead\" 🎸", ranges: range, capture: false).after?.instance == testID("gtr-meter"))
        #expect(await controller.analyze(instance: "gtr lead", ranges: range, capture: false).after?.instance == testID("gtr-meter"))
        #expect(await controller.analyze(instance: "Bass", ranges: range, capture: false).after?.instance == testID("bass-meter"))
        // "0000bead" is both an id and another instance's name: the exact id wins.
        #expect(await controller.analyze(instance: "0000bead", ranges: range, capture: false).after?.instance == "0000bead")
        // Also once that instance has disconnected: never the connected namesake instead.
        await controller.handle(.disconnected(ConnectionID(3), reason: nil))
        let gone = await controller.analyze(instance: "0000bead", ranges: range, capture: false)
        #expect(gone.status == .failed && gone.summary.contains("not connected"), "\(gone.summary)")
        #expect(gone.after?.instance != testID("named-meter"))
        // The namesake is still found by its own id.
        #expect(await controller.analyze(instance: testID("named-meter"), ranges: range, capture: false).after?.instance == testID("named-meter"))
        #expect(await controller.analyze(instance: testID("bass-meter"), ranges: range, capture: false).after?.instance == testID("bass-meter"))
    }

    @Test func aSpoofedIDCannotTakeOverALiveOwner() async throws {
        let controller = AnalysisController(transport: nil)
        var real = FrameScript()
        real.instance = testID("meter-1")
        await feed(controller, real.frames(fromBeat: 0, count: 40, lufs: -18), connection: 1)
        // Same id from another connection while the owner keeps sending: refused, data untouched.
        var spoof = FrameScript()
        spoof.instance = testID("meter-1")
        spoof.contextName = "Evil"
        for (a, b) in zip(real.frames(fromBeat: 8, count: 20, lufs: -18), spoof.frames(fromBeat: 8, count: 20, lufs: 0)) {
            await controller.handle(.frame(ConnectionID(1), a))
            await controller.handle(.frame(ConnectionID(2), b))
        }
        let info = try #require(await controller.report().instances.first)
        #expect(info.pluginReportedContextName == "Stereo Out")
        #expect(info.duplicateFramesRefused == 20)
        let result = await controller.analyze(instance: nil, ranges: [AnalysisRange(fromBar: 1, toBar: 4)], capture: false)
        #expect(abs(try #require(result.after?.ranges.first?.integratedLufs) - -18) < 0.01)
        #expect(result.status == .partial)  // a duplicate is live: flagged
    }

    @Test func rangeValidation() async {
        let controller = AnalysisController(transport: nil)
        for ranges in [[], [AnalysisRange(fromBar: 0, toBar: 2)], [AnalysisRange(fromBar: 5, toBar: 4)],
                       Array(repeating: AnalysisRange(fromBar: 1, toBar: 1), count: 17)] {
            let result = await controller.analyze(instance: nil, ranges: ranges, capture: true)
            #expect(result.status == .failed)
            #expect(result.summary.contains("Nothing was played"))
        }
    }

    @Test func historyIsBoundedAcrossInstances() async throws {
        var configuration = AnalysisController.Configuration()
        configuration.historyCapacity = 100
        let controller = AnalysisController(transport: nil, configuration: configuration)
        var a = FrameScript()
        a.instance = testID("a")
        var b = FrameScript()
        b.instance = testID("b")
        await feed(controller, a.frames(fromBeat: 0, count: 80, lufs: -20), connection: 1)
        await feed(controller, b.frames(fromBeat: 0, count: 80, lufs: -20), connection: 2)
        let report = await controller.report()
        #expect(report.historyBlocks == 100)
        #expect(report.instances.first { $0.instance == testID("b") }?.historySeconds == 8)
    }

    @Test func instanceCountIsBounded() async {
        var configuration = AnalysisController.Configuration()
        configuration.maxInstances = 2
        let controller = AnalysisController(transport: nil, configuration: configuration)
        for (index, name) in ["a", "b", "c"].enumerated() {
            var script = FrameScript()
            script.instance = testID(name)
            await feed(controller, script.frames(fromBeat: 0, count: 1, lufs: -20), connection: UInt64(index))
        }
        #expect(await controller.report().instances.map(\.instance) == ["a", "b"].map(testID))
        // Once one disconnects it can be replaced.
        await controller.handle(.disconnected(ConnectionID(0), reason: nil))
        var c = FrameScript()
        c.instance = testID("c")
        await feed(controller, c.frames(fromBeat: 0, count: 1, lufs: -20), connection: 2)
        #expect(await controller.report().instances.map(\.instance) == ["b", "c"].map(testID))
    }
}

/// Capture against FakeLogic: FakePlayhead advances the fake's time display while it plays and a
/// fake plug-in (8 kHz mono, real kernel) streams the demo song through the in-memory link.
/// A switch the fake plug-in's host clock reads: when on, the plug-in sees a stopped transport
/// whatever FakeLogic does (so it stores nothing).
private final class Blindfold: Sendable {
    let on = Mutex(false)
}

private struct CaptureRig {
    let harness: Harness
    let playhead: FakePlayhead
    let plugin: FakeAnalysisPlugin
    let controller: AnalysisController
    let blindfold: Blindfold

    static func make(
        rate: Double = 4, behavior: FakeLogicHost.Behavior = .init(), timeouts: TransportController.Timeouts = .init(),
        configure: (inout AnalysisController.Configuration) -> Void = { _ in }
    ) async -> CaptureRig {
        let harness = await Harness.make(behavior, timeouts: timeouts)
        let playhead = FakePlayhead(host: harness.host, tempoBPM: 240, rate: rate)
        await playhead.start()
        let core = LinkServerCore(hello: ServerHello(version: "test"))
        var configuration = AnalysisController.Configuration()
        configuration.dataWait = .seconds(2)
        configure(&configuration)
        let controller = AnalysisController(transport: harness.transport, configuration: configuration)
        await controller.attach(core)
        let client = AnalysisLinkClient(configuration: .init(backoff: [.milliseconds(10)]), connector: InMemoryLinkConnector(core: core))
        let blindfold = Blindfold()
        let plugin = FakeAnalysisPlugin(
            configuration: .init(instanceID: testID("fake-meter"), sampleRate: 8000, channels: 1, tick: .milliseconds(10), spectrum: false),
            client: client) {
            let state = await playhead.state()
            let playing = state.playing && !blindfold.on.withLock { $0 }
            return FakeHostState(playing: playing, beats: state.beats, tempoBPM: state.tempoBPM)
        }
        await plugin.start()
        _ = await waitUntil(.seconds(3)) {
            guard let info = await controller.report().instances.first else { return false }
            return info.connected && info.tempoBpm != nil
        }
        return CaptureRig(harness: harness, playhead: playhead, plugin: plugin, controller: controller, blindfold: blindfold)
    }

    func playPresses() async -> Int {
        await harness.host.presses.filter { $0 == MCUButton.play.rawValue }.count
    }

    func shutdown() async {
        await plugin.stop()
        await playhead.stop()
    }
}

@Suite("Analysis capture against FakeLogic", .serialized)
struct AnalysisCaptureTests {
    @Test func capturePlaysTheMissingRangeAndStops() async throws {
        let rig = await CaptureRig.make()
        defer { Task { await rig.shutdown() } }
        let result = await rig.controller.analyze(
            instance: nil, ranges: [AnalysisRange(label: "verse", fromBar: 5, toBar: 6)], capture: true)
        #expect(result.status == .verified, "\(result.summary) \(result.warnings)")
        let range = try #require(result.after?.ranges.first)
        #expect(range.captured)
        #expect(range.complete)
        #expect(range.coverage > 0.95)
        // Demo song bars 5-8: 1 kHz at -26 dBFS; mono, so -29.0 LUFS.
        #expect(abs(try #require(range.integratedLufs) - -29.01) < 0.2)
        #expect(result.before?.ranges.first?.coverage == 0)
        #expect(result.after?.transport?.playing == false)
        let presses = await rig.harness.host.presses
        #expect(presses.contains(MCUButton.play.rawValue))
        #expect(presses.last == MCUButton.stop.rawValue)
        #expect(result.evidence.contains { $0.contains("time display reached") })
        // A second call finds the data already there and plays nothing.
        let again = await rig.controller.analyze(instance: nil, ranges: [AnalysisRange(fromBar: 5, toBar: 6)], capture: true)
        #expect(again.status == .verified)
        #expect(again.after?.ranges.first?.captured == false)
        #expect(await rig.harness.host.presses.count == presses.count)
    }

    /// Observed on Logic 13: the metronome click is part of the main output's audio.
    @Test func aCaptureWithTheMetronomeOnSaysSo() async throws {
        var behavior = FakeLogicHost.Behavior()
        behavior.reportsClickLED = true
        behavior.clickOn = true
        let rig = await CaptureRig.make(behavior: behavior)
        defer { Task { await rig.shutdown() } }
        let result = await rig.controller.analyze(instance: nil, ranges: [AnalysisRange(fromBar: 5, toBar: 6)], capture: true)
        #expect(result.status == .verified, "\(result.summary) \(result.warnings)")
        #expect(result.warnings.contains(AnalysisController.metronomeWarning))
    }

    @Test func anUnconfirmedStopIsNeverVerified() async throws {
        // Logic accepts Play, then ignores the surface (a dialog opened): Stop is not confirmed.
        var behavior = FakeLogicHost.Behavior()
        behavior.ignoresSurfaceAfterPresses = 1
        var timeouts = TransportController.Timeouts()
        timeouts.stop = .milliseconds(300)
        let rig = await CaptureRig.make(behavior: behavior, timeouts: timeouts)
        defer { Task { await rig.shutdown() } }
        let result = await rig.controller.analyze(instance: nil, ranges: [AnalysisRange(fromBar: 5, toBar: 6)], capture: true)
        // The range itself was measured completely, yet Logic may still be playing.
        let range = try #require(result.after?.ranges.first)
        #expect(range.complete && range.captured)
        #expect(result.status == .partial, "\(result.summary)")
        #expect(result.summary.contains(AnalysisController.ResultWarning.stopNotConfirmed), "\(result.summary)")
        #expect(result.warnings.contains { $0.contains("Stop was not confirmed") })
        #expect(await rig.harness.host.playing == true)
        #expect(await rig.harness.host.presses.last == MCUButton.stop.rawValue)
    }

    @Test func aLateStartWhoseStopIsIgnoredIsReported() async throws {
        // Play is not confirmed in time, Logic starts late, then ignores the Stop press.
        var behavior = FakeLogicHost.Behavior()
        behavior.playStartDelay = .milliseconds(500)
        behavior.ignoresSurfaceAfterPresses = 1
        var timeouts = TransportController.Timeouts()
        timeouts.play = .milliseconds(200)
        timeouts.stop = .milliseconds(300)
        let rig = await CaptureRig.make(behavior: behavior, timeouts: timeouts)
        defer { Task { await rig.shutdown() } }
        let result = await rig.controller.analyze(instance: nil, ranges: [AnalysisRange(fromBar: 5, toBar: 6)], capture: true)
        // Failed or partial (the late playback may have stored some data), never verified.
        #expect(result.status != .verified)
        #expect(result.after?.ranges.first?.captured == false)
        #expect(result.summary.contains("Play was not confirmed"), "\(result.summary)")
        #expect(result.summary.contains(AnalysisController.ResultWarning.stopNotConfirmed), "\(result.summary)")
        #expect(result.warnings.contains { $0.contains("started playing after the Play timeout and Stop was not confirmed") })
        #expect(await rig.harness.host.playing == true)
        #expect(await rig.harness.host.presses.last == MCUButton.stop.rawValue)
    }

    @Test func oneTimeLimitCoversTheWholeCall() async throws {
        // Two passes of two bars at 240 bpm reported (4 s estimated) within a 4.5 s limit, while
        // the playhead runs at half speed: the first pass takes about 4 s, so the second must
        // not start (separate per-pass limits used to allow 4.5 s each).
        let rig = await CaptureRig.make(rate: 0.5) { $0.maxCaptureSeconds = 4.5 }
        defer { Task { await rig.shutdown() } }
        let clock = ContinuousClock()
        let started = clock.now
        let result = await rig.controller.analyze(
            instance: nil, ranges: [AnalysisRange(fromBar: 5, toBar: 5), AnalysisRange(fromBar: 9, toBar: 9)], capture: true)
        let elapsed = started.duration(to: clock.now)
        #expect(result.status != .verified)
        #expect(result.summary.contains("time limit for one call"), "\(result.summary)")
        #expect(elapsed < .seconds(7), "\(elapsed)")
        #expect(await rig.playPresses() <= 2)
        #expect(await rig.harness.host.playing == false)
        #expect(await rig.harness.host.presses.last == MCUButton.stop.rawValue)
        #expect(result.after?.ranges.last?.complete == false)
    }

    @Test func maxAgePlaysMeasuredRangesAgain() async throws {
        let rig = await CaptureRig.make()
        defer { Task { await rig.shutdown() } }
        let range = [AnalysisRange(fromBar: 5, toBar: 6)]
        let first = await rig.controller.analyze(instance: nil, ranges: range, capture: true)
        #expect(first.status == .verified, "\(first.summary)")
        try await Task.sleep(for: .milliseconds(300))
        // Fresh enough: nothing is played.
        let fresh = await rig.controller.analyze(instance: nil, ranges: range, capture: true, maxAgeSeconds: 60)
        #expect(fresh.after?.ranges.first?.captured == false)
        #expect(await rig.playPresses() == 1)
        #expect(try #require(fresh.after?.ranges.first?.oldestDataAgeSeconds) >= 0.3)
        // Older than allowed: played again, and the range holds only the new data.
        let clock = ContinuousClock()
        let startedAgain = clock.now
        let again = await rig.controller.analyze(instance: nil, ranges: range, capture: true, maxAgeSeconds: 0.2)
        let sinceStart = startedAgain.duration(to: clock.now).seconds
        #expect(again.status == .verified, "\(again.summary)")
        #expect(again.after?.ranges.first?.captured == true)
        #expect(await rig.playPresses() == 2)
        let after = try #require(again.after?.ranges.first)
        #expect(try #require(after.oldestDataAgeSeconds) <= sinceStart + 0.01, "\(after.oldestDataAgeSeconds ?? -1) vs \(sinceStart)")
        #expect(after.passes == 1)
        let invalid = await rig.controller.analyze(instance: nil, ranges: range, capture: true, maxAgeSeconds: -1)
        #expect(invalid.status == .failed && invalid.summary.contains("max_age_seconds"))
    }

    @Test func captureRefusesWhileLogicPlays() async throws {
        let rig = await CaptureRig.make()
        defer { Task { await rig.shutdown() } }
        _ = await rig.harness.transport.play()
        let result = await rig.controller.analyze(instance: nil, ranges: [AnalysisRange(fromBar: 30, toBar: 31)], capture: true)
        #expect(result.status != .verified)
        #expect(result.summary.contains("Stop first"))
        _ = await rig.harness.transport.stop()
    }

    @Test func captureLimitIsCheckedBeforePlaying() async throws {
        let rig = await CaptureRig.make()
        defer { Task { await rig.shutdown() } }
        let result = await rig.controller.analyze(instance: nil, ranges: [AnalysisRange(fromBar: 1, toBar: 200)], capture: true)
        #expect(result.status == .failed)
        #expect(result.summary.contains("limit"))
        #expect(await rig.harness.host.presses.isEmpty)
        #expect(await rig.harness.host.jogTicks == 0)
    }

    @Test func overlappingRangesArePlayedOnce() async throws {
        let rig = await CaptureRig.make()
        defer { Task { await rig.shutdown() } }
        let result = await rig.controller.analyze(
            instance: nil, ranges: [AnalysisRange(label: "all", fromBar: 2, toBar: 8), AnalysisRange(label: "verse", fromBar: 5, toBar: 6)],
            capture: true)
        #expect(result.status == .verified, "\(result.summary) \(result.warnings)")
        #expect(await rig.playPresses() == 1)
        let ranges = try #require(result.after?.ranges)
        #expect(ranges.allSatisfy { $0.captured && $0.complete && $0.passes == 1 })
        #expect(await rig.harness.host.presses.last == MCUButton.stop.rawValue)
    }

    @Test func aLateStartAfterThePlayTimeoutIsStopped() async throws {
        var behavior = FakeLogicHost.Behavior()
        behavior.playStartDelay = .milliseconds(500)
        var timeouts = TransportController.Timeouts()
        timeouts.play = .milliseconds(200)
        let rig = await CaptureRig.make(behavior: behavior, timeouts: timeouts)
        defer { Task { await rig.shutdown() } }
        let result = await rig.controller.analyze(instance: nil, ranges: [AnalysisRange(fromBar: 5, toBar: 6)], capture: true)
        #expect(result.status == .failed)
        #expect(result.summary.contains("Play was not confirmed"))
        #expect(result.evidence.contains { $0.contains("Stop was pressed") }, "\(result.evidence) \(result.warnings)")
        #expect(await rig.harness.host.playing == false)
        #expect(await rig.harness.host.presses.last == MCUButton.stop.rawValue)
        #expect(result.after?.ranges.first?.captured == false)
    }

    @Test func aJumpBackStopsTheCapture() async throws {
        let rig = await CaptureRig.make()
        defer { Task { await rig.shutdown() } }
        // Logic loops bars 4-6 although no Cycle LED was ever reported.
        await rig.playhead.setCycle(4...6)
        let result = await rig.controller.analyze(instance: nil, ranges: [AnalysisRange(fromBar: 5, toBar: 8)], capture: true)
        #expect(result.status != .verified)
        #expect(result.summary.contains("jumped back"), "\(result.summary)")
        #expect(await rig.harness.host.playing == false)
        #expect(await rig.harness.host.presses.last == MCUButton.stop.rawValue)
    }

    @Test func aLoopEndingInThePreRollBarIsCaught() async throws {
        // Cycle on bars 3-4, capture 5-8: playback starts at bar 4 and never gets past it.
        let rig = await CaptureRig.make(rate: 2)
        defer { Task { await rig.shutdown() } }
        await rig.playhead.setCycle(3...4)
        let clock = ContinuousClock()
        let started = clock.now
        let result = await rig.controller.analyze(instance: nil, ranges: [AnalysisRange(fromBar: 5, toBar: 8)], capture: true)
        #expect(result.summary.contains("jumped back from bar 4 to bar 3"), "\(result.summary)")
        // Caught on the first loop, long before the time limit (5 bars at 0.5 s, x 1.5, + 5 s).
        #expect(started.duration(to: clock.now) < .seconds(4))
        #expect(await rig.harness.host.playing == false)
        #expect(await rig.harness.host.presses.last == MCUButton.stop.rawValue)
    }

    @Test func playTimeAndLastBarAreCheckedBeforePlaying() async throws {
        let rig = await CaptureRig.make { $0.maxCaptureSeconds = 10 }
        defer { Task { await rig.shutdown() } }
        // 17 bars of 4/4 at 240 bpm: 17 s.
        let long = await rig.controller.analyze(instance: nil, ranges: [AnalysisRange(fromBar: 5, toBar: 20)], capture: true)
        #expect(long.status == .failed)
        #expect(long.summary.contains("about 17 s") && long.summary.contains("10 s"), "\(long.summary)")
        // The time display has three bar digits.
        let far = await rig.controller.analyze(instance: nil, ranges: [AnalysisRange(fromBar: 998, toBar: 999)], capture: true)
        #expect(far.status == .failed)
        #expect(far.summary.contains("up to bar 998"))
        #expect(await rig.harness.host.presses.isEmpty)
        #expect(await rig.harness.host.jogTicks == 0)
    }

    @Test func dataFromAnEarlierCaptureDoesNotCount() async throws {
        let rig = await CaptureRig.make()
        defer { Task { await rig.shutdown() } }
        let first = await rig.controller.analyze(instance: nil, ranges: [AnalysisRange(fromBar: 20, toBar: 21)], capture: true)
        #expect(first.status == .verified, "\(first.summary)")
        // Now the plug-in stores nothing while Logic plays bars 4-6.
        rig.blindfold.on.withLock { $0 = true }
        let second = await rig.controller.analyze(instance: nil, ranges: [AnalysisRange(fromBar: 5, toBar: 6)], capture: true)
        #expect(second.status == .failed)
        #expect(second.warnings.contains { $0.contains("sent no data") }, "\(second.warnings)")
        #expect(!second.evidence.contains { $0.contains("plug-in data up to") }, "\(second.evidence)")
    }

    @Test func pluginVanishingDuringCaptureStillStopsLogic() async throws {
        let rig = await CaptureRig.make(rate: 1)
        defer { Task { await rig.shutdown() } }
        Task {
            try? await Task.sleep(for: .milliseconds(400))
            await rig.plugin.stop()
        }
        let result = await rig.controller.analyze(instance: nil, ranges: [AnalysisRange(fromBar: 2, toBar: 9)], capture: true)
        #expect(result.status != .verified)
        #expect(result.summary.contains("disconnected"))
        #expect(await rig.harness.host.playing == false)
        #expect(await rig.harness.host.presses.last == MCUButton.stop.rawValue)
    }
}
