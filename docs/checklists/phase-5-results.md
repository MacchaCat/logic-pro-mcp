# Phase 5 test results (real Logic 13.0)

Date: 2026-11-21  
Environment: Logic Pro 13.0 (Japanese UI), a new empty project (120 BPM, 4/4, **96 kHz**), 1 software instrument track `Inst 1` (Drum Kit Designer); the project's MIDI clock is sent to `LogicMCP Sync`  
Plug-in: `Plugin/` (XcodeGen), Release, ad-hoc signed, installed per the [Phase 5 setup](../setup/06-plugin.md)  
Run by: Claude through Claude Code's MCP tools; Claude operated Logic's UI with computer use

> Menu names are those of Logic's English UI. The tests were run on Logic 13.0 with the Japanese
> UI, so these names come from Apple's English documentation and have not been checked on an
> English-UI Logic yet.

## Merge and security review

- `phase-5-hardening-fix` merged into main (conflicts: `Package.swift`, tool registration, FakeLogic's playback start; the tools of all three phases coexist). All tests pass.
- **Fix (high)**: `Frames.swift` computed `abs(block.frames - blockFrames)` on the `frames` value sent by the plug-in; with values near `Int.min` / `Int.max` Swift traps on overflow, so any program on this Mac could make the server exit by sending one frame. Replaced with a range check that does no arithmetic on untrusted values; the codec tests gained extreme values.
- **Fix (medium)**: when `analyze_audio`'s `instance` exactly equals an instance's id, that instance is now always selected (if it is disconnected, the call reports "not connected"). Previously, after that instance disconnected, another connected instance that had named its channel after this id was silently selected.
- Confirmed: when several instances claim to be the main output, the call reports that the choice is ambiguous and asks for `instance`; the claim of an instance that connected later is not trusted.
- The remaining items (plug-in text only in labelled fields, the various limits, the connection lifecycle, the BS.1770 / Tech 3341 / 3342 values) were re-checked by an independent review; the results are in the "Independent review" section at the end of this file.

## Plug-in

- `auval -v aufx lmtr Lmcp`: **AU VALIDATION SUCCEEDED** (render tests at 22.05–192 kHz, mono, connection semantics, wrong maximum frame count).
- A small offline host (AVAudioEngine manual rendering, no sound output) fed a -20 dBFS 1 kHz stereo sine: the server measured momentary and short-term loudness of **-19.99 LUFS**.
- While auval runs, the plug-in has no time to connect (each test gets only a few milliseconds), so auval itself cannot be used to test the link.
- Logic scans for new AUs only at startup: the plug-in was not in the Plug-in Manager of the running Logic; after Logic was restarted it appeared under Audio FX > Audio Units > **LogicMCP** > **Meter** > Stereo.

## Results

| Item | Result | Notes |
|---|---|---|
| A1 | Not checked | Did not specifically watch for a firewall prompt when the server started |
| A2 | Pass | `notes` of `logic_status`: `Analysis link: listening on 127.0.0.1:47810; no plug-in instance connected` |
| A3 | Pass | `lsof`: only `logic-mcp 127.0.0.1:47810 (LISTEN)` |
| A4 | Pass | The instance appeared immediately after the plug-in was inserted on Stereo Out, `connected: true`, the id is a UUID, `plugin_reported_context_name` is **`Stereo Out`** (the contextName Logic gives the AU), `claims_main_output` true, `sample_rate` 96000 |
| A5 | Recorded | The plug-in runs in **the extension's own process** `LogicMCPMeterExtension` (research.md §5.1 case A, App Sandbox + `network.client`); the TCP connection comes from this process |
| A8 | **Expectation changed** | The plug-in **does not store its id in the project**: when a plug-in is copied, Logic copies its state, and with two instances on the same id the server refuses the second. The id is generated once when the plug-in instance is created and does not change when Logic changes the sample rate or buffer size (reallocating resources) (the first version generated a new id on every allocation; fixed; offline-host test: the same id before and after reallocation). After the project is reopened the id is new; select the instance by channel name (`Stereo Out`) instead |
| B1 | Pass | Stopped at 7.1.1.231: `bar` 7.06, `tempo_bpm` 120, `time_signature` `4/4`, `playing` false |
| D2 | Pass | `analyze_audio` on the verse (bars 3–4) and chorus (bars 5–6), `capture` true, `max_age_seconds` 0: jumped to bar 2, played, stopped after the time display passed bar 7 (10.1 seconds), `verified`, both ranges `complete`, coverage 0.996 |
| D4 | Pass | The same two ranges requested again right away: `captured` false, no playback, same result |
| — | **Goal** | Verse (hi-hat 35, kick 50, snare 45 velocity) **-28.2 LUFS**, chorus (100 / 120 / 118) **-20.6 LUFS**: the chorus is **7.6 LU** louder; true peak -11.6 dBTP in the verse, -2.7 dBTP in the chorus (re-measured with the metronome off) |
| — | **Finding: metronome** | In the first measurement the metronome was on (Click LED lit): integrated loudness was almost the same (-28.1 / -20.4), but both ranges had a true peak of -0.7 dBTP and a 1 kHz band of -38.7 dB. That was the metronome click, which goes through Stereo Out together with the music. `analyze_audio` now warns when the Click LED is lit during a capture, and the transport state also reports `click` |
| — | Phase 4 also verified | In the new project the selected `Inst 1` (auto record-enabled, LED steady on) is the write target: pressing Rec makes it a manual record-arm (blinking); after the recording Rec was pressed again to restore it, and the LED returned to steady on |

## C. Comparison with Logic's built-in Loudness Meter (2026-11-21)

On Stereo Out, Logic's **Loudness Meter** (Metering > Loudness Meter) was inserted after our Meter, so both measured the same signal. Before each measurement, Reset and Start were clicked on the Loudness Meter; after `analyze_audio` (`capture` true, `max_age_seconds` 0) had finished playing, Pause was clicked and the values were read. Logic's meter shows only two numbers, Integrated and LU Range; it does not show true peak or maximum values. During the tests Stereo Out was muted (Mute), so the speakers were silent; the plug-in is pre-fader and measured as usual.

| Material | Our I (LUFS) | Logic I | Our LRA (LU) | Logic LRA | Notes |
|---|---|---|---|---|---|
| C1: Test Oscillator 1 kHz sine at -12 dBFS (stereo), bars 2–5 | **-12.01** | -12.1 | **0.0** | 4.4 | Theoretical value -12.0 LUFS, LRA 0. Our max momentary / short-term -12.01, true peak -12.0 dBTP, spectrum 1 kHz band -12 dB (all others ≤ -80 dB); Logic's M / S are also -12.0 |
| C2: drums, 8 seconds (bars 3–6: 4 seconds soft, 4 seconds loud) | **-21.79** | -21.8 | 7.73 | 12.5 | Integrated loudness matches |
| C3: drums, 64 seconds (bars 9–40, soft / loud alternating every 4 bars), first pass | -21.98 | -21.5 | **7.79** | 7.7 | Once the material is long enough, LRA matches |
| C3: same, second pass | -21.84 | -21.5 | **7.72** | 7.7 | — |

Conclusions:

- **Steady signals and short material: integrated loudness within 0.1 LU**; the sine's value matches the theoretical value.
- **LRA**: on short material Logic reads higher (sine 4.4, 8-second drums 12.5). After Start, Logic's meter also counts 3-second windows that are not yet full, and these low short-term values at the beginning pull down the 10th percentile; we use only complete windows (as libebur128 does). The sine's theoretical LRA is 0, and ours is 0. On the 64-second material both agree (7.7–7.8).
- **Known difference (not fully confirmed)**: on the 64-second soft / loud material, Logic's integrated loudness was 0.35–0.48 LU higher than ours both times (more than checklist C2's 0.2). The most likely cause is the relative gate (-10 LU): Logic excludes more of the soft parts' 400 ms blocks. Our gating passes the EBU Tech 3341 gating test vectors (unit tests), and the independent review also confirmed it conforms to BS.1770. The drums (Drum Kit Designer) sound slightly different on each pass: the individual sections we measured differ by up to about 0.5 LU from pass to pass, the whole range by about 0.14 LU; Logic shows its value only to 0.1.
- **Finding**: when Stereo Out is muted and its input is silent, Logic does not run the plug-ins on the output channel, so there is no data for that time (which is why coverage was only 82%; the tool reported this accurately). Moving the Stereo Out fader through Mackie had no effect (Logic showed +0.0 dB and the fader did not move after that), and the tool returned `failed`; the mute button works.

