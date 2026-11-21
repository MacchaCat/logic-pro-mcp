import FakeLogic
import Foundation
import Testing
@testable import LogicBridge
import MackieControl
import MIDICore

/// Wires an `MCUSession` + `SyncMonitor` to a `FakeLogicHost` through in-memory pipes.
struct Harness {
    let session: MCUSession
    let sync: SyncMonitor
    let host: FakeLogicHost
    let transport: TransportController

    static func make(
        _ behavior: FakeLogicHost.Behavior = .init(),
        timeouts: TransportController.Timeouts = .init()
    ) async -> Harness {
        let surfaceToHost = MIDIPipe()
        let hostToSurface = MIDIPipe()
        let hostToSync = TimedMIDIPipe()  // timed on arrival, like the CoreMIDI callback
        let session = MCUSession(output: surfaceToHost, limits: .none)
        await session.start(input: hostToSurface.stream)
        let sync = SyncMonitor()
        await sync.start(input: hostToSync.stream)
        let host = FakeLogicHost(behavior: behavior, toSurface: hostToSurface, toSync: hostToSync)
        await host.connect(surfaceInput: surfaceToHost.stream)
        _ = await session.waitUntil(timeout: .seconds(2)) { $0.lcdRevision > 0 && $0.timecodeRevision > 0 }
        return Harness(session: session, sync: sync, host: host,
                       transport: TransportController(mcu: session, sync: sync, timeouts: timeouts))
    }
}

private var shortTimeouts: TransportController.Timeouts {
    var t = TransportController.Timeouts()
    t.play = .milliseconds(200)
    t.stop = .milliseconds(200)
    t.record = .milliseconds(200)
    return t
}

@Suite("Transport against FakeLogic")
struct TransportTests {
    @Test func handshakeCompletes() async throws {
        let h = await Harness.make()
        let confirmed = await pollUntil { await h.host.handshakeConfirmed }
        #expect(confirmed)
        #expect(await h.session.linkStatus().handshake == .confirmed)
        #expect(await h.session.linkStatus().otherModelProbes == ["15"])
    }

    @Test func playIsVerifiedByTheLED() async {
        let h = await Harness.make()
        let result = await h.transport.play()
        #expect(result.status == .verified)
        #expect(result.before?.playing == false)
        #expect(result.after?.playing == true)
        #expect(await h.host.presses == [MCUButton.play.rawValue])
    }

    @Test func playWhenAlreadyPlayingSendsNothing() async {
        let h = await Harness.make()
        _ = await h.transport.play()
        let again = await h.transport.play()
        #expect(again.status == .verified)
        #expect(again.summary.contains("Already playing"))
        #expect(await h.host.presses == [MCUButton.play.rawValue])
    }

    @Test func stopWhenStoppedDoesNotPressStop() async {
        let h = await Harness.make()
        let result = await h.transport.stop()
        #expect(result.status == .verified)
        #expect(await h.host.presses.isEmpty)
    }

    @Test func stopAfterPlay() async {
        let h = await Harness.make()
        _ = await h.transport.play()
        let result = await h.transport.stop()
        #expect(result.status == .verified)
        #expect(result.after?.playing == false)
        #expect(await h.host.presses == [MCUButton.play.rawValue, MCUButton.stop.rawValue])
    }

    @Test func recordInReplaceModeNeedsConfirmation() async {
        var behavior = FakeLogicHost.Behavior()
        behavior.replaceOn = true
        let h = await Harness.make(behavior)
        let first = await h.transport.record(confirmed: false)
        #expect(first.status == .needsConfirmation)
        #expect(await h.host.presses.isEmpty)
        let second = await h.transport.record(confirmed: true)
        #expect(second.status == .verified)
        #expect(second.after?.recording == true)
        #expect(second.warnings.count == 1)
    }

    @Test func recordWithUnknownReplaceStateNeedsConfirmation() async {
        var behavior = FakeLogicHost.Behavior()
        behavior.reportsReplaceLED = false
        let h = await Harness.make(behavior)
        let result = await h.transport.record(confirmed: false)
        #expect(result.status == .needsConfirmation)
        #expect(result.summary.contains("has not reported the Replace LED"))
        #expect(await h.host.presses.isEmpty)
    }

