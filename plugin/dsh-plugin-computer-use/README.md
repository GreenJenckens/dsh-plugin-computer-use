# dsh-plugin-computer-use

Управление рабочим столом Windows для DeepSeek Harness одним компактным тулом
`computer`: окна, UI Automation, ввод, скриншоты, OCR и запуск приложений.
Постоянный процесс Windows PowerShell 5.1 держит UIA и Win32 тёплыми; каждый
вызов — JSON-строка в хост. Схема тула ≈ 3.1 КБ compact; 42 actions и 47
параметров.

Версия **0.6.0**. Слои: `lib/index.js` (тул, режимы, гейты, `act.sequence`,
image-block) → `lib/bridge.js` (тёплый powershell.exe, очередь, abort,
retention) → `lib/scripts/bridge.ps1` (окна, UIA, ввод, скриншоты, OCR, wait,
diagnostics, launch) → `lib/scripts/CuCommon.ps1` (DPI, Win32 P/Invoke,
virtual-desktop mapping, ES_PASSWORD). Индикатор и диалог подтверждения —
`lib/indicator/`.

## Возможности

| Группа | Действия |
|---|---|
| окна | `windows.list/info/activate/minimize/maximize/restore/close/move`; `windows.list` отдаёт DWM-frame и `monitor=N WxH at x,y dpi=96 100%` |
| наблюдение | `observe.tree/info/getvalue/gettext` — компактный текст `ref=ab12cd34 i=12 Button "Save" #save 100,200 80x32 [invoke]`; `observe.wait` — ждать hwnd/title/regex/element до 60 с |
| действия | `act.invoke/click/doubleclick/rightclick/setvalue/toggle/select/expand/collapse/focus/scroll` |
| пакет | `act.sequence` — 1–8 действий за один вызов, стоп на первой ошибке, отчёт по шагам |
| ввод | `input.type/key/hotkey/paste/move/click/doubleclick/rightclick/middleclick/drag/scroll/wait/cursor` |
| экран | `screenshot` (PNG в результате; `capture: auto/screen/print`, DWM-кроп, детект пустого кадра, `sourceX/sourceY/scale`, `expectedWindow`-забор) |
| текст с экрана | `ocr` (Windows OCR, ru/en, боксы `[x,y,wxh]`, clamp под лимит 10 000 px, `expectedWindow`) |
| запуск | `launch` (приложение/файл/URL; стабильный hwnd; deny-list интерпретаторов, UNC, чужих схем) |
| браузер | `browser.list` / `browser.eval` — CDP через loopback `cdpPort`; список вкладок и JS в странице |
| диагностика | `diagnostics` — PowerShell/UIA/OCR/мониторы/temp/indicator/mode |

## Стабильные ссылки

`observe.tree` печатает `ref=<8 hex>` для каждого элемента. Передавай `ref` в
`act.*`/`observe.*` вместо `i=`: ref проверяется на свежем дереве при каждом
вызове и падает с `stale ref`, если окно закрылось или элемент исчез/переехал.
`i=` остаётся per-walk и годится только сразу после `observe.tree`.

## CDP-браузер

Опционально: `cdpPort: 9222` в конфиге и Edge/Chrome, запущенный с
`--remote-debugging-port=9222`.

- `browser.list` — вкладки (id/title/url/ws), только loopback.
- `browser.eval` — `text` как JS-выражение, `target` — подстрока id/title/url;
  выполняется в выбранной вкладке через `Runtime.evaluate`.
- `browser.eval` — произвольный JS в странице; включай осознанно, это не
  sandbox. `browser.list` разрешён в `readonly`, `browser.eval` — нет.

## Режимы

`mode` — только конфиг, модель не может его переключить через аргументы:

- `auto` (по умолчанию) — все действия;
- `readonly` — только наблюдение (`windows.list/info`, `observe.*`, `screenshot`,
  `ocr`, `diagnostics`, `browser.list`, cursor/wait); клики, ввод, запуск и
  `browser.eval` отклоняются;
- `disabled` — все вызовы отклоняются, включая диагностику.

## Индикатор и подтверждение

- Пока агент работает с ПК, сверху — синяя градиентная **пилюля** с белой
  кнопкой **Остановить/Продолжить**, по краям — тонкая линия + мягкое свечение,
  вокруг курсора — тонкое кольцо с точкой. Через ~15 с бездействия всё плавно
  исчезает.
- В паузе пилюля и кольцо краснеют, кнопка становится **Продолжить**, а bridge
  отклоняет операции до повторного нажатия.
- Class-C действия (ввод в терминал/интерпретатор, запись в пароль, кнопки с
  ключевыми словами `оплат/купить/оформить/удалить/отправить/...`, `pay/send/
  delete/...`) показывают диалог **«Разрешить / Запретить»** с таймаутом 30 с;
  без ответа — отказ. `confirm: "never"` — полный доступ без диалогов.
- Окна индикатора/диалога имеют `WS_EX_TRANSPARENT | NOACTIVATE | TOOLWINDOW`,
  заголовки `DSH-CU-*`, не попадают в `windows.list` и не могут быть целью тула.

## Безопасность

- **Субагенты: default deny.** Через `ctx.tools.guard` (структурно до тела тула)
  и fallback в `execute`: `delegationDepth ≥ 1` / `origin:"subagent"` получают
  отказ, audit-строку `denied-subagent` и не спавнят хост. Включить обратно —
  `subagents: allow` в конфиге плагина. Это policy-контроль, не OS-граница.
