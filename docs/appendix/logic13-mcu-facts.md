# Logic Pro 13.0 Mackie Control: observed facts

Captured 2026-11-20/21 on this Mac with `logic-mcp console` against real Logic Pro 13.0
(build 7801, Japanese UI). Raw traffic logs are in `captures/`. Every statement here was
observed, not assumed; anything not listed is still unverified. Logic menu, window and
key-command names are given as in Logic's English UI (taken from Apple's English documentation,
not checked on an English-UI Logic yet); Japanese strings that are themselves observed data
(track names, LCD text, Accessibility strings, alert text) are kept as recorded, with an English
gloss.

Test project: 11 tracks — `Inst 1`, `Inst 2` (software instruments), `オーディオ 1` … `オーディオ 9`
(audio; the Japanese UI's default audio-track names, "Audio 1" … "Audio 9" in the English UI).
Surface group: Channel Strip View Mode = Tracks, Clock Display = Beats.

## Connection

- Logic probes every new destination with `F0 00 00 66 <10|11|17|14|15> 00 F7` and `… 13 00 F7`
  (including `LogicMCP Sync`). Answering model `14` with `01` makes Logic **auto-install** a
  Mackie Control within ~0.3 s and start driving it. Logic never sends `02`.
- When the ports vanish and reappear while Logic runs, Logic re-probes and re-binds within ~0.3 s.
- Logic's Controller Assignments **Learn Mode** captures surface traffic if left on (it then
  shows "このコントロールはすでに…割り当て直しますか?" alerts, saying the control is already
  assigned to another parameter and asking whether to reassign it). Make sure it is off.

## Time display

- Beats layout 3/2/2/3, right-aligned, space-padded, **no decimal points**: `  1 1 1  1`,
  `  2 3 1217`. Only changed digits are sent (one CC 40–49 each).
- BEATS LED (`72`) on, SMPTE LED (`71`) off at connect.

## Views and the LCD

- Assignment display `PN.` (trailing dot) = **channel view**: upper line `Pan    -      - …`,
  only strip 1 shows a parameter. Bank keys do nothing visible. Pressing **Pan** (`2A`)
  switches to the multi-track view, assignment `PN` (no dot).
- Multi-track view, Pan assignment, Display Mode "Value":
  - upper line = track names, 7-char cells, 6 visible characters
    (`Inst 1 Inst 2 1      2      3      4      5      6      `)
  - lower line = pan values (`0`, `+3`, `-3`)
- **Non-ASCII characters are dropped**, only the ASCII remainder is shown: `オーディオ 1` → `1`.
  Full names must come from Accessibility (the track-name `AXTextField`s of the main window
  carry the full names, e.g. `Inst 1`, `オーディオ 1`).
- Name/Value (`34`) toggles the lower line between values (`0`) and parameter names (`Pan`).
- A transient message (`Pan/Surround parameter: Pan`) can overwrite part of the upper line
  for ~1 s after a mode change.

## Banking (11 tracks, Tracks view)

| Action from the first page | Upper line |
|---|---|
| start | `Inst 1 Inst 2 1 2 3 4 5 6` (tracks 1–8) |
| Bank Right | `3 4 5 6 7 8 9 <blank>` (tracks 5–11, strip 8 blank) |
| Bank Right again | unchanged (end) |
| Bank Left | back to tracks 1–8 |
| Channel Right ×1 | `Inst 2 1 2 3 4 5 6 7` (tracks 2–9) |
| Channel Right ×2 | `1 2 3 4 5 6 7 8` (tracks 3–10) |
| Option + Bank Right | same as Bank Right at the end |
| Option + Bank Left | first page |

The LCD shows no track numbers. Note the last page is **not** right-aligned to 8 tracks:
it started at track 5 with an empty 8th strip. Do not assume either rule — derive the
strip→track mapping from what is shown (and from Accessibility names).

## Faders

