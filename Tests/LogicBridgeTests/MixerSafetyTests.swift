import FakeLogic
import Foundation
import Testing
@testable import LogicBridge
import MackieControl
import MIDICore

/// Distinct names made only of non-ASCII characters (full-width digits included): every one
/// shows as blank on the Mackie LCD.
func japaneseNames(_ count: Int) -> [String] {
    let digits = Array("０１２３４５６７８９")
    return (1...count).map { number in
        "トラック" + String(String(number).map { digits[Int(String($0))!] })
    }
}

extension MixerHarness {
    /// Track numbers (1-based) that are muted in the fake.
    func mutedTracks() async -> [Int] {
        let tracks = await host.tracks
        return tracks.indices.filter { tracks[$0].mute }.map { $0 + 1 }
    }
}

/// Navigation, scanning and refusal paths that must never touch the wrong track or report a
/// guess as Logic's state.
@Suite("Mixer safety against FakeLogic")
struct MixerSafetyTests {
    // MARK: The track list changes between the scan and a batch

    @Test func tracksRemovedBeforeABatchFailCleanly() async {
        let h = await MixerHarness.make(tracks: names(12), names: .none)
        #expect(await h.mixer.tracks(refresh: true).after?.trackCount == 12)
        await h.host.setTracks(names(9))
        let result = await h.mixer.set([MixerChange(track: 12, mute: true), MixerChange(track: 10, mute: true)])
        #expect(result.status == .failed, "\(result.summary) \(result.warnings)")
        #expect(result.warnings.filter { $0.contains("does not exist") }.count == 2, "\(result.warnings)")
        #expect(await h.mutedTracks().isEmpty)
    }

    @Test func everyChangeIsCheckedAgainAfterARescan() async {
        let h = await MixerHarness.make(tracks: names(20), names: .none)
        _ = await h.mixer.tracks(refresh: true)  // surface back on the first page
        // Reordered beyond the first page, so the cached scan still looks valid there.
        var reordered = names(20)
        reordered.swapAt(12, 13)
        reordered.swapAt(15, 16)
        await h.host.setTracks(reordered)
        let result = await h.mixer.set([
            MixerChange(track: 13, expectedName: "Trk13", mute: true),
            MixerChange(track: 16, expectedName: "Trk16", mute: true),
            MixerChange(track: 18, expectedName: "Trk18", mute: true),
        ])
        #expect(result.status == .partial, "\(result.summary) \(result.warnings)")
        #expect(result.warnings.filter { $0.contains("name check failed") }.count == 2, "\(result.warnings)")
        // Track 16 is now "Trk17": checked again after the rescan, so it was not touched.
        #expect(await h.mutedTracks() == [18])
    }

    // MARK: Positions are proven from names and values

    @Test func blankNamesAndAnUnexpectedBankStepReachTheRightTrack() async {
        let tracks = japaneseNames(30).enumerated().map { FakeTrack($1, pan: $0 - 15) }
        let h = await MixerHarness.make(tracks: tracks) { $0.mixer.bankStep = 4 }
        let scan = await h.mixer.tracks(refresh: true)
        #expect(scan.status == .verified, "\(scan.summary)")
        #expect(scan.after?.trackCount == 30)
        let result = await h.mixer.set([MixerChange(track: 27, expectedName: tracks[26].name, mute: true)])
        #expect(result.status == .verified, "\(result.summary) \(result.warnings)")
        #expect(result.warnings.contains { $0.contains("Bank Right") })
        #expect(await h.mutedTracks() == [27])
        #expect(await h.selectPresses().isEmpty)
    }

