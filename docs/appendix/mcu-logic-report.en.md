# Mackie Control (MCU) emulation for Logic Pro 13.0: research report

All byte values are hex. The SysEx header `<Hdr>` is `F0 00 00 66 <model>`. Source keys in [brackets] are listed at the end.

**Evidence tags**
- **[13]**: documented in Apple's Logic Pro User Guide pages served as version 13.0.
- **[11.2-doc]**: Apple's Control Surfaces Support guide. The web version's selector tops out at 11.2. The 13.0 User Guide links to a guide PDF (`logicpromac-css`) that is byte-for-byte the same text as the one I read: 220 pages, created May 2025. I found no newer edition.
- **[OLD]**: older official source (the Logic Control / Logic 7 era). Needs verification in real Logic.
- **[OSS]**: open-source implementation code.
- **[OBS-11.2] / [OBS-12.3]**: third-party traffic captured from real Logic 11.2 / 12.3 using a virtual CoreMIDI port.
- **[FORUM]**: user reports.

**How these map to the two requested tags**
- **Documented for Logic 11+/13:** [13] and [11.2-doc].
- **Older source, needs verification in real Logic:** [OLD] and [FORUM].
- **[OBS] and [OSS]:** not Apple documentation; they hold for the Logic version stated.

**Nothing at the byte level has been observed on Logic 13.0.** Every wire-level claim below needs to be confirmed against real Logic 13.

---

## A. Protocol (byte level)

### Primary byte-level references
- **Official spec [LC7] [OLD]:** the Emagic/Apple *Logic Control MIDI Implementation*, Appendix B of the Logic 7 manual (pp. 239–255, firmware V1.0). I did not find a Mackie-branded MCU owner's manual with an implementation chart. Apple's current guides document behaviour only, not bytes.
- **Cross-checks:** Ardour master `libs/surfaces/mackie` [ARD] (host side), the TouchMCU protocol doc [TMCU] (device side, reverse-engineered), and a real Logic 12.3 capture [CAP12].
- **About [CAP12]:** the capture is published as little-endian Universal MIDI Packet (UMP) words. I decoded it to MIDI 1.0 (161 frames) and the result is coherent.
- **Parts of [LC7] lost in the text conversion:** the V-Pot ring diagrams (p. 244), the 7-segment character table (p. 248), and the switch-vs-LED columns of the ID table (pp. 251–254). Those details below are grounded in [LC7]'s worked examples, [ARD], [TMCU] and [CAP12].

### A1. Buttons and LEDs

**Message format**
- **Surface → host:** Note On, channel 1. `90 id 7F` = pressed, `90 id 00` = released. Note-off is sent as velocity 00 [LC7 p.242, p.255].
- **Host → surface (LEDs):** the same message with the same ID. `90 id 7F` = on, `90 id 01` = flashing, `90 id 00` = off [LC7 p.242]. [TMCU] agrees.
- **Logic 12.3 at connect [CAP12]:** Logic sent `90 id 00|7F` for IDs 00–2D, 32, 33, 4A–51, 54–5F, 64, 65, 71, 72, 73. This is a practical list of the IDs Logic treats as having LEDs.
- **Current state in that capture:** 2A (Pan) on, 4A (Read/Off) on, 5D (Stop) on.

**Note-number table.** [LC7] pp. 251–254, [ARD] `device_info.cc` and [TMCU] agree on every ID.

| ID | Function | ID | Function |
|---|---|---|---|
| 00–07 | REC/RDY ch 1–8 | 4A–4E | Automation: Read/Off, Write, Trim, Touch, Latch |
| 08–0F | SOLO ch 1–8 | 4F | Group |
| 10–17 | MUTE ch 1–8 | 50–53 | Save, Undo, Cancel, Enter |
| 18–1F | SELECT ch 1–8 | 54 | Marker |
| 20–27 | V-Pot push (V-Select) ch 1–8 | 55 | Nudge |
| 28–2D | Assign: Track, Send, Pan/Surround, Plug-in, EQ, Instrument | 56–59 | Cycle, Drop, Replace, Click |
| 2E / 2F | Bank Left / Right | 5A | Solo (global) |
| 30 / 31 | Channel Left / Right | 5B–5F | Rewind, Fast Fwd, Stop, Play, Record |
| 32 | Flip | 60–63 | Cursor Up, Down, Left, Right |
| 33 | Global View | 64 / 65 | Zoom / Scrub |
| 34 | Name/Value | 66 / 67 | User Switch A / B |
| 35 | SMPTE/Beats | 68–6F | Fader touch ch 1–8 |
| 36–3D | F1–F8 | 70 | Fader touch master |
| 3E–45 | Global View: MIDI Tracks, Inputs, Audio Tracks, Audio Instrument, Aux, Busses, Outputs, User | 71 / 72 | SMPTE LED / BEATS LED |
| 46–49 | Shift, Option, Control, Cmd/Alt | 73 / 76 | Rude Solo LED / Relay click |

Logic's function for each button and modifier combination is in [CSS-TT], [CSS-FK], [CSS-UT] and [CSS-CK].
- **Rewind/FF:** shuttle in normal mode. With Marker held they go to the previous/next marker.
- **F1–F8:** recall screensets. With Marker held, Apple's guide contradicts itself:
  - the prose says they go to markers 1–8;
  - the function-key table says F1 = create a marker without rounding, F2 = create rounded, F3 = delete, F4–F8 = nothing.
  - See Disagreements.