- Surface moves are accepted **with or without** touch notes.
- Logic **echoes** the position as pitch bend ~30 ms later, quantized (12000 → 11965), and the
  lower LCD cell shows the value in dB for ~2 s (`-1.2 dB `, written at offset 56 + 7×strip).
- Calibration (sent → echo → LCD):

| sent | echo | dB |
|---|---|---|
| 16383 | 14845 | +6.0 (maximum; values above are clamped) |
| 15000 | 14845 | +6.0 |
| 14000 | 13976 | +3.8 |
| 13000 | 12967 | +1.3 |
| 12443 | 12443 | +0.0 |
| 12000 | 11965 | −1.2 |
| 11000 | 10969 | −3.7 |
| 10000 | 9990 | −5.8 |
| 9000 | 8962 | −7.6 |
| 8192 | 8178 | −9.0 |
| 7000 | 6987 | −12.8 |
| 6000 | 5990 | −17.1 |
| 5000 | 4995 | −22.6 |
| 4000 | 3990 | −30.0 |
| 3000 | 2995 | −35.6 |
| 2000 | 1994 | −45.3 |
| 1000 | 994 | −55.0 |
| 500 | 495 | −59.6 |
| 100 | 99 | −106 |
| 0 | 0 | −∞ (`-oo dB`) |

## V-Pots (Pan assignment)

- One tick = pan ±1 (Logic range −64…+63). The upper cell shows `Pan` while turning, the lower
  cell the value (`+3`). Ring: `B0 30 16` at +3, `B0 30 56` at centre.
- Logic sends the LCD value updates one tick at a time (30–70 ms apart).

## Solo (observed 2026-11-21)

- Soloing a track: the lower cell shows `Soloed`, Rude Solo (`73`) flashes (velocity `01`), the
  track's solo LED turns on, and Logic **blinks the mute LEDs of all other tracks by sending
  `90 1x 7F` / `90 1x 00` about every 0.75 s** (not the `01` flashing state). While any track is
  soloed, mute LEDs say nothing reliable about the Mute buttons.

## Modifiers (observed)

- While Option is held, Logic lights select LEDs of several strips and flashes Global View;
  they return when Option is released.

## Accessibility (observed 2026-11-21)

- Track-name fields in the main window are `AXTextField`s whose **AXValue and AXTitle are empty**;
  the full name is in **AXDescription** (`Inst 1`, `オーディオ 1`). AXHelp (Japanese UI):
  `名前フィールド. ダブルクリックしてトラック名を変更します。` ("Name field. Double-click to rename
  the track."). They form one column (same x,
  65 pt apart in the test project).
- When the project window is not the main window (minimized / not shown), the app's windows read
  through AX are unrelated 0×0 windows and the names cannot be read.

## Buttons

- Mute (`10`+strip): LED `90 10 7F` on, the lower cell shows `Muted` briefly; pressing again
  turns it off. Toggle semantics confirmed.
- Play `5E`, Stop `5D`, Record `5F`, Replace `58`: LEDs follow the transport. Replace toggles.

## Play and record start positions (observed 2026-11-21)

- Play from 9.1.1.1: Logic's Song Position Pointer reports 127 sixteenths (8.4.4), one sixteenth
  before the playhead; stopping shortly after shows a position just before bar 9.
- Record from 9.1.1.1 (Replace on, no count-in configured by us): SPP 112 sixteenths = bar 8.1,
  i.e. Logic started one bar before the playhead (pre-roll / count-in).

## Recording notes from LogicMCP Notes (spike 2026-11-21)

- Setup: Inst 2 (software instrument, Drum Kit) record-armed, Replace off, stopped at 9.1.1.1.
  `transport record`, then eight notes (36/42/38/42…, 250 ms apart, velocity 100) sent on
  `LogicMCP Notes`, then stop. Logic recorded **a MIDI region on Inst 2 starting at bar 9** with
  all 8 notes, evenly spaced (eighths at 120 BPM). The track's MIDI input setting was Logic's
  default; no extra configuration was needed.
