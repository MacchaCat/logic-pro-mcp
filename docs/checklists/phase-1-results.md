# Phase 1 test results (real Logic 13.0)

Date: 2026-11-20 (23:30–23:50)  
Environment: macOS 27.3, Logic Pro 13.0 (build 7801, Japanese UI, key command preset Simplified Chinese), logic-mcp 0.1.0  
Run by: Claude, sending commands through `logic-mcp console --fifo`; the settings in Logic's UI were made by Claude through computer use  
Test project: the open, unsaved project “Untitled 2” (two instrument tracks, Inst 1 and Inst 2; Inst 2 record-enabled)  
Raw logs: `var/logs/console-20261120-233019.log`, `console-20261120-233938.log`, `console-20261120-234737.log`

> Menu names are those of Logic's English UI. The tests were run on Logic 13.0 with the Japanese
> UI, so these names come from Apple's English documentation and have not been checked on an
> English-UI Logic yet.

## Results overview

| Item | Result | Notes |
|---|---|---|
| A0 | Not tested on real Logic | Logic installed the control surface automatically within 0.3 s, too fast to test; covered by the fake-Logic tests |
| A1 | No prompt | Once the ports appeared, Logic **installed** Mackie Control **automatically** (input and output both `LogicMCP MCU`, version showing the `1.00` we reply with, serial number blank) |
| A2 | Pass | Right after connecting it received the LCD, all LEDs, faders and display mode |
| A3 | `queried` | Logic sends the device query and the firmware query and **never sends the `02` reply**, but drives the control surface anyway |
| A4 | 10, 11, 15, 17 | Same as Logic 12.3; Logic also sends the same probes to `LogicMCP Sync` (that port has no output, so it is not installed as a surface) |
| B1–B4 | Pass | Play confirmed within 42 ms; repeated play / stop sends no message |
| B5 | Pass | With Replace off, recording starts directly; both the Record and Play LEDs confirmed |
| B5a | Pass | With no input, Logic creates no region; nothing extra in the track |
| B6 | Pass | After Replace was turned on through Mackie, record returned `needs_confirmation` and the Record button was not pressed |
| B7 | Pass | Tested in `serve` mode with another app frontmost and Logic in the background; play, stop and locate all `verified` |
| B8 | Pass | During playback the tempo estimated from the clock was 120 BPM (project tempo 120); the SPP position matched the time display |
| C | Pass (C5 not tested) | See “Time display format” below |
| D (method A) | **Not adopted** | The dialog opens and the digits are entered (the dialog shows the new position `17 1 1 1`), but the MCU's Enter did not press OK, and the playhead went to 1.1.1.1 instead; cause not found |
| E (method B) | Pass | Back to the beginning + each step forward is exactly one bar |
| F (Jog) | Pass | One tick is exactly one bar, aligned to bar lines in both directions; ticks sent in quick succession are unreliable |
| G1 | Recorded | After the port disappears, the Control Surfaces Setup window still shows `LogicMCP MCU` |
| G2 | Pass | When the port reappears, Logic re-probes and drives the surface within 0.3 s; no need to add it again |
| G3 | **Not tested** | The case where the port does not exist when Logic starts |
| G4 | Pass | After restarting the console 3 times, the Control Surfaces Setup window still has only 1 Mackie Control |
| H1–H2 | Pass | 2026-11-21: after this session moved to `~/logic-pro-mcp`, it loaded `.mcp.json` directly: client `claude-code 2.1.326`, protocol negotiation succeeded; `logic_status`, play (17 ms), stop, and locating to bar 9 (7 ticks, 1 second) were all `verified` |
| H3–H4 (token) | Pass | 2026-11-21: with chat-token confirmation now the default, `transport record` with Replace on returned `needs_confirmation` and a token; after the user agreed in the conversation, the call with the token was `verified` (Record LED lit within 23 ms), then recording was stopped and Replace turned off. The record-enabled track had no input, so no region was created. Token lifetime changed to 5 minutes |
| H3–H4 (dialog) | **Problem found** | The client declares support for confirmation dialogs (`client_supports_elicitation: true`), but the desktop app's Code tab **did not show the dialog and returned “decline” directly** (both times). The server treated this as a decline and did not send the Record button, so there is no safety issue; but recording in Replace mode could therefore not be confirmed. The server needs a setting to “use chat confirmation instead” |
| Locating (after implementation) | Pass | See below |

## Time display format (C)

- In Beats mode the digits are shown in groups of 3 / 2 / 2 / 3, each group right-aligned, with **no dots**: bar 1 shows as `  1 1 1  1`, and 2.3.1.217 read during playback shows as `  2 3 1217`.
- Positions read in testing: 1.1.1.1, 2.3.1.217, 5.1.1.1, 12.1.1.1, 17.1.1.1, 101.1.1.1, 3.4.1.92, 6.3.4.137, all parsed correctly.
- Logic sends only the digits that changed (one CC per digit), so wait for the display to settle before reading it (the implementation waits until there has been no update for 30 ms).
- On connection the BEATS LED is lit and the SMPTE LED is off, so `display_mode` is judged to be beats.

