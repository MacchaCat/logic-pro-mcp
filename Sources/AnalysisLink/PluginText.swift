/// Rules for the text a plug-in sends (channel name, version). That text is untrusted: any local
/// process can connect and send frames, and what the server stores ends up in tool results the
/// model reads. So the text is cut down to a conservative character set and a short length, by
/// the plug-in before sending (`FrameBuilder`) and again by the server before it stores or shows
/// anything (`AnalysisController`), and the server only ever puts it into fields named
/// `plugin_reported_*`, never into summary, evidence, warning or note prose.
///
/// Instance ids need no cleaning: `AnalysisFrame.validate()` already limits them to 8-40
/// characters of hex digits and "-" (frames with other ids are rejected).
public enum PluginText {
    public static let maxContextNameCharacters = 40
    public static let maxContextNameBytes = 128
    public static let maxVersionLength = 16

    /// Punctuation kept in channel names besides letters, digits and spaces.
    static let contextNamePunctuation: Set<Unicode.Scalar> = [
        "-", "_", ".", ",", "(", ")", "+", "&", "#", "/", ":", "\u{30FB}",  // U+30FB katakana middle dot
    ]

    /// `name` reduced to letters and digits of any script (so Japanese channel names stay
    /// readable and selectable), combining marks, single spaces and `- _ . , ( ) + & # / :` and
    /// the katakana middle dot; everything else (quotes, brackets, backticks, angle brackets, other
    /// symbols, emoji, control and format characters) is dropped. Then cut on a character boundary
    /// to at most 40 characters and 128 UTF-8 bytes. nil when nothing remains.
    public static func contextName(_ name: String?) -> String? {
        guard let name else { return nil }
        var scalars = String.UnicodeScalarView()
        var pendingSpace = false
        for scalar in name.unicodeScalars.prefix(4096) {
            if scalar.properties.isWhitespace {
                pendingSpace = !scalars.isEmpty
                continue
            }
            guard isAllowedInContextName(scalar) else { continue }
            if pendingSpace {
                scalars.append(" ")
                pendingSpace = false
            }
            scalars.append(scalar)
        }
        var result = ""
        var characters = 0
        var bytes = 0
        for character in String(scalars) {
            let size = character.utf8.count
            guard characters < maxContextNameCharacters, bytes + size <= maxContextNameBytes else { break }
            result.append(character)
            characters += 1
            bytes += size
        }
        while result.last == " " { result.removeLast() }
        return result.isEmpty ? nil : result
    }

    /// True when `name` already satisfies the rules (`contextName(name) == name`).
    public static func isCleanContextName(_ name: String) -> Bool {
        contextName(name) == name
    }

    static func isAllowedInContextName(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
             .nonspacingMark, .spacingMark, .decimalNumber:
            return true
        default:
            return contextNamePunctuation.contains(scalar)
        }
    }

    /// `version` if it is 1-16 characters of A-Z a-z 0-9 . + _ - (nil otherwise).
    public static func pluginVersion(_ version: String?) -> String? {
        guard let version, (1...maxVersionLength).contains(version.utf8.count),
              version.unicodeScalars.allSatisfy({ isASCIIAlphanumeric($0) || ".+_-".unicodeScalars.contains($0) })
        else { return nil }
        return version
    }

    static func isASCIIAlphanumeric(_ scalar: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar) || ("0"..."9").contains(scalar)
    }
}
