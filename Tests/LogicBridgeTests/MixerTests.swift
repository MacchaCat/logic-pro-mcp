import FakeLogic
import Foundation
import Testing
@testable import LogicBridge
import MackieControl
import MIDICore

/// Controller timings scaled for the in-memory fake (whose overlays last `fakeOverlay`).
let fakeOverlay: Duration = .milliseconds(250)

func fastTimings() -> MixerTimings {
    var timings = MixerTimings()
    timings.moveTimeout = .milliseconds(150)
    timings.settleQuiet = .milliseconds(15)
    timings.settleTimeout = .milliseconds(500)
    timings.overlayHold = .milliseconds(400)
    timings.faderTimeout = .milliseconds(250)
    timings.faderFollowUp = .milliseconds(40)
    timings.vPotStepTimeout = .milliseconds(250)
    timings.ledTimeout = .milliseconds(250)
    timings.pollInterval = .milliseconds(2)
    timings.identicalRunProbe = 16
    timings.recordArmWindow = .milliseconds(160)
    return timings
}

struct MixerHarness {
    let base: Harness
    let mixer: MixerController
    var host: FakeLogicHost { base.host }
    var session: MCUSession { base.session }

    enum Names { case fromFake, none, fixed([String]) }

    static func make(
        tracks: [FakeTrack] = FakeTrack.observedProject,
        names: Names = .fromFake,
        configure: (inout FakeLogicHost.Behavior) -> Void = { _ in }
    ) async -> MixerHarness {
        var behavior = FakeLogicHost.Behavior()
        behavior.tracks = tracks
        behavior.mixer.overlayDuration = fakeOverlay
        // Armed tracks' Rec LEDs blink (Logic 13: 0.73 s); faster here, within recordArmWindow.
        behavior.mixer.recArmBlinkHalfPeriod = .milliseconds(60)
        configure(&behavior)
        let base = await Harness.make(behavior)
        let host = base.host
        let source: (any TrackNameSource)?
        switch names {
        case .fromFake: source = ClosureTrackNameSource { TrackNameList(names: await host.trackNames) }
        case .none: source = nil
        case .fixed(let list): source = ClosureTrackNameSource { TrackNameList(names: list) }
        }
        let mixer = MixerController(mcu: base.session, sync: base.sync, names: source, timings: fastTimings())
        return MixerHarness(base: base, mixer: mixer)
    }

    /// Presses a surface button directly (to set up a starting position).
    func press(_ button: MCUButton) async {
        await session.press(button)
        _ = await session.waitUntil(timeout: .milliseconds(50)) { _ in false }
    }

    func selectPresses() async -> [UInt8] {
        await host.presses.filter { (0x18...0x1F).contains($0) }
    }
}

func names(_ count: Int, prefix: String = "Trk") -> [FakeTrack] {
    (1...count).map { FakeTrack("\(prefix)\($0)") }
}

@Suite("Track scan against FakeLogic")
struct TrackScanTests {
    @Test func observedProjectFromChannelView() async {
        let h = await MixerHarness.make()
        let result = await h.mixer.tracks(refresh: true)
        #expect(result.status == .verified)
        let tracks = result.after?.tracks ?? []
        #expect(result.after?.trackCount == 11)
        #expect(tracks.map(\.name) == FakeTrack.observedProject.map(\.name))
        #expect(tracks.map(\.lcdName) == ["Inst 1", "Inst 2"] + (1...9).map(String.init))
        #expect(tracks.allSatisfy { $0.nameSource == .accessibility })
        #expect(tracks.allSatisfy { $0.pan == 0 && $0.volumeDb == .db(0) && $0.faderPosition == 12443 })
        #expect(tracks.allSatisfy { $0.mute == false && $0.solo == false })
        #expect(result.warnings.contains { $0.contains("multi-track Pan view") })
        // Pan pressed exactly once; never Select; Name/Value untouched.
        let presses = await h.host.presses
        #expect(presses.filter { $0 == MCUButton.assignPan.rawValue }.count == 1)
        #expect(!presses.contains(MCUButton.nameValue.rawValue))
        #expect(await h.selectPresses().isEmpty)
        #expect(await h.host.mixer.channelView == false)
        #expect(await h.host.mixer.offset == 0)
    }