- Logic sends **Song Position Pointer even while stopped**, whenever the playhead moves
  (locate by jog: `F2 20 01`, `F2 10 01`, `F2 00 01` → 160, 144, 128 sixteenths; bar 9 = 128 in 4/4).
  So after locating, the SPP gives the absolute sixteenth position of the target bar.
- On Record from 9.1.1.1 Logic sent SPP 112 (bar 8.1): a one-bar pre-roll before the playhead;
  the recorded region still starts at the playhead (bar 9).
- On Stop Logic sends `FC` then the stop position as SPP.
- Raw log: `captures/logic13-note-recording-spike.log`.

## Jog

- One tick = one bar, snapping to the bar line (from 6.3.4.137: +1 → 7.1.1.1, −1 → 6.1.1.1).
- Bursts 20 ms apart are accelerated or merged (+3 → +2, −6 → −9). Use one tick at a time.

## Key commands through controller assignments (observed 2026-11-21)

Learned in the Key Commands window (Logic Pro > Key Commands > Edit Assignments…) with Learn New
Assignment, triggers `BF <cc> 7F` on `LogicMCP Keys`. Row names: [phase-3-results](../checklists/phase-3-results.md).

- Every one of CC 23–39 was learned on the first send and shows as `CC n (127)` in the
  Control Surface column; commands that already had a Mackie assignment show `(+1)` etc.
- **While Learn New Assignment is armed, Logic learns the trigger and does not run the command**
  (learning New Audio Track / New Software Instrument Track / New Track with Duplicate Settings
  left the track count unchanged). The button returns to normal after one message.
- **The armed Key Commands window also learns Mackie Control input**: a track scan sent while
  "Delete Track" was armed was learned as `ノート 46` ("Note 46" in the English UI; Bank Left,
  `90 2E 7F`), and the scan's Bank Left had no effect. Removed with Delete Assignment and
  relearned as CC 29.
- Not armed, a learned trigger runs the command (a learn trigger for Toggle Cycle Mode toggled
  Cycle).
- One `BF <cc> 7F` (no value 0 afterwards) runs the command once; four Toggle Cycle Mode triggers
  ≥ 150 ms apart all ran.
- Playhead: Go to Beginning moves to 1 1 1 1 (also while playing: the playhead jumps and playback
  continues). Forward from a bar line → next bar line; from mid-bar (4.3.4.59) → the next bar line
  (5.1.1.1). Rewind from a bar line → previous bar line; from mid-bar (5.3.4.74) → the start of
  the same bar (5.1.1.1). The time display starts changing ~130 ms after the trigger.
- New Audio Track / New Software Instrument Track / New Track with Duplicate Settings: no dialog,
  exactly one track **below the selected track**, and the new track becomes selected. The new
  instrument track opened no Library or plug-in window. The duplicate copied the channel strip
  (Ample Guitar) and was named `Inst 4`. The surface shows the new track count ~2.2–2.6 s after
  the trigger (first rescan).
- Delete Track deleted exactly the selected (empty) track, no dialog; the track scan before the
  trigger did not change Logic's track selection.
- Cycle (`56`) and Click (`59`) LEDs follow the key commands within 6 ms, follow clicks on the
  control-bar buttons, and stay steadily lit during playback with a soloed track (no blinking,
  unlike the mute LEDs).
- Undo (the one in the Various Windows group; Japanese UI name (observed): `取り消す`) and Redo
  removed / restored a created track. Logic lights the Mackie Undo LED once there is something to
  undo.
- Select All with the Tracks area focused selected all regions. Toggle Zoom to Fit Selection or
  All Contents is a toggle: the first trigger fitted the selected region, the second returned to
  the previous zoom. Show/Hide Mixer and Show/Hide Piano Roll toggle the panes; Select All right
  after showing the Mixer did not visibly select Mixer strips. Create Marker created `マーカー1`
  ("Marker 1") at bar 3. Toggle Count-in toggled the control-bar 1234 button.