- **Enter / Cancel:** press the default / Cancel button of an alert. [11.2-doc]

### A2. Faders

**Position: Pitch Bend, one MIDI channel per fader** [LC7 p.242] [ARD fader.cc] [TMCU]

| Message | Meaning |
|---|---|
| `E0`–`E7 ll hh` | Strips 1–8 |
| `E8 ll hh` | Master |

- Byte order is LSB first, then MSB. The value is `(hh<<7)|ll`, 0–16383.
- [ARD] writes `posi & 0x7f, posi >> 7` for the bytes and parses incoming values as `pb/16383`.
- [LC7]: real hardware transmits only the top 10 bits (1024 steps). The host may send the full 14 bits.

**Observed values**
- **[CAP12]:** at connect, Logic 12.3 sent `E0`–`E8 1B 61` (12443) for all nine, then `E9 00 00` (MIDI channel 10). The meaning of both is unestablished.
- **[OBS-11.2]:** sending touch-on, `PB 12000`, touch-off moved Logic's channel-1 fader. The LCD briefly showed Volume −1.2 dB, then restored the names. Logic did **not** echo the surface-originated move back as pitch bend. A mouse drag in Logic *did* produce pitch-bend feedback.
- **dB mapping:** the only observed anchor is 12000 → −1.2 dB [OBS-11.2]. The full value↔dB curve is unverified.

**Fader touch**
- Note On `90 68+n 7F` (touch) and `90 68+n 00` (release). Master is note `70` [LC7] [ARD] [TMCU].
- At connect Logic sends the configuration message `<Hdr> 0C 00` [CAP12] [OBS-11.2]. Per [LC7] p.241 this tells the device to transmit fader moves only while the fader is touched. It is an instruction to the **device**, not proof that the host enforces it.
- **Does Logic ignore bare pitch bend without a touch note? Unverified.** Nobody tested it. [OBS-11.2] always bracketed moves with touch notes.
- [FORUM, Logic 9]: users whose hardware touch sensing failed saw faders snap back. Enabling *Touchless movable faders* (Special parameters; that is the `0C 01` message) fixed it. This is consistent with touch mattering, but it does not isolate host behaviour.
- **Recommendation:** always send touch-on → pitch bend(s) → touch-off. Add a real-Logic test of bare pitch bend.

### A3. V-Pots

| Direction | Message | Encoding |
|---|---|---|
| Rotation, surface → host | `B0 1i vv`, i = 0–7 (CC 10–17) | `vv = 0 s n n n n n n`. s = 0 is clockwise, s = 1 is counter-clockwise. n = tick count. |
| LED ring, host → surface | `B0 3i xx` (CC 30–37) | `xx = 0 p m m v v v v`. p = centre LED. mm = mode 0–3. vvvv = 0 (all off) or 1–0B (position). |
| Push | Note `20`–`27` | Button format (A1) |

**Rotation examples** [LC7 p.243]
- `B0 10 01` = V-Pot 1, one tick clockwise.
- `B0 17 47` = V-Pot 8, seven ticks counter-clockwise.

[ARD] reads bit 6 as the sign and bits 0–5 as the tick count, and treats 0 as 1. [TMCU] agrees.

**Ring modes** [ARD pot.h] [TMCU]: 0 = dot, 1 = boost/cut, 2 = wrap, 3 = spread.
- Ardour computes the value as `lrintf(val*10)+1` (spread: `val*6`), sent on CC `0x20+0x10+i` = `0x30+i`.
- Example from [LC7]: `B0 31 06` = V-Pot 2, position 6.

**[CAP12]:** in Pan mode Logic 12.3 sent `B0 30..37 56`. That decodes to centre LED on, mode 1 (boost/cut), position 6, i.e. pan centred.

**Logic-side settings** [13]
- *Resolution of Relative Controls* (default 128 steps).
- *Relative Change Mode* (Coarse, Full, Fine).

### A4. LCD

**Message:** `<Hdr> 12 oo <ASCII…> F7` [LC7 p.246] [ARD] [TMCU] [CAP12]

**Header model byte**

| Byte | Device | Source |
|---|---|---|
| 14 | Mackie Control (Universal/Pro) | [ARD] [TMCU] [CAP12] |
| 15 | Mackie Control XT | [ARD] [TMCU] |
| 10 | Logic Control | [LC7] |
| 11 | Logic Control XT | [LC7] |

[LC7] notes that no device ID is needed, because each unit has its own MIDI port. Logic used `14` for a device installed as "Mackie Control" [CAP12].

**Offsets and layout** [LC7]
- `oo`: 00–37 is the upper line, 38–6F the lower line. Text wraps from the upper line to the lower one.
- The buffer is 2×56. Each strip has 7 characters (strip 8: 6). For scribble strips, use 6 characters plus a space.

**Example** [LC7]: `F0 00 00 66 10 12 00 48 65 6C 6C 6F F7` writes "Hello" at the top left.

**Real Logic 12.3 [CAP12]**
- One message at offset 00 carried **111 data bytes**: both lines, 56 + 55.
- Upper line: 6-character abbreviated names, each followed by a space. Lower line: `0` values (Pan mode).
- A parser must therefore accept long messages and arbitrary offsets. Maintain a 112-byte framebuffer.

