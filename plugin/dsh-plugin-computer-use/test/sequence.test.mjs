import { test } from 'node:test'
import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { pathToFileURL } from 'node:url'
import { fileURLToPath } from 'node:url'

const pluginDir = path.join(path.dirname(fileURLToPath(import.meta.url)), '..')

async function load() {
  const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'dsh-cu-sequence-'))
  const tools = new Map()
  const disposers = []
  const ctx = {
    get: () => undefined,
    on(event, callback) { if (event === 'dispose') disposers.push(callback) },
    tools: { register(tool) { tools.set(tool.name, tool) } },
  }
  const mod = await import(pathToFileURL(path.join(pluginDir, 'lib', 'index.js')).href)
  mod.apply(ctx, { tempDir: temp, markerDir: temp, timeoutMs: 30000 })
  return { tool: tools.get('computer'), temp, disposers }
}

async function dispose(disposers) {
  for (const disposer of disposers) { try { await disposer() } catch {} }
}

test('act.sequence runs multiple steps in one call and reports each one', async () => {
  const { tool, temp, disposers } = await load()
  try {
    const result = await tool.execute({
      action: 'act.sequence',
      steps: [
        { action: 'windows.list', limit: 3 },
        { action: 'input.cursor' },
      ],
    }, {})
    assert.match(result.text, /sequence ok \(2 steps\)/)
    assert.match(result.text, /1\. windows\.list:/)
    assert.match(result.text, /2\. input\.cursor:/)
  } finally {
    await dispose(disposers)
    fs.rmSync(temp, { recursive: true, force: true })
  }
})

test('act.sequence stops at the first failure and says which step failed', async () => {
  const { tool, temp, disposers } = await load()
  try {
    await assert.rejects(
      tool.execute({
        action: 'act.sequence',
        steps: [
          { action: 'windows.list', limit: 3 },
          { action: 'act.invoke', hwnd: 999999, name: 'missing' },
          { action: 'input.cursor' },
        ],
      }, {}),
      /sequence stopped at step 2 \(act\.invoke\).*completed 1 step/,
    )
  } finally {
    await dispose(disposers)
    fs.rmSync(temp, { recursive: true, force: true })
  }
})

test('act.sequence validates its shape without touching the host', async () => {
  const { tool, temp, disposers } = await load()
  try {
    await assert.rejects(tool.execute({ action: 'act.sequence', steps: [] }, {}), /1-8 steps/)
    await assert.rejects(tool.execute({ action: 'act.sequence', steps: Array.from({ length: 9 }, () => ({ action: 'input.cursor' })) }, {}), /1-8 steps/)
    await assert.rejects(tool.execute({ action: 'act.sequence', steps: [{ action: 'act.sequence', steps: [] }] }, {}), /cannot be nested/)
    await assert.rejects(tool.execute({ action: 'act.sequence', steps: [{ action: 'nope.nope' }] }, {}), /unknown action/)
  } finally {
    await dispose(disposers)
    fs.rmSync(temp, { recursive: true, force: true })
  }
})
