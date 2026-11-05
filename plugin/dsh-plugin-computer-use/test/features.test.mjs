import { test } from 'node:test'
import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { spawn } from 'node:child_process'
import http from 'node:http'
import { pathToFileURL } from 'node:url'
import { fileURLToPath } from 'node:url'

const pluginDir = path.join(path.dirname(fileURLToPath(import.meta.url)), '..')
const missingHost = 'C:\\definitely-missing\\dsh-cu-nope.exe'

async function load(config = {}) {
  const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'dsh-cu-features-'))
  const tools = new Map()
  const disposers = []
  const ctx = {
    get: () => undefined,
    on(event, callback) { if (event === 'dispose') disposers.push(callback) },
    tools: { register(tool) { tools.set(tool.name, tool) } },
  }
  const mod = await import(pathToFileURL(path.join(pluginDir, 'lib', 'index.js')).href)
  mod.apply(ctx, { powershell: missingHost, tempDir: temp, markerDir: temp, timeoutMs: 15000, ...config })
  return { tool: tools.get('computer'), temp, disposers }
}

async function loadReal(config = {}) {
  return load({ ...config, powershell: undefined })
}

async function dispose(disposers) {
  for (const disposer of disposers) {
    try { await disposer() } catch {}
  }
}

function startForm(title) {
  const file = path.join(os.tmpdir(), `dsh-cu-wait-${process.pid}-${Date.now()}.ps1`)
  fs.writeFileSync(file, `Add-Type -AssemblyName System.Windows.Forms\n$f=New-Object System.Windows.Forms.Form\n$f.Text='${title}'\n$f.Width=320\n$f.Height=160\n$b=New-Object System.Windows.Forms.Button\n$b.Text='RefTarget'\n$b.Name='RefTarget'\n$b.Location=New-Object System.Drawing.Point(20,40)\n$b.Width=120\n$f.Controls.Add($b)\n[void]$f.ShowDialog()\n`)
  const child = spawn('powershell.exe', ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', file], { windowsHide: false, stdio: 'ignore' })
  return { child, file }
}

test('readonly and disabled modes reject actions before the host is contacted', async () => {
  const read = await load({ mode: 'readonly' })
  try {
    await assert.rejects(read.tool.execute({ action: 'act.invoke', name: 'x' }, {}), /readonly mode/)
  } finally { await dispose(read.disposers) }

  const off = await load({ mode: 'disabled' })
  try {
    await assert.rejects(off.tool.execute({ action: 'windows.list' }, {}), /disabled by plugin config/)
  } finally { await dispose(off.disposers) }
})

test('diagnostics reports PowerShell, UIA and monitor state', async () => {
  const { tool, disposers } = await loadReal()
  try {
    const result = await tool.execute({ action: 'diagnostics' }, {})
    assert.match(result.text, /powershell=5\.1/)
    assert.match(result.text, /uia=ok/)
    assert.match(result.text, /monitors=\d+x\d+@/)
    assert.match(result.text, /mode=auto/)
  } finally { await dispose(disposers) }
})

test('observe.wait resolves a window title without side effects', async () => {
  const title = `CUC_WAIT_${process.pid}_${Date.now()}`
  const form = startForm(title)
  const { tool, disposers } = await loadReal()
  try {
    const result = await tool.execute({ action: 'observe.wait', title, waitMs: 8000 }, {})
    assert.match(result.text, /waited \d+ ms; matched hwnd=\d+/)
  } finally {
    try { form.child.kill() } catch {}
    try { fs.unlinkSync(form.file) } catch {}
    await dispose(disposers)
  }
})

test('observe.tree ref is re-resolved and stale after the window closes', async () => {
  const title = `CUC_REF_${process.pid}_${Date.now()}`
  const form = startForm(title)
  const { tool, disposers } = await loadReal()
  try {
    await tool.execute({ action: 'observe.wait', title, waitMs: 8000 }, {})
    const tree = await tool.execute({ action: 'observe.tree', title, maxNodes: 80 }, {})
    const line = String(tree.text).split('\n').find((row) => row.includes('RefTarget'))
    assert.ok(line, 'button row not found')
    const ref = line.match(/ref=([0-9a-f]{8})/)[1]
    const clicked = await tool.execute({ action: 'act.click', ref }, {})
    assert.match(clicked.text, /^clicked /)
    try { form.child.kill() } catch {}
    await new Promise((resolve) => setTimeout(resolve, 400))
    await assert.rejects(tool.execute({ action: 'act.invoke', ref }, {}), /stale ref/)
  } finally {
    try { form.child.kill() } catch {}
    try { fs.unlinkSync(form.file) } catch {}
    await dispose(disposers)
  }
})

test('browser.list reads the loopback CDP target list', async () => {
  const server = http.createServer((req, res) => {
    res.setHeader('content-type', 'application/json')
    res.end(JSON.stringify([{ id: 'PAGE1', type: 'page', title: 'VK Shorts', url: 'https://vkvideo.ru/shorts', webSocketDebuggerUrl: 'ws://127.0.0.1/devtools/page/PAGE1' }]))
  })
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve))
  const port = server.address().port
  const { tool, disposers } = await load({ cdpPort: port })
  try {
    const result = await tool.execute({ action: 'browser.list' }, {})
    assert.match(result.text, /title="VK Shorts"/)
    assert.match(result.text, /url=https:\/\/vkvideo\.ru\/shorts/)
  } finally {
    server.close()
    await dispose(disposers)
  }
})

test('screenshot expectedWindow fences a stale foreground', async () => {
  const { tool, disposers } = await loadReal()
  try {
    await assert.rejects(tool.execute({ action: 'screenshot', expectedWindow: 1 }, {}), /expectedWindow=1/)
  } finally { await dispose(disposers) }
})
