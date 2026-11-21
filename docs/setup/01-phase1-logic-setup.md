# Phase 1 setup: build, and connect Logic to the emulated Mackie Control surface

Menu names are those of Logic's English UI. The tests were run on Logic 13.0 with the Japanese UI, so these names come from Apple's English documentation and have not been checked on an English-UI Logic yet. Every step below was actually carried out on this Mac on 2026-11-20.

> This Mac is already fully set up (see the [Phase 1 test results](../checklists/phase-1-results.md)). The steps below are for reinstalling, switching projects or moving to another computer.

---

## 0. Build

```bash
cd ~/logic-pro-mcp && swift build -c release
```

On success the last line is `Build complete!`. The executable is `~/logic-pro-mcp/.build/release/logic-mcp`.

## 1. Before you start: controller assignments must not be in learn mode

If Logic's Controller Assignments window is learning, it takes the Mackie messages as the input to learn and shows an alert saying the control is already assigned to another parameter and asking whether to reassign it; the Mackie buttons also have no effect.

1. **Logic Pro > Control Surfaces > Controller Assignments…**
2. Look at the **Learn Mode** button at the bottom right of the window: if it is highlighted blue, click it once to turn it off.
3. If that alert has already appeared, always click **Cancel**; do not click the reassign button.

## 2. Make the ports appear

The ports are created by the server or by the console; the two cannot run at the same time.

- Normally: open a Claude Code session in `~/logic-pro-mcp` and the server starts automatically (first copy `.mcp.json.example` to `.mcp.json` and fix the paths in it).
- For debugging: run the console in a terminal:

  ```bash
  ~/logic-pro-mcp/.build/release/logic-mcp console
  ```

Once the ports appear, **Logic adds a Mackie Control automatically within 1 second**. There is no need to add it by hand, and no alert appears.

## 3. Check the control surface and set its display modes

1. **Logic Pro > Control Surfaces > Setup…** opens the Control Surfaces Setup window.
2. There should be exactly **1** Mackie Control. If there are more, select the extra ones and delete them with the Edit menu at the top left.
3. Select it. Under **Device** on the left, Output Port and Input Port are both `LogicMCP MCU`.
4. In the **Control Surface Group** below: set **Channel Strip View Mode** to **Tracks** (not Arrange); **Clock Display** is **Beats**.

## 4. General control surface settings

**Logic Pro > Control Surfaces > Settings…** opens the Settings window at **Control Surfaces > General**:

| Setting | Set to | Why |
|---|---|---|
| Bypass all while in background | **Off** | Logic must stay controllable while it is in the background |
| Touching fader selects track | **Off** | Selecting makes the surface switch banks on its own and makes edits apply to several tracks |
| Control surface follows track selection | **Off** | Otherwise selecting a track in Logic scrambles the channel strip positions the server reads |
| Jog resolution depends on horizontal zoom | **Off** | Locating relies on "one Jog step = one bar" |

## 5. Have Logic send MIDI clock to the server (once per project)

1. **File > Project Settings > Synchronization…**, then switch to the **MIDI** tab.
2. In the first row, set **Destination** to `LogicMCP Sync` and tick **Clock** in that row.
3. **Clock Mode** is "Song—SPP at Play Start and Stop/SPP/Continue at Cycle Jump" (this is the default).
4. Leave both MMC options below **unticked**.

Without this step, play / stop still work (confirmed by the LEDs), but the tempo cannot be read.

## 6. (Optional) Learn three key commands

Locating now uses the Jog wheel, so this step is **not needed**. These three commands are kept for later optimisation and for Phase 3; on this Mac they are already learned.

| Name in the console | Key command (English / Japanese UI name, observed) | Message |
|---|---|---|
| `go-to-position` | Go to Position… / 位置を指定して移動… | `CC 20`, channel 16 |
| `go-to-beginning` | Go to Beginning / 先頭に移動 | `CC 21`, channel 16 |
| `forward-one-bar` | Forward / 早送り | `CC 22`, channel 16 |

For each one:

1. **Logic Pro > Key Commands > Edit Assignments…**, and type the command name into the search field at the top right (for example "Go to").
2. **First click the row to select it**, then click **Learn New Assignment** under "Control Surface" on the right (this button looks the same armed and unarmed).
3. In the console, type `key go-to-position` (with the matching name).
4. If text such as `CC 20 (127)` appears in the row's "Control Surface" column, it worked; if not, repeat steps 2 and 3.

## 7. Verify

Type these in the console, in order:

```text
status
play
stop
locate 9
```

If `mackie.surface_active` in `status` is `true` and the other three all return `"status" : "verified"`, setup is complete.