**Character set:** ASCII. Logic converts 8-bit characters (curly quotes, umlauts) to the nearest 7-bit equivalents [CSS-DISP] [11.2-doc].

**Timing** [LC7]: the device ignores LCD writes for at least 600 ms after a meter-mode change (`21`).

### A5. Time code / BBT display and the Assignment display

**Messages** [LC7 p.247] [ARD] [TMCU] [CAP12]

| Display | Single character | Multiple characters |
|---|---|---|
| Time code (10 digits) | `B0 4i yy`, CC 40–49. 40 = rightmost digit, 49 = leftmost. | `<Hdr> 10 yy… F7`, up to 10 bytes. The first byte is the rightmost digit. |
| Assignment (2 characters) | `B0 4A yy` = right, `B0 4B yy` = left | `<Hdr> 11 yy yy F7` |

Both displays are written right to left [LC7]. [TMCU] notes some DAWs use channel 16 (`BF`); Logic used `B0` [CAP12].

**Character code** (6 bits, from the [LC7] worked examples and [ARD] `translate_seven_segment`)
- 00–1F = ASCII 40–5F (`@ A … Z [ \ ] ^ _`).
- 20–3F = ASCII 20–3F (space, punctuation, `0`–`9`).
- **+40 lights the decimal point.**

Examples [LC7]
- `B0 4B 10 4A 4E` writes "P", then "N" with its decimal point.
- The SysEx example `… 10 36 32 31 71 30 72 30 79 30 31 F7`, read right to left, displays "109.02.01.126".
- [CAP12]: Logic 12.3 sent `B0 4B 10`, `B0 4A 0E`, i.e. "PN" (Pan).

**Digit grouping**
- BBT: 3/2/2/3 = bars, beats, subdivision, ticks.
- SMPTE: hours, minutes, seconds, frames.
- Sources: [CSS-DISP] [11.2-doc] for the four fields, and an [ARD] comment citing "the Logic docs" for 888/88/88/888.
- Exactly how Logic pads and dots the digits is **unverified**. At connect Logic 12.3 sent `00` to all ten digits [CAP12]; the meaning of that is uninterpreted.

**SMPTE vs Beats mode**
- Shown by LED notes `71` (SMPTE) and `72` (BEATS) [LC7] [TMCU].
- Toggled by note `35` (SMPTE/BEATS) or V-Pot 8 in group-settings mode.
- The default comes from the group's *Clock Display* parameter [13] [11.2-doc].
- At connect, Logic 12.3 sent both `71` and `72` as `00` [CAP12]. Infer the mode from LED updates or the digit pattern only after testing.

### A6. Meters

**Level:** `D0 xx`, with `xx = 0 hhh llll` [LC7 p.249]
- hhh = strip 0–7.
- llll: 0–C = 0–100 %, E = set overload, F = clear overload.

**Configuration**
- `<Hdr> 20 ii mm F7`: per-channel mode, `mm = 00000 l p s` (LCD meter, peak hold, signal LED).
- `<Hdr> 21 yy F7`: 00 = horizontal, 01 = vertical.
- At connect Logic sends `21 01` and `20 ii 07` for ii = 0–7 [CAP12] [OBS-11.2 per SF23].

**Behaviour**
- The host sends peaks only. The device decays them at about 300 ms per division [LC7].
- An emulator that wants a "current level" must apply its own decay.
- Stereo channels send the maximum of left and right [LC7].

### A7. Handshake, identification, global commands

**Roles:** the **surface** issues the challenge. The host computes the response, and the surface verifies it [LC7 p.240].

| Direction | Message | Meaning |
|---|---|---|
| host → surface | `<Hdr> 00 F7` | Device Query |
| surface → host | `<Hdr> 01 s1…s7 c1…c4 F7` | Host Connection Query (18 bytes). Sent at power-up and in reply to a query. Serial = 7 ASCII bytes, not NUL-terminated. Challenge = 4 bytes. |
| host → surface | `<Hdr> 02 s1…s7 r1…r4 F7` | Host Connection Reply. [LC7] requires it within 300 ms. |
| surface → host | `<Hdr> 03 s1…s7 F7` | Confirmation; device goes online |
| surface → host | `<Hdr> 04 s1…s7 F7` | Error (wrong response) |
| host → surface | `<Hdr> 13 00 F7` | Firmware version request |
| surface → host | `<Hdr> 14 v1…v5 F7` | 5 ASCII bytes, e.g. "V1.0" (padding unverified) |
| host → surface | `<Hdr> 0F 7F F7` | Go offline |
| host → surface | `<Hdr> 61 F7` / `62 F7` / `63 F7` | Faders to minimum / all LEDs off / reset to offline |
| host → surface | `<Hdr> 0A tt`, `0B ll`, `0C mm`, `0E ii ss` | Transport click / backlight timeout (min) / touchless faders / touch sensitivity (ii 0–8, ss 0–5) |

**Response formula** [LC7 p.240], each result masked with 0x7F:
- `r1 = l1 + (l2 ^ 0x0A) - l4`
- `r2 = (l3 >> 4) ^ (l1 + l4)`
- `r3 = (l4 - (l3 << 2)) ^ (l1 | l2)`
- `r4 = l2 - l3 + (0xF0 ^ (l4 << 4))`

[TMCU] matches. Ardour's r2 differs (see Disagreements). As the emulated surface, you choose the challenge and may accept any response.

