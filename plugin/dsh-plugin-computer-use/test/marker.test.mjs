import { test } from 'node:test'
import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { pathToFileURL } from 'node:url'
import { fileURLToPath } from 'node:url'

const pluginDir = path.join(path.dirname(fileURLToPath(import.meta.url)), '..')

function loadPlugin() {
  const tools = new Map()
  const disposers = []
  const ctx = {
    get: () => undefined,
    on(event, callback) { if (event === 'dispose') disposers.push(callback) },
    tools: { register(tool) { tools.set(tool.name, tool) } },
  }
  return { ctx, tools, disposers }
}

test('non-Electron imports never create or overwrite the generic mount marker', async () => {
  const markerDir = fs.mkdtempSync(path.join(os.tmpdir(), 'dsh-cu-marker-test-'))
  const sentinel = JSON.stringify({ pid: 999999, version: '0.0.0', buildHash: 'sentinel', electron: true })
  fs.writeFileSync(path.join(markerDir, 'mounted.json'), sentinel)
  try {
    const mod = await import(pathToFileURL(path.join(pluginDir, 'lib', 'index.js')).href)
    const { ctx, disposers } = loadPlugin()
    mod.apply(ctx, { markerDir })
    assert.equal(fs.readFileSync(path.join(markerDir, 'mounted.json'), 'utf8'), sentinel)
    const perPid = path.join(markerDir, `mounted-${process.pid}.json`)
    assert.ok(fs.existsSync(perPid), 'per-pid marker was not written')
    const marker = JSON.parse(fs.readFileSync(perPid, 'utf8'))
    assert.equal(marker.pid, process.pid)
    assert.equal(marker.electron, false)
    assert.equal(typeof marker.version, 'string')
    for (const dispose of disposers) await dispose()
  } finally {
    fs.rmSync(markerDir, { recursive: true, force: true })
  }
})

test('stale dead per-pid markers are pruned, live markers are kept', async () => {
  const markerDir = fs.mkdtempSync(path.join(os.tmpdir(), 'dsh-cu-marker-prune-'))
  try {
    const stale = path.join(markerDir, 'mounted-999998.json')
    fs.writeFileSync(stale, JSON.stringify({ pid: 999998, version: '0.0.0', buildHash: 'x', electron: false }))
    const old = new Date(Date.now() - 60 * 60 * 1000)
    fs.utimesSync(stale, old, old)
    const mod = await import(pathToFileURL(path.join(pluginDir, 'lib', 'index.js')).href)
    const { ctx, disposers } = loadPlugin()
    mod.apply(ctx, { markerDir })
    assert.equal(fs.existsSync(stale), false, 'stale dead marker was not pruned')
    assert.ok(fs.existsSync(path.join(markerDir, `mounted-${process.pid}.json`)))
    for (const dispose of disposers) await dispose()
  } finally {
    fs.rmSync(markerDir, { recursive: true, force: true })
  }
})
