import MIDICore

/// Phase 3: Logic key commands triggered through controller assignments (design §3.7).
///
/// The server sends Control Change `controller` with value 127 on MIDI channel 16 on the
/// `LogicMCP Keys` port. Logic runs a key command for it once the user has taught Logic the
/// mapping with Key Commands > Learn New Assignment, see
/// docs/setup/03-phase3-commands.md. Logic gives no execution feedback for key commands
/// (research §3.3), so each command says how its effect can be seen on the Mackie Control
/// surface, if at all.
///
/// The catalog is a Swift table (`CommandCatalog`) rather than a JSON resource: there is no
/// resource bundle to locate at run time (a SwiftPM `Bundle.module` lookup fails when the binary
/// is moved away from its build directory), and the compiler checks every field. Tests check
/// that ids and controller numbers are unique and in range.
///
/// Differences from design §3.2 / §3.7 as written (design.md is not updated here): the catalog is
/// this Swift table, not `Resources/commands.json`; triggers are on MIDI channel 16
/// (`BF <cc> 7F`), not channel 1 (`B0 14 7F`); the confirmation parameter is
/// `confirmation_token`, as for the other tools; there is a third tool, `learn_command`, instead
/// of `logic-mcp setup-commands`; and Logic does not report which commands it has learned, so
/// `list_commands` shows the last run that sent each trigger (`last_run`) instead of a
/// "learned" flag.
public struct LogicCommand: Sendable, Hashable, Identifiable, CustomStringConvertible {
    /// Kebab-case identifier used by the tools and the console, e.g. "new-audio-track".
    public let id: String
    /// The key command's name in Logic's Key Commands window, English UI.
    public let englishName: String
    /// The name in Logic's Japanese UI. Empty unless it was seen on this Mac's Logic 13.
    public let japaneseName: String
    /// Words likely to appear in the Japanese name, to type into the Key Commands window's search
    /// field. Unverified guesses; never shown as the command's name.
    public let japaneseKeywords: [String]
    /// Control Change number on MIDI channel 16 (20–63; never 0–19 or 64–127).
    public let controller: UInt8
    /// Needs the user's explicit confirmation before it is sent (design §4.1).
    public let destructive: Bool
    /// Why it is destructive (shown in the confirmation question); nil when it is not.
    public let confirmationReason: String?
    /// How its effect can be confirmed from Logic's Mackie Control output.
    public let verification: CommandVerification
    /// What happens when it is run while Logic is playing.
    public let whilePlaying: PlaybackPolicy
    /// The command may add, remove or reorder tracks. Required for track-count checks; the
    /// controller drops the mixer's cached track list after every trigger anyway, since a CC may
    /// be learned for a different command in Logic.
    public let affectsTrackList: Bool
    /// One-sentence description of what Logic does.
    public let summary: String
    /// Caveats that the tools report with every run.
    public let notes: [String]

    public init(
        id: String, englishName: String, japaneseName: String = "", japaneseKeywords: [String] = [],
        controller: UInt8, destructive: Bool = false, confirmationReason: String? = nil,
        verification: CommandVerification, whilePlaying: PlaybackPolicy = .allowed,
        affectsTrackList: Bool = false, summary: String, notes: [String] = []
    ) {
        self.id = id
        self.englishName = englishName
        self.japaneseName = japaneseName
        self.japaneseKeywords = japaneseKeywords
        self.controller = controller
        self.destructive = destructive
        self.confirmationReason = confirmationReason
        self.verification = verification
        self.whilePlaying = whilePlaying
        self.affectsTrackList = affectsTrackList
        self.summary = summary
        self.notes = notes
    }

    /// MIDI channel 16 (0-based 15).
    public static let channel: UInt8 = 15
    public static let triggerValue: UInt8 = 0x7F

    /// The trigger: `B F <controller> 7F`.
    public var message: MIDIMessage {
        .controlChange(channel: Self.channel, controller: controller, value: Self.triggerValue)
    }

    /// The name to look for in Logic's Japanese UI, or nil when it has not been seen.
    public var verifiedJapaneseName: String? { japaneseName.isEmpty ? nil : japaneseName }

    /// True when `run_command` can send it (false for commands that open a dialog).
    public var runnable: Bool {
        if case .notRunnable = verification { return false }
        return true
    }

    public var description: String { "\(id) (CC \(controller), \(englishName))" }

    public static func == (lhs: LogicCommand, rhs: LogicCommand) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// How the effect of a key command is confirmed. Only Mackie Control feedback counts.
public enum CommandVerification: Sendable, Hashable {
    /// The track count read by a full track scan changes by `change` (+1 new, −1 delete).
    case trackCount(change: Int)
    /// A transport-section LED of the Mackie Control surface toggles.
    case surfaceLED(SurfaceLED)
    /// The position on the time display (Beats mode) moves; only while Logic is stopped.
    case playhead(PlayheadMove)
    /// No feedback channel: the result is always "unverified".
    case none
    /// `run_command` refuses it (it can still be learned): e.g. it opens a dialog that the
    /// server cannot operate.
    case notRunnable(reason: String)

    /// Short machine-readable name for listings.
    public var kind: String {
        switch self {
        case .trackCount: return "track_count"
        case .surfaceLED(let led): return "\(led.rawValue)_led"
        case .playhead: return "time_display"
        case .none: return "none"
        case .notRunnable: return "not_runnable"
        }
    }

    public var canVerify: Bool {
        switch self {
        case .trackCount, .surfaceLED, .playhead: return true
        case .none, .notRunnable: return false
        }
    }
}

/// Mackie Control transport-section LEDs a key command can toggle (note numbers in LogicBridge).
public enum SurfaceLED: String, Sendable, Hashable, CaseIterable {
    /// Cycle, note 0x56.
    case cycle
    /// Click (metronome), note 0x59.
    case click
}

public enum PlayheadMove: String, Sendable, Hashable {
    /// To 1 1 1 1.
    case toBeginning
    /// One bar later.
    case forwardOneBar
    /// One bar earlier (or back to the start of the current bar).
    case rewindOneBar
}

public enum PlaybackPolicy: String, Sendable, Hashable {
    /// Runs and is verified the same way while playing.
    case allowed
    /// Runs while playing, but the result is "unverified": the time display moves anyway.
    case unverifiedWhilePlaying = "unverified_while_playing"
}
