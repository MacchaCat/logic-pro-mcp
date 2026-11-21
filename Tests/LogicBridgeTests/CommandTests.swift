import CommandMap
import FakeLogic
import Foundation
import Testing
@testable import LogicBridge
import MackieControl
import MIDICore
import Synchronization

func fastCommandTimings() -> CommandTimings {
    var timings = CommandTimings()
    timings.ledTimeout = .milliseconds(250)
    timings.playheadTimeout = .milliseconds(250)
    timings.trackFirstScanDelay = .milliseconds(20)
    timings.trackRescanGap = .milliseconds(20)
    timings.maxTrackScans = 3
    timings.trackDeadline = .seconds(3)
    timings.pollInterval = .milliseconds(2)
    return timings
}

/// FakeLogic with the Mackie Control surface, a mixer controller, and a fake key-command host on
/// an in-memory Keys pipe.
struct CommandHarness {
    let session: MCUSession
    let sync: SyncMonitor
    let host: FakeLogicHost
    let keys: FakeKeyCommandHost
    /// The Keys output: its `sentCount` is final when a call returns, unlike what the fake has
    /// processed so far.
    let keysOut: OutputScheduler
    let mixer: MixerController
    let transport: TransportController
    let controller: CommandController

    enum Names { case fromFake, none }

    static func make(
        tracks: [FakeTrack] = FakeTrack.observedProject,
        names: Names = .fromFake,
        configure: (inout FakeLogicHost.Behavior) -> Void = { _ in },
        keyBehavior: (inout FakeKeyCommandHost.Behavior) -> Void = { _ in },
        limits: RateLimits = .none
    ) async -> CommandHarness {
        var behavior = FakeLogicHost.Behavior()
        behavior.tracks = tracks
        behavior.mixer.overlayDuration = fakeOverlay
        configure(&behavior)
        let surfaceToHost = MIDIPipe(), hostToSurface = MIDIPipe(), hostToSync = MIDIPipe(), keysPipe = MIDIPipe()
        let session = MCUSession(output: surfaceToHost, limits: .none)
        await session.start(input: hostToSurface.stream)
        let sync = SyncMonitor()
        await sync.start(input: hostToSync.stream)
        let host = FakeLogicHost(behavior: behavior, toSurface: hostToSurface, toSync: hostToSync)
        await host.connect(surfaceInput: surfaceToHost.stream)
        var keyHostBehavior = FakeKeyCommandHost.Behavior()
        keyBehavior(&keyHostBehavior)
        let keys = await FakeKeyCommandHost.attach(host: host, surface: hostToSurface, keys: keysPipe.stream, behavior: keyHostBehavior)
        _ = await session.waitUntil(timeout: .seconds(2)) { $0.lcdRevision > 0 && $0.timecodeRevision > 0 }
        if keyHostBehavior.reportsLEDs {
            _ = await session.waitUntil(timeout: .seconds(2)) { $0.led(.cycle) != nil && $0.led(.click) != nil }
        }
        let source: (any TrackNameSource)? = names == .fromFake
            ? ClosureTrackNameSource { TrackNameList(names: await host.trackNames) } : nil
        let mixer = MixerController(mcu: session, sync: sync, names: source, timings: fastTimings())
        let keysOut = OutputScheduler(output: keysPipe)
        let controller = CommandController(
            mcu: session, sync: sync, mixer: mixer, keys: keysOut,
            limits: limits, timings: fastCommandTimings())
        return CommandHarness(session: session, sync: sync, host: host, keys: keys, keysOut: keysOut, mixer: mixer,
                              transport: TransportController(mcu: session, sync: sync), controller: controller)
    }

    /// Moves the fake's playhead and waits until the surface shows it.
    func setPosition(_ position: BeatsPosition) async {
        await host.setPosition(position)
        _ = await session.waitUntil(timeout: .seconds(1)) { $0.beatsPosition == position }
    }

    /// What the fake received, once it has received everything the controller sent.
    func delivered() async -> [MIDIMessage] {
        let sent = await keysOut.sentCount
        let keys = self.keys
        _ = await pollUntil { await keys.received.count >= sent }
        return await keys.received
    }

