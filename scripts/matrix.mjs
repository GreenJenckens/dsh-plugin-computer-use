import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { spawn, spawnSync } from 'node:child_process'
import { fileURLToPath, pathToFileURL } from 'node:url'

const here = path.dirname(fileURLToPath(import.meta.url))
const pluginDir = path.join(here, '..', 'plugin', 'dsh-plugin-computer-use')
const args = process.argv.slice(2)
const jsonOut = args.includes('--json') ? args[args.indexOf('--json') + 1] : path.join(here, '..', 'docs', 'v0.4-matrix.json')
const writeBaseline = args.includes('--write-baseline')
const only = args.includes('--scenario') ? args[args.indexOf('--scenario') + 1].split(',') : null
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms))

function edgePath() {
  const roots = [process.env['PROGRAMFILES(X86)'], process.env.PROGRAMFILES, 'C:\\Program Files (x86)', 'C:\\Program Files'].filter(Boolean)
  for (const root of roots) {
    const candidate = path.join(root, 'Microsoft', 'Edge', 'Application', 'msedge.exe')
    if (fs.existsSync(candidate)) return candidate
  }
  return ''
}
const EDGE = edgePath()

function unique(prefix) {
  return `${prefix}_${process.pid}_${Date.now()}_${Math.random().toString(36).slice(2, 6)}`
}

function loadTool(tempDir) {
  const tools = new Map()
  const disposers = []
  const ctx = {
    get(name) {
      if (name === 'llm') return { resolveModelInfo: async () => ({ inputModalities: ['text'] }) }
      return undefined
    },
    on(event, callback) { if (event === 'dispose') disposers.push(callback) },
    tools: { register(tool) { tools.set(tool.name, tool) } },
  }
  return import(pathToFileURL(path.join(pluginDir, 'lib', 'index.js')).href).then((mod) => {
    mod.apply(ctx, { tempDir, markerDir: tempDir, timeoutMs: 60000 })
    return { tool: tools.get('computer'), disposers }
  })
}

function startForm(script, title) {
  const file = path.join(os.tmpdir(), `${title}.ps1`)
  fs.writeFileSync(file, script.replaceAll('__TITLE__', title))
  const child = spawn('powershell.exe', ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', file], { windowsHide: false, stdio: 'ignore' })
  return { child, file, title, hwnd: 0 }
}

async function waitWindow(call, form, timeoutMs = 12000) {
  const deadline = Date.now() + timeoutMs
  while (Date.now() < deadline) {
    const list = await call('windows.list', { limit: 120 })
    const row = list.value.text.split('\n').find((line) => line.startsWith('hwnd=') && line.includes(form.title))
    if (row) {
      const pid = Number((row.match(/pid=(\d+)/) || [])[1] || 0)
      if (!form.child || pid === form.child.pid) {
        form.hwnd = Number(row.match(/hwnd=(\d+)/)[1])
        return form.hwnd
      }
    }
    await sleep(200)
  }
  return 0
}

async function closeOwned(call, form) {
  if (form?.hwnd) { try { await call('windows.close', { hwnd: form.hwnd }) } catch {} }
  if (form?.child) {
    try { form.child.kill() } catch {}
    await new Promise((resolve) => {
      if (form.child.exitCode !== null) return resolve()
      const timer = setTimeout(resolve, 3000)
      form.child.once('exit', () => { clearTimeout(timer); resolve() })
    })
  }
  if (form?.file) { try { fs.rmSync(form.file, { force: true }) } catch {} }
}

const scenarios = []
function register(id, run) { scenarios.push({ id, run }) }

register('windows-dpi', async (call) => {
  const list = await call('windows.list', { limit: 20 })
  const monitor = list.value.text.split('\n').find((line) => line.startsWith('monitor=0 '))
  if (!monitor || !/dpi=\d+ \d+%/.test(monitor)) throw new Error('monitor dpi line missing')
  const row = list.value.text.split('\n').find((line) => line.startsWith('hwnd='))
  if (!row) throw new Error('no window row')
  const hwnd = Number(row.match(/hwnd=(\d+)/)[1])
  const info = await call('windows.info', { hwnd })
  const a = row.match(/ (-?\d+),(-?\d+) (\d+)x(\d+)/)
  const b = info.value.text.match(/ (-?\d+),(-?\d+) (\d+)x(\d+)/)
  if (!a || !b || a.slice(1).join(',') !== b.slice(1).join(',')) throw new Error('list/info geometry mismatch')
  return { monitor: monitor.trim(), geometry: a.slice(1).join(',') }
})

register('calc-7x8', async (call) => {
  const before = new Set((await call('windows.list', { limit: 120 })).value.text.split('\n').filter((l) => l.startsWith('hwnd=')).map((l) => Number(l.match(/hwnd=(\d+)/)[1])))
  const launched = await call('launch', { target: 'calc.exe', waitMs: 1200 })
  if (!/^launched/.test(launched.value.text)) throw new Error('launch failed')
  let target = 0
  const deadline = Date.now() + 10000
  while (!target && Date.now() < deadline) {
    const rows = (await call('windows.list', { limit: 120 })).value.text.split('\n').filter((l) => l.startsWith('hwnd='))
    const row = rows.find((l) => !before.has(Number(l.match(/hwnd=(\d+)/)[1])) && /"(?:[^"]*)(Calculator|Калькулятор)[^"]*"/i.test(l))
    if (row) target = Number(row.match(/hwnd=(\d+)/)[1])
    else await sleep(250)
  }
  if (!target) throw new Error('calculator window not found')
  try {
    for (const id of ['num7Button', 'multiplyButton', 'num8Button', 'equalButton']) await call('act.invoke', { hwnd: target, automationId: id })
    const result = await call('observe.tree', { hwnd: target, automationId: 'CalculatorResults' })
    if (!/\b56\b/.test(result.value.text)) throw new Error('result is not 56')
    return { result: '56' }
  } finally {
    try { await call('windows.close', { hwnd: target }) } catch {}
  }
})

