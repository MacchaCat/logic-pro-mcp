# Phase 4 test checklist (real Logic 13)

Purpose: confirm that `write_midi` (console `write`) records notes onto the right track at the right position in real Logic, and check one by one the behaviour the code relies on that is not yet in [Logic 13 observed facts](../appendix/logic13-mcu-facts.md) (the relevant rows are tagged **[#n]**, matching the “Assumptions” list at the end of this document).

> Menu names are those of Logic's English UI. The tests were run on Logic 13.0 with the Japanese UI, so these names come from Apple's English documentation and have not been checked on an English-UI Logic yet.

Prerequisites:

- Steps 0–5 of [Phase 1 setup](../setup/01-phase1-logic-setup.md) and [Phase 4 setup](../setup/04-phase4-recording.md) are done (**the MIDI clock of step 5 is required**).
- Accessibility is granted as described in [Phase 2 setup](../setup/02-phase2-accessibility.md) (H3 specifically tests the case without it).
- Use a **new test project**: the tests record and change record-arm states.
- Replace off, Cycle off, Autopunch off, Logic stopped.

Project setup (called “project R” below): 120 BPM, 4/4, 5 tracks:

| Track | Type | Name | Record arm at the start |
|---|---|---|---|
| 1 | Software Instrument (piano) | `Piano` | Off |
| 2 | Software Instrument (any) | `Synth` | Off |
| 3 | Audio | `オーディオ 1` (“Audio 1” in the English UI) | **On** |
| 4 | External MIDI (can be created without an external device) | `Ext` | Off |
| 5 | Software Instrument | `シンセ` (“Synth”; a name entirely in Japanese) | Off |

Console command format: `write <track> <start_bar> <pitch:start:dur[:vel],...|-> [cc=...] [bend=...] [offset=<ms>] [expected name]` (`cc=` / `bend=` and `-` for “no notes” are used in N; type `write` alone for the details). Beats are **quarter notes**, counted from the first beat of the start bar; a pitch can be written as `60` or `C4` (C4 = 60). `write!` confirms recording in Replace mode. Example: `write 1 9 C4:0:1,E4:1:1,G4:2:1,C5:3:1 Piano`.

For each item, fill in what you actually see. Keep the console logs (`~/logic-pro-mcp/var/logs/console-*.log`, which contain `SYNC` and `NOTES` lines) and give Claude their paths when you are done. A–L and N use the console, M uses Claude.

**How to read position errors**: Logic's Event List shows `bar beat division tick`; 1 sixteenth note = 240 ticks (960 ppq). To convert an error in ticks to milliseconds: `tick × 62.5 / BPM` (at 120 BPM, 1 tick ≈ 0.52 ms).

---

## A. Basic recording

| # | Action | Expected | Actual |
|---|---|---|---|
| A1 | `write 1 9 C4:0:1,E4:1:1,G4:2:1,C5:3:1 Piano` | Returns `partial`; `evidence` contains “only track 1 "Piano" is lit”, “Logic started its clock … at song position 112” and “sent 4 note-on(s)”; in Logic, a region with 4 notes appears on track 1 starting at bar 9 **[#1][#2][#3][#4]** | |
| A2 | After A1, look at track 3 (audio) | It was disarmed during recording (no new audio region) and armed again afterwards; `arm_after` equals `arm_before` **[#5][#6][#9]** | |
| A3 | Look at the 4 notes of A1 in the Event List | Positions near `9 1 1 1`, `9 2 1 1`, `9 3 1 1`, `9 4 1 1`; note how many ticks each note is off the grid; length about 1 beat; velocity 100 **[#1][#2][#3][#18]** | |
| A4 | `timing` in the A1 result | Note `start_bar_song_position` (should be 128), `bar_length_sixteenths` (16), `record_start_song_position` (112), `stop_song_position`, `max_scheduling_error_ms`, `clock_jitter_ms`, `display_start_bar_offset_sixteenths`, `clocks_with_timestamp`, `clock_timestamp_lead_max_ms` / `_min_ms` / `_mean_ms` **[#11][#26][#37]** | |
| A5 | Near bar 1, `write 1 2 C4:0:1 Piano` | The pre-roll starts at bar 1; record whether Logic sends `FB` (Continue) or `FA` (Start) after Record in the log, and whether the note is at `2 1 1 1` **[#14]** | |
| A6 | Watch the console log during recording | Whether the Rec LEDs (`90 00`–`90 07`) are steady or flashing (`01`) while recording; the Record / Play LEDs stay lit; **no** new `F2` (SPP) in the middle of recording **[#8][#13][#15]** | |
| A7 | The line about timestamps in the `evidence` of A1 | Record whether Logic's Clock carries CoreMIDI timestamps: “carried no CoreMIDI timestamps” (no), or “N of M clock messages carried CoreMIDI timestamps” (yes). If yes, note the max / min / mean lead (timestamp minus the moment it reached the server): clearly above 0 means Logic sends Clock early, and the server already aligns to the timestamps **[#3][#37]** | |

## B. Alignment accuracy (Event List)

After each recording, note the positions of all notes in the Event List and work out the deviation from the grid (ticks and ms).

| # | Action | Expected | Actual |
|---|---|---|---|
| B1 | 120 BPM: `write 1 9 C4:0:0.25,C4:0.25:0.25,…` (16 sixteenth notes, or have Claude generate the command) | All deviations within ±5 ticks (about ±2.6 ms); note the mean and the maximum deviation **[#1][#2][#3]** | |
| B2 | The same 16 notes, with the project tempo changed to 60 BPM | Note the mean / maximum deviation (ticks and ms) **[#1][#2][#3]** | |
| B3 | The same, at 180 BPM | As above **[#1][#2][#3]** | |
| B4 | Compare B1–B3 | If the mean deviation is **the same number of ticks** at all three tempos (e.g. 40 ticks = 1/24 beat each time), the assumption “the first Clock is exactly at the SPP position” is wrong **[#1]**; if it is **the same number of milliseconds**, there is a fixed latency **[#2][#3]**: re-record B1 with `offset=<-ms>` to see whether that removes it, and give Claude the value | |
| B5 | The position of the first note (beat 0) | At `9 1 1 1` or slightly later (not earlier than the start of the region, and not lost) **[#4]** | |
| B6 | Record B1 once with Logic's I/O buffer size set to the largest value and once with it set to the smallest | Note whether the mean deviation changes with the buffer size **[#2][#3]** | |
| B7 | `write 1 9 C4:0.25:0.5,E4:2:0.5 offset=-30 Piano` | The first note is **not earlier** than `9 1 1 1` (a negative offset does not move notes before the start bar); the second note is about 30 ms earlier than without the offset (about 58 ticks at 120 BPM) **[#4]** | |

## C. Chords

| # | Action | Expected | Actual |
|---|---|---|---|
| C1 | `write 1 9 C4:0:2,E4:0:2,G4:0:2,B4:0:2,F4:2:2,A4:2:2,C5:2:2 Piano` | 7 notes; the notes of one chord are at exactly the same position or a few ticks apart; note the difference | |
| C2 | `write 1 9 C4:0:1,C4:0.5:1 Piano` (the same pitch overlapping) | `warnings` says the first note was shortened to beat 0.5; two C4s in the Event List: beats 0–0.5 and 0.5–1.5 | |

## D. Long notes and notes across bars

| # | Action | Expected | Actual |
|---|---|---|---|
| D1 | `write 1 9 C3:0:6,G3:3.5:5 Piano` | C3 lasts 6 beats, from `9 1 1 1` to `10 3 1 1`; G3 from `9 4 3 1` to around `11 1 3 1`; the region ends slightly after the last note-off | |
| D2 | 64 bars: `write 1 9 C4:255:1 Piano` | Accepted, a little over 2 minutes; the last note around `72 4 1 1` | |
| D3 | `write 1 9 C4:256:1 Piano` | `failed` (“bars long”); only the playhead moved, no record-arm change, no recording | |

## E. Tempo changes

| # | Action | Expected | Actual |
|---|---|---|---|
| E1 | In the tempo track, change from 120 to 90 at bar 11 (a step), `write 1 9 C4:0:0.5,…` (one note per beat, 16 beats) | The notes before and after bar 11 are all on the grid (deviation of the same order as in B1); `tempo_bpm` is the average **[#25]** | |
| E2 | In the tempo track, a gradual change from 120 to 150 over bars 9–13, the same 16 notes | Note the deviations; whether they grow during the tempo change **[#25]** | |

## F. Count-in / pre-roll settings

| # | Action | Expected | Actual |
|---|---|---|---|
| F1 | Set Count-in to None, `write 1 9 C4:0:1,E4:1:1 Piano` | Note `record_start_song_position` and `pre_roll_sixteenths`; if it is 0, `warnings` contains “without pre-roll”; whether the first note is recorded at `9 1 1 1` **[#12][#4]** | |
| F2 | Set Count-in to 2 bars, the same as above | Note `pre_roll_sixteenths` (32?), whether the Record LED flashes during the count-in, and where the clock starts in the log **[#12][#15]** | |
| F3 | Restore the default settings | — | |

## G. MIDI input filter

| # | Action | Expected | Actual |
|---|---|---|---|
| G1 | Change the MIDI Input in track 1's inspector to another port (not `LogicMCP Notes`), `write 1 9 C4:0:1 Piano` | Still returns `partial` (the server cannot see it), but **no** notes are recorded: this setting must stay at its default **[#19]** | |
| G2 | Change it to receive only `LogicMCP Notes`, repeat G1 | The notes are recorded **[#19]** | |
| G3 | Restore “All” | — | |

## H. Track types and names

| # | Action | Expected | Actual |
|---|---|---|---|
| H1 | `write 3 9 C4:0:1 オーディオ 1` (audio track) | Record whether an audio region was recorded and whether any dialog appeared; whether the record-arm state is restored afterwards **[#9]** | |
| H2 | `write 4 9 C4:0:1,E4:1:1 Ext` (external MIDI track) | Record whether a MIDI region was recorded | |
| H3 | Turn off the Accessibility permission, then `write 5 9 C4:0:1 シンセ` | `failed` (the name cannot be checked), and **no** record-arm change or recording at all; after restoring the permission, try again: it succeeds | |
| H4 | `write 2 9 C4:0:1 Piano` (the name does not match the track) | `failed` (name check failed), no record-arm change or recording at all | |

## I. Record arm

| # | Action | Expected | Actual |
|---|---|---|---|
| I1 | In Logic, arm both tracks 2 and 3, `write 1 9 C4:0:1 Piano` | Only track 1 records; afterwards tracks 2 and 3 are armed again and track 1 is disarmed again **[#5][#6][#9]** | |
| I2 | Disarm all tracks, and **select** track 2 (Synth) in Logic. First check the Rec LEDs with `status`: is track 2 lit automatically? Then `write 1 9 C4:0:1 Piano` | Only track 1 records (no new region on track 2); afterwards track 2's Rec LED is the same as before **[#5][#7]** | |
| I3 | Arm track 2, then **hide** it (H), `write 1 9 C4:0:1 Piano` | Record whether track 2 also recorded the notes (the server cannot see hidden tracks, so they are expected to be recorded; this is a known limitation) **[#10]** | |
| I4 | Watch Logic's main window while Rec is being pressed | The track selection does not change, and no temporary text appears on the LCD **[#6]** | |

## J. Abort and safety

| # | Action | Expected | Actual |
|---|---|---|---|
| J1 | `write 1 9 C4:0:8,E4:4:4 Piano`; after the first note sounds, press the **Space bar** in Logic to stop | Returns `failed` (“Stopped after …”); in the log, **no** new note-on after the stop, a note-off for C4, and `B0 7B 00` (CC 123) last; no note hangs; the record-arm state is restored **[#16][#17][#31]**. Also: `evidence` contains “Logic stopped by itself … so Stop was not pressed”; in the log, **no** `OUT 90 5D 7F` (Stop button) from the server after Logic's `FC`; `stop_song_position` equals the value of the `F2` right after `FC` in the log; the playhead stays where it stopped **[#36]** | |
| J2 | The J1 region in the Event List | C4 ends at the stop point; **no** CC 123 event in the region **[#17]** | |
| J3 | `write 1 9 C4:0:1 Piano`; press Stop during the pre-roll bar (before the first note) | `failed` (“before any note”); record whether Logic leaves an empty region **[#16]** | |
| J4 | Turn Replace on, `write 1 9 C4:0:1 Piano` | Returns `needs_confirmation`, and **nothing is sent** (no `OUT` in the log); only `write! 1 9 C4:0:1 Piano` records. Under Replace, what range of the existing notes from bar 9 on is erased in the Event List: from the start bar to the stop point? Is the pre-roll bar erased? **[#21]** | |
| J5 | Turn Cycle on, `write 1 9 C4:0:1 Piano` | `failed` (Cycle is on), nothing sent **[#22]** | |
| J6 | `write 1 9 C4:0:1 Piano` while Logic is playing | `failed`, nothing sent | |
| J7 | Temporarily turn off the project's MIDI clock output (Phase 1 step 5), `write 1 9 C4:0:1 Piano` | `failed` (“did not send a Song Position Pointer”), only the playhead moved; restore the setting afterwards | |
| J8 | `write 1 9 C4:0:8,E4:4:4 Piano`; after the first note sounds, in Logic **turn off recording only and let playback continue** (press the Record button again, or use the Record Toggle key command) | Record whether Logic keeps playing, whether the Record LED goes off, and whether Logic sends anything on the Sync port. Expected: `failed` (“Record LED went off”); no more note-ons after that; a note-off for C4; about 300 ms later the server presses Stop (one `OUT 90 5D 7F` in the log), and CC 123 last **[#15][#38]** | |
| J9 | `write 1 9 C4:0:8,E4:4:4 Piano`; after the first note sounds, click another position in the ruler (the playhead jumps during recording) | Record what Logic sent in the log (a new `F2`? `FC` / `FB` / `FA`?). Expected: `failed` (“jumped”, “restarted” or “stopped”), no more note-ons after that, a note-off for C4, and CC 123 last **[#13][#39]** | |

## K. Play / record start position (“play starts one sixteenth note early”)

| # | Action | Expected | Actual |
|---|---|---|---|
| K1 | `locate 9`, `play`, `stop` (console), look at the log | On Play the SPP is 127 (one sixteenth note early, already observed); record the position after stopping | |
| K2 | `locate 9`, `record`, `stop` | On Record the SPP is 112 (a whole bar early); `write` uses Record, so it is not affected by K1 **[#12]** | |
| K3 | Change the same project to 3/4, `write 1 9 C4:0:1 Piano` | `bar_length_sixteenths` 12; `record_start_song_position` is the SPP of the start bar minus 12; the note is at `9 1 1 1` **[#11][#24]** | |
| K4 | Change to 6/8, `write 1 9 C4:0:1.5,E4:1.5:1.5 Piano` | `bar_length_sixteenths` 12; the two notes are on the 1st and 4th eighth notes of bar 9 (beats are counted in quarter notes) **[#24]** | |

## L. Other

| # | Action | Expected | Actual |
|---|---|---|---|
| L1 | Record A1 again over an existing region (Replace off) | Merged or recorded as a new take, according to the Overlapping MIDI Recordings setting; the existing notes do not disappear **[#20]** | |
| L2 | Turn Autopunch on (bars 10–11), `write 1 9 C4:0:1,E4:4:1 Piano`, then turn it off | Record: is only the E4 inside the punch range recorded? (The server cannot see Autopunch; this is a known limitation) | |
| L3 | `lcd` before and after recording; look at the surface's page position | The scan puts the surface back on its original page; record whether they match | |

## M. Using it through Claude (MCP)

Quit the console and start a Claude Code session in `~/logic-pro-mcp`:

| # | Say to Claude | Expected | Actual |
|---|---|---|---|
| M1 | “Write a C major scale (eighth notes) at bar 9 on the Piano track” | Claude calls `write_midi` (with `expected_name`), gets `partial`, and explains that the content was not read back; 8 notes appear in Logic | |
| M2 | With Replace on, say “Write a C chord at bar 17 on Piano” | After receiving `needs_confirmation`, Claude asks you in the chat; if you agree, it calls again with the token and records; if you do not, nothing is recorded | |
| M3 | Have Claude write a longer melody, and press Stop in Logic in the middle of recording | The tool returns `failed`, and Claude truthfully says that only part of it was recorded | |
| M4 | (after N) “Write a two-bar melody at bar 41 on Synth with a modulation swell and a pitch bend up into the last note” | Claude passes `controllers` (CC 1 ramp, pitch-bend ramp, and a bend back to 0 at the end), gets `partial`; the region has the notes, CC 1 and pitch bend events | |

## N. Control Change and pitch bend (added 2026-11-21, not yet run)

Before N: the feature is newer than the build the server last ran from. Run `swift build -c release` and restart the console (or the Claude Code session) first. Use track 2 `Synth` (an instrument that responds to the modulation wheel, pitch bend and the sustain pedal), and open the new region in the Event List after each item.

| # | Action | Expected | Actual |
|---|---|---|---|
| N1 | **Run first, without sending anything**: open Logic Pro > Control Surfaces > Controller Assignments…, switch to Expert View, select the assignment learned for Delete Track (`CC 29`) | Record the input port and MIDI channel it is bound to. Expected: `LogicMCP Keys`, channel 16. If so, CC 20–39 on channel 1 of `LogicMCP Notes` cannot trigger the key commands, and the server's refusal of CC 20–39 can be lifted **[#41]** | |
| N2 | `write 2 9 C4:0:4 cc=1:0:0>127:4 Synth` | `partial`; the region has C4 at `9 1 1 1` and CC 1 (modulation) events rising from 0 at `9 1 1 1` to 127 near `10 1 1 1`, about 128 events; the modulation is heard while recording **[#42][#43]** | |
| N3 | `write 2 9 C4:0:2 bend=0.5:0>8191:0.5,1:0 Synth` | Pitch bend events rising from the centre at `9 1 3 1` to the top at `9 2 1 1`, then back to the centre at `9 2 1 1`; the bend is heard going up and snapping back **[#42][#44]** | |
| N4 | `write 2 9 C4:0:1,E4:1:1 cc=64:1:127,64:3:0 bend=1:2000,2:0 Synth` | At `9 2 1 1` the CC 64 and pitch bend events come before E4's note-on in the Event List, and E4 sounds bent from its start; E4 rings on (sustain) until about `9 4 1 1` **[#45]** | |
| N5 | `write 2 17 - cc=11:0:100>40:4 Synth` (controllers only, no notes) | `partial`, and the summary counts controller messages; a region with only CC 11 (expression) events falling from 100 to 40 appears at bar 17 (or is merged, according to the Overlapping MIDI Recordings setting) **[#46]** | |
| N6 | `tracks`, note track 2's volume and pan; `write 2 25 - cc=7:0:64,10:0:20 Synth`; `tracks` again and look at track 2's channel strip | The result warns about CC 7 / CC 10. Record whether track 2's fader and pan moved. In File > Project Settings > MIDI, find the setting that decides whether CC 7 / 10 control the channel strip's volume / pan (name not yet seen on this Mac) and record its name and value **[#47]**. Restore volume and pan afterwards | |
| N7 | `write 2 33 C4:0:8 cc=64:0:127 bend=0:0>8191:8 Synth`; press Stop in Logic about two beats in | `failed` (“Stopped after …”); in the console log, after the stop: `B0 40 00` (sustain off), `E0 00 40` (bend centre), then `B0 7B 00` (All Notes Off). Afterwards, play track 2 with Musical Typing (⌘K): no pedal held, no bend. The region has no events after the stop point **[#48]** | |
| N8 | `write 2 9 - cc=29:0:127 Synth`, then `write 2 9 - cc=123:0:0 Synth` | Both return `failed` with nothing sent: CC 20–39 are refused for now, CC 120–127 are channel mode messages. No region is recorded, the playhead does not move | |
| N9 | Only if N2 or N3 recorded no controller events: check the input filter in File > Project Settings > MIDI (name not yet seen on this Mac) | Record whether Control Change / Pitch Bend are filtered; they must not be **[#42]** | |

---

## Implementation notes (where it differs from design document §3.8)

[The design document](../design.md) §3.8 still describes the original plan (that file is not changed in this phase). The actual implementation is as follows; this checklist and the code take precedence:

- **Locating**: the playhead moves directly to `start_bar` (not to the bar before), and the pre-roll is Logic's own recording pre-roll (one bar, observed). The server does not assume a pre-roll length and only follows Logic's clock; it aborts if the clock only starts after the start bar.
- **Record arm**: the target does not have to be armed manually beforehand, and other tracks do not have to be disarmed. The server uses the Mackie Rec buttons to make the target the **only** armed track (confirmed by reading all Rec LEDs again), and restores the original state afterwards; a failed restore is reported in `summary`.
- **Sending**: CoreMIDI timestamps are not used to schedule ahead. A dedicated high-priority thread sends each note immediately (timestamp 0) when Logic's clock reaches its position; if the Clock messages from Logic carry timestamps, alignment follows the timestamps (#37). Nothing is sent before the Clock for the first beat of the start bar arrives (#4).
- **Stopping**: when Logic stops by itself, the server no longer presses Stop (#36); the stop position is taken from the SPP that immediately follows `FC`.

---

## Assumptions (behaviour the code relies on but that has not yet been observed on Logic 13)

| # | Assumption | Used in | How to verify |
|---|---|---|---|
| #1 | The **first** Clock after Continue / Start is at tick SPP × 6, and each later Clock adds 1 tick (the convention of the MIDI spec); the moment a Clock arrives is the moment Logic's playback position reaches that tick. The capture logs can only confirm this to about ±1 tick: the timecode display differs from this convention by 0.3–0.5 tick (the Clock slightly ahead of the display); by this convention the 247th Clock is tick 918 (= SPP 153.0), and it arrived in the same millisecond as `FC`, yet after stopping Logic reported SPP 152. So Logic's Clock may run **ahead** of its own playback position by up to about 1 tick (about 20 ms at 120 BPM); in that case, notes on beat 0 would be recorded before the start of the region, or lost. The capture logs record arrival times, not CoreMIDI timestamps: if the lead comes from Logic stamping Clock messages with future timestamps, the server now aligns to the timestamps and the lead is gone (see #37, A7) | `SyncTimeline`, `NoteScheduler` | B1–B5, A7 (a fixed **tick** deviation at all three tempos means the convention is wrong; a beat-0 note earlier than `9 1 1 1`, or lost, means the Clock runs ahead) |
| #2 | Logic converts notes to recording positions by their **arrival time** (the server sends with timestamp 0 = immediately); there is no fixed latency compensation larger than a few milliseconds | Real-time sending | B1–B4, B6 (a fixed **millisecond** deviation) |
| #3 | If Logic's Clock carries CoreMIDI timestamps, the timestamp is the moment Logic's playback position reaches that tick (the server aligns to it); without timestamps (0), Clock is sent in real time: the moment it reaches the server (recorded in the CoreMIDI callback, unaffected by task switching inside the server) ≈ the moment Logic's position reaches that tick | `SyncTimeline`, `NoteScheduler`, the meaning of `max_scheduling_error_ms` | A7, B1–B4, `display_start_bar_offset_sixteenths` in A4 |
| #4 | **No** note is sent before Logic's Clock reaches the first beat of the start bar (by its timestamp); after that, notes on the first beat are sent immediately, get recorded, and are not earlier than the start of the region. A negative offset does not make notes earlier than this moment either | `NoteScheduler.dueTime` (every note waits for the Clock at the start point) | B5, B7, F1 |
| #5 | Only record-armed tracks record: when one track has been explicitly armed, a selected but unarmed software instrument track does not record (2026-11-21: the steady LED of the selected track goes off by itself once another track is armed, consistent with this) | The “only armed track” logic | I1, I2 |
| #6 | Pressing a Mackie Rec button (`00`–`07`, press and release) toggles record arm of the track on that strip, and Logic answers within 800 ms with a steady Rec LED (`7F` / `00`); it does not change the track selection or show temporary text on the LCD | `MixerController.setToggle` (record arm) | A1, I1, I4 |
| #7 | ~~Logic does not automatically arm a software instrument track because it is “selected”~~ **Does not hold** (2026-11-21): when no track is armed manually, the selected track (software instrument and audio alike) is armed automatically, with a steady Rec LED; the LED goes off when another track is armed; after the last manual arm is cancelled, Logic does not resend its LED until a page change redraws it. The code now observes flashing / steady | Observation before and after arming | I2 |
| #8 | ~~After stopping, the Rec LED is steady / off (not flashing)~~ **Does not hold** (2026-11-21): the LED of a manually armed track flashes with on and off messages (about 0.73 seconds), and is steady while recording. Restoring only presses again the buttons the server itself pressed | Restoring record arm | A6, A2 |
| #9 | Disarming / re-arming an audio track does not open a dialog (for example because the input is in use), and after restoring, the state is the same as before | Restoring record arm | A2, I1, H1 |
| #10 | Hidden or collapsed tracks are not record-armed (the server cannot see them) | The “only armed track” check | I3 |
| #11 | When locating, the SPP Logic sends after each Jog step arrives before the timecode settles and `locate` returns, so “the last SPP after locating” is the position of the target bar; the difference between the SPPs of two adjacent bars is the length of that bar (in sixteenth notes) | Start position, bar length, the 64-bar limit | A4, K3 |
| #12 | When recording, Logic starts from before the playhead (or exactly at it), sending SPP first, then Continue / Start and Clock; the count-in setting only changes the length of the pre-roll. The code aborts if Logic starts later than the start bar | `waitForClockStart` | F1, F2, K2 |
| #13 | During normal recording Logic sends no more SPP (only when the playhead jumps); any SPP received after recording has started is treated as a jump and aborts | `NoteScheduler.transportProblem` | A6 |
| #14 | When pre-rolling from bar 1 (start bar 2), Logic may send either Continue or Start; SPP cannot represent positions before bar 1, so the start bar is at least 2 | Input check, `waitForClockStart` | A5 |
| #15 | During recording the Record LED stays lit (or flashes), and it goes off when recording stops; the LED going off means abort | Monitoring | A6, F2 |
| #16 | Pressing Stop on the surface stops recording and keeps the recorded region; if recording stops before any note has been sent, an empty region, if one is left, is harmless | Abort flow | J1, J3 |
| #17 | Note-offs sent during recording end the recorded notes normally; note-offs and CC 123 sent after Logic stops are not recorded, and they silence the instrument | Abort flow | J1, J2 |
| #18 | Velocities 1–127 are recorded as sent; note-off velocity 0; MIDI channel 1 | The messages sent | A3 |
| #19 | The target track's MIDI input is the default “All” (or `LogicMCP Notes`); the server cannot see this setting | Cannot be checked | G1, G2 |
| #20 | With Replace off, recording does not delete existing notes (overlaps are merged or recorded as a new take according to Logic's setting) | `needs_confirmation` only when Replace is on / unknown | L1 |
| #21 | Replace mode only erases the armed track (only the target), from the start bar to the stop point, and does not erase the pre-roll bar | The wording of the confirmation prompt | J4 |
| #22 | A lit Cycle LED (`56`) means Cycle is on (the report for “off” has been observed, “on” has not) | Precondition check | J5 |
| #23 | During recording the timecode shows the running position in Beats (quarter notes as beats, sixteenth notes as divisions, 240 ticks per division); used only for the circumstantial evidence `display_start_bar_offset_sixteenths` | Evidence | A4 |
| #24 | MIDI Clock is always 24 per **quarter note**, whatever the denominator of the time signature; a “beat” in the tool is a quarter note | Position conversion | K4 |
| #25 | Changes in the tempo track are reflected in real time in the Clock intervals, without separate SPP | The tempo estimate in `SyncTimeline` | E1, E2 |
| #26 | The jitter in the server's latency handling Logic's messages is about 1 ms (`clock_jitter_ms`), so extrapolating a least-squares line through the last 24 Clocks is accurate enough | `SyncTimeline.fix` | A4, B1 |
| #27 | Notes sent from a virtual source (timestamp 0) are handed to Logic immediately by CoreMIDI | Real-time sending | B1–B4 |
| #28 | All the notes are within the time signature of the start bar (the 64-bar limit is computed from the length of the start bar) | Limit check | D2, D3 |
| #29 | The project's MIDI sync settings have no clock delay / offset (default 0); Clock Mode is the default “Song…” | The setup document | B4, J7 |
| #30 | The `LogicMCP Notes` port is not “eaten” by controller assignments (Learn Mode is off) | The setup document | A1 |
| #31 | When Logic is stopped from within Logic (Space bar, transport buttons), Logic also sends `FC` on the Sync port (only stopping from the surface has been observed) | Abort detection (in addition to the Record LED) | J1 |
| #32 | Autopunch is off (this state is not visible on the Mackie) | Cannot be checked | L2 |
| #33 | The bar **after** the start bar can be reached with Jog (it is not past the end of the project); at bar 999 the previous bar is used instead. If it cannot be reached, `write` fails before changing any track | Measuring the bar length | Try once at the last bar of the project |
| #34 | SPP is 14-bit, at most 16383 sixteenth notes (about 1024 bars in 4/4); with long-bar time signatures (e.g. 7/4) it overflows after about 585 bars, and the code does not check this | Start position | No test needed; avoid it in use |
| #35 | Reading the track list and the Rec LEDs depends on Phase 2 assumptions ([Phase 2 checklist](phase-2.md) #22 the meaning of the Rec LED, #23 only changed LEDs are sent after a page change, #27 Option does not change the selection, etc.) | The three scans before and after arming | Phase 2 checklist |
| #36 | When Logic stops by itself (Space bar, transport buttons, Stop on the surface), it first sends `FC` and an `F2` with the stop position on the Sync port, and then turns off the Play / Record LEDs within 300 ms (in the capture, stopping from the surface: `FC` 23.813, `F2` 23.815, LEDs 23.817). After it sees `FC` or the Record LED going off, the server waits at most 300 ms, and once both LEDs are off it **does not press Stop** (pressing Stop on an already stopped Logic moves the playhead); `stop_song_position` is taken from the `F2` that immediately follows `FC` | `NoteWriter.waitForOwnStop`, `stopSongPosition` | J1, J3 |
| #37 | The CoreMIDI timestamps Logic puts on Clock messages (if any) are host time (`mach_absolute_time`), and CoreMIDI hands them unchanged to the virtual destination (packets with future timestamps are delivered early). In the receive callback the server reads both the host time and `ContinuousClock` and converts using the difference; when the timestamp is 0 or more than 1 second away from the arrival time, the arrival time is used | `VirtualPorts`, `HostTime.instant`, `SyncMonitor` | A7; the self-test `syncDestinationKeepsPacketTimestamps` (needs `LOGIC_MCP_REAL_MIDI_TESTS=1` and creates real ports; run it only when Claude asks) |
| #38 | When only recording is turned off during recording and playback continues (Record LED off, Play LED on), Logic stops recording from that moment; the server stops sending, waits about 300 ms and presses Stop; note-offs sent in between are not recorded | Monitoring (Record LED), `waitForOwnStop` | J8 |
| #39 | When the playhead jumps during recording, Logic sends a new SPP (or Stop / Continue / Start) on the Sync port; any of these makes the server stop sending | `NoteScheduler.transportProblem` | J9 |
| #40 | The timestamps Logic puts on Clock messages are never more than 1 second away from the arrival time. For a timestamp more than 1 second away, the server **silently** falls back to the arrival time (so that a bad timestamp cannot push sending far into the future); in that case alignment falls back to the “real-time arrival” assumption of #3 | `HostTime.instant` | A7 (`clock_timestamp_lead_max_ms` / `_min_ms` should both be within ±1000, and `clocks_with_timestamp` should equal the total number of Clocks) |
| #41 | Logic's controller assignments match the input port and MIDI channel: the assignments learned from `LogicMCP Keys` channel 16 do not react to the same CC number on `LogicMCP Notes` channel 1 | Refusing CC 20–39 (`ControllerSpec.reservedControllers`) is only a precaution until this holds | N1 |
| #42 | Control Change and pitch bend messages that arrive on `LogicMCP Notes` while recording are recorded into the same region as the notes, at their arrival positions; Logic's default input filter lets them through | Controller recording | N2, N3, N9 |
| #43 | Ramp steps (at most one every 1/48 quarter note, only where the value changes) are recorded as separate events; Logic does not thin them out while recording | Ramp expansion in `NotePlan.expand` | N2 |
| #44 | Pitch bend is 14-bit with 8192 = centre (value 0 in the tool, −8192…8191); how many semitones that is depends on the instrument's bend range | Pitch bend conversion | N3 |
| #45 | Events at one position keep the order they arrived in (note-offs, controller changes, note-ons) when Logic records and plays them back | Same-position order in `NotePlan.Group.messages` | N4 |
| #46 | A recording with only controller events still creates a region (it is not dropped as empty) | Calls with controllers but no notes | N5 |
| #47 | CC 7 / CC 10 may also move the channel strip's volume / pan, depending on a project MIDI setting | The CC 7 / 10 warning | N6 |
| #48 | Sustain off and pitch-bend centre sent after Stop are not recorded and return the instrument to normal; CC 64 = 0 releases notes the pedal holds (All Notes Off alone does not) | Resets after Stop (`NoteWriter.resetMessages`) | N7 |
