# LogicMCP: control Logic Pro from Claude

LogicMCP lets Claude operate Logic Pro on your Mac through an emulated Mackie Control surface and
virtual CoreMIDI ports. Claude can start, stop, record and locate, read the track list and set
volume, pan, mute and solo, run Logic key commands, record notes together with Control Change and
pitch bend in real time along Logic's own MIDI clock, and compare loudness between bar ranges
(with the optional LogicMCP Meter plug-in). Every tool reports what Logic actually showed
afterwards, so a result is "verified" only when Logic confirmed it.

Not affiliated with or endorsed by Apple. Logic Pro is a trademark of Apple Inc. Source code,
design notes and test records: https://github.com/MacchaCat/logic-pro-mcp

## Requirements

- A Mac with **Apple silicon**, macOS 15 or later, and Logic Pro (tested with Logic Pro 13.0).
- **Claude Code** (tested), or Cowork running on the same Mac (supported for local servers
  according to Anthropic's documentation; not tested). The server is a local program: Claude chat
  on the web or in the desktop app's chat cannot use it.
- Only one copy of the server can own the LogicMCP ports at a time. If a second Claude session
  starts it while the first is running, the second copy stops with an error saying so.

## One-time setup in Logic

1. Enable the plugin and start a Claude Code session. The server creates the ports
   `LogicMCP MCU`, `LogicMCP Keys`, `LogicMCP Notes` and `LogicMCP Sync`, and Logic adds a
   Mackie Control surface by itself within about a second.
2. In **Logic Pro > Control Surfaces > Setup…** check that there is exactly one Mackie Control
   on `LogicMCP MCU`, then set **Channel Strip View Mode** to **Tracks** and **Clock Display**
   to **Beats**.
3. In **Logic Pro > Control Surfaces > Settings… > General** turn off "Bypass all while in
   background", "Touching fader selects track", "Control surface follows track selection" and
   "Jog resolution depends on horizontal zoom".
4. In every project you use with Claude: **File > Project Settings > Synchronization… > MIDI**,
   set **Destination** to `LogicMCP Sync` and tick **Clock**. Recording with `write_midi` needs
   this.

Optional extras, each with its own guide in the repository's `docs/setup/` folder:

- **Full track names**: grant Accessibility to the app that runs Claude (read-only access to
  Logic's track names; `02-phase2-accessibility.md`).
- **Key commands**: teach Logic the 20 key commands once (`03-phase3-commands.md`); Claude walks
  you through it with `learn_command`.
- **Loudness analysis**: build and insert the LogicMCP Meter Audio Unit from source with Xcode
  (`06-plugin.md`). It is not part of this plugin.

The menu names above are those of Logic's English UI. The project was tested with the Japanese
UI, so if a name differs slightly, go by what Logic shows.

## Tools

| Tool | What it does |
|---|---|
| `logic_status` | Connection state of the Mackie Control link, MIDI clock and analysis plug-in |
| `transport` | Play, stop, record and locate to a bar, confirmed by Logic's LEDs and time display |
| `get_session_state` | Transport state and, on request, the track list with volume, pan, mute and solo |
| `mixer_set` | Set volume, pan, mute and solo of tracks, each change checked by name first |
| `list_commands`, `run_command`, `learn_command` | Logic key commands through controller assignments |
| `write_midi` | Record notes, Control Changes and pitch bend into a track in real time |
| `analyze_audio`, `list_analysis_instances` | Loudness (EBU R 128), true peak and spectrum per bar range |

Destructive steps (deleting a track, saving, recording in Replace mode and similar) return a
one-time confirmation token first: Claude must ask you in the chat and only continue after you
agree.

## Example prompts

- "Start playback from bar 9, then stop when I say so."
- "Show me the tracks in this project and turn the Vocal track down by 3 dB."
- "Write a C major arpeggio in eighth notes at bar 17 on the Synth track, with a modulation swell
  over the last bar."
- "Compare the loudness of the verse (bars 9–16) with the chorus (bars 17–24)." (needs the
  LogicMCP Meter plug-in)
- "Create a new software instrument track and select all." (needs the learned key commands)

## Limits

- Tested on one Mac with Logic Pro 13.0 (Japanese UI). The English menu names come from Apple's
  documentation and have not been checked on an English-UI Logic yet.
- Recording of Control Changes and pitch bend is tested against the built-in fake Logic only, not
  yet on real Logic.
- Mackie Control cannot see regions or notes: after `write_midi`, check the new region in Logic.

## Privacy

Everything runs on your Mac. See [PRIVACY.md](PRIVACY.md).

## License

MIT (see [LICENSE](LICENSE)). `server/logic-mcp` is built from the source in
https://github.com/MacchaCat/logic-pro-mcp by `scripts/build-plugin.sh` (arm64, size-optimised,
ad-hoc signed). It includes third-party code under the MIT and Apache 2.0 licenses; see
[THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md).