register('edge-password', async (call, temp) => {
  if (!EDGE) throw new Error('Edge not installed')
  const title = unique('CUMATRIX_EDGE')
  const secret = unique('SECRET_EDGE')
  const profile = fs.mkdtempSync(path.join(os.tmpdir(), 'dsh-cu-matrix-edge-'))
  const html = path.join(os.tmpdir(), `${title}.html`)
  fs.writeFileSync(html, `<title>${title}</title><body><input id="plain" value="hello-edge"><input id="pwd" type="password" value="${secret}"></body>`)
  const child = spawn(EDGE, [`--app=${pathToFileURL(html).href}`, `--user-data-dir=${profile}`, '--no-first-run', '--disable-sync', '--disable-extensions', '--force-renderer-accessibility', '--window-size=800,500', '--window-position=40,40'], { stdio: 'ignore' })
  const form = { child, title, file: html, hwnd: 0 }
  try {
    const hwnd = await waitWindow(call, form)
    if (!hwnd) throw new Error('Edge window not found')
    let tree = ''
    for (let i = 0; i < 12; i++) {
      tree = (await call('observe.tree', { hwnd, maxNodes: 400 })).value.text
      if (tree.includes('hello-edge')) break
      await sleep(250)
    }
    if (!tree.includes('hello-edge')) throw new Error('plain input not visible')
    if (tree.includes(secret)) throw new Error('password leaked in tree')
    const value = await call('observe.getvalue', { hwnd, automationId: 'pwd' })
    if (value.value.text.includes(secret)) throw new Error('password leaked in getvalue')
    const ocr = await call('ocr', { hwnd, maxLines: 80 })
    if (ocr.value.text.includes(secret)) throw new Error('password leaked in OCR')
    return { leak: 0 }
  } finally {
    await closeOwned(call, form)
    spawnSync('powershell.exe', ['-NoProfile', '-Command', `Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" | Where-Object { $_.CommandLine -like '*${profile.replace(/'/g, "''")}*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }`], { stdio: 'ignore', windowsHide: true })
    try { fs.rmSync(profile, { recursive: true, force: true }) } catch {}
  }
})

register('confirm-password', async (call) => {
  const title = unique('CUMATRIX_PWD')
  const form = startForm(`Add-Type -AssemblyName System.Windows.Forms
$f=New-Object System.Windows.Forms.Form; $f.Text='__TITLE__'; $f.Width=420; $f.Height=220
$p=New-Object System.Windows.Forms.TextBox; $p.Name='PwdBox'; $p.UseSystemPasswordChar=$true; $p.Text='SECRET-MATRIX'; $p.Location=New-Object System.Drawing.Point(10,20); $f.Controls.Add($p)
[void]$f.ShowDialog()`, title)
  try {
    const hwnd = await waitWindow(call, form)
    if (!hwnd) throw new Error('form not found')
    const tree = await call('observe.tree', { hwnd, maxNodes: 80 })
    const line = tree.value.text.split('\n').find((l) => l.includes('[password redacted]'))
    if (!line) throw new Error('password field not redacted')
    const index = Number(line.match(/i=(\d+)/)[1])
    await call('act.click', { hwnd, index })
    let denied = false
    try { await call('input.type', { hwnd, text: 'denied' }) } catch (error) { denied = /pre-authorization/.test(error.message) }
    if (!denied) throw new Error('password typing was not denied')
    if (tree.value.text.includes('SECRET-MATRIX')) throw new Error('password leaked in tree')
    return { denied: true }
  } finally { await closeOwned(call, form) }
})

register('act-sequence', async (call) => {
  const result = await call('act.sequence', { steps: [{ action: 'windows.list', limit: 3 }, { action: 'input.cursor' }] })
  if (!/sequence ok \(2 steps\)/.test(result.value.text)) throw new Error('sequence did not complete 2 steps')
  return { steps: 2 }
})

