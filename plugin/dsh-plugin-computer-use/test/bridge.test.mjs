import { test } from 'node:test'
import assert from 'node:assert/strict'
import path from 'node:path'
import fs from 'node:fs'
import os from 'node:os'
import { spawnSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'
import { createHost } from '../lib/bridge.js'

const hostScript = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', 'lib', 'scripts', 'bridge.ps1')

function newHost(options = {}) {
  return createHost({ script: hostScript, timeoutMs: 30000, ...options })
}

test('host lists windows and monitors', async () => {
  const host = newHost()
  try {
    const result = await host.enqueue('windows.list', { limit: 5 })
    assert.match(result.text, /hwnd=\d+ pid=\d+/)
    assert.match(result.text, /monitor=0 \d+x\d+/)
    assert.match(result.text, /monitor=0 \d+x\d+ at -?\d+,-?\d+ dpi=\d+ \d+%/)
  } finally {
    host.dispose()
  }
})

test('window list and window info report the same DWM frame geometry', async () => {
  const host = newHost()
  try {
    const list = await host.enqueue('windows.list', { limit: 20 })
    const rows = list.text.split('\n').filter((line) => line.startsWith('hwnd='))
    let compared = false
    for (const row of rows.slice(0, 10)) {
      const hwnd = Number(row.match(/hwnd=(\d+)/)[1])
      let info
      try { info = await host.enqueue('windows.info', { hwnd }) } catch { continue }
      const fromRow = row.match(/ (-?\d+),(-?\d+) (\d+)x(\d+)/)
      const fromInfo = info.text.match(/ (-?\d+),(-?\d+) (\d+)x(\d+)/)
      assert.ok(fromRow && fromInfo, 'geometry missing from list/info')
      assert.deepEqual(fromRow.slice(1).map(Number), fromInfo.slice(1).map(Number))
      compared = true
      break
    }
    assert.ok(compared, 'no live window could be compared')
  } finally {
    host.dispose()
  }
})

test('bridge -SelfTest covers virtual-desktop mapping including negative origins', () => {
  const result = spawnSync('powershell.exe', [
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', hostScript, '-SelfTest',
  ], { encoding: 'utf8', timeout: 60000 })
  assert.equal(result.status, 0, result.stderr || result.stdout)
  assert.match(result.stdout, /SELFTEST OK/)
  assert.match(result.stdout, /PASS negative-origin 15705,30368/)
  assert.match(result.stdout, /INFO dpi=\d+/)
})

test('cursor operation reports a position', async () => {
  const host = newHost()
  try {
    const result = await host.enqueue('input.cursor', {})
    assert.match(result.text, /cursor -?\d+,-?\d+/)
  } finally {
    host.dispose()
  }
})

test('screenshot writes a real PNG', async () => {
  const host = newHost()
  try {
    const result = await host.enqueue('screenshot', { maxWidth: 320 })
    assert.ok(result.path.endsWith('.png'))
    const bytes = fs.readFileSync(result.path)
    assert.equal(bytes[0], 0x89)
    assert.equal(bytes[1], 0x50)
    assert.ok(result.width <= 320)
  } finally {
    host.dispose()
  }
})

test('unknown op is rejected without killing the host', async () => {
  const host = newHost()
  try {
    await assert.rejects(host.enqueue('does.not.exist', {}), /unknown op/)
    const result = await host.enqueue('input.cursor', {})
    assert.match(result.text, /^cursor /)
  } finally {
    host.dispose()
  }
})

test('host restarts after dispose', async () => {
  const first = newHost()
  await first.enqueue('input.cursor', {})
  first.dispose()
  const second = newHost()
  try {
    const result = await second.enqueue('input.cursor', {})
    assert.match(result.text, /^cursor /)
  } finally {
    second.dispose()
  }
})

test('timeout restarts the host and the next call recovers', async () => {
  const host = newHost({ timeoutMs: 1500 })
  try {
    await assert.rejects(host.enqueue('input.wait', { ms: 5000 }), /timed out/)
    const result = await host.enqueue('input.cursor', {})
    assert.match(result.text, /^cursor /)
  } finally {
    host.dispose()
  }
})

test('abort signal cancels in flight work and the host recovers', async () => {
  const host = newHost()
  try {
    const controller = new AbortController()
    const pending = host.enqueue('input.wait', { ms: 5000 }, { signal: controller.signal })
    setTimeout(() => controller.abort(), 100)
    await assert.rejects(pending, /aborted/)
    const result = await host.enqueue('input.cursor', {})
    assert.match(result.text, /^cursor /)
  } finally {
    host.dispose()
  }
})

test('limits reject instead of slicing windows', async () => {
  const host = newHost()
  try {
    const zero = await host.enqueue('windows.list', { limit: 0 })
    assert.equal(zero.text.split('\n').filter((line) => line.startsWith('hwnd=')).length, 0)
    await assert.rejects(host.enqueue('windows.list', { limit: -1 }), /limit must be >= 0/)
  } finally {
    host.dispose()
  }
})

test('capture guards reject regions outside the virtual screen', async () => {
  const host = newHost()
  try {
    await assert.rejects(host.enqueue('screenshot', { region: '5000,5000,100,100' }), /outside the virtual screen/)
  } finally {
    host.dispose()
  }
})

test('screenshot path cannot escape the computer-use temp dir', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'dsh-cu-shot-'))
  const host = newHost({ tempDir: dir })
  try {
    const outside = path.join(os.tmpdir(), `dsh-cu-outside-${process.pid}.png`)
    await assert.rejects(host.enqueue('screenshot', { path: outside, maxWidth: 200 }), /must be inside/)
    assert.equal(fs.existsSync(outside), false)
    const inside = path.join(dir, 'inside.png')
    const result = await host.enqueue('screenshot', { path: inside, maxWidth: 200 })
    assert.ok(fs.existsSync(inside))
    assert.equal(result.path.toLowerCase(), inside.toLowerCase())
  } finally {
    host.dispose()
    fs.rmSync(dir, { recursive: true, force: true })
  }
})

test('launch deny-list blocks interpreters and exotic schemes', async () => {
  const host = newHost()
  try {
    await assert.rejects(host.enqueue('launch', { target: 'cmd.exe' }), /blocked by policy/)
    await assert.rejects(host.enqueue('launch', { target: 'file:///etc/passwd' }), /URL scheme is not allowed/)
  } finally {
    host.dispose()
  }
})
