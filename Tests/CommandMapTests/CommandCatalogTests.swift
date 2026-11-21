import MIDICore
import Testing
@testable import CommandMap

@Suite("Command catalog")
struct CommandCatalogTests {
    let all = CommandCatalog.all

    @Test func catalogIsConsistent() {
        #expect(CommandCatalog.problems(in: all) == [])
    }

    @Test func idsAndControllersAreUnique() {
        #expect(Set(all.map(\.id)).count == all.count)
        #expect(Set(all.map(\.controller)).count == all.count)
    }

    @Test func controllersStayOutOfReservedRanges() {
        for command in all {
            #expect(command.controller >= 20, "\(command.id)")
            #expect(command.controller < 64, "\(command.id)")
        }
    }

    @Test func phase1ControllersAreUnchanged() {
        // Learned on real Logic 13 (phase-1-results); renumbering would break the user's setup.
        #expect(LogicCommand.goToPosition.controller == 20)
        #expect(LogicCommand.goToBeginning.controller == 21)
        #expect(LogicCommand.forwardOneBar.controller == 22)
        #expect(CommandCatalog.command(id: "go-to-position") == .goToPosition)
        #expect(CommandCatalog.command(controller: 21) == .goToBeginning)
    }

    @Test func newControllersContinueFrom23() {
        let added = all.map(\.controller).filter { $0 > 22 }.sorted()
        #expect(added == Array(23...UInt8(22 + added.count)))
    }