**What Logic actually sent [CAP12, Logic 12.3]**

The first RX frame equals the capturing server's own transmission, so it is not used. The unambiguous Logic traffic:
- **Configuration:** `21 01`, then `20 ii 07` interleaved with `D0 i0`, then `0A 01`, `0E 00..08 03`, `0C 00`, `0B 0F`. These are the factory defaults from [LC7].
- **State:** LCD `12`; timecode CC 49→40 = 00; assignment `4B 10`, `4A 0E`; LEDs; colour SysEx `72 02 02 02 02 02 02 02 02`; faders `E0..E8 1B 61`, `E9 00 00`; rings `B0 30..37 56`.
- **Probing:**
  - `<Hdr10> 00`, `<Hdr11> 00`, `<Hdr17> 00`, `<Hdr17> 13 00`.
  - Then `<Hdr14> 00` and `<Hdr14> 13 00`, then `<Hdr15> 00` and `<Hdr15> 13 00`.
  - The 14/15 pair was repeated three times, followed by another round of `0E`, and finally `E0 00 40` (uninterpreted).
- The capturing server never answered. Model `17` is not identified by any source.
- `72` is Behringer's X-Touch scribble-strip colour message: one byte per strip, bit0 = R, bit1 = G, bit2 = B [ARD `display_colors_on_xtouch`] [SF23]. Logic 10.8 added track colours on X-Touch LCDs [RN10.8].

**Must the surface answer?**
- [OBS-11.2]: with a manually installed surface, no handshake exchange took place (the issue does not say whether Logic sent a query). The surface still received full feedback, and its writes worked.
- [CAP12]/[ML736, 12.3]: also no replies. Feedback arrived, but no packets followed the server's own fader write. The authors suspect, but did not test, the missing handshake.
- **No source captured Logic sending `02`.** Whether Logic sends `02` (and expects `03`) is **unverified**, as is whether a reply enables auto-detection.
- **Recommendation (cheap):**
  1. Answer `<Hdr14> 00` with `01` + fixed serial + challenge.
  2. Answer `02` with `03` + serial.
  3. Answer `13 00` with `14` + five ASCII bytes.
  4. Ignore queries for other model IDs.
  5. For an XT, use `15` on a second port pair.
- Logic shows the serial number and firmware version in the Setup inspector [13 special/device params]. That is the likely use of these replies; this is an inference.

### A8. Jog wheel and external controller

- **Jog:** `B0 3C xx` with the same sign-magnitude encoding as the V-Pots. `B0 3C 01` = forward 1 tick, `B0 3C 41` = reverse 1 tick [LC7 p.245] [ARD jog.cc ID 0x3C] [TMCU].
- **External controller (foot pedal):** `B0 2E vv` [LC7].
- **Resolution per tick:** not documented.
  - [13] General settings: *Jog resolution depends on horizontal zoom*. When it is off, resolution is constant but the value is unstated.
  - Scrub (note 65) toggles scrub. Shift + Scrub gives shuttle [CSS-JOG].

---

## B. Logic Pro and Mackie Control

### B1. Adding the device (documented for Logic 13 [LP13-ADD])

1. Choose **Logic Pro > Control Surfaces > Setup**.
2. Choose **New > Install** and select the device. Then do one of:
   - **Scan** (preferred; Logic gathers more info, then installs and connects found devices), or
   - **Add**, then set the **Input Port / Output Port** pop-ups in Device parameters [LP13-DEV].
   - *New > Scan All* scans every type on every port.
   - *Logic Pro > Control Surfaces > Rebuild Defaults* reinitializes support.
3. Apple says a powered Mackie Control is auto-detected at launch [13] [11.2-doc].
   - [OBS-11.2]: a virtual port was **not** auto-detected; it was installed manually.
   - Whether a virtual surface answering `00` with `01` gets auto-installed or scanned is **unverified**.
4. **[OBS-12.3, ML-INST]**
   - The Install list row reads *Loud Technologies / Mackie — Mackie Control*. After Add, Module = *Logic Control*, Model = *Mackie Control*. [LP13-DEV] also says the Module/Model fields can show the internal module, e.g. "Logic Control".
   - The virtual endpoints must exist while you pick the ports.
   - *Rebuild Defaults* with the ports up wrote the port names into `~/Library/Preferences/com.apple.logic.pro.cs` but installed **no** device.
5. **Extenders (XT)**
   - Each unit needs its own MIDI in/out pair [LP13-REQ]. In MCU terms that is a second virtual port pair using model `15`.
   - Group units by dragging their icons into **one horizontal row** of the Setup window. Left-to-right order sets channel order, e.g. LC + XT = 16 channels: 1–8 and 9–16 [LP13-GRP].
   - Fader Bank Offset is assigned automatically from the faders to the left (e.g. 16 for a third unit) and can be edited [LP13-DEV].
   - Bank buttons move by the whole group width: MC + 2 XT = 24 [CSS-BANK].
   - Up to 20 groups are allowed [LP13-GRP].
6. **Settings that matter for a background MCP server** [13 general CS settings]
   - **Bypass all while in background:** when on, the surface is shared/bypassed while Logic is not the active app. The default is unverified; it should be off.
   - The **Bypass All Control Surfaces** command exists, and since 11.2.1 it fully bypasses Mackie devices [RN11].
   - *Touching fader selects track*, *Control surface follows track selection*, *Flash Mute and Solo*, *Multiple Controls per Parameter*.
   - Settings are stored in `~/Library/Preferences/com.apple.logic.pro.cs` [LP9-CS, OLD] [ML736 12.3: it contains "Mackie Control" and the port name for in and out].

