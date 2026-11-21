# Phase 1 test checklist (real Logic 13)

Two goals: confirm that the Phase 1 features work in real Logic, and answer the questions in research.md §9 that only real Logic can answer, above all “which method to use to jump to a given bar”.

> Menu names are those of Logic's English UI. The tests were run on Logic 13.0 with the Japanese
> UI, so these names come from Apple's English documentation and have not been checked on an
> English-UI Logic yet.

Prerequisites: steps 0–5 of [Phase 1 setup](../setup/01-phase1-logic-setup.md) are done; use a **new, empty project** with 2–3 instrument tracks, one of them record-enabled.

For each item, fill in what you actually see in the last column. Keep the console's log files (`~/logic-pro-mcp/var/logs/console-*.log`); when testing is done, just tell Claude their paths.

---

## A. Connection and handshake (research §9 #2, #4a)

| # | Action | Expected | Actual |
|---|---|---|---|
| A0 | **Before the control surface has been added**, type `play` in the console | `failed` (the explanation says Logic has only probed the port or has not sent any message); Logic does not play, and no notes appear in any track | |
| A1 | When the console was opened in step 1, did Logic show a prompt? What did it say? | Just record it | |
| A2 | Type `status` in the console | `mackie.messages_received` > 0; `surface.lcd_upper` has abbreviated track names | |
| A3 | `mackie.handshake` in the same `status` | `queried` or `confirmed` (`idle` means Logic sent no device query) | |
| A4 | `mackie.other_model_probes` in the same `status` | Just record it (Logic 12.3 probes 10, 11, 15, 17) | |

## B. Transport (part of the Phase 1 completion criteria)

| # | Action | Expected | Actual |
|---|---|---|---|
| B1 | Console `play` | `"status": "verified"`, Logic starts playing | |
| B2 | Type `play` again | `Already playing; nothing sent.` | |
| B3 | `stop` | `verified`, Logic stops | |
| B4 | Type `stop` again | `Already stopped; nothing sent.`, the playhead does **not** move | |
| B5 | Make sure Replace in Logic's control bar is off, then `record` | `verified`, Logic starts recording; then `stop` | |
| B5a | Open the region recorded in B5 (Piano Roll and Event List) | It contains **no** notes or controller events (button messages must not be recorded as a performance) | |
| B6 | Turn Replace on, `record` | `needs_confirmation`, **Logic does not record**; then turn Replace off | |
| B7 | Click into the terminal so that Logic is in the background, `play` then `stop` | Both `verified` | |
| B8 | Type `status` during playback | `sync.running` is true, `sync.tempo_bpm` is close to the project tempo | |

## C. Time display format (research §9 #4c; locating depends on it)

In Logic, put the playhead at each position below (while stopped). Each time, type `status` in the console and note `surface.time_display`, `surface.time_display_codes` and `transport.position`.

| # | Playhead position | `time_display` | `transport.position` |
|---|---|---|---|
| C1 | 1 1 1 1 | | |
| C2 | 5 1 1 1 | | |
| C3 | Around 17 3 2 120 | | |
| C4 | 101 1 1 1 | | |
| C5 | In the console, `press smpteBeats` to switch the display, then `status`; then press it again to switch back | Whether `transport.display_mode` changes between beats / smpte | |

## D. Locating method A: Go to Position dialog (research §2.5, §9 #11)

| # | Action | Expected | Actual |
|---|---|---|---|
| D1 | Console `dialog 5` | The console shows “LCD changed”, Logic opens the Go to Position dialog, the digits are filled in, and after Enter the playhead is at bar 5 | |
| D2 | `dialog 17` | Same, to bar 17 | |
| D3 | `dialog 123` | Same, to bar 123 | |
| D4 | If the dialog stays open on screen | Console `press cancel` closes it | |

If D1 shows “No dialog text appeared on the LCD”, Logic did not send text to the LCD while the dialog was open (or the key command was not learned successfully). Method A cannot be used; continue with E.

## E. Locating method B: back to the beginning + forward one bar at a time

| # | Action | Expected | Actual |
|---|---|---|---|
| E1 | Console `step 5` | The position printed at each step is bar 2, 3, 4, 5 in turn, ending at 5 1 1 1 | |
| E2 | `step 12` | Ends at 12 1 1 1; note roughly how many seconds the whole run took | |

## F. Jog wheel (calibration for locating method C)

| # | Action | Expected | Actual |
|---|---|---|---|
| F1 | Playhead at 1 1 1 1, console `jog 1`, then `jog 1` again | How far each one moves (see the printed time display) | |
| F2 | `jog 10` | How far it moves | |

## G. Port lifecycle (research §9 #2)

| # | Action | Expected | Actual |
|---|---|---|---|
| G1 | With Logic open, console `quit`. Check what the Control Surfaces Setup window shows for the Mackie Control's ports | Just record it | |
| G2 | Reopen the console, wait 3 seconds, `status` | `messages_received` > 0 (Logic reconnects automatically); if it is 0, the ports have to be selected again | |
| G3 | Quit the console, quit Logic; open Logic first (no ports exist at that point), then open the console, `status` | Same as above; does Logic warn at startup that the port does not exist? | |
| G4 | Open the Control Surfaces Setup window and count the Mackie Controls | Exactly 1 (an extra one means Logic installed it twice; note it down) | |

## H. Use through Claude (MCP)

1. Quit the console (the server and the console cannot run at the same time).
2. Copy `.mcp.json.example` at the repository root to `.mcp.json` and change the path in it to the absolute path of the repository on this Mac (`.mcp.json` is not under version control). It registers the `logic-pro` server, so there is no need to run `claude mcp add`.
3. Start a new Claude Code session in the `~/logic-pro-mcp` directory (CLI or desktop app). On first use it asks whether to trust this project's MCP server; choose allow.

| # | Say to Claude | Expected | Actual |
|---|---|---|---|
| H1 | “Call logic_status” | It connects; `client` shows the client name; is `client_supports_elicitation` true or false? | |
| H2 | “Make Logic play”, then “Stop” | Two `verified` | |
| H3 | Turn Replace on, “Start recording”, then **decline** | First a confirmation dialog appears (when H1 is true) or Claude asks you in the conversation; after you decline, Logic does not record | |
| H4 | Try again, and this time agree | Recording starts; then have Claude stop | |
| H5 | The Control Surfaces Setup window still has only 1 Mackie Control | Same as G4 | |

---

Fill in this table (or just send Claude a written description of what you observed) and send it back together with the log file paths. The rest of Phase 1, “jump to a given bar”, will be implemented based on the results of C–F.
