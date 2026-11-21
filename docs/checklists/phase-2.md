# Phase 2 test checklist (real Logic 13)

Goal: confirm that “list all tracks, and adjust the volume / pan / mute / solo of any track” works in real Logic, and verify one by one the behaviour the code relies on that is not yet in [Logic 13 observed facts](../appendix/logic13-mcu-facts.md) (the rows concerned are tagged with a number **[#n]**, which refers to the “Assumption list” at the end of this document).

> Menu names are those of Logic's English UI. The tests were run on Logic 13.0 with the Japanese
> UI, so these names come from Apple's English documentation and have not been checked on an
> English-UI Logic yet.

Prerequisites:

- Steps 0–5 of [Phase 1 setup](../setup/01-phase1-logic-setup.md) are done (in particular, “Touching fader selects track” and “Control surface follows track selection” must both be **off**).
- For the Accessibility part, permission is granted as in [Phase 2 setup](../setup/02-phase2-accessibility.md) (section E specifically tests the case without permission).
- Use a **new test project**, not a real one: the tests change faders, pan, mute and solo.
- Logic is **stopped** (unless an item asks for playback).

Project preparation (called “project P” below): **24 tracks**, named as in this table (top to bottom):

| Track | Type | Name |
|---|---|---|
| 1–2 | Software Instrument | `Inst 1`, `Inst 2` |
| 3–11 | Audio (mono) | `オーディオ 1` … `オーディオ 9` (the Japanese UI's default names; “Audio 1” … “Audio 9” in the English UI) |
| 12 | Audio (stereo) | `Lead Vocal Double` (long ASCII name) |
| 13 | Audio | `Café Ü` (accented letters) |
| 14 | Audio | `ボーカル` (“Vocal”; entirely Japanese) |
| 15 | Audio | `Bass ‘DI’` (curly quotes) |
| 16–17 | Audio | `Audio 10`, `Audio 11` (both `Audio` on the LCD) |
| 18–24 | Audio | `Gtr 18` … `Gtr 24` |

(There is a specific limitation when 9 or more consecutive tracks are identical on the LCD; it is tested separately in B9, so project P has at most two tracks with the same abbreviation.)

For each item, fill in what you actually see in the last column. Keep the console's log files (`~/logic-pro-mcp/var/logs/console-*.log`) and tell Claude their paths when you are done. The console and the server cannot run at the same time: use the console for A–I and Claude for J.

Common console commands: `tracks` (scan all tracks), `mixer <track> <volume|pan|mute|solo> <value> [expected name]`, `lcd`, `press <button>`, `status`.

---

## A. View switching

| # | Action | Expected | Actual |
|---|---|---|---|
| A1 | Reopen the console (the surface goes back to the channel view `PN.` it has on connection), note `assign=` with `lcd`, then `tracks` | `tracks` succeeds; `warnings` contains “Switched the control surface from the "PN." view to the multi-track Pan view”; afterwards `lcd` shows `assign=PN` | |
| A2 | `tracks` again | Pan is not pressed again (no new `OUT 90 2A` in the log) | |
| A3 | `press nameValue` (the lower row becomes `Pan Pan …`), then `tracks` | `warnings` contains “from parameter names to values”; every `pan` is read **[#9]** | |
| A4 | `press assignTrack` (or Send), note `assign=` and both rows with `lcd`, then `tracks` | `tracks` succeeds, and afterwards `assign=PN`. Note how assign changes before and after Pan is pressed **[#7][#8]** | |
| A5 | In the `PN` state, `press assignPan` once, then `lcd` | Note whether assign becomes `PN.` (the code never presses Pan in `PN`; this only confirms why) **[#7]**; then `tracks` to restore | |
| A6 | `press flip`, then `lcd`, `status` (check whether `leds_lit` includes flip) and `tracks`; then `press flip` again to turn it off | `tracks` returns `failed`, saying Flip is on, and **no banking button was sent** **[#10]** | |
| A7 | `press globalView`, `status`, `tracks`; then `press globalView` again to turn it off | Note whether the globalView LED is on or flashing; when it is on, `tracks` returns `failed` **[#10]** | |

## B. Banking and track count

| # | Action | Expected | Actual |
|---|---|---|---|
| B1 | Project P, `tracks` | `track_count` 24; note how many seconds the whole command took | |
| B2 | `chord option bankLeft`, then `press channelRight` 20 times, with `lcd` after each | Each press moves exactly one track to the right (the name in strip 1 becomes the next track each time) **[#2]** | |
| B3 | Keep doing `press channelRight` until the LCD no longer changes, note the upper row of the last page, and press once more; then `press channelLeft`, `lcd`, then `press channelRight`, `lcd` | Which track does the last page start at? Is strip 8 blank? After the extra press the log shows that **Logic sends nothing**; Channel Left moves back exactly one track, and Channel Right returns to the last page **[#3][#5][#46]** | |
| B4 | On the last page, `chord option bankLeft`, `lcd` | Back to page 1 (`Inst 1 Inst 2 1 …`) **[#1]** | |
| B5 | On page 1, `press bankRight`, `lcd`; `press bankRight`, `lcd` again; then once more | The first press changes the page from starting at `Inst 1` to starting at track 9, the second to starting at track 17 (in the middle of the list it moves exactly 8 tracks); just record the result of the third **[#4]** | |
| B6 | `press channelRight` 3 times, then `press bankRight`, `lcd` | Record: after Bank Right from the page starting at track 4, which track does the page start at (12? or aligned to 9 / 17?) **[#4]** | |
| B7 | Delete tracks from project P down to **3 / 7 / 8 / 9 / 16 / 17** tracks in turn (delete the tracks at the end of the project); each time run `tracks`, then `chord option bankRight`, `lcd` | `track_count` is correct each time and `status` is `verified`; `evidence` explains how the end of the list was confirmed (with 3 and 7 tracks it is “answered Name/Value”, the log has two `OUT 90 34`, and the lower row still shows values afterwards); record the first track of the last page and the number of blank strips each time **[#3][#5][#47]** | |
| B8 | Back to 24 tracks. `press channelRight` 5 times (the surface is now at track 6), `tracks`, then `lcd` | After the scan the surface is back at the page starting at track 6 (no “original bank position” in `warnings`) | |
| B9 | New project: 10 audio tracks with exactly the same name (all called `Audio`, no parameters changed), `tracks`; then `mixer 10 mute on`, `mixer 5 mute on`, then both `off` | If strip 8 on the last page is blank: `track_count` 10, `verified`, and `evidence` contains “press(es) showed no change” (when all 8 strips are identical, the scan keeps pressing until the blank strip moves in); if the last page has no blank strip: `unverified`, with “8 strips with the same name and values” in `warnings`. Record the time taken. Both `mixer` commands are `verified`, and the tracks muted in Logic really are tracks 10 and 5; for `mixer 5`, the log has two `OUT 90 34` after Option + Bank Left, and the lower row still shows values afterwards **[#29][#44][#45]** | |
| B10 | In project P, create a **folder track** (put 16–18 in it and collapse it) and a **track stack**, and **hide** a track (H), then `tracks` | Record: whether the folder / the stack's main track / collapsed or hidden tracks appear on the surface; whether the order matches the main window **[#26]** | |
| B11 | During a scan (while `tracks` is running), watch Logic's main window | No track gets selected or changed **[#27]** | |
| B12 | New project: the English UI's default names `Audio 1` … `Audio 20` (or all 20 called `Audio`), no parameters changed; `tracks`, then `mixer 10 mute on`, `mixer 20 mute on`, then both `off` | `track_count` 20, `verified`; record the time taken (about 0.5 s per track for this kind of project). Both `mixer` commands are `verified`, and the tracks muted in Logic really are tracks 10 and 20; for `mixer 10`, the log has two `OUT 90 34` after a few Channel Right presses **[#29][#44][#45]** | |
| B13 | **While Logic is playing** (some tracks have volume / pan automation in Read mode), `tracks`, then stop | `tracks` succeeds (`verified`) and `track_count` is correct; record whether the values are the instantaneous values during playback, and whether `warnings` contains “original bank position” **[#37]** | |
| B14 | Make Logic open a modal dialog (for example Project Settings) and **leave it open**, then `tracks`; close the dialog and `tracks` again | With the dialog open: if Logic does not respond to the surface, `tracks` returns `failed` (“did not react” or “Could not confirm the end of the track list”) rather than an undercounted number of tracks; normal after the dialog is closed **[#3][#46][#47]** | |

## C. Track names (LCD)

Run `tracks` on project P and record each track's `lcd_name`:

| # | Track | The code's assumption | Actual `lcd_name` |
|---|---|---|---|
| C1 | `Inst 1` | `Inst 1` | |
| C2 | `オーディオ 1` | `1` | |
| C3 | `Lead Vocal Double` | `Lead V` (the first 6 characters) **[#28]** | |
| C4 | `Café Ü` | `Caf` (non-ASCII characters simply dropped) or `Cafe U` (accents removed); both are accepted **[#28]** | |
| C5 | `ボーカル` | Blank, but the lower row still shows the pan value, and it counts as a track **[#6]** | |
| C6 | `Bass ‘DI’` | `Bass D` (curly quotes dropped) or `Bass '` (curly quotes turned into straight quotes); both are accepted **[#28]** | |
| C7 | `Audio 10` | `Audio` (the first 6 characters are `Audio `, with the trailing space removed) **[#28]** | |

If the actual result differs from the assumption, the `warnings` of `get_session_state` list “Full names that do not match the LCD were not used”, and those tracks fall back to the LCD name. Please tell Claude the actual abbreviation rule.

## D. Track names (Accessibility)

| # | Action | Expected | Actual |
|---|---|---|---|
| D1 | With permission granted and all track headers on screen, `tracks` | All names are full names and `name_source` is `accessibility` (except where the abbreviation in section C does not match) **[#30][#33]** | |
| D2 | Shrink / scroll the main window so that only about tracks 5–12 are visible, `tracks` | `warnings` says only some names were read and which range of tracks they were matched to; the rest are LCD names **[#30]** | |
| D3 | Open the inspector (I), the Mixer (X), the Piano Roll and so on, `tracks` | Names are still correct (channel names in the inspector or the Mixer were not taken as track names) **[#30]** | |
| D4 | Open a second project window or a plug-in window in front, `tracks` | Names still come from the main window of the right project **[#30]** | |
| D5 | Record how much longer D1's `tracks` took than without permission | Just record it **[#32]** | |
| D6 | Quit Logic; start the console; **then** start Logic and open project P, `tracks` | Names are read (the server finds a Logic that was started after it) **[#41]** | |

## E. Without Accessibility permission

| # | Action | Expected | Actual |
|---|---|---|---|
| E1 | In Accessibility settings, turn off the permission of the terminal app that launches the console, reopen the console, `tracks` | Succeeds; `name_source` is `lcd` for all tracks; `warnings` explains that there is no permission **[#31]** | |
| E2 | `mixer 3 mute on オーディオ 1` | `verified`, with `warnings` noting that the name was checked only against the LCD abbreviation; then `mixer 3 mute off` | |
| E3 | `mixer 3 mute on Bass` | `failed` (name mismatch), **nothing pressed** | |
| E4 | `mixer 14 mute on ボーカル` | `failed` (an entirely Japanese name is blank on the LCD and cannot be checked without Accessibility), **nothing pressed** | |

## F. Volume

Use `mixer <track> volume <dB>` each time, and record the returned `status` and `evidence` and the value shown on Logic's fader:

| # | Action | Expected | Actual |
|---|---|---|---|
| F1 | `mixer 1 volume -6` | `verified`, Logic's fader shows −6.0 | |
| F2 | `mixer 3 volume -6` (audio track) | Same as above; note the echo value in `evidence` and whether it is the same as in F1 **[#19]** | |
| F3 | `mixer 4 volume -3.7`, `-17.1`, `-27.3`, `-45`, `-58.4`, `-80`, `+2.2`, `+6` | All `verified`; the value Logic shows differs from the request by ≤ 0.1 dB (≤ 1 dB below −60 dB); note how many corrections each one took (how many `E3 …` the log has for the same fader) **[#17][#18]** | |
| F4 | `mixer 5 volume -inf` | `verified`, Logic shows −∞ | |
| F5 | `mixer 1 volume +6` twice | The second time: “already … nothing sent” | |
| F6 | With the surface on page 1, `mixer 8 volume -12.8` | What dB text does strip 8's lower row show (cut to `-12.8 d`?); `verified` **[#15]** | |
| F7 | `mixer 2 volume -9`, then `lcd` immediately | Strip 2's lower row shows the dB text; note which character it starts at and how long it stays **[#15][#24]** | |
| F8 | After F1–F4, **play** a few bars in Logic and stop | The fader values did not change and no automation was written to the tracks (the automation mode stays Read) **[#20]** | |
| F9 | Drag track 2's fader with the mouse in Logic, then immediately `lcd` in the console | Note whether the LCD shows dB text; then whether `tracks` succeeds **[#36]** | |
| F10 | After `tracks`, compare the `volume_db` of the tracks set in F3 with the values Logic shows | Note the differences (during a scan the volume is interpolated from the fader position using the calibration table) **[#17]** | |
| F11 | With the surface on page 1, `mixer 8 volume -6`, then **immediately** `press channelRight`, `lcd` | Record: whether strip 8's lower row (now track 9) still shows `-6.0 dB`, or whether it has been replaced by track 9's pan value **[#38]** | |
| F12 | In Logic, drag track 6's fader with the mouse below −106 dB (above −∞), `tracks` | Record the value Logic shows and `volume_db` (this range is extrapolated with 20·log10) **[#40]** | |
| F13 | Set track 4's automation mode to **Touch**; while stopped, `mixer 4 volume -10`, `mixer 4 pan 15`; then play 4 bars, stop, and open that track's volume and pan automation | Both `verified`; **no automation points were written**, and the fader and pan stay at −10 / +15 **[#20]** | |
| F14 | Same as F13, but with the mode set to **Latch** (use track 5) | Same: no automation written **[#20]** | |
| F15 | `mixer 1 volume -6`, then `press channelRight` 8 times and `press channelLeft` 8 times (so that track 1 leaves the surface and comes back); check strip 1's fader position in `status` or the log | The fader position Logic sends when the track comes back equals the echo value in `evidence` at the start of F15 **[#48]** | |

## G. Pan

| # | Action | Expected | Actual |
|---|---|---|---|
| G1 | `mixer 2 pan -20` | `verified`; Inst 2's pan in Logic is −20 | |
| G2 | `mixer 7 pan 63`, then `mixer 7 pan 63` | The first is `verified`; the second “already … nothing sent” **[#13]** | |
| G3 | `mixer 7 pan 64` | `failed` (out of range), nothing sent | |
| G4 | First `mixer 7 pan 63`, then `vpot 7 1` in the console, `lcd` | Record: after reaching the limit, whether Logic still sends an LCD update when the V-Pot is turned one more tick **[#13]** | |
| G5 | `mixer 12 pan -30` (stereo track, shown as pan / balance) | `verified`; record the format shown in the LCD lower row **[#11]** | |
| G6 | On track 5, `mixer 5 pan 10`, then `lcd` immediately | Which strips of the upper row are covered by `Pan` (strips 5 and 6?), and how long until they recover **[#12][#14]** | |
| G7 | Change a track's panner to the Surround Panner (if the project is surround) or to Stereo Pan, `tracks` | Record that track's `pan` and `warnings` **[#11]** | |

## H. Mute / solo / record enable

| # | Action | Expected | Actual |
|---|---|---|---|
| H1 | `mixer 3 mute on`, then `mixer 3 mute on` | The first is `verified`; the second presses nothing | |
| H2 | `mixer 3 solo on`, then immediately `lcd`, `status` | `verified`; record whether text appears in the lower row (like `Muted` for mute) and whether `rudeSoloLED` is lit **[#21]** | |
| H3 | After H2, check `leds_lit` with `status` | Record whether the other tracks' mute LEDs are flashing **[#21]** | |
| H4 | After H3, `tracks` | Record whether the other tracks' `mute` is `false` or `null` (`null` when flashing, explained in `warnings`) **[#21]** | |
| H5 | `mixer 3 solo off`, `mixer 3 mute off` | Both `verified` | |
| H6 | In Logic, record-enable track 9, `tracks` | Track 9 has `rec_arm: true`; record whether the LED flashes during playback / recording **[#22]** | |
| H7 | `mixer 20 mute on` (needs banking) | `verified`, `Gtr 20` is muted in Logic; **no track is selected in the main window**; then `mixer 20 mute off` | |
| H8 | With the surface on page 1, `mixer 5 mute on`, then immediately `lcd`; then `mixer 5 mute off`, then immediately `lcd` | Strip 5's lower row shows `Muted`, then `--` (so far only observed on strip 1) **[#39]** | |

## I. Safety

| # | Action | Expected | Actual |
|---|---|---|---|
| I1 | `mixer 1 volume -3` while Logic is playing | `failed` (“playing or recording”); the log has **no** `E0`, `90 68` or any other message **[#35]** | |
| I2 | Select track 5 in Logic, then `tracks`, `mixer 20 mute on`, `mixer 20 mute off` | The selection does not change (still track 5); no `90 18`–`90 1F` in the log | |
| I3 | After `tracks`, **delete track 1** in Logic, then `mixer 3 mute on オーディオ 1` | The server notices that the track list changed and rescans; track 3 is now `オーディオ 2`, so the name check fails (`failed`) and **no track is muted** | |
| I4 | Turn on “Control surface follows track selection”, click track 20 in Logic, then `mixer 2 mute on` | Acts on track 2 (the server notices that the bank position was changed and relocates); turn the setting off after the test **[#34]** | |

## J. Use through Claude (MCP)

Quit the console and open a Claude Code session in `~/logic-pro-mcp`:

| # | Say to Claude | Expected | Actual |
|---|---|---|---|
| J1 | “List all tracks with their volume and pan” | Claude calls `get_session_state` (`include` with tracks) and lists 24 tracks, with complete Japanese names | |
| J2 | “Set the volume of オーディオ 3 to −8 dB and its pan to 15 left” | `mixer_set` returns `verified`; the values in Logic are correct | |
| J3 | “Mute tracks 1 to 4” | One batch call, `verified`; then “Unmute them” | |
| J4 | During playback, say “Set Inst 1 to −3 dB” | `failed`, explaining that Logic must be stopped first | |
| J5 | First say “List all tracks”; then, **within 30 seconds**, swap tracks 13 and 14, and tracks 16 and 17, in Logic (do not touch the surface), then say “In one mixer_set batch call with expected_name, mute track 13 Café Ü and track 16 Audio 10” | One batch call; the first entry notices that the track list changed, rescans and fails the name check; the second is **checked again** against the new scan and fails too; `failed`, **no track is muted** | |

---

## Assumption list (behaviour the code relies on that has not yet been observed on Logic 13)

| # | Assumption | Used in | How to verify |
|---|---|---|---|
| #1 | From any position (including the middle of the list and the last page), Option + Bank Left returns to page 1, and strip 1 of page 1 is track 1 | `MixerController.goToFirstPage`, the starting point of scanning and locating | B4, B8 |
| #2 | Channel Right moves exactly one track to the right from any position (only observed pressing it once or twice from page 1) | The scan moves one track at a time and checks | B2 |
| #3 | After the end is reached, pressing Channel Right makes Logic send nothing (only observed with Bank Right at the end); the end counts as confirmed only when pressing Channel Left / Channel Right afterwards (or pressing Name/Value twice when there are fewer than 8 tracks) shows the expected change (when Logic does not respond to the surface, the scan returns `failed`) | Deciding where the scan ends | B3, B7, B14 |
| #4 | In the middle of the list, Bank Right from a page starting at track 1, 9, 17 … moves exactly 8 tracks (only observed with 11 tracks, where it moved 4 tracks to the end); if not, the code falls back to Channel Right and reports it in `warnings` | `move(toOffset:)` fast locating | B5, B6 |
| #5 | Blank strips at the end have both rows empty; with fewer than 8 tracks, the blank strips on page 1 are the same (only observed for strip 8 with 11 tracks) | Dropping trailing blank strips, counting tracks | B3, B7 |
| #6 | A track whose name is entirely non-ASCII has an empty upper row, and its lower row still shows the pan value | Blank-named tracks in the middle still count | C5 |
| #7 | In assignments other than the channel view (`PN.`) (Track, Send …), pressing Pan once enters the multi-track Pan view `PN`; pressing Pan in `PN` enters the channel view (so the code never presses it in `PN`) | `ensureView` | A4, A5 |
| #8 | Assignment display `PN` = multi-track Pan view; the dot on the right = channel view (only observed for Pan) | `SurfaceViewState` | A1, A4 |
| #9 | In parameter-name mode, pressing Name/Value once switches back to values; parameter-name mode is detected by the lower row being entirely non-numeric text | `ensureView` | A3 |
| #10 | A lit Flip (`32`) or Global View (`33`) LED means that mode is on (only observed off, and Global View flashing while Option is held) | `ensureView` refuses to run | A6, A7 |
| #11 | For every track type, pan shows in the lower row as `0` / `+n` / `-n` (−64…+63), including the balance of stereo tracks; the surround panner is unknown | `MixerLCD.pan` | G5, G7 |
| #12 | Pan values and V-Pot behaviour on strips 2–8 are the same as on strip 1 | Reading and setting pan | G1, G6 |
| #13 | Each V-Pot tick is ±1, with one LCD update per tick (only observed on strip 1); at the upper / lower limit Logic no longer changes the value (the code reports a failure) | `setPan` closed loop | G2, G4 |
| #14 | While the V-Pot turns, `Pan` covers the track names of this strip and the strip to its right for about 2 seconds (only observed on strip 1) | Waiting for the overlay to clear before reading names | G6 |
| #15 | The dB text after a fader move is written from the start of that strip, in the format `-1.2 dB` / `-12.8 dB` / `-106 dB` / `-oo dB`; on strip 8 it is cut to `-12.8 d` (only observed on strip 1) | `MixerLCD.volume` | F6, F7 |
| #16 | After every fader move Logic sends the position back on the same fader channel (about 30 ms); when the position does not change it neither sends it back nor shows dB | `setVolume` | F1–F5 |
| #17 | dB is converted by linear interpolation between calibration points (only an approximation); the `volume_db` reported by a scan comes from this, with unknown error | `FaderCalibration`, scan results | F3, F10 |
| #18 | Above −60 dB, every 0.1 dB step can be reached by correction (tolerance 0.1 dB; 1 dB below −60 dB) | `setVolume` closed-loop correction | F3 |
| #19 | The calibration (measured on a software instrument track) is the same for audio, aux and all other channel strips | `FaderCalibration` | F2 |
| #20 | Moving a fader through the surface (with touch) while stopped writes no automation and does not select the track | `mixer_set` | F8, I2 |
| #21 | The solo LED (`08`+strip) has toggle semantics, lit = soloed; whether the lower row shows text while soloed is unknown; whether the other tracks' mute LEDs flash is unknown (the code treats flashing as uncertain and does not press) | `setToggle`, mute/solo in the scan | H2–H4 |
| #22 | Record-enable LED lit = record-enabled (observed); the meaning of flashing is unknown (read as `null`) | `rec_arm` in the scan | H6 |
| #23 | After banking, Logic sends only the LCD / LEDs / faders that changed (observed); as long as no message is lost, the surface state matches Logic | All reads | Logs |
| #24 | Temporary text (parameter names, dB, `Muted`, `Pan`) reverts after about 2 seconds (the code waits 2.6 seconds); whether banking clears it as well is unknown | `overlayHold`, waiting before reads | F7, G6 |
| #25 | After banking, Logic finishes redrawing within 500 ms, and one redraw is sent within 60 ms | `moveTimeout`, `settleQuiet` | Time taken in B1, logs |
| #26 | The channel order on the surface (Tracks mode) = the track-list order in the main window = the top-to-bottom order read through Accessibility; the behaviour of folders, stacks and hidden tracks is unknown | Track numbering, matching names | B10, D1 |
| #27 | Holding Option only lights the Select LEDs temporarily; it does not select tracks or change any other state | `goToFirstPage` | B11, I2 |
| #28 | ASCII names longer than 6 characters appear on the LCD as “the first 6 characters after trimming leading and trailing spaces”; whether accented letters and curly quotes are simply dropped (the observed rule) or turned into base letters / straight quotes is unknown, and both are accepted | `TrackNameMerge.lcdKey`, `lcdForms` (on a mismatch, falls back to the LCD name with a warning) | C3–C7 |
| #29 | When all 8 strips are identical (same names and values), pressing Channel Right shows no visible movement; the code keeps pressing (at most 32 times, waiting 500 ms each) until a different track or the trailing blank strip moves in; if the last page is right-aligned (no blank strip) or there are too many identical tracks, it returns `unverified` | Deciding where the scan ends | B9, B12 |
| #30 | Accessibility: the main window is AXMainWindow (or the focused window); track names are AXTextFields whose AXValue (or AXTitle) is the full name; they form one column (same x) and are the longest column of text fields in the window; fields whose description contains “track / トラック” (“トラック” is Japanese for “track”) are preferred; tracks scrolled out of the window may not be readable | `LogicTrackNameReader`, `TrackNameFieldSelector` | D1–D4 |
| #31 | Once Accessibility permission is granted to the app that launches the server (the Claude desktop app or a terminal), the server process can read | `AXIsProcessTrusted` | E1, D1 |
| #32 | Reading the main window's Accessibility tree finishes within 3 seconds and 40,000 elements | Time and count limits for reading | D5 |
| #33 | In the Japanese UI, AXValue is the track name (observed in the facts document: `Inst 1`, `オーディオ 1`) | Same as above | D1 |
| #34 | If “Control surface follows track selection” is on, clicking a track in Logic changes the bank position; before acting, the code checks by names and values which page the surface shows, and relocates or rescans if they do not match (if the surface is moved between two presses to a page that happens to look the same, this cannot be detected) | Locate check | I4 |
| #35 | Play LED off = stopped; `mixer_set` refuses to run when the Play LED state is unknown | `notStopped` | I1 |
| #36 | Whether the surface shows dB text when a fader is changed with the mouse in Logic is unknown; if it does, the scan waits for it to disappear | Waiting before reads | F9 |
| #37 | During playback, automation changes the fader and pan display; scanning, end confirmation and returning to the original position all judge bank moves by names only, so scanning also works during playback (when all 8 names are identical it has to use values, and may fail during playback) | Scan | B13 |
| #38 | Temporary text in the lower row (dB, `Muted`) may stay at its old LCD position after banking and cover the new track's value; the code waits for it to disappear after every bank move, and dB text counts as confirmation only if it appears or changes after this fader move (its disappearance does not count) | `bringIntoView`, `setVolume` | F11 |
| #39 | When strips 2–8 are muted, the lower row also shows `Muted` / `--` (only observed on strip 1) | Recognising temporary text | H8 |
| #40 | The dB for fader positions 1–98 (below −106 dB) is extrapolated from −106 dB with 20·log10 (not calibrated) | `FaderCalibration.level` | F12 |
| #41 | The server finds Logic through the process list (without depending on the main run loop), so it also finds a Logic opened after the server started | `LogicTrackNameReader.findLogic` | D6 |
| #42 | After `mixer_set` the surface stays on the page last operated on and does not return to its original position (only the `get_session_state` scan returns to the original position); the surface is virtual and has no effect on the project | `mixer_set` | `lcd` after any `mixer` |
| #43 | Logic 13 sends the position back after every fader move (not only on strip 1); if some version does not (as reported for Logic 11.2), the code confirms by the dB text and then does not trust that fader until Logic sends its position again | `setVolume`, `fader_position` in the scan | Echo in the `evidence` of F1–F3 |
| #44 | Logic processes surface button presses in order and does not drop earlier presses while processing later ones; each Channel Right that is processed moves exactly one track (no further once at the end). So if a later press shows the expected change, the earlier presses that showed no change each moved one track as well. If Logic drops a press in the middle of a series (for example when a modal dialog happens to open and close in between), and the pages before and after the dropped step look the same, the position is off by one and this cannot be detected | Identical consecutive 8 strips during a scan, identical-looking pages during locating, `confirmEnd` | B9, B12, B14 |
| #45 | When a page looks the same as other pages (same names and values) and the position cannot be confirmed from the display, the code presses Name/Value twice after moving: Logic switching the lower row to parameter names and back to values shows that it has processed all earlier presses in order (Option + Bank Left, the Channel Right presses that showed no change), so the number of presses is the position; if there is no reaction, nothing is done (depends on #1, #44, #47) | `move(toOffset:)`, `nameValueAcknowledged` | B9, B12 |
| #46 | On the last page, Channel Left moves back exactly one track, and Channel Right then returns to the last page (Channel Left only observed near the start of the list) | Confirming the end of the list | B3, B14 |
| #47 | In the multi-track view, pressing Name/Value changes the lower row to parameter names (`Pan`), and pressing it again returns to values, with the upper row unchanged; the same with fewer than 8 tracks (observed with 11 tracks, on page 1) | `nameValueAcknowledged`: confirming the end of the list when there are fewer than 8 tracks, confirming the position on identical-looking pages | B7, B9, B12 |
| #48 | Locating identifies each strip by name plus values (pan text, fader position, mute / solo / record-enable LEDs): when a track comes back onto the surface, the fader position, pan text and LEDs that Logic sends are the same as before (fader = the echo value after the move); values covered by temporary text, flashing LEDs and untrusted fader positions are left out of the comparison. On a mismatch the code assumes that the track list changed and rescans | `StripKey`, `move(toOffset:)`, `bringIntoView` | F15, H7 |
| #49 | The dB text is 8 characters wide and covers the first character of the next strip (that is, where the next strip's pan value is), so that strip's value is treated as unknown; when the text disappears, Logic rewrites the values of both strips (strip 1 → strip 2 was observed in the capture log: `lcd @56 "-1.2 dB "`, then about 2 seconds later `lcd @56 "0      0"`). Other strips not observed | `PageReading.keys` | F7 |
| #50 | Within the 30 seconds for which the scan result is cached, if tracks are inserted or deleted in Logic before the current page while the names on the surface's current page still match the old scan (and the count read through Accessibility is unchanged or unavailable), `mixer_set` still computes track numbers from the old scan; the strip acted on is checked by name and values, so it is that track in the old list. Also, if within the same 30 seconds tracks at the end were deleted, there is no Accessibility count to compare, the pages all look the same, and the last page is right-aligned, then the premise of the Name/Value confirmation (#45) that “none of these presses went past the end of the list” comes from the old scan, and Channel Right presses that reach the real end are still counted | `cachedLayout`, `move(toOffset:)` | I3, J5 |
| #51 | Only dB text, `Muted` and `--` in the lower row are recognised as temporary text; if Logic shows other temporary text (for example during solo, #21), locating takes it as a changed value, assumes that the track list changed and rescans (safe, but slower) | `StripKey`, `locate` | H2–H4 |
