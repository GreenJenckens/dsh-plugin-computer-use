import { test } from 'node:test'
import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { createHost } from '../lib/bridge.js'

const hostScript = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', 'lib', 'scripts', 'bridge.ps1')

test('host start enforces the temp PNG TTL and keeps non-PNG files', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'dsh-cu-retention-'))
  const host = createHost({ script: hostScript, tempDir: dir, retentionHours: 1, maxFiles: 10, timeoutMs: 30000 })
  try {
    const oldPng = path.join(dir, 'old.png')
    const freshPng = path.join(dir, 'fresh.png')
    fs.writeFileSync(oldPng, 'old')
    fs.writeFileSync(freshPng, 'fresh')
    fs.writeFileSync(path.join(dir, 'audit.jsonl'), '{}\n')
    fs.writeFileSync(path.join(dir, 'notes.txt'), 'keep')
    const old = new Date(Date.now() - 3 * 60 * 60 * 1000)
    fs.utimesSync(oldPng, old, old)

    await host.enqueue('input.cursor', {})
    assert.equal(fs.existsSync(oldPng), false, 'expired PNG was not removed')
    assert.equal(fs.existsSync(freshPng), true, 'fresh PNG was removed')
    assert.equal(fs.existsSync(path.join(dir, 'audit.jsonl')), true)
    assert.equal(fs.existsSync(path.join(dir, 'notes.txt')), true)
  } finally {
    await host.dispose()
    fs.rmSync(dir, { recursive: true, force: true })
  }
})

test('host start keeps only the newest maxFiles PNGs', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'dsh-cu-retention-count-'))
  const host = createHost({ script: hostScript, tempDir: dir, retentionHours: 24, maxFiles: 2, timeoutMs: 30000 })
  try {
    for (let i = 0; i < 5; i++) {
      const file = path.join(dir, `shot-${i}.png`)
      fs.writeFileSync(file, String(i))
      const time = new Date(Date.now() - (10 - i) * 60 * 1000)
      fs.utimesSync(file, time, time)
    }
    await host.enqueue('input.cursor', {})
    const left = fs.readdirSync(dir).filter((name) => name.endsWith('.png')).sort()
    assert.deepEqual(left, ['shot-3.png', 'shot-4.png'])
  } finally {
    await host.dispose()
    fs.rmSync(dir, { recursive: true, force: true })
  }
})
