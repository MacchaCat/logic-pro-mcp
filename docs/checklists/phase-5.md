# Phase 5 test checklist (real Logic 13)

Purpose: once the analysis plug-in (LogicMCP Meter; its Xcode project comes in a later phase) is built, confirm three things in real Logic:

1. The plug-in can connect to the server, and macOS shows no firewall prompt while the server listens on the local loopback port (research.md §9 #8);
2. Logic 13 really gives the plug-in the tempo, time signature, play position and transport state, and which process the plug-in runs in (research.md §9 #7);
3. The values `analyze_audio` measures match Logic's built-in loudness meter, and `capture` locates, plays and stops correctly.

All of this phase's code has been tested against FakeLogic and synthetic signals, but none of the Logic behaviours in the tables below has **been observed on real Logic yet**. If one does not match, fill in what you actually saw and tell Claude; the code will be changed to follow the observed result.

About text sent by the plug-in: the channel name, role, version and instance id are all sent by the plug-in, and any program on this Mac can connect to the server's port (see section G), so the server treats them as untrusted labels. The channel name keeps only letters, digits and a little punctuation (at most 40 characters) and appears only in fields with the `plugin_reported_` prefix, such as `plugin_reported_context_name`. The instance id must be UUID-shaped (8–40 hexadecimal digits and `-`, which cannot spell words) and appears only in the `instance` field. Neither ever appears in a result's `summary`, `evidence`, `warnings` or `notes`, nor in the `logic_status` line. When checking names in the tables below, look at these fields.

> Menu names are those of Logic's English UI. The tests were run on Logic 13.0 with the Japanese
> UI, so these names come from Apple's English documentation and have not been checked on an
> English-UI Logic yet.

Prerequisites:

- Mackie Control is set up per the Phase 1 setup (time display set to Beats, "Jog resolution depends on horizontal zoom" off).
- The plug-in is installed (installation instructions come in a later phase) and, to start with, inserted in a plug-in slot on **Stereo Out (the main output)**.
- Test project: 4/4, 120 BPM, starting at bar 1; one audio or instrument track, quiet in bars 1–8 (for example a 1 kHz sine at -26 dBFS; Logic's Test Oscillator can produce it) and louder in bars 9–16 (for example -20 dBFS). Cycle off, stopped.
- Fill in what you actually see after each item. If anything unusual happens, keep the server's stderr log.

---

## A. Connection, ports and firewall

| # | Action | Expected | Actual |
|---|---|---|---|
| A1 | Start a Claude Code session (the server starts with it), **without the plug-in inserted** | macOS **does not show** the prompt asking whether to allow logic-mcp to accept incoming network connections. If it does, write down the prompt's exact text, click "Deny", then continue and see whether the plug-in can still connect | |
| A2 | Ask Claude to call `logic_status` | `notes` has the line `Analysis link: listening on 127.0.0.1:47810; no plug-in instance connected` (after the plug-in is inserted it becomes `1 plug-in instance connected`; this line contains no channel name or id) | |
| A3 | In Terminal, run `lsof -nP -iTCP:47810-47813 -sTCP:LISTEN` | Only `127.0.0.1:47810` (not `*:47810`), meaning it listens on local loopback only | |
| A4 | Insert the plug-in on Stereo Out, wait 2 seconds, call `list_analysis_instances` | 1 instance appears, `connected: true`, `instance` is a UUID (e.g. `3F2A…-…`); write down what `plugin_reported_context_name` shows (expected `Stereo Out`; it may be another name or empty) | |
| A5 | In Activity Monitor, check which process the plug-in runs in (search for `AUHostingService` or the name of the plug-in's extension) | Just record it: inside the Logic process / `AUHostingServiceXPC` / the extension's own process (the three cases of research.md §5.1) | |
| A6 | End the Claude Code session and start a new one (the server restarts), wait 3 seconds, `list_analysis_instances` | The plug-in reconnects automatically, with the same instance id as before | |
| A7 | First occupy 47810 (run `nc -l 127.0.0.1 47810` in Terminal and leave it running), then restart the session, `logic_status` | The server starts normally and listens on 47811 instead; the plug-in also connects to 47811. Stop `nc` afterwards | |
| A8 | Save the project, close it, reopen it, `list_analysis_instances` | A **new** id appears (the plug-in does not store its id in the project: copying a plug-in copies its state, and the server refuses a second instance with the same id); the channel name is still `Stereo Out`, and `analyze_audio` selects it both without `instance` and by channel name | |

## B. Information Logic gives the plug-in (research.md §5.5, §9 #7)

| # | Action | Expected | Actual |
|---|---|---|---|
| B1 | Stopped, playhead at 1 1 1 1, `list_analysis_instances` | `tempo_bpm` 120, `time_signature` `4/4`, `bar` 1.0, `playing` false | |
| B2 | Click the playhead to 5 1 1 1 (stopped), check again | `bar` 5.0 (meaning Logic's beat position 0 = start of bar 1, in quarter notes) | |
| B3 | Play for about 3 seconds, then check (call while playing) | `playing` true, `bar` increases with playback and matches the bar number in Logic's LCD (±0.1 bar) | |
| B4 | Change the project tempo to 90 BPM, check while playing | `tempo_bpm` 90 | |
| B5 | Change the time signature to 3/4 (from bar 1), put the playhead at 3 1 1 1 | `time_signature` `3/4`, `bar` 3.0 | |
| B6 | Insert a time signature change at bar 5 (bars 1–4 in 4/4, 3/4 from bar 5), put the playhead at 7 1 1 1 | Record what `bar` shows, whether `warnings` contains the "the meter changes earlier in the project" warning, and what `first_unfitting_downbeat_beats` is (known limitation: bar numbers assume the time signature stays unchanged from bar 1) | |
| B6b | Following B6: delete the time signature change at bar 5 (4/4 throughout), play from bar 5 to bar 8 and stop, then `list_analysis_instances` | The time signature warning disappears and `first_unfitting_downbeat_beats` becomes `null` (it is cleared only when the bar that did not fit lines up again; playing only bars 1–4 keeps the warning, by design) | |
| B7 | Insert a tempo change at bar 5 (120 → 90), play from bar 3 to bar 7, then `analyze_audio` bars 3–7 | Coverage close to 1, `notes` mentions that the tempo changes within the range; bar positions are not scrambled | |
| B8 | Turn on Cycle (bars 3–5), play two loops, stop, `list_analysis_instances` | `covered_bars` has only one span, 3–5 (the cycle jump back is recognized as a new pass, and new data replaces the old), with no data after bar 5 | |
| B9 | In Project Settings, set the sample rate to 44.1 / 48 / 88.2 / 96 kHz in turn; at each, play bars 9–16 once, then `analyze_audio` | The instance's `sample_rate` follows; integrated loudness differs by ≤ 0.1 LU across the runs and true peak by ≤ 0.3 dB (true-peak oversampling: 4× below 96 kHz, 2× from 96 kHz, none from 192 kHz) | |
| B10 | While playing (Beats display), call `get_session_state` or the `transport` status query several times in a row | The bar number in `position` keeps increasing during playback (capture decides it is finished when "the time display passes to_bar"; if the display does not update during playback, capture fails with a timeout) | |
| B11 | While stopped, press Logic's Cycle button to turn Cycle on, then off; check the transport state after each | Record whether `cycle` changes from `null` to `true` / `false` (whether Logic sends the Cycle LED to the control surface) | |
| B12 | Likewise turn Cycle on, then off; call `list_analysis_instances` after each | Record whether the instance's `cycling` follows to `true` / `false` (whether the plug-in receives the Cycle flag from the AU host's transport state); this is capture's fallback check when the Cycle LED is not reported | |

> Note: if neither B11 nor B12 shows the Cycle state, capture still plays, but warns "Cycle could not be checked" in the result; it stops at once when the time display moves back by a bar or more and stays there for 0.25 seconds (see D14). A cycle region within a single bar cannot be detected: playback then continues until the time limit (estimated time × 1.5 + 5 seconds, at most about 300 seconds for the whole call) before it stops.

## C. Accuracy (compared with Logic's built-in Loudness Meter)

On Stereo Out, insert Logic's built-in Loudness Meter **after** LogicMCP Meter.

| # | Action | Expected | Actual |
|---|---|---|---|
| C1 | Only a Test Oscillator: 1 kHz sine, -18 dBFS, stereo; play bars 1–8, then `analyze_audio` bars 2–7 | `integrated_lufs` -18.0 ± 0.1; Logic's loudness meter I likewise about -18 | |
| C2 | Back in the test project, play from bar 1 to bar 17 and write down the Logic loudness meter's I, LRA, max S, max M and true peak; then `analyze_audio` bars 1–16 | Difference from Logic's loudness meter: I ≤ 0.2 LU, LRA ≤ 1 LU, max short-term ≤ 0.3 LU, max momentary ≤ 0.3 LU, true peak ≤ 0.3 dB (the 400 ms max-momentary window steps by 10 ms; EBU Tech 3341 tests 13/14 pass in the unit tests) | |
| C3 | A real mix project: play the whole song, `analyze_audio` the whole song (at most 64 bars per range, so split it into several ranges) and compare with Logic's loudness meter | As C2 (when split, compare each range; do not compare the whole-song I) | |
| C4 | Look at `spectrum` for bars 9–16 of C2 | The band around 1 kHz is the highest, matching the test signal | |
| C5 | Raise the level by 6 dB **before** the plug-in (e.g. a Gain plug-in in the slot above it, +6 dB) and measure the same range; then remove the Gain, raise only this channel strip's fader by 6 dB and measure again | With Gain, integrated loudness is exactly 6.0 dB higher (showing that the signal at the plug-in's position is measured). With only the fader, record whether it changes (expected: no change, since plug-in slots are normally pre-fader; not confirmed on Logic 13) | |
| C6 | (Without Logic; done) Compare the 48-tap 4× oversampling coefficient table of ITU-R BS.1770-5 Annex 2 with `lk_tp4_coefficients` one by one | Checked against the original text on 2026-11-21: all 48 coefficients match; the K-weighting coefficients (Annex 1 Tables 1 and 2) and the EBU Tech 3341 / 3342 test parameters were also checked against the original texts and corrected (the unit tests keep the original coefficient tables) | Match |
| C8 | (Once the plug-in supports surround) Insert the plug-in on the main output of a 5.1 and a 7.1 project; with Test Oscillator, send 1 kHz -20 dBFS on one channel at a time and measure each | Record each channel's integrated loudness. Expected: L, R, C about -23.0; 5.1 Ls/Rs and 7.1 side surrounds about -21.5 (weight 1.41); 7.1 rear surrounds about -23.0; LFE not counted (null). A mismatch means Logic's channel order differs from what the code assumes (5.1: L R C LFE Ls Rs; 7.1: L R C LFE side-left side-right rear-left rear-right) | |
| C7 | Place a very loud transient (e.g. a snare) about 30 ms before beat 1 of bar 9, with lower level after it; play bars 8–10, then `analyze_audio` bar 8 and bars 9–10 separately | Record which range the transient's true peak is counted in. Known rule: the plug-in measures in 100 ms blocks, each assigned by its midpoint, so range boundaries have a ±50 ms error, and a peak up to 50 ms before the bar line may be counted in the following range | |

## D. The `analyze_audio` capture flow

| # | Action | Expected | Actual |
|---|---|---|---|
| D1 | Server just started, nothing played yet: `analyze_audio` bars 5–6 and 9–10, `capture` false | `failed`, `coverage` 0 for each range, and the explanation suggests `capture=true` | |
| D2 | Same two ranges, `capture` true | Logic first jumps to bar 4, plays, stops after passing bar 6, then jumps to bar 8, plays, stops after passing bar 10; the result is `verified`, both ranges `complete` true; `evidence` includes the locate, play, `time display reached` and `stopped at` | |
| D3 | Observe D2: does playback start **immediately** at the located bar (no count-in, pre-roll or automatic return to another position)? | Just record it (with a count-in it is still expected to complete, only more slowly) | |
| D4 | Right after D2 finishes, make the same request again | No playback (`captured` false); the result is returned directly | |
| D5 | Call with `capture` true while playing | `failed`/`partial`, explanation "Logic is playing… Stop first"; Logic is not interrupted | |
| D6 | Turn on Cycle, call with `capture` true (the bars to capture have no data yet) | No playback; the explanation says Cycle is on | |
| D7 | `capture` true for bars 2–40; press Stop by hand during playback | The result says "Logic stopped before the end of the range"; the part measured so far is reported as usual | |
| D8 | `capture` true for bars 2–40; remove the plug-in from its slot during playback | The result says the plug-in disconnected; Logic **is stopped** | |
| D9 | Ask to capture more than 64 bars | `failed` at once; nothing is played | |
| D10 | Switch the time display to SMPTE, then call with `capture` true | An explanation that locating failed; nothing is played. Switch back to Beats | |
| D11 | During playback put Logic in the background (click into Terminal); capture completes normally | `verified` | |
| D12 | `capture` true for bars 2–8 and bars 5–6 in one call (two overlapping ranges) | Logic plays only **once** (from bar 1 until after bar 8, then stops); both ranges have `passes` 1 and `captured` true | |
| D13 | Change the project tempo to 40 BPM, `capture` true for bars 2–64 (64 bars including the pre-roll, about 384 seconds) | `failed` at once; the explanation says the estimated play time exceeds 300 seconds; nothing is played. Change back to 120 BPM | |
| D14 | Turn on Cycle (bars 3–4), `capture` true for bars 5–8 (skip this item if D6 was already refused because of the Cycle LED or the plug-in's `cycling`) | Playback starts at bar 4; when bar 4 ends and playback jumps back to bar 3, Logic is stopped within about 0.5 seconds; the result says "jumped back from bar 4 to bar 3" | |
| D15 | A capture that needs long playback: project tempo 60 BPM, capture bars 2–60 (about 4 minutes) | Claude Code does not time out or report an error because the tool call takes long, and the result comes back normally (other tool calls queue while the capture runs). The whole call (locate, play, wait for data) takes at most about 300 seconds; a range that does not fit is not played, and `summary` mentions the "time limit for one call" | |
| D16 | Park the playhead at bar 1 first, turn on Count-in in the settings, then repeat D2 | Record whether playback starts at the located position and whether the result is `verified` (it is normal if the count-in only affects recording) | |
| D17 | After D4, change the test signal's level by 3 dB (the Test Oscillator's level or the region gain, not the fader: the plug-in may be pre-fader, see C5), then call `capture` true with the same ranges and `max_age_seconds` 0 | Logic plays both ranges again (`captured` true), the new `integrated_lufs` reflects the change, and `oldest_data_age_seconds` is only a few seconds. Without `max_age_seconds` there is no replay; when the old data is more than 5 minutes old, `summary` mentions its age in minutes | |
| D18 | (Optional; checks how a failed Stop is handled) `capture` true for bars 2–40; during playback open a modal dialog that makes Logic stop responding to the control surface (e.g. "File > Project Settings…"), and wait for the capture to end | The result is **not** `verified`, and `summary` contains "Logic did not confirm Stop and may still be playing; stop it by hand."; close the dialog and stop by hand. Record whether Logic still responds to Stop while a modal dialog is open | |

## E. Multiple instances

| # | Action | Expected | Actual |
|---|---|---|---|
| E1 | Insert another plug-in on the audio track, `list_analysis_instances` | Two instances; write down each one's `plugin_reported_context_name` (expected: the track name) and `claims_main_output` | |
| E2 | Call `analyze_audio` without `instance` | The main-output one is selected (marked as the main output in the plug-in, or named like `Stereo Out`; it connected **before** the plug-in on the track), and afterwards its `is_default` is true; the result carries the "Several analysis plug-in instances are connected" warning. If neither looks like the main output, both do, or the only one that does connected **after** the other, the call is `failed` and `after.candidates` lists both instances (with `claims_main_output`; the server does not choose for you in these cases) | |
| E2b | First delete both plug-ins, then insert one on the track first and then one on Stereo Out (the reverse of E1's order); call `analyze_audio` without `instance` | `failed`, explanation "connected after another one, so its claim is not trusted", `after.candidates` lists both; `instance: "Stereo Out"` measures. Record: after a server restart (A6), whether the two plug-ins always reconnect in the same order (if not, a call without `instance` after a restart may need `instance` once) | |
| E3 | Call with the track name (`instance: "<track name>"`) | The instance on the track is selected | |
| E4 | E1 and E3 with a Japanese track name (e.g. `オーディオ 1`, the Japanese UI's default name for an audio track; "Audio 1" in the English UI) | The name is shown in full, and the instance can be selected by the Japanese name | |
| E8 | First insert the plug-in on one track only and call `analyze_audio` once (it becomes the default), then insert the plug-in on Stereo Out and call again without `instance` | The one on the track is still measured (the default does not change while it stays connected; a "main output" that connects later cannot replace it), and the result carries the "Several…" warning; only specifying `instance` measures Stereo Out. After the plug-in on the track is deleted, the next call makes the one on Stereo Out the default | |
| E5 | Option-drag the plug-in on Stereo Out to a track to **copy** it (or copy the whole channel strip / create a track from a template that contains the plug-in), wait 2 seconds, `list_analysis_instances` | Record whether the copy has the same instance id as the original. If it does: only one instance; `warnings` has a warning containing "same instance id" (the exact text starts with "Another live LogicMCP Meter plug-in reports the same instance id"), and `duplicate_frames_refused` keeps increasing; the `analyze_audio` result is `partial`, with the same warning first in `warnings` | |
| E6 | Following E5: delete the original plug-in on Stereo Out, wait 2 seconds, `list_analysis_instances` | The instance is now provided by the copy on the track, the warning disappears, and the previous data is cleared (`covered_bars` empty; playback has to be repeated) | |
| E9 | Delete the plug-in on Stereo Out, insert a new one from the plug-in menu (new instance id), wait 2 seconds, call `analyze_audio` with `instance: "Stereo Out"` | The newly inserted one is selected (the old, disconnected instance has the same name but no longer causes "matches several instances"); in `list_analysis_instances` the old instance is `connected: false` | |
| E7 | E1 with a very long track name (over 40 characters) or one containing emoji, quotation marks or brackets | The instance connects normally; `plugin_reported_context_name` keeps only letters, digits, spaces and `- _ . , ( ) + & # / :`, at most 40 characters, so emoji and quotation marks are removed; `frames_rejected` does not increase | |

## F. Long runs and resources

| # | Action | Expected | Actual |
|---|---|---|---|
| F1 | Play a song of 4 minutes or more from start to end twice | `history_seconds` in `list_analysis_instances` does not exceed about 7200 (the limit is two hours); the server's memory does not keep growing | |
| F2 | The plug-in's CPU use (Logic's CPU meter / Activity Monitor) | Same order of magnitude as Logic's built-in Loudness Meter | |
| F3 | Quit Logic during playback | The server does not crash; `list_analysis_instances` shows the instance as `connected: false` and the earlier data can still be queried, but `analyze_audio` reports it as not connected | |
| F4 | While stopped, bypass the plug-in for 10 seconds, check `last_frame_seconds_ago` in `list_analysis_instances`, then turn bypass off | Record whether the plug-in still sends data while bypassed (whether Logic still calls the plug-in's render); after bypass is turned off it is still the same instance, `connected: true`, with no "same instance id" warning | |
| F5 | Following F4: bypass for 70 seconds or more, checking `list_analysis_instances` every 20 seconds | Expected: while bypassed, the plug-in sends a heartbeat once a second even if it is not rendering, so the instance stays `connected: true`, `last_frame_seconds_ago` is under 2 and `link.timed_out_connections` does not increase. If the instance becomes `connected: false` (while bypassed, even the plug-in's background sending stopped), the server closes the connection after 60 seconds, and after bypass is turned off the plug-in should reconnect automatically with the same instance id and measured data. Record which of the two happens | |
| F6 | Insert the plug-in on an audio track **with no regions and input monitoring off**; with Logic stopped, wait 70 seconds or more, checking `list_analysis_instances` every 20 seconds | Record whether `last_frame_seconds_ago` stays under 2 (whether Logic still calls render for the plug-in on this track while stopped). If it does not, the plug-in should send a heartbeat once a second: the instance stays `connected: true`, `link.timed_out_connections` does not increase, and `tempo_bpm` etc. keep their last values; if the instance becomes `connected: false`, the plug-in is not sending heartbeats (a problem for the plug-in phase) | |
| F7 | Following F6: select the instance on this track with `instance`, `capture` true for bars 2–3 | Record whether Logic starts rendering this track during playback (result `verified`, or a "sent no data" warning); it is normal for a plug-in on an empty track to measure nothing | |

## G. Other programs on this Mac (security)

The server listens only on 127.0.0.1, so other computers cannot connect; but **any program on this Mac can connect and send data, with no authentication**. There is no shared secret for now because the plug-in is a sandboxed AUv3 extension and cannot read a key file the server writes into this repository's `var/` (a pairing method that works inside the sandbox is left to the plug-in phase). So the server relies on limits instead: plug-in text is used only as a label, and an instance id can only be UUID-shaped (see the paragraph about text sent by the plug-in at the top); once the default instance is chosen, a "main output" that connects later does not replace it (E8), and before the first choice, an instance that connects later and claims to be the main output does not replace an instance that connected **earlier** either (the call fails and lists the candidates, E2b); only one connection is accepted per instance id (E5); each connection has a send-rate limit (counted by number of sub-blocks and data size); a connection that sends no valid data within 10 seconds of connecting, or no valid data for 60 seconds, is closed. What it still cannot prevent: a program that connects **before the real plug-in** (or while the real plug-in is disconnected) and claims to be the main output can become the default instance.

| # | Action | Expected | Actual |
|---|---|---|---|
| G1 | With the server running, run `nc 127.0.0.1 47810` in Terminal, type nothing, wait 15 seconds | `nc` first shows a few garbage characters (the server's hello frame; normal); after about 10 seconds the server closes the connection (`nc` exits, or reports an error on the next input); `link.timed_out_connections` in `list_analysis_instances` goes up by 1; the plug-in in Logic is not affected | |
| G2 | Connect the same way, then type a line of arbitrary text and press Return | The connection is closed at once (it is not data of this protocol); the plug-in is not affected | |