### B2. State Logic sends back

All of the following was observed in [CAP12] (12.3) and/or [OBS-11.2], and is documented behaviourally in [11.2-doc]:
- LCD names and values
- Assignment display (two characters; trailing dot = Channel view)
- LEDs for mute/solo/rec/select, assignment, automation and transport
- Fader positions (pitch bend)
- V-Pot rings
- Time display
- Meter mode and levels
- Track colours (`72`)

**Track names**
- 6 characters plus a separator in each 7-character cell [CAP12] [LC7].
- Apple only says names are abbreviated [CSS-DISP].
- **No documented way to obtain full names over MCU.**

**Display-related options** [13 group "other" params] [CSS display buttons]
- *Track Name Format* = Name or No:Name (track number + name). It can also be set with group-settings V-Pot 5. The table entry for Option + Name/Value says it toggles name vs number:name, but the prose says Option or Cmd/Alt + Name/Value opens group-settings mode (see Disagreements).
- *Display Mode* (name/value) and Name/Value (note 34).
- Channel view puts the channel-strip name in the upper row. Its length is unverified.
- *Multiple Controls per Parameter* (1/2/4/8 encoders) widens **parameter** names and values only.
- Group mode shows the group name on the Time display (last 10 characters) [CSS-PDF].
- Large Marker mode shows marker names [CSS-LMM].
- Modal-dialog text appears on the LCD upper row and scrolls [LP13-MODAL].
- 11.2.1 fixed MCU track names not showing in new projects for TouchOSC [RN11].
- An XT adds 8 more strips, not longer names.

**Tempo:** I found no mention of tempo anywhere in Apple's Mackie Control chapter. I searched the full guide PDF text, and none of the protocol sources mention it either. **Tempo is not readable via MCU as far as documented.** Deriving it from the BBT display while playing would be an inference, untested.

### B3. Banking and paging [CSS-BANK] [CSS-CH] [11.2-doc]

**Button behaviour**
- **Bank Right/Left** moves 8 strips, or the group width.
- The last bank is right-aligned. In a 19-channel project the banks are 1–8 → 9–16 → 12–19, and Left from 12–19 returns to 9–16.
- **Channel Right/Left** moves 1 strip.
- **Option + Bank/Channel Left** jumps to the first set; **Option + Right** jumps to the last set.
- Views that show one strip type remember their last bank.

**Which track is in strip 1:** not transmitted. Options, all **unverified**:
- Set Track Name Format = No:Name and parse the number.
- Or home with Option + Bank Left and count steps.

**Caveats**
- *Channel Strip View Mode* = **Arrange** (the default for most devices) merges channels used by several tracks into one strip. **Tracks** view shows them individually. So strip index ≠ track index in general [LP13-DISP].
- [OBS-11.2]: in a 2-track project the LCD showed `Inst 1 | Inst 2 | St Out | Master`. Output and master strips follow the tracks, so blank cells do **not** mark the end of the list.

**Total track count:** no MCU message. Option + Bank Right followed by reading No:Name is a candidate, but unverified.

### B4. Port lifecycle

**Official [13]/[11.2-doc]**
- Ports are chosen by name in the Device-parameter pop-ups.
- 12.0: the Setup window now hides MIDI ports disabled in MIDI settings instead of listing them as *Invalid Port*.
- 12.4: adding a surface no longer changes the ports of other, unconnected devices [RN12].

**CoreMIDI [ADC]**
- Apple advises giving a virtual source/destination the **same unique ID** it had last time (`kMIDIPropertyUniqueID`), so other clients can keep persistent references.
- Setting it can fail on collision.

**Real-world**
- **[ML-INST, OBS-12.3, one host]:**
  - Test: kill all server processes so the endpoints vanish, then start a new server. MCU writes worked again without re-adding the surface.
  - The authors conclude that Logic re-binds **by name**.
  - **Caveat:** that project sets deterministic uniqueIDs, an FNV hash of the name, in code present since 2026-09-02 [ML-UID]. The test therefore cannot tell name matching from uniqueID matching.
  - Whether Logic was restarted in between is not stated. A hot re-appearance while Logic keeps running appears to be what was tested.
- **[FORUM, Logic 9.1.8]:** when a virtual port was absent at Logic **launch**, Logic warned that the device was assigned to a port that is not present, and the assignment reverted. The workaround was to restore the port and re-select it.
- **[ML-UID] code comment:** registration failures tracked **duplicate endpoint names**. Never run two processes that create the same names.

**Verdict and recommendation**
- Keep **both** the endpoint name and the uniqueID stable.
- Create the ports before Logic launches.
- Re-send state on reconnect.
- Re-binding is **unverified on 13.0**. Test both a hot re-appearance and a cold start without the ports.

### B5. Locating to bar N (all candidates pending a Logic-13 test)