## Comparison of locating methods (D, E, F)

| Method | Result |
|---|---|
| A: Go to Position dialog + digits on the F keys | After the dialog opens, the LCD shows ` -` and `OK` (so modal dialogs **do** send output to the surface, contrary to community reports for Logic 12). After pressing F1 and F7 the LCD did not change, but checking the dialog afterwards, its “New” field **already read `17 1 1 1`**: the digits had in fact been entered. After pressing the MCU's Enter the playhead went to 1.1.1.1 instead of 17; cause not found. The screenset was not switched by mistake (still 1). **Not adopted** |
| B: back to the beginning + forward one bar at a time | 1→5 and 1→12 both accurate. Requires learning two key commands |
| C: Jog wheel | One tick +1 / −1 is exactly one bar; from mid-bar (6.3.4.137), +1 goes to 7.1.1.1 and −1 to 6.1.1.1. Each tick gets a response in 30–100 ms. Ticks sent back to back at 20 ms intervals are unreliable: +3 moved only 2, −6 moved 9 |

**Adopted: C** (a closed loop, one tick and one confirmation at a time): it uses only Mackie, does not depend on key commands, and can move in both directions.

Test results after implementation:

| Action | Result |
|---|---|
| Bar 5 → 17 | `verified`, 12 ticks, 1.5 s |
| Bar 17 → 101 | `verified`, 84 ticks, 10.5 s |
| Bar 101 → 3 | `verified`, 98 ticks, 12.4 s |
| Already at bar 3 | Nothing sent |
| From 3.4.1.92 → bar 9 | `verified`, stopped at 9.1.1.1 |
| Locating during playback | `failed`, nothing sent |

Speed is about 0.12 s per bar, so long-distance locating is slow; this can be optimised later (for example, “go to the beginning” first when the target is closer to the start).

## Problems found and how they were handled

1. **Logic's Controller Assignments window was in “learn” mode at the time** (waiting to learn a message for Show/Hide Editor; Japanese UI name (observed): `エディタを表示/非表示`). The SysEx with which the console answered the device query and the first Play message were both caught by the learn function. Logic showed one alert after another saying the control was already assigned to another parameter and asking whether to reassign it, and because of this the first Play press did not take effect.
   - Handling: clicked Cancel in every alert (no assignment changed), then turned learn mode off; the unfinished pending assignment disappeared with it.
   - Lesson: add a step to the setup guide: “before starting, make sure the Controller Assignments window is not in learn mode”.
2. In this project the LCD upper row showed `Pan    -      -  …` instead of track names. The Control Surface Group's Display Mode was Value; it may need to be switched to name display. To be handled in Phase 2.
3. The Key Commands window's Learn New Assignment button looks the same whether it is on or off: first select the command row, then click the button, then send the message. While learning Go to Beginning (Japanese UI name (observed): `先頭に移動`), two sends were not learned; **it was not confirmed whether those two `CC 21` messages were bound to some other command**. Open the Controller Assignments window in the foreground and confirm that “(No Zone)” contains only three new assignments: `CC 20`, `CC 21` and `CC 22`.
4. After testing, Logic's window list still contained a Go to Position dialog and a Settings window (both in other desktop spaces, possibly just leftovers of closed windows); the Control Surfaces Setup window had been minimised to the Dock.

## Changes Claude made in Logic

| Change | Where |
|---|---|
| (Logic, automatically) Added Mackie Control, port `LogicMCP MCU` | Control Surfaces Setup |
| Channel Strip View Mode: Arrange → **Tracks** | Control Surfaces Setup > Control Surface Group |
| Turned off “Control surface follows track selection” | Settings > Control Surfaces > General |
| Turned off learn mode in Controller Assignments, cancelled 3 or more reassign alerts | Controller Assignments window |
| Learned three key commands: Go to Position… (`CC 20`; Japanese UI name (observed): `位置を指定して移動…`), Go to Beginning (`CC 21`), Forward (`CC 22`; Japanese UI name (observed): `早送り`), all on `LogicMCP Keys`, channel 16 | Key Commands (Simplified Chinese preset) |
| Project sync: Destination `LogicMCP Sync`, Clock checked (Clock Mode was already correct) | “Untitled 2” > Project Settings > Synchronization > MIDI (project not saved) |
| Play, stop, record (no region created), Replace turned on and back off, playhead moves | “Untitled 2” |

## Still for you to do

- **Controller assignments**: open Logic Pro > Control Surfaces > Controller Assignments… in the foreground and confirm that only three assignments, `CC 20 / 21 / 22`, were added, and that Learn Mode at the bottom right is not lit.
- **Save the project**: “Untitled 2” now has unsaved changes; “MIDI clock sent to LogicMCP Sync” is a project setting, so if it is not saved it has to be set again next time.
- **H**: start a new Claude Code session in the `~/logic-pro-mcp` directory, allow the project's `logic-pro` MCP server, then have Claude call `logic_status`, play, stop, and locate to bar 9. Then turn Replace on and try recording once, to see whether a confirmation dialog appears (H3, H4).
- **G3**: quit Logic, start Logic while the port does not exist, then start the server, and see whether Logic connects automatically.
