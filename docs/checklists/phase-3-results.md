# Phase 3 test results (real Logic 13.0)

Date: 2026-11-21  
Environment: Logic Pro 13.0 (Japanese UI), test project “Untitled 2” (unsaved): 11 tracks at the start (`Inst 1`, `Inst 2`, `オーディオ 1`…`オーディオ 9`, i.e. “Audio 1”…“Audio 9” in the English UI)  
Run by: A–G operated by Claude through `logic-mcp console --fifo` (logs `var/logs/console-20261121-080343.log`, `console-20261121-081941.log`), H through the MCP tools in Claude Code; Claude operated Logic's UI via computer use (learning, selecting tracks, checking results)

> Menu names are those of Logic's English UI. The tests were run on Logic 13.0 with the Japanese UI, so these names come from Apple's English documentation and have not been checked on an English-UI Logic yet.

Not every item of the full checklist ([phase-3.md](phase-3.md)) was run; the items not run are listed at the end. The “run after confirmation” path of destructive commands (delete, quantize, save) was only run after the user agreed.

## A. Learning

All 17 commands (CC 23–39) were learned on the first attempt, and each showed `CC n (127)` in the Control Surface column. The Japanese names actually observed:

| Command id | CC | Japanese UI name (observed) | Originally guessed keyword |
|---|---|---|---|
| `rewind-one-bar` | 23 | 早戻し (Rewind) | 巻き戻し (literally ‘rewind’; **wrong** guess) |
| `undo` | 24 | 取り消す (Undo; in the さまざまなウインドウ (Various Windows) group, ⌘Z) | 取り消す |
| `redo` | 25 | やり直す (Redo) | やり直す |
| `new-audio-track` | 26 | 新規オーディオトラック (New Audio Track) | オーディオトラック (audio track), 新規 (new) |
| `new-software-instrument-track` | 27 | 新規ソフトウェア音源トラック (New Software Instrument Track) | ソフトウェア音源 (software instrument), 新規 (new) |
| `duplicate-track` | 28 | 設定の複製を使った新規トラック (New Track with Duplicate Settings; ⌘D) | 複製 (duplicate) |
| `delete-track` | 29 | トラックを削除 (Delete Track; ⌘⌫) | トラックを削除, 削除 (delete) |
| `save` | 30 | 保存 (Save) | 保存 |
| `toggle-cycle` | 31 | サイクルモードを切り替え (Toggle Cycle Mode) | サイクル (cycle) |
| `toggle-metronome` | 32 | メトロノームクリックを切り替え (Toggle Metronome Click) | メトロノーム (metronome), クリック (click) |
| `toggle-count-in` | 33 | カウントインを切り替え (Toggle Count-in) | カウントイン (count-in) |
| `create-marker` | 34 | マーカーを作成 (Create Marker) | マーカー (marker) |
| `quantize-selection` | 35 | 選択したリージョン/セル/イベントをクオンタイズ (Quantize Selected Regions/Cells/Events; Q) | クオンタイズ (quantize) |
| `select-all` | 36 | すべてを選択 (Select All) | すべてを選択 |
| `show-hide-mixer` | 37 | ミキサーを表示/非表示 (Show/Hide Mixer) | ミキサー (mixer) |
| `show-hide-piano-roll` | 38 | ピアノロールを表示/非表示 (Show/Hide Piano Roll) | ピアノロール (piano roll) |
| `zoom-to-fit` | 39 | ズームして選択部分またはすべてのコンテンツのどちらにサイズを合わせるかを切り替え (Toggle Zoom to Fit Selection or All Contents) | ズーム (zoom) |

| Item | Result | Notes |
|---|---|---|
| A1 | Pass | See the table above; commands that already had a Mackie assignment show `CC n (127) (+1)` and so on (several assignments coexist) |
| A4 / #6 | **Confirmed (accident)** | While learning Delete Track, `tracks` was run once after the button had been pressed: Logic learned the Bank Left press from the scan (`90 2E 7F`) as **`ノート 46`** (“Note 46” in the English UI), and so the scan's Bank Left did not take effect either (“Could not return the surface…” warning). The assignment was removed with Delete Assignment, and CC 29 was learned again. The docs and tool descriptions now say that the learning state **does** capture Mackie messages |
| #4 | Pass | In the learning state a received trigger message is only learned, not executed: after learning 26/27/28 the track count was still 11 |
| A5 | Pass | `learn toggle-cycle` with the button not pressed: Cycle was turned on (the command was executed), then turned off again with `run toggle-cycle` |
| — | Observation | The button resets by itself after receiving one message (it does not stay in the learning state) |

## B. Playhead

| Item | Result | Notes |
|---|---|---|
| B1 | Pass | 9.4.4.45 → 1.1.1.1, `verified` |
| B2 | Pass | Already at 1 1 1 1: `verified`, “nothing sent”, with the warning that this does not prove the command has been learned |
| B3 | Pass | 5.1.1.1 → 6.1.1.1 |
| B4 | Pass | 4.3.4.59 → 5.1.1.1 (from mid-bar, forward to the start of the next bar) |
| B5 | Pass | 5.1.1.1 → 4.1.1.1 |
| B6 | Pass | 5.3.4.74 → 5.1.1.1 (from mid-bar, back to the start of the same bar) |
| B7 | Pass | At 1 1 1 1: “cannot move earlier; nothing sent” |
| B8 | Pass | `run go-to-beginning` during playback: `unverified`; after stopping, the display showed 1.4.4.34, so the playhead had jumped back to the beginning and kept playing |

## C. Tracks