    @Test func recordWithReplaceOffStartsDirectly() async {
        let h = await Harness.make()
        let result = await h.transport.record(confirmed: false)
        #expect(result.status == .verified)
        #expect(result.after?.recording == true)
        #expect(result.warnings.isEmpty)
    }

    @Test func unresponsiveHostIsReportedAsFailed() async {
        var behavior = FakeLogicHost.Behavior()
        behavior.respondsToButtons = false
        let h = await Harness.make(behavior, timeouts: shortTimeouts)
        let result = await h.transport.play()
        #expect(result.status == .failed)
        #expect(result.after?.playing == false)
        #expect(await h.host.presses == [MCUButton.play.rawValue])
    }

    @Test func syncAloneCanConfirmPlay() async {
        var behavior = FakeLogicHost.Behavior()
        behavior.transportLEDs = false
        behavior.reportsReplaceLED = false
        let h = await Harness.make(behavior)
        let result = await h.transport.play()
        #expect(result.status == .verified)
        #expect(result.after?.sync.running == true)
    }

    @Test func nothingIsSentBeforeLogicTalks() async {
        let output = MIDIPipe()
        let session = MCUSession(output: output, limits: .none)
        let transport = TransportController(mcu: session, sync: SyncMonitor(), timeouts: shortTimeouts)
        let result = await transport.play()
        #expect(result.status == .failed)
        #expect(await session.linkStatus().messagesSent == 0)
    }

    @Test func positionIsReadFromTheTimeDisplay() async {
        let h = await Harness.make()
        await h.host.setPosition(BeatsPosition(bar: 17, beat: 3, division: 2, tick: 120))
        let ok = await pollUntil { await h.transport.snapshot().position?.bar == 17 }
        #expect(ok)
        let snapshot = await h.transport.snapshot()
        #expect(snapshot.position == BeatsPosition(bar: 17, beat: 3, division: 2, tick: 120))
        #expect(snapshot.displayMode == .beats)
        #expect(snapshot.display == " 17 3 2120")
    }

    @Test func smpteDisplayIsNotParsedAsBars() async {
        var behavior = FakeLogicHost.Behavior()
        behavior.beatsDisplay = false
        let h = await Harness.make(behavior)
        let snapshot = await h.transport.snapshot()
        #expect(snapshot.displayMode == .smpte)
        #expect(snapshot.position == nil)
    }

    @Test func locateForwardWithJog() async {
        let h = await Harness.make()
        let result = await h.transport.locate(bar: 17, beat: 1)
        #expect(result.status == .verified)
        #expect(result.after?.position == BeatsPosition(bar: 17, beat: 1, division: 1, tick: 1))
        #expect(await h.host.jogTicks == 16)
    }

    @Test func locateBackwardAcrossDigitBoundaries() async {
        let h = await Harness.make()
        await h.host.setPosition(BeatsPosition(bar: 102, beat: 1, division: 1, tick: 1))
        _ = await pollUntil { await h.transport.snapshot().position?.bar == 102 }
        let result = await h.transport.locate(bar: 98, beat: 1)
        #expect(result.status == .verified)
        #expect(result.after?.position?.bar == 98)
        #expect(await h.host.jogTicks == 4)
    }

    @Test func locateFromMidBarSnapsBack() async {
        let h = await Harness.make()
        await h.host.setPosition(BeatsPosition(bar: 6, beat: 3, division: 4, tick: 137))
        _ = await pollUntil { await h.transport.snapshot().position?.tick == 137 }
        let result = await h.transport.locate(bar: 6, beat: 1)
        #expect(result.status == .verified)
        #expect(await h.host.jogTicks == 1)
    }

    @Test func locateWhenAlreadyThereSendsNothing() async {
        let h = await Harness.make()
        let result = await h.transport.locate(bar: 1, beat: 1)
        #expect(result.status == .verified)
        #expect(await h.host.jogTicks == 0)
    }

    @Test func locateRefusesWhilePlayingAndOtherBeats() async {
        let h = await Harness.make()
        #expect(await h.transport.locate(bar: 5, beat: 2).status == .failed)
        #expect(await h.transport.locate(bar: 1000, beat: 1).status == .failed)
        _ = await h.transport.play()
        let result = await h.transport.locate(bar: 5, beat: 1)
        #expect(result.status == .failed)
        #expect(result.summary.contains("Stop first"))
        #expect(await h.host.jogTicks == 0)
    }

