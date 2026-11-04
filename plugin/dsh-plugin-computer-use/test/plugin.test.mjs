import { test } from 'node:test'
import assert from 'node:assert/strict'
import path from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'

const pluginDir = path.join(path.dirname(fileURLToPath(import.meta.url)), '..')

function loadPlugin() {
  const tools = new Map()
  const ctx = {
    get: () => undefined,
    on() {},
    tools: { register(tool) { tools.set(tool.name, tool) } },
  }
  return { ctx, tools }
}

test('plugin registers exactly one dispatcher tool', async () => {
  const mod = await import(pathToFileURL(path.join(pluginDir, 'lib', 'index.js')).href)
  const { ctx, tools } = loadPlugin()
  mod.apply(ctx, {})
  assert.deepEqual([...tools.keys()], ['computer'])
  const tool = tools.get('computer')
  assert.equal(tool.parameters.required[0], 'action')
  assert.ok(tool.parameters.properties.action)
  assert.ok(tool.parameters.properties.hwnd)
  assert.ok(tool.parameters.properties.ocrScale)
  assert.equal(typeof tool.output.render, 'function')
})

test('unknown action fails before touching the host', async () => {
  const mod = await import(pathToFileURL(path.join(pluginDir, 'lib', 'index.js')).href)
  const { ctx, tools } = loadPlugin()
  mod.apply(ctx, {})
  const tool = tools.get('computer')
  await assert.rejects(tool.execute({ action: 'nope.nope' }, {}), /unknown action/)
})

test('action vocabulary covers every bridge op family', async () => {
  const mod = await import(pathToFileURL(path.join(pluginDir, 'lib', 'index.js')).href)
  const { ctx, tools } = loadPlugin()
  mod.apply(ctx, {})
  const list = tools.get('computer').parameters.properties.action.description
  for (const prefix of ['windows.', 'observe.', 'act.', 'input.']) {
    assert.ok(list.includes(prefix + 'list') || list.includes(prefix), `missing ${prefix}`)
  }
  for (const action of ['screenshot', 'ocr', 'launch']) {
    assert.ok(list.includes(action), `missing ${action}`)
  }
})

