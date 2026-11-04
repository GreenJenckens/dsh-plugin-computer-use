import fs from 'node:fs'
import path from 'node:path'
import zlib from 'node:zlib'

function parseArgs(argv) {
  const out = { home: process.env.DSH_HOME || path.join(process.env.USERPROFILE || process.env.HOME || '.', '.dsh'), scans: [] }
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === '--dsh-home' && argv[i + 1]) out.home = argv[++i]
    else if (argv[i] === '--scan' && argv[i + 1]) out.scans.push(argv[++i])
  }
  if (out.scans.length === 0) out.scans = ['sessions', 'storages']
  return out
}

function walk(dir, files) {
  let entries
  try { entries = fs.readdirSync(dir, { withFileTypes: true }) } catch { return }
  for (const entry of entries) {
    const full = path.join(dir, entry.name)
    if (entry.isDirectory()) walk(full, files)
    else if (entry.isFile()) files.push(full)
  }
}

const args = parseArgs(process.argv.slice(2))
const home = path.resolve(args.home)
const refs = new Set()
const errors = []
let files = 0
let sessions = 0
const regex = /sha256:([0-9a-f]{64})/gi

for (const scan of args.scans) {
  const root = path.join(home, scan)
  const found = []
  walk(root, found)
  for (const file of found) {
    files++
    const ext = path.extname(file).toLowerCase()
    if (!['.zstd', '.jsonl', '.json'].includes(ext)) continue
    try {
      let text
      if (ext === '.zstd') {
        if (typeof zlib.zstdDecompressSync !== 'function') throw new Error('node:zlib.zstdDecompressSync is unavailable')
        text = zlib.zstdDecompressSync(fs.readFileSync(file)).toString('utf8')
      } else {
        text = fs.readFileSync(file, 'utf8')
      }
      sessions++
      for (const match of text.matchAll(regex)) refs.add(match[1].toLowerCase())
    } catch (error) {
      errors.push({ file, error: error.message })
    }
  }
}

process.stdout.write(JSON.stringify({
  ok: errors.length === 0,
  home,
  scanned: args.scans,
  files,
  sessions,
  refs: [...refs].sort(),
  errors,
}) + '\n')
