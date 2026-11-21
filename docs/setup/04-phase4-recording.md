# Phase 4 setup: entering notes with `write_midi`

While Logic records, `write_midi` (`write` in the console) sends notes **in real time** through the `LogicMCP Notes` port. When each note is sent is aligned to the MIDI clock (Song Position Pointer + Clock) that Logic itself sends to `LogicMCP Sync`, not to an estimate from the server's wall clock.

Very little needs setting in Logic; most of it is "leave the default". Menu names are those of Logic's English UI. The tests were run on Logic 13.0 with the Japanese UI, so these names come from Apple's English documentation and have not been checked on an English-UI Logic yet. Names marked "(name not yet seen on this Mac)" have not yet been seen in Logic's UI on this Mac: go by what Logic actually shows, and tell Claude the correct name.

> Prerequisite: steps 0–5 of [Phase 1 setup](01-phase1-logic-setup.md) are done.

---

## 1. Required: MIDI clock to `LogicMCP Sync` (once per project)

This is **step 5** of the Phase 1 setup: on the **MIDI** tab of **File > Project Settings > Synchronization…**, set **Destination** in the first row to `LogicMCP Sync` and tick **Clock**; leave **Clock Mode** at its default ("Song—SPP at Play Start and Stop/SPP/Continue at Cycle Jump").

- In Phase 1 this step only decides whether the tempo can be read; **`write_midi` cannot work without it**: when Logic sends no Song Position Pointer, `write_midi` returns `failed` ("did not send a Song Position Pointer") before changing any track.
- If the same page has an item such as a clock delay / offset (Clock delay; name not yet seen on this Mac), keep it at **0**. When it is not 0, the clock Logic sends is offset from its own playback position, and all notes land early or late by the same amount.

## 2. Target track

- Use a **software instrument track** (or an external MIDI track). Mackie Control cannot tell the track type, so the server cannot check it; on an audio track, Logic records the audio at that track's input, not notes.
- Leave **MIDI Input** in the track inspector (name not yet seen on this Mac) at its default, "All". If it is set to receive from one port only, that port must be `LogicMCP Notes`; otherwise the notes are not recorded, and the server cannot detect that.
- There is **no need** to record-enable the track by hand: `write_midi` makes the target track the **only** track that will record, and restores the previous state afterwards. Logic 13's rules, as observed (2026-11-21):
  - Tracks record-enabled by hand (R pressed): the Rec LED **blinks** (about 0.73 seconds on, 0.73 seconds off, all record-enabled tracks in sync; steady while recording). Logic records only on these tracks.
  - When no track is record-enabled by hand, the **selected track** is record-enabled automatically: its Rec LED is **steady**. As soon as another track is record-enabled by hand, its LED goes out by itself.
  - So the server first watches the Rec LEDs of each bank of 8 tracks for 1 second (to tell blinking / steady / off apart), presses Rec once on the target (not if it is already blinking) and once on every other blinking track, then watches again to confirm that only the target is lit. At the end it presses **the buttons it pressed itself, the same number of times, in reverse order**, and touches no other track (earlier versions turned the selected track's automatic record-enable into a real one).
  - `get_session_state`, which reads the track list, no longer reports `rec_arm`: a single look at an LED cannot tell blinking from steady.
- Tracks that are hidden (H) or collapsed inside a folder are not visible on the control surface, so if they are record-enabled the server cannot disable them. Before using `write_midi`, make sure no such track is record-enabled.

## 3. Transport state

| Item | Should be | If it is not |
|---|---|---|
| Replace (name not yet seen on this Mac) | Off | `write_midi` first returns `needs_confirmation`: in Replace mode, recording **erases** the existing content of the target track from the start bar to where it stops. Claude calls again with the token only after you explicitly agree in chat |
| Cycle (name not yet seen on this Mac) | Off | `write_midi` refuses to run (the recording would repeat over the cycle range) |
| Autopunch (name not yet seen on this Mac) | Off | Only the notes inside the punch range are recorded. Mackie Control has no such state, so the server cannot see it |
| Count-in / pre-roll (Count-in; name not yet seen on this Mac) | Default | Observed: with the default settings, when recording from bar 9, Logic starts running from bar 8 (one bar of pre-roll). The server follows Logic's clock, so other settings should work in principle, but they have not been tested yet (checklist F) |

## 4. Controller assignments

- **Learn mode must be off** (Phase 1 setup step 1).
- Do not learn messages on the `LogicMCP Notes` port as controller assignments: a message "eaten" by an assignment does not reach the recording (research §3.7).

## 5. Recording over existing regions

Logic's "Overlapping MIDI recordings" setting (merge with the existing region, create a take folder, etc.; name and menu location not yet seen on this Mac) decides what happens when you record over existing regions. With Replace off, existing notes are not deleted.

## 6. Accessibility (recommended)

`write_midi` requires `expected_name` and checks it before record-enabling the track. Japanese and Chinese track names cannot be seen on the Mackie LCD; checking them needs the full names read through Accessibility, as set up in [Phase 2 setup](02-phase2-accessibility.md). Without the permission, a name made only of non-ASCII characters fails the check (and nothing is changed).

## 7. Run time and aborting

- By default `write_midi` delays every note by **+3 ms** (as observed, Logic 13 on this Mac otherwise records each note about 3 ms early at 120 BPM; see the [Phase 4 test results](../checklists/phase-4-results.md)). `write_midi` records **in real time**: one call takes about one bar of pre-roll plus the length of the notes themselves (at the project tempo), plus 10–20 seconds of preparation and wrap-up (reading the track list, watching the Rec LEDs for 1 second per 8 tracks × 2, another 2.2 seconds of watching after restoring, locating).
- No other tool can be called while it runs (tool calls are serial). **To abort, press Stop in Logic** (the space bar or the transport's Stop button): the server stops sending at once, sends note-off for notes still held, sends All Notes Off (CC 123) after stopping, restores the record-enable state and returns `failed`. If Logic has already stopped, the server does **not** press Stop again (that would move the playhead). What has already been recorded stays in Logic; undo it (⌘Z) if you do not want it.
- The recording time (from pressing Record to the end of the last note) is capped at 600 seconds. During recording the server keeps re-estimating it from the current tempo of Logic's clock; if tempo automation slows the tempo partway through and the estimate exceeds the cap, it also aborts early.
- After recording, the playhead stays where it stopped.

## 8. Calibration (console only)

The console's `write` command accepts `offset=<ms>`, which shifts all notes later (positive) or earlier (negative). Use it only if testing (checklist B) finds that Logic records the notes with a **fixed offset of some milliseconds**, and tell Claude the measured value so that it can become the default. Whatever the offset, **no** note is sent before Logic's clock reaches the first beat of the start bar: a negative offset makes notes near the start go out at that moment at the earliest (checklist B7).

The server aligns to the CoreMIDI timestamps Logic puts on its MIDI clock when they are present; without timestamps it uses the time each clock message reached the server. The result's `evidence` and `timing.clocks_with_timestamp` show which one was used (checklist A7).
