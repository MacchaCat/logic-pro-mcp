# Phase 3 setup: learning key commands (controller assignments)

The server triggers Logic key commands by sending **CCs (MIDI channel 16, value 127)** on the `LogicMCP Keys` port. Logic does not know by itself which CC belongs to which command, so each command has to be **learned once** in Logic's Key Commands window (design.md §7 question 6 chose "guided learning"). Learned assignments are stored in Logic's control surface settings and do not need to be learned again (whether they are lost when switching key command presets is not verified yet; see [Phase 3 checklist](../checklists/phase-3.md) assumption #24).

Menu names are those of Logic's English UI. The tests were run on Logic 13.0 with the Japanese UI, so these names come from Apple's English documentation and have not been checked on an English-UI Logic yet.

> On this Mac all 20 commands (CC 20–39) **are already learned**: CC 20–22 in Phase 1 ([Phase 1 setup](01-phase1-logic-setup.md) §6), CC 23–39 on 2026-11-21 ([Phase 3 test results](../checklists/phase-3-results.md)). This document is for learning them again on another Mac, or relearning after deleting the assignments.

---

## 0. Before you start

- Logic is connected to the emulated Mackie Control surface as described in [Phase 1 setup](01-phase1-logic-setup.md). `run_command` relies on the surface's Record LED to confirm that Logic is not recording, and refuses to run whenever the surface is not available (learning is an exception, see §5).
- **The Controller Assignments window must not be in learn mode** (Phase 1 setup §1): open **Logic Pro > Control Surfaces > Controller Assignments…**; **Learn Mode** at the bottom right must not be highlighted blue.
- Use a **test project**: trying the commands creates and deletes tracks.
- Logic is **stopped** (while recording, the server refuses to send any trigger message).

## 1. Command list

The English names are the primary names; type them into the search field at the top right of the Key Commands window to find the row. They have not yet been checked one by one on an English-UI Logic. The "Japanese UI name (observed)" column lists the row names actually seen in Logic 13's Key Commands window on this Mac; with a Japanese-UI Logic, paste one of them into the search field instead. Undo (`取り消す`) is in the Various Windows group (`さまざまなウインドウ`); `開いたあとのすべての変更を取り消す` (literally "undo all changes since opening"), whose name also contains `取り消す`, is a different command.

| Command id | CC | English name (Key Commands window, not yet checked on an English-UI Logic) | Japanese UI name (observed) | Needs confirmation | How the result is checked |
|---|---|---|---|---|---|
| `go-to-position` | 20 | **Go to Position…** | 位置を指定して移動… | | Cannot be run with `run_command` (it opens a dialog); used only for learning |
| `go-to-beginning` | 21 | **Go to Beginning** | 先頭に移動 | | The time display shows 1 1 1 1 |
| `forward-one-bar` | 22 | **Forward** | 早送り | | The time display moves one bar later |
| `rewind-one-bar` | 23 | **Rewind** | 早戻し | | The time display moves one bar earlier |
| `undo` | 24 | **Undo** (group Various Windows) | 取り消す (group さまざまなウインドウ) | | Cannot be checked |
| `redo` | 25 | **Redo** | やり直す | | Cannot be checked |
| `new-audio-track` | 26 | **New Audio Track** | 新規オーディオトラック | | Track count +1 |
| `new-software-instrument-track` | 27 | **New Software Instrument Track** | 新規ソフトウェア音源トラック | | Track count +1 |
| `duplicate-track` | 28 | **New Track with Duplicate Settings** | 設定の複製を使った新規トラック | | Track count +1 |
| `delete-track` | 29 | **Delete Track** | トラックを削除 | **Yes** | Track count −1 |
| `save` | 30 | **Save** | 保存 | **Yes** | Cannot be checked |
| `toggle-cycle` | 31 | **Toggle Cycle Mode** | サイクルモードを切り替え | | Cycle LED |
| `toggle-metronome` | 32 | **Toggle Metronome Click** | メトロノームクリックを切り替え | | Click LED |
| `toggle-count-in` | 33 | **Toggle Count-in** | カウントインを切り替え | | Cannot be checked |
| `create-marker` | 34 | **Create Marker** | マーカーを作成 | | Cannot be checked |
| `quantize-selection` | 35 | **Quantize Selected Regions/Cells/Events** | 選択したリージョン/セル/イベントをクオンタイズ | **Yes** | Cannot be checked |
| `select-all` | 36 | **Select All** | すべてを選択 | | Cannot be checked |
| `show-hide-mixer` | 37 | **Show/Hide Mixer** | ミキサーを表示/非表示 | | Cannot be checked |
| `show-hide-piano-roll` | 38 | **Show/Hide Piano Roll** | ピアノロールを表示/非表示 | | Cannot be checked |
| `zoom-to-fit` | 39 | **Toggle Zoom to Fit Selection or All Contents** | ズームして選択部分またはすべてのコンテンツのどちらにサイズを合わせるかを切り替え | | Cannot be checked |

For the commands that need confirmation (delete track, save, quantize), Claude has to ask you in the conversation before every run, and sends the command only after you agree:

- **delete-track**: deletes the track **currently selected** in Logic (with its regions). The server cannot see which track is selected.
- **save**: overwrites the project file on disk; this cannot be undone. For a project that has never been saved, Logic probably opens its Save dialog.
- **quantize-selection**: rewrites the timing of the regions or notes selected in **the Logic window that has key focus**. The server cannot see what is selected, nor read the result (it can be reverted with `undo`).

Commands marked "Cannot be checked" return `unverified` after running: Logic gives no acknowledgement for key commands (research §3.3), and nothing changes on the Mackie Control surface either, so check in Logic.

## 2. Learning one command

**Key point: the Learn New Assignment button looks the same armed and unarmed.** In Phase 1, two sends while learning Go to Beginning were not learned, precisely because the order was wrong. Always follow the order "select the row first → then click the button → then send".

1. In Logic, open **Logic Pro > Key Commands > Edit Assignments…** (the Key Commands window).
2. Type the command's English name from the table above into the **search field** at the top right and find that row. With Logic's Japanese UI, search for the Japanese name in the table instead.
3. **Click the row first to select it**, then click **Learn New Assignment** under "Control Surface" on the right.
4. Send the trigger message (either way):
   - **Through Claude**: tell Claude "the button is pressed"; Claude calls `learn_command`.
   - **Through the console** (when the server is not running): type `learn <command id>`, for example `learn rewind-one-bar`. The console prints the steps first and sends **after 5 seconds**.
5. Check the row's "Control Surface" column: text such as `CC 23 (127)` (port LogicMCP Keys, channel 16) means it worked. If nothing appears, repeat steps 3 and 4.

Notes:

- **After clicking the button and before the message is sent, do not let Claude call any other Logic tool** (play, mixer, `run_command` and so on). While learning, Logic **does** take messages from the Mackie Control surface as the input to learn: in Phase 1 the Controller Assignments window caught the Play button; on 2026-11-21, while the Key Commands window was learning Delete Track, the track list was read once, and the Bank Left pressed during that scan was learned as "ノート 46" ("Note 46" in the English UI; after that, pressing Bank Left on the Mackie Control surface would delete a track!). If an assignment like `ノート nn` ("Note nn" in the English UI) ever appears, select the row, select that assignment in the "Control Surface" list on the right, click **Delete Assignment**, and learn again.
- If an alert says the control is already assigned to another parameter and asks whether to reassign it: agree only if you are sure you are relearning this command; otherwise click **Cancel**.
- **The three commands that need confirmation** (delete-track, save, quantize-selection) need confirmation when learning, too: if the command has in fact been learned already and the button is not armed, the message **runs the command directly** (for example, deletes the selected track). In the console use `learn! delete-track` (with `!`); through Claude, Claude asks you first.
- The same applies when relearning `go-to-position`: if the button is not armed and CC 20 is already learned, Logic **opens the Go to Position dialog**. In that case, first click **Cancel** in Logic to close the dialog, and only then let Claude use other Logic tools: the server cannot close this dialog, and while it is open, input from the Mackie Control surface goes into the dialog (observed in Phase 1).

## 3. Learning all commands in one go (about 5–10 minutes)

The console is the fastest way (if the server is running, quit the Claude Code session first; the two cannot run at the same time):

```bash
~/logic-pro-mcp/.build/release/logic-mcp console
```

Keep the Key Commands window open. For each line below: in Logic, **select the row → click Learn New Assignment**, then type the line in the terminal (it is sent after 5 seconds); move on to the next one once `CC n (127)` appears.

```text
learn rewind-one-bar
learn undo
learn redo
learn new-audio-track
learn new-software-instrument-track
learn duplicate-track
learn toggle-cycle
learn toggle-metronome
learn toggle-count-in
learn create-marker
learn select-all
learn show-hide-mixer
learn show-hide-piano-roll
learn zoom-to-fit
learn! delete-track
learn! save
learn! quantize-selection
```

Type `commands` in the console to see the command table at any time (id, CC, English name, verified Japanese name, how each is checked).

## 4. Checks after learning

1. Open **Logic Pro > Control Surfaces > Controller Assignments…**: **Learn Mode** at the bottom right is not lit, and under "(No Zone)" the LogicMCP Keys assignments are only CC 20–39, with nothing extra.
2. In the test project, with the playhead stopped at **1 1 1 1**, try these in the console (each should return `"status" : "verified"`):

   ```text
   run toggle-cycle
   run toggle-cycle
   run forward-one-bar
   run forward-one-bar
   run rewind-one-bar
   run go-to-beginning
   run new-audio-track
   ```

   The order matters: with the playhead already at 1 1 1 1, `go-to-beginning` and `rewind-one-bar` **send nothing** (the result says "nothing sent" and is still `verified`), and such a result does not show that the command was learned. So first move forward two bars (1 → 2 → 3), then back one bar (3 → 2), and finally back to the beginning (2 → 1), so that every trigger message is actually sent.

   `run new-audio-track` scans the track list twice (each scan takes about 0.3 seconds per track, so about 0.6 seconds per track in total: about 7 seconds for 11 tracks, about 1 minute for 100).
3. In Logic, **select the track you just created**, then `run! delete-track`: it should return `verified`, and the track count drops by 1.
4. `run undo`, `run select-all` and the like returning `unverified` is normal: check in Logic whether they took effect.

Reading the results:

- A `failed` with "Nothing was sent" is a **refusal** (recording, recording state unknown, track list unreadable, `go-to-position`) and has nothing to do with whether the command was learned.
- Any other `failed` means the expected change was not seen, usually because the command has not been learned yet (or was learned onto a different command). However, a new-track command that returns `failed` may in fact have run without the change being visible on the Mackie Control surface (for example, the selected track is inside a collapsed folder or track stack, or there are hidden tracks): **check the track list in Logic before running it again**, or you may create an extra track.
- When the LED does not change for `toggle-cycle` or `toggle-metronome`, the result is `unverified` (whether Logic shows a key-command toggle on the LEDs is not verified yet): check whether the Cycle / Metronome button in Logic's control bar toggled before running it again, or you may toggle it back. Only once the LED has followed a toggle earlier in the same server (or console) session does an unchanged LED count as `failed`.

## 5. Notes for use

- **Key commands act on the Logic window that has key focus.** For example, when the Mixer has focus, `select-all` selects channel strips. Normally keep the focus on the main window (Tracks area). `show-hide-mixer` and `show-hide-piano-roll` may move the focus to the Mixer or the Piano Roll.
- Whether key commands work while Logic is in the **background** is not verified yet (the Mackie Control surface does work in the background).
- While recording, the server sends no trigger messages (`run_command`, `learn_command`, and the console's `run`, `learn`, `key`): a trigger message that has not been learned would be recorded into a region as ordinary MIDI input. When Logic has not reported the recording state through the Mackie Control surface, `run_command` and the console's `run` also refuse to run; **learning (`learn_command`, the console's `learn`) and the console's `key` are exceptions**: they are for setup and diagnostics, so they still send when the recording state is unknown, but the result carries a warning.
- The CC sent for a command that has not been learned reaches the selected track as ordinary MIDI input. CC 20–31 are undefined in the MIDI specification; CC 32–39 are the LSBs of CC 0–7 (bank select, modulation, volume, etc.) and usually have no audible effect.
- To see Logic's full command list at once, export it with "Copy Key Commands to Clipboard" in the Key Commands window and paste it to Claude to fill in Japanese names.