register('windows-move', async (call) => {
  const title = unique('CUMATRIX_MOVE')
  const form = startForm(`Add-Type -AssemblyName System.Windows.Forms
$f=New-Object System.Windows.Forms.Form; $f.Text='__TITLE__'; $f.Width=400; $f.Height=240
[void]$f.ShowDialog()`, title)
  try {
    const hwnd = await waitWindow(call, form)
    if (!hwnd) throw new Error('form not found')
    const moved = await call('windows.move', { hwnd, x: -100, y: -50 })
    if (!/moved hwnd=/.test(moved.value.text)) throw new Error('move failed')
    const info = await call('windows.info', { hwnd })
    const pos = info.value.text.match(/ (-?\d+),(-?\d+) /)
    if (!pos) throw new Error(`no position: ${info.value.text}`)
    const x = Number(pos[1]); const y = Number(pos[2])
    // SetWindowPos moves the outer window; the reported DWM frame can differ by
    // the invisible resize border (about 7 px at 100%).
    if (x < -110 || x > -90 || y < -60 || y > -40) throw new Error(`unexpected position: ${info.value.text}`)
    return { requested: [-100, -50], frame: [x, y] }
  } finally { await closeOwned(call, form) }
})

register('ocr-digits', async (call) => {
  const title = unique('CUMATRIX_OCR')
  const form = startForm(`Add-Type -AssemblyName System.Windows.Forms
$f=New-Object System.Windows.Forms.Form; $f.Text='__TITLE__'; $f.Width=560; $f.Height=220
$l=New-Object System.Windows.Forms.Label; $l.Text='0123456789 0O1Il5S'; $l.Font=New-Object System.Drawing.Font('Segoe UI',18); $l.AutoSize=$true; $l.Location=New-Object System.Drawing.Point(20,40); $f.Controls.Add($l)
[void]$f.ShowDialog()`, title)
  try {
    const hwnd = await waitWindow(call, form)
    if (!hwnd) throw new Error('form not found')
    const ocr = await call('ocr', { hwnd, ocrLang: 'en-US', maxLines: 20 })
    if (!ocr.value.text.includes('0123456789')) throw new Error(`digits not read: ${ocr.value.text.split('\n').slice(0, 3).join(' | ')}`)
    return { digits: true }
  } finally { await closeOwned(call, form) }
})

const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'dsh-cu-matrix-'))
const { tool, disposers } = await loadTool(temp)
const schemaBytes = Buffer.byteLength(JSON.stringify(tool.parameters))
let steps = 0
let tokens = 0
const calls = []
async function call(action, extra = {}) {
  const started = performance.now()
  const value = await tool.execute({ action, ...extra }, {})
  const ms = performance.now() - started
  steps++
  const text = String(value.text ?? '')
  tokens += Buffer.byteLength(text, 'utf8') / 4
  calls.push({ action, ms, text: text.slice(0, 200) })
  return { value, ms }
}

const results = []
try {
  for (const scenario of scenarios) {
    if (only && !only.includes(scenario.id)) continue
    const beforeSteps = steps
    const beforeTokens = tokens
    const started = performance.now()
    const scenarioTemp = path.join(temp, scenario.id)
    fs.mkdirSync(scenarioTemp, { recursive: true })
    let pass = true
    let error = ''
    let detail = null
    try { detail = await scenario.run(call, scenarioTemp) }
    catch (failure) { pass = false; error = failure.message }
    const latency = performance.now() - started
    results.push({
      id: scenario.id, pass, error, detail,
      steps: steps - beforeSteps,
      tokensEstimate: Math.round(tokens - beforeTokens),
      latencyMs: Math.round(latency),
    })
    console.log(`${pass ? 'PASS' : 'FAIL'} ${scenario.id} steps=${steps - beforeSteps} tokens~${Math.round(tokens - beforeTokens)} ${Math.round(latency)}ms${error ? ' :: ' + error : ''}`)
  }
} finally {
  for (const dispose of disposers) { try { await dispose() } catch {} }
  try { fs.rmSync(temp, { recursive: true, force: true }) } catch {}
}

const report = {
  generatedAt: new Date().toISOString(),
  runId: unique('matrix'),
  environment: {
    os: os.version(),
    node: process.version,
    platform: process.platform,
    edge: EDGE || null,
    monitors: 'see windows-dpi',
  },
  schema: { bytesCompact: schemaBytes, actions: tool.parameters.properties.action.description.split('|').length, params: Object.keys(tool.parameters.properties).length },
  summary: { total: results.length, passed: results.filter((r) => r.pass).length, failed: results.filter((r) => !r.pass).length, steps, tokensEstimate: Math.round(tokens) },
  scenarios: results,
}
fs.mkdirSync(path.dirname(jsonOut), { recursive: true })
fs.writeFileSync(jsonOut, JSON.stringify(report, null, 2) + '\n')
console.log(`wrote ${jsonOut}: ${report.summary.passed}/${report.summary.total} passed`)
if (report.summary.failed > 0) process.exitCode = 1
