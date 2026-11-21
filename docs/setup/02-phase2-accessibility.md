# Phase 2 setup: Accessibility permission (reading full track names)

The LCD of the emulated Mackie Control surface shows only **6 ASCII characters** per track, and Japanese and Chinese characters are simply dropped (`オーディオ 1`, the Japanese UI's default name for "Audio 1", shows as just `1` on the LCD). So that Claude can see full track names, the server uses **read-only Accessibility** to read the names from the track headers in Logic's main window (design.md §7 question 2 chose (b)).

This step is **optional**: without the permission, reading and setting the mixer work as usual; only the track names fall back to the LCD abbreviations, and the result's `warnings` say so.

Menu names are those of the English macOS UI. The steps were run on macOS 27 with the Japanese UI, so these names have not been checked on an English-UI macOS yet.

---

## 1. What the server does and does not do with Accessibility

- **Read-only**: it only reads the contents and positions of the text fields in the main window of the process with bundle ID `com.apple.logic10` (Logic Pro), to get the track names.
- **No actions**: it does not click, type or change any UI state, and it does not read other apps. The code is all in `Sources/LogicAX/LogicAX.swift`, so it is easy to review.
- No permission dialog appears: without the permission the server simply cannot read, and its result tells you to follow this document.

## 2. Which app to authorise

macOS grants the Accessibility permission to **the app that launches the server** (the server is its child process), and it grants it to **the whole app**, not just this server:

| How you use Claude | App to authorise |
|---|---|
| Claude desktop app (Code tab) | **Claude** (`/Applications/Claude.app`) |
| `claude` run in Terminal | **Terminal** (`/System/Applications/Utilities/Terminal.app`) |
| `claude` run in iTerm or another terminal | That terminal app |

> Once authorised, any program running in that app can use Accessibility. If that concerns you, turn it on only when you need full track names and turn it off again afterwards.

## 3. Authorisation steps

1. Open **System Settings > Privacy & Security > Accessibility**.
2. If the app to authorise (the table in section 2) is already in the list, turn on the switch to its right.
3. If it is not, click **+** below the list, enter your Mac login password, select the app (for example `/Applications/Claude.app`), click **Open**, and check that the switch is on.
4. **Quit the app completely and reopen it** (quit the Claude desktop app with ⌘Q; for a terminal, close the window and run `claude` again). The permission applies only to processes started after that; the server restarts along with the app.

## 4. Making every track name readable

- Logic Pro must be running, with the project's **main window** open.
- Accessibility can only read **track headers shown on screen**: tracks scrolled out of the window may not be read. With many tracks, enlarge the main window or reduce the track height (for example with the vertical zoom slider at the top right of the Tracks area) so that all track headers are visible. When fewer names are read than there are tracks, the server uses them only where their position can be matched unambiguously; the other tracks use the LCD abbreviation, and `warnings` says so.
- The server cross-checks each name: the full name with non-ASCII characters removed and leading/trailing spaces trimmed, cut to its first 6 characters, must equal the LCD abbreviation; otherwise the name is not used (and is listed in `warnings`). Whether real Logic drops accented letters (`é`) and curly quotes (`‘ ’`) or turns them into `e` and `'` is not yet confirmed (checklist C4, C6), so the server accepts both forms.

## 5. Check

Ask Claude to call `get_session_state` with `tracks` in `include` (or type `tracks` in the console; the console and the server cannot run at the same time):

- Permission granted: each track's `name_source` is `"accessibility"`, `name` is the full name (for example `オーディオ 1`), and `lcd_name` is the LCD abbreviation (`1`).
- No permission: `name_source` is `"lcd"`, and `warnings` contains "Full track names unavailable (this process is not allowed to use Accessibility …)".
- Logic not running: `warnings` contains "Logic Pro (com.apple.logic10) is not running".

## 6. What happens without the permission

| Feature | Effect |
|---|---|
| Track list of `get_session_state` | Works as usual; `name` is the LCD abbreviation (at most 6 ASCII characters; a name entirely in Japanese shows as empty) |
| `mixer_set` | Works as usual; `expected_name` can only be checked against the LCD abbreviation (the result notes "only against the LCD abbreviation"). A name made only of Japanese or other non-ASCII characters (for example `ボーカル`, "Vocal") is blank on the LCD and cannot be checked, so a call with such an `expected_name` returns `failed` immediately and changes nothing |
| Other tools | Not affected |

To revoke the permission: go back to the list in step 3 and turn the switch off.
