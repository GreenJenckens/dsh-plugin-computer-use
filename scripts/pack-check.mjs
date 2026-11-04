import fs from 'node:fs'
import path from 'node:path'
import { spawnSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'

const here = path.dirname(fileURLToPath(import.meta.url))
const pluginDir = path.join(here, '..', 'plugin', 'dsh-plugin-computer-use')
const pkg = JSON.parse(fs.readFileSync(path.join(pluginDir, 'package.json'), 'utf8'))
const build = JSON.parse(fs.readFileSync(path.join(pluginDir, 'build.json'), 'utf8'))
const result = spawnSync('cmd.exe', ['/c', 'npm pack --dry-run --json'], { cwd: pluginDir, encoding: 'utf8' })
if (result.error) {
  console.error(result.error.message)
  process.exit(1)
}
if (result.status !== 0) {
  console.error(result.stderr || result.stdout)
  process.exit(1)
}
const start = result.stdout.indexOf('[')
const end = result.stdout.lastIndexOf(']')
if (start < 0 || end < start) throw new Error('could not parse npm pack --dry-run --json')
const packed = JSON.parse(result.stdout.slice(start, end + 1))[0]
const names = new Set((packed.files || []).map((file) => file.path.replaceAll('\\', '/')))
const required = [
  'package.json', 'cordis.patch.yml', 'README.md', 'CHANGELOG.md', 'SECURITY.md', 'build.json', 'LICENSE',
  'lib/index.js', 'lib/bridge.js', 'lib/indicator.js', 'lib/titles.js',
  'lib/scripts/bridge.ps1', 'lib/scripts/CuCommon.ps1',
  'lib/indicator/indicator.ps1', 'lib/indicator/strings.json',
]
const missing = required.filter((name) => !names.has(name))
if (missing.length > 0) {
  console.error('missing from pack:', missing.join(', '))
  process.exit(1)
}
if (build.version !== pkg.version || !/^[0-9a-f]{64}$/.test(build.buildHash)) {
  console.error('build.json is not consistent with package.json')
  process.exit(1)
}
if (packed.version !== pkg.version) {
  console.error(`packed version ${packed.version} != package version ${pkg.version}`)
  process.exit(1)
}
console.log(`PACK OK: ${pkg.name}@${pkg.version} ${packed.entryCount} files, build ${build.buildHash.slice(0, 12)}`)