    @Test func lookAlikePagesDisableBankRight() async {
        // Alternating names and equal values: pages 8 apart look the same, so only counted
        // Channel Right steps prove the position, and the first page needs Logic's Name/Value
        // acknowledgement.
        let tracks = (1...20).map { FakeTrack($0 % 2 == 0 ? "Even" : "Odd") }
        let h = await MixerHarness.make(tracks: tracks, names: .none) { $0.mixer.bankStep = 4 }
        let scan = await h.mixer.tracks(refresh: true)
        #expect(scan.status == .verified, "\(scan.summary)")
        #expect(scan.after?.trackCount == 20)
        for _ in 0..<13 { await h.press(.channelLeft) }
        #expect(await h.host.mixer.offset == 0)
        let nameValue = await h.host.presses.filter { $0 == MCUButton.nameValue.rawValue }.count
        let result = await h.mixer.set([MixerChange(track: 17, mute: true), MixerChange(track: 5, mute: true)])
        #expect(result.status == .verified, "\(result.summary) \(result.warnings)")
        #expect(await h.mutedTracks() == [5, 17])
        #expect(!(await h.host.presses).contains(MCUButton.bankRight.rawValue))
        // Track 17: proven by visible steps; track 5: by Name/Value after Option + Bank Left.
        #expect(await h.host.presses.filter { $0 == MCUButton.nameValue.rawValue }.count == nameValue + 2)
        #expect(await h.host.mixer.showValues)
    }

    @Test func lookAlikeFirstPageWithoutAcknowledgementChangesNothing() async {
        let tracks = (1...20).map { FakeTrack($0 % 2 == 0 ? "Even" : "Odd") }
        let h = await MixerHarness.make(tracks: tracks, names: .none)
        _ = await h.mixer.tracks(refresh: true)
        for _ in 0..<13 { await h.press(.channelLeft) }
        await h.host.setRespondsToButtons(false)
        let result = await h.mixer.set([MixerChange(track: 5, mute: true)])
        #expect(result.status == .failed, "\(result.summary) \(result.warnings)")
        #expect(result.warnings.contains { $0.contains("did not confirm") }, "\(result.warnings)")
        #expect(await h.mutedTracks().isEmpty)
    }

    @Test func defaultEnglishNamesAreCountedAndReachable() async {
        // "Audio 1" … "Audio 20" at default values all show "Audio" on the LCD.
        let h = await MixerHarness.make(tracks: (1...20).map { FakeTrack("Audio \($0)") }, names: .none)
        let scan = await h.mixer.tracks(refresh: true)
        #expect(scan.status == .verified, "\(scan.summary)")
        #expect(scan.after?.trackCount == 20)
        #expect(scan.evidence.contains { $0.contains("press(es) showed no change") }, "\(scan.evidence)")
        let result = await h.mixer.set([
            MixerChange(track: 3, mute: true), MixerChange(track: 10, mute: true), MixerChange(track: 20, mute: true),
        ])
        #expect(result.status == .verified, "\(result.summary) \(result.warnings)")
        #expect(await h.mutedTracks() == [3, 10, 20])
        #expect(await h.host.mixer.showValues)
        #expect(await h.selectPresses().isEmpty)
    }

    @Test func aRunOfIdenticalStripsIsCountedWhenItsEndShows() async {
        // Tracks 16–24 all show "Audio" with the same values (checklist project P before the fix).
        let tracks = names(15) + (10...18).map { FakeTrack("Audio \($0)") }
        let h = await MixerHarness.make(tracks: tracks, names: .none)
        let result = await h.mixer.tracks(refresh: true)
        #expect(result.status == .verified, "\(result.summary)")
        #expect(result.after?.trackCount == 24)
        #expect(result.after?.tracks.suffix(9).allSatisfy { $0.lcdName == "Audio" } == true)
        let set = await h.mixer.set([MixerChange(track: 21, mute: true), MixerChange(track: 24, mute: true)])
        #expect(set.status == .verified, "\(set.summary) \(set.warnings)")
        #expect(await h.mutedTracks() == [21, 24])
    }

    @Test func tenIdenticalTracksAreCounted() async {
        let h = await MixerHarness.make(tracks: Array(repeating: FakeTrack("Audio"), count: 10), names: .none)
        let result = await h.mixer.tracks(refresh: true)
        #expect(result.status == .verified, "\(result.summary)")
        #expect(result.after?.trackCount == 10)
    }