    @Test(arguments: [FakeMixerBehavior.LastPage.observed, .rightAligned])
    func bothEndRules(rule: FakeMixerBehavior.LastPage) async {
        for count in [3, 7, 8, 9, 11, 20] {
            let h = await MixerHarness.make(tracks: names(count)) { $0.mixer.lastPage = rule }
            let result = await h.mixer.tracks(refresh: true)
            #expect(result.status == .verified, "count \(count)")
            #expect(result.after?.trackCount == count, "count \(count) rule \(rule)")
            #expect(result.after?.tracks.map(\.name) == (1...count).map { "Trk\($0)" })
        }
    }

    @Test func nameModeIsSwitchedToValues() async {
        let h = await MixerHarness.make(tracks: names(5)) {
            $0.mixer.startInChannelView = false
            $0.mixer.startShowingNames = true
        }
        let result = await h.mixer.tracks(refresh: true)
        #expect(result.status == .verified)
        #expect(result.after?.tracks.allSatisfy { $0.pan == 0 } == true)
        // Once to switch to values; twice more to confirm Logic is responding (the five tracks
        // fit on the first page, so no page move can show it).
        #expect(await h.host.presses.filter { $0 == MCUButton.nameValue.rawValue }.count == 3)
        #expect(await h.host.mixer.showValues)
        #expect(!(await h.host.presses).contains(MCUButton.assignPan.rawValue))
    }

    @Test func originalBankPositionIsRestored() async {
        let h = await MixerHarness.make(tracks: names(20)) { $0.mixer.startInChannelView = false }
        for _ in 0..<5 { await h.press(.channelRight) }
        #expect(await h.host.mixer.offset == 5)
        let result = await h.mixer.tracks(refresh: true)
        #expect(result.after?.trackCount == 20)
        #expect(await h.host.mixer.offset == 5)
        #expect(!result.warnings.contains { $0.contains("original bank position") })
    }

    @Test func valuesAndPartialAccessibility() async {
        var tracks = names(12)
        tracks[2].pan = -20
        tracks[9].pan = 35
        tracks[9].mute = true
        tracks[10].recArm = true
        tracks[4].fader = 8178
        tracks[5].fader = 0
        let h = await MixerHarness.make(tracks: tracks, names: .fixed(["Trk3", "Trk4", "Trk5"])) {
            $0.mixer.startInChannelView = false
        }
        let result = await h.mixer.tracks(refresh: true)
        let info = result.after?.tracks ?? []
        #expect(info.count == 12)
        #expect(info[2].pan == -20)
        #expect(info[9].pan == 35 && info[9].mute == true)
        #expect(info[4].volumeDb == .db(-9.0))
        #expect(info[5].volumeDb == .minusInfinity)
        #expect(info.map(\.nameSource) == [.lcd, .lcd, .accessibility, .accessibility, .accessibility] + Array(repeating: .lcd, count: 7))
        #expect(result.warnings.contains { $0.contains("matched them to tracks 3–5") })
    }

    @Test func withoutAccessibilityNamesComeFromTheLCD() async {
        let h = await MixerHarness.make(names: .none)
        let result = await h.mixer.tracks(refresh: true)
        #expect(result.after?.tracks.map(\.name) == ["Inst 1", "Inst 2"] + (1...9).map(String.init))
        #expect(result.after?.tracks.allSatisfy { $0.nameSource == .lcd } == true)
        #expect(result.warnings.contains { $0.contains("Full track names unavailable") })
    }

    @Test func nonASCIIOnlyNamesInTheMiddleAreCounted() async {
        let tracks = [FakeTrack("Kick"), FakeTrack("ボーカル"), FakeTrack("Snare")]
        let h = await MixerHarness.make(tracks: tracks)
        let result = await h.mixer.tracks(refresh: true)
        #expect(result.after?.trackCount == 3)
        #expect(result.after?.tracks.map(\.lcdName) == ["Kick", "", "Snare"])
        #expect(result.after?.tracks[1].name == "ボーカル")
    }