    /// The commands the fake ran, once it has handled everything the controller sent.
    func executed() async -> [String] {
        _ = await delivered()
        let keys = self.keys
        let handled = await keys.received.count
        _ = await pollUntil { await keys.executed.count + keys.passedThrough.count >= handled }
        return await keys.executed
    }
}

func bar(_ bar: Int, _ beat: Int = 1, _ division: Int = 1, _ tick: Int = 1) -> BeatsPosition {
    BeatsPosition(bar: bar, beat: beat, division: division, tick: tick)
}

@Suite("Key commands: track count")
struct CommandTrackCountTests {
    @Test func newAudioTrackIsVerifiedByTheTrackCount() async {
        let h = await CommandHarness.make()
        let result = await h.controller.run(.newAudioTrack, confirmed: false)
        #expect(result.status == .verified, "\(result.summary) \(result.warnings)")
        #expect(result.before?.trackCount == 11)
        #expect(result.after?.trackCount == 12)
        #expect(result.after?.trackNames?.last == "オーディオ 12")
        #expect(await h.executed() == ["new-audio-track"])
        #expect(await h.delivered() == [LogicCommand.newAudioTrack.message])
        #expect(result.evidence.contains { $0.contains("BF 1A 7F") })
    }

    @Test func instrumentAndDuplicateTracks() async {
        let h = await CommandHarness.make(tracks: names(3))
        let instrument = await h.controller.run(.newSoftwareInstrumentTrack, confirmed: false)
        #expect(instrument.status == .verified, "\(instrument.summary)")
        #expect(instrument.after?.trackNames == ["Trk1", "Trk2", "Trk3", "Inst 4"])
        let duplicate = await h.controller.run(.duplicateTrack, confirmed: false)
        #expect(duplicate.status == .verified, "\(duplicate.summary)")
        #expect(duplicate.after?.trackNames == ["Trk1", "Trk2", "Trk3", "Inst 4", "Inst 4"])
    }

    @Test func deleteTrackNeedsConfirmationThenIsVerified() async {
        let h = await CommandHarness.make()
        let pending = await h.controller.run(.deleteTrack, confirmed: false)
        #expect(pending.status == .needsConfirmation)
        #expect(pending.summary.contains("selected"))
        #expect(await h.delivered().isEmpty)
        #expect(await h.host.tracks.count == 11)
        // A confirmation request is not a run.
        #expect(await h.controller.lastRuns["delete-track"] == nil)

        let result = await h.controller.run(.deleteTrack, confirmed: true)
        #expect(result.status == .verified, "\(result.summary)")
        #expect(result.before?.trackCount == 11)
        #expect(result.after?.trackCount == 10)
        #expect(await h.host.trackNames.last == "オーディオ 8")
        #expect(await h.controller.lastRuns["delete-track"]?.status == "verified")
    }

    @Test func notLearnedFailsAfterRescanning() async {
        let h = await CommandHarness.make(tracks: names(4)) { _ in } keyBehavior: { $0.unlearn(["new-audio-track"]) }
        let result = await h.controller.run(.newAudioTrack, confirmed: false)
        #expect(result.status == .failed)
        #expect(result.summary.contains("stayed at 4"))
        #expect(result.summary.contains("3 scans"))
        #expect(result.warnings.first?.contains("not been learned") == true)
        // It may have run where the surface does not show it: no blind retry.
        #expect(result.warnings.contains { $0.contains("collapsed folder") && $0.contains("creates another track") })
        #expect(await h.delivered().count == 1)
        #expect(await h.keys.passedThrough == [LogicCommand.newAudioTrack.message])
        #expect(await h.controller.lastRuns["new-audio-track"]?.status == "failed")
    }

    @Test func noScanStartsAfterTheDeadline() {
        var timings = CommandTimings()
        timings.maxTrackScans = 3
        timings.trackRescanGap = .milliseconds(300)
        timings.trackDeadline = .seconds(8)
        #expect(CommandController.startsAnotherScan(after: 1, elapsed: .seconds(4), timings: timings))
        #expect(CommandController.startsAnotherScan(after: 2, elapsed: .milliseconds(7700), timings: timings))
        // 11 tracks: the second scan ends at about 7.8 s; a third would start at 8.1 s.
        #expect(!CommandController.startsAnotherScan(after: 2, elapsed: .milliseconds(7800), timings: timings))
        #expect(!CommandController.startsAnotherScan(after: 1, elapsed: .seconds(8), timings: timings))
        #expect(!CommandController.startsAnotherScan(after: 3, elapsed: .seconds(1), timings: timings))
    }