    @Test func identicalPagesInAnUnconfirmedListAreNotGuessed() async {
        // Right-aligned last page: the identical run at the end never shows its end.
        let tracks = names(4) + Array(repeating: FakeTrack("Audio"), count: 12)
        let h = await MixerHarness.make(tracks: tracks, names: .none) { $0.mixer.lastPage = .rightAligned }
        let scan = await h.mixer.tracks(refresh: true)
        #expect(scan.status == .unverified, "\(scan.summary)")
        let count = scan.after?.trackCount ?? 0
        #expect(count < 16)
        // Track 2 is reached by counted steps from the first page; the last scanned track sits
        // on a page that looks like the ones after it, but its arrival from the page before
        // shows, so it can be reached too.
        let result = await h.mixer.set([MixerChange(track: 2, mute: true), MixerChange(track: count, mute: true)])
        #expect(result.status == .verified, "\(result.summary) \(result.warnings)")
        #expect(await h.mutedTracks() == [2, count])
    }

    // MARK: Logic not handling the surface

    @Test func logicIgnoringTheSurfaceFailsTheScan() async {
        let h = await MixerHarness.make(tracks: names(20)) {
            $0.mixer.startInChannelView = false
            $0.respondsToButtons = false
        }
        let result = await h.mixer.tracks(refresh: true)
        #expect(result.status == .failed, "\(result.summary)")
        #expect(result.after == nil)
        #expect(result.summary.contains("did not react"))
        let set = await h.mixer.set([MixerChange(track: 3, mute: true)])
        #expect(set.status == .failed)
        #expect(await h.mutedTracks().isEmpty)
    }

    @Test func logicIgnoringTheSurfaceMidListFailsTheScan() async {
        let h = await MixerHarness.make(tracks: names(20)) { $0.mixer.startInChannelView = false }
        for _ in 0..<5 { await h.press(.channelRight) }
        await h.host.setRespondsToButtons(false)
        let result = await h.mixer.tracks(refresh: true)
        #expect(result.status == .failed, "\(result.summary)")
        #expect(result.after == nil)
    }

    @Test func logicStoppingMidScanFailsTheScan() async {
        // Logic handles Option, Bank Left and six Channel Right presses, then ignores the surface.
        let h = await MixerHarness.make(tracks: names(20)) {
            $0.mixer.startInChannelView = false
            $0.ignoresSurfaceAfterPresses = 8
        }
        let result = await h.mixer.tracks(refresh: true)
        #expect(result.status == .failed, "\(result.summary)")
        #expect(result.summary.contains("end of the track list"))
        #expect(result.after == nil)
    }

    @Test func emptyProjectIsReportedWithoutProbing() async {
        let h = await MixerHarness.make(tracks: [], names: .none) { $0.mixer.startInChannelView = false }
        let result = await h.mixer.tracks(refresh: true)
        #expect(result.status == .unverified, "\(result.summary)")
        #expect(result.after?.trackCount == 0)
        #expect(result.summary.contains("no track"))
        // One Channel Right to look for more; no run probe.
        #expect(await h.host.presses.filter { $0 == MCUButton.channelRight.rawValue }.count == 1)
    }

    @Test func endOfTheListIsConfirmed() async {
        let h = await MixerHarness.make(tracks: names(11))
        let result = await h.mixer.tracks(refresh: true)
        #expect(result.status == .verified)
        #expect(result.evidence.contains { $0.contains("Channel Left moved back one strip") })
        let small = await MixerHarness.make(tracks: names(3))
        let few = await small.mixer.tracks(refresh: true)
        #expect(few.status == .verified)
        #expect(few.evidence.contains { $0.contains("Name/Value") })
    }

    // MARK: Names, volume reports, transport

