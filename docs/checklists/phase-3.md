# Phase 3 test checklist (real Logic 13)

Purpose: confirm that “Claude can run common commands such as creating tracks, quantizing and undo” works in real Logic, and check one by one the behaviour the code relies on that is not yet in [Logic 13 observed facts](../appendix/logic13-mcu-facts.md) (the relevant rows are tagged **[#n]**, matching the “Assumptions” list at the end of this document).

> Menu names are those of Logic's English UI. The tests were run on Logic 13.0 with the Japanese UI, so these names come from Apple's English documentation and have not been checked on an English-UI Logic yet.

Prerequisites:

- Logic is connected to the emulated Mackie Control surface as described in [Phase 1 setup](../setup/01-phase1-logic-setup.md); `mackie.surface_active` in `status` is `true`.
- Use a **new test project**, not a real one: the tests create and delete tracks, quantize and save. Suggested: 2 software instrument tracks (`Inst 1`, `Inst 2`, with a MIDI region of a few notes recorded on `Inst 1`) + 3 audio tracks; **save it once first** (E5 and E6 need this).
- Logic is **stopped** (unless an item asks for playback).
- For section A, learn the commands following [Phase 3 setup](../setup/03-phase3-commands.md); C9 must be done **before** learning `new-audio-track`.

For each item, fill in what you actually see. Keep the console logs (`~/logic-pro-mcp/var/logs/console-*.log`) and give Claude their paths when you are done. The console and the server cannot run at the same time: A–G use the console, H uses Claude.

Common console commands: `commands`, `run <id>` (`run! <id>` for destructive commands), `learn <id>`, `key <id>`, `status`, `lcd`.

---

## A. Learning

| # | Action | Expected | Actual |
|---|---|---|---|
| A1 | Learn the 17 commands following §3 of the setup document; for each, record the **actual Japanese name** in the Key Commands window and whether the English name matches `commands` | The Control Surface column of each shows `CC n (127)` (n = 23…39) **[#1][#2][#3]**; fill the Japanese names into the table below | |
| A2 | Open the Controller Assignments… window | Under “(No Zone)”, the LogicMCP Keys assignments are exactly CC 20–39; Learn Mode (bottom right) is not lit; record the category these assignments are shown under (Key Command?) **[#24]** | |
| A3 | While learning (button already pressed), run `status` in the console, then look at Logic | Logic shows no “already assigned…” prompt (`status` sends no message to Logic) **[#6]** | |
| A4 | Optional: while learning `zoom-to-fit`, after pressing the button, run `press cycle` in the console | Record whether Logic takes the Mackie Cycle button as the input to learn (if a prompt appears, click Cancel) **[#6]** | |
| A5 | With the button **not** pressed, `learn toggle-cycle` (already learned) | Logic's Cycle is toggled (the message sent executed the command directly); then `run toggle-cycle` to switch it back **[#5]** | |
| A6 | After pressing the button, `learn rewind-one-bar` (learning the same command again) | Record whether a “reassign” prompt appears, and whether the command was **also executed** while learning (did the playhead move back?) **[#4][#29]** | |
| A7 | Quit and reopen Logic, `run toggle-cycle` | `verified` (the assignment still works after the restart); then switch the key command preset to another one and back, and repeat **[#24]** | |
| A8 | Select the `redo` row and press Learn New Assignment, then switch to another app (Logic goes to the background) and wait 30 seconds, then `learn redo` in the console | Still learned (`CC 25 (127)`); when learning through Claude, the button also stays in the learning state while a destructive command is being confirmed in the conversation (H5) **[#32]** | |
| A9 | With the button **not** pressed, `learn go-to-position` (CC 20 already learned) | Logic opens the Go to Position dialog (the command is executed); the first warning and the check steps the console prints ask you to close the dialog in Logic first; **only while the dialog is actually open**, run `press f1` in the console (outside the dialog, F keys switch screensets) and record whether digits go into the dialog; finally click Cancel in Logic **[#5][#38]** | |

Japanese names observed:

| Command id | Japanese UI name (observed) |
|---|---|
| `rewind-one-bar` | |
| `undo` | |
| `redo` | |
| `new-audio-track` | |
| `new-software-instrument-track` | |
| `duplicate-track` | |
| `delete-track` | |
| `save` | |
| `toggle-cycle` | |
| `toggle-metronome` | |
| `toggle-count-in` | |
| `create-marker` | |
| `quantize-selection` | |
| `select-all` | |
| `show-hide-mixer` | |
| `show-hide-piano-roll` | |
| `zoom-to-fit` | |

## B. Playhead

| # | Action | Expected | Actual |
|---|---|---|---|
| B1 | `locate 9`, `play`, `stop` after about 2 seconds (stopping mid-bar), `run go-to-beginning` | `verified`, `after.position` is 1.1.1.1 **[#11][#14]** | |
| B2 | `run go-to-beginning` when already at 1 1 1 1 | `verified`, “nothing sent”; `warnings` explains that this does not prove the command has been learned | |
| B3 | `locate 5`, `run forward-one-bar` | `verified`, 6.1.1.1 **[#12]** | |
| B4 | `play`, `stop` after about 1.5 seconds (stopping mid-bar; note the position), `run forward-one-bar` | Record the new position (start of the next bar? Or the same beat position?); any position within the next bar counts as `verified` **[#12]** | |
| B5 | `locate 5`, `run rewind-one-bar` | `verified`, 4.1.1.1 **[#13]** | |
| B6 | Stopped mid-bar (as in B4), `run rewind-one-bar` | Record the new position: start of this bar? The same position in the previous bar? Both count as `verified` **[#13]** | |
| B7 | `run rewind-one-bar` at 1 1 1 1 | `verified`, “cannot move earlier; nothing sent” | |
| B8 | `play`, `run go-to-beginning`, then `stop` | `unverified` (cannot be confirmed during playback); in Logic the playhead did jump back to the beginning **[#10]** | |
| B9 | Open the Go to Position dialog with `key go-to-position`, then `run forward-one-bar`; afterwards close the dialog in Logic | `failed` (the time display did not change); record whether the command was executed while the dialog was open | |

## C. Tracks

| # | Action | Expected | Actual |
|---|---|---|---|
| C9 | (**Before** learning `new-audio-track`) `run new-audio-track` | `failed`, “track count stayed at 5 (3 scans …)”; no new track in Logic **[#7]** | |
| C1 | Select the last track, `run new-audio-track`; note the time taken | `verified`, 5 → 6; Logic shows no dialog, and the new track is below the selected track **[#15][#18]** | |
| C2 | `run new-software-instrument-track`, then `run select-all` | `verified`, +1; record whether a dialog, the Library or an instrument window opens, and what `select-all` then selects (did keyboard focus leave the Tracks area?) **[#15][#35]** | |
| C3 | Select `Inst 1`, `run duplicate-track` | `verified`, +1; the new track is below `Inst 1`; record its name and whether the regions were copied **[#16]** | |
| C4 | Select the track created in C1 (an empty track), `run delete-track` | `needs_confirmation`, nothing sent; then `run! delete-track`: `verified`, −1, and the deleted track is the selected one **[#17][#27]** | |
| C5 | Select two empty tracks, `run! delete-track` | Both are deleted, result `unverified` (“not by -1 as expected”) **[#17]** | |
| C6 | Select a track **with regions**, `run! delete-track` | Record whether Logic shows a confirmation dialog; if it does, the result is `failed` (track count unchanged); click Cancel in Logic **[#17]** | |
| C7 | Select a track **in the middle** (e.g. the 2nd), `run new-audio-track`, then `tracks` | `verified`; the new track is inserted as the 3rd, and the order of names in `tracks` matches Logic's main window **[#15][#18]** | |
| C8 | `run new-audio-track` in a project with 30 tracks; note the time taken | `verified`; takes about 2 × 30 × 0.3 seconds **[#18]** | |
| C10 | Select the 2nd track (an empty track), `run! delete-track` | `verified`, and the deleted track is **exactly the 2nd**: the track scan before sending (Option + Bank Left, Channel Right, Pan, Name/Value) did not change Logic's track selection; afterwards the main window still has keyboard focus (`run select-all` selects the regions in the Tracks area) **[#31]** | |
| C11 | Put two audio tracks into a **folder track** and collapse it, select one of the tracks in the folder (expand, select, then collapse again), `run new-audio-track`; repeat with a (collapsed) track stack; then **hide** a track (H button), select the track above it, and repeat. After each, run `tracks` and look at Logic's main window | For each case, record whether the result is `verified` or `failed`, where the new track appears, and whether it is in the console's track list. `failed` while Logic actually has an extra track means the console cannot see collapsed / hidden tracks (the warning in the result says not to retry) **[#36]** (corresponds to assumption #26 and B10 in the Phase 2 checklist) | |

## D. LEDs

| # | Action | Expected | Actual |
|---|---|---|---|
| D1 | `status`; note whether `leds_lit` contains `cycle` and `click`; compare with the Cycle and metronome buttons in Logic's control bar | Cycle LED = Cycle state; Click LED = metronome state **[#19][#20]** | |
| D2 | Right after the console starts, `run toggle-cycle` twice | Both `verified` (off → on → off), and the Cycle button in Logic's control bar follows; each run toggles only once (a single CC with value 127 counts as one press). If `unverified` (“LED stayed off”): record whether the control bar's Cycle button toggled; if it did, Logic does not reflect key commands on the LED (#19 does not hold) **[#19][#34][#37]** | |
| D3 | `run toggle-metronome` twice | Both `verified`, and Logic's metronome button follows; if `unverified`, record the metronome button as in D2 **[#20][#37]** | |
| D4 | Click the Cycle and metronome buttons in Logic's control bar with the mouse, `status` after each | `leds_lit` changes accordingly (the LEDs do not react only to key commands) **[#19][#20]** | |
| D5 | Solo a track, turn Cycle on and play; `status` once per second, 5 times; then stop, unsolo and turn Cycle off | `cycle` and `click` in `leds_lit` stay steady, and do not alternate on and off like the mute LEDs while soloing **[#33]** | |
| D6 | After D2 (in the same console run), delete the CC 31 assignment in Controller Assignments…, `run toggle-cycle`, then learn toggle-cycle again following the setup document | `failed` (“LED stayed …”): in this run the LED has already followed a key command, so no change counts as not executed; Cycle did not toggle in Logic **[#37]** | |

## E. Commands without feedback

After each one, check the effect in Logic, and see whether the console log shows any `IN` messages after it (if it does, note them: they might be usable for verification) **[#21]**.

| # | Action | Expected | Actual |
|---|---|---|---|
| E1 | `run new-audio-track`, then `run undo`, then `tracks` | `undo` is `unverified`; the new track disappears in Logic, and `tracks` shows one track fewer | |
| E2 | `run redo`, then `tracks` | `unverified`; the track comes back | |
| E3 | `run select-all` while the main window has focus | `unverified`; all regions in the Tracks area are selected **[#8]** | |
| E4 | Select only the MIDI region on `Inst 1`, `run quantize-selection`; then `run! quantize-selection`; then `run undo` | The first returns `needs_confirmation` (nothing sent); the second `unverified`, and the region is quantized; restored after undo | |
| E5 | Make a small change to a project that has been saved before, `run! save` | `unverified`; the “edited” mark in Logic's title bar disappears; record whether the Save LED (`save` in `leds_lit` from `status`) changes between before and after saving **[#21][#22]** | |
| E6 | Create a project that has **never been saved**, `run! save` | Record whether Logic opens a save dialog (then click Cancel in Logic) **[#22]** | |
| E7 | `run toggle-count-in` twice | Count-in in the control bar turns on, then off | |
| E8 | `locate 3`, `run create-marker` | A marker appears at bar 3 | |
| E9 | `run show-hide-mixer` twice, `run show-hide-piano-roll` twice | The Mixer and the Piano Roll are shown / hidden; record whether keyboard focus moved to them **[#30]** | |
| E10 | `run zoom-to-fit` | The Tracks area zooms to show all contents | |

## F. Focus and background

| # | Action | Expected | Actual |
|---|---|---|---|
| F1 | With another app (e.g. Terminal) in front and Logic in the background, `run toggle-cycle`, `run new-audio-track` | Both `verified` **[#9]** | |
| F2 | Click the Mixer in Logic to give it focus, `run select-all` | Record what gets selected (channel strips?) **[#8]** | |
| F3 | `run toggle-cycle` while Logic's Key Commands window is in front (has focus) | Record whether it takes effect **[#8]** | |

## G. Safety

| # | Action | Expected | Actual |
|---|---|---|---|
| G1 | `record` (Replace off); while recording, `run toggle-cycle`, `learn undo`, `key undo`, then `stop` | All three are refused (“recording”), and the console prints no `sent`; the recorded region contains no CC data **[#23]** | |
| G2 | Record-arm a software instrument track; delete the CC 39 (zoom-to-fit) assignment in Controller Assignments…; while stopped, `key zoom-to-fit`; afterwards learn zoom-to-fit again following the setup document | Logic treats it only as an ordinary MIDI CC (the MIDI activity display in the control bar reacts), with no audible or visible change **[#7]** | |
| G3 | `--run "run toggle-cycle; run toggle-cycle; run toggle-cycle; run toggle-cycle"` | All four `verified` (triggers 150 ms apart are all executed) **[#25]** | |
| G4 | Turn off the Mackie control surface (or quit Logic and run only the console), `run undo`; then `key zoom-to-fit` | `run undo`: `failed` (cannot confirm that Logic is not recording), nothing sent; `key zoom-to-fit`: still sent, with the warning “could not be checked that Logic was not recording” (learning and `key` are exceptions) **[#23]** | |

## H. Using it through Claude (MCP)

Quit the console and start a Claude Code session in `~/logic-pro-mcp`:

| # | Say to Claude | Expected | Actual |
|---|---|---|---|
| H1 | “Which Logic commands can I use?” | Claude calls `list_commands`, lists 20 commands, and explains which can be verified and which need your consent | |
| H2 | “Create a new audio track” | `run_command` (new-audio-track) `verified` | |
| H3 | Select the track just created in Logic, and say “Delete the selected track” | Claude first gets `needs_confirmation` and asks you in the conversation; after you agree, it calls again with the token, `verified` | |
| H4 | “Turn the metronome on” (turn the metronome off in Logic first) | Claude uses `toggle-metronome`, and `after.click` in the result is `true`; if the metronome was already on, Claude should check `before.click` or `logic_status` before deciding | |
| H5 | Delete the CC 39 assignment in Controller Assignments…, and say “Help me learn zoom-to-fit again” | Claude first gives you the steps (the `learn_steps` from `list_commands`) and calls `learn_command` only after you say the button is pressed, without calling any other Logic tool in between; once learned, `run_command zoom-to-fit` returns `unverified` | |
| H6 | “Save the project” | Claude asks you first; after you agree, `unverified`, and it reminds you to check in Logic | |
| H7 | Say “Undo” while recording | `failed` (refused while recording), and Claude does not retry | |
| H8 | With the playhead at 1 1 1 1, say “Go back to the beginning”, then “List the commands” | `run_command` (go-to-beginning) `verified`, “nothing sent”; the `last_run` of go-to-beginning in `list_commands` does not appear or change because of it (runs that send nothing are not recorded) | |
| H9 | In Logic, put the selected track into a collapsed folder (as in C11), and say “Create a new audio track”; if the result is `failed` | Claude does not retry, and first asks you to check in Logic whether a track has already been added **[#36]** | |

---

## Assumptions (behaviour the code relies on but that has not yet been observed on Logic 13)

| # | Assumption | Used in | How to verify |
|---|---|---|---|
| #1 | The English names in the command table match Logic 13's Key Commands window (for CC 20–22 only the Japanese names were checked); `duplicate-track` uses “New Track with Duplicate Settings”; the names `Toggle Cycle Mode`, `Toggle Metronome Click`, `Toggle Count-in` and `Toggle Zoom to Fit Selection or All Contents` are the least certain | `englishName` in `CommandCatalog`, the learning steps | A1 |
| #2 | The Japanese search keywords (巻き戻し (literally ‘rewind’; wrong guess), 取り消す (undo), やり直す (redo), オーディオトラック (audio track), ソフトウェア音源 (software instrument), 複製 (duplicate), 削除 (delete), 保存 (save), サイクル (cycle), メトロノーム (metronome), クリック (click), カウントイン (count-in), マーカー (marker), クオンタイズ (quantize), すべてを選択 (select all), ミキサー (mixer), ピアノロール (piano roll), ズーム (zoom)) find the matching commands in the search field; they are only guesses, and the Japanese names in the command table stay empty until verified | `japaneseKeywords`, `LearnGuide.findRow` | A1 |
| #3 | Every command can be learned with Learn New Assignment as `CC n (127)` (LogicMCP Keys, channel 16); once learned, receiving this CC with value 127 executes the command once (observed only for CC 21 and 22 in Phase 1) | Every `run_command` | A1, B, C, D |
| #4 | While Learn New Assignment is in the learning state, a received trigger message is only learned and the command is **not executed** | The description of `learn_command` | A6 |
| #5 | When not in the learning state and already learned, a trigger message executes the command directly; so `learn_command` for destructive commands also needs confirmation | The confirmation in `CommandController.learn` | A5 |
| #6 | The learning state of the Key Commands window, like that of the Controller Assignments window, may also take messages from the emulated Mackie Control surface as the input to learn (the facts document only observed this for the Controller Assignments window); so `learn_command` sends nothing to the Mackie port, and the tool description says not to call other Logic tools while learning | `learn_command`, the tool description, the setup document | A3, A4 |
| #7 | An unlearned trigger message goes to the selected track as ordinary MIDI input, with no effect while stopped (CC 20–31 are undefined; 32 = Bank Select LSB, 33 = Modulation LSB, 38 = Data Entry LSB, 39 = Volume LSB etc. are only low-order bytes), and is recorded into the region while recording (hence sending is refused while recording) | CC assignment, refusal while recording | C9, G1, G2 |
| #8 | Key commands act on the window that has keyboard focus (as the research report says) | The descriptions of `select-all`, `quantize-selection` etc. | E3, F2, F3 |
| #9 | Key commands also work while Logic is in the background (Phase 1 only showed that the emulated Mackie Control surface works in the background) | Every `run_command` | F1 |
| #10 | Logic also executes key commands during playback; playhead commands cannot be verified from the time display during playback and return `unverified` | `PlaybackPolicy.unverifiedWhilePlaying` | B8 |
| #11 | Go to Beginning always goes to 1 1 1 1 (observed in that project in Phase 1; projects that do not start at bar 1 were not considered); when already at 1 1 1 1 the code sends nothing | `PlayheadMove.toBeginning` | B1, B2 |
| #12 | Forward moves from a bar line to the bar line of the next bar (observed in Phase 1); from mid-bar it moves to some position within the next bar (the code accepts any position within the next bar) | `CommandController.matches` | B3, B4 |
| #13 | Rewind moves from a bar line back to the bar line of the previous bar; from mid-bar it moves back to the start of this bar or to the same position in the previous bar (both are accepted); at 1 1 1 1 it does not move (the code sends nothing) | Same as above | B5–B7 |
| #14 | After a key command moves the playhead, the time display starts updating within 1 second and settles quickly, as with Jog (waiting for 30 ms without updates) | `playheadTimeout`, `waitForTimecodeQuiet` | B1–B6 |
| #15 | New Audio Track / New Software Instrument Track create **one** track directly, without opening the New Tracks dialog, inserted below the selected track | `trackCount(change: 1)` | C1, C2, C7 |
| #16 | New Track with Duplicate Settings creates exactly one track without a dialog when one track is selected | Same as above | C3 |
| #17 | Delete Track deletes the selected track without a dialog (a track with regions might show one; then the track count is unchanged → `failed`); with several tracks selected, it deletes them all (result `unverified`) | `trackCount(change: -1)`, `TrackCountOutcome` | C4–C6 |
| #18 | After a track is created / deleted, Logic reflects the change on the control surface within the scan window (the first scan starts 0.3 seconds after sending, at most 3 scans, and each scan starts no later than 8 seconds after sending, so with many tracks only one scan follows the send), and the Phase 2 scan can count the new number of tracks. The times in the tool description (about 0.6 seconds per track, about 1 minute for 100 tracks) are a linear extrapolation from 3.6 seconds for 11 tracks | `CommandTimings`, `runTrackCount`, `startsAnotherScan`, the description of `run_command` | C1, C7, C8 |
| #19 | The Cycle LED (`56`) follows the Cycle state, including when it is changed by a key command (only observed as off at connection); until this is verified, if the LED does not change within 1 second the result is `unverified` (not `failed`), with a reminder to check Logic before retrying | `surfaceLED(.cycle)`, `runLED` | D1, D2, D4 |
| #20 | The Click LED (`59`) shows whether the metronome is on and follows the Toggle Metronome Click command (observed on at connection; meaning unverified); handled as in #19 | `surfaceLED(.click)`, `runLED` | D1, D3, D4 |
| #21 | Undo, redo, select all, quantize, save, count-in, marker, show / hide and zoom have no usable feedback on the Mackie Control surface (the result is always `unverified`); the Save LED (`50`, on at connection) may mean “unsaved changes”, but the code does not use it | `verification: .none` | E1–E10 |
| #22 | In a project that has been saved before, Save saves directly; in a project that has never been saved, Save opens a save dialog | The description of `save` | E5, E6 |
| #23 | A lit or flashing Record LED (including during the count-in) means recording; when the LED is unknown, `run` refuses, while learning and the console's `key` still send (with a warning) (Phase 1 observed the Record LED following the transport; flashing during the count-in has not been observed) | `recordingRefusal`, `learn`, `trigger` | G1, G4 |
| #24 | Learned assignments are stored under “(No Zone)” in the controller assignments, and still work after Logic restarts and after switching key command presets | The setup document | A2, A7 |
| #25 | Consecutive triggers 150 ms apart are all executed | `RateLimits.keyCommandGap` | G3 |
| #26 | Key commands produce no output on the LogicMCP Keys port (that port only goes server → Logic anyway), and assignments learned on LogicMCP Keys do not affect the emulated Mackie Control surface on LogicMCP MCU | Design | A2, logs |
| #27 | After creating a track, Logic selects the new track (only used in the steps of this checklist; the code does not rely on it) | The steps of C4 | C4 |
| #28 | Logic 13's Key Commands window has “Copy Key Commands to Clipboard” (the research report cites the 13.0 documentation; the Japanese menu name is unknown) | The setup document | Check the menu |
| #29 | When a CC that is already assigned is learned again, Logic asks whether to reassign it | The learning steps | A6 |
| #30 | Show/Hide Mixer and Show/Hide Piano Roll may move keyboard focus to the Mixer / Piano Roll | The command descriptions | E9 |
| #31 | The track scan before sending (which presses Option + Bank Left, Channel Right, Pan, Name/Value) does not change the selected track or keyboard focus in Logic; delete-track, duplicate-track and the insertion position of new tracks all depend on the selected track (B11 of the Phase 2 checklist has not been run yet) | `runTrackCount` scans after the user confirms and before sending | C10, C4 |
| #32 | After Learn New Assignment is pressed, the learning state persists while Logic is in the background (the user switches to Claude or Terminal) and while a destructive command is being confirmed in the conversation | The `learn_command` flow, the setup document | A8, H5 |
| #33 | The Cycle and Click LEDs are steady on / off, and do not flash with alternating on / off messages like the mute LEDs while soloing; if they did, an unlearned toggle command might be misjudged as `verified` | `runLED` | D5 |
| #34 | Sending a single CC with value 127 (and no value 0 afterwards) counts as one press and one execution for every command (observed only on CC 20–22) | The trigger message format `LogicCommand.message` | A1, B3, D2, G3 |
| #35 | New Software Instrument Track may open the Library or an instrument window and move keyboard focus away from the Tracks area, affecting later key commands (the code does not rely on this; only the command description warns about it) | The command description | C2 |
| #36 | When the selected track is inside a **collapsed folder / track stack**, or the project has **hidden tracks**, created / duplicated / deleted tracks also appear in (or disappear from) the track list of the control surface (Tracks mode), and the scan can count the change in the track count (assumption #26 and B10 of the Phase 2 checklist have not been run yet). If this does not hold, the result is `failed` although the command was actually executed, so the `failed` warning asks the user to check Logic before retrying | `runTrackCount`, the description of `run_command` | C11, H9 |
| #37 | Within one run (of the server or console process), once the Cycle / Click LED has changed within 1 second after one of our trigger messages, every later key command that changes the setting is also reflected within 1 second; so if the LED does not change later, the command counts as not executed (`failed`). Related to #33: if these two LEDs flash, one chance change would turn every later timeout into `failed` | `runLED` (`ledsSeenFollowing`) | D2, D3, D5, D6 |
| #38 | When not in the learning state, the learned CC 20 opens the modal Go to Position dialog; the server cannot close it (in Phase 1, Mackie's Enter did not press OK); while the dialog is open, input from the emulated Mackie Control surface (F keys) goes into the dialog (recorded in Phase 1, not in the facts document) | The warning of `learn_command` (go-to-position), `LearnGuide.afterSending`, setup document §2 | A9 |