    @Test func lateScansAreSkipped() async {
        // The deadline is shorter than the first scan delay plus one gap: one scan only.
        var timings = fastCommandTimings()
        timings.maxTrackScans = 10
        timings.trackDeadline = .milliseconds(30)
        let h = await CommandHarness.make(tracks: names(3)) { _ in } keyBehavior: { $0.unlearn(["new-audio-track"]) }
        let controller = CommandController(mcu: h.session, sync: h.sync, mixer: h.mixer, keys: h.keysOut,
                                           limits: .none, timings: timings)
        let result = await controller.run(.newAudioTrack, confirmed: false)
        #expect(result.status == .failed)
        #expect(result.summary.contains("(1 scans"), "\(result.summary)")
    }

    @Test func slowRedrawIsFoundByRescanning() async {
        // Logic adds the track only after the first scan has started.
        let h = await CommandHarness.make(tracks: names(4)) { _ in } keyBehavior: { $0.effectDelay = .milliseconds(120) }
        let result = await h.controller.run(.newAudioTrack, confirmed: false)
        #expect(result.status == .verified, "\(result.summary) \(result.evidence)")
        #expect(result.after?.trackCount == 5)
    }

    @Test func learnedForAnotherCommandIsCaught() async {
        // CC 26 (New Audio Track) was learned for Delete Track by mistake.
        let h = await CommandHarness.make(tracks: names(4)) { _ in } keyBehavior: { $0.assignments[26] = "delete-track" }
        let result = await h.controller.run(.newAudioTrack, confirmed: false)
        #expect(result.status == .failed)
        #expect(result.summary.contains("from 4 to 3"))
        #expect(result.summary.contains("opposite"))
    }

    @Test func outcomeTable() {
        typealias O = CommandController.TrackCountOutcome
        #expect(CommandController.trackCountOutcome(change: 1, from: 4, to: 5, confirmed: true) == O.expected)
        #expect(CommandController.trackCountOutcome(change: -1, from: 4, to: 3, confirmed: true) == O.expected)
        #expect(CommandController.trackCountOutcome(change: 1, from: 4, to: 4, confirmed: true) == O.unchanged)
        #expect(CommandController.trackCountOutcome(change: -1, from: 4, to: 2, confirmed: true) == O.otherAmount)
        #expect(CommandController.trackCountOutcome(change: 1, from: 4, to: 3, confirmed: true) == O.opposite)
        #expect(CommandController.trackCountOutcome(change: 1, from: 4, to: 5, confirmed: false) == O.notConfirmed)
        #expect(CommandController.trackCountOutcome(change: 1, from: 4, to: 4, confirmed: false) == O.notConfirmed)
    }

    @Test func unreadableTrackListSendsNothing() async {
        // Flip mode on: the mixer refuses to scan, so the effect could not be checked.
        let h = await CommandHarness.make(tracks: names(4)) { $0.mixer.flipOn = true }
        let result = await h.controller.run(.newAudioTrack, confirmed: false)
        #expect(result.status == .failed)
        #expect(result.summary.contains("Nothing was sent"))
        #expect(await h.delivered().isEmpty)
    }

    @Test func trackCommandsDropTheMixerCache() async {
        // Without full names, a cached scan is reused while the surface shows one of its pages.
        let h = await CommandHarness.make(names: .none)
        #expect(await h.mixer.tracks(refresh: true).after?.trackCount == 11)
        // Tracks removed at the end in Logic: the first page still looks the same.
        await h.host.setTracks(Array(FakeTrack.observedProject.prefix(10)))
        _ = await h.session.waitUntil(timeout: .milliseconds(200)) { _ in false }
        #expect(await h.mixer.tracks(refresh: false).after?.trackCount == 11)  // stale, as designed
        // Undo may change the track list: the cache must not survive it.
        let undo = await h.controller.run(.undo, confirmed: false)
        #expect(undo.status == .unverified)
        #expect(await h.mixer.tracks(refresh: false).after?.trackCount == 10)
    }