    @Test func nonASCIIExpectedNameNeedsAccessibility() async {
        let tracks = [FakeTrack("ボーカル"), FakeTrack("ギター"), FakeTrack("Kick")]
        let h = await MixerHarness.make(tracks: tracks, names: .none)
        let result = await h.mixer.set([MixerChange(track: 2, expectedName: "ボーカル", mute: true)])
        #expect(result.status == .failed)
        #expect(result.summary.contains("Accessibility"), "\(result.summary)")
        #expect(await h.mutedTracks().isEmpty)

        let full = await MixerHarness.make(tracks: tracks)
        #expect(await full.mixer.set([MixerChange(track: 2, expectedName: "ボーカル", mute: true)]).status == .failed)
        #expect(await full.mutedTracks().isEmpty)
        let right = await full.mixer.set([MixerChange(track: 2, expectedName: "ギター", mute: true)])
        #expect(right.status == .verified, "\(right.summary) \(right.warnings)")
        #expect(await full.mutedTracks() == [2])
    }

    @Test func aFailedVolumeChangeReportsWhereTheFaderIs() async {
        // Coarse steps: corrections jump past the target and the last move can end farther
        // away than an earlier one.
        let h = await MixerHarness.make(tracks: names(3)) {
            $0.mixer.startInChannelView = false
            $0.mixer.faderQuantum = 1000
        }
        let result = await h.mixer.set([MixerChange(track: 1, volume: .db(-2.0))])
        #expect(result.status == .failed, "\(result.summary) \(result.warnings)")
        let fader = await h.host.tracks[0].fader
        let actual = MixerLCD.volume(FakeMixer.volumeText(fader))
        #expect(result.after?.first?.volumeDb == actual, "\(result.warnings)")
        #expect(result.after?.first?.faderPosition == Int(fader))
        // The release goes through an asynchronous pipe; wait for the fake to process it.
        #expect(await pollUntil { await h.host.touchedFaders.isEmpty })
        let cached = await h.mixer.tracks(refresh: false)
        #expect(cached.after?.tracks.first?.volumeDb == actual)
    }

    @Test func playbackStartingDuringPanStopsTheRest() async {
        let h = await MixerHarness.make(tracks: names(3)) {
            $0.mixer.startInChannelView = false
            $0.startsPlayingAfterVPotTicks = 3
        }
        let result = await h.mixer.set([MixerChange(track: 1, volume: .db(-6), pan: 10, mute: true)])
        #expect(result.status == .failed, "\(result.summary) \(result.warnings)")
        #expect(result.warnings.filter { $0.contains("playing") }.count >= 3, "\(result.warnings)")
        let track = await h.host.tracks[0]
        #expect((3...4).contains(track.pan))
        #expect(!track.mute)
        #expect(await h.host.mixer.faderMoves == 0)
        #expect(!(await h.host.presses).contains(MCUButton.faderTouch(0)))
        // The release goes through an asynchronous pipe; wait for the fake to process it.
        #expect(await pollUntil { await h.host.touchedFaders.isEmpty })
    }

    @Test func playbackStartingDuringVolumeCorrectionsReleasesTheTouch() async {
        let h = await MixerHarness.make(tracks: names(3)) {
            $0.mixer.startInChannelView = false
            $0.startsPlayingAfterFaderMoves = 1
        }
        // -27.3 dB needs a correction after the first move with the fake's fader law.
        let result = await h.mixer.set([MixerChange(track: 1, volume: .db(-27.3))])
        #expect(result.status == .failed, "\(result.summary) \(result.warnings)")
        #expect(result.warnings.contains { $0.contains("playing") && $0.contains("touch released") }, "\(result.warnings)")
        #expect(await h.host.mixer.faderMoves == 1)
        // The release goes through an asynchronous pipe; wait for the fake to process it.
        #expect(await pollUntil { await h.host.touchedFaders.isEmpty })
    }

    /// Observed 2026-11-21: right after New Audio Track Logic handled the Option release late,
    /// so a Channel Right sent 65 ms after it jumped to the last page. The scan waits for Logic
    /// to show the release (Global View stops flashing) before the next press.
    @Test func lateOptionReleaseDoesNotTurnChannelRightIntoAJump() async {
        let h = await MixerHarness.make(tracks: names(12)) {
            $0.mixer.optionReleaseLag = .milliseconds(150)
        }
        let scan = await h.mixer.tracks(refresh: true)
        #expect(scan.status == .verified, "\(scan.summary) \(scan.warnings)")
        #expect(scan.after?.trackCount == 12)
        #expect(await h.mixer.set([MixerChange(track: 3, mute: true)]).status == .verified)
        #expect(await h.mutedTracks() == [3])
    }

