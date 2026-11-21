# Logic Pro MCP — Phase 0 verification report

Verification date: 2026-11-20  
This file covers the 7 verification items of Phase 0. Every conclusion cites its source. Anything for which no reliable source was found, or that is only documented for older Logic versions, is marked as such and left for manual verification in real Logic.

## 0. Notes

### 0.1 Tags

| Tag | Meaning |
|---|---|
| **[L13]** | Stated explicitly in Apple's official Logic Pro 13.0 documentation |
| **[Official-old]** | Official Apple / Mackie / Emagic documentation, but for Logic 12 or earlier |
| **[Source code]** | Source code of an open-source implementation |
| **[Community]** | Test reports from forums, blogs and third-party projects |
| **[Local]** | Found by read-only inspection on this Mac (app bundle, SDK headers, system sandbox profiles) |
| **[Inferred]** | Conclusion inferred from the categories above, with no direct evidence yet |
| **[Unverified]** | No source found |

Apple web pages were read through a summarising tool, so citations give the meaning, not the verbatim text. Standards documents (ITU / EBU PDFs), SDK headers and open-source code were read in the original.

### 0.2 Local environment [Local]

| Item | Value |
|---|---|
| macOS | 27.3 (26C5047e) |
| Xcode | 27.2 (27B52), SDK `MacOSX27.2.sdk` |
| Swift | 6.4.2 |
| Logic Pro | 13.0 (build 7801), path `/Applications/DAW/Logic Pro.app`, bundle ID `com.apple.logic10` |
| Code signing | 1 valid signing identity in the keychain (with a 10-character Team ID) |

Logic Pro 13.0's own entitlements (`codesign -d --entitlements`):

- `com.apple.security.app-sandbox = false`: Logic itself is **not sandboxed**
- `network.client` and `network.server` are both true
- `temporary-exception.audio-unit-host = true`

Note: Logic not being sandboxed does not mean plug-ins run outside a sandbox. See section 5.

### 0.3 Clues in the local app bundle [Local]

- `Contents/PlugIns/MIDI Device Plug-ins/Logic Control.bundle` (version 13.0) is Logic's Mackie control surface module. Its resources include these device models: Logic Control, Logic Control XT, Mackie Control, Mackie Control Extender, Extender Pro, MCU Pro, Mackie Control C4, Nucleus.
- The module's settings (`Localizable.strings`): `Touchless movable faders`, `Fader Touch Sensitivity`, `Serial No.`, `Transport Button Click`, `Backlight Saver Timeout`.
- Mode names that appear in the binary's strings (these only show that the features exist, not protocol details): `SMPTE/Beats`, `Name/Value`, various `Marker` / `Nudge` modes, `Cycle Set Locators by Jog Wheel`, `Bank Left/Right`, `Channel Left/Right`, `Flip Mode`, `Global View` (with filters such as `Audio Tracks` and `Midi Tracks`).
- `~/Library/Preferences/com.apple.logic.pro.cs` (the file that stores control surfaces and controller assignments) is a private binary format: header `4D 52 4F 46 … 46 43 53 53` ("MROF…FCSS", an IFF-like chunk container), not a plist.
- The key command sets `Resources/Key Commands/*.logikcs` are XML plists, but their only content is a binary blob `LogicBinaryPreferences`, so the command list cannot be read from them directly.
- Logic's `Info.plist` has `NSAppleScriptEnabled = true` but no `OSAScriptingDefinition`: AppleScript offers only the Standard Suite (open / save / close / quit), with no Logic-specific classes or commands.
- `MACore.framework/.../MIDI Device Scripts/` contains 98 `<model>.device/config.lua` files: Lua scripts Logic uses to auto-map common MIDI keyboards.

---

## 1. Mackie Control protocol

### 1.0 Sources and reliability

Byte-level formats were cross-checked against these four sources, which agree with one another:

