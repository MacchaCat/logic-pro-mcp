# Logic Pro MCP — Phase 0 design

Status: **confirmed (2026-11-20)**; the decisions are in §7. Sources: [research.md](research.md) (cited below as "research §x").

---

## 1. Overall structure

```
┌─────────────┐  stdio (JSON-RPC)  ┌────────────────────────────────────────────────┐
│ Claude Code │ ◀────────────────▶ │ logic-mcp (Swift executable)                   │
└─────────────┘                    │  ├ MCP layer: tool definitions, confirmation,  │
                                   │  │  result envelope                            │
                                   │  ├ LogicBridge: state model, controllers,      │
                                   │  │  rate limiting                              │
                                   │  ├ MIDIPorts: CoreMIDI virtual ports           │
                                   │  └ AnalysisLink: 127.0.0.1 TCP listener        │
                                   └─────┬──────────────────────────────────▲───────┘
                 CoreMIDI virtual ports  │                                  │ TCP (plug-in
       ┌────────────────┬────────────────┼────────────────┐                 │ is the client)
       ▼                ▼                ▼                │                 │
 LogicMCP MCU     LogicMCP Keys   LogicMCP Notes    LogicMCP Sync           │
(bidirectional)     (one-way,        (one-way,    (Logic → server:          │
       │           controller          note          Clock/SPP)             │
       │          assignments)      recording)            │                 │
       └────────────────┴───────┬────────┴────────────────┘                 │
                                ▼                                           │
                     ┌─────────────────────┐              ┌─────────────────┴───┐
                     │    Logic Pro 13     │─────────────▶│ LogicMCP Meter      │
                     │                     │              │ (AUv3, Phase 5)     │
                     └─────────────────────┘              └─────────────────────┘
```

### 1.1 Why four ports

| Port | Direction | Purpose | Basis |
|---|---|---|---|
| `LogicMCP MCU` | Bidirectional | Mackie Control: transport, mixer, LCD, time code feedback | research §1, §2 |
| `LogicMCP Keys` | Server → Logic | Controller assignments that trigger key commands (two or three for locating in Phase 1, more in Phase 3) | Messages that match an assignment are consumed by Logic and are not recorded; also, controller assignments give no feedback on an ordinary port (research §3.3, §3.7) |
| `LogicMCP Notes` | Server → Logic | Note data for recording (Phase 4) | Must not be mixed with control messages (research §3.7) |
| `LogicMCP Sync` | Logic → Server | MIDI Clock + Song Position Pointer sent by Logic: confirms play state, position and tempo, and lets the note sending line up with the start of the recording | research §3.6, §4.2 |

### 1.2 Key principles

1. **Report only what is seen.** A write operation is reported as "verified" only after Logic's feedback (LEDs, fader echo, LCD, time code, Clock/SPP, plug-in data) confirms it. When no feedback is seen, the result honestly says "sent, could not be confirmed" and never calls it a success.
2. **Assume nothing about the Mackie state.** Before acting on a track, read the current bank position and the track name on the LCD and check them. Mute / solo / record arm are toggle keys: read the state first and press only if it differs (research §7.3).
3. **Never press Select.** Selecting a channel makes Logic bank automatically, and makes later edits apply to all selected tracks (research §7.3).
4. **Only the MIDI module touches CoreMIDI.** All other modules are pure logic and can be tested against a "fake Logic".

---

## 2. Directory layout

