import { test } from 'node:test'
import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { spawn } from 'node:child_process'
import { fileURLToPath } from 'node:url'
import { createHost } from '../lib/bridge.js'

const hostScript = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', 'lib', 'scripts', 'bridge.ps1')

function startForm(title, extra = '', writeHandle = '') {
  const file = path.join(os.tmpdir(), `${title}.ps1`)
  const handleFile = writeHandle ? path.join(os.tmpdir(), `${title}.hwnd`) : ''
  fs.writeFileSync(file, `Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$f=New-Object System.Windows.Forms.Form
$f.Text='${title}'
$f.Width=420
$f.Height=220
${extra}
${handleFile ? `[IO.File]::WriteAllText('${handleFile.replaceAll("'", "''")}', [string]$f.Handle)` : ''}
[void]$f.ShowDialog()
`)
  const child = spawn('powershell.exe', ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', file], { windowsHide: false, stdio: 'ignore' })
  return { child, file, title, handleFile }
}

async function waitHandle(form) {
  for (let i = 0; i < 50; i++) {
    if (form.handleFile && fs.existsSync(form.handleFile)) {
      const hwnd = Number(fs.readFileSync(form.handleFile, 'utf8').trim())
      if (hwnd) return hwnd
    }
    await new Promise((resolve) => setTimeout(resolve, 150))
  }
  return 0
}

async function waitWindow(host, form) {
  for (let i = 0; i < 50; i++) {
    const list = await host.enqueue('windows.list', { limit: 120 })
    const row = list.text.split('\n').find((line) => line.startsWith('hwnd=') && line.includes(form.title))
    if (row) return Number(row.match(/hwnd=(\d+)/)[1])
    await new Promise((resolve) => setTimeout(resolve, 150))
  }
  return 0
}

function cleanup(form) {
  try { form.child.kill() } catch {}
  try { fs.rmSync(form.file, { force: true }) } catch {}
  try { if (form.handleFile) fs.rmSync(form.handleFile, { force: true }) } catch {}
}

test('overlay windows are hidden from windows.list and cannot be targeted', { skip: process.platform !== 'win32', timeout: 30000 }, async () => {
  const title = `DSH-CU-OVERLAY-TEST_${process.pid}_${Date.now()}`
  const form = startForm(title, '', true)
  const host = createHost({ script: hostScript, timeoutMs: 30000 })
  try {
    const hwnd = await waitHandle(form)
    assert.ok(hwnd > 0, 'form handle was not written')
    const list = await host.enqueue('windows.list', { limit: 200 })
    assert.equal(list.text.includes(`hwnd=${hwnd}`), false, 'overlay was listed')
    await assert.rejects(host.enqueue('windows.info', { hwnd }), /overlay windows are not valid targets/)
  } finally {
    cleanup(form)
    await host.dispose()
  }
})

test('clicking a sensitive keyword button is gated', { skip: process.platform !== 'win32', timeout: 30000 }, async () => {
  const title = `CUC_SENSITIVE_${process.pid}_${Date.now()}`
  const form = startForm(title, `$b=New-Object System.Windows.Forms.Button
$b.Text='Send payment'
$b.Name='SendButton'
$b.Location=New-Object System.Drawing.Point(20,40)
$b.Width=180
$f.Controls.Add($b)`)
  const host = createHost({ script: hostScript, timeoutMs: 30000 })
  try {
    const hwnd = await waitWindow(host, form)
    assert.ok(hwnd > 0, 'form did not appear')
    const tree = await host.enqueue('observe.tree', { hwnd, maxNodes: 80 })
    const line = tree.text.split('\n').find((l) => l.includes('Send payment'))
    assert.ok(line, 'sensitive button not found')
    const index = Number(line.match(/i=(\d+)/)[1])
    await assert.rejects(
      host.enqueue('act.click', { hwnd, index, __confirmMode: 'deny' }),
      /pre-authorization/,
    )
    const allowed = await host.enqueue('act.click', { hwnd, index, __allowConsequential: true })
    assert.match(allowed.text, /clicked/)
  } finally {
    try { await host.enqueue('windows.close', { hwnd }); } catch {}
    cleanup(form)
    await host.dispose()
  }
})

