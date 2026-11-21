# LogicMCP privacy policy

Effective 2026-11-21. This policy covers the LogicMCP plugin and its server program
(`server/logic-mcp`), published at https://github.com/MacchaCat/logic-pro-mcp.

## What the server reads

- **From Logic Pro, over the emulated Mackie Control surface** (virtual MIDI ports on your Mac):
  the transport state, the time display, LED states, and the channel strips' short track names,
  volume, pan, mute and solo.
- **From Logic Pro's window, only if you grant Accessibility**: the full track names. The access
  is read-only; the server never clicks, types or reads other apps.
- **From the optional LogicMCP Meter plug-in**: loudness, true-peak and spectrum measurements,
  Logic's tempo and playback position, and the name of the channel strip the plug-in is on, over
  a TCP connection to 127.0.0.1 (your own Mac). The plug-in sends measurements, not audio.

## Where the data goes

- Tool results (for example track names and mixer values) go to the Claude app that started the
  server, as part of your conversation. From there, Anthropic's own privacy policy applies.
- The server makes **no other network connections**: no telemetry, analytics, crash reporting
  or third-party services. Its only listener is on 127.0.0.1, for the analysis plug-in.

## What is stored

- The server stores only a lock file with its process ID, in
  `~/Library/Application Support/logic-mcp`, so that only one copy owns the MIDI ports.
- The separate `logic-mcp console` tool, if you run it yourself, writes MIDI traffic logs to the
  same folder (or to `var/` in a source checkout). The plugin never runs it.
- Nothing else is kept between sessions. Deleting the folder above removes everything.

## Children

LogicMCP is a tool for operating music software; it does not knowingly collect data from
anyone, including children under 18.

## Changes and contact

Changes to this policy are published in the repository above. Questions: open an issue at
https://github.com/MacchaCat/logic-pro-mcp/issues.