| Mechanism | Takes bars directly? | Needs Logic focus? | Documented for 13? | Verification |
|---|---|---|---|---|
| **Go to Position dialog** | Yes | Keystroke path: yes. MIDI-learned path: unverified. | Partly; see below | BBT readback on MCU timecode |
| **MTC Full Frame** | No (SMPTE, needs tempo map) | Probably not; unverified | Yes; see below | BBT readback |
| **MMC Locate** | No | n/a | **No** | n/a |
| **Markers** | Only if pre-placed | No | Yes; see below | BBT readback |
| **Jog wheel (closed loop)** | Indirectly | No | Partly; see below | BBT readback |
| **Key commands Return then N−1 × "."** | Yes, by stepping | Yes (keystrokes) | Yes; see below | BBT readback |
| **SPP input** | n/a | n/a | No | n/a |
| **Nudge / Large Nudge** | n/a | n/a | n/a | Moves selected regions, not the playhead [CSS-NUDGE] |

**Go to Position dialog**
- The key command *Go to Position* = `/` [LP13-KC].
- Digits can be entered from the MCU: in modal dialogs F1–F8 = 1–8, MIDI Tracks (3E) = 9, Inputs (3F) = 0 [CSS-PDF FK].
- Enter (53) presses the default button in alerts [CSS-UT]. Dialog text appears on the LCD [LP13-MODAL].
- The `/` must come from a keystroke, or from a MIDI message learned to the key command from a second port [LP13-ASSIGN].
- Unverified: whether this dialog accepts the F-key digits, and its field format.

**MTC Full Frame**
- Message: `F0 7F 7F 01 01 hh mm ss ff F7`, where hh = `0rrhhhhh` [WIKI-MTC].
- Enable Project Settings > Synchronization > MIDI > **Listen to MIDI Machine Control (MMC) input**. Logic then honours MMC Play, Deferred Play and Stop, plus **Full Frame** messages, which set the playhead without playing [LP13-SYNC].
- Incoming MTC takes priority. This is a per-project setting.
- Converting bars to SMPTE needs the tempo map and the project start. Full Frame resolves to frames, so it generally cannot land exactly on a bar line.

**MMC Locate**
- Message: `F0 7F dev 06 44 06 01 hh mm ss ff sf F7` [ML-MMC code].
- **Not** in Apple's list of recognised MMC input commands, so unsupported as far as documented.
- [ML-0914, 12.3]: MMC play/stop had no effect, but the surface was unregistered and the Listen setting was unreported, so this is inconclusive.

**Markers**
- Marker held + F1–F8 goes to markers 1–8 per the prose, but Apple's own F-key table conflicts with that.
- Large Marker mode: V-Pots 1–5 jump to the first five markers. Marker + Rewind/FF: previous/next marker [CSS-MRK] [CSS-LMM].
- Key commands: Go to Marker Number 1–20 [LP13-KC].

**Jog wheel (closed loop)**
- `B0 3C` ticks while watching BBT. Resolution is undocumented; turn off zoom-dependence.
- Slow, with overshoot risk.

**Key commands: Go to Beginning, then Forward**
- Go to Beginning = Return. Forward = "." [LP13-KC].
- Apple says the control-bar Forward button moves one bar [LP13-TRANSPORT]. The key command is assumed to match (unverified).
- The **MCU** Rewind/FF buttons are shuttle, not bar steps [CSS-TT].

**SPP input**
- Logic 13 sync sources are Internal, Link, MTC, Manual and Auto Sync In. There is no MIDI-clock input, and SPP is documented only as transmitted [LP13-EXTSYNC] [LP13-SYNC].

**Ranking (pending test)**
1. Go to Position via `/` + F-key digits + Enter: takes bars directly, needs no tempo map, can be verified on BBT.
2. MTC Full Frame: focus-independent and documented for 13, but frame-quantized and needs the tempo map.
3. Closed-loop jog.
4. Markers, if they already exist.

Always confirm with the MCU BBT display.

### B6. Version-specific notes (Apple release notes)

| Version | Change |
|---|---|
| 10.7.2 | Display-mode changes retained in Logic Control mode. Moving the playhead by ticks no longer only moves backwards. |
| 10.7.8 | Hang on wake with a Mackie Control fixed. Multi-select from Mackie Control. |
| 10.8 | Track colours on X-Touch LCDs (the `72` message). Option + Select sets unity gain. Mackie LEDs update reliably when MIDI 2.0 is enabled. X-Touch functions work regardless of window focus. Settings moved to *Logic Pro > Settings*. |
| 11.2.1 | Bypass All fully bypasses Mackie devices. TouchOSC/MCU track names fixed in new projects. MCU Pro numeric displays no longer blank after the Controller Assignments window. Rotary encoders fixed. |
| 12.0 | Several Mackie custom-assignment fixes. Invalid Port listing removed. Large Nudge loop fix. |
| 12.2 | Control of mixer channels without tracks. Fader no longer jumps to master. |
| 12.3 | Mackie gets feedback for Sends on Faders. |
| 12.4 | Port assignments of unconnected devices are preserved. |
| 13.0 | No control-surface entries in the 13.0 release notes (searched). |

The Control Surfaces Support guide's selector stops at 11.2. The 13.0 User Guide covers setup and settings only.

---

## Disagreements between sources

1. **Challenge r2:** [LC7] uses `l3 >> 4`. Ardour master uses `l[2] >> l[3]`, shifting by l4 [ARD surface.cc `calculate_challenge_response`]. [TMCU] follows [LC7].
2. **Ardour commands not matching [LC7]:**
   - "reset" = `08 00` and "recalibrate faders" = `09 00` are not in [LC7].
   - "toggle backlight" uses `0A`, which [LC7] defines as transport click; [LC7]'s backlight command is `0B`.