    @Test func identicalStripsAtTheEndAreReportedAsUnverified() async {
        // Right-aligned last page: a run of identical strips at the end never shows a change.
        let tracks = Array(repeating: FakeTrack("Audio"), count: 12)
        let h = await MixerHarness.make(tracks: tracks, names: .none) {
            $0.mixer.lastPage = .rightAligned
            $0.mixer.startInChannelView = false
        }
        let result = await h.mixer.tracks(refresh: true)
        #expect(result.status == .unverified)
        #expect(result.summary.contains("not confirmed"))
        #expect(result.warnings.contains { $0.contains("8 strips with the same name and values") })
        // The cache keeps the status.
        let cached = await h.mixer.tracks(refresh: false)
        #expect(cached.after?.cached == true)
        #expect(cached.status == .unverified)
    }

    @Test func lowerLineOverlayIsWaitedOut() async {
        let h = await MixerHarness.make(tracks: names(4)) { $0.mixer.startInChannelView = false }
        // A fader move in Logic shows "x.x dB" over the pan value for a while.
        await h.session.send([.fader(fader: 1, value: 8178)])
        _ = await h.session.waitUntil(timeout: .milliseconds(200)) { StripReading.read($0, strip: 1).volumeText != nil }
        let result = await h.mixer.tracks(refresh: true)
        #expect(result.after?.tracks[1].pan == 0)
        #expect(result.after?.tracks[1].volumeDb == .db(-9.0))
    }

    @Test func cachedScanIsReused() async {
        let h = await MixerHarness.make(tracks: names(10))
        _ = await h.mixer.tracks(refresh: true)
        let pressesAfterScan = await h.host.presses.count
        let cached = await h.mixer.tracks(refresh: false)
        #expect(cached.after?.cached == true)
        #expect(await h.host.presses.count == pressesAfterScan)
    }

    @Test func unconnectedSurfaceSendsNothing() async {
        var behavior = FakeLogicHost.Behavior()
        behavior.probeOnly = true
        let base = await Harness.make(behavior)
        _ = await pollUntil { await base.session.linkStatus().messagesReceived >= 2 }
        let mixer = MixerController(mcu: base.session, sync: base.sync, names: nil, timings: fastTimings())
        #expect(await mixer.tracks(refresh: true).status == .failed)
        #expect(await mixer.set([MixerChange(track: 1, mute: true)]).status == .failed)
        #expect(await base.host.presses.isEmpty)
    }
}

@Suite("mixer_set against FakeLogic")
struct MixerSetTests {
    @Test func volumeIsSetAndVerifiedByLogic() async {
        let h = await MixerHarness.make()
        let result = await h.mixer.set([MixerChange(track: 3, expectedName: "オーディオ 1", volume: .db(-6.0))])
        #expect(result.status == .verified, "\(result.summary) \(result.warnings)")
        #expect(result.before?.first?.volumeDb == .db(0))
        #expect(result.after?.first?.volumeDb == .db(-6.0))
        let fader = await h.host.tracks[2].fader
        #expect(FakeMixer.volumeText(fader) == "-6.0 dB")
        #expect(await h.selectPresses().isEmpty)
        let presses = await h.host.presses
        #expect(presses.contains(MCUButton.faderTouch(2)))
        // The release goes through an asynchronous pipe; wait for the fake to process it.
        #expect(await pollUntil { await h.host.touchedFaders.isEmpty })
    }

    @Test(arguments: [-0.5, -3.0, -17.0, -27.3, -40.0, -58.0, 2.2, 6.0])
    func volumeClosedLoopReachesTarget(target: Double) async {
        let h = await MixerHarness.make(tracks: names(3)) { $0.mixer.startInChannelView = false }
        let result = await h.mixer.set([MixerChange(track: 1, volume: .db(target))])
        #expect(result.status == .verified, "\(target): \(result.summary) \(result.warnings)")
        guard case .db(let shown)? = result.after?.first?.volumeDb else { Issue.record("no level"); return }
        #expect(abs(shown - target) <= 0.1 + 1e-9)
        // The release goes through an asynchronous pipe; wait for the fake to process it.
        #expect(await pollUntil { await h.host.touchedFaders.isEmpty })
    }

