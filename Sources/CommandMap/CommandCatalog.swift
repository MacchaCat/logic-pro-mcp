/// The commands the server can trigger. Controller numbers are permanent once a user has learned
/// them: never renumber an entry, only add new ones (next free: CC 40).
///
/// CC 20–22 were learned on real Logic 13 in Phase 1 (docs/checklists/phase-1-results.md); the
/// rest continue from 23. CC 20–31 are undefined in the MIDI 1.0 spec; 32–39 are the LSBs of
/// CC 0–7 (bank select, modulation, …, volume). They only reach Logic as ordinary MIDI input when
/// a command is sent before it has been learned.
///
/// Japanese names are the rows seen in Logic 13's Japanese Key Commands window on this Mac
/// (CC 20–22 in Phase 1, CC 23–39 on 2026-11-21: docs/checklists/phase-3-results.md). English
/// names follow Apple's Logic Pro key command reference (checked against its Japanese edition)
/// and are not yet checked on an English-UI Logic.
extension LogicCommand {
    public static let goToPosition = LogicCommand(
        id: "go-to-position", englishName: "Go to Position…", japaneseName: "位置を指定して移動…",
        controller: 20,
        verification: .notRunnable(reason: "It opens Logic's Go to Position dialog, which the server cannot confirm (on Logic 13 the Mackie Enter key did not press OK). Use the transport tool's locate instead."),
        summary: "Opens the Go to Position dialog.")

    public static let goToBeginning = LogicCommand(
        id: "go-to-beginning", englishName: "Go to Beginning", japaneseName: "先頭に移動",
        controller: 21, verification: .playhead(.toBeginning), whilePlaying: .unverifiedWhilePlaying,
        summary: "Moves the playhead to the beginning of the project (1 1 1 1).")

    public static let forwardOneBar = LogicCommand(
        id: "forward-one-bar", englishName: "Forward", japaneseName: "早送り",
        controller: 22, verification: .playhead(.forwardOneBar), whilePlaying: .unverifiedWhilePlaying,
        summary: "Moves the playhead one bar later.")

    public static let rewindOneBar = LogicCommand(
        id: "rewind-one-bar", englishName: "Rewind", japaneseName: "早戻し",
        controller: 23, verification: .playhead(.rewindOneBar), whilePlaying: .unverifiedWhilePlaying,
        summary: "Moves the playhead one bar earlier.")

    public static let undo = LogicCommand(
        id: "undo", englishName: "Undo", japaneseName: "取り消す",
        controller: 24, verification: .none, affectsTrackList: true,
        summary: "Undoes the most recent edit in Logic's undo history.",
        notes: ["Undo reverts Logic's most recent edit, whoever made it (possibly the user, not Claude). Logic's Edit menu names the edit that will be undone."])

    public static let redo = LogicCommand(
        id: "redo", englishName: "Redo", japaneseName: "やり直す",
        controller: 25, verification: .none, affectsTrackList: true,
        summary: "Redoes the most recently undone edit.")

    public static let newAudioTrack = LogicCommand(
        id: "new-audio-track", englishName: "New Audio Track",
        japaneseName: "新規オーディオトラック",
        controller: 26, verification: .trackCount(change: 1), affectsTrackList: true,
        summary: "Creates a new audio track below the selected track.")

    public static let newSoftwareInstrumentTrack = LogicCommand(
        id: "new-software-instrument-track", englishName: "New Software Instrument Track",
        japaneseName: "新規ソフトウェア音源トラック",
        controller: 27, verification: .trackCount(change: 1), affectsTrackList: true,
        summary: "Creates a new software instrument track below the selected track.",
        notes: ["On Logic 13 no dialog, Library or instrument window opened; key focus stayed in the Tracks area (2026-11-21)."])

    public static let duplicateTrack = LogicCommand(
        id: "duplicate-track", englishName: "New Track with Duplicate Settings",
        japaneseName: "設定の複製を使った新規トラック",
        controller: 28, verification: .trackCount(change: 1), affectsTrackList: true,
        summary: "Creates a new track below the selected one with the same channel strip settings (regions are not copied).")

    public static let deleteTrack = LogicCommand(
        id: "delete-track", englishName: "Delete Track", japaneseName: "トラックを削除",
        controller: 29, destructive: true,
        confirmationReason: "Delete Track removes the track(s) currently selected in Logic, with their regions. The server cannot see which track is selected.",
        verification: .trackCount(change: -1), affectsTrackList: true,
        summary: "Deletes the selected track(s).")

    public static let save = LogicCommand(
        id: "save", englishName: "Save", japaneseName: "保存",
        controller: 30, destructive: true,
        confirmationReason: "Save overwrites the project file on disk; that cannot be undone.",
        verification: .none,
        summary: "Saves the project.",
        notes: ["Logic gives no feedback for saving. If the project has never been saved, Logic probably opens its Save dialog instead; close it in Logic before using other tools."])

    public static let toggleCycle = LogicCommand(
        id: "toggle-cycle", englishName: "Toggle Cycle Mode", japaneseName: "サイクルモードを切り替え",
        controller: 31, verification: .surfaceLED(.cycle),
        summary: "Turns Cycle mode on or off.")

    public static let toggleMetronome = LogicCommand(
        id: "toggle-metronome", englishName: "Toggle Metronome Click", japaneseName: "メトロノームクリックを切り替え",
        controller: 32, verification: .surfaceLED(.click),
        summary: "Turns the metronome click on or off.")

