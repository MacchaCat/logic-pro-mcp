# Phase 4 test results (real Logic 13.0)

Date: 2026-11-21  
Environment: Logic Pro 13.0 (Japanese UI), test project “Untitled 2” (unsaved, 120 BPM, 4/4), with the project's MIDI clock sent to `LogicMCP Sync` (Phase 1 step 5); target track `Inst 1` (Software Instrument, Ample Guitar); at the start `Inst 2` was selected (automatically record-armed)  
Run by: Claude through `logic-mcp console --fifo` (logs `var/logs/console-20261121-08*.log`), reading note positions in Logic's Event List (View > Show List Editors, Event tab)

> Menu names are those of Logic's English UI. The tests were run on Logic 13.0 with the Japanese UI, so these names come from Apple's English documentation and have not been checked on an English-UI Logic yet.

Not every item of the full checklist ([phase-4.md](phase-4.md)) was run; the items not run are listed at the end.

## First run: the record-arm model turned out to be wrong (fixed)

`write 1 13 C4:0:1,E4:1:1,G4:2:1,C5:3:1 Inst 1` returned `failed` and **did not send a single note**, but it exposed two problems:

1. After Rec was pressed for `Inst 1`, Logic itself turned off the Rec LED of `Inst 2` (the selected track, automatically armed). The code treated the Rec LEDs as part of the track identity, so it concluded “this page differs from the scan” and aborted.
2. When restoring, the code pressed Rec on `Inst 2` because “`Inst 2` was lit before the start”, which turned it from “automatically armed” into really armed (its LED started flashing). I pressed it once more from the console to restore the original state.

4 small experiments in the console followed (results recorded in [observed facts](../appendix/logic13-mcu-facts.md), “Record arm LEDs”): the LED of a manually armed track alternates on and off about every 0.73 seconds (all tracks in phase, steady while recording); when no track is armed manually, the selected track (instrument and audio alike) is armed automatically, with a steady LED; it goes off by itself when another track is armed; after the last manual arm is cancelled, Logic does not resend its LED until a page change redraws it.

Fix: the Rec LEDs are no longer part of the page identity; `get_session_state` no longer reports `rec_arm`; the new `readRecordArms` observes each page for 1 second (flashing / steady / off); `write_midi` presses Rec only on the target (unless it is already flashing) and on the other flashing tracks, confirms by observation that only the target is lit, and afterwards presses the buttons it pressed once more in reverse order, touching nothing else. The fake Logic gained a model of flashing and automatic arming, and new tests cover both “selected track” cases.

## Results

| Item | Result | Notes |
|---|---|---|
| H4 | Pass | `write 2 13 C4:0:1 Inst 1` (track 2 is `Inst 2`): `failed`, name check, nothing sent |
| A1 | Pass (after the fix) | Rerun with the same configuration: `partial`; evidence: only `Inst 1`'s Rec was pressed (off → on), the observation confirmed “only track 1 "Inst 1" is lit (alternating)”, Logic started rolling from SPP 176 (bar 12, one bar of pre-roll) with Continue, and 4 note-ons / 4 note-offs were sent; restoring pressed `Inst 1`'s Rec only once, and the observation afterwards was “as before” |
| A2 / I2 | Pass | The selected `Inst 2` (automatically armed) was never pressed; its LED went off by itself during recording and was steady again afterwards; nothing was recorded on `Inst 2` |
| A3 | Systematic offset found | Event List: `12 4 4 236`, `13 1 4 235`, `13 2 4 236`, `13 3 4 236`; every note is **5–6 ticks early** relative to the grid (about 3 ms); length about 1 beat; velocity 100. Logic names notes with C3 = MIDI 60 (`C4` is shown as C3 in Logic) |
| A7 | Pass | 205 / 205 Clock messages carried CoreMIDI timestamps; timestamp minus arrival time −0.02 … −0.18 ms (Logic does not send early); maximum scheduling error 0.46 ms |
| B1 | Same as above | 16 sixteenth notes: 15 were 5–6 ticks early; the last one, sent 2.6 ms late, landed almost on the grid, which shows a **fixed millisecond-scale offset**, not an accumulating error |
| B4 | **Calibrated** | Re-recorded with `offset=3`: **all 16 notes exactly on the grid** (`17 1 1 1` … `17 4 4 1`, each exactly one sixteenth note long). The default compensation was changed to +3 ms (`NoteWriteRequest.defaultTimingOffsetMs`), used by both `write_midi` and the console's `write` |
| — | **Addendum** | With the same default of +3 ms, in a later drum part (bar 25, 96 notes) some notes were still 5 ticks early (e.g. `25 1 4 236`), and the rest were exactly on the grid. 5 ticks (about 3 ms at 120 BPM) is roughly the length of one audio buffer: Logic's timing precision when recording MIDI appears to be about one buffer. +3 ms puts most notes on the grid but cannot remove this one-buffer jitter (the effect of the buffer size, B6, has not been tested yet; sending ahead with CoreMIDI timestamps might be sample-accurate, to be investigated) |
| C1 | Pass | Default +3 ms: C3 E3 G3 B3 all at `19 1 1 1`, 2 beats long; F3 A3 C4 all at `19 3 1 1`; the notes of each chord at exactly the same position |
| J5 | Pass | With Cycle on: `failed` (“Cycle is on”), nothing sent |
| — | Observation | In one run Logic sent no messages at all for 28 seconds, then reinitialised the whole control surface (back to the channel view), which coincided with the check after restoring, so the result said “could not read the Rec LEDs afterwards”. The restoring Rec press had already been made before the reset, and the record-arm state was confirmed correct afterwards. Cause unknown (Logic's main window was being minimised at the same time) |

## Items not run

- B2 / B3 / B6 (other tempos, buffer sizes): it is not yet known whether +3 ms is right for every tempo: if the offset is in fact a fixed number of ticks, it will be under-compensated at slow tempos and over-compensated at fast ones.
- Parts of the records for A4–A6, A5 (near bar 1), D (long notes, 64 bars), E (tempo changes), F (count-in settings), G (MIDI input filter), H1–H3, I1 / I3 / I4, J1–J4, J6–J9 (abort, Replace, during playback, clock turned off, jumps), K, L.
- Abort (J1) has tests on the fake Logic but has not been tested on real Logic yet.