| Key | Source | Nature |
|---|---|---|
| LC7 | Emagic / Apple *Logic Control MIDI Implementation*, Appendix B of the Logic 7 manual (pp. 239–255, firmware V1.0) ([manualsdir](https://www.manualsdir.com/manuals/547263/apple-logic-7.html?page=239)) | [Official-old], the only official byte-level specification found |
| ARD | Ardour `libs/surfaces/mackie` ([GitHub](https://github.com/Ardour/ardour/tree/master/libs/surfaces/mackie)) | [Source code], host-side implementation |
| TMCU | TouchMCU protocol document ([GitHub](https://github.com/NicoG60/TouchMCU/blob/main/doc/mackie_control_protocol.md)) | [Source code], surface-side, reverse-engineered |
| CAP12 | Real data captured by a third party on Logic 12.3 through a virtual port ([MongLong capture](https://github.com/MongLong0214/logic-pro-mcp/blob/main/docs/observations/evidence/2026-09-08-mcu-feedback-trace-en.json); a research subtask decoded it into 161 MIDI 1.0 messages) | [Community], observed on Logic 12.3 |

Apple's current *Control Surfaces Support Guide* describes behaviour only and gives no bytes. The newest web edition is 11.2; the PDF linked from the Logic 13.0 User Guide has the same content (May 2025, 220 pages) ([PDF](https://help.apple.com/pdf/logicpromac-css/en_US/logic-pro-mac-control-surfaces-support-guide.pdf)).

**None of the byte-level conclusions below have been observed on Logic 13.0.** Phase 1 must re-check them on real Logic 13.

SysEx header `<Hdr>` = `F0 00 00 66 <model>`. Models: `14` = Mackie Control (Universal / Pro), `15` = Mackie Control XT, `10` / `11` = Logic Control / XT (LC7, ARD, TMCU). Logic uses `14` for a device installed as "Mackie Control" (CAP12).

### 1.1 Buttons and LEDs

- Surface → host: `90 id 7F` pressed, `90 id 00` released.
- Host → surface (LEDs): `90 id 7F` on, `90 id 01` flashing, `90 id 00` off (LC7 p. 242; TMCU agrees).

| ID | Function | ID | Function |
|---|---|---|---|
| 00–07 | Record-ready, channels 1–8 | 4A–4E | Automation Read/Off, Write, Trim, Touch, Latch |
| 08–0F | Solo, channels 1–8 | 50–53 | Save, Undo, Cancel, Enter |
| 10–17 | Mute, channels 1–8 | 54 / 55 | Marker / Nudge |
| 18–1F | Select, channels 1–8 | 56–59 | Cycle, Drop, **Replace**, Click |
| 20–27 | V-Pot push | 5A | Solo (global) |
| 28–2D | Assign: Track, Send, Pan, Plug-in, EQ, Instrument | 5B–5F | Rewind, Fast Fwd, **Stop, Play, Record** |
| 2E / 2F | Bank Left / Right | 60–63 | Cursor keys |
| 30 / 31 | Channel Left / Right | 64 / 65 | Zoom / Scrub |
| 32 | Flip | 68–6F | Fader touch, channels 1–8 |
| 33 | Global View | 70 | Master fader touch |
| 34 | Name/Value | 71 / 72 | SMPTE LED / BEATS LED |
| 35 | SMPTE/Beats | 36–3D | F1–F8 |
| 3E–45 | Global View filters: MIDI Tracks, Inputs, Audio Tracks, Audio Instrument, Aux, Busses, Outputs, User | 46–49 | Shift, Option, Control, Cmd/Alt |

LC7 (pp. 251–254), ARD `device_info.cc` and TMCU agree on every ID. On connect, Logic 12.3 sent LED states for 00–2D, 32, 33, 4A–51, 54–5F, 64, 65 and 71–73 (CAP12); this can serve as the practical list of "buttons with LEDs".

### 1.2 Faders

- Position: Pitch Bend, one MIDI channel per fader, `E0`–`E7` = channels 1–8, `E8` = master fader; LSB first, then MSB, value `(hh<<7)|ll`, range 0–16383 (LC7 p. 242, ARD `fader.cc`, TMCU).
- Touch: `90 68+n 7F` / `90 68+n 00`, master fader `70` (LC7, ARD, TMCU).
- On connect Logic sends `<Hdr> 0C 00`. According to LC7 p. 241 this tells the **device** to "send fader moves only while touched"; it does not mean the host requires touch (CAP12).
- Whether Logic accepts Pitch Bend sent directly, without touch: **nobody has tested this in isolation** [Unverified]. One test on Logic 11.2 moved a fader with "touch → Pitch Bend 12000 → release"; the LCD briefly showed `Volume -1.2 dB` and then went back to the track name [Community] ([sharpfive #5](https://github.com/ambiguouscherry/sharpfive/issues/5)).
- **Whether Logic echoes Pitch Bend back after the surface moves a fader: sources conflict** [Unverified].
  - No echo: on Logic 11.2, moves started from the surface were not echoed back; only dragging with the mouse produced an echo (sharpfive #5). On Logic 12.3 no packets at all came back after writing a fader (MongLong; the author suspects the handshake had not been completed).
  - Echo: on Logic 12.0.1 an echo arrived after about 130 ms, and it was quantized (Imtylerrrrrr).
  - So the design must accept both: either an echo or the `Volume x.x dB` text on the LCD counts as confirmation.
- Research reports 0 dB = 12443 and +6 dB = 14845 on Logic 12.0.1 [Community] (Imtylerrrrrr); on connect, Logic 12.3 sent exactly 12443 (`1B 61`) for every fader (CAP12). The full value ↔ dB curve is [Unverified].

### 1.3 V-Pot

| Direction | Message | Encoding |
|---|---|---|
| Rotation (surface → host) | `B0 1i vv` (i = 0–7) | `vv = 0 s nnnnnn`: s = 0 clockwise, 1 counter-clockwise, n = number of ticks. Examples: `B0 10 01` = V-Pot 1 clockwise 1 tick, `B0 17 47` = V-Pot 8 counter-clockwise 7 ticks |
| LED ring (host → surface) | `B0 3i xx` | `xx = 0 p mm vvvv`: p = centre LED, mm = mode (0 dot / 1 boost-cut / 2 fill / 3 spread), vvvv = 0 (all off) or 1–0B (position) |
| Push | Note `20`–`27` | Same as buttons |

(LC7 pp. 243–244, ARD `pot.h`, TMCU.) In pan mode Logic 12.3 sends `B0 30..37 56`: centre LED on, mode 1, position 6, meaning pan centred (CAP12).

### 1.4 LCD

- Message: `<Hdr> 12 oo <ASCII…> F7`. `oo` 00–37 is the upper line, 38–6F the lower line; text can run on from the upper line into the lower line (LC7 p. 246, ARD, TMCU, CAP12).
- The buffer is 2 × 56 characters, 7 cells per channel strip; **a track name is effectively 6 characters + 1 space** (LC7; CAP12 shows Logic 12.3 does the same).
- Logic 12.3 wrote 111 bytes in one message (both lines together, 56 + 55) (CAP12); it also refreshes in several partial writes (research §7.3 item 6). The parser must keep a 112-byte frame buffer and accept any offset and length.
- Character set: ASCII. Logic converts 8-bit characters (curly quotes, accented letters) to the closest 7-bit characters [Official-old] ([Displays overview](https://support.apple.com/guide/logicpro-css/displays-overview-ctls72226f72/mac)). Chinese and Japanese characters cannot be displayed [Community] (Imtylerrrrrr).

### 1.5 Timecode display and assignment display

| Display | Single character | Multiple characters |
|---|---|---|
| Timecode (10 digits) | `B0 4i yy`, CC 40–49; 40 is the rightmost digit | `<Hdr> 10 yy… F7`, the first byte is the rightmost digit |
| Assignment display (2 digits) | `B0 4A yy` right, `B0 4B yy` left | `<Hdr> 11 yy yy F7` |

- Character encoding (6 bits): 00–1F = ASCII 40–5F (`@ A … Z`), 20–3F = ASCII 20–3F (space, punctuation, digits); **add 40 to light the decimal point** (LC7 example, ARD `translate_seven_segment`).
- Beats mode shows bars / beats / divisions / ticks grouped as 3 / 2 / 2 / 3 digits; SMPTE mode shows hours / minutes / seconds / frames [Official-old] (Displays overview).
- **Observed on Logic 13.0** (2026-11-20, [Phase 1 test results](checklists/phase-1-results.md)): each group is right-aligned and padded with spaces, and **no decimal point is ever lit**, e.g. `  1 1 1  1`, `  2 3 1217`. Only changed digits are sent, one CC per digit.
- The current mode is shown by LED `71` (SMPTE) / `72` (BEATS) and toggled with `35` (LC7, TMCU). On connect Logic 12.3 sent "off" for both LEDs (CAP12), so the mode has to be judged from later LED updates or from the digit format; needs testing.
- On connect Logic 12.3 sent the assignment display `PN` (Pan) (CAP12).

### 1.6 Meters

`D0 xx`, `xx = 0 hhh llll`: hhh = channel 0–7, llll = 0–C for 0–100%, E sets overload, F clears overload (LC7 p. 249; ARD / TMCU treat D as the maximum). The host sends only peaks and the surface decays them itself (about one segment per 300 ms). On connect Logic sends `<Hdr> 21 01` (vertical meters) and `<Hdr> 20 ii 07` (CAP12).

### 1.7 Handshake and global commands

| Direction | Message | Meaning |
|---|---|---|
| Host → surface | `<Hdr> 00 F7` | Device query |
| Surface → host | `<Hdr> 01 s1…s7 c1…c4 F7` | Connection query: 7-byte ASCII serial number + 4-byte challenge |
| Host → surface | `<Hdr> 02 s1…s7 r1…r4 F7` | Connection reply |
| Surface → host | `<Hdr> 03 s1…s7 F7` / `04 …` | Confirm online / reply error |
| Host → surface | `<Hdr> 13 00 F7` | Firmware version query; the surface replies `<Hdr> 14 v1…v5 F7` |
| Host → surface | `<Hdr> 0F 7F F7`, `61`, `62`, `63` | Go offline, all faders to zero, all LEDs off, reset |
| Host → surface | `0A`, `0B`, `0C`, `0E` | Transport button click, backlight timeout, touchless faders, touch sensitivity |

- The challenge is issued by the **surface**, so an emulated surface can pick its own challenge and accept any reply (LC7 p. 240; ARD's formula differs from LC7 in one place, which does not affect us).
- Logic 12.3 sends device queries and firmware queries to several models (`10`, `11`, `14`, `15`, `17`) (CAP12). No source has ever captured Logic sending `02` [Unverified].
- A manually installed virtual surface on Logic 11.2 received full feedback without completing the handshake [Community] (sharpfive #5); a 2003 MIDIbox forum post says a fixed fake serial number and challenge are enough to bring Logic online [Community-old] ([midibox](https://forum.midibox.org/t/lc-initialization/596)).
- **Approach**: for model `14`, answer `00` (reply `01` + fixed serial number + challenge), `02` (reply `03`) and `13` (reply `14` + version number), and ignore other models. The cost is low.

### 1.8 Jog wheel

`B0 3C xx`, encoded like the V-Pot (`01` forward 1 tick, `41` back 1 tick) (LC7 p. 245, ARD `jog.cc`, TMCU). How far one tick moves is undocumented. Logic's settings have a "Jog resolution depends on horizontal zoom" option; with it off the resolution is fixed, but its value is not stated [L13] ([General settings](https://support.apple.com/guide/logicpro/general-settings-lgcp1fe673ef/13.0/mac/27)).

### 1.9 Disagreements between sources

1. Challenge-response formula r2: LC7 / TMCU use `l3 >> 4`, Ardour uses `l3 >> l4`. (We are the surface side and do not need to compute it.)
2. Meter maximum: C in LC7, D in ARD / TMCU.
3. Length of one LCD message: the LC7 transcription says at most 100 bytes, Logic 12.3 actually sent 111 bytes, TMCU says at most 112.
4. Apple's guide contradicts itself: in one place Marker + F1–F8 jumps to markers 1–8, but the function key table says F1–F3 create / delete markers; in one place Option + Name/Value enters group settings, in another it toggles between "Name" and "No:Name".

## 2. Mackie Control in Logic Pro

### 2.1 Adding the device [L13]

1. Logic Pro > Control Surfaces > Setup… ([ctls718ddc0e](https://support.apple.com/guide/logicpro/add-a-control-surface-ctls718ddc0e/mac)).
2. New > Install, select Mackie Control, then "Scan" (Logic finds the ports itself), or "Add" and then choose the input / output ports manually in the device parameters ([ctls718dd91b](https://support.apple.com/guide/logicpro/ctls718dd91b/mac)). The virtual ports must already exist when the ports are chosen.
3. Apple says a connected Mackie Control is detected automatically when Logic starts; but on Logic 11.2 a virtual port was **not** detected automatically and was added manually [Community] (sharpfive #5). Whether it is detected automatically once it answers the device query is [Unverified]; projects disagree (research §7.3 item 11).
4. Extenders (XT): each unit has its own pair of ports (model `15`); drag them into one row in the Setup window, and their left-to-right order sets the channel order ([ctls718ddd90](https://support.apple.com/guide/logicpro/ctls718ddd90/mac)).
5. Settings related to running in the background [L13] ([General settings](https://support.apple.com/guide/logicpro/general-settings-lgcp1fe673ef/13.0/mac/27)):
   - **"Bypass all while in background"**: when on, control surfaces do nothing while Logic is not in the foreground. Our server must work while Logic is in the background, so this **must be off**. Default value [Unverified].
   - "Touching fader selects track": triggers selection → automatic banking (research §7.3 item 2); **turning it off is recommended**.
   - "Control surface follows track selection": makes the bank position follow what you click in Logic; **turning it off is recommended**, otherwise the bank position the server has read gets scrambled.
6. Set Channel Strip View Mode to **Tracks**: the default Arrange mode merges channels shared by several tracks into one channel strip, so channel strip index ≠ track number [L13] ([ctls718ddb55](https://support.apple.com/guide/logicpro/ctls718ddb55/mac)).

### 2.2 What state Logic sends back

Observed on Logic 12.3 (CAP12) and 11.2 (sharpfive #5), with the behaviour described in the 11.2 guide:

| State | How it is sent back | Notes |
|---|---|---|
| Track name | LCD upper line | **6 ASCII characters**; Chinese and Japanese are not shown |
| Pan and other V-Pot parameter values | LCD lower line + LED ring | |
| Fader position | Pitch Bend | Sent back when changed on the Logic side (mouse, automation); whether it is sent back after the surface itself moves the fader: sources conflict (§1.2) |
| Volume value | LCD briefly shows `Volume x.x dB` after a fader move | sharpfive #5 |
| Mute / solo / record-ready / select | LED | |
| Transport (play, stop, record, cycle, Replace) | LED | |
| Position | Timecode display (Beats or SMPTE) | |
| Assignment mode | 2-digit display | |
| Meters | Channel Pressure | |
| Track colour | `<Hdr> 72 …` (X-Touch extension) | 10.8 and later |
| Dialog text | Scrolls on the LCD upper line | [L13] ([ctls718dd7ba](https://support.apple.com/guide/logicpro/ctls718dd7ba/mac)) |

- **Full track names: not available over MCU**; there is no documented method. "Track Name Format = No:Name" puts the track number in front of the name (using up character cells of the name) [L13] ([ctls718ddfa8](https://support.apple.com/guide/logicpro/ctls718ddfa8/mac)). Extenders add channels, not name length.
- **Tempo: cannot be read over MCU.** Apple's Mackie chapters never mention tempo, and neither do the protocol references.
- Total track count: there is no message for it. One can jump to the last bank with Option + Bank Right and read the highest number from No:Name [Unverified]. Output and master channel strips come after the tracks, so a blank cell does not mean the end of the list [Community] (sharpfive #5).

### 2.3 Banking [Official-old]

([Bank buttons](https://support.apple.com/guide/logicpro-css/bank-buttons-ctls72224042/mac), [Channel buttons](https://support.apple.com/guide/logicpro-css/channel-buttons-ctls72227ddd/mac))

- Bank Left / Right moves 8 strips at a time (with extenders, the width of the whole group); Channel Left / Right moves 1 strip at a time.
- The last bank is right-aligned: with 19 tracks the banks are 1–8 → 9–16 → 12–19.
- Option + Bank / Channel Left jumps to the first bank, Option + Right to the last bank.
- Logic **does not tell the surface directly** which track the first channel strip is. Workarounds: go back to the start with Option + Bank Left and count the bank moves, or read the number from the LCD with the No:Name format [Unverified].
- After banking, wait for the LCD to settle; research reports about 250 ms [Community] (MongLong #862). One project reports that the Bank buttons have no effect, while another observed Bank moving 8 strips and Channel moving 1; these conflict (research §7.3).

### 2.4 Port lifecycle

- Logic selects ports by name in the device parameters [L13]. Since 12.0 the Setup window no longer lists disabled MIDI ports as "Invalid Port"; since 12.4 adding a new surface no longer changes the ports of other, unconnected devices [Official] ([Logic 12 release notes](https://support.apple.com/en-us/149604)).
- Apple recommends setting a virtual port back to the same `kMIDIPropertyUniqueID` every time it is created, so other clients keep their references (see §8.2).
- Test [Community] (MongLong, Logic 12.3, one machine): after the server was killed so its ports disappeared and a new server was started, things recovered **without re-adding the surface**. But that project fixed both the name and the UniqueID, so it is unclear which of the two Logic matched on; it also did not say whether Logic was restarted in between.
- Old report [Community-old] (Logic 9.1.8, [Apple Communities 4618552](https://discussions.apple.com/thread/4618552)): if a virtual port does not exist **when Logic starts**, Logic reports the missing port and drops the assignment.
- **Conclusion**: keep both the name and the UniqueID fixed; create the ports before Logic starts where possible; re-sync state after reconnecting. Both "port disappears and reappears while Logic is running" and "port missing when Logic starts" must be tested on Logic 13.

### 2.5 Jumping to a given bar

The Mackie protocol has **no** "go to bar N" message. Candidates:

| Option | Uses the bar number directly | Needs Logic in the foreground | Documentation | Confirmation |
|---|---|---|---|---|
| **A. Go to Position dialog**: key command `/` opens the dialog, the MCU types digits into it (F1–F8 = 1–8, MIDI Tracks = 9, Inputs = 0), Enter confirms | Yes | When `/` is triggered through a controller assignment from the Keys port: [Unverified] | Key command [L13] ([lgcp02bf31b6](https://support.apple.com/guide/logicpro/lgcp02bf31b6/mac)); F keys entering digits in the dialog [Official-old] (function key table, CSS PDF) | LCD shows the dialog text + timecode |
| **B. Key command "Go to Beginning" (Return) + N−1 × "Forward" (`.`, one bar each)**, closing the loop by reading the timecode after each step | Bar by bar | Same as A | [L13] (key command and transport pages; that the key command steps the same distance as the control bar button is [Inferred]) | Timecode |
| C. Jog wheel closed loop: go to the beginning first, then turn while reading the timecode | Indirectly | No | Step per tick undocumented | Timecode |
| D. MTC Full Frame: `F0 7F 7F 01 01 hh mm ss ff F7`; requires turning on "Listen to MIDI Machine Control (MMC) input" in Project Settings > Synchronization > MIDI | No: converting bars to SMPTE needs the tempo map, the SMPTE start and the frame rate; accurate only to the frame | Probably not [Unverified] | [L13] ([lgcp72142361](https://support.apple.com/guide/logicpro/midi-project-settings-lgcp72142361/mac)); the doc says that, once this is on, Logic responds to MMC play / stop and Full Frame locate | Timecode |
| E. Markers | Only if markers were placed in advance | No | [L13] | Timecode |
| MMC Locate (`F0 7F … 06 44 …`) | — | — | **Not** in the list of MMC commands Logic responds to | — |
| Song Position Pointer input | — | — | Logic only sends SPP, it does not receive it | — |

The MCU's own Rewind / FF buttons shuttle continuously; they do not move bar by bar [Official-old] ([Transport buttons table](https://support.apple.com/guide/logicpro-css/transport-buttons-table-ctls7222788e/mac)).

**Initial ranking** (all pending tests on Logic 13): A > B > C. D is set aside because Phase 1 has no access to the tempo map, the SMPTE start or the frame rate. Whatever the option, the bar number read from the timecode display is authoritative.

Caveats for option A:

- Outside the dialog, F1–F8 recall screensets and MIDI Tracks / Inputs change the Global View filter [Official-old] (function key table). So the digit keys **must only be sent after the dialog text has appeared on the LCD**; if any step fails, send Cancel (`52`) to close the dialog.
- Sources conflict: Apple says the dialog text is shown on the LCD upper line ([ctls718dd7ba](https://support.apple.com/guide/logicpro/ctls718dd7ba/mac)), while Imtylerrrrrr reports that on Logic 12.0.1 a modal dialog stops all control surface output.

**Logic 13.0 test results** (2026-11-20, [Phase 1 test results](checklists/phase-1-results.md)):

- Option A: as soon as the Go to Position dialog opened, the LCD showed the dialog contents (` -` and `OK`), so a modal dialog **does** send output to the surface. The digits entered with F1 and F7 reached the dialog (the "New" field showed `17 1 1 1`, but the LCD did not show it), yet after pressing the MCU's Enter the playhead went to 1.1.1.1; the cause has not been found. **Not adopted.**
- Option B: works; each "Forward" moves exactly one bar.
- Option C: with "Jog resolution depends on horizontal zoom" turned off, one tick is exactly one bar and lands on bar lines in both directions; ticks sent at 20 ms intervals get accelerated or merged, so each tick must be confirmed before the next. **C is adopted**: tests 5→17, 17→101, 101→3 and mid-bar→9 were all exact, at about 0.12 s per bar.

### 2.6 Version differences (Apple release notes)

| Version | Mackie-related changes |
|---|---|
| 10.8 | X-Touch LCDs show track colours; LED updates are reliable with MIDI 2.0 enabled; settings moved to Logic Pro > Settings |
| 11.2.1 | "Bypass All Control Surfaces" fully bypasses Mackie; fixed MCU track names not showing in new projects |
| 12.0 | Several Mackie custom assignment fixes; Invalid Port no longer shown |
| 12.2 | Mixer channels without a track can be controlled; faders no longer jump to the main output |
| 12.4 | Port assignments of unconnected devices are kept |
| 13.0 | No control surface entries in the release notes ([109503](https://support.apple.com/en-us/109503)) |

---

## 3. Controller Assignments

### 3.1 What can be mapped

The Class pop-up menu in the Expert view offers these target classes [L13] ([ctls71c306f7](https://support.apple.com/guide/logicpro/ctls71c306f7/13.0/mac/27)):

- **Key Command**: runs a key command. Since 12.0 the command menu has a search field. The docs say "some key commands provide on/off feedback".
- **Key**: emulates a computer keyboard key.
- **Global**: playhead position (several formats), scrub, locators and punch locators, marker positions and Go to Marker, Nudge, automation mode of all tracks, Cycle, Autopunch, plus zoom, quantize value and the like for the "currently focused window".
- **Channel Strip**: any channel strip or plug-in parameter. The channel can be specified as "selected track / fader group / index / audio / instrument / bus / aux / output / master / fixed to a track (11.2 and later)".
- Plus Mode Change, Control Surface Group and Automation Group.

Which key commands can be assigned: **there is no official allowlist or blocklist** [L13]. Apple says nearly every function has a key command. "Copy Key Commands to Clipboard" in the Key Commands window exports the complete list as tabular text ([lgcp68d9ced1](https://support.apple.com/guide/logicpro/lgcp68d9ced1/13.0/mac/27)); this is the most practical way to build a command list.

Two ways to create an assignment [L13]:

1. In the Key Commands window, select a command → "Learn New Assignment" → send a MIDI message ([lgcp41ff6979](https://support.apple.com/guide/logicpro/lgcp41ff6979/13.0/mac/27)). The learned entry is shown as device + MIDI string + "zone and mode", which indicates that it is stored in the controller assignments.
2. Choose the Key Command class directly in the Controller Assignments Expert view.

### 3.2 Message format, Learn, zones and modes [L13]

- How to open: Logic Pro > Control Surfaces > Controller Assignments… The shortcut documentation gives two different shortcuts (Cmd-K and Option-Shift-K); needs testing ([lgcp3bc760d6](https://support.apple.com/guide/logicpro/lgcp3bc760d6/13.0/mac/27)).
- When learning, Logic **ignores note messages by default**; first uncheck "Ignore MIDI Notes While Learning" in the Action menu ([ctls71c31855](https://support.apple.com/guide/logicpro/ctls71c31855/13.0/mac/27)).
- The Value Change field is a hexadecimal byte template with Lo7 / Hi7 placeholders. It supports 7-bit and 14-bit values and combinations of several messages; a message without placeholders is treated as a button (value 1). Negative values can be unsigned / two's complement / one's complement / sign-magnitude ([ctls71c30fbf](https://support.apple.com/guide/logicpro/ctls71c30fbf/13.0/mac/27)). Whether SysEx and Pitch Bend can be matched is not stated in the docs [Unverified].
- Assignments are bound to an input port.
- A zone is a group of controls and a mode is a set of assignments within a zone. Only one mode per zone is active at a time; assignments in "No Zone / No Mode" are always active ([ctls71c30a1c](https://support.apple.com/guide/logicpro/ctls71c30a1c/13.0/mac/27)). Apple's typical example is exactly this kind of always-on assignment, such as "transport, save, undo".
- The Easy view can only assign channel strip and plug-in parameters; key commands, Global and the like need the Expert view ([ctls71c3162b](https://support.apple.com/guide/logicpro/ctls71c3162b/13.0/mac/27)). Since 12.0 the Expert view no longer requires turning on "Advanced Tools" ([lgcp022a8b80](https://support.apple.com/guide/logicpro/lgcp022a8b80/13.0/mac/27)).

### 3.3 Feedback: essentially one-way

- Feedback only works for "directly supported control surfaces" and for Lua-script devices with CoreMIDI input and output ports; "feedback does not work over IAC"; "unsupported control surfaces can only send information, not receive it" [L13] ([ctls71c30e80](https://support.apple.com/guide/logicpro/ctls71c30e80/13.0/mac/27), [ctls71c30b7c](https://support.apple.com/guide/logicpro/ctls71c30b7c/13.0/mac/27)).
- A forum report says key-command assignments cannot send feedback, only CC assignments can [Community, search snippet only] ([Logic Pro Help #137967](https://www.logicprohelp.com/forums/topic/137967-logic-controller-assignments-feedback/)).
- **Conclusion**: ordinary assignments learned through a virtual port should be treated as "fire and forget", with no execution receipt. The state after a key command has run can only be confirmed indirectly through other channels (see 3.6).

### 3.4 Storage, export, import

- Controller assignments and all control surface settings are stored in `~/Library/Preferences/com.apple.logic.pro.cs` and **written automatically when Logic quits** [L13] ([ctls71c31487](https://support.apple.com/guide/logicpro/ctls71c31487/13.0/mac/27)).
- The 13.0 documentation has **no** export / import command for controller assignments. The official migration method is to copy the whole preferences file to the other computer and then change the input port of one assignment; all assignments that use the same port follow [L13]. This overwrites all of the user's control surface settings.
- The file is a private binary format (see 0.3) with no public specification. Logic rewrites it on quit, so changes made while Logic is running would be overwritten [Inferred]. **Programs should not write this file directly.**
- A user reports that every time a port is opened, entries are added to this file [Community] ([Imtylerrrrrr/logic-mcp troubleshooting](https://github.com/Imtylerrrrrr/logic-mcp/blob/main/docs/troubleshooting.md)).
- Key command sets can be imported and exported (`~/Music/Audio Music Apps/Key Commands/`) [L13], but whether key commands learned via MIDI are exported with the set is [Unverified] (they are shown as zone and mode, so they are more likely stored in the `.cs` file). Another project reports that since Logic 12.2, importing old-style key command plists is no longer accepted [Community] ([MongLong0214/logic-pro-mcp](https://github.com/MongLong0214/logic-pro-mcp)).

**Another installation path: Lua MIDI Device Scripts.** User scripts can be placed in `~/Music/Audio Music Apps/MIDI Device Scripts/<vendor>/` and then appear in the control surface Install window [L13] ([ctls718dd5b2](https://support.apple.com/guide/logicpro/ctls718dd5b2/13.0/mac/27)). But the Lua API has no public documentation; the bundled scripts are the only reference [Community]. Whether it can map arbitrary key commands, and whether it can match the virtual ports we create, are both [Unverified].

### 3.5 Version differences

- Since 11.2: new "fixed to a track" assignments (stored in the project); focused-track assignments are saved globally ([lgcpa3dd9191](https://support.apple.com/guide/logicpro/lgcpa3dd9191/13.0/mac/27)).
- Since 12.0: advanced features are no longer separated out; a new game controller tab; the command menu is searchable.
- The 13.0 "What's New" page does not mention controller assignments ([lgcp4a62a494](https://support.apple.com/guide/logicpro/lgcp4a62a494/13.0/mac/27)).

### 3.6 How to confirm what a key command did

Available indirect channels:

| Channel | What it can confirm | Source |
|---|---|---|
| Mackie Control feedback (LCD, LEDs, timecode) | Transport, changes in track count and names, mute / solo, etc. | Sections 1 and 2 |
| MIDI Clock / SPP / MTC sent by Logic (can be sent to any destination port, including our virtual port) | Play state, position, tempo | [L13] [lgcp72142361](https://support.apple.com/guide/logicpro/lgcp72142361/13.0/mac/27) |
| `document` properties of AppleScript's Standard Suite (`name`, `modified`) | Whether the project has been saved | [Local]; whether Logic implements them correctly [Unverified] |
| The Phase 5 plug-in | Tempo, time signature, playhead position | Section 5 |

For commands that no channel can confirm (for example "Quantize"), the tool must honestly return "sent, cannot confirm".

### 3.7 Needs testing

1. Do MIDI-triggered key commands act on the currently focused window? Do they work while Logic is in the background?
2. Can Value Change match SysEx / Pitch Bend?
3. Is the Controller Assignments shortcut in 13.0 Cmd-K or Option-Shift-K?
4. MIDI messages that match an assignment are "swallowed" and do not reach the recording [Community, search snippet only] ([#158554](https://www.logicprohelp.com/forums/topic/158554-how-does-the-controller-assignments-window-actually-work/)): control ports and note ports must be separate.

---

## 4. Writing notes into Logic

### 4.1 Importing a Standard MIDI File

- File > Import > MIDI File (or the Import button in the File Browser): placed **at the playhead position, rounded to the bar** [L13] ([lgcpdf6a3851](https://support.apple.com/guide/logicpro/lgcpdf6a3851/13.0/mac/27)).
- Dragging from the Finder into the Tracks area: the drop point sets the position (rounded to the bar) and the first track [L13].
- Opening a MIDI file with File > Open **creates a new project**; it is not inserted into the current project [L13]. `open -a "Logic Pro" x.mid` and AppleScript's `open` can only do the same [Inferred].
- **A way to import without the file dialog: none.** AppleScript has only the Standard Suite [Local], and there is no documented auto-import folder. All remaining methods need UI interaction: trigger "Import MIDI File" and drive the open panel through Accessibility, or have the user drag the file in by hand.
- Single-track files land on the selected track and multi-track files create new tracks; this behaviour is recorded only in an old forum thread [Community-old] ([#94089](https://www.logicprohelp.com/forums/topic/94089-import-midi-file-in-an-existing-track/)).
- Tempo trap: when the tempo mode is Adapt / Auto, imported MIDI changes the project tempo; Keep Project Tempo must be used [L13] ([lgcpca199cf6](https://support.apple.com/guide/logicpro/lgcpca199cf6/13.0/mac/27)).
- Known drag-and-drop issue: Logic 11.2 only accepted drops of type fileURL; Apple DTS says this was fixed in 12.0 [Official-old] ([developer forums 787165](https://developer.apple.com/forums/thread/787165)).

### 4.2 Playing live into a virtual port and recording

- Each track's inspector lets you choose a MIDI input port [L13] ([lgcp7aa2eb86](https://support.apple.com/guide/logicpro/lgcp7aa2eb86/13.0/mac/27), [lgcpa24ebb64](https://support.apple.com/guide/logicpro/lgcpa24ebb64/13.0/mac/27)), so the target track can listen to a "notes only" port alone.
- The handling of overlapping recordings (take folders, merge, overwrite, new tracks, etc.) and Replace mode are all selectable [L13] ([lgcp411dd5c8](https://support.apple.com/guide/logicpro/lgcp411dd5c8/13.0/mac/27), [lgcpb19162bf](https://support.apple.com/guide/logicpro/lgcpb19162bf/13.0/mac/27)).
- Count-in and pre-roll can be set. The Adapt tempo mode turns off cycle and may change the tempo, so Keep Project Tempo must be used [L13] ([lgcpbc10f1ea](https://support.apple.com/guide/logicpro/lgcpbc10f1ea/13.0/mac/27)).
- Logic can send MIDI Clock + SPP (or MTC) to any destination port [L13] ([lgcp72142361](https://support.apple.com/guide/logicpro/lgcp72142361/13.0/mac/27)): the side sending the notes can lock onto the moment Logic actually starts recording instead of estimating it from the wall clock.
- Timing accuracy: a virtual source must timestamp its own packets; CoreMIDI does not schedule `MIDIReceived` for you [Official] ([MIDIReceived](https://developer.apple.com/documentation/coremidi/midireceived(_:_:)), [coreaudio-api 2004](https://lists.apple.com/archives/coreaudio-api/2004/May/msg00139.html)). Whether Logic uses the packet timestamp or the arrival time when recording is [Unverified]; jitter and offset need to be measured.
- Variant: **Flashback Capture** (Shift-R; called Capture as Recording in 11.1 and earlier). Logic buffers incoming MIDI both while playing and while stopped; pressing it creates a region at the playhead on the focused instrument track, with no need to record-enable first [L13] ([lgcp8f89929b](https://support.apple.com/guide/logicpro/lgcp8f89929b/13.0/mac/27)).
- Temporarily raising the tempo to speed up entry: undocumented [Unverified].

**Assessment**: entirely over CoreMIDI, with no dialogs or UI scripting; lands on a known track; keeps velocities and off-grid timing. The cost is that it takes real time and has a little jitter.

### 4.3 MIDI step input

- The "MIDI In" button in the Piano Roll turns on step input. Notes can be entered one at a time from a MIDI keyboard at the current note length; note length, velocity, rests and moving forward / back all have key commands [L13] ([lgcpb19a8406](https://support.apple.com/guide/logicpro/lgcpb19a8406/13.0/mac/27), [lgcp4fe41fb3](https://support.apple.com/guide/logicpro/lgcp4fe41fb3/13.0/mac/27)).
- Drawbacks: grid timing only; the editor must be open with MIDI In on; depends on keyboard focus [Unverified].

### 4.4 MIDI effects / Scripter

- Since 11.0, "Record MIDI to Track Here" can record a MIDI effect's output as a region [L13] ([lgcp423beea5](https://support.apple.com/guide/logicpro/lgcp423beea5/13.0/mac/27)); internal MIDI routing can also record one track's output onto another ([lgcp1efa7c4d](https://support.apple.com/guide/logicpro/lgcp1efa7c4d/13.0/mac/27)). Both are still real-time recording.
- Scripter can send events at a given beat with `Event.sendAtBeat()` [L13] ([lgce0d0efc5a](https://support.apple.com/guide/logicpro/lgce0d0efc5a/13.0/mac/27)), but it can only receive data from MIDI input and has no documented file or network access.

### 4.5 Other

- Pasting MIDI from another app: no documentation and no reports; treated as unsupported [Unverified].
- Logic 13.0's smart assistant (beta) can generate MIDI regions, but it needs an Apple Creator Studio subscription and has no public interface [L13] ([lgcpd2878f53](https://support.apple.com/guide/logicpro/lgcpd2878f53/13.0/mac/27)).

### 4.6 Conclusion

| Option | Needs UI interaction | Accuracy | Speed | Placement certainty |
|---|---|---|---|---|
| Live recording (separate note port + Clock/SPP sync) | No | Some jitter; can be quantized afterwards | Real time | High (record-enabled track) |
| Flashback Capture | No | Same as above | Real time | High (focused track) |
| Import MIDI file | Yes (dialog or drag and drop) | Exact | Fast | Medium (rounded to the bar; multi-track files create new tracks) |
| Step input | No, but depends on editor state | Grid | Fast | Medium |

**Recommendation**: prefer "live recording"; use MIDI file import as the fallback for long passages or when exact timing is needed (needs Accessibility permission or a drag by the user); defer step input.

---

## 5. Communication between an AUv3 plug-in and an external process

### 5.1 Which process Logic runs plug-ins in

- AUv3 loads **out of process** by default. Only hosts on macOS can request in-process loading, and it can only succeed if the plug-in is packaged as a separate framework (`AudioComponentBundle` key); if the request fails, loading falls back to out of process [Official] ([Migrating your audio unit host to the AUv3 API](https://developer.apple.com/documentation/audiotoolbox/migrating-your-audio-unit-host-to-the-auv3-api); [Local] SDK `AudioComponent.h` lines 200–245).
- Out-of-process plug-ins run in `AUHostingServiceXPC` [Official] ([Debugging out-of-process audio units on Apple silicon](https://developer.apple.com/documentation/audiotoolbox/debugging-out-of-process-audio-units-on-apple-silicon)).
- Logic on Apple silicon does not load AUv3 in process; replying to a technical support request, Apple said this is expected behaviour [Community, quoting Apple] ([forums 766503](https://developer.apple.com/forums/thread/766503)).
- App Extensions on macOS **must** use App Sandbox [Official, DTS] ([forums 798886](https://developer.apple.com/forums/thread/798886)).
- `AUHostingService` uses a custom Apple sandbox, not App Sandbox [Official, DTS] ([forums 770046](https://developer.apple.com/forums/thread/770046)).
- Actual Logic 13 behaviour: all of the evidence predates 13.0, so it **needs testing** [Unverified].

So plug-in code may run in three places [Inferred]:

| Case | Where it runs | Sandbox |
|---|---|---|
| A | The AUv3 extension's own process | App Sandbox (per the extension's entitlements) |
| B | `AUHostingServiceXPC` | Apple's custom sandbox |
| C | Inside the Logic process | None (Logic is not sandboxed) |

### 5.2 Check of the local sandbox profiles [Local]

(The headers of `/System/Library/Sandbox/Profiles/*.sb` state that they are private Apple interfaces that may change at any time; what follows applies only to macOS 27.3.)

- **App Sandbox** (`application.sb`): `network.client` allows outgoing connections to any address, excluding only localhost:631 (the printing service). Once an App Group is declared, it allows reading, writing and binding sockets in that group's container, Mach names starting with `<group ID>.` and POSIX IPC names starting with `<group ID>/`.
- **AUHostingService** (`com.apple.audio.AUHostingService.sb`): deny by default; allows reading and writing the home directory, temporary directories, `/Library/Application Support` and `/Users/Shared`; **explicitly denies** `~/Library/Group Containers` and `~/Library/Containers`; allows all mach-lookup, outgoing network connections and POSIX shared memory. No rule for "accepting incoming connections" was found, so the plug-in side should act as the client.

### 5.3 Which options work under the sandboxes

| Option | Case A | Case B | Case C | Entitlements / signing needed | Source |
|---|---|---|---|---|---|
| **Local loopback TCP (plug-in as client)** | Yes | Yes | Yes | Add `network.client` to the extension | [Official] [network.client](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.network.client); [Local] both sandbox profiles |
| POSIX shared memory (name `<TeamID>.<short name>/<name>`, ≤31 characters) | Yes | Yes | Yes | The extension declares an App Group (Team ID prefix, no provisioning profile needed) | [Official] [application-groups](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.application-groups); [Local] `PSHMNAMLEN = 31` |
| Unix socket / file in a group container | Yes | **No** (group containers are denied) | Shows an authorization prompt or fails | Both the extension and the CLI must declare the App Group; the CLI must also be packaged in an app-like structure | Same as above; [Official] [Accessing app group containers](https://developer.apple.com/documentation/xcode/accessing-app-group-containers) |
| XPC / Mach service | Yes | Yes | Yes | Needs a resident launchd-managed agent as a relay; a server started over stdio cannot register a Mach name itself | [Official, DTS] [forums 715338](https://developer.apple.com/forums/thread/715338), [755911](https://developer.apple.com/forums/thread/755911) |
| Darwin notifications | Carries no data; whether allowed under the sandbox [Unverified] | | | | [Community] |

Additional notes:

- Since macOS 15 group containers are protected: even an unsandboxed process that accesses another app's group container triggers a "would like to access data from other apps" prompt. Only cases such as a matching Team ID prefix, an App Store install or authorization through a provisioning profile are exempt [Official, DTS] ([forums 721701](https://developer.apple.com/forums/thread/721701)). A bare CLI cannot embed a provisioning profile [Official] ([forums 835305](https://developer.apple.com/forums/thread/835305)).
- Listening on the loopback address does not need the "Local Network" permission; TN3179 is about broadcast networks such as Wi-Fi / Ethernet [Official] ([TN3179](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy), revised 2026-10-06). That loopback is excluded is [Inferred]. Whether the firewall shows a prompt when listening only on loopback is [Unverified].
- A free developer account can also use App Groups and App Sandbox [Official] ([Supported capabilities (macOS)](https://developer.apple.com/help/account/reference/supported-capabilities-macos)). The recommended option needs no App Group at all.
- `AUAudioUnit.messageChannelFor:` only connects the plug-in and the host; it cannot reach an external process [Local] SDK `AUAudioUnit.h`.

### 5.4 Switching to AUv2 (JUCE)

This does not fully avoid the sandbox problem [Inferred]: Logic on Apple silicon very likely also runs native AUv2 plug-ins inside `AUHostingServiceXPC` [Community-old] ([MacRumors](https://forums.macrumors.com/threads/native-m1-plugins-are-not-handled-natively-in-logic-pro-auhostingservice.2326554/)), under the same custom sandbox. The AUv2 API is not marked deprecated in the 27.2 SDK [Local], and Apple still maintains [AudioUnitSDK](https://github.com/apple/AudioUnitSDK). Loopback TCP works just as well under AUv2, so the premise "the AUv3 sandbox makes IPC too hard" **does not hold**, and there is no need to switch to JUCE.

### 5.5 Reading tempo and position in the plug-in

- AUv3: `musicalContextBlock` gives tempo, time signature, the beat position at the start of the current buffer and the beat position of the current bar's downbeat; `transportStateBlock` gives play / record / cycle state, sample position and cycle start / end beats [Local] SDK `AUAudioUnit.h` lines 218–304.
- AUv2: `kAudioUnitProperty_HostCallbacks` [Local] `AudioUnitProperties.h`.
- Whether Logic provides these callbacks: in 2017 they were reported empty in Logic 10.3.0 and fixed in 10.3.1 [Community-old] ([JUCE forum](https://forum.juce.com/t/audio-unit-v3-in-logic-and-garageband-mac/20737)); 13.0 [Unverified]. Another developer notes that only the current tempo and time signature are available, not the full tempo map or the bar number [Community] ([forums 858067](https://developer.apple.com/forums/thread/858067)).

### 5.6 Real-time safety

The render thread must not allocate memory, take locks, do file or network I/O, or touch the Swift / Objective-C runtime; Apple's sample writes the DSP kernel in C++ [Official] ([Creating custom audio effects](https://developer.apple.com/documentation/avfaudio/creating-custom-audio-effects)). The SDK marks some real-time APIs as unavailable in Swift [Local].

Recommended pattern [Inferred, industry practice]: the render thread (C++) only does the K-weighting filter and the sum of squares and sample peak of each 100 ms sub-block, and writes them into a preallocated lock-free single-producer single-consumer ring buffer; a background thread computes M / S / I / LRA / true peak / spectrum at 10–20 Hz and sends them. 100 ms sub-blocks combine exactly into the 400 ms (4 blocks) and 3 s (30 blocks) windows, and into the 75%-overlapping gating blocks.

### 5.7 Conclusion

- **First choice: local loopback TCP**. The MCP server listens on `127.0.0.1` and the plug-in's background thread connects to it as a client, with length-prefixed frames, at about 10 Hz, reconnecting 1–2 seconds after a disconnect. It works in all three cases; it needs no App Group and no provisioning profile; it does not touch group containers and causes no authorization prompt. The extension needs `app-sandbox = true` + `network.client = true`.
- **Fallback: POSIX shared memory + seqlock** (name `<TeamID>.<short name>/<name>`).
- Any local process can connect to this port, so the server treats received frames as untrusted data: it checks the magic number, version and length, and uses the data read-only.

---

## 6. Loudness measurement standards

### 6.1 ITU-R BS.1770

The current version is **BS.1770-5 (November 2023)** ([ITU-R BS.1770](https://www.itu.int/rec/R-REC-BS.1770)). The constants below are taken from the original text of the standard [Official].

**K-weighting** (48 kHz, two biquad stages; difference equation `y = b0·x + b1·x₋₁ + b2·x₋₂ − a1·y₋₁ − a2·y₋₂`):

| Stage | b0 | b1 | b2 | a1 | a2 |
|---|---|---|---|---|---|
| Stage 1 (high shelf, models the head) | 1.53512485958697 | −2.69169618940638 | 1.19839281085285 | −1.69065929318241 | 0.73248077421585 |
| Stage 2 (RLB high-pass) | 1.0 | −2.0 | 1.0 | −1.99004745483398 | 0.99007225036621 |

Other sample rates: the standard only requires "the same frequency response" and gives no formula. The open-source library [libebur128](https://github.com/jiixyj/libebur128) (MIT) derives the coefficients with the bilinear transform, using stage 1 f0 = 1681.974450955533 Hz, gain 3.999843853973347 dB, Q = 0.7071752369554196, and stage 2 f0 = 38.13547087602444 Hz, Q = 0.5003270373238773 [Source code]. A research subtask verified on this machine that at 48 kHz these parameters match the standard's table to 14 decimal places.

**Formulas**:

- Mean square: `z_i = (1/T) ∫ y_i² dt`
- Loudness: `L_K = −0.691 + 10·log10(Σ G_i · z_i)`, in LKFS (i.e. LUFS)
- Channel weights: L / R / C = 1.0, Ls / Rs = 1.41, LFE not counted
- Gating: 400 ms blocks, 75% overlap (100 ms step); absolute gate −70 LKFS; relative gate = mean loudness of the blocks that pass the absolute gate − 10 LU; the mean is taken over mean-square values, not over dB values

### 6.2 EBU R 128 and companion technical documents

- [R 128 V5](https://tech.ebu.ch/docs/r/r128.pdf) (2023-11): target **−23.0 LUFS**, maximum true peak **−1 dBTP**.
- [Tech 3341 V4](https://tech.ebu.ch/docs/tech/tech3341.pdf) (2023-11, "EBU Mode"): Momentary M = 400 ms sliding window, Short-term S = 3 s window, neither gated; Integrated I is computed with BS.1770 gating. A real-time meter must refresh S at least at 10 Hz and I at least at 1 Hz. Calibration: a 1 kHz stereo in-phase sine at −18 dBFS must read −18.0 LUFS.
- [Tech 3342 V4](https://tech.ebu.ch/docs/tech/tech3342.pdf) (2023-11, Loudness Range LRA): the input is the ungated 3 s short-term loudness (sampled at ≥10 Hz); absolute gate −70 LUFS; relative gate −20 LU; **LRA = 95th percentile − 10th percentile**.

### 6.3 True peak

BS.1770-5 Annex 2 [Official]: 4× oversampling (2× is enough for 96 kHz input), low-pass interpolation (the standard gives an example 48-tap, 4-phase FIR), absolute value, conversion to dBTP. 4× oversampling underestimates by about 0.55–0.69 dB in the worst case. Tech 3341 requires the true-peak test signals to be read within +0.2 / −0.4 dB. Sample peak (`max|x|`) underestimates transients.

### 6.4 Reference signals for unit tests

- [EBU loudness test set v5.0](https://tech.ebu.ch/publications/ebu_loudness_test_set) (zip, 87.4 MB, 48 kHz).
- Key points of the terms of use ([Use of EBU audio test sequences](https://tech.ebu.ch/files/live/sites/tech/files/shared/testmaterial/use%20of%20EBU%20AUDIO%20test%20sequences.pdf), version 1.0 of July 2019, read on 2026-11-20): it may only be used to evaluate the performance of audio equipment and systems in internal R&D; it must not be used for commercial or profit-making activities; it must not be copied, modified, published or distributed; **downloading or using it counts as accepting the terms**; citations must credit "© EBU". **Decision (2026-11-20): do not download it.** Tests use only signals synthesized from the text descriptions in Tech 3341 / 3342; the programme-material cases (3341 #7–8, 3342 #5–6) and the true-peak cases that depend on a specific downsampling filter (3341 #20–23) are therefore not covered.
- Most cases in Tech 3341 Table 1 (1 kHz sines, gating sequences, true-peak sines) and cases 1–4 of Tech 3342 Table 1 can be synthesized in tests from the documents' descriptions; the programme-material cases (3341 #7–8, 3342 #5–6) and some true-peak cases are only available from the zip [Inferred].

### 6.5 Spectrum

4096–8192-point FFT, Hann window, 50–75% overlap, computed with Accelerate/vDSP on a background thread and then merged into fractional-octave bands. This is engineering convention; there is no standard for it.

---

## 7. Existing projects

### 7.1 MCP projects for Logic Pro (as of 2026-11-20)

| Project | Language | Approach | Status |
|---|---|---|---|
| [MongLong0214/logic-pro-mcp](https://github.com/MongLong0214/logic-pro-mcp) | Swift, official Swift SDK | Accessibility + AppleScript + CGEvent + CoreMIDI + Mackie + Scripter | 213★, v3.19.0 (2026-11-18); claims Logic 13.0 support, but only 17 of its 138 operations have been verified on 13.0 |
| [koltyj/logic-pro-mcp](https://github.com/koltyj/logic-pro-mcp) | Swift | CoreMIDI + Accessibility + CGEvent + AppleScript + OSC | 145★ |
| [Imtylerrrrrr/logic-mcp](https://github.com/Imtylerrrrrr/logic-mcp) | Python | **Pure Mackie emulation**, needs no privacy permissions | 0★, but has protocol notes from tests on Logic 12.0.1 |
| [rosasynthesiz/logic-pro-mcp](https://github.com/rosasynthesiz/logic-pro-mcp) | Python | Poses as TouchOSC + Mackie + Accessibility | 4★ |
| [BanneBanning/logician-mcp](https://github.com/BanneBanning/logician-mcp) | Swift | Mackie + Accessibility, can export audio | 7★ |
| [cotyledonlab/logic-llm-connector](https://github.com/cotyledonlab/logic-llm-connector) | TS + Swift | Unix socket with mode 0600 to a companion process | 0★ |
| [audiohacking/logicx-mcp](https://github.com/audiohacking/logicx-mcp) | Rust AUv2 + companion app | Chat UI inside the plug-in; the companion app drives Logic through Accessibility | 4★ |
| [mrcolo/rubin](https://github.com/mrcolo/rubin) | Python | Generates MIDI files and imports them | 2★ |
| [PsychQuant/che-logic-pro-mcp](https://github.com/PsychQuant/che-logic-pro-mcp) | Swift | AppleScript keystroke emulation + virtual MIDI + MMC + Scripter templates | 11★, a one-day project |
| [qinnovates/logic-pro-mcp](https://github.com/qinnovates/logic-pro-mcp) | Swift | CoreMIDI / CGEvent / Accessibility / AppleScript / OSC routing table | 3★ |
| [aircrack-ng-debug/Logic-Pro-MCP](https://github.com/aircrack-ng-debug/Logic-Pro-MCP) | TS + Swift | AppleScript + Accessibility + node-midi | 5★ |
| [AnanK-sudo/logic-mcp](https://github.com/AnanK-sudo/logic-mcp) | TS | MCU + key commands + JXA Accessibility | 0★, paused (the plug-in selection pop-up is not in the Accessibility tree) |
| [infinitule/logicx](https://github.com/infinitule/logicx) | Python | Emulated MCU (Logic 12.3.1) | 0★ |
| [Jiinn-hhhh/logic-pro-codex-mcp](https://github.com/Jiinn-hhhh/logic-pro-codex-mcp) | Swift | Accessibility + AppleScript + CoreMIDI; observe → plan → confirm → execute → read back | 0★ |

Only MongLong0214 is in the official MCP registry. Not examined individually: rubenknol/logic-pro-mcp, LP12Magic (PyPI), sandst1/mcp-server-midi.

The full English report of the Mackie protocol research and the decoded Logic 12.3 capture are kept in [appendix/](appendix/) for reference.

### 7.2 Mackie surface emulators

- [tonvanderkolk/bcf-bridge](https://github.com/tonvanderkolk/bcf-bridge) (Swift, 2026-11): turns a BCF2000 into an MCU for Logic; the handshake is implemented in `MackieHandshake.swift`.
- [NicoG60/TouchMCU](https://github.com/NicoG60/TouchMCU): comes with a fairly complete MCU protocol document.
- [abrahamjeyaraj/faderport-classic-mcu](https://github.com/abrahamjeyaraj/faderport-classic-mcu) (C++).

### 7.3 Known Mackie pitfalls in Logic (all from Logic 12.x or earlier; 13.0 [Unverified])

1. **"Connected" cannot be inferred from receiving just any data**: after a virtual port disappears, Logic keeps a stale "Invalid Port" binding [Community] ([MongLong #861](https://github.com/MongLong0214/logic-pro-mcp/pull/861)).
2. **Selecting a channel makes Logic bank automatically**, so channel strip indexes silently point at other tracks; after banking it takes about 250 ms to settle ([#862](https://github.com/MongLong0214/logic-pro-mcp/issues/862)). Read the "channel strip → track" mapping from the LCD before acting (rosasynthesiz).
3. **Mute / solo / record-ready / select are all toggles**: read the state first and press only when it differs ([MongLong #1020](https://github.com/MongLong0214/logic-pro-mcp/issues/1020), koltyj #39).
4. **Edits apply to all selected channel strips**: one mute may mute 8 tracks ([infinitule/logicx](https://github.com/infinitule/logicx)).
5. **Faders should send touch messages**: a code comment in bcf-bridge says that if touch is not reported, Logic "fights" the fader, so it simulates a touch and releases it after about 400 ms [Source code]; in the Logic 9 era, users whose hardware touch sensing failed saw faders snap back [Community-old]. But "it does not work without touch" has not been tested in isolation (see §1.2).
6. **Decode UMP by bit shifting, not by reading bytes from memory**; SysEx was once dropped during UMP conversion, so no LCD text arrived ([#835](https://github.com/MongLong0214/logic-pro-mcp/pull/835), [#860](https://github.com/MongLong0214/logic-pro-mcp/pull/860)). Logic refreshes one LCD line in several partial SysEx writes.
7. **Work done in CoreMIDI callbacks must be bounded**, otherwise the whole server hangs (MongLong #683).
8. When Logic shows a modal dialog, all control surface output stops [Community] (Imtylerrrrrr). This contradicts Apple's documentation, which says "dialog text is shown on the LCD" (see §2.5); needs testing.
9. Non-ASCII track names are not shown on the LCD [Community] (Imtylerrrrrr). For Chinese / Japanese track names this is a hard limit.
10. An MCP client may start the server twice; a single-instance lock is needed to protect the ports (MongLong #1568, using `flock`).
11. Projects disagree on whether Logic installs a virtual MCU automatically.

### 7.4 Worth borrowing / to avoid

**Borrow:**

- A small number of "dispatcher" tools plus resources that provide state, rather than hundreds of tools (koltyj, MongLong).
- Honest result levels: verified / unverified / skipped / failed, with the values before and after the operation (MongLong, Imtylerrrrrr, yoka-cubase-mcp).
- Report success only after Logic's own feedback (LEDs, faders, LCD) confirms it.
- When addressing a target, also pass the expected track name and check it against the LCD.
- Two-step confirmation for destructive operations: first return a plan, then execute with a confirmation token (MongLong's plan hash).
- A `doctor` self-check tool that reports installation and connection status.
- Batch operations and range reads to save tokens ([ableton-mcp #130](https://github.com/ahujasid/ableton-mcp/issues/130)).

**Avoid:**

- Reporting success from pre-send or stale state ([ableton-mcp #134](https://github.com/ahujasid/ableton-mcp/issues/134), [#138](https://github.com/ahujasid/ableton-mcp/issues/138)).
- Assuming the current bank position; using toggles as if they set a state.
- Unstable or duplicate port names.
- Tools that execute arbitrary code.
- Pressing a plug-in's "action"-type parameters from the Mackie (Space Designer, for example, opens a file dialog this way) [Community].

---

## 8. MCP Swift SDK and CoreMIDI

### 8.1 MCP Swift SDK

| Item | Conclusion | Source |
|---|---|---|
| Latest release | **0.12.1 (2026-05-07)** | [releases](https://github.com/modelcontextprotocol/swift-sdk/releases) |
| Supported protocol versions | 2025-11-25 and earlier | [Versioning.swift @0.12.1](https://github.com/modelcontextprotocol/swift-sdk/blob/0.12.1/Sources/MCP/Base/Versioning.swift) |
| Minimum requirements | swift-tools 6.1 (plus a separate 6.0 manifest), macOS 13 | [Package.swift @0.12.1](https://github.com/modelcontextprotocol/swift-sdk/blob/0.12.1/Package.swift) |
| Supported features | stdio transport, tool annotations (`readOnlyHint`, `destructiveHint`, etc.), resources, progress notifications, logging, form-style elicitation | Same source code |
| Tool input schema | Hand-written JSON Schema (`Value`); no automatic generation from Codable | `Tools.swift @0.12.1` |

**Important:**

- **The current MCP specification is the 2026-07-28 version** (stateless, drops `initialize`, adds `server/discover`, elicitation changes to multi-round results) ([changelog](https://modelcontextprotocol.io/specification/2026-07-28/changelog)). The Swift SDK has not released a matching version yet ([PR #314](https://github.com/modelcontextprotocol/swift-sdk/pull/314) is not merged).
- Since Claude Code 2.1.292 (2026-10-06), stdio negotiates 2026-07-28 by default, and the specification requires dual-version clients to fall back to `initialize` on failure; the environment variable `MCP_PROTOCOL_NEGOTIATION=legacy` forces the old protocol ([Claude Code changelog](https://code.claude.com/docs/en/changelog)). Whether a 0.12.1 server handles the fallback smoothly is [Unverified]; it is the first item to test in Phase 1.
- **Pin the 0.12.1 tag; do not follow `main`**: changes on `main` make stdio crash on a socketpair, and that is exactly how Node-based clients (including Claude Code) start servers ([#327](https://github.com/modelcontextprotocol/swift-sdk/issues/327)).
- Known issue in 0.12.1: concurrent `send()` calls under backpressure can splice two JSON-RPC messages together ([#263](https://github.com/modelcontextprotocol/swift-sdk/issues/263)), so we must serialize all sends ourselves.
- A stdio server must never log to stdout, only to stderr ([specification](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports)). The example in the SDK README logs to stdout and must not be copied as is.
- In 0.12.1, elicitation does not check by default whether the client supports it; we must decide that ourselves from the client capabilities sent at initialization.
- Claude Code supports elicitation since 2.1.76. Tool annotations are shown in `/mcp`, but there is no evidence that Claude Code changes its permission behaviour based on `destructiveHint` [Unverified]. **So confirmation of destructive operations cannot rely on annotations alone.**

### 8.2 CoreMIDI virtual ports [Local SDK headers + official documentation]

- Recommended APIs: `MIDIClientCreateWithBlock`, `MIDISourceCreateWithProtocol`, `MIDIDestinationCreateWithProtocol`, `MIDIReceivedEventList` ([documentation](https://developer.apple.com/documentation/coremidi/midisourcecreatewithprotocol(_:_:_:_:))).
- The old APIs (`MIDISourceCreate`, `MIDIReceived`, `MIDIPacketList`, etc.) are marked "to be deprecated" in the 27.2 SDK; Swift 6.4.2 compiles them without warnings, and they still work.
- **SysEx in UMP carries at most 6 data bytes per 64-bit packet** (`kMIDI1UPMaxSysexSize = 6`), without F0 / F7, with status bits marking complete / start / continue / end. One MCU LCD write (payload up to 118 bytes) takes about 20 packets. Whether CoreMIDI's conversion of UMP SysEx into the byte stream it hands to Logic is fully lossless is [Unverified]; the fallback is to send SysEx through the old `MIDIPacketList` path (which is what MongLong does).
- Stable `kMIDIPropertyUniqueID`: Apple recommends setting a virtual port back to its previous ID every time it is created; on a conflict, `kMIDIIDNotUnique` is returned ([documentation](https://developer.apple.com/documentation/coremidi/kmidipropertyuniqueid)). Sources and destinations need different IDs. Whether a fixed ID alone lets Logic re-bind automatically: projects disagree [Unverified].
- **Swift 6 concurrency trap**: closures for CoreMIDI written inside a `@MainActor` context are inferred to be main-actor isolated. This compiles without errors, but when CoreMIDI calls them on its own thread, a runtime check fires and the process crashes (a research subtask verified this on this machine with SIL; [SE-0423](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0423-dynamic-actor-isolation.md)). The MIDI module must stay nonisolated by default, callbacks must be explicit `@Sendable` closures, and a callback must only copy the data and post it to an `AsyncStream`, without waiting or doing heavy work.

---

## 9. Summary: open questions that affect the design

| # | Question | Phase | How to verify |
|---|---|---|---|
| 1 | When Claude Code negotiates 2026-07-28, can a Swift SDK 0.12.1 server fall back correctly | 1 | First item of Phase 1 |
| 2 | Does Logic 13 install a virtual MCU automatically; does it re-bind automatically after a port disappears and reappears | 1 | Manual checklist |
| 3 | Does UMP SysEx reach Logic losslessly | 1–2 | **Verified**: the version `1.00` shown in Logic's Control Surfaces Setup window comes from the firmware version reply we sent as UMP SysEx, so Logic received it intact. CoreMIDI layer (self-test, 2026-11-20): UMP SysEx sent from a virtual source (5–120 bytes, including 6-byte packet splitting) was received intact by both a UMP reader and a legacy MIDIPacketList reader; the legacy path (`--sysex legacy`) was intact as well. Whether Logic itself receives everything intact is still to be tested in Phase 1 |
| 4 | Which way to jump to a given bar | 1 | **Tested**: option A does not work, B works, C (closed-loop jog) works and is adopted; see §2.5 |
| 4a | Does Logic detect the surface automatically once it answers the device query; does Logic send `02` | 1 | **Tested**: after the console answered the device query, Logic **automatically installed** a Mackie Control within 0.3 s and started driving it; Logic never sends `02`. (In an earlier self-test that did not answer the query, Logic did not react at all.) |
| 4b | Do fader moves without touch messages work; fader value ↔ dB curve | 2 | Manual checklist + calibration |
| 4c | Digit count, zero padding and decimal points of the timecode display; do the SMPTE / BEATS LEDs follow the mode | 1 | **Tested**: right-aligned, space-padded, no decimal points; the BEATS LED is on at connect. Switching to SMPTE not tested |
| 4d | Can the No:Name format reliably give track numbers; how to get the total track count | 2 | Manual checklist |
| 5 | Do MIDI-triggered key commands depend on the focused window; do they work in the background | 3 | Manual checklist |
| 6 | Does Logic record by timestamp or by arrival time; actual jitter | 4 | Manual checklist + measurement |
| 7 | Which process Logic 13 runs plug-ins in; does it provide tempo / transport callbacks | 5 | Manual checklist |
| 8 | Does a CLI that listens only on loopback trigger a firewall prompt | 5 | Manual checklist |
| 9 | Do the Claude desktop app (Code tab) and the CLI both show the MCP elicitation confirmation dialog | 3 | **Tested (desktop app)**: Claude Code 2.1.326 declares the elicitation capability at initialization but shows no dialog and replies `decline` directly. The server cannot rely on elicitation and must be configurable to confirm in chat (token) |
| 10 | Does Logic echo Pitch Bend back after the surface moves a fader (sources conflict, §1.2) | 2 | Manual checklist |
| 11 | Does the control surface still get output while a modal dialog is open (sources conflict, §2.5) | 1 | **Tested**: while the Go to Position dialog is open, the LCD shows the dialog contents |
| 12 | Does Logic reconnect automatically after a port disappears and reappears | 1 | **Tested**: when the port reappears while Logic is running, Logic reconnects automatically within 0.3 s without installing a duplicate; the case where the port is missing when Logic starts has not been tested |
| 13 | When Claude Code negotiates 2026-07-28, can it fall back to an SDK 0.12.1 server | 1 | The server returns -32601 for `server/discover` and handles `initialize` normally; driving `serve` with a scripted client passed against real Logic. The real Claude Code client has not been tested (the CLI was not logged in); left for you to verify in a new session |
