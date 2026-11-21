/// Text that comes from the user's Logic project (track names read over Accessibility or from
/// the LCD) and is quoted inside result prose (summaries, evidence, warnings). Such text is
/// untrusted: a project from someone else can carry anything in a track name. Prose therefore
/// gets a short, single-line, quoted form; the exact name stays in the structured fields.
public enum ProjectText {
    /// Longest name shown in prose, in characters.
    public static let proseLimit = 40

    /// `"name"` with control, format (e.g. bidi override) and line/paragraph separator
    /// characters replaced by spaces, double quotes by single ones (so the quoted span cannot
    /// end early), and at most `limit` characters (then "…"). Ordinary names come out unchanged.
    public static func quoted(_ name: String, limit: Int = proseLimit) -> String {
        "\"" + clean(name, limit: limit) + "\""
    }

    static func clean(_ name: String, limit: Int) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in name.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator, .privateUse, .unassigned:
                scalars.append(" ")
            default:
                scalars.append(scalar == "\"" ? "'" : scalar)
            }
        }
        let text = String(scalars)
        guard text.count > limit else { return text }
        return String(text.prefix(max(limit - 1, 0))) + "…"
    }
}