    /// Any trigger may run a track command in Logic (a CC learned for a different command, or a
    /// learn trigger when learn mode was not armed), so every send drops the cache.
    @Test func everyTriggerDropsTheMixerCache() async {
        let h = await CommandHarness.make(names: .none)
        typealias Send = @Sendable (CommandController) async -> Void
        let sends: [(String, Send)] = [
            ("run toggle-cycle", { _ = await $0.run(.toggleCycle, confirmed: false) }),
            ("learn create-marker", { _ = await $0.learn(.createMarker, confirmed: false) }),
            ("trigger redo", { _ = await $0.trigger(.redo, confirmed: false) }),
        ]
        var count = 11
        for (label, send) in sends {
            #expect(await h.mixer.tracks(refresh: true).after?.trackCount == count, "\(label)")
            // Tracks removed at the end in Logic: the first page still looks the same, so
            // without full names only a dropped cache notices.
            count -= 1
            await h.host.setTracks(Array(FakeTrack.observedProject.prefix(count)))
            #expect(await h.mixer.tracks(refresh: false).after?.trackCount == count + 1, "\(label): stale, as designed")
            await send(h.controller)
            #expect(await h.mixer.tracks(refresh: false).after?.trackCount == count, "\(label)")
        }
    }
}

@Suite("Key commands: LEDs")
struct CommandLEDTests {
    @Test func cycleToggleIsVerifiedByTheLED() async {
        let h = await CommandHarness.make(tracks: names(3))
        let on = await h.controller.run(.toggleCycle, confirmed: false)
        #expect(on.status == .verified, "\(on.summary)")
        #expect(on.before?.cycle == false)
        #expect(on.after?.cycle == true)
        let off = await h.controller.run(.toggleCycle, confirmed: false)
        #expect(off.status == .verified)
        #expect(off.after?.cycle == false)
    }

    @Test func metronomeToggleIsVerifiedByTheClickLED() async {
        // Logic 13 reported Click on at connect.
        let h = await CommandHarness.make(tracks: names(3))
        let result = await h.controller.run(.toggleMetronome, confirmed: false)
        #expect(result.status == .verified)
        #expect(result.before?.click == true)
        #expect(result.after?.click == false)
    }

    /// That the LEDs follow key commands is not confirmed on Logic 13: an unchanged LED may mean
    /// the toggle ran anyway, so "failed" (which invites a retry that toggles back) is wrong.
    @Test func unchangedLEDIsUnverifiedUntilSeenFollowing() async {
        let h = await CommandHarness.make(tracks: names(3)) { _ in } keyBehavior: { $0.assignments = [:] }
        let result = await h.controller.run(.toggleCycle, confirmed: false)
        #expect(result.status == .unverified)
        #expect(result.summary.contains("stayed off"))
        #expect(result.warnings.first?.contains("not yet confirmed on Logic 13") == true)
        #expect(result.warnings.first?.contains("before running toggle-cycle again") == true)
        #expect(await h.controller.lastRuns["toggle-cycle"]?.status == "unverified")
    }

    @Test func unchangedLEDFailsOnceItFollowedARun() async {
        let h = await CommandHarness.make(tracks: names(3))
        #expect(await h.controller.run(.toggleCycle, confirmed: false).status == .verified)
        await h.keys.setAssignments([:])
        let cycle = await h.controller.run(.toggleCycle, confirmed: false)
        #expect(cycle.status == .failed, "\(cycle.summary)")
        #expect(cycle.summary.contains("stayed on"))
        #expect(cycle.warnings.first?.contains("not been learned") == true)
        // Only the LED that was seen following: Click is still unproven.
        let click = await h.controller.run(.toggleMetronome, confirmed: false)
        #expect(click.status == .unverified)
    }