    public static let toggleCountIn = LogicCommand(
        id: "toggle-count-in", englishName: "Toggle Count-in", japaneseName: "カウントインを切り替え",
        controller: 33, verification: .none,
        summary: "Turns the recording count-in on or off.",
        notes: ["Mackie Control has no count-in LED, so the new state cannot be read; check Logic's control bar."])

    public static let createMarker = LogicCommand(
        id: "create-marker", englishName: "Create Marker", japaneseName: "マーカーを作成",
        controller: 34, verification: .none,
        summary: "Creates a marker at the playhead position.")

    public static let quantizeSelection = LogicCommand(
        id: "quantize-selection", englishName: "Quantize Selected Regions/Cells/Events", japaneseName: "選択したリージョン/セル/イベントをクオンタイズ",
        controller: 35, destructive: true,
        confirmationReason: "Quantize rewrites the timing of whatever is selected in the Logic window with key focus (regions or notes). The server cannot see the selection or the result; Undo can revert it.",
        verification: .none,
        summary: "Quantizes the selected regions or notes with their current quantize setting.")

    public static let selectAll = LogicCommand(
        id: "select-all", englishName: "Select All", japaneseName: "すべてを選択",
        controller: 36, verification: .none,
        summary: "Selects everything in the Logic window with key focus (e.g. all regions in the Tracks area).")

    public static let showHideMixer = LogicCommand(
        id: "show-hide-mixer", englishName: "Show/Hide Mixer", japaneseName: "ミキサーを表示/非表示",
        controller: 37, verification: .none,
        summary: "Shows or hides the Mixer in the main window.",
        notes: ["Showing the Mixer may move key focus to it, which changes what later key commands act on."])

    public static let showHidePianoRoll = LogicCommand(
        id: "show-hide-piano-roll", englishName: "Show/Hide Piano Roll", japaneseName: "ピアノロールを表示/非表示",
        controller: 38, verification: .none,
        summary: "Shows or hides the Piano Roll editor in the main window.",
        notes: ["Showing the Piano Roll may move key focus to it, which changes what later key commands act on."])

    public static let zoomToFit = LogicCommand(
        id: "zoom-to-fit", englishName: "Toggle Zoom to Fit Selection or All Contents", japaneseName: "ズームして選択部分またはすべてのコンテンツのどちらにサイズを合わせるかを切り替え",
        controller: 39, verification: .none,
        summary: "Toggles the zoom of the window with key focus: fits the selection (or all content), and running it again returns to the previous zoom.")
}

public enum CommandCatalog {
    /// Every command, in listing order.
    public static let all: [LogicCommand] = [
        .goToBeginning, .forwardOneBar, .rewindOneBar, .goToPosition,
        .undo, .redo,
        .newAudioTrack, .newSoftwareInstrumentTrack, .duplicateTrack, .deleteTrack,
        .save,
        .toggleCycle, .toggleMetronome, .toggleCountIn,
        .createMarker, .quantizeSelection, .selectAll,
        .showHideMixer, .showHidePianoRoll, .zoomToFit,
    ]

    /// Controllers the catalog may use: CC 20–63. 0–19 hold bank select, modulation, volume, pan
    /// and other controllers instruments react to; 64–127 hold pedals, sound controllers,
    /// RPN/NRPN and channel mode messages.
    public static let allowedControllers: ClosedRange<UInt8> = 20...63

    public static func command(id: String) -> LogicCommand? {
        all.first { $0.id == id }
    }

    public static func command(controller: UInt8) -> LogicCommand? {
        all.first { $0.controller == controller }
    }

    /// Everything wrong with a catalog; empty when it is consistent.
    public static func problems(in commands: [LogicCommand]) -> [String] {
        var problems: [String] = []
        var ids: Set<String> = []
        var controllers: [UInt8: String] = [:]
        for command in commands {
            if !ids.insert(command.id).inserted { problems.append("duplicate id \(command.id)") }
            if !isKebabCase(command.id) { problems.append("\(command.id): id is not kebab-case") }
            if let other = controllers[command.controller] {
                problems.append("\(command.id): CC \(command.controller) is already used by \(other)")
            }
            controllers[command.controller] = command.id
            if !allowedControllers.contains(command.controller) {
                problems.append("\(command.id): CC \(command.controller) is outside \(allowedControllers)")
            }
            if command.englishName.isEmpty { problems.append("\(command.id): no English name") }
            if command.summary.isEmpty { problems.append("\(command.id): no summary") }
            if command.destructive != (command.confirmationReason != nil) {
                problems.append("\(command.id): destructive commands need a confirmation reason, others none")
            }
            if case .trackCount(let change) = command.verification {
                if change == 0 { problems.append("\(command.id): a track-count check needs a non-zero change") }
                if !command.affectsTrackList { problems.append("\(command.id): changes the track count but not marked affectsTrackList") }
            }
            if case .playhead = command.verification, command.whilePlaying != .unverifiedWhilePlaying {
                problems.append("\(command.id): the time display cannot verify a move during playback")
            }
        }
        return problems
    }

    static func isKebabCase(_ id: String) -> Bool {
        let parts = id.split(separator: "-", omittingEmptySubsequences: false)
        return !parts.isEmpty && parts.allSatisfy { part in
            !part.isEmpty && part.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) }
        }
    }
}
