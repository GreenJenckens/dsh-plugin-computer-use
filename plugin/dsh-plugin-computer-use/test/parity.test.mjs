import { test } from 'node:test'
import assert from 'node:assert/strict'
import path from 'node:path'
import fs from 'node:fs'
import { fileURLToPath, pathToFileURL } from 'node:url'

const pluginDir = path.join(path.dirname(fileURLToPath(import.meta.url)), '..')
const bridgeText = fs.readFileSync(path.join(pluginDir, 'lib', 'scripts', 'bridge.ps1'), 'utf8')

function loadPlugin() {
  const tools = new Map()
  const ctx = {
    get: () => undefined,
    on() {},
    tools: { register(tool) { tools.set(tool.name, tool) } },
  }
  return { ctx, tools }
}

test('plugin registers exactly one dispatcher tool with a timeout', async () => {
  const mod = await import(pathToFileURL(path.join(pluginDir, 'lib', 'index.js')).href)
  const { ctx, tools } = loadPlugin()
  mod.apply(ctx, {})
  assert.deepEqual([...tools.keys()], ['computer'])
  const tool = tools.get('computer')
  assert.equal(tool.parameters.required[0], 'action')
  assert.ok(tool.timeoutMs > 0)
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
    assert.ok(list.includes(prefix), `missing ${prefix}`)
  }
  for (const action of ['screenshot', 'ocr', 'launch']) {
    assert.ok(list.includes(action), `missing ${action}`)
  }
})

test('schema parameters and the PowerShell dispatcher stay in parity', async () => {
  const mod = await import(pathToFileURL(path.join(pluginDir, 'lib', 'index.js')).href)
  const { ctx, tools } = loadPlugin()
  mod.apply(ctx, {})
  const properties = Object.keys(tools.get('computer').parameters.properties)
  // act.sequence is executed in JS and never reaches the PowerShell dispatcher.
  const jsOnly = new Set(['steps'])
  const missing = properties.filter((name) => !jsOnly.has(name) && !bridgeText.includes(`'${name}'`) && !bridgeText.includes(`"${name}"`))
  assert.deepEqual(missing, [], `parameters not read by bridge.ps1: ${missing.join(', ')}`)
})

test('schema stays within the v0.4 budget and keeps the action surface', async () => {
  const mod = await import(pathToFileURL(path.join(pluginDir, 'lib', 'index.js')).href)
  const { ctx, tools } = loadPlugin()
  mod.apply(ctx, {})
  const parameters = tools.get('computer').parameters
  assert.ok(Buffer.byteLength(JSON.stringify(parameters)) <= 4300)
  assert.equal(Object.keys(parameters.properties).length, 46)
  assert.equal(parameters.properties.action.description.split('|').length, 40)
})
