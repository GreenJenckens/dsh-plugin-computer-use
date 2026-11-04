import fs from 'node:fs'
import path from 'node:path'
import crypto from 'node:crypto'
import { fileURLToPath } from 'node:url'

const here = path.dirname(fileURLToPath(import.meta.url))
const pluginDir = path.join(here, '..', 'plugin', 'dsh-plugin-computer-use')
const pkg = JSON.parse(fs.readFileSync(path.join(pluginDir, 'package.json'), 'utf8'))

const includeExact = new Set(['package.json', 'cordis.patch.yml', 'README.md', 'CHANGELOG.md', 'SECURITY.md'])
const files = []

function walk(dir, prefix = '') {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const rel = prefix ? `${prefix}/${entry.name}` : entry.name
    if (entry.isDirectory()) { walk(path.join(dir, entry.name), rel); continue }
    if (!entry.isFile()) continue
    if (rel.startsWith('lib/') || includeExact.has(rel)) files.push(rel)
  }
}
walk(pluginDir)
files.sort()

const lines = []
const map = {}
for (const rel of files) {
  const data = fs.readFileSync(path.join(pluginDir, rel))
  const hash = crypto.createHash('sha256').update(data).digest('hex')
  map[rel] = hash
  lines.push(`${rel}:${hash}`)
}
const buildHash = crypto.createHash('sha256').update(lines.join('\n'), 'utf8').digest('hex')
const build = {
  version: pkg.version,
  buildHash,
  generatedAt: new Date().toISOString(),
  files: map,
}
fs.writeFileSync(path.join(pluginDir, 'build.json'), JSON.stringify(build, null, 2) + '\n')
