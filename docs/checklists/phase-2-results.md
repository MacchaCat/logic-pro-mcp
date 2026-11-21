# Phase 2 test results (real Logic 13.0)

Date: 2026-11-21  
Environment: Logic Pro 13.0 (Japanese UI), test project “Untitled 2”: 11 tracks (`Inst 1`, `Inst 2`, `オーディオ 1`…`オーディオ 9`, the Japanese UI's default audio-track names, i.e. “Audio 1”…“Audio 9” in the English UI), stopped at bar 9  
Run by: Claude through `logic-mcp console --fifo`; logs in `var/logs/console-20261121-02*.log`

The full checklist ([phase-2.md](phase-2.md)) has many assumption items; this run covered only the parts directly related to the Phase 2 completion criteria. The items that were not run are listed at the end.

## Results

| Item | Result | Notes |
|---|---|---|
| A1 | Pass | The scan started from the channel view and switched to the multi-track view automatically |
| B1 | Pass | 11 tracks, about 3.6 s; the end was confirmed with Channel Left / Right |
| D1 | Pass (after a fix) | The names read the first time were all empty strings: Logic 13 puts the track name in `AXDescription`, and `AXValue` is empty. After the fix all 11 are full names and `name_source` is `accessibility` |
| — | Found | When the project window is not the main window (minimised or hidden), the names cannot be read; the scan falls back to the LCD abbreviations automatically and gives a warning |
| F1 / F3 / F4 | Pass | `mixer 1 volume -6`, `mixer 3 volume -17.1` (echo 5990) and `mixer 10 volume -3.7` (needs banking) were all `verified`; restoring 0 dB was also `verified` |
| F5 | Pass | When the value is already the target, it reports “unchanged” and does not move the fader again |
| G1 | Pass | `mixer 10 pan -20` (20 ticks, 0.66 s), `mixer 2 pan 15`, then both back to 0 |
| H1 / H5 / H7 | Pass | Track 10 mute on, off; turning it on when it is already on presses nothing |
| H2–H4 | **Problem found and fixed** | While a track is soloed, Logic blinks the other tracks' mute LEDs by alternating on and off messages (not the “flashing” state). Because of this the original code refused every operation after a solo, and could also press the wrong mute. After the fix: during a solo the mute value is `null` with the reason given; mute operations are refused; other operations work normally |
| I1 | Pass | `mixer 1 volume -3` during playback returns `failed`; the log shows that no message was sent |
| I2 | Pass | No Select (`90 18`–`90 1F`) anywhere in the log during the whole test |
| Like E3 | Pass | `mixer 5 mute on オーディオ 4` (track 5 is actually `オーディオ 3`) returns `failed`; nothing pressed |
| J1 | Pass | `get_session_state` called through Claude (`include` with tracks): 11 tracks, Japanese names complete |
| J2 | Pass | `mixer_set` on track 5 (expected_name `オーディオ 3`), volume −8 dB, pan −15: `verified` (Logic reports −8.1 dB), then restored |
| J3 | Pass | One batch call muted tracks 1–4 and another batch call unmuted them, both `verified` |
| J4 | Pass | `mixer_set` during playback returns `failed`; nothing sent |
| — | Fixed | After the server restarted, the client did not fetch the tool list again (`mixer_set` did not appear). The server now declares `tools.listChanged` and sends `notifications/tools/list_changed` after initialization, and Claude Code then refreshes the list |

## Items not run

A2–A7, B2–B14 (including the 24-track project, deleting tracks, folders / stacks, modal dialogs), the long names / accents / curly quotes in section C, D2–D6, E1, E2, E4, F2, F6–F15, G2–G7, H6, H8, I3, I4. These need specially built projects and are left for later regression testing.