    @Test func unreportedLEDIsUnverified() async {
        // Since Phase 4 FakeLogicHost reports the Cycle LED at connect too (transport model).
        let h = await CommandHarness.make(tracks: names(3)) { $0.reportsCycleLED = false } keyBehavior: { $0.reportsLEDs = false }
        let result = await h.controller.run(.toggleCycle, confirmed: false)
        #expect(result.status == .unverified)
        #expect(result.summary.contains("had not reported the Cycle LED"))
        #expect(await h.executed() == ["toggle-cycle"])
    }
}

@Suite("Key commands: playhead")
struct CommandPlayheadTests {
    @Test func goToBeginning() async {
        let h = await CommandHarness.make(tracks: names(3))
        await h.setPosition(bar(9, 2, 3, 40))
        let result = await h.controller.run(.goToBeginning, confirmed: false)
        #expect(result.status == .verified, "\(result.summary)")
        #expect(result.before?.position == bar(9, 2, 3, 40))
        #expect(result.after?.position == bar(1))
    }

    @Test func alreadyAtTheBeginningSendsNothing() async {
        let h = await CommandHarness.make(tracks: names(3))
        for command in [LogicCommand.goToBeginning, .rewindOneBar] {
            let result = await h.controller.run(command, confirmed: false)
            #expect(result.status == .verified)
            #expect(result.summary.contains("nothing sent"))
            #expect(result.warnings.contains { $0.contains("does not show whether \(command.englishName) is learned") })
        }
        #expect(await h.delivered().isEmpty)
    }

    /// Nothing learned, playhead at 1 1 1 1: the short-cut must not make list_commands present
    /// go-to-beginning as working.
    @Test func shortCutIsNotALearnedRun() async {
        let h = await CommandHarness.make(tracks: names(3)) { _ in } keyBehavior: { $0.assignments = [:] }
        #expect(await h.controller.run(.goToBeginning, confirmed: false).status == .verified)
        #expect(await h.controller.run(.rewindOneBar, confirmed: false).status == .verified)
        #expect(await h.controller.lastRuns.isEmpty)
        #expect(await h.delivered().isEmpty)
    }

    @Test func aNothingSentRunKeepsTheEarlierRecord() async {
        let h = await CommandHarness.make(tracks: names(3))
        await h.setPosition(bar(5))
        #expect(await h.controller.run(.goToBeginning, confirmed: false).status == .verified)
        let record = await h.controller.lastRuns["go-to-beginning"]
        #expect(record?.status == "verified")
        #expect(record?.summary.contains("moved from 5.1.1.1") == true)
        // Now at 1 1 1 1: nothing is sent, and the record of the real run stays.
        let shortCut = await h.controller.run(.goToBeginning, confirmed: false)
        #expect(shortCut.summary.contains("nothing sent"))
        #expect(await h.controller.lastRuns["go-to-beginning"] == record)
        #expect(await h.delivered() == [LogicCommand.goToBeginning.message])
    }

    @Test func forwardAndRewind() async {
        let h = await CommandHarness.make(tracks: names(3))
        await h.setPosition(bar(5))
        let forward = await h.controller.run(.forwardOneBar, confirmed: false)
        #expect(forward.status == .verified, "\(forward.summary)")
        #expect(forward.after?.position == bar(6))
        let rewind = await h.controller.run(.rewindOneBar, confirmed: false)
        #expect(rewind.status == .verified)
        #expect(rewind.after?.position == bar(5))
        // From inside a bar, back to its start.
        await h.setPosition(bar(6, 3, 4, 137))
        let snap = await h.controller.run(.rewindOneBar, confirmed: false)
        #expect(snap.status == .verified, "\(snap.summary)")
        #expect(snap.after?.position == bar(6))
    }

    @Test func notLearnedFails() async {
        let h = await CommandHarness.make(tracks: names(3)) { _ in } keyBehavior: { $0.assignments = [:] }
        await h.setPosition(bar(5))
        let result = await h.controller.run(.forwardOneBar, confirmed: false)
        #expect(result.status == .failed)
        #expect(result.summary.contains("stayed at 5.1.1.1"))
    }

