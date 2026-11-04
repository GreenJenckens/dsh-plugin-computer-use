---
name: computer-use
description: Drive the Windows desktop like a person - list and activate windows, read the UI Automation tree, click real controls, type text, send hotkeys and capture screenshots - when a task needs a GUI application or a website that has no API, CLI, or file path.
whenToUse: The task requires operating a Windows GUI application or browser UI (clicking buttons and menus, filling forms, reading on-screen state, taking a screenshot) instead of files, shell commands, or HTTP.
---

# Computer use (Windows desktop)

This skill gives you eyes and hands on the local Windows desktop through PowerShell and UI Automation. It needs no Python, no extra packages: every script is plain Windows PowerShell 5.1 that ships with the OS.

Resolve `<base>` below to the **Base directory** reported when this skill was loaded. Do not guess it.

## Golden rules

1. **Observe before acting.** `windows.ps1 -Action list` to find the target window, then `uia.ps1 -Action tree` to see its controls. Never click blind coordinates you have not seen in a screenshot or element rectangle.
2. **Prefer semantics over pixels.** `uia.ps1 -Action invoke/setvalue/toggle/select` beats a synthetic click; a click on an element from the tree beats raw coordinates.
3. **One action per call, then verify.** After every action re-read the tree, `getvalue`/`gettext`, or a fresh screenshot. Do not chain several unverified guesses.
4. **Pass `-Title` or `-Hwnd` to click/type calls.** The scripts then activate the window, verify it really is in the foreground, and refuse to send a blind click or keystroke into whatever happens to be on top. If a call errors with `could not bring ... to the foreground`, stop and report instead of retrying coordinates.
5. **Screenshots are physical pixels.** The capture reports `sourceWidth/Height`, `scale`, `sourceX/Y`. To click a point seen on an image: `screenX = sourceX + imageX / scale`, `screenY = sourceY + imageY / scale`.
6. **Ambiguity is a stop sign.** If a selector matches several elements the script returns `code: "ambiguous"` with matches; refine with `-ControlType`, exact `-Name`, `-AutomationId`, or `-MatchIndex`. Never assume the first match is the intended one.
7. **Safety.** Never type passwords, payment data, or one-time codes. Do not send messages, buy, delete, or publish without explicit user confirmation. On a real desktop the user sees every action; keep steps short, explain what you are doing, and prefer reversible actions.
8. **No UAC/secure-desktop control.** Elevated apps, UAC prompts and the lock screen are out of reach unless the harness itself runs elevated. Say so instead of retrying.

## The scripts

