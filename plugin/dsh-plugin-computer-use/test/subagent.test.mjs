import { test } from 'node:test'
import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { pathToFileURL } from 'node:url'
import { fileURLToPath } from 'node:url'

const pluginDir = path.join(path.dirname(fileURLToPath(import.meta.url)), '..')
const missingHost = 'C:\\definitely-missing\\dsh-cu-nope.exe'

async function load(config = {}) {
  const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'dsh-cu-subagent-'))
  const tools = new Map()
  const disposers = []
  const ctx = {
    get: () => undefined,
    on(event, callback) { if (event === 'dispose') disposers.push(callback) },
    tools: { register(tool) { tools.set(tool.name, tool) } },
  }
  const mod = await import(pathToFileURL(path.join(pluginDir, 'lib', 'index.js')).href)
  mod.apply(ctx, { powershell: missingHost, tempDir: temp, markerDir: temp, timeoutMs: 1000, ...config })
  return { tool: tools.get('computer'), temp, disposers }
}

async function dispose(disposers) {
  for (const disposer of disposers) {
    try { await disposer() } catch {}
  }
}

test('subagent depth >= 1 is denied before the host is contacted', async () => {
  const { tool, temp, disposers } = await load()
  try {
    for (const action of ['windows.list', 'screenshot', 'input.type', 'launch']) {
      await assert.rejects(
        tool.execute({ action, text: 'CANARY-SECRET-42', title: 'CANARY-TITLE' }, { agent: { session: { header: { delegationDepth: 1 } } } }),
        /disabled for subagent sessions/,
      )
    }
    const lines = fs.readFileSync(path.join(temp, 'denied.jsonl'), 'utf8').trim().split('\n')
    assert.equal(lines.length, 4)
    for (const line of lines) {
      const record = JSON.parse(line)
      assert.equal(record.reason, 'subagent-denied')
      assert.equal(record.ok, false)
      assert.equal(typeof record.depth, 'number')
      assert.deepEqual(Object.keys(record).sort(), ['action', 'at', 'depth', 'ok', 'reason'])
      assert.ok(!JSON.stringify(record).includes('CANARY'))
    }
  } finally {
    await dispose(disposers)
    fs.rmSync(temp, { recursive: true, force: true })
  }
})

test('origin=subagent and options.subagentDepth are also denied; depth 0 is allowed through to the host', async () => {
  const { tool, temp, disposers } = await load()
  try {
    await assert.rejects(
      tool.execute({ action: 'windows.list' }, { agent: { session: { header: { origin: 'subagent' } } } }),
      /disabled for subagent sessions/,
    )
    await assert.rejects(
      tool.execute({ action: 'windows.list' }, { agent: { options: { subagentDepth: 2 } } }),
      /disabled for subagent sessions/,
    )
    await assert.rejects(
      tool.execute({ action: 'windows.list' }, { agent: { session: { header: { delegationDepth: 0 } } } }),
      /cannot start the computer-use host/,
    )
    await assert.rejects(
      tool.execute({ action: 'windows.list' }, {}),
      /cannot start the computer-use host/,
    )
  } finally {
    await dispose(disposers)
    fs.rmSync(temp, { recursive: true, force: true })
  }
})

test('subagents:"allow" opts a child back in; schema is unchanged', async () => {
  const { tool, temp, disposers } = await load({ subagents: 'allow' })
  try {
    await assert.rejects(
      tool.execute({ action: 'windows.list' }, { agent: { session: { header: { delegationDepth: 1 } } } }),
      /cannot start the computer-use host/,
    )
    assert.equal(Object.keys(tool.parameters.properties).length, 48)
    assert.equal(tool.parameters.properties.action.description.split('|').length, 44)
  } finally {
    await dispose(disposers)
    fs.rmSync(temp, { recursive: true, force: true })
  }
})

test('tools.guard denies a child structurally before the tool body', async () => {
  const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'dsh-cu-guard-'))
  const guards = []
  const ctx = {
    get: () => undefined,
    on() {},
    tools: { register() {}, guard(callback) { guards.push(callback) } },
  }
  try {
    const mod = await import(pathToFileURL(path.join(pluginDir, 'lib', 'index.js')).href)
    mod.apply(ctx, { powershell: missingHost, tempDir: temp, markerDir: temp, timeoutMs: 1000 })
    assert.equal(guards.length, 1)
    const child = { name: 'computer', arguments: { action: 'screenshot' }, agent: { session: { header: { delegationDepth: 1 } } } }
    assert.match(guards[0](child), /disabled for subagent sessions/)
    assert.equal(guards[0]({ ...child, name: 'other' }), undefined)
    assert.equal(guards[0]({ ...child, agent: { session: { header: { delegationDepth: 0 } } } }), undefined)
    const lines = fs.readFileSync(path.join(temp, 'denied.jsonl'), 'utf8').trim().split('\n')
    assert.equal(lines.length, 1)
    assert.equal(JSON.parse(lines[0]).reason, 'subagent-denied')
  } finally {
    fs.rmSync(temp, { recursive: true, force: true })
  }
})
