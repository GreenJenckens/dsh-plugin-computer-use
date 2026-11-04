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

function edgePath() {
  const roots = [process.env['PROGRAMFILES(X86)'], process.env.PROGRAMFILES, 'C:\\Program Files (x86)', 'C:\\Program Files'].filter(Boolean)
  for (const root of roots) {
    const candidate = path.join(root, 'Microsoft', 'Edge', 'Application', 'msedge.exe')
    if (fs.existsSync(candidate)) return candidate
  }
  return ''
}

const edge = edgePath()
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms))

test('Chromium page password fields do not leak plaintext through UIA, OCR or selectors', { skip: process.platform !== 'win32' || !edge, timeout: 45000 }, async () => {
  const id = `${process.pid}_${Date.now()}_${Math.random().toString(36).slice(2, 7)}`
  const title = `CUC_EDGE_PWD_${id}`
  const secret = `SECRET-EDGE-${id}`
  const profile = fs.mkdtempSync(path.join(os.tmpdir(), 'dsh-cu-edge-profile-'))
  const htmlPath = path.join(os.tmpdir(), `dsh-cu-edge-${id}.html`)
  fs.writeFileSync(htmlPath, `<!doctype html><html><head><meta charset="utf-8"><title>${title}</title></head>
<body style="font:16px Segoe UI;padding:20px"><h1>${title}</h1>
<label>User <input id="plain" value="hello-edge"></label><br><br>
<label>Password <input id="pwd" type="password" value="${secret}"></label>
<p>visible-marker-text-123</p></body></html>`)

  const child = spawn(edge, [
    `--app=${pathToFileURL(htmlPath).href}`,
    `--user-data-dir=${profile}`,
    '--no-first-run', '--no-default-browser-check', '--disable-sync', '--disable-extensions',
    '--disable-component-update', '--disable-background-networking', '--disable-domain-reliability',
    '--force-renderer-accessibility', '--window-size=900,620', '--window-position=60,60', '--noerrdialogs',
  ], { stdio: 'ignore' })

  const host = createHost({ script: hostScript, timeoutMs: 30000 })
  let hwnd = 0
  try {
    for (let attempt = 0; attempt < 60 && hwnd === 0; attempt++) {
      const list = await host.enqueue('windows.list', { limit: 120 })
      const row = list.text.split('\n').find((line) => line.startsWith('hwnd=') && line.includes(title))
      if (row) hwnd = Number(row.match(/hwnd=(\d+)/)[1])
      else await sleep(200)
    }
    assert.ok(hwnd > 0, 'Edge window did not appear')

    let tree = ''
    for (let attempt = 0; attempt < 12; attempt++) {
      tree = (await host.enqueue('observe.tree', { hwnd, maxNodes: 500 })).text
      if (tree.includes('Document') && tree.includes('hello-edge')) break
      await sleep(250)
    }
    assert.ok(tree.includes('hello-edge'), 'plain input was not visible in the tree')
    assert.ok(!tree.includes(secret), 'password leaked in the UIA tree')
    assert.ok(/\[password redacted\]|•/.test(tree), 'password field was neither redacted nor masked')

    const value = await host.enqueue('observe.getvalue', { hwnd, automationId: 'pwd' })
    assert.ok(!value.text.includes(secret), 'password leaked through getvalue')
    assert.match(value.text, /redacted/)

    await assert.rejects(host.enqueue('observe.gettext', { hwnd, automationId: 'pwd' }), /redacted/)
    const byName = await host.enqueue('observe.tree', { hwnd, name: secret })
    assert.ok(!byName.text.includes(secret), 'password leaked through a name selector')
    assert.equal(byName.count, 0, 'password value unexpectedly matched an element name')

    const ocr = await host.enqueue('ocr', { hwnd, maxLines: 80 })
    assert.ok(!ocr.text.includes(secret), 'password leaked through OCR')
  } finally {
    if (hwnd) { try { await host.enqueue('windows.close', { hwnd }) } catch {} }
    try { child.kill() } catch {}
    // Kill only Edge processes that use this run's private profile.
    const escaped = profile.replace(/'/g, "''")
    spawnSync('powershell.exe', ['-NoProfile', '-Command',
      `Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" | Where-Object { $_.CommandLine -like '*${escaped}*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }`],
    { stdio: 'ignore', windowsHide: true })
    await host.dispose()
    for (const delay of [0, 300, 800]) {
      if (delay) await sleep(delay)
      try { fs.rmSync(profile, { recursive: true, force: true }); break } catch {}
    }
    try { fs.rmSync(htmlPath, { force: true }) } catch {}
  }
})