## Items not run

- A6, A7, B2–B12, C1–C5, C7, C8, D1, D3, D5–D7.
- C4, C5, C7, C8; C3 used the drum test material and has not yet been compared on a real mix.

## Independent review (Phase 5 code, 2026-11-21)

A read-only review agent checked the merged code item by item and ran the related tests (all passed):

| Item | Result | Action |
|---|---|---|
| Plug-in text appears only in labelled fields (`plugin_reported_*`, `instance`) and is never put into summary / evidence / warning | Pass | The comment on the id format in `PluginText.swift` was out of date (it said 1–40 characters of A-Z a-z 0-9 - _ .); changed to 8–40 hexadecimal digits and `-` |
| Limits: 8 warnings, 16 instances, 72 000 blocks of history, 64 KiB per frame, a rate limit per connection, 16 connections | Pass | — |
| Tempo was only required to be > 0: at a tempo of 1e-20 the sub-block width is 0 and the count in `PositionHistory.removeOverlap` goes wrong (the review agent reproduced this on a copy) | **Defect (low)** | `validTempo` changed to ≥ 5 BPM (Logic's minimum), `removeOverlap` gained a `first <= last` guard, and the tests gained extreme values |
| The heartbeat keeps the Cycle flag of the last audio frame: after Cycle is turned off, a capture could still be refused because of the plug-in's stale flag | **Possible issue** | When Logic reports the Cycle LED, the LED is authoritative (before the capture and during playback); the plug-in's flag is used only when the LED state is unknown; new tests added |
| `connectionOwners` has no hard limit (it is cleaned up only when the instance table is full or a tool is called) | To watch | It only accumulates if disconnect events are lost, and the next tool call cleans it up; no change for now |
| Connection lifecycle (`isOpen` check, owners cleared on disconnect, heartbeats do not wipe the host state) | Pass | — |
| Loudness values: K-weighting (48 kHz coefficients match digit for digit), integration gating, LRA (Tech 3342), true peak with a 48-tap 4-phase FIR, 400 ms / 3 s windows | Pass | — |
