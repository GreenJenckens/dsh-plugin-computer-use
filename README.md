# computer-use для DeepSeek Harness (Windows)

Управление рабочим столом Windows для агента DSH: окна, UI Automation, клики и
ввод, скриншоты, OCR, запуск приложений. Основной вариант — **нативный плагин
v0.6.0** с одним тулом-диспетчером `computer` и тёплым PowerShell-хостом; рядом
лежит исходный **скилл** как fallback и референс.

## Почему плагин, а не скилл

| | Скилл | Плагин |
|---|---|---|
| Инструкции | тело `SKILL.md` 9.4 КБ ≈ 2.4k токенов при каждом использовании | нет тела: правила в описании тула |
| Схема инструмента | — | один тул: **≈3.2 КБ ≈790 токенов** compact (44 actions/48 params) |
| Дерево | сырой JSON | компактные строки: 1037 против 3465 символов (×3.3) |
| Задержка | новый PowerShell на вызов | тёплый хост: tree ~0.2 с, screenshot ~0.3 с, cursor ~0.004 с |
| Скриншот | путь + `read_image` | PNG в блоке результата; `capture:print` для фоновых окон |
| Установка | `~/.dsh/skills` | bundle в профиле + `build.json` и `-Verify` |

## Состав

```
plugin/dsh-plugin-computer-use/     ← нативный плагин
  package.json, cordis.patch.yml
  lib/index.js                      тул computer, гейты, act.sequence, image-block
  lib/bridge.js                     хост: очередь, JSON-lines, signal/таймаут, retention
  lib/scripts/bridge.ps1            окна, UIA, ввод, скриншоты, OCR, запуск, -SelfTest
  lib/scripts/CuCommon.ps1          DPI, Win32 P/Invoke, VIRTUALDESK, ES_PASSWORD
  lib/scripts/collect-attachment-refs.mjs  zstd-aware refs для prune
  test/                             55 node --test кейса + OCR-датасет 12×3
  README.md, CHANGELOG.md, SECURITY.md
plugin/smoke.mjs                    E2E с assert (калькулятор 7×8=56)
scripts/                            prune, make-ocr-fixtures, ocr-eval, ci, build/pack
install-plugin.ps1                  установка + -Verify (build.json/SHA-256)
```

## Что нового в 0.6.0

- **Режимы** `auto / readonly / disabled` — только в конфиге; readonly оставляет
  наблюдение, disabled отклоняет всё.
- **`observe.wait`** — ждать окно/заголовок/element до 60 с без side effects.
- **`diagnostics`** — самопроверка PowerShell/UIA/OCR/мониторов/temp/индикатора.
- **`expectedWindow`** — забор против устаревшего скриншота: отказ, если
  foreground-hwnd изменился.
- **Стабильные ref** из `observe.tree` — повторная проверка элемента на каждом
  действии, `stale ref` вместо клика по случайному месту.
- **CDP-браузер** — `browser.list` / `browser.eval` через loopback `cdpPort`.
- **Новый takeover-pill** — синяя градиентная плашка с кнопкой
  Остановить/Продолжить, тонкая кромка и аккуратное кольцо курсора.
- **55 тестов**; новые кейсы на режимы, wait, diagnostics, refs/stale,
  CDP list и fence.

### Ранее, в 0.4.x

- **`act.sequence`** — до 8 действий за один вызов, стоп на первой ошибке.
- **Least privilege субагентов** — default deny через `ctx.tools.guard`, audit
  `denied.jsonl`, opt-in `subagents:"allow"`.
- **Индикатор активности** — синяя/циан кромка, кольцо курсора и баннер
  «DeepSeek Harness использует ПК»; `Ctrl+Alt+Shift+Q` — пауза/продолжение.
- **Human confirm** — class-C действия показывают диалог «Разрешить/Запретить»
  (30 с, Esc — отказ); `confirm:"never"` — полный доступ. Полного takeover
  (передачи мыши человеку) нет — документированный разрыв.
