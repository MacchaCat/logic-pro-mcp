# logic-pro-mcp

An MCP server that lets Claude control Logic Pro on macOS through virtual CoreMIDI ports:
an emulated Mackie Control surface (transport, mixer, displays), controller-assignment
key commands, real-time note recording, and a companion Audio Unit for loudness analysis.

Tested only on one Mac with Logic Pro 13.0 (Japanese UI), Claude Code and macOS 27. Menu names in
`docs/` and in the server's setup steps are those of Logic's English UI, taken from Apple's English
documentation; they have not been checked on an English-UI Logic yet. Not affiliated with or
endorsed by Apple; Logic Pro is a trademark of Apple Inc.

Status (each verified against real Logic 13.0, Japanese UI):
**Phase 1** — transport (play / stop / record / locate).
**Phase 2** — track list (`get_session_state` with `tracks`) and `mixer_set` (volume, pan, mute,
solo).
**Phase 3** — Logic key commands through controller assignments (`list_commands`, `run_command`,
`learn_command`): a catalog of 20 commands on `LogicMCP Keys`, all learned on this Mac, verified
where Logic's control surface shows the effect.
**Phase 4** — `write_midi`: notes recorded in real time along Logic's MIDI clock (+3 ms calibration).
Control Changes and pitch bend can be recorded with the notes too (tested against FakeLogic only, not
yet on real Logic).
**Phase 5** — `analyze_audio` / `list_analysis_instances` with the LogicMCP Meter AUv3 plug-in
(`Plugin/`, BS.1770-5 / EBU R 128 loudness, true peak, spectrum per bar range).
See `docs/design.md` for the plan, `docs/research.md` for sources and
`docs/checklists/phase-*-results.md` for the real-Logic test records.

## Use with Claude Code

Copy `.mcp.json.example` to `.mcp.json` and put the absolute path of this checkout in it, then
follow `docs/setup/01-phase1-logic-setup.md` to let Logic install the emulated Mackie Control.

## Build and test

```bash
swift build -c release
swift test
```

`swift test` never creates real MIDI ports. The one test that does runs only with
`LOGIC_MCP_REAL_MIDI_TESTS=1`.

## Run

- `logic-mcp serve` — MCP server on stdio (what Claude Code launches).
- `logic-mcp console` — interactive setup/diagnostic tool on the same ports.
- `logic-mcp serve --fake` — MCP server against an in-memory fake Logic (no ports).

Setup steps for Logic: `docs/setup/01-phase1-logic-setup.md`; full track names (optional
Accessibility permission): `docs/setup/02-phase2-accessibility.md`; key commands:
`docs/setup/03-phase3-commands.md`; note recording: `docs/setup/04-phase4-recording.md`; analysis plug-in:
`docs/setup/06-plugin.md`.
Manual verification: `docs/checklists/phase-1.md`, `docs/checklists/phase-2.md`, `docs/checklists/phase-3.md`.

## Layout

| Module | Role |
|---|---|
| `MIDICore` | MIDI 1.0 byte stream and UMP codec (pure) |
| `MackieControl` | Mackie Control messages, surface state, handshake (pure) |
| `MIDIPorts` | CoreMIDI virtual endpoints — the only module importing CoreMIDI |
| `LogicBridge` | Session state, transport, mixer (track scan, `mixer_set`), key commands, sync, rate limiting, result envelope |
| `LogicAX` | Read-only Accessibility reader of Logic's full track names |
| `CommandMap` | Key-command catalog (a Swift table: id, CC, Logic names, how each is verified) and learning steps |
| `FakeLogic` | Test double for Logic's Mackie Control host side |
| `LogicMCP` | Executable: MCP server, console |

## License

MIT, see `LICENSE`. Third-party material and its notices: `THIRD_PARTY_NOTICES.md`.