    @Test func wrongMoveFails() async {
        // CC 22 (Forward) learned for Go to Beginning.
        let h = await CommandHarness.make(tracks: names(3)) { _ in } keyBehavior: { $0.assignments[22] = "go-to-beginning" }
        await h.setPosition(bar(5))
        let result = await h.controller.run(.forwardOneBar, confirmed: false)
        #expect(result.status == .failed)
        #expect(result.summary.contains("from 5.1.1.1 to 1.1.1.1"))
    }

    @Test func whilePlayingIsUnverified() async {
        let h = await CommandHarness.make(tracks: names(3))
        await h.setPosition(bar(5))
        #expect(await h.transport.play().status == .verified)
        let result = await h.controller.run(.goToBeginning, confirmed: false)
        #expect(result.status == .unverified)
        #expect(result.summary.contains("playing"))
        #expect(await h.delivered() == [LogicCommand.goToBeginning.message])
    }
}

@Suite("Key commands: safety")
struct CommandSafetyTests {
    @Test func nothingIsSentWhileRecording() async {
        let h = await CommandHarness.make(tracks: names(3))
        #expect(await h.transport.record(confirmed: false).status == .verified)
        for command in CommandCatalog.all {
            let result = await h.controller.run(command, confirmed: true)
            #expect(result.status == .failed, "\(command.id)")
            #expect(result.summary.contains("Nothing was sent"), "\(command.id)")
            let learn = await h.controller.learn(command, confirmed: true)
            #expect(learn.status == .failed, "\(command.id)")
            let trigger = await h.controller.trigger(command, confirmed: true)
            #expect(trigger.status == .failed, "\(command.id)")
            #expect(trigger.summary.contains("Nothing was sent"), "\(command.id)")
        }
        #expect(await h.delivered().isEmpty)
        // Refusals are not runs: list_commands must not read them as "not learned".
        #expect(await h.controller.lastRuns.isEmpty)
    }

    @Test func unknownRecordStateRefusesRuns() async {
        let h = await CommandHarness.make(tracks: names(3)) { $0.transportLEDs = false }
        let result = await h.controller.run(.undo, confirmed: false)
        #expect(result.status == .failed)
        #expect(result.summary.contains("cannot be confirmed that Logic is not recording"))
        #expect(await h.delivered().isEmpty)
        #expect(await h.controller.lastRuns.isEmpty)
        // Learning and raw triggers (setup, diagnostics) still send, with a warning.
        let learn = await h.controller.learn(.undo, confirmed: false)
        #expect(learn.status == .unverified)
        #expect(learn.warnings.contains { $0.contains("could not be checked that Logic was not recording") })
        let trigger = await h.controller.trigger(.redo, confirmed: false)
        #expect(trigger.status == .unverified)
        #expect(trigger.warnings.contains { $0.contains("could not be checked that Logic was not recording") })
        #expect(await h.delivered() == [LogicCommand.undo.message, LogicCommand.redo.message])
        #expect(await h.controller.lastRuns.isEmpty)
    }

    @Test func goToPositionIsNotRunnable() async {
        let h = await CommandHarness.make(tracks: names(3))
        let result = await h.controller.run(.goToPosition, confirmed: true)
        #expect(result.status == .failed)
        #expect(result.summary.contains("locate"))
        #expect(await h.delivered().isEmpty)
        #expect(await h.controller.lastRuns["go-to-position"] == nil)
    }

    @Test func triggerSendsOnceWithoutChecking() async {
        let h = await CommandHarness.make(tracks: names(3))
        let pending = await h.controller.trigger(.save, confirmed: false)
        #expect(pending.status == .needsConfirmation)
        #expect(await h.delivered().isEmpty)
        let sent = await h.controller.trigger(.save, confirmed: true)
        #expect(sent.status == .unverified)
        #expect(sent.warnings.isEmpty)
        // go-to-position is not runnable, but a raw trigger may send it (checklist B9).
        #expect(await h.controller.trigger(.goToPosition, confirmed: false).status == .unverified)
        #expect(await h.delivered() == [LogicCommand.save.message, LogicCommand.goToPosition.message])
        #expect(await h.controller.lastRuns.isEmpty)
    }