    // MARK: Record arm (Logic 13: armed tracks blink, the selected one is steady)

    @Test func recordArmLightsAreWatched() async {
        var tracks = names(12)
        tracks[2].recArm = true
        tracks[9].recArm = true
        let h = await MixerHarness.make(tracks: tracks) { $0.mixer.selectedTrack = 5 }
        let result = await h.mixer.readRecordArms()
        #expect(result.status == .verified, "\(result.summary) \(result.warnings)")
        var expected = [RecordArmLight?](repeating: .off, count: 12)
        expected[2] = .alternating
        expected[9] = .alternating
        #expect(result.after?.map(\.light) == expected)
        #expect(result.summary.contains("3, 10"))
        #expect(await h.host.presses.filter { $0 <= 0x07 }.isEmpty)
    }

    @Test func theSelectedTracksSteadyLightNeedsARedraw() async {
        let h = await MixerHarness.make(tracks: names(5)) { $0.mixer.selectedTrack = 3 }
        #expect(await h.mixer.pressRecordArm(track: 1, expectedName: "Trk1").status == .verified)
        #expect(await h.mixer.pressRecordArm(track: 1, expectedName: "Trk1").status != .failed)
        // Logic turned the selected track's LED off when track 1 was armed and has not sent it
        // again; the watch starts with a redraw.
        #expect(await h.session.surface.led(MCUButton.recArm(3)) == .off)
        let result = await h.mixer.readRecordArms()
        #expect(result.after?.map(\.light) == [.off, .off, .off, .steady, .off])
    }

    @Test func aRecPressChecksTheName() async {
        let h = await MixerHarness.make(tracks: names(5))
        let result = await h.mixer.pressRecordArm(track: 2, expectedName: "Trk3")
        #expect(result.status == .failed)
        #expect(result.summary.contains("Nothing was pressed"))
        #expect(await h.host.presses.filter { $0 <= 0x07 }.isEmpty)
    }

    @Test(arguments: ["flip", "globalView"])
    func modesThatChangeTheStripsAreRefused(mode: String) async {
        let h = await MixerHarness.make(tracks: names(4)) {
            if mode == "flip" { $0.mixer.flipOn = true } else { $0.mixer.globalViewOn = true }
        }
        let scan = await h.mixer.tracks(refresh: true)
        #expect(scan.status == .failed)
        #expect(scan.summary.contains(mode == "flip" ? "Flip" : "Global View"))
        #expect(await h.mixer.set([MixerChange(track: 1, mute: true)]).status == .failed)
        #expect(await h.host.presses.isEmpty)
    }

    @Test func unknownTransportStateIsRefused() async {
        let h = await MixerHarness.make(tracks: names(4)) {
            $0.transportLEDs = false
            $0.sendsSync = false
        }
        let result = await h.mixer.set([MixerChange(track: 1, volume: .db(-3), mute: true)])
        #expect(result.status == .failed)
        #expect(result.summary.contains("has not reported its transport state"))
        #expect(await h.host.presses.isEmpty)
        #expect(await h.host.mixer.faderMoves == 0)
    }

    @Test func recordingIsRefused() async {
        let h = await MixerHarness.make(tracks: names(4))
        _ = await h.base.transport.record(confirmed: true)
        #expect(await h.host.recording)
        let before = await h.host.presses
        let result = await h.mixer.set([MixerChange(track: 1, volume: .db(-3), mute: true)])
        #expect(result.status == .failed)
        #expect(result.summary.contains("recording"))
        #expect(await h.host.presses == before)
        #expect(await h.host.mixer.faderMoves == 0)
    }

    // MARK: Reusing a scan

