# Security notes — dsh-plugin-computer-use v0.5

This plugin lets an LLM drive the real Windows desktop: click, type, start
processes, read UI Automation trees and capture screenshots/OCR. Treat it as a
high-privilege capability, not as a security boundary.

## What the plugin enforces

| Control | Behaviour |
|---|---|
| Runtime mode | `mode: "auto" | "readonly" | "disabled"` is config-only and checked before the host is contacted. `readonly` permits only observation (window list/info, `observe.*`, screenshot, OCR, diagnostics, cursor/wait); `disabled` rejects every call. The model cannot change the mode through tool arguments. |
| Subagent default-deny | `ctx.tools.guard` and the `execute` fallback deny `computer` to sessions with `delegationDepth >= 1` or `origin: "subagent"` before the host is contacted. Denial is fixed text + a `denied.jsonl` record; tool arguments are never logged. Opt-in: `subagents: "allow"`. |
| Consequential confirmation | By default `input.type/paste/key/hotkey` into a console/interpreter window, writes into `IsPassword` fields, and clicks on keyword-matched buttons (`оплат`, `купить`, `оформить`, `удалить`, `send`, `pay`, ...) ask the human through the overlay dialog. `confirm: "never"` is an explicit full-access opt-in; without the indicator the same actions are denied. |
| Activity indicator / cancel | A click-through blue/cyan edge glow, cursor ring and top banner show while the tool is active; `Ctrl+Alt+Shift+Q` pauses/resumes and the bridge rejects operations while paused. Overlay/dialog windows are `WS_EX_TRANSPARENT | NOACTIVATE | TOOLWINDOW`, titled `DSH-CU-*`, filtered from `windows.list`, and rejected as targets. |
| Password read redaction | `IsPassword` or `ES_PASSWORD` on the element's native handle; `Name`, `Value`, `Text` and action descriptions become `[password redacted]`. `gettext` refuses password fields even with `clipboard=true`. Verified on WinForms and Edge 156; Chromium page fields also mask value/text themselves. Custom `-webkit-text-security` widgets are **not** protected. |
| Clipboard fallback | Off by default. `clipboard=true` compares the buffer before/after and restores it in `finally`; console windows are refused. `input.paste` also restores the previous clipboard in `finally`. |
| Blind input | `input.*` activates and checks the target window when `hwnd`/`title` is given; `act.click`/`scroll` refuse when the window cannot be foregrounded. |
| Screenshot path | A caller-supplied screenshot `path` must resolve inside the plugin temp dir; arbitrary file writes outside it are refused. |
| Stale capture fence | `screenshot`/`ocr` accept `expectedWindow`; when set, capture is refused if the current foreground hwnd differs, so a stale observation cannot be mistaken for the live screen. |
| Launch policy | Denies interpreter/shell binaries (`cmd`, `powershell`, `pwsh`, `wscript`, `cscript`, `mshta`, `regsvr32`, `rundll32`, `certutil`, `bitsadmin`, `msiexec`, `wmic`, `schtasks`, `reg`), UNC paths and URL schemes other than `http(s)`/`mailto`. |
| Ambiguity | A selector matching several elements fails with the candidates; `matchIndex` out of range is an error, not a silent clamp. |
| Bounds | Tree/text/input/OCR limits are clamped; regexes have a 200 ms timeout and a 200-character limit; `ocrScale <= 3` and is further clamped under the Windows OCR 10 000 px limit; capture rectangles are validated against the virtual screen. |
| Audit | `%TEMP%\dsh-cu\audit.jsonl` receives `windows.*`, `observe.*`, `act.*`, `input.*`, `screenshot`, `ocr`, `launch` and failures (5 MB rotation). Typed text is logged as a character count only. `denied.jsonl` records subagent denials. |
| Capture hygiene | Screenshot/OCR files older than 2 h are purged, at most 150 PNGs are kept by default; both are configurable (`retentionHours`, `maxFiles`) and enforced at host start as well as on capture. The attachment prune is operator-only and fails closed when a zstd session cannot be read. |
| Diagnostics | `diagnostics` reports PowerShell/UIA/OCR/monitors/temp/indicator/mode only; it does not dump window titles, screenshots or typed text. |

## What it cannot enforce

- **Human confirmation is on-desktop, not a hardened approval channel.** The
  dialog is a real human action, but the agent runs on the same desktop and a
  blind click at dialog coordinates is not technically impossible; the dialog is
  filtered from selectors, not from pixels. The OS/DSH approval policy remains
  the stronger boundary. Full takeover (hand the mouse to the human and back) is
  not implemented; `Ctrl+Alt+Shift+Q` only pauses/resumes the agent.
- **OS-level isolation.** The PowerShell host runs outside the DSH workspace
  sandbox. A workspace-write/read-only session still has full desktop access;
  a child with `pwsh`/`read_image` can reach the desktop and stored screenshots
  without this tool. Only enable the plugin for sessions allowed to control the
  desktop; use a dedicated low-privilege user or VM for untrusted work.
- **Prompt injection.** UI text, OCR output and clipboard content are untrusted
  input. A malicious page can instruct the model to click or type; there is no
  technical barrier beyond the controls above and the user watching the desktop.
- **Screenshot/OCR content.** Reading is redacted only for `IsPassword` fields;
  anything visible on the screen (including a revealed password) is captured.
  `%TEMP%\dsh-cu` and the DSH attachment store keep copies. OCR is not a
  redaction layer.
- **Attachment-store retention.** DSH stores attachments under
  `~/.dsh/attachments/v1/objects` and never deletes them automatically; referenced
  objects are shared by resumed/forked sessions. The plugin does not auto-GC
  them. `scripts/prune-attachments.ps1` is an operator tool: dry-run by default,
  scans zstd sessions for `sha256:` references, requires an age threshold and a
  path guard, and refuses to delete when sessions exist but no refs were found.
- **Audit integrity.** `audit.jsonl`/`denied.jsonl` live in `%TEMP%` and the
  agent has shell access; they are best-effort diagnostics, not tamper-evident
  logging.
- **Elevation.** UAC prompts, the lock screen and elevated applications are out
  of reach; a non-elevated host cannot read them. UIPI can also make input to an
  elevated window a silent no-op.
- **Mixed-DPI hardware.** `MOUSEEVENTF_VIRTUALDESK`, per-monitor DPI reporting and
  the mapping self-test are implemented; 2 monitors, 125%/150% and mixed-DPI
  Windows behaviour are **not validated on this machine**.

## Recommended deployment

1. Run in a dedicated Windows VM or a separate low-privilege user.
2. Keep the profile at `danger-full-access` only for sessions that genuinely
   need desktop control; disable the plugin elsewhere.
3. Keep `subagents: deny` unless a child explicitly needs desktop control; add
   the composition `toolFilter: { deny: ['computer'] }` as a second layer.
4. Keep `confirm: "consequential"` for real work; do not type passwords, payment
   data or one-time codes. The plugin redacts reading, not what the model knows.
5. Treat screenshots and OCR text as potentially sensitive; prune
   `%TEMP%\dsh-cu` and the DSH attachment store according to your policy.
6. Accept that v0.4 has no interactive human takeover; for high-risk actions
   require a human at the desktop or a stricter composition.

## Reporting

Open an issue in the plugin repository (or the workspace copy) with the exact
action, target, and the `audit.jsonl` line; do not attach screenshots of secrets.