```
logic-pro-mcp/
├── Package.swift                 # SwiftPM: server, libraries, tests
├── README.md
├── docs/
│   ├── research.md               # Phase 0 verification report
│   ├── design.md                 # this file
│   ├── setup/                    # step-by-step instructions for you
│   │   ├── 01-install-server.md          # build, register with Claude Code
│   │   ├── 02-logic-mackie-control.md    # add the Mackie Control surface in Logic
│   │   ├── 03-logic-sync-output.md       # make Logic send Clock/SPP to LogicMCP Sync
│   │   ├── 04-controller-assignments.md  # Phase 3: learn the command mappings
│   │   ├── 05-recording-setup.md         # Phase 4: recording settings
│   │   └── 06-plugin.md                  # Phase 5: install the plug-in
│   └── checklists/               # per-phase manual verification checklists for real Logic
│       └── phase-1.md … phase-5.md
├── Sources/
│   ├── LogicMCP/                 # executable: MCP server, tool definitions, argument validation, confirmation flow
│   ├── LogicBridge/              # core: session state; transport / mixer / command / note-writing / analysis controllers; rate limiting; result envelope
│   ├── MackieControl/            # pure protocol: message encoding/decoding, handshake, surface state model (LCD buffer, LEDs, faders, time code)
│   ├── MIDICore/                 # pure protocol: MIDI 1.0 byte-stream parsing, UMP ↔ byte conversion (including 6-byte SysEx packets)
│   ├── MIDIPorts/                # the only module that imports CoreMIDI: virtual ports, stable UniqueIDs, send/receive queues
│   ├── LogicAX/                  # Phase 2: read-only Accessibility, reads full track names (com.apple.logic10 only)
│   ├── CommandMap/               # command table: command name → MIDI message, destructive or not, how to verify
│   ├── AnalysisLink/             # TCP listener, frame format (types shared by the plug-in and the server)
│   ├── LoudnessKernel/           # C++: K-weighting, 100 ms sub-block accumulation, true-peak interpolation (real-time safe, shared by the plug-in and the tests)
│   ├── AudioAnalysis/            # Swift: gated integrated loudness, LRA, spectrum (used on a background thread)
│   └── FakeLogic/                # fake Logic: simulates the Mackie host side (for tests; `logic-mcp serve --fake` uses it too, without creating real ports)
├── Tests/
│   ├── MIDICoreTests/
│   ├── MackieControlTests/
│   ├── LogicBridgeTests/         # all run against FakeLogic
│   ├── CommandMapTests/
│   ├── AudioAnalysisTests/       # with EBU test signals (synthesised)
│   └── AnalysisLinkTests/
├── Resources/
│   └── commands.json             # Phase 3 command mapping table
├── Plugin/                       # Phase 5: container app + AUv3 extension (Xcode project)
│   ├── App/
│   ├── Extension/
│   └── LogicMCPMeter.xcodeproj
├── scripts/
│   ├── build.sh
│   └── register-claude.sh        # prints / runs the `claude mcp add` command
└── var/                          # runtime files (not in git): single-instance lock
```

Dependencies (all pinned):

