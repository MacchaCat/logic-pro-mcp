# Phase 5 setup: installing the LogicMCP Meter analysis plug-in

The measurements of `analyze_audio` come from an AUv3 audio effect plug-in, **LogicMCP: Meter**. It is inserted on Logic's main output (Stereo Out), passes the audio through unchanged, and meanwhile computes loudness (ITU-R BS.1770-5 / EBU R 128), peak, true peak and a 1/3-octave spectrum, in blocks of 100 ms, which it sends to the logic-mcp server over local loopback TCP (`127.0.0.1:47810`–`47813`; the plug-in is the client). The plug-in connects only to this Mac, never to the network.

Menu names are those of Logic's English UI. The tests were run on Logic 13.0 with the Japanese UI, so these names come from Apple's English documentation and have not been checked on an English-UI Logic yet.

## 1. Build (once)

Requires Xcode and XcodeGen (installed on this Mac: `/opt/homebrew/bin/xcodegen`).

```bash
cd ~/logic-pro-mcp/Plugin && xcodegen generate
```

```bash
cd ~/logic-pro-mcp/Plugin && xcodebuild -project LogicMCPMeter.xcodeproj -scheme LogicMCPMeter -configuration Release -derivedDataPath ../var/plugin-build build
```

- Signing is "Sign to Run Locally" (ad-hoc), so the plug-in works only on the Mac that built it; the project stores no developer account or certificate information.
- Output: `~/logic-pro-mcp/var/plugin-build/Build/Products/Release/LogicMCPMeter.app`; the plug-in is inside it at `Contents/PlugIns/LogicMCPMeterExtension.appex`.

## 2. Register the plug-in with macOS (once)

Open the container app once (it only shows a short explanation, and you can quit it right away):

```bash
open ~/logic-pro-mcp/var/plugin-build/Build/Products/Release/LogicMCPMeter.app
```

Check that it is registered and passes Apple's validation:

```bash
auval -v aufx lmtr Lmcp
```

The last line should be `AU VALIDATION SUCCEEDED.` (passed on this Mac on 2026-11-21).

> Just leave the app in `var/plugin-build`. Moving or deleting it makes the plug-in disappear; after rebuilding, open it once again.

> **Do not rebuild while Logic is using the plug-in**: the build replaces the extension on disk, the plug-in process running in Logic exits at once, and Logic shows "An Audio Unit plug-in reported a problem which might cause the system to become unstable." (observed 2026-11-21). The dialog has two buttons, **復元** and **終了** (the Japanese UI labels as observed, literally "Restore" and "Quit"; the English labels are unverified). That time, after the dialog closed (whether 復元 was clicked or the dialog went away by itself was not seen), Logic recreated the instance with the newly built plug-in without restarting (with a new instance id). To be safe, quit Logic or remove the plug-in before rebuilding.

## 3. Make Logic see the plug-in

Logic scans for new Audio Units only **at launch** (opening the Plug-in Manager while it is running does not find them either). So after registering, **quit and reopen Logic**. On reopening, Logic validates the new plug-in, and in **Logic Pro > Settings > Plug-in Manager…** you can find the manufacturer **LogicMCP** (code `Lmcp`) with the name **Meter**; its Compatibility column should show "✓".

## 4. Insert it

1. Find the **Stereo Out** channel strip in the Mixer or the inspector.
2. Click its **Audio FX** slot → **Audio Units** → **LogicMCP** → **Meter** → **Stereo**.
3. The plug-in has no interface: opening it shows only a blank window or the generic parameter view, which you can close.

When the plug-in is **last** in the Stereo Out effects chain, it measures the final output. It can also go on a track: then `analyze_audio` must name it with `instance` (`list_analysis_instances` lists all instances and their channel names).

## 5. Check

Ask Claude to call `list_analysis_instances`: you should see one instance with `connected: true`, `plugin_reported_context_name` set to the channel name Logic gives it, and `claims_main_output` `true` (the name looks like "Stereo Out"). During playback `momentary_lufs` changes, and `covered_bars` grows as playback goes on.

When the server (logic-mcp in Claude Code) is not running, the plug-in reports no error; it just sends nothing. It reconnects automatically within a few seconds after the server starts.