3. **Meter maximum:** [LC7] gives 0–C. [ARD] scales to 0xD (13 segments), and [TMCU] lists D = 100 %.
4. **Line length:** [ARD] writes 55 characters per line, [LC7] says 2×56, and Logic 12.3 wrote 56 + 55 = 111 in one message.
5. **LCD message length:** the transcribed [LC7] page allows up to 100 data bytes per message. Logic 12.3 sent 111 and [TMCU] says up to 112.
6. **Fader-touch IDs:** an [ARD] `surface.cc` comment and check use 0xE0–0xE8, which are unreachable as note numbers. Its own `device_info.cc` uses 68–70, matching [LC7]/[TMCU].
7. **Unsupported "bare pitch bend" claim:** sharpfive's research doc says bare pitch bend works, but its own spike always sent touch notes.
8. **Apple's guide, Marker + F-keys:** the marker overview says F1–F8 go to markers 1–8. The function-key table gives create without rounding / create rounded / delete for F1–F3 and nothing for F4–F8 [CSS-PDF].
9. **Apple's guide, Option + Name/Value:** the prose says Option or Cmd/Alt opens group-settings mode. The display-buttons table says Option toggles name vs number:name, and only Cmd/Alt opens group settings [CSS-PDF].

## Open questions (test on Logic 13.0)

1. Does Logic send `02` after a `01` reply? Does replying enable auto-detection or scan, or fix the missing post-write feedback reported for 12.3?
2. Is bare pitch bend accepted without touch, and in which automation modes?
3. The value↔dB curve. The meaning of `E9`, model `17`, all-`00` timecode digits at connect, and white (`07`) in `72`.
4. Exact BBT/SMPTE digit layout, dots and padding. Whether the SMPTE/BEATS LEDs track the mode.
5. Jog resolution per tick.
6. Re-binding after hot re-appearance vs a cold launch, and whether matching is by name or uniqueID.
7. Whether the Go to Position dialog accepts MCU F-key digits. Whether Full Frame works in 13. The default of *Bypass all while in background*.
8. **CoreMIDI implementation note [ML736]:** a destination created with `MIDIDestinationCreateWithProtocol(._1_0)` delivers **UMP**. Channel voice arrives as 32-bit type-2 words; SysEx arrives as 64-bit type-3 packets of up to 6 bytes with start/continue/end status. These must be reassembled, not treated as a byte stream. In one project, reading the words' memory image as MIDI 1.0 bytes produced 8 garbled events from 161 packets, where a correct UMP read yields 112 channel messages.

## Sources

**Official (Apple/Emagic)**
- [LC7] Logic Control MIDI Implementation, Apple Logic 7 manual (manualsdir), pp. 239–255: https://www.manualsdir.com/manuals/547263/apple-logic-7.html?page=239 (also pages 240–249 and 251–255)
- [LP13-ADD] https://support.apple.com/guide/logicpro/add-a-control-surface-ctls718ddc0e/mac (13.0)
- [LP13-DEV] https://support.apple.com/guide/logicpro/ctls718dd91b/mac
- [LP13-DISP] https://support.apple.com/guide/logicpro/ctls718ddb55/mac
- [13 group "other" params] https://support.apple.com/guide/logicpro/ctls718ddfa8/mac
- [13 special params] https://support.apple.com/guide/logicpro/ctls718de3eb/mac
- [LP13-GRP] https://support.apple.com/guide/logicpro/ctls718ddd90/mac
- [LP13-REQ] https://support.apple.com/guide/logicpro/ctls718de679/mac
- [LP13-MODAL] https://support.apple.com/guide/logicpro/ctls718dd7ba/mac
- [13 general CS settings] https://support.apple.com/guide/logicpro/general-settings-lgcp1fe673ef/13.0/mac/27
- [LP13-SYNC] https://support.apple.com/guide/logicpro/midi-project-settings-lgcp72142361/mac
- [LP13-EXTSYNC] https://support.apple.com/guide/logicpro/external-synchronization-lgcpfff9377e/mac
- [LP13-MMC] https://support.apple.com/guide/logicpro/midi-machine-control-lgcpfff7af21/mac
- [LP13-KC] https://support.apple.com/guide/logicpro/lgcp02bf31b6/mac
- [LP13-TRANSPORT] https://support.apple.com/guide/logicpro/control-playback-with-the-transport-buttons-lgcp0b07c0c9/mac
- [LP13-ASSIGN] https://support.apple.com/guide/logicpro/assign-buttons-to-key-commands-ctls71c31056/mac
- [LP13 navigate using markers] https://support.apple.com/guide/logicpro/navigate-using-markers-lgcpa855b268/mac
- [CSS] Mackie Control overview: https://support.apple.com/guide/logicpro-css/mackie-control-overview-ctls7222820e/mac
- [CSS-DISP] https://support.apple.com/guide/logicpro-css/displays-overview-ctls72226f72/mac
- [CSS display buttons] https://support.apple.com/guide/logicpro-css/display-control-buttons-ctls72224fdb/mac and https://support.apple.com/guide/logicpro-css/display-buttons-table-ctls72225094/mac
- [CSS faders] https://support.apple.com/guide/logicpro-css/faders-ctls72224aae/mac
- [CSS-BANK] https://support.apple.com/guide/logicpro-css/bank-buttons-ctls72224042/mac
- [CSS-CH] https://support.apple.com/guide/logicpro-css/channel-buttons-ctls72227ddd/mac
- [CSS-JOG] https://support.apple.com/guide/logicpro-css/jogscrub-wheel-ctls72228ef7/mac and https://support.apple.com/guide/logicpro-css/jogscrub-wheel-assignments-table-ctls72224cd7/mac
- [CSS-MRK] https://support.apple.com/guide/logicpro-css/marker-button-overview-ctls722283e4/mac
- [CSS-LMM] https://support.apple.com/guide/logicpro-css/large-marker-mode-ctls72224e6a/mac
- [CSS-NUDGE] https://support.apple.com/guide/logicpro-css/nudge-button-overview-ctls72226245/mac
- [CSS-TT] https://support.apple.com/guide/logicpro-css/transport-buttons-table-ctls7222788e/mac
- [CSS-FK] https://support.apple.com/guide/logicpro-css/assign-function-keys-table-ctls72227e31/mac
- [CSS-UT] https://support.apple.com/guide/logicpro-css/utilities-buttons-table-ctls72227fb2/mac
- [CSS-CK] https://support.apple.com/guide/logicpro-css/cursor-keys-table-ctls72224335/mac
- [CSS channel view] https://support.apple.com/guide/logicpro-css/channel-view-ctls722257eb/mac
- [CSS-PDF] https://help.apple.com/pdf/logicpro-css/en_US/logic-pro-control-surfaces-support-guide.pdf and the identical copy linked from the 13.0 User Guide, https://help.apple.com/pdf/logicpromac-css/en_US/logic-pro-mac-control-surfaces-support-guide.pdf (© 2025, created May 2025, 220 pages)
- [LP9-CS] https://help.apple.com/logicpro/mac/9.1.6/en/logicpro/controlsurfacessupport/chapter_1_section_5.html
- [RN] Release notes:
  - 13.0: https://support.apple.com/en-us/109503
  - 12 [RN12]: https://support.apple.com/en-us/149604
  - 11 [RN11]: https://support.apple.com/en-us/126835
  - 10.8 [RN10.8]: https://support.apple.com/120134
  - 10.7: https://support.apple.com/106014