    @Test func commandsWithoutFeedbackAreUnverified() async {
        let h = await CommandHarness.make(tracks: names(3))
        for command in [LogicCommand.undo, .redo, .selectAll, .createMarker, .toggleCountIn] {
            let result = await h.controller.run(command, confirmed: false)
            #expect(result.status == .unverified, "\(command.id)")
        }
        let save = await h.controller.run(.save, confirmed: false)
        #expect(save.status == .needsConfirmation)
        let saved = await h.controller.run(.save, confirmed: true)
        #expect(saved.status == .unverified)
        #expect(saved.warnings.contains { $0.contains("Save dialog") })
        #expect(await h.executed() == ["undo", "redo", "select-all", "create-marker", "toggle-count-in", "save"])
    }

    /// With nothing learned, no command may claim success (except "nothing to do" short-cuts,
    /// which send nothing).
    @Test func nothingLearnedNeverVerifies() async {
        let h = await CommandHarness.make(tracks: names(3)) { _ in } keyBehavior: { $0.assignments = [:] }
        await h.setPosition(bar(5))
        for command in CommandCatalog.all {
            let result = await h.controller.run(command, confirmed: true)
            #expect(result.status != .verified, "\(command.id): \(result.summary)")
        }
        #expect(await h.executed().isEmpty)
        #expect(await h.host.tracks.count == 3)
    }

    /// With everything learned, every command that can be verified is verified.
    @Test func everythingLearnedVerifies() async {
        let h = await CommandHarness.make(tracks: names(3))
        await h.setPosition(bar(5))
        for command in CommandCatalog.all where command.verification.canVerify {
            let result = await h.controller.run(command, confirmed: true)
            #expect(result.status == .verified, "\(command.id): \(result.summary) \(result.warnings)")
        }
    }

    @Test func runsAreSerialised() async {
        let h = await CommandHarness.make(tracks: names(3))
        let controller = h.controller
        async let first = controller.run(.toggleCycle, confirmed: false)
        async let second = controller.run(.toggleCycle, confirmed: false)
        let results = await [first, second]
        // Each run saw the LED change it caused: on, then off again.
        #expect(results.allSatisfy { $0.status == .verified })
        #expect(Set(results.compactMap { $0.after?.cycle }) == [true, false])
        #expect(await h.session.surface.led(.cycle) == .off)
    }

    @Test func keyCommandsAreRateLimited() async {
        let pipe = MIDIPipe()
        let scheduler = OutputScheduler(output: pipe)
        var limits = RateLimits.none
        limits.keyCommandGap = .milliseconds(80)
        let clock = ContinuousClock()
        let start = clock.now
        await scheduler.sendKeyCommand(.undo, limits: limits)
        await scheduler.sendKeyCommand(.redo, limits: limits)
        #expect(start.duration(to: clock.now) >= .milliseconds(80))
        #expect(await scheduler.sentCount == 2)
    }

    /// The scheduler actor is reentrant at its sleep: overlapping callers must still keep the gap
    /// (two waiting callers used to wake at the same due time and send back to back).
    @Test func overlappingCallersKeepTheGap() async {
        let output = TimestampedOutput()
        let scheduler = OutputScheduler(output: output)
        let limits = {
            var limits = RateLimits.none
            limits.keyCommandGap = .milliseconds(40)
            return limits
        }()
        await withTaskGroup(of: Void.self) { group in
            for command in [LogicCommand.undo, .redo, .selectAll, .createMarker] {
                group.addTask { await scheduler.sendKeyCommand(command, limits: limits) }
            }
        }
        let times = output.sent.map(\.at)
        #expect(times.count == 4)
        for (earlier, later) in zip(times, times.dropFirst()) {
            #expect(earlier.duration(to: later) >= .milliseconds(40))
        }
    }

    @Test func overlappingBatchesDoNotInterleave() async {
        let output = TimestampedOutput()
        let scheduler = OutputScheduler(output: output)
        var limits = RateLimits.none
        limits.shortMessageGap = .milliseconds(5)
        let first = (0..<4).map { MIDIMessage.controlChange(channel: 0, controller: 20, value: UInt8($0)) }
        let second = (0..<4).map { MIDIMessage.controlChange(channel: 1, controller: 20, value: UInt8($0)) }
        async let a: Void = scheduler.send(first, limits: limits)
        async let b: Void = scheduler.send(second, limits: limits)
        _ = await (a, b)
        let sent = output.sent.map(\.message)
        #expect(sent == first + second || sent == second + first)
    }
}