All scripts print one line of JSON on stdout: `{"ok":true,...}` on success or `{"ok":false,"code":"...","error":"..."}` on failure. Exit code 1 means failure. Always run them through `powershell.exe` with `-NoProfile -ExecutionPolicy Bypass`:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "<base>\scripts\windows.ps1" -Action list
```

### windows.ps1 — top-level windows

| Action | What it does |
|---|---|
| `list` | Top-level windows, foreground first: `hwnd`, `pid`, `process`, `title`, `class`, `x/y/width/height`, `foreground`, `minimized`; plus monitors |
| `info` | Details for one window (selector below) |
| `activate` | Restore + bring to foreground (returns `foreground:true` when it worked) |
| `minimize` / `maximize` / `restore` / `close` | Window state; `close` posts WM_CLOSE (the app may show a save prompt - handle it via `uia.ps1`) |
| `move` | `-X -Y` and optional `-Width -Height` |

Selectors shared by all scripts: `-Hwnd <number>`, `-Title <substring>`, `-TitleRegex <regex>`, `-ProcessId <pid>`. Prefer the exact `hwnd` from `list` whenever two windows look alike.

### uia.ps1 — UI Automation tree and semantic actions

`-Action tree` returns the control tree of a window (foreground by default): `i` index, `role`, `name`, `id`, `class`, `enabled`, `offscreen`, `focus`, `x/y/w/h`, and when available `actions` (`invoke`, `setvalue`, `toggle`, `select`, `expand`, `scroll`, `text`), `value`, `checked`, `selected`, `text` preview.

Caps and filters: `-MaxDepth` (default 10), `-MaxNodes` (default 200; raise to 400 for dialogs), `-All` (raw tree, includes unnamed text nodes), `-NoPatterns` (faster, no pattern probing), and output filters `-Name/-NameRegex/-AutomationId/-ControlType` (when any filter is set the tree returns only matching elements).

| Action | Needs | Notes |
|---|---|---|
| `tree` | — | The main observation call |
| `info` | selector | All elements with properties |
| `invoke` | selector | Best for buttons, menu items, hyperlinks |
| `click` / `doubleclick` / `rightclick` | selector | Activates the window, then clicks the element centre; use when there is no invoke pattern |
| `setvalue` | selector + `-Value` | For Edit/ComboBox/Document fields with a value pattern |
| `getvalue` | selector | Reads the value pattern |
| `gettext` | selector, optional `-Value <maxChars>` | TextPattern, or select-all + copy fallback (restores the clipboard) |
| `toggle` / `select` / `expand` / `collapse` / `focus` | selector | Checkboxes, tabs, menu items |
| `scroll` | selector, `-Value <wheelDelta>` | Wheel over the element centre (default -600 = down) |

`-MatchIndex N` picks the Nth match after refinement. Elements are matched with AND semantics across the selectors you pass.

### input.ps1 — raw mouse and keyboard

| Action | Parameters |
|---|---|
| `click` / `doubleclick` / `rightclick` / `middleclick` | `-X -Y` (physical pixels), optional `-Clicks` |
| `move` | `-X -Y` |
| `drag` | `-X -Y` start, `-X2 -Y2` end |
| `scroll` | `-X -Y`, `-Delta` (negative = down) |
| `type` | `-Text` — layout-independent Unicode typing, `\n` becomes ENTER |
| `key` | `-Key ENTER\|TAB\|ESC\|F5\|DOWN\|DELETE\|...` |
| `hotkey` | `-Hotkey "ctrl+shift+s"`, `"alt+tab"`, `"win+r"` |
| `paste` | `-Text` — clipboard + Ctrl+V, best for long text |
| `wait` | `-Ms` |
| `cursor` | Reports the cursor position and foreground window title |

Pass `-Title`/`-Hwnd` to make the script activate that window first (recommended). `-NoActivate` skips that when you intentionally work with whatever is foreground.

### screen.ps1 — screenshots

```powershell
# whole primary monitor, downscaled to 1600 px wide, PNG path in the result
powershell.exe ... -File "<base>\scripts\screen.ps1"
# one window, activating it first
powershell.exe ... -File "<base>\scripts\screen.ps1" -Title "Calculator" -MaxWidth 1200
# a rectangle, or another monitor
... -Region "0,0,800,600"     ... -Monitor 1     ... -ListMonitors
```

Returns `path`, `width/height` (saved image), `sourceWidth/Height`, `scale`, `sourceX/Y`, `label`, `cursor`. Load the saved PNG with the image-reading tool to see the screen. Prefer the text tree for reading labels and exact bounds; use screenshots for visual state, layout, canvas, or when accessibility exposes nothing useful.

## Recommended loop

```
1. windows.ps1 -Action list                      # where is the app? get hwnd
2. uia.ps1 -Action tree -Hwnd <hwnd> -MaxNodes 120
3. pick ONE element (prefer actions: invoke/setvalue)
4. uia.ps1 -Action invoke -Hwnd <hwnd> -Name "Save" -ControlType Button
5. verify: uia.ps1 -Action tree / gettext / screen.ps1 + imagen
6. repeat; open a new window or menu -> go back to step 2
```

For visual tasks (games, canvas apps, PDFs, ambiguous layout) skip the tree and use `screen.ps1` + coordinates from the image, then verify with another screenshot.

## Worked example: type into Notepad

```powershell
$ps = "powershell.exe"; $b = "<base>\scripts"
Start-Process notepad.exe; Start-Sleep -Seconds 2
& $ps -NoProfile -ExecutionPolicy Bypass -File "$b\windows.ps1" -Action list -Limit 8
& $ps -NoProfile -ExecutionPolicy Bypass -File "$b\uia.ps1" -Action tree -Title "Блокнот" -MaxNodes 40
& $ps -NoProfile -ExecutionPolicy Bypass -File "$b\uia.ps1" -Action click -Title "Блокнот" -ControlType Document
& $ps -NoProfile -ExecutionPolicy Bypass -File "$b\input.ps1" -Action type -Title "Блокнот" -Text "Привет`nline two"
& $ps -NoProfile -ExecutionPolicy Bypass -File "$b\uia.ps1" -Action gettext -Title "Блокнот" -ControlType Document
```

If the app shows a confirmation dialog after WM_CLOSE, read it with `uia.ps1 -Action tree` and act on the dialog buttons (they are normal elements in the same window; `invoke` may not be implemented, so use `-Action click` with `-Name ... -ControlType Button`).

## Limits and failure modes

- **Accessibility quality varies.** Win32/WPF/UWP/WinUI apps expose rich trees; Chromium/Electron apps expose their own tree but sometimes need `--force-renderer-accessibility`; games and custom canvases expose almost nothing - fall back to screenshots.
- **Tree is capped.** `truncated:true` means some elements were not returned; narrow the window, raise `-MaxNodes`, or filter with `-ControlType`.
- **Some controls lack patterns.** A `Button` without `invoke` (common in WinUI dialogs) still works via `-Action click`.
- **Foreground stealing.** The harness window may take focus back between tool calls; that is why every click/type call activates its target and checks the foreground first.
- **Clipboard fallback for text** selects all text in the control; do not use it in apps where Select All is destructive.
