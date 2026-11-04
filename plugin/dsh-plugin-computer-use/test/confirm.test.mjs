import { test } from 'node:test'
import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { spawn, spawnSync } from 'node:child_process'
import { fileURLToPath, pathToFileURL } from 'node:url'
import { createHost } from '../lib/bridge.js'

const pluginDir = path.join(path.dirname(fileURLToPath(import.meta.url)), '..')
const hostScript = path.join(pluginDir, 'lib', 'scripts', 'bridge.ps1')

const FORM = `
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$form = New-Object System.Windows.Forms.Form
$form.Text = '__TITLE__'
$form.Width = 420
$form.Height = 260
$form.StartPosition = 'CenterScreen'
$plain = New-Object System.Windows.Forms.TextBox
$plain.Name = 'PlainBox'
$plain.Text = 'hello-normal'
$plain.Location = New-Object System.Drawing.Point(10, 20)
$form.Controls.Add($plain)
$pw = New-Object System.Windows.Forms.TextBox
$pw.Name = 'PwdBox'
$pw.UseSystemPasswordChar = $true
$pw.Text = 'SECRET-PWD-999'
$pw.Location = New-Object System.Drawing.Point(10, 60)
$form.Controls.Add($pw)
[void]$form.ShowDialog()
`

function startForm() {
  const id = `CUC_CONFIRM_${process.pid}_${Date.now()}_${Math.random().toString(36).slice(2, 7)}`
  const file = path.join(os.tmpdir(), `${id}.ps1`)
  fs.writeFileSync(file, FORM.replaceAll('__TITLE__', id))
  const child = spawn('powershell.exe', ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', file], { windowsHide: false, stdio: 'ignore' })
  return { child, id, file, hwnd: 0 }
}

async function waitForForm(host, form) {
  for (let i = 0; i < 50; i++) {
    const list = await host.enqueue('windows.list', { limit: 120 })
    const row = list.text.split('\n').find((line) => line.startsWith('hwnd=') && line.includes(form.id))
    if (row && Number((row.match(/pid=(\d+)/) || [])[1]) === form.child.pid) {
      form.hwnd = Number(row.match(/hwnd=(\d+)/)[1])
      return form.hwnd
    }
    await new Promise((resolve) => setTimeout(resolve, 150))
  }
  return 0
}

async function stopForm(host, form) {
  try { if (form.hwnd) await host.enqueue('windows.close', { hwnd: form.hwnd }) } catch {}
  try { form.child.kill() } catch {}
  await new Promise((resolve) => {
    if (form.child.exitCode !== null) return resolve()
    const timer = setTimeout(resolve, 3000)
    form.child.once('exit', () => { clearTimeout(timer); resolve() })
  })
  try { fs.rmSync(form.file, { force: true }) } catch {}
}

test('consequential input into a password field is denied unless explicitly pre-authorized', { skip: process.platform !== 'win32', timeout: 45000 }, async () => {
  const form = startForm()
  const host = createHost({ script: hostScript, timeoutMs: 30000 })
  try {
    const hwnd = await waitForForm(host, form)
    assert.ok(hwnd > 0, 'test form did not appear')
    const tree = await host.enqueue('observe.tree', { hwnd, maxNodes: 100 })
    const pwdLine = tree.text.split('\n').find((line) => line.includes('[password redacted]'))
    assert.ok(pwdLine, 'password element was not found in the tree')
    const pwdIndex = Number(pwdLine.match(/i=(\d+)/)[1])
    await host.enqueue('act.click', { hwnd, index: pwdIndex })
    await assert.rejects(
      host.enqueue('input.type', { hwnd, text: 'denied-text' }),
      /pre-authorization/,
    )
    const allowed = await host.enqueue('input.type', { hwnd, text: 'allowed-text', __allowConsequential: true })
    assert.match(allowed.text, /typed 12 characters/)
    const plainLine = tree.text.split('\n').find((line) => line.includes('hello-normal'))
    assert.ok(plainLine, 'plain element was not found in the tree')
    const plainIndex = Number(plainLine.match(/i=(\d+)/)[1])
    await host.enqueue('act.click', { hwnd, index: plainIndex })
    const plain = await host.enqueue('input.type', { hwnd, text: 'hello-normal-2' })
    assert.match(plain.text, /typed 14 characters/)
  } finally {
    await stopForm(host, form)
    await host.dispose()
  }
})

test('plugin config confirm:"never" is the only way to pass the pre-authorization gate', { skip: process.platform !== 'win32', timeout: 45000 }, async () => {
  const form = startForm()
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'dsh-cu-confirm-'))
  const disposers = []
  let bridgeHost = null
  try {
    bridgeHost = createHost({ script: hostScript, timeoutMs: 30000 })
    const hwnd = await waitForForm(bridgeHost, form)
    assert.ok(hwnd > 0)
    const tree = await bridgeHost.enqueue('observe.tree', { hwnd, maxNodes: 100 })
    const pwdLine = tree.text.split('\n').find((line) => line.includes('[password redacted]'))
    assert.ok(pwdLine, 'password element was not found in the tree')
    const pwdIndex = Number(pwdLine.match(/i=(\d+)/)[1])
    await bridgeHost.enqueue('act.click', { hwnd, index: pwdIndex })

    const mod = await import(pathToFileURL(path.join(pluginDir, 'lib', 'index.js')).href)
    const tools = new Map()
    const ctx = {
      get: () => undefined,
      on(event, callback) { if (event === 'dispose') disposers.push(callback) },
      tools: { register(tool) { tools.set(tool.name, tool) } },
    }
    mod.apply(ctx, { tempDir, markerDir: tempDir, timeoutMs: 30000 })
    const tool = tools.get('computer')
    await assert.rejects(
      tool.execute({ action: 'input.type', hwnd, text: 'denied-text' }, {}),
      /pre-authorization/,
    )

    const tools2 = new Map()
    const ctx2 = {
      get: () => undefined,
      on(event, callback) { if (event === 'dispose') disposers.push(callback) },
      tools: { register(tool) { tools2.set(tool.name, tool) } },
    }
    mod.apply(ctx2, { tempDir, markerDir: tempDir, timeoutMs: 30000, confirm: 'never' })
    const allowed = await tools2.get('computer').execute({ action: 'input.type', hwnd, text: 'allowed-text' }, {})
    assert.match(allowed.text, /typed 12 characters/)
  } finally {
    if (bridgeHost) {
      await stopForm(bridgeHost, form)
      await bridgeHost.dispose()
    }
    for (const dispose of disposers) { try { await dispose() } catch {} }
    fs.rmSync(tempDir, { recursive: true, force: true })
  }
})