| Dependency | Version | Reason |
|---|---|---|
| [modelcontextprotocol/swift-sdk](https://github.com/modelcontextprotocol/swift-sdk) | **exact 0.12.1** | Latest release; `main` has an stdio crash (research §8.1) |
| swift-log (a dependency of the SDK) | follows the SDK | Logs go to stderr only |

Everything else uses system frameworks (CoreMIDI, Network, Accelerate, AudioToolbox, AVFoundation); no other third-party libraries.

---

## 3. MCP tools

### 3.1 Common result format

Every tool returns the same structure (`structuredContent`), with a text summary in `content`:

```json
{
  "status": "verified | unverified | partial | failed | needs_confirmation",
  "summary": "Track 3 \"Bass\" muted",
  "before": { "...": "state read before the operation" },
  "after":  { "...": "state read from Logic's feedback after the operation" },
  "evidence": ["mcu.led.mute[3]=on @ 412ms"],
  "warnings": [],
  "as_of": "2026-11-20T22:41:03.120+09:00"
}
```

- `verified`: the expected feedback was seen within the timeout.
- `unverified`: the message was sent, but this operation has no usable feedback channel (for example "Quantize").
- `partial`: part of a batch operation succeeded; each item is listed.
- `failed`: the expected feedback was not seen, or a precondition check failed (for example the LCD track name does not match the expected one); the reason is given.
- `needs_confirmation`: the first step of a destructive operation, see §4.1.

### 3.2 Tool list

| Tool | Read-only | Destructive | Phase |
|---|---|---|---|
| `logic_status` | Yes | No | 1 |
| `transport` | No | No (for recording see §4.1 question 3) | 1 |
| `get_session_state` | Yes | No | 1 (transport part), 2 (track part) |
| `mixer_set` | No | No | 2 |
| `list_commands` | Yes | No | 3 |
| `run_command` | No | Depends on the command | 3 |
| `write_midi` | No | No (see §3.8) | 4 |
| `analyze_audio` | No (with `capture` it locates and plays) | No | 5 |

Tool annotations `readOnlyHint` / `destructiveHint` / `idempotentHint` are set as the MCP spec describes, but whether Claude Code changes its permission behaviour because of them is unverified (research §8.1), so **the confirmation flow does not rely on the annotations**.

### 3.3 `logic_status`

Self-check tool; the first call when troubleshooting.

- Input: none.
- Returns: server version, client name and whether the client supports confirmation dialogs; whether the four virtual ports exist, and their UniqueIDs; Mackie handshake state and the time of the last message received from Logic; current bank position; whether Clock/SPP is being received; command mapping table version and "learned" flags; connected plug-in instances.
- State source: the server's internal state + the time each port last received data.

### 3.4 `transport`

- Input: `action`: `play` / `stop` / `record` / `locate`; `locate` takes `bar` (required) and `beat` (optional, default 1).
- Returns: `playing`, `recording`, `position` (bar.beat.division.tick).
- Play / stop / record: press the MCU Play (5E) / Stop (5D) / Record (5F) key.
- Verification: the LEDs of these three keys + the Mackie time display (Beats mode) + Clock Start / Stop and SPP on the Sync port.
- Locating (decided after the 2026-11-20 test, research §2.5): **closed loop on the jog wheel**. On Logic 13 one tick moves exactly one bar and snaps to the bar line, so send one tick, wait until the time display settles (no update for 30 ms), read it again, and repeat until it stops at 1.1.1.1 of the target bar. Uses Mackie only; no key commands needed.
  - Limits: can only locate to the start of a bar (`beat` must be 1); runs only while stopped; the time display must be in Beats mode; "Jog resolution depends on horizontal zoom" must be off.
  - Speed is about 0.12 s per bar (17→101 took 10.5 s). Can be optimised later, for example by triggering "Go to Beginning" first when the target is closer to the start.
  - Go to Position dialog (method A): in the test the digits could be entered, but the MCU Enter key did not confirm the dialog, so it is not used for now. "Go to Beginning + Forward" (method B) works but needs key commands; it is kept as an optimisation option.
  - The position read from the time display is authoritative; if the target is not reached, the tool returns `failed` with the actual position.
- Rate limit: at least 30 ms between key presses (press + release); only one transport operation at a time.

### 3.5 `get_session_state`

- Input: `include`: any combination of `transport` / `tracks` / `tempo`; `refresh`: whether to force a rescan of all tracks (by default the cache is used; the cache carries a timestamp).
- Returns:
  - `transport`: same as §3.4.
  - `tracks`: `[{ number, name, name_truncated, volume_db, pan, mute, solo, rec_arm }]`, plus `track_count`.
  - `tempo`: `{ bpm, time_signature, source }`; `source` is `plugin` (Phase 5) or `midi_clock` (estimated from the Clock interval during playback); when neither is available it is `null` with the reason.
- State sources:

  | Field | Source |
  |---|---|
  | Track name, volume, pan | Mackie LCD, fader echo, V-Pot display |
  | Mute, solo, record arm | Mackie LEDs |
  | Play / record state | Mackie LEDs + Clock Start/Stop |
  | Position | Mackie time display, with SPP as corroboration |
  | Tempo, time signature | Plug-in (Phase 5); before that, only the tempo can be estimated from Clock during playback, and the time signature is not available |

- Scanning all tracks means banking through them page by page (8 tracks per page; after each bank, wait for the LCD to settle, about 250 ms according to the research report), then banking back to the original position. Track numbers come from going back to the start with Option + Bank Left and counting pages, or from reading the LCD in the No:Name display format (Phase 2 tests which one is reliable).
- **Track name limits**: the Mackie LCD shows only **6 ASCII characters** per channel, does not show Chinese or Japanese names at all, and there is no way to get the full name through Mackie (research §2.2). So full names come from a **read-only Accessibility read** instead (the decision on §7 question 2): the full names (including Chinese and Japanese) are read from the track headers in Logic's main window and matched to the Mackie channel strips by track number. The result has `name` (full name, source `accessibility`) and `lcd_name` (the Mackie abbreviation). If Accessibility permission is not granted or the read fails, it falls back to the LCD abbreviation and says so in `warnings`.

### 3.6 `mixer_set`

- Input: `track` (track number), `expected_name` (optional, recommended; checked against the LCD), `volume_db` / `pan` / `mute` / `solo` (at least one). Also accepts an array for batch settings.
- Flow: bank to the page that holds the target track → check the name on the LCD → read the current values → act → wait for feedback → return the before and after values.
  - Volume: fader touch → 14-bit fader value → touch release (always with touch messages, research §1.2). Sources contradict each other on whether Logic echoes Pitch Bend after a surface move, so **either the echo or the `Volume x.x dB` that briefly appears on the LCD counts as confirmation**. The dB ↔ fader value table is calibrated in the Phase 2 tests (the research report gives 0 dB = 12443 on Logic 12; unverified on 13.0).
  - Pan: in Pan assignment mode the lower LCD line shows the pan value; the V-Pot is turned relatively and read back in a closed loop until it reaches the target value.
  - Mute / solo: pressed only if the current LED state differs from the target; the LED is checked after the press.
- **Runs only while stopped**: during playback, if a track is in Touch / Latch / Write automation mode, touching its fader writes automation, and "clearing / overwriting automation" is an operation that needs confirmation. So a call during playback returns `failed` with the reason. Also, if a track has automation in Read mode, values changed while stopped are overridden by the automation on playback; Mackie cannot read each track's automation mode, so the result always carries this reminder.
- Rate limit: consecutive moves of the same fader are merged into the last value; at least 2 ms between messages.

### 3.7 `list_commands` and `run_command`

- `list_commands` returns every command in the mapping table: name, description, whether it is destructive, how it can be verified after running (or "cannot be verified"), whether it has been learned.
- `run_command` input: `command` (command name), `confirmation` (for the second step of a destructive command).
- Each entry of the command table `Resources/commands.json`:

  ```json
  { "name": "undo", "logic_key_command": "Undo", "midi": "B0 14 7F",
    "destructive": false, "verify": "none" }
  ```

  `midi` is assigned by the server (a CC on the `LogicMCP Keys` port). `verify` can be `none` / `mcu_track_count` / `mcu_led:<key>` / `mcu_timecode` etc., and decides how the result is read back. Only MIDI feedback is used, never AppleScript to read the document state (that needs the Automation permission, which violates §4.3), so commands such as "Save" return `unverified`.
- Destructive commands (delete track, delete region, save over the file, clear automation) go through the confirmation flow in §4.1.
- Rate limit: at least 150 ms between key commands, run serially.

### 3.8 `write_midi`

Following research §4.6, "real-time recording" is the first choice:

- Input: `track`, `expected_name`, `start_bar`, `notes: [{ pitch, start_beat, duration_beats, velocity }]` (`start_beat` is relative to beat 1 of `start_bar`), `quantize` (optional). Pitch accepts 0–127 or `"C4"` notation.
- Flow:
  1. Precondition check: the target track is record-armed, no other track is armed, the Replace key (MCU `58`) LED is off, Cycle is off.
  2. Locate to the bar before `start_bar` and start recording.
  3. Get Logic's actual position from Clock / SPP on the Sync port, compute a CoreMIDI timestamp for each note from its beat position, and schedule the notes to `LogicMCP Notes` ahead of time.
  4. Stop after the last note ends; run the Quantize command if requested.
- Returns: the start and end position of the recording (confirmed by the time display) and the number of notes sent. **There is currently no way to read back the recorded notes themselves**, so the status is at best `partial` ("recording confirmed, content not read back"). After Phase 5, a MIDI monitoring plug-in could be added to check the result on playback.
- Limits: at most 2000 notes and 64 bars per call.
- Fallback: importing a MIDI file (needs Accessibility permission, or you drag it in by hand); whether to implement it is decided after the Phase 4 tests.

### 3.9 `analyze_audio`

- The plug-in sits on the main output (or any track), computes continuously and sends at about 10 Hz: momentary / short-term loudness, sample peak and true peak, spectrum (1/3 octave), tempo, time signature, play position.
- The server keeps a history indexed by bar position.
- Input: `instance` (plug-in instance, by default the one on the main output), `ranges: [{ label, from_bar, to_bar }]`, `capture` (when true and a range has no history, the tool locates and plays that range to capture it; this moves the playhead, so the tool is not marked read-only).
- Returns, per range: integrated loudness (LUFS), maximum short-term loudness, LRA, true peak (dBTP), average spectrum, and `coverage` (the fraction of the range actually measured). For example, "is the chorus much louder than the verse" is the difference between the integrated loudness of two ranges.

---

## 4. Safety and reliability

### 4.1 Confirming destructive operations

Two layers:

1. **Elicitation (preferred)**: Claude Code supports MCP elicitation from 2.1.76 (research §8.1). Before acting, the server sends a confirmation request to the client, the client shows a dialog, and the operation runs only after **you yourself click confirm**; declining or cancelling means it does not run. Whether the Code tab of the Claude desktop app shows the dialog as well has not been verified yet (research §9 item 9); it is tested in Phase 3.
2. **Confirmation token (fallback)**: when the client does not support elicitation, the first call returns `needs_confirmation` with a description of the operation and a one-time token (valid for 60 seconds, bound to the content of the operation). Claude must ask you in the conversation and call again with the token after you agree. This layer depends on Claude following the rules and is less reliable than the first.

Operations that need confirmation: delete track, delete region, save (overwrites the project file), clear automation. This list lives in the command table and can be extended or shortened later.

### 4.2 Rate limiting

All messages to Logic go through one serial send queue:

| Category | Default interval |
|---|---|
| Ordinary 3-byte message | ≥ 2 ms |
| SysEx | ≥ 10 ms |
| Key press (press → release) | 30 ms |
| Bank | wait until the LCD update finishes, at most 500 ms |
| Key command (Keys port) | ≥ 150 ms |
| Fader | only the latest target value of each fader is sent |

Also: only one tool call runs at a time (serialised in the MCP layer), and a single call has a cap on the number of operations. The values are configurable and are tuned after the Phase 1 and 2 tests.

### 4.3 Scope limits

- Communicates with Logic only through its own virtual MIDI ports; sends no AppleScript to other apps and does not simulate the keyboard.
- Accessibility (from Phase 2) is **read-only**: it reads only the UI elements of the process with bundle ID `com.apple.logic10`, to get the full track names; it does not click, type or change any UI state. The Accessibility code is kept in its own `LogicAX` module so it is easy to review.
- File access: only `var/` in this project's directory (single-instance lock). UniqueIDs are derived by hashing the port names, so no file is needed for them. Logs go to stderr only.

### 4.4 Reliability details

- **Single instance**: a lock file in `var/` ensures that only one server owns the four ports at a time; a second instance reports an error and exits at startup (research §7.3 item 10).
- **Stable port identity**: port names are fixed and UniqueIDs are FNV-1a hashes of the port names; a collision is reported as an error (research §8.2).
- **CoreMIDI callbacks**: the MIDI module is nonisolated by default; callbacks only copy the data and post it to an `AsyncStream`, with a cap on how much each callback processes (research §8.2).
- **SysEx**: sent as UMP first; Phase 1 tests whether Logic receives it complete. If it does not, switch to the old API.
- **stdio**: all messages to the client are serialised, to work around the message-concatenation problem of SDK 0.12.1 (research §8.1).

---

## 5. Testing

### 5.1 Unit tests

| Module | What is tested |
|---|---|
| MIDICore | Byte-stream parsing (running status, interleaved real-time messages, segmented SysEx); UMP ↔ byte conversion in both directions, especially 6-byte SysEx packets |
| MackieControl | Encoding and decoding of each message type; partial LCD updates; time code digits and decimal points; handshake flow |
| CommandMap | Loading and validating the command table; no conflicting MIDI assignments |
| AudioAnalysis | M / S / I / LRA / true peak checked with test signals synthesised from the written descriptions in EBU Tech 3341 / 3342, within the standards' tolerances (the EBU test-set files are not used) |
| AnalysisLink | Frame encoding/decoding, rejection of malformed frames |
| LogicMCP | Argument validation, confirmation tokens, result format |

### 5.2 Fake Logic (FakeLogic)

A pure-Swift model of Logic's Mackie host side, connected to LogicBridge through an in-memory pipe (the same interface as the real ports), with time from an injectable virtual clock so tests are repeatable:

- A number of tracks (name, volume, pan, mute, solo, record arm) and a bank position.
- Feedback the way Logic sends it: LCD (truncated, only the changed part sent), LEDs, fader echo (with delay and quantisation), time code.
- Simulates known quirks: toggle-key semantics, automatic banking when a channel is selected, bank delay, right-aligned last page, dropped messages.
- Behaviours on which sources contradict each other are switches, and both cases are tested: whether Logic echoes Pitch Bend after a fader is moved on the surface; whether output stops while a modal dialog is open.
- Transport: during playback it advances the time code and sends Clock / SPP; during recording it records the notes received on the Notes port as a "region", whose content and position tests can check.

`logic-mcp serve --fake` runs the whole MCP server with the same model on an in-memory pipe and creates no real ports, for end-to-end tests that do not disturb Logic. `logic-mcp console` is the companion debug console: it opens the real ports, logs Mackie traffic, sends key commands and runs locate experiments.

### 5.3 Manual verification checklists

One `docs/checklists/phase-N.md` per phase. Each item says "what to do in Logic → which tool to have Claude call → what you should see", and the checklist includes the questions from research.md §9 that need testing in that phase.

---

## 6. Phase plan (adjusted to the verification results)

| Phase | Content | Change from the original plan | Done when |
|---|---|---|---|
| 1 | Skeleton: SwiftPM project, MCP stdio, four virtual ports, single-instance lock, MCU handshake and state model, FakeLogic, `logic_status`, `transport` | Tested first: whether Claude Code can connect to an SDK 0.12.1 server; locate methods A / B / C; whether binding recovers automatically after the ports disappear | Claude can make Logic play, stop, record and jump to a given bar, and reads back the actual state |
| 2 | Mixer: banking, LCD parsing, fader dB calibration, `get_session_state` (track part), `mixer_set` | Full track names are read through read-only Accessibility, with the Mackie LCD abbreviations as fallback | Claude can list all tracks and set the volume, pan, mute and solo of any track |
| 3 | Command mapping table, guided learning with `logic-mcp setup-commands`, `list_commands`, `run_command`, confirmation of destructive commands | "One-click setup" replaced by guided learning (§7 question 6) | Claude can run common commands such as new track, quantize and undo |
| 4 | `write_midi`: real-time recording through the Notes port, aligned by Clock / SPP | The recorded content itself cannot be read back for now | A melody or chords written by Claude appear on the given track (you check visually in Logic) |
| 5 | AUv3 analysis plug-in + TCP feedback + `analyze_audio` | IPC uses loopback TCP; no need to switch to JUCE / AUv2 | Claude can answer "is the chorus much louder than the verse" |

Delivered at the end of each phase: code + all unit / FakeLogic tests passing + the `docs/checklists/phase-N.md` manual verification checklist + `docs/setup/` instructions for the steps you have to do.

What Phase 1 needs you to do in Logic (to be written up as detailed steps at that time): add a Mackie Control control surface and choose the `LogicMCP MCU` port; turn off "Bypass all while in background", "Touching fader selects track" and "Control surface follows track selection"; set Channel Strip View Mode to Tracks; in Project Settings, send MIDI Clock to `LogicMCP Sync`; learn the two or three key-command assignments used for locating ("Go to Position…", "Go to Beginning", "Forward").

---

## 7. Decision record

After the Phase 1 tests: question 1 is no longer needed (locating now uses the jog wheel and does not depend on key commands; the three key commands that were already learned are kept as a fallback).

Confirmed 2026-11-20: question 2 → (b). Question 8 was first answered "download", then, after reading the EBU terms of use (internal R&D only, no redistribution, downloading counts as acceptance; see research §6.4), changed to **do not download**; loudness tests use synthesised signals only. The rest follow the default recommendations (question 1: learn the locate key commands early; question 3: start with the session for now; question 4: confirm before recording in Replace mode; question 5: the project folder is this repository's directory; question 6: guided learning; question 7: use XcodeGen, confirm again before installing).

The original questions are kept below for reference.

1. **Jumping to a given bar**: both the preferred method A (Go to Position dialog) and the fallback method B (Go to Beginning + Forward one bar at a time) trigger key commands from the Keys port, so Phase 1 already needs you to learn two or three key-command assignments, earlier than the original plan's Phase 3. If you do not want to do this early, the only option is method C (closed loop on the jog wheel, Mackie only, slower, step size still to be calibrated). I suggest doing it early. Is that OK?
2. **Full track names**: Mackie gives only 6 ASCII characters, so Chinese and Japanese names cannot be read. Phase 2's completion criterion "read all track names" can be understood in two ways:
   - (a) Accept the abbreviations: Claude refers to tracks by "track number + abbreviation". Pure MIDI, no privacy permission needed.
   - (b) Add a read-only Accessibility read: read the full track names from Logic's window. The program that launches the server (the Claude desktop app or Terminal) has to be granted Accessibility permission, and that permission covers the whole program, not just this server; it also breaks easily when the UI structure changes.
   I lean towards (a) and suggest giving your frequently used tracks English names. Do your projects have many Chinese or Japanese track names?
3. **Port lifetime**: the server starts and exits with the Claude Code session, and the ports disappear with it. I suggest doing it this way in Phase 1 and testing whether Logic restores the binding automatically when the ports reappear; if it does not, move the ports and the Mackie state into a resident background process (LaunchAgent), with the MCP server only forwarding.
4. **Recording over existing material**: recording in Replace mode overwrites existing content. `write_midi` is already designed to refuse while Replace is lit; should `transport record` also ask you to confirm first in Replace mode?
5. **Scope of "the project folder"**: I take it to mean this repository's directory `~/logic-pro-mcp` (the server uses only its `var/`); the Logic project folder is written to only in the "import a MIDI file" fallback, for a temporary `.mid` file. Is that right?
6. **"One-click setup" in Phase 3**: controller assignments have no export / import, and the preferences file is a private binary format (research §3.4), so true one-click setup is not possible. Workable options:
   - (a) **Guided learning (recommended)**: run `logic-mcp setup-commands`; it tells you, one command at a time, which command's "Learn New Assignment" to click in the Key Commands window, then sends the matching message automatically. Fully supported; about 5 minutes for about 20 commands.
   - (b) Operate the Key Commands window automatically through Accessibility: needs Accessibility permission and breaks easily when Logic's UI changes.
   - (c) Provide a ready-made preferences file for you to swap in by hand: it overwrites all your existing control surface settings; not recommended.
7. **Xcode project for the Phase 5 plug-in**: writing an `.xcodeproj` by hand is not practical. I suggest XcodeGen (one `project.yml` generates the project; it needs a developer tool installed with Homebrew), or you create the project in Xcode from the Audio Unit Extension template and I fill in the code. Which do you prefer?
8. **EBU loudness test set** (87.4 MB zip): download it for testing? Without it, synthesised signals still cover most of the cases.