| Item | Result | Notes |
|---|---|---|
| C1 / C7 | Pass | `run new-audio-track` with the 2nd track, `Inst 2`, selected: 11 → 12, `verified`; the new track `オーディオ 10` (“Audio 10”) was inserted as the 3rd track, with no dialog, and was selected; the order in `tracks` matched the main window |
| — | **Problem found and fixed** | The `tracks` run right after it failed: Logic took the Channel Right pressed 65 ms after Option was released as Option + Channel Right (jump to the last page). Having just created a track, Logic processed the Option release late. The scan now waits for Global View to stop flashing before it presses the next key (`MixerController.goToFirstPage`); the fake Logic gained `optionReleaseLag`, and a new test fails when the fix is removed |
| C2 | Pass | `run new-software-instrument-track`: 12 → 13; no dialog, Library or instrument window; the following `run select-all` selected the regions in the Tracks area (focus stayed in the Tracks area) |
| C3 | Pass | `run duplicate-track` with `Inst 1` selected: 13 → 14; the new track `Inst 4` was below `Inst 1` and kept Ample Guitar (`Inst 1` had no regions, so whether regions are copied was not tested) |
| C4 (console) | Partial | `run delete-track` was refused and nothing was sent; `run! delete-track` was blocked by the safety check of Claude Code's auto mode, so it was run in H3 instead, after the user agreed |
| H3 / C10 | Pass | See H3: the deleted track was exactly the selected one, and the scan before the deletion did not change the selected track (#31) |

## D. LEDs

| Item | Result | Notes |
|---|---|---|
| D1 | Pass | `leds_lit` had `click` and no `cycle`, matching the control bar |
| D2 | Pass | `run toggle-cycle` twice: off → on → off, each `verified`, the LED changed within 6 ms |
| D3 | Pass | `run toggle-metronome` twice, same as above |
| D4 | Pass | After Cycle was clicked in the control bar, `cycle` appeared in `leds_lit` |
| D5 | Pass | Track 1 soloed + Cycle on + playing, 5 × `status`: `cycle` and `click` stayed lit; the mute LEDs were present in some of the 5 and absent in others (alternating flashing) |
| G3 | Pass | Four `run toggle-cycle` in a row (≥150 ms apart) were all `verified` |

## E. Commands without feedback

| Item | Result | Notes |
|---|---|---|
| E1 | Pass | `run undo`: `unverified`; `tracks` 14 → 13 (`Inst 4` gone) |
| E2 | Pass | `run redo`: `Inst 4` came back (14), then it was removed again with `run undo` |
| E3 | Pass | `run select-all` with the Tracks area focused: the only region (`Inst 2`, bar 9) was selected |
| E7 | Pass | `run toggle-count-in` twice: the control bar's “1234” turned off, then on |
| E8 | Pass | `locate 3`, `run create-marker`: “マーカー1” (“Marker 1”) appeared at bar 3 |
| E9 | Pass | The Mixer and the Piano Roll were each shown / hidden; after the Mixer was shown, `select-all` did not visibly select any channel strip |
| E4 | Pass (after user consent) | With the `Inst 1` region at bar 13 selected (all 4 notes 5 ticks early), `run_command quantize-selection` first returned `needs_confirmation` (nothing sent); after the user agreed, called with the token: `unverified`, and in the Event List the 4 notes were quantized to `13 1 1 1`…`13 4 1 1`; after `run_command undo` they were back in their original positions |
| E6 | Pass (after user consent) | Project never saved: `run_command save` first returned `needs_confirmation`; with the token, Logic opened the Save dialog (name “プロジェクト 3”, i.e. “Project 3”); Cancel was clicked, the project was still “Untitled 2”, and nothing was written to disk |
| E10 | Pass (description changed) | The first run zoomed to the selected region, the second went back to the previous zoom: it is a **toggle** command, and its description in the command table has been changed |
| — | Finding | After E9, `St Out` and `Master` appeared at the end of the Mackie track list (13 tracks shown as 15 channel strips); the cause has not been found (showing / hiding the Mixer is the most likely suspect). Verification of track count changes is not affected |

## G. Safety

| Item | Result | Notes |
|---|---|---|
| G1 | Pass | During `record` (Replace off), `run toggle-cycle`, `key undo` and `learn undo` were all refused; the log had no `BF` messages at all; no region was recorded |

## H. Using it through Claude (MCP)

| Item | Result | Notes |
|---|---|---|
| — | Pass | After the server restarted, Claude Code reconnected automatically and got the new `list_commands`, `run_command` and `learn_command` through `tools/list_changed` |
| H1 | Pass | `list_commands` listed 20 commands, with `destructive`, `verification` and `can_verify` |
| H2 | Pass | `run_command new-audio-track`: 15 → 16, `verified`, the new track `オーディオ 11` (“Audio 11”) below the selected `Inst 1` |
| H3 | Pass | `run_command delete-track` first returned `needs_confirmation` (a token, nothing sent); the user was asked in the conversation and answered “I agree!”, then the call with the token: 16 → 15, `verified`, and the deleted track was exactly `オーディオ 11` |
| H4 | Pass | `logic_status` first showed the metronome already on; tested off → on: `after.click` was `true` |
| H7 | Pass | `run_command undo` while recording: `failed`, “Nothing was sent” |
| H8 | Pass | `go-to-beginning` at 1 1 1 1: “nothing sent”; `last_run` in `list_commands` was still the earlier run that actually sent |

## Items not run

- A2 (Controller Assignments window): in background mode the menu command did not open the window, so it was not checked; all CC assignments were seen in the Key Commands window.
- A3, A6, A7 (restarting Logic, switching key command presets), A8, A9, B9: not run (A7 would close the unsaved test project).
- C5, C6, C8, C9, C11: not run (C9 can only be done before learning; C11, folders / hidden tracks, is left for later).
- D6, F1–F3, G2, G4, H5, H6, H9: not run.
- E5 (saving a project that has been saved before): not run, because the test project had never been saved.
