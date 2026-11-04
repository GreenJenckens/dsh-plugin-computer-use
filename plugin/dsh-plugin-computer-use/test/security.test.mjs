import { test } from 'node:test'
import assert from 'node:assert/strict'
import path from 'node:path'
import os from 'node:os'
import fs from 'node:fs'
import { spawn } from 'node:child_process'
import { fileURLToPath } from 'node:url'
import { createHost } from '../lib/bridge.js'

const hostScript = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', 'lib', 'scripts', 'bridge.ps1')

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
  const id = `CUSEC_PWD_${process.pid}_${Date.now()}_${Math.random().toString(36).slice(2, 8)}`
  const file = path.join(os.tmpdir(), `${id}.ps1`)
  fs.writeFileSync(file, FORM.replaceAll('__TITLE__', id))
  const child = spawn('powershell.exe', ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', file], { windowsHide: false, stdio: 'ignore' })
  return { child, id, file, hwnd: 0 }
}

async function waitForForm(host, form) {
  for (let i = 0; i < 50; i++) {
    const list = await host.enqueue('windows.list', { limit: 120 })
    const row = list.text.split('\n').find((line) => line.startsWith('hwnd=') && line.includes(form.id))
    if (row) {
      const pid = Number((row.match(/pid=(\d+)/) || [])[1] || 0)
      if (pid === form.child.pid) {
        form.hwnd = Number(row.match(/hwnd=(\d+)/)[1])
        return form.hwnd
      }
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

test('password fields are redacted and clipboard fallback is opt-in', { skip: process.platform !== 'win32' }, async () => {
  const form = startForm()
  const host = createHost({ script: hostScript, timeoutMs: 30000 })
  try {
    const hwnd = await waitForForm(host, form)
    assert.ok(hwnd > 0, 'test form window did not appear')

    const tree = await host.enqueue('observe.tree', { hwnd, maxNodes: 80 })
    assert.ok(!tree.text.includes('SECRET-PWD-999'), 'password leaked in the tree')
    assert.ok(tree.text.includes('[password redacted]'), 'password field was not marked')
    assert.ok(tree.text.includes('hello-normal'), 'plain text disappeared')

    await assert.rejects(host.enqueue('observe.gettext', { hwnd, name: 'SECRET-PWD-999' }), /redacted/)

    const buffered = host.enqueue('observe.gettext', { hwnd, name: 'hello-normal' })
    await assert.rejects(buffered, /no TextPattern/)
  } finally {
    await stopForm(host, form)
    await host.dispose()
  }
})

test('password gettext with clipboard=true still refuses the field', { skip: process.platform !== 'win32' }, async () => {
  const form = startForm()
  const host = createHost({ script: hostScript, timeoutMs: 30000 })
  try {
    const hwnd = await waitForForm(host, form)
    assert.ok(hwnd > 0)
    await assert.rejects(host.enqueue('observe.gettext', { hwnd, name: 'SECRET-PWD-999', clipboard: true }), /redacted/)
  } finally {
    await stopForm(host, form)
    await host.dispose()
  }
})
