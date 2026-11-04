import { pathToFileURL } from 'node:url'
import path from 'node:path'
import os from 'node:os'
import fs from 'node:fs'

const pluginDir = process.argv[2]
if (!pluginDir) throw new Error('usage: node smoke.mjs <plugin-dir>')

const failures = []
const check = (condition, message) => { if (!condition) failures.push(message) }
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms))

// Keep smoke's host and markers away from the live DSH artifacts. A failed
// smoke run must never look like a real mount or delete another session's PNGs.
const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'dsh-cu-smoke-'))
const markerDir = fs.mkdtempSync(path.join(os.tmpdir(), 'dsh-cu-smoke-markers-'))

const tools = new Map()
const disposers = []
const ctx = {
  get(name) {
    if (name === 'llm') return { resolveModelInfo: async () => ({ inputModalities: ['text', 'image'] }) }
    if (name === 'attachments') {
      return {
        saveImage: async ({ data, mediaType, name }) => ({
          attachmentId: 'att_test', mediaType, bytes: data.length, width: 1, height: 1, name,
        }),
      }
    }
    return undefined
  },
  on(event, callback) { if (event === 'dispose') disposers.push(callback) },
  tools: { register(tool) { tools.set(tool.name, tool) } },
}

const mod = await import(pathToFileURL(path.join(pluginDir, 'lib', 'index.js')).href)
const titles = await import(pathToFileURL(path.join(pluginDir, 'lib', 'titles.js')).href)
const isCalculator = titles.isCalculatorTitle
mod.apply(ctx, { tempDir, markerDir })
check([...tools.keys()].join(',') === 'computer', 'expected exactly one tool named computer')

const exec = { agent: { options: { provider: 'p', model: 'm' }, session: { requestHeader: () => ({ config: {} }) } } }
const call = async (action, args = {}) => {
  const tool = tools.get('computer')
  const value = await tool.execute({ action, ...args }, exec)
  return { value, blocks: tool.output.render({ action, ...args }, value) }
}

const listRows = async () => {
  const result = await call('windows.list', { limit: 120 })
  return result.value.text.split('\n')
    .filter((line) => line.startsWith('hwnd='))
    .map((line) => ({ hwnd: Number(line.match(/hwnd=(\d+)/)[1]), line }))
}

let target = 0
try {
  const before = new Set((await listRows()).map((row) => row.hwnd))
  const list = await call('windows.list', { limit: 10 })
  check(/hwnd=\d+ pid=\d+/.test(list.value.text), 'windows.list returned no window rows')

  const launch = await call('launch', { target: 'calc.exe', waitMs: 1500 })
  check(/^launched "calc.exe"/.test(launch.value.text), `unexpected launch text: ${launch.value.text}`)

  // Only a window that did not exist before this run is ours. A pre-existing
  // Calculator belongs to the user and must not be touched or closed.
  for (let attempt = 0; attempt < 24 && target === 0; attempt++) {
    const row = (await listRows()).find((entry) => !before.has(entry.hwnd) && isCalculator(entry.line))
    if (row) target = row.hwnd
    else await sleep(250)
  }
  check(target > 0, 'calculator window not found after launch')

  if (target > 0) {
    for (const id of ['num7Button', 'multiplyButton', 'num8Button', 'equalButton']) {
      const result = await call('act.invoke', { hwnd: target, automationId: id })
      check(/invoked/.test(result.value.text), `act.invoke ${id} failed: ${result.value.text}`)
    }

    const resultLine = await call('observe.tree', { hwnd: target, automationId: 'CalculatorResults' })
    check(/\b56\b/.test(resultLine.value.text), `calculator result is not 56: ${resultLine.value.text}`)

    const shot = await call('screenshot', { hwnd: target, maxWidth: 500 })
    check(typeof shot.value.path === 'string' && shot.value.path.endsWith('.png'), 'screenshot returned no png path')
    check(shot.blocks.some((block) => block.type === 'image'), 'screenshot returned no image block')
  }
} catch (error) {
  failures.push(`smoke threw: ${error.message}`)
} finally {
  if (target > 0) {
    try { await call('windows.close', { hwnd: target }) } catch (error) { failures.push(`close failed: ${error.message}`) }
    const deadline = Date.now() + 5000
    let stillVisible = true
    while (Date.now() < deadline) {
      const rows = await listRows().catch(() => [])
      stillVisible = rows.some((row) => row.hwnd === target)
      if (!stillVisible) break
      await sleep(200)
    }
    if (stillVisible) failures.push(`calculator hwnd=${target} is still visible after close`)
  }
  for (const dispose of disposers) {
    try { await dispose() } catch {}
  }
}

if (failures.length > 0) {
  console.error('FAILURES:\n- ' + failures.join('\n- '))
  console.error(`artifacts kept in ${tempDir}`)
  process.exitCode = 1
} else {
  try { fs.rmSync(tempDir, { recursive: true, force: true }) } catch {}
  console.log('SMOKE OK: calculator 7x8=56, inline screenshot, own window closed, no leftovers')
  process.exitCode = 0
}
try { fs.rmSync(markerDir, { recursive: true, force: true }) } catch {}