    @Test func partialAccessibilityListsDoNotForceRescans() async {
        let h = await MixerHarness.make(tracks: names(12), names: .fixed(["Trk3", "Trk4", "Trk5"])) {
            $0.mixer.startInChannelView = false
        }
        #expect(await h.mixer.set([MixerChange(track: 2, mute: true)]).status == .verified)
        let count = await h.host.presses.count
        #expect(await h.mixer.set([MixerChange(track: 3, mute: true)]).status == .verified)
        #expect(Array(await h.host.presses.dropFirst(count)) == [MCUButton.mute(2)])
    }

    @Test func cachedTrackListIsCheckedAgainstTheSurface() async {
        let h = await MixerHarness.make(tracks: names(10), names: .none)
        _ = await h.mixer.tracks(refresh: true)
        #expect(await h.mixer.tracks(refresh: false).after?.cached == true)
        await h.host.setTracks(names(10, prefix: "New"))
        _ = await h.session.waitUntil(timeout: .seconds(1)) { $0.lcdCell(strip: 0) == "New1" }
        let again = await h.mixer.tracks(refresh: false)
        #expect(again.after?.cached == false)
        #expect(again.after?.tracks.first?.name == "New1")
    }

    @Test(arguments: [false, true])
    func accentedNamesMatchEitherLCDForm(folds: Bool) async {
        let tracks = [FakeTrack("Café Ü"), FakeTrack("Bass \u{2018}DI\u{2019}"), FakeTrack("Kick")]
        let h = await MixerHarness.make(tracks: tracks) { $0.mixer.foldsAccents = folds }
        let result = await h.mixer.tracks(refresh: true)
        #expect(result.status == .verified)
        #expect(result.after?.tracks.map(\.nameSource) == [.accessibility, .accessibility, .accessibility])
        #expect(result.after?.tracks.first?.lcdName == (folds ? "Cafe U" : "Caf"))
        #expect(!result.warnings.contains { $0.contains("do not match the LCD") })
    }
}

/// Logic 13 with a soloed track (observed 2026-11-21): Rude Solo flashes and the other tracks'
/// mute LEDs blink through on/off messages, so mute LEDs cannot be trusted.
@Suite("Mixer while a track is soloed")
struct MixerSoloTests {
    @Test func scanReportsMuteAsUnknownWhileSoloed() async {
        var tracks = names(11)
        tracks[2].solo = true
        let h = await MixerHarness.make(tracks: tracks)
        let result = await h.mixer.tracks(refresh: true)
        #expect(result.status == .verified, "\(result.summary) \(result.warnings)")
        #expect(result.after?.trackCount == 11)
        #expect(result.after?.tracks.allSatisfy { $0.mute == nil } == true)
        #expect(result.after?.tracks[2].solo == true)
        #expect(result.warnings.contains { $0.contains("soloed") })
    }

    @Test func muteChangesAreRefusedWhileSoloed() async {
        var tracks = names(11)
        tracks[2].solo = true
        let h = await MixerHarness.make(tracks: tracks)
        let result = await h.mixer.set([MixerChange(track: 10, mute: true)])
        #expect(result.status == .failed)
        #expect(result.warnings.contains { $0.contains("soloed") })
        #expect(await h.mutedTracks().isEmpty)
        #expect(await h.host.presses.filter { (0x10...0x17).contains($0) }.isEmpty)
    }

    @Test func navigationStillWorksAfterSoloChangesTheLEDs() async {
        // The scan happens before solo; afterwards the mute LEDs differ from the scan.
        let h = await MixerHarness.make(tracks: names(11))
        #expect(await h.mixer.tracks(refresh: true).status == .verified)
        #expect(await h.mixer.set([MixerChange(track: 3, solo: true)]).status == .verified)
        let volume = await h.mixer.set([MixerChange(track: 10, volume: .db(-6))])
        #expect(volume.status == .verified, "\(volume.summary) \(volume.warnings)")
        let off = await h.mixer.set([MixerChange(track: 3, solo: false)])
        #expect(off.status == .verified, "\(off.summary) \(off.warnings)")
        #expect(await h.host.tracks[2].solo == false)
    }
}
