import Foundation

/// Full track names read from outside Mackie Control (Accessibility, in the real server).
public struct TrackNameList: Sendable, Equatable {
    /// Names top to bottom as listed, or nil when they could not be read.
    public var names: [String]?
    /// Why `names` is nil (e.g. Accessibility not granted).
    public var failure: String?
    /// Caveats, e.g. "traversal stopped at the node limit".
    public var notes: [String]

    public init(names: [String]?, failure: String? = nil, notes: [String] = []) {
        self.names = names
        self.failure = failure
        self.notes = notes
    }

    public static func unavailable(_ reason: String) -> TrackNameList {
        TrackNameList(names: nil, failure: reason)
    }
}

/// Where full track names come from. The real server reads Logic's track headers through
/// Accessibility (LogicAX); tests and `serve --fake` use fakes.
public protocol TrackNameSource: Sendable {
    func trackNames() async -> TrackNameList
}

/// A `TrackNameSource` backed by a closure.
public struct ClosureTrackNameSource: TrackNameSource {
    private let read: @Sendable () async -> TrackNameList
    public init(_ read: @escaping @Sendable () async -> TrackNameList) { self.read = read }
    public func trackNames() async -> TrackNameList { await read() }
}

/// Name for one track after combining the LCD scan with full names.
public struct ResolvedTrackName: Sendable, Equatable {
    public enum Source: String, Sendable, Codable { case accessibility, lcd }
    public var name: String
    public var source: Source
    /// The full name from Accessibility, when one was matched to this track.
    public var fullName: String?
}

public enum TrackNameMerge {
    /// What Logic's Mackie LCD shows for a full name by the observed rule: non-ASCII characters
    /// dropped, spaces trimmed, first 6 characters, trimmed again. Observed on Logic 13:
    /// "Inst 1" → "Inst 1", "オーディオ 1" → "1". Longer ASCII names are not observed yet
    /// (checklist C3, C7).
    public static func lcdKey(_ fullName: String) -> String {
        let ascii = String(String.UnicodeScalarView(fullName.unicodeScalars.filter { $0.value >= 0x20 && $0.value < 0x7F }))
        let trimmed = ascii.trimmingCharacters(in: .whitespaces)
        return String(trimmed.prefix(6)).trimmingCharacters(in: .whitespaces)
    }