/// Records each message with the time it was handed to the output.
final class TimestampedOutput: MIDIOutput {
    private let log = Mutex<[(message: MIDIMessage, at: ContinuousClock.Instant)]>([])

    func send(_ messages: [MIDIMessage]) {
        let now = ContinuousClock.now
        log.withLock { log in log.append(contentsOf: messages.map { ($0, now) }) }
    }

    var sent: [(message: MIDIMessage, at: ContinuousClock.Instant)] { log.withLock { $0 } }
}

@Suite("Key commands: learn")
struct CommandLearnTests {
    @Test func learnSendsOneTriggerAndNothingOnTheSurface() async {
        let h = await CommandHarness.make(tracks: names(3)) { _ in } keyBehavior: { $0.assignments = [:] }
        let sentBefore = await h.session.linkStatus().messagesSent
        let result = await h.controller.learn(.newAudioTrack, confirmed: false)
        #expect(result.status == .unverified)
        #expect(await h.delivered() == [LogicCommand.newAudioTrack.message])
        #expect(await h.session.linkStatus().messagesSent == sentBefore)
        #expect(await h.host.presses.isEmpty)
        let report = result.after
        #expect(report?.controller == 26)
        #expect(report?.channel == 16)
        #expect(report?.message == "BF 1A 7F")
        #expect(report?.japaneseName == "新規オーディオトラック")
        #expect(report?.check.first?.contains("CC 26 (127)") == true)
        let steps = report?.steps.joined(separator: "\n") ?? ""
        #expect(steps.contains("Logic Pro > Key Commands > Edit Assignments…"))
        #expect(steps.contains("Learn New Assignment"))
        #expect(steps.contains("learn_command (command: new-audio-track)"))
    }

    @Test func refusalsAndConfirmationsCarryTheSteps() async {
        let h = await CommandHarness.make(tracks: names(3))
        let pending = await h.controller.learn(.save, confirmed: false)
        #expect(pending.after?.steps.contains { $0.contains("Key Commands > Edit Assignments…") } == true)
        #expect(await h.transport.record(confirmed: false).status == .verified)
        let refused = await h.controller.learn(.undo, confirmed: false)
        #expect(refused.status == .failed)
        #expect(refused.after?.steps.isEmpty == false)
        #expect(await h.delivered().isEmpty)
    }

    @Test func destructiveLearnNeedsConfirmation() async {
        let h = await CommandHarness.make(tracks: names(3))
        let pending = await h.controller.learn(.deleteTrack, confirmed: false)
        #expect(pending.status == .needsConfirmation)
        #expect(pending.summary.contains("already learned"))
        #expect(await h.delivered().isEmpty)
        let sent = await h.controller.learn(.deleteTrack, confirmed: true)
        #expect(sent.status == .unverified)
        #expect(await h.delivered() == [LogicCommand.deleteTrack.message])
    }

    @Test func goToPositionCanBeLearned() async {
        let h = await CommandHarness.make(tracks: names(3)) { _ in } keyBehavior: { $0.assignments = [:] }
        let result = await h.controller.learn(.goToPosition, confirmed: false)
        #expect(result.status == .unverified)
        #expect(result.after?.japaneseName == "位置を指定して移動…")
        #expect(await h.delivered() == [LogicCommand.goToPosition.message])
        // If learn mode was not armed, Logic opened the dialog that run_command avoids.
        #expect(result.warnings.first?.contains("opened its dialog") == true)
        #expect(result.warnings.first?.contains("before using any other Logic tool") == true)
        #expect(result.after?.check.contains { $0.contains("Cancel") && $0.contains("Go to Position…") } == true)
        // Other commands keep the generic warning.
        let undo = await h.controller.learn(.undo, confirmed: false)
        #expect(undo.warnings.first?.hasSuffix("Logic ran Undo.") == true)
        #expect(undo.after?.check.contains { $0.contains("dialog (") } == false)
    }
}