- **Multi-monitor/DPI** — `MOUSEEVENTF_VIRTUALDESK`, per-monitor `dpi/scale` в
  `windows.list`, `-SelfTest` математики (negative origin, 125/150% layouts).
- **Chromium-пароли** — регресс Edge 156: `IsPassword` + маскирование, 0 утечек.
- **OCR** — clamp под лимит 10 000 px, датасет и CER/WER, 0→D исследован.
- **Retention** — настраиваемый TTL/лимит PNG, `prune-attachments.ps1` с dry-run
  и zstd-aware ссылками; attachment-store DSH сам не чистится.
- **CI/упаковка** — git baseline, `scripts/ci.ps1`, hosted/self-hosted lanes,
  `build.json` в `npm pack`, `-Verify` проверяет hash/version.

## Требования

- Windows 10/11, Windows PowerShell 5.1 (Desktop), интерактивный рабочий стол.
- Установленный DeepSeek Harness с профилем `desktop`; для установки — `pnpm`.
- Node.js ≥ 22 для тестов и `scripts/*.mjs`; Edge/Chromium — для P3-регресса.

## Установка и проверка

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "install-plugin.ps1"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "install-plugin.ps1" -Verify
cd plugin\dsh-plugin-computer-use; npm test; npm run smoke
npm run build:json; npm run pack:check; npm run matrix
```

`-Verify` сравнивает дерево исходника и установленной копии, проверяет
`build.json` и выходит с кодом 1 при расхождении. Смонтированный экземпляр
пишет `%TEMP%\dsh-cu\mounted-<pid>.json`; generic `mounted.json` — только
Electron.

## Проверено

| Проверка | Результат |
|---|---|
| `npm test` | **55/55 pass** (lifecycle, timeout/abort, security, marker, Chromium, confirm, DPI, retention, prune, OCR, sequence, modes, wait, diagnostics, refs/stale, CDP, fence, schema) |
| `npm run smoke` | калькулятор 7×8=56, inline-PNG, своё окно закрыто, 0 хвостов |
| `npm run matrix` | **7/7 pass**, 36 шагов, ~2.7k tokens (estimate), 9.5 s; `docs/v0.4-matrix.json` |
| `-SelfTest` | **37/37** mapping-кейсов, включая negative origin и 4 layout'а |
| `npm run pack:check` | **16 файлов**, `build.json` и `LICENSE` в пакете |
| `-Verify` | **VERIFY OK** `1c7bc32bf511… (0.6.0)` |
| HMR-монтаж | `mounted-4992.json`: `0.6.0` / `1c7bc32bf511…` / `electron:true` |

## Ограничения и остаточные риски

- UAC/локскрин/приложения «от администратора» недоступны.
- **Human confirm — on-desktop диалог**, не tamper-proof канал: агент работает на
  том же рабочем столе, слепой клик по координатам технически возможен. Полного
  takeover (передачи мыши человеку) нет; для строгой границы — VM/DSH approval.
- `computer` регистрируется глобально, но субагенты по умолчанию denied;
  `subagents:"allow"` снимает контроль. Хост PowerShell работает вне sandbox DSH;
  child с `pwsh`/`read_image` всё равно может дотянуться до desktop.
- Мультимонитор/125–150% проверены только математически; hardware-матрицы нет.
- OCR: смешанные `0O1Il5S` визуально неразличимы; CER/WER — report-only.
- Attachment-store DSH хранит объекты вечно; prune — операторская команда,
  не автоматический GC. При ошибке чтения хотя бы одной сессии prune
  **отказывается удалять** и требует `-Force` после ручной проверки.

Подробности: [plugin README](plugin/dsh-plugin-computer-use/README.md),
[SECURITY.md](plugin/dsh-plugin-computer-use/SECURITY.md),
[CHANGELOG](plugin/dsh-plugin-computer-use/CHANGELOG.md),
[parity map](docs/v0.4-parity.md),
[v0.6 evidence](docs/v0.6.0-evidence.md),
[v0.5 evidence](docs/v0.5.0-evidence.md), [v0.4 plan](docs/v0.4-plan.md).

## Лицензия

[MIT](LICENSE) © 2026 GreenJenckens.