- **After the Mixer tests, the Mackie track list also contained `St Out` and `Master` after the
  last track** (15 strips for 13 tracks); before them a scan of the same project listed only the
  13 tracks. Cause not isolated (Show/Hide Mixer is the likely one).
- Scan timing: right after New Audio Track, Logic handled the Option release of Option + Bank Left
  only after a Channel Right sent 65 ms later, which then acted as Option + Channel Right (last
  page). The scan now waits for Global View to stop flashing before the next press.

## Record arm LEDs (observed 2026-11-21)

Console experiments on the test project (`captures/` not kept; console log
`var/logs/console-20261121-083*.log`).

- A **record-armed** track's Rec LED (`90 0x`) **blinks by on/off messages**, about 0.73 s on and
  0.73 s off, all armed tracks in phase. Pressing Rec lights it within ~0.1 s; the first off came
  0.77 s later in one test and 2.0 s later in another. **While recording the LEDs are steady on**;
  after Stop they blink again.
- With **no track armed**, the **selected track** (software instrument or audio) is
  record-enabled automatically: its Rec LED is **steady on**, and Logic draws its R button
  pink/red.
- Arming any track turns the selected track's LED off at once (`90 01 00` 50 ms after the arm).
  Disarming the last armed track re-enables the selected track in Logic, but **Logic sends no LED
  message for it** until the strips are redrawn: Option + Bank Left (even on the first page) or a
  selection change re-sends it.
- Disarming a track while its LED is in the off phase produces no LED message at all.
- Changing the selection in Logic re-sends all 8 Rec LEDs of the page (all off, then the new
  selected track's on).
- Pressing Rec on the automatically enabled selected track makes it a real arm (blinking); a
  second press makes it automatic again (steady, after a redraw).

## Recording notes from LogicMCP Notes: timing (observed 2026-11-21)

- `write` at 120 BPM, notes sent on Logic's MIDI-clock timestamps (scheduling error < 0.5 ms):
  Logic's Event List shows every note **5–6 ticks (about 3 ms) before** its grid position. With a
  +3 ms send offset all 16 sixteenths of a bar and two 3–4-note chords landed exactly on the grid
  (`17 1 1 1` … `17 4 4 1`). `write_midi` now adds +3 ms by default. In a later, denser take
  (drums, 96 notes) some notes were still 5 ticks early while others landed exactly: about one
  audio buffer of jitter remains. Other tempos and audio buffer sizes are not measured yet.
- Logic's Clock messages carried CoreMIDI timestamps (205 of 205), 0.02–0.18 ms before their
  arrival at the server: Logic does not send its clock ahead of time.
- Record from bar 13: Logic sent SPP 176 (bar 12) and Continue, i.e. one bar of pre-roll.
- Logic names MIDI note 60 "C3" in the Event List.
- Once, Logic sent nothing on the MCU port for 28 s and then re-initialised the whole surface
  (channel view, all LEDs and LCD) while its main window was being minimised.

## Analysis plug-in on Stereo Out (observed 2026-11-21)

- Logic 13 sets the AU's contextName to `Stereo Out` on the main output strip and gives the plug-in
  tempo, time signature, beat position and transport state (`musicalContextBlock`,
  `transportStateBlock`). The AUv3 runs in its own extension process.
- With Stereo Out **muted** and its input silent, Logic did not run the output strip's plug-ins:
  no audio reached the Meter for those bars.
- A Mackie fader move on the `St Out` strip (Tracks view) did not move Logic's Stereo Out fader;
  the strip's Mute button worked.
- Logic's Loudness Meter: integrated and LU Range accumulate only after its Start button. Versus
  LogicMCP Meter: within 0.1 LU on a steady sine and short material; LRA larger on short material
  (partial windows after Start); on 64 s of alternating soft/loud drums Logic's integrated read
  0.35–0.48 LU higher (see phase-5-results.md, section C).