    @Test func locateRefusesWithoutBeatsDisplay() async {
        var behavior = FakeLogicHost.Behavior()
        behavior.beatsDisplay = false
        let h = await Harness.make(behavior)
        let result = await h.transport.locate(bar: 5, beat: 1)
        #expect(result.status == .failed)
        #expect(await h.host.jogTicks == 0)
    }

    @Test func locateReportsNoMovement() async {
        var behavior = FakeLogicHost.Behavior()
        behavior.respondsToButtons = false
        var timeouts = TransportController.Timeouts()
        timeouts.locateStep = .milliseconds(200)
        let h = await Harness.make(behavior, timeouts: timeouts)
        let result = await h.transport.locate(bar: 5, beat: 1)
        #expect(result.status == .failed)
        #expect(await h.host.jogTicks == 1)
    }
}

@Suite("Sync monitor")
struct SyncMonitorTests {
    @Test func tempoFromClockIntervals() async {
        let monitor = SyncMonitor()
        let t0 = ContinuousClock.now
        await monitor.handle(.songPosition(32), at: t0)
        await monitor.handle(.continue, at: t0)
        // 120 BPM → 24 clocks per 0.5 s → 20.8333 ms per clock.
        for i in 0..<48 {
            await monitor.handle(.timingClock, at: t0.advanced(by: .microseconds(20_833) * i))
        }
        let snapshot = await monitor.snapshot()
        #expect(snapshot.running == true)
        #expect(snapshot.tempoBPM == 120.0)
        #expect(snapshot.positionSixteenths == 32 + 48 / 6)
    }

    @Test func stopClearsRunning() async {
        let monitor = SyncMonitor()
        await monitor.handle(.start, at: .now)
        await monitor.handle(.stop, at: .now)
        let snapshot = await monitor.snapshot()
        #expect(snapshot.running == false)
        #expect(snapshot.tempoBPM == nil)
    }
}

/// Polls an async condition for up to one second.
func pollUntil(_ condition: @Sendable () async -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(1))
    while clock.now < deadline {
        if await condition() { return true }
        try? await clock.sleep(for: .milliseconds(5))
    }
    return false
}

@Suite("Safety gates")
struct SafetyTests {
    @Test func probeTrafficAloneIsNotAConnection() async {
        var behavior = FakeLogicHost.Behavior()
        behavior.probeOnly = true
        let h = await Harness.make(behavior, timeouts: shortTimeouts)
        // Logic probed the port (device + firmware queries) but drives no display or LEDs.
        _ = await pollUntil { await h.session.linkStatus().messagesReceived >= 2 }
        let link = await h.session.linkStatus()
        #expect(link.messagesReceived >= 2)
        #expect(link.surfaceActive == false)
        for result in [await h.transport.play(), await h.transport.stop(), await h.transport.record(confirmed: true)] {
            #expect(result.status == .failed)
            #expect(result.summary.contains("only probed"))
        }
        // Nothing but handshake replies reached Logic: no button press that could become a note.
        #expect(await h.host.presses.isEmpty)
    }

    @Test func positionIsNotParsedWhenDisplayModeIsUnknown() async {
        // Logic 12.3 sent both SMPTE and BEATS LEDs off at connect.
        let output = MIDIPipe()
        let session = MCUSession(output: output, limits: .none)
        let input = MIDIPipe()
        await session.start(input: input.stream)
        input.send([
            .noteOn(channel: 0, note: MCUButton.beatsLED.rawValue, velocity: 0),
            .noteOn(channel: 0, note: MCUButton.smpteLED.rawValue, velocity: 0),
            .sysEx([0x00, 0x00, 0x66, 0x14, 0x10, 0x31, 0x20, 0x20, 0x71, 0x20, 0x71, 0x20, 0x75, 0x20, 0x20]),
        ])
        _ = await session.waitUntil(timeout: .seconds(1)) { $0.timecodeRevision > 0 }
        let snapshot = await TransportController(mcu: session, sync: SyncMonitor()).snapshot()
        #expect(snapshot.displayMode == .unknown)
        #expect(snapshot.position == nil)
        #expect(snapshot.display == "  5. 1. 1.  1")
    }

    @Test func secondInstanceLockIsRefused() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("lock-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try InstanceLock(directory: directory)
        #expect(throws: InstanceLockError.self) { _ = try InstanceLock(directory: directory) }
        withExtendedLifetime(first) {}
    }
}