    @Test func requiredCommandsArePresent() {
        let required = [
            "go-to-beginning", "forward-one-bar", "rewind-one-bar", "go-to-position", "undo", "redo",
            "new-audio-track", "new-software-instrument-track", "delete-track", "duplicate-track", "save",
            "toggle-cycle", "toggle-metronome", "toggle-count-in", "create-marker", "quantize-selection",
            "select-all",
        ]
        for id in required { #expect(CommandCatalog.command(id: id) != nil, "\(id)") }
        #expect((18...24).contains(all.count))
    }

    @Test func japaneseNamesOnlyWhereObserved() {
        // Seen in Logic 13's Japanese Key Commands window: CC 20–22 in Phase 1
        // (docs/setup/01-phase1-logic-setup.md §6), CC 23–39 on 2026-11-21
        // (docs/checklists/phase-3-results.md).
        let observed = [
            "go-to-position": "位置を指定して移動…", "go-to-beginning": "先頭に移動", "forward-one-bar": "早送り",
            "rewind-one-bar": "早戻し", "undo": "取り消す", "redo": "やり直す",
            "new-audio-track": "新規オーディオトラック", "new-software-instrument-track": "新規ソフトウェア音源トラック",
            "duplicate-track": "設定の複製を使った新規トラック", "delete-track": "トラックを削除", "save": "保存",
            "toggle-cycle": "サイクルモードを切り替え", "toggle-metronome": "メトロノームクリックを切り替え",
            "toggle-count-in": "カウントインを切り替え", "create-marker": "マーカーを作成",
            "quantize-selection": "選択したリージョン/セル/イベントをクオンタイズ", "select-all": "すべてを選択",
            "show-hide-mixer": "ミキサーを表示/非表示", "show-hide-piano-roll": "ピアノロールを表示/非表示",
            "zoom-to-fit": "ズームして選択部分またはすべてのコンテンツのどちらにサイズを合わせるかを切り替え",
        ]
        for command in all {
            #expect(command.verifiedJapaneseName == observed[command.id], "\(command.id)")
        }
    }

    @Test func destructiveCommands() {
        #expect(Set(all.filter(\.destructive).map(\.id)) == ["delete-track", "save", "quantize-selection"])
        for command in all where command.destructive {
            #expect(command.confirmationReason?.isEmpty == false)
        }
    }

    @Test func verificationKinds() {
        func kind(_ id: String) -> String? { CommandCatalog.command(id: id)?.verification.kind }
        #expect(kind("new-audio-track") == "track_count")
        #expect(kind("new-software-instrument-track") == "track_count")
        #expect(kind("duplicate-track") == "track_count")
        #expect(kind("delete-track") == "track_count")
        #expect(kind("toggle-cycle") == "cycle_led")
        #expect(kind("toggle-metronome") == "click_led")
        #expect(kind("go-to-beginning") == "time_display")
        #expect(kind("forward-one-bar") == "time_display")
        #expect(kind("rewind-one-bar") == "time_display")
        for id in ["undo", "redo", "select-all", "quantize-selection", "save", "toggle-count-in", "create-marker"] {
            #expect(kind(id) == "none", "\(id)")
        }
        #expect(LogicCommand.deleteTrack.verification == .trackCount(change: -1))
        #expect(LogicCommand.newAudioTrack.verification == .trackCount(change: 1))
        #expect(LogicCommand.goToPosition.runnable == false)
        #expect(all.filter { !$0.runnable }.map(\.id) == ["go-to-position"])
    }

    @Test func playheadCommandsAreUnverifiedWhilePlaying() {
        for command in all {
            if case .playhead = command.verification {
                #expect(command.whilePlaying == .unverifiedWhilePlaying)
            } else {
                #expect(command.whilePlaying == .allowed)
            }
        }
    }

    @Test func triggerMessage() {
        #expect(LogicCommand.goToPosition.message == .controlChange(channel: 15, controller: 20, value: 127))
        #expect(LogicCommand.goToPosition.message.bytes.hexString == "BF 14 7F")
        #expect(LogicCommand.newAudioTrack.message.bytes.hexString == "BF 1A 7F")
    }

    @Test func validationFindsProblems() {
        let bad = [
            LogicCommand(id: "a", englishName: "A", controller: 20, verification: .none, summary: "x"),
            LogicCommand(id: "a", englishName: "B", controller: 20, verification: .none, summary: "x"),
            LogicCommand(id: "Bad_Id", englishName: "", controller: 64, verification: .none, summary: "x"),
            LogicCommand(id: "low", englishName: "Low", controller: 7, destructive: true, verification: .trackCount(change: 0), summary: "x"),
        ]
        let problems = CommandCatalog.problems(in: bad)
        #expect(problems.contains("duplicate id a"))
        #expect(problems.contains { $0.contains("CC 20 is already used by a") })
        #expect(problems.contains { $0.contains("Bad_Id: id is not kebab-case") })
        #expect(problems.contains { $0.contains("Bad_Id: CC 64 is outside") })
        #expect(problems.contains { $0.contains("low: CC 7 is outside") })
        #expect(problems.contains { $0.contains("Bad_Id: no English name") })
        #expect(problems.contains { $0.contains("low: destructive commands need a confirmation reason") })
        #expect(problems.contains { $0.contains("low: a track-count check needs a non-zero change") })
        #expect(problems.contains { $0.contains("low: changes the track count but not marked affectsTrackList") })
    }

    @Test func kebabCase() {
        #expect(CommandCatalog.isKebabCase("new-audio-track"))
        #expect(CommandCatalog.isKebabCase("undo"))
        #expect(!CommandCatalog.isKebabCase("-undo"))
        #expect(!CommandCatalog.isKebabCase("undo-"))
        #expect(!CommandCatalog.isKebabCase("un--do"))
        #expect(!CommandCatalog.isKebabCase("Undo"))
        #expect(!CommandCatalog.isKebabCase(""))
    }
}

@Suite("Learn guide")
struct LearnGuideTests {
    @Test func observedNameIsSearchedDirectly() {
        let row = LearnGuide.findRow(.goToBeginning)
        #expect(row.contains("“Go to Beginning”"))
        #expect(row.contains("“先頭に移動”"))
        #expect(!row.contains("unverified"))
    }

    @Test func unconfirmedNamesAreMarkedAsGuesses() {
        // Every catalog command has an observed name now; a future one may not.
        let unconfirmed = LogicCommand(
            id: "future-command", englishName: "Delete Track", japaneseKeywords: ["削除"],
            controller: 40, verification: .none, summary: "Test only.")
        let row = LearnGuide.findRow(unconfirmed)
        #expect(row.contains("unverified"))
        #expect(row.contains("“削除”"))
        #expect(row.contains("Delete Track"))
    }

    @Test func stepsNameTheEnglishMenusAndTheController() {
        let steps = LearnGuide.steps(.newAudioTrack, sendStep: "SEND")
        let text = steps.joined(separator: "\n")
        #expect(text.contains("Logic Pro > Key Commands > Edit Assignments…"))
        #expect(text.contains("Learn New Assignment"))
        #expect(text.contains("Click the row first to select it"))
        #expect(text.contains("Logic Pro > Control Surfaces > Controller Assignments…"))
        #expect(text.contains("CC 26 (127)"))
        #expect(steps.firstIndex(of: "SEND") == LearnGuide.beforeSending(.newAudioTrack).count)
    }
}
