import { test } from 'node:test'
import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { spawn } from 'node:child_process'
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
  fs.writeFileSync(file, `Add-Type -AssemblyName System.Windows.Forms\n$f=New-Object System.Windows.Forms.Form\n$f.Text='${title}'\n$f.Width=320\n$f.Height=160\n[void]$f.ShowDialog()\n`)
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

test('screenshot expectedWindow fences a stale foreground', async () => {
  const { tool, disposers } = await loadReal()
  try {
    await assert.rejects(tool.execute({ action: 'screenshot', expectedWindow: 1 }, {}), /expectedWindow=1/)
  } finally { await dispose(disposers) }
})