    @Test func silenceAndLowLevels() async {
        let h = await MixerHarness.make(tracks: names(3)) { $0.mixer.startInChannelView = false }
        let silent = await h.mixer.set([MixerChange(track: 2, volume: .minusInfinity)])
        #expect(silent.status == .verified)
        #expect(silent.after?.first?.volumeDb == .minusInfinity)
        #expect(await h.host.tracks[1].fader == 0)
        let low = await h.mixer.set([MixerChange(track: 3, volume: .db(-90))])
        #expect(low.status == .verified, "\(low.warnings)")
    }

    @Test func trackOnALaterPageIsReached() async {
        let h = await MixerHarness.make(tracks: names(30))
        let result = await h.mixer.set([MixerChange(track: 27, expectedName: "Trk27", volume: .db(-3.0), pan: 12)])
        #expect(result.status == .verified, "\(result.summary) \(result.warnings)")
        let track = await h.host.tracks[26]
        #expect(track.pan == 12)
        #expect(FakeMixer.volumeText(track.fader) == "-3.0 dB")
        for index in [0, 25, 27] { #expect(await h.host.tracks[index].fader == 12443) }
        #expect(await h.selectPresses().isEmpty)
    }

    @Test func unexpectedBankStepFallsBackToChannelSteps() async {
        let h = await MixerHarness.make(tracks: names(30)) { $0.mixer.bankStep = 4 }
        _ = await h.mixer.tracks(refresh: true)  // returns the surface to the first page
        #expect(await h.host.mixer.offset == 0)
        let result = await h.mixer.set([MixerChange(track: 27, expectedName: "Trk27", mute: true)])
        #expect(result.status == .verified, "\(result.summary) \(result.warnings)")
        #expect(result.warnings.contains { $0.contains("Bank Right") })
        #expect(await h.host.tracks[26].mute == true)
        #expect(await h.host.tracks.filter(\.mute).count == 1)
    }

    @Test func panMovesOneTickAtATime() async {
        let h = await MixerHarness.make(tracks: names(4)) { $0.mixer.startInChannelView = false }
        let result = await h.mixer.set([MixerChange(track: 2, pan: -7)])
        #expect(result.status == .verified)
        #expect(result.before?.first?.pan == 0)
        #expect(result.after?.first?.pan == -7)
        #expect(await h.host.tracks[1].pan == -7)
        #expect(await h.host.mixer.vPotTicks == 7)
        // Already there: nothing sent.
        let again = await h.mixer.set([MixerChange(track: 2, pan: -7)])
        #expect(again.status == .verified)
        #expect(await h.host.mixer.vPotTicks == 7)
    }

    @Test func muteAndSoloPressOnlyWhenDifferent() async {
        let h = await MixerHarness.make(tracks: names(4)) { $0.mixer.startInChannelView = false }
        let mute = await h.mixer.set([MixerChange(track: 4, mute: true)])
        #expect(mute.status == .verified, "\(mute.warnings)")
        #expect(mute.after?.first?.mute == true)
        var count = await h.host.presses.count
        #expect(await h.mixer.set([MixerChange(track: 4, mute: true)]).status == .verified)
        #expect(await h.host.presses.count == count)
        #expect(await h.mixer.set([MixerChange(track: 4, mute: false)]).status == .verified)
        #expect(await h.host.tracks[3].mute == false)

        let solo = await h.mixer.set([MixerChange(track: 4, solo: true)])
        #expect(solo.status == .verified, "\(solo.warnings)")
        #expect(solo.after?.first?.solo == true)
        // While soloed, Logic blinks the other mute LEDs: mute reads as unknown.
        #expect(solo.after?.first?.mute == nil)
        count = await h.host.presses.count
        #expect(await h.mixer.set([MixerChange(track: 4, solo: true)]).status == .verified)
        #expect(await h.host.presses.count == count)
        #expect(await h.mixer.set([MixerChange(track: 4, solo: false)]).status == .verified)
        #expect(await h.host.tracks[3].solo == false)
    }

    @Test func refusedWhilePlayingSendsNothing() async {
        let h = await MixerHarness.make(tracks: names(4))
        _ = await h.base.transport.play()
        let before = await h.host.presses
        let result = await h.mixer.set([MixerChange(track: 1, volume: .db(-3), mute: true)])
        #expect(result.status == .failed)
        #expect(result.summary.contains("playing"))
        #expect(await h.host.presses == before)
        #expect(await h.host.mixer.faderMoves == 0)
    }

    @Test func nameMismatchSendsNothingToTracks() async {
        let h = await MixerHarness.make()
        let result = await h.mixer.set([
            MixerChange(track: 1, expectedName: "Inst 1", volume: .db(-3)),
            MixerChange(track: 3, expectedName: "Bass", mute: true),
        ])
        #expect(result.status == .failed)
        #expect(result.summary.contains("name check failed"))
        #expect(await h.host.mixer.faderMoves == 0)
        #expect(await h.host.tracks.allSatisfy { !$0.mute && $0.fader == 12443 })
    }

    @Test func invalidInputAndMissingTrackSendNothing() async {
        let h = await MixerHarness.make(tracks: names(4)) { $0.mixer.startInChannelView = false }
        #expect(await h.mixer.set([MixerChange(track: 1, volume: .db(7))]).status == .failed)
        #expect(await h.mixer.set([MixerChange(track: 1, pan: 64)]).status == .failed)
        #expect(await h.mixer.set([MixerChange(track: 1)]).status == .failed)
        #expect(await h.host.presses.isEmpty)
        let missing = await h.mixer.set([MixerChange(track: 1, mute: true), MixerChange(track: 9, mute: true)])
        #expect(missing.status == .failed)
        #expect(missing.summary.contains("does not exist"))
        #expect(await h.host.tracks.allSatisfy { !$0.mute })
    }

    @Test func echoOffIsVerifiedByTheLCDText() async {
        let h = await MixerHarness.make(tracks: names(3)) {
            $0.mixer.startInChannelView = false
            $0.mixer.echoesFaderMoves = false
        }
        let result = await h.mixer.set([MixerChange(track: 1, volume: .db(-12.0))])
        #expect(result.status == .verified, "\(result.warnings)")
        #expect(result.evidence.contains { $0.contains("no echo") }, "\(result.evidence)")
        #expect(result.after?.first?.volumeDb == .db(-12.0))
        #expect(result.after?.first?.faderPosition == nil)
    }

    @Test func echoOnlyIsVerifiedThroughTheCalibration() async {
        let h = await MixerHarness.make(tracks: names(3)) {
            $0.mixer.startInChannelView = false
            $0.mixer.showsVolumeText = false
        }
        let result = await h.mixer.set([MixerChange(track: 1, volume: .db(-9.0))])
        #expect(result.status == .verified, "\(result.warnings)")
        #expect(result.evidence.contains { $0.contains("calibration") })
    }

    @Test func noFeedbackFailsAndBatchIsPartial() async {
        let h = await MixerHarness.make(tracks: names(3)) {
            $0.mixer.startInChannelView = false
            $0.mixer.echoesFaderMoves = false
            $0.mixer.showsVolumeText = false
        }
        let result = await h.mixer.set([MixerChange(track: 1, mute: true), MixerChange(track: 2, volume: .db(-3))])
        #expect(result.status == .partial)
        #expect(result.warnings.contains { $0.contains("track 2") })
        #expect(await h.host.tracks[0].mute == true)
        // The fader was touched, and the touch was released although it failed.
        #expect(await h.host.presses.filter { $0 == MCUButton.faderTouch(1) }.count >= 1)
        // The release goes through an asynchronous pipe; wait for the fake to process it.
        #expect(await pollUntil { await h.host.touchedFaders.isEmpty })
        // Nothing usable came back: the level is unknown, not a guess.
        #expect(result.after?.last?.volumeDb == nil)
    }

    @Test func dBTextLeftOnAStripIsNotTakenForTheNextTrack() async {
        let h = await MixerHarness.make(tracks: names(12))
        _ = await h.mixer.tracks(refresh: true)  // surface back on the first page
        let result = await h.mixer.set([MixerChange(track: 8, volume: .db(-6)), MixerChange(track: 9, volume: .db(-6))])
        #expect(result.status == .verified, "\(result.warnings)")
        #expect(FakeMixer.volumeText(await h.host.tracks[8].fader) == "-6.0 dB")
    }

    @Test func dBTextLeftOnAStripDoesNotLeakIntoAnotherTracksState() async {
        let h = await MixerHarness.make(tracks: names(12))
        _ = await h.mixer.tracks(refresh: true)
        let result = await h.mixer.set([MixerChange(track: 8, volume: .db(-6)), MixerChange(track: 9, mute: true)])
        #expect(result.status == .verified, "\(result.warnings)")
        #expect(result.after?.last?.volumeDb == .db(0))
        let cached = await h.mixer.tracks(refresh: false)
        #expect(cached.after?.tracks[8].volumeDb == .db(0))
        #expect(cached.after?.tracks[7].volumeDb == .db(-6))
    }

    @Test func staleFaderWithoutEchoIsNotTrusted() async {
        let h = await MixerHarness.make(tracks: names(3)) {
            $0.mixer.startInChannelView = false
            $0.mixer.echoesFaderMoves = false
        }
        #expect(await h.mixer.set([MixerChange(track: 1, volume: .db(-12))]).status == .verified)
        let back = await h.mixer.set([MixerChange(track: 1, volume: .db(0))])
        #expect(back.status == .verified, "\(back.warnings)")
        #expect(await h.host.tracks[0].fader == 12443)
    }

    @Test func alreadyAtTargetSendsNoFaderMove() async {
        let h = await MixerHarness.make(tracks: names(3)) { $0.mixer.startInChannelView = false }
        let result = await h.mixer.set([MixerChange(track: 1, volume: .db(0))])
        #expect(result.status == .verified)
        #expect(await h.host.mixer.faderMoves == 0)
        _ = await h.mixer.set([MixerChange(track: 1, volume: .db(6))])
        let moves = await h.host.mixer.faderMoves
        let again = await h.mixer.set([MixerChange(track: 1, volume: .db(6))])
        #expect(again.status == .verified)
        #expect(await h.host.mixer.faderMoves == moves)
    }

    @Test func insertedTrackForcesRescan() async {
        let h = await MixerHarness.make(tracks: names(10))
        _ = await h.mixer.tracks(refresh: true)
        await h.host.setTracks([FakeTrack("New")] + names(10))
        let result = await h.mixer.set([MixerChange(track: 5, expectedName: "Trk4", mute: true)])
        #expect(result.status == .verified, "\(result.summary) \(result.warnings)")
        #expect(await h.host.tracks[4].mute == true)
        #expect(await h.host.tracks[4].name == "Trk4")
    }

    @Test func renamedTrackWithoutAccessibilityIsCaughtByNavigation() async {
        let h = await MixerHarness.make(tracks: names(12), names: .none)
        _ = await h.mixer.tracks(refresh: true)
        // Same count, different order: the cached layout no longer matches the surface.
        var swapped = names(12)
        swapped.swapAt(9, 10)
        await h.host.setTracks(swapped)
        let result = await h.mixer.set([MixerChange(track: 11, expectedName: "Trk11", mute: true)])
        // After rescanning, track 11 is "Trk10": the name check refuses it.
        #expect(result.status == .failed)
        #expect(result.warnings.contains { $0.contains("name check failed") })
        #expect(await h.host.tracks.allSatisfy { !$0.mute })
    }

    @Test func overlayFromPanDoesNotBreakTheNextChangeOnThePage() async {
        let h = await MixerHarness.make(tracks: names(6)) { $0.mixer.startInChannelView = false }
        let result = await h.mixer.set([
            MixerChange(track: 1, pan: 5),
            MixerChange(track: 2, volume: .db(-6), pan: -5),
            MixerChange(track: 1, mute: true),
        ])
        #expect(result.status == .verified, "\(result.warnings)")
        let first = await h.host.tracks[0]
        #expect(first.pan == 5 && first.mute)
        #expect(await h.host.tracks[1].pan == -5)
    }

    @Test func splitLCDWritesAndEchoDelay() async {
        let h = await MixerHarness.make(tracks: names(14)) {
            $0.mixer.lcdChunk = 5
            $0.mixer.echoDelay = .milliseconds(30)
        }
        let scan = await h.mixer.tracks(refresh: true)
        #expect(scan.after?.trackCount == 14)
        let result = await h.mixer.set([MixerChange(track: 13, volume: .db(-4.5))])
        #expect(result.status == .verified, "\(result.warnings)")
    }
}
