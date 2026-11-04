import { test } from 'node:test'
import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import zlib from 'node:zlib'
import { spawnSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'

const pluginDir = path.join(path.dirname(fileURLToPath(import.meta.url)), '..')
const helper = path.join(pluginDir, 'lib', 'scripts', 'collect-attachment-refs.mjs')
const pruneScript = path.join(pluginDir, '..', '..', 'scripts', 'prune-attachments.ps1')
const A = 'a'.repeat(64)
const B = 'b'.repeat(64)
const C = 'c'.repeat(64)

function writeObject(home, hash, bytes, ageHours) {
  const dir = path.join(home, 'attachments', 'v1', 'objects', hash.slice(0, 2))
  fs.mkdirSync(dir, { recursive: true })
  const file = path.join(dir, hash)
  fs.writeFileSync(file, bytes)
  const time = new Date(Date.now() - ageHours * 60 * 60 * 1000)
  fs.utimesSync(file, time, time)
  return file
}

function makeHome(referenced = true) {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'dsh-cu-prune-'))
  const sessions = path.join(home, 'sessions', 's1')
  fs.mkdirSync(sessions, { recursive: true })
  const payload = referenced
    ? JSON.stringify({ attachmentId: `sha256:${A}` })
    : JSON.stringify({ text: 'no attachments here' })
  fs.writeFileSync(path.join(sessions, 'session.v4.jsonl.zstd'), zlib.zstdCompressSync(Buffer.from(payload)))
  const fileA = writeObject(home, A, 'A', 48)
  const fileB = writeObject(home, B, 'B', 48)
  const fileC = writeObject(home, C, 'C', 0)
  fs.mkdirSync(path.join(home, 'attachments', 'v1', 'file-objects'), { recursive: true })
  fs.writeFileSync(path.join(home, 'attachments', 'v1', 'file-objects', 'keep.bin'), 'keep')
  return { home, fileA, fileB, fileC }
}

function run(script, args) {
  const result = spawnSync('powershell.exe', ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', script, ...args], { encoding: 'utf8' })
  return { status: result.status, stdout: result.stdout.trim(), stderr: result.stderr.trim() }
}

test('attachment reference collector decompresses zstd sessions and finds sha256 refs', () => {
  const { home } = makeHome(true)
  try {
    const result = spawnSync(process.execPath, [helper, '--dsh-home', home], { encoding: 'utf8' })
    assert.equal(result.status, 0, result.stderr)
    const parsed = JSON.parse(result.stdout)
    assert.deepEqual(parsed.refs, [A])
    assert.equal(parsed.sessions, 1)
  } finally {
    fs.rmSync(home, { recursive: true, force: true })
  }
})

test('prune dry-run deletes nothing and apply removes only old unreferenced objects', () => {
  const { home, fileA, fileB, fileC } = makeHome(true)
  try {
    const dry = run(pruneScript, ['-DshHome', home, '-OlderThanDays', '1', '-Json'])
    assert.equal(dry.status, 0, dry.stderr)
    const dryReport = JSON.parse(dry.stdout)
    assert.equal(dryReport.dryRun, true)
    assert.equal(dryReport.referenced, 1)
    assert.equal(dryReport.candidates, 1)
    assert.equal(dryReport.deleted, 0)
    assert.ok(fs.existsSync(fileA) && fs.existsSync(fileB) && fs.existsSync(fileC))

    const applied = run(pruneScript, ['-DshHome', home, '-OlderThanDays', '1', '-Apply', '-Force', '-Json'])
    assert.equal(applied.status, 0, applied.stderr)
    const report = JSON.parse(applied.stdout)
    assert.equal(report.deleted, 1)
    assert.equal(fs.existsSync(fileA), true, 'referenced object was deleted')
    assert.equal(fs.existsSync(fileB), false, 'unreferenced old object was kept')
    assert.equal(fs.existsSync(fileC), true, 'new object was deleted')
    assert.equal(fs.existsSync(path.join(home, 'attachments', 'v1', 'file-objects', 'keep.bin')), true)

    const again = run(pruneScript, ['-DshHome', home, '-OlderThanDays', '1', '-Apply', '-Force', '-Json'])
    assert.equal(again.status, 0, again.stderr)
    assert.equal(JSON.parse(again.stdout).deleted, 0)
  } finally {
    fs.rmSync(home, { recursive: true, force: true })
  }
})

test('prune fails closed when sessions exist but no references were found', () => {
  const { home, fileB } = makeHome(false)
  try {
    const result = run(pruneScript, ['-DshHome', home, '-OlderThanDays', '7', '-Apply', '-Json'])
    assert.notEqual(result.status, 0)
    assert.match(result.stderr + result.stdout, /no attachment references/)
    assert.equal(fs.existsSync(fileB), true)
  } finally {
    fs.rmSync(home, { recursive: true, force: true })
  }
})

test('prune fails closed and deletes nothing when a session cannot be decompressed', () => {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'dsh-cu-prune-corrupt-'))
  try {
    const sessions = path.join(home, 'sessions')
    fs.mkdirSync(path.join(sessions, 'valid'), { recursive: true })
    fs.mkdirSync(path.join(sessions, 'corrupt'), { recursive: true })
    fs.writeFileSync(path.join(sessions, 'valid', 'session.v4.jsonl.zstd'), zlib.zstdCompressSync(Buffer.from(JSON.stringify({ attachmentId: `sha256:${B}` }))))
    fs.writeFileSync(path.join(sessions, 'corrupt', 'session.v4.jsonl.zstd'), Buffer.from('not-a-zstd-session'))
    const fileA = writeObject(home, A, 'A', 48)
    const fileB = writeObject(home, B, 'B', 48)
    const result = run(pruneScript, ['-DshHome', home, '-OlderThanDays', '7', '-Apply', '-Json'])
    assert.notEqual(result.status, 0, 'prune must fail closed on a corrupt session')
    assert.match(result.stderr + result.stdout, /reference scan had errors/)
    assert.equal(fs.existsSync(fileA), true, 'object referenced only by a corrupt session was deleted')
    assert.equal(fs.existsSync(fileB), true, 'referenced object was deleted')
  } finally {
    fs.rmSync(home, { recursive: true, force: true })
  }
})