test('ask mode waits for a human response from the overlay', { skip: process.platform !== 'win32', timeout: 45000 }, async () => {
  const form = startForm()
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'dsh-cu-confirm-ask-'))
  const indicatorDir = path.join(tempDir, 'indicator')
  fs.mkdirSync(indicatorDir, { recursive: true })
  fs.writeFileSync(path.join(indicatorDir, 'ready'), JSON.stringify({ pid: process.pid, at: new Date().toISOString() }))
  const host = createHost({ script: hostScript, timeoutMs: 30000, tempDir })
  try {
    const hwnd = await waitForForm(host, form)
    assert.ok(hwnd > 0)
    const tree = await host.enqueue('observe.tree', { hwnd, maxNodes: 100 })
    const pwdLine = tree.text.split('\n').find((line) => line.includes('[password redacted]'))
    assert.ok(pwdLine, 'password element was not found')
    const pwdIndex = Number(pwdLine.match(/i=(\d+)/)[1])
    await host.enqueue('act.click', { hwnd, index: pwdIndex })

    const pending = host.enqueue('input.type', { hwnd, text: 'approved-text', __confirmMode: 'ask' })
    const requestPath = path.join(indicatorDir, 'confirm-request.json')
    let request = null
    for (let i = 0; i < 50 && !request; i++) {
      if (fs.existsSync(requestPath)) request = JSON.parse(fs.readFileSync(requestPath, 'utf8'))
      else await new Promise((resolve) => setTimeout(resolve, 100))
    }
    assert.ok(request && request.id, 'confirmation request was not written')
    fs.writeFileSync(path.join(indicatorDir, 'confirm-response.json'), JSON.stringify({ id: request.id, allow: true, reason: 'test' }))
    const result = await pending
    assert.match(result.text, /typed 13 characters/)
  } finally {
    await stopForm(host, form)
    await host.dispose()
    fs.rmSync(tempDir, { recursive: true, force: true })
  }
})

test('typing into an already-open terminal is a consequential action', { skip: process.platform !== 'win32', timeout: 45000 }, async () => {
  const id = `CUC_TERMINAL_${process.pid}_${Date.now()}_${Math.random().toString(36).slice(2, 7)}`
  const child = spawn('cmd.exe', ['/c', 'start', '', 'cmd.exe', '/k', `title ${id}`], { windowsHide: true, stdio: 'ignore' })
  const host = createHost({ script: hostScript, timeoutMs: 30000 })
  let hwnd = 0
  try {
    for (let i = 0; i < 50 && hwnd === 0; i++) {
      const list = await host.enqueue('windows.list', { limit: 120 })
      const row = list.text.split('\n').find((line) => line.startsWith('hwnd=') && line.includes(id))
      if (row) hwnd = Number(row.match(/hwnd=(\d+)/)[1])
      else await new Promise((resolve) => setTimeout(resolve, 150))
    }
    assert.ok(hwnd > 0, 'console window did not appear')
    await assert.rejects(
      host.enqueue('input.type', { hwnd, text: 'rem should-not-type' }),
      /pre-authorization/,
    )
    const allowed = await host.enqueue('input.type', { hwnd, text: 'rem allowed', __allowConsequential: true })
    assert.match(allowed.text, /typed 11 characters/)
  } finally {
    if (hwnd) { try { await host.enqueue('windows.close', { hwnd }) } catch {} }
    try { child.kill() } catch {}
    try { spawnSync('taskkill.exe', ['/FI', `WINDOWTITLE eq ${id}`, '/F'], { stdio: 'ignore', windowsHide: true }) } catch {}
    await host.dispose()
  }
})

test('the cancel flag stops the next host operation until the hotkey resumes', { timeout: 30000 }, async () => {
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'dsh-cu-cancel-'))
  const indicatorDir = path.join(tempDir, 'indicator')
  fs.mkdirSync(indicatorDir, { recursive: true })
  fs.writeFileSync(path.join(indicatorDir, 'cancel'), new Date().toISOString())
  const host = createHost({ script: hostScript, timeoutMs: 30000, tempDir })
  try {
    await assert.rejects(host.enqueue('input.cursor', {}), /cancelled by the user/)
    fs.rmSync(path.join(indicatorDir, 'cancel'), { force: true })
    const result = await host.enqueue('input.cursor', {})
    assert.match(result.text, /^cursor /)
  } finally {
    await host.dispose()
    fs.rmSync(tempDir, { recursive: true, force: true })
  }
})