- **Pre-authorization для class-C.** По умолчанию запрещены ввод в
  терминал/интерпретатор (`cmd`, `powershell`, Windows Terminal) и запись в
  поля-пароли. Осознанный opt-in: `confirm: "never"`. Интерактивного takeover
  в v0.4 нет — это документированный разрыв с Anthropic/OpenAI.
- Пароли при чтении редактируются по `IsPassword` **и** `ES_PASSWORD`; Edge 156
  отдаёт page-поле с `IsPassword=true`, а Chromium дополнительно маскирует
  value/text. Кастомные `-webkit-text-security`-виджеты не защищены.
- `gettext`-fallback через буфер — только `clipboard:true`, с восстановлением
  буфера в `finally` и запретом консольных окон.
- `input.*` и `act.click` активируют окно и проверяют foreground, иначе отказ.
- Скриншот нельзя записать вне temp-каталога плагина (`path` ограничен).
- Аудит: `%TEMP%\dsh-cu\audit.jsonl` для всех действий, экранов, OCR, запусков
  и ошибок; текст ввода — только длиной; ротация 5 МБ.
- Границы: `maxNodes/maxDepth/maxChars/maxLines/limit/ms/waitMs/text`,
  regex-таймаут 200 мс, `region` в пределах virtual screen, `ocrScale ≤ 3`.
- Temp retention: 2 ч / 150 PNG по умолчанию, настраивается
  (`retentionHours`, `maxFiles`), чистится и при старте хоста.
- Подробности и остаточные риски — [SECURITY.md](SECURITY.md).

## Установка и проверка

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "<repo>\install-plugin.ps1"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "<repo>\install-plugin.ps1" -Verify
```

Скрипт делает бэкап прошлой установки (`*.bak_<ts>`), копирует `lib` + README/
CHANGELOG/SECURITY, пишет `build.json` (SHA-256 каждого файла и общий
`buildHash`), добавляет `link:`-зависимость и bundle в профиль, запускает
`pnpm install`. `-Verify` сравнивает дерево исходника и установленной копии,
проверяет `build.json` (hash/version) и выходит с кодом 1 при расхождении.

Смонтированный экземпляр пишет `%TEMP%\dsh-cu\mounted-<pid>.json` с `version`,
`buildHash` и `electron:true`. Generic `mounted.json` пишет только Electron;
тесты и CLI-импорты его больше не затирают. При включённом HMR плагин
перезагружается без перезапуска DSH.

## Конфигурация

```yaml
- id: computer-use
  config:
    timeoutMs: 60000
    mode: auto             # auto | readonly | disabled
    cdpPort: 9222          # optional; Edge/Chrome --remote-debugging-port=9222
    tempDir: C:\Temp\cu
    markerDir: C:\Temp\cu\markers
    retentionHours: 2
    maxFiles: 150
    subagents: deny        # allow — только осознанно
    confirm: consequential # never — полный доступ без диалогов
    indicator: true        # кромка/курсор/баннер + диалог подтверждения
    confirmKeywords:
      - оплат
      - оплатить
      - купить
      - оформить
      - удалить
      - отправить
    powershell: C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe
```

## Тесты

```powershell
cd plugin\dsh-plugin-computer-use
npm test          # все кейсы, GUI-файлы последовательно
npm run test:unit # без рабочего стола (schema/gates/marker)
npm run smoke     # E2E: калькулятор 7×8=56, inline-PNG, своё окно закрыто
npm run matrix    # 7 сценариев, steps/tokens/latency, non-visual asserts
npm run pack:check
npm run ocr:eval  # датасет 12×3, CER/WER (dev-only seam DSH_CU_OCR_EVAL)
```

Тесты интеграционные (нужен рабочий стол): реальные окна, WinForms-форма с
паролем, Edge-страница с паролем, терминал, скриншоты. Каждый тест закрывает
своё окно/процесс и использует уникальные заголовки.

## Ограничения

- UAC, экран блокировки и приложения «от администратора» недоступны без
  повышения прав.
- Окна, которые нельзя вывести на передний план, снимаются через PrintWindow;
  часть приложений отдаёт пустой кадр — тогда ошибка, а не чёрный «успех».
- OCR: на 2×-масштабе цифры/0→D заметно лучше, чем на 1×; на смешанных
  `0O1Il5S`-кодах Windows OCR путает визуально неразличимые глифы. CER/WER
  считаются датасетом, абсолютные пороги — report-only.
- Мультимонитор/125–150%: механизм (VIRTUALDESK, per-monitor DPI, self-test
  математики) готов, hardware-матрицы на этой машине нет — не заявляется.
- Человеческое подтверждение — **on-desktop диалог**, а не tamper-proof канал:
  агент работает на том же рабочем столе, слепой клик по координатам диалога
  технически возможен. Для строгой границы — VM/low-priv пользователь или DSH
  approval policy. Полноценного takeover с передачей мыши нет.
- Attachment-store DSH хранит объекты вечно и не даёт refcount; плагин не
  удаляет их сам. Для оператора есть `scripts/prune-attachments.ps1` (dry-run
  по умолчанию, zstd-aware refs, path-guard).