- [ADC] CoreMIDI:
  - https://developer.apple.com/documentation/coremidi/midisourcecreatewithprotocol(_:_:_:_:)
  - https://developer.apple.com/documentation/coremidi/mididestinationcreatewithprotocol(_:_:_:_:_:)

**Open source / observations**
- [ARD] https://github.com/Ardour/ardour/tree/master/libs/surfaces/mackie (`surface.cc`, `device_info.cc`, `fader.cc`, `pot.cc`, `pot.h`, `meter.cc`, `jog.cc`, `mackie_control_protocol.cc`)
- [TMCU] https://github.com/NicoG60/TouchMCU/blob/main/doc/mackie_control_protocol.md
- [CAP12] https://github.com/MongLong0214/logic-pro-mcp/blob/main/docs/observations/evidence/2026-09-08-mcu-feedback-trace-en.json
- [ML736] https://github.com/MongLong0214/logic-pro-mcp/blob/main/docs/observations/2026-09-08-mcu-feedback-is-decoded-as-if-it-were-midi-1.json and https://github.com/MongLong0214/logic-pro-mcp/blob/main/docs/tickets/issue-736-mcu-ump-decode/STATUS.md
- [ML-INST] https://github.com/MongLong0214/logic-pro-mcp/blob/main/docs/observations/2026-09-15-the-setup-windows-own-menu-installs-the-surface.json
- [ML-UID] https://github.com/MongLong0214/logic-pro-mcp/blob/main/Sources/LogicProMCP/MIDI/VirtualMIDIEndpointIdentity.swift
- [ML-MMC] https://github.com/MongLong0214/logic-pro-mcp/blob/main/Sources/LogicProMCP/MIDI/MMCCommands.swift
- [ML-0914] https://github.com/MongLong0214/logic-pro-mcp/blob/main/docs/observations/2026-09-14-the-control-surface-channels-are-not-set-up-so-six-operations-send-into-nothing.json
- [ML-SETUP] https://github.com/MongLong0214/logic-pro-mcp/blob/main/docs/SETUP.md
- [OBS-11.2] https://github.com/ambiguouscherry/sharpfive/issues/5
- [SF23] https://github.com/ambiguouscherry/sharpfive/issues/23 and https://github.com/ambiguouscherry/sharpfive/blob/main/research/logic-mcu-sysex-extensions.md
- sharpfive research doc (secondary): https://github.com/ambiguouscherry/sharpfive/blob/main/research/mcu-protocol.md
- [WIKI-MTC] https://en.wikipedia.org/wiki/MIDI_timecode

**Forums**
- https://discussions.apple.com/thread/4618552 (Logic 9.1.8: missing virtual port)
- https://discussions.apple.com/thread/2742976 (MCU fader moves ignored; touchless faders fix)
- https://logic-users-group.com/threads/lp9-mackie-control-issues.1384/
- https://forum.midibox.org/t/lc-initialization/596 (2003, MIDIbox LC emulator: answers 00 with 01 + dummy serial/challenge, 02 with 03, 13 with 14 "V1.42"; the author says dummy challenge bytes suffice with Logic. Old forum source.)