    /// Every LCD form accepted for a full name: the observed drop rule (`lcdKey`) and, as an
    /// unobserved alternative, the same after converting accented letters to their base letter
    /// and curly quotes to straight ones ("Café" → "Caf" or "Cafe"). Assumption until checklist
    /// C4/C6 shows which one Logic 13 uses.
    public static func lcdForms(_ fullName: String) -> [String] {
        let dropped = lcdKey(fullName)
        let folded = lcdKey(fullName
            .replacingOccurrences(of: "\u{2018}", with: "'")
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{201C}", with: "\"")
            .replacingOccurrences(of: "\u{201D}", with: "\"")
            .folding(options: [.diacriticInsensitive], locale: nil))
        return dropped == folded ? [dropped] : [dropped, folded]
    }

    /// True when `lcd` is one of the LCD forms of `fullName`.
    public static func matchesLCD(_ fullName: String, _ lcd: String) -> Bool {
        lcdForms(fullName).contains(lcd)
    }

    /// Combines LCD names (one per track, in surface order) with full names.
    ///
    /// Full names are used only where they line up with the LCD by position **and** pass the
    /// `lcdForms` rule. When Accessibility lists fewer names (tracks scrolled out of view) they are
    /// placed at the single offset where every name matches; with no or several such offsets
    /// nothing is guessed. Every fallback is reported in the warnings.
    public static func merge(lcd: [String], full: TrackNameList) -> (names: [ResolvedTrackName], warnings: [String]) {
        var resolved = lcd.map { ResolvedTrackName(name: $0, source: .lcd, fullName: nil) }
        var warnings = full.notes
        guard let names = full.names else {
            warnings.append("Full track names unavailable (\(full.failure ?? "no reason given")). Names are the Mackie LCD abbreviations: at most 6 ASCII characters, non-ASCII characters are not shown.")
            return (resolved, warnings)
        }
        guard !lcd.isEmpty else { return (resolved, warnings) }
        func fits(_ name: Int, _ track: Int) -> Bool { matchesLCD(names[name], lcd[track]) }

        var offset: Int?
        if names.count == lcd.count {
            offset = 0
        } else if names.count < lcd.count, !names.isEmpty {
            let candidates = (0...(lcd.count - names.count)).filter { start in
                names.indices.allSatisfy { fits($0, start + $0) }
            }
            if candidates.count == 1 {
                offset = candidates[0]
                warnings.append("Accessibility listed \(names.count) of the \(lcd.count) tracks on the surface (tracks scrolled out of view in Logic's main window are usually missing); matched them to tracks \(candidates[0] + 1)–\(candidates[0] + names.count). The other tracks use LCD names.")
            } else {
                warnings.append("Accessibility listed \(names.count) names for \(lcd.count) tracks on the surface and they fit \(candidates.isEmpty ? "no" : "\(candidates.count)") positions, so none were used. Scroll Logic's track list so all tracks are visible, or use the LCD names.")
            }
        } else if names.count > lcd.count {
            let candidates = (0...(names.count - lcd.count)).filter { start in
                lcd.indices.allSatisfy { fits(start + $0, $0) }
            }
            warnings.append("Accessibility listed \(names.count) names but the surface shows \(lcd.count) tracks.")
            if candidates.count == 1 {
                // Surface tracks are a contiguous run of the listed names.
                for index in lcd.indices {
                    resolved[index] = ResolvedTrackName(name: names[candidates[0] + index], source: .accessibility, fullName: names[candidates[0] + index])
                }
                warnings.append("Matched the surface tracks to Accessibility names \(candidates[0] + 1)–\(candidates[0] + lcd.count).")
            } else {
                warnings.append("Could not line them up, so LCD names are used.")
            }
            return (resolved, warnings)
        }

        guard let offset else { return (resolved, warnings) }
        var mismatches: [String] = []
        for (index, name) in names.enumerated() {
            let track = offset + index
            if fits(index, track) {
                resolved[track] = ResolvedTrackName(name: name, source: .accessibility, fullName: name)
            } else {
                mismatches.append("track \(track + 1): LCD \(ProjectText.quoted(lcd[track])), Accessibility \(ProjectText.quoted(name))")
            }
        }
        if !mismatches.isEmpty {
            warnings.append("Full names that do not match the LCD were not used (\(mismatches.count)): " + mismatches.joined(separator: "; ") + ". Those tracks use LCD names.")
        }
        return (resolved, warnings)
    }

    public enum NameCheck: Equatable, Sendable {
        /// Matches the full (Accessibility) name.
        case matchesFullName
        /// No full name for this track; `expected` reduces to the (non-blank) LCD name.
        case matchesLCDOnly
        /// No full name, and the LCD cannot tell: the track's LCD name is blank and `expected`
        /// would show blank too (only non-ASCII characters). Callers treat this as a failure.
        case uncheckable(String)
        case mismatch(String)
    }

    /// Checks a caller's expected name for a track before anything is changed.
    /// With a full name the comparison is exact (after trimming spaces); without one, only the
    /// LCD forms of `expected` can be compared, and a blank LCD name proves nothing.
    public static func check(expected: String, lcdName: String, fullName: String?) -> NameCheck {
        let wanted = expected.trimmingCharacters(in: .whitespacesAndNewlines)
        if let fullName {
            if fullName.trimmingCharacters(in: .whitespacesAndNewlines) == wanted { return .matchesFullName }
            return .mismatch("expected \"\(wanted)\" but the track is \(ProjectText.quoted(fullName))")
        }
        let forms = lcdForms(wanted)
        if lcdName.isEmpty, forms.contains("") {
            return .uncheckable("the track's LCD name is blank and \"\(wanted)\" has no ASCII characters that the LCD would show, so the two cannot be compared; checking such names needs the full track names from Accessibility (docs/setup/02-phase2-accessibility.md)")
        }
        if forms.contains(lcdName) { return .matchesLCDOnly }
        return .mismatch("expected \"\(wanted)\" (LCD form \"\(forms[0])\") but the surface shows \(ProjectText.quoted(lcdName))")
    }
}
