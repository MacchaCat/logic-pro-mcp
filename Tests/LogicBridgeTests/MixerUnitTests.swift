import Foundation
import Testing
@testable import LogicBridge
import MackieControl

@Suite("Fader calibration and LCD parsing")
struct FaderCalibrationTests {
    @Test func measuredPointsMapExactly() {
        for point in FaderCalibration.points {
            #expect(FaderCalibration.level(forPosition: point.position) == .db(point.db))
            #expect(FaderCalibration.position(for: .db(point.db)) == point.position)
        }
        #expect(FaderCalibration.level(forPosition: 0) == .minusInfinity)
        #expect(FaderCalibration.position(for: .minusInfinity) == 0)
    }

    @Test func interpolatesBetweenPoints() {
        // Halfway between 11965 (-1.2) and 12443 (0.0).
        guard case .db(let db) = FaderCalibration.level(forPosition: 12204) else { Issue.record("not finite"); return }
        #expect(abs(db - -0.6) < 0.01)
        #expect(FaderCalibration.position(for: .db(-0.6)) == 12204)
    }

    @Test func clampsAndRejectsOutOfRange() {
        #expect(FaderCalibration.level(forPosition: 16383) == .db(6.0))
        #expect(FaderCalibration.position(for: .db(6.0)) == 14845)
        #expect(FaderCalibration.position(for: .db(6.5)) == nil)
        #expect(FaderCalibration.position(for: .db(-107)) == nil)
        if case .db(let low) = FaderCalibration.level(forPosition: 50) { #expect(low < -106) } else { Issue.record("expected finite") }
    }

    @Test func roundTripIsMonotonic() {
        var previous = -Double.infinity
        for position in stride(from: 1, through: 14845, by: 97) {
            guard case .db(let db) = FaderCalibration.level(forPosition: position) else { continue }
            #expect(db >= previous)
            previous = db
        }
    }

    @Test func panParserIsStrict() {
        #expect(MixerLCD.pan("0") == 0)
        #expect(MixerLCD.pan("+3") == 3)
        #expect(MixerLCD.pan("-64") == -64)
        #expect(MixerLCD.pan("+63") == 63)
        #expect(MixerLCD.pan("+64") == nil)
        #expect(MixerLCD.pan("3") == nil)
        #expect(MixerLCD.pan("Pan") == nil)
        #expect(MixerLCD.pan("") == nil)
        #expect(MixerLCD.pan("-1.2 dB") == nil)
        #expect(MixerLCD.pan("Muted") == nil)
        #expect(MixerLCD.pan("--") == nil)
    }

    @Test func volumeTextAsLogic13WritesIt() {
        #expect(MixerLCD.volume("-1.2 dB ") == .db(-1.2))
        #expect(MixerLCD.volume("+0.0 dB       0") == .db(0))
        #expect(MixerLCD.volume("-12.8 dB") == .db(-12.8))
        #expect(MixerLCD.volume("-12.8 d") == .db(-12.8))  // cut at the end of the line (strip 8)
        #expect(MixerLCD.volume("-106 dB ") == .db(-106))
        #expect(MixerLCD.volume("-oo dB  ") == .minusInfinity)
        #expect(MixerLCD.volume("+6.0 dB ") == .db(6))
        #expect(MixerLCD.volume("0      ") == nil)
        #expect(MixerLCD.volume("+3     ") == nil)
        #expect(MixerLCD.volume("Muted  ") == nil)
        #expect(MixerLCD.volume("Inst 1 ") == nil)
    }

    @Test func volumeLevelEncodesSilenceAsString() throws {
        let encoder = JSONEncoder()
        #expect(String(decoding: try encoder.encode([VolumeLevel.minusInfinity, .db(-3.04), .db(6)]), as: UTF8.self) == #"["-inf",-3,6]"#)
        let decoded = try JSONDecoder().decode([VolumeLevel].self, from: Data(#"["-inf", -2.5, "-oo"]"#.utf8))
        #expect(decoded == [.minusInfinity, .db(-2.5), .minusInfinity])
        #expect(VolumeLevel.parse("silence") == .minusInfinity)
        #expect(VolumeLevel.parse("abc") == nil)
    }

    @Test func trackInfoWithSilenceEncodes() throws {
        let info = TrackInfo(number: 1, name: "Bass", nameSource: .lcd, lcdName: "Bass", volumeDb: .minusInfinity,
                             faderPosition: 0, pan: 0, mute: false, solo: false)
        let json = String(decoding: try JSONEncoder().encode(info), as: UTF8.self)
        #expect(json.contains(#""volume_db":"-inf""#))
        #expect(json.contains(#""name_source":"lcd""#))
    }
}

@Suite("Track name merge")
struct TrackNameMergeTests {
    @Test func lcdKeyFollowsObservedRule() {
        #expect(TrackNameMerge.lcdKey("Inst 1") == "Inst 1")
        #expect(TrackNameMerge.lcdKey("オーディオ 1") == "1")
        #expect(TrackNameMerge.lcdKey("Inst 10") == "Inst 1")
        #expect(TrackNameMerge.lcdKey("ボーカル") == "")
        #expect(TrackNameMerge.lcdKey("  Lead Vocal") == "Lead V")
        #expect(TrackNameMerge.lcdKey("Café") == "Caf")  // non-ASCII dropped (observed rule)
        #expect(TrackNameMerge.lcdKey("ベース A") == "A")
    }

    @Test func lcdFormsAcceptDroppingAndFolding() {
        // Folding accents / curly quotes is not observed; both forms are accepted until it is.
        #expect(TrackNameMerge.lcdForms("Café Ü") == ["Caf", "Cafe U"])
        #expect(TrackNameMerge.lcdForms("Bass \u{2018}DI\u{2019}") == ["Bass D", "Bass '"])
        #expect(TrackNameMerge.lcdForms("オーディオ 1") == ["1"])
        #expect(TrackNameMerge.matchesLCD("Café Ü", "Caf"))
        #expect(TrackNameMerge.matchesLCD("Café Ü", "Cafe U"))
        #expect(!TrackNameMerge.matchesLCD("Café Ü", "Cafe"))
        let merged = TrackNameMerge.merge(lcd: ["Caf", "Cafe U"], full: TrackNameList(names: ["Café Ü", "Café Ü"]))
        #expect(merged.names.allSatisfy { $0.source == .accessibility })
    }

    @Test func sameCountMergesByPosition() {
        let lcd = ["Inst 1", "Inst 2", "1", "2"]
        let full = TrackNameList(names: ["Inst 1", "Inst 2", "オーディオ 1", "オーディオ 2"])
        let merged = TrackNameMerge.merge(lcd: lcd, full: full)
        #expect(merged.names.map(\.name) == ["Inst 1", "Inst 2", "オーディオ 1", "オーディオ 2"])
        #expect(merged.names.allSatisfy { $0.source == .accessibility })
        #expect(merged.warnings.isEmpty)
    }

    @Test func mismatchFallsBackToLCDWithWarning() {
        let merged = TrackNameMerge.merge(lcd: ["Inst 1", "Bass"], full: TrackNameList(names: ["Inst 1", "Guitar"]))
        #expect(merged.names[0].source == .accessibility)
        #expect(merged.names[1] == ResolvedTrackName(name: "Bass", source: .lcd, fullName: nil))
        #expect(merged.warnings.count == 1)
        #expect(merged.warnings[0].contains("Guitar"))
    }

    @Test func visibleSubsetIsPlacedOnlyWhenUnique() {
        let lcd = ["Inst 1", "Inst 2", "1", "2", "3"]
        let unique = TrackNameMerge.merge(lcd: lcd, full: TrackNameList(names: ["オーディオ 1", "オーディオ 2"]))
        #expect(unique.names.map(\.source) == [.lcd, .lcd, .accessibility, .accessibility, .lcd])
        #expect(unique.names[2].name == "オーディオ 1")
        #expect(unique.warnings.contains { $0.contains("tracks 3–4") })

        let repeated = ["1", "1", "1"]
        let ambiguous = TrackNameMerge.merge(lcd: repeated, full: TrackNameList(names: ["オーディオ 1"]))
        #expect(ambiguous.names.allSatisfy { $0.source == .lcd })
        #expect(ambiguous.warnings.contains { $0.contains("none were used") })
    }

    @Test func unavailableNamesWarn() {
        let merged = TrackNameMerge.merge(lcd: ["1"], full: .unavailable("not trusted"))
        #expect(merged.names == [ResolvedTrackName(name: "1", source: .lcd, fullName: nil)])
        #expect(merged.warnings.first?.contains("not trusted") == true)
    }

    @Test func expectedNameCheck() {
        #expect(TrackNameMerge.check(expected: "オーディオ 1", lcdName: "1", fullName: "オーディオ 1") == .matchesFullName)
        #expect(TrackNameMerge.check(expected: "オーディオ 1", lcdName: "1", fullName: nil) == .matchesLCDOnly)
        if case .mismatch = TrackNameMerge.check(expected: "Bass 2X", lcdName: "Bass 2", fullName: "Bass 2Y") {} else {
            Issue.record("a different full name must not pass on the LCD form")
        }
        if case .mismatch = TrackNameMerge.check(expected: "Drums", lcdName: "Bass", fullName: nil) {} else {
            Issue.record("expected a mismatch")
        }
    }

    @Test func blankLCDNamesCannotConfirmNonASCIINames() {
        // Without Accessibility a name of only non-ASCII characters shows blank, like every
        // other such name: the check must not pass.
        if case .uncheckable = TrackNameMerge.check(expected: "ボーカル", lcdName: "", fullName: nil) {} else {
            Issue.record("a blank LCD name must not confirm a non-ASCII name")
        }
        if case .uncheckable = TrackNameMerge.check(expected: "Ü", lcdName: "", fullName: nil) {} else {
            Issue.record("a name that may show blank must not be confirmed by a blank LCD name")
        }
        if case .mismatch = TrackNameMerge.check(expected: "ボーカル", lcdName: "Kick", fullName: nil) {} else {
            Issue.record("a non-ASCII name cannot be a non-blank LCD name")
        }
        if case .mismatch = TrackNameMerge.check(expected: "Kick", lcdName: "", fullName: nil) {} else {
            Issue.record("an ASCII name cannot be a blank LCD name")
        }
        #expect(TrackNameMerge.check(expected: "ボーカル", lcdName: "", fullName: "ボーカル") == .matchesFullName)
        #expect(TrackNameMerge.check(expected: "Café Ü", lcdName: "Caf", fullName: nil) == .matchesLCDOnly)
    }
}

@Suite("Page step classification")
struct StepClassificationTests {
    func page(_ names: [String], values: [String]? = nil) -> PageReading {
        PageReading(strips: names.enumerated().map { index, name in
            StripReading(lcdName: name, valueText: values?[index] ?? (name.isEmpty ? "" : "0"),
                         valueRaw: "", fader: 12443, mute: .off, solo: .off, recArm: .off)
        })
    }

    @Test func oneStripShift() {
        let old = page(["a", "b", "c", "d", "e", "f", "g", "h"])
        #expect(MixerController.classify(old: old, new: page(["b", "c", "d", "e", "f", "g", "h", "i"])) == .shifted)
        #expect(MixerController.classify(old: old, new: page(["b", "c", "d", "e", "f", "g", "h", ""])) == .shifted)
        #expect(MixerController.classify(old: old, new: old) == .unchanged)
        #expect(MixerController.classify(old: old, new: page(["c", "d", "e", "f", "g", "h", "i", "j"])) == .unexpected)
    }

    @Test func stripKeysIgnoreUnknownFields() {
        var shown = page(["a", "b"] + Array(repeating: "", count: 6), values: ["-1.2 dB", "", "0", "0", "0", "0", "0", "0"])
        shown.strips[0].valueRaw = "-1.2 dB "
        let keys = shown.keys
        // dB text in strip 1 covers the start of strip 2's lower cell: neither value counts.
        #expect(keys[0].value == nil && keys[1].value == nil && keys[2].value == "0")
        let scanned = page(["a", "b"] + Array(repeating: "", count: 6), values: ["+3", "-5", "0", "0", "0", "0", "0", "0"]).keys
        #expect(StripKey.matches(keys, scanned))
        var other = scanned
        other[2].value = "+1"
        #expect(!StripKey.matches(keys, other))
        var flashing = scanned
        flashing[3].mute = nil
        #expect(StripKey.matches(flashing, scanned))
        var faded = scanned
        faded[4].fader = 100
        #expect(!StripKey.matches(faded, scanned))
    }

    @Test func identicalNamesUseValues() {
        let names = Array(repeating: "Audio", count: 8)
        let old = page(names, values: ["0", "+1", "+2", "+3", "+4", "+5", "+6", "+7"])
        #expect(MixerController.classify(old: old, new: page(names, values: ["+1", "+2", "+3", "+4", "+5", "+6", "+7", "+8"])) == .shifted)
        #expect(MixerController.classify(old: old, new: old) == .unchanged)
        let flat = page(names)
        #expect(MixerController.classify(old: flat, new: flat) == .unchangedIdentical)
    }
}
