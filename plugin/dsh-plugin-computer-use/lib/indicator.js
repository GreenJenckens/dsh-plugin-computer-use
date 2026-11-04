import { spawn } from 'node:child_process'
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const here = path.dirname(fileURLToPath(import.meta.url))

export class Indicator {
  constructor(options = {}) {
    this.stateDir = options.stateDir
    this.powershell = options.powershell || path.join(process.env.WINDIR || 'C:\\Windows', 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe')
    this.script = options.script || path.join(here, 'indicator', 'indicator.ps1')
    this.child = null
    this.disposed = false
    this.starting = false
  }

  start() {
    if (this.disposed || this.child) return
    if (this.starting) return
    this.starting = true
    try {
      mkdirSync(this.stateDir, { recursive: true })
      const child = spawn(this.powershell, [
        '-NoLogo', '-NoProfile', '-NonInteractive', '-STA',
        '-ExecutionPolicy', 'Bypass',
        '-File', this.script,
        '-StateDir', this.stateDir,
      ], { windowsHide: true, stdio: 'ignore' })
      child.on('exit', () => { if (this.child === child) this.child = null; this.starting = false })
      child.on('error', () => { if (this.child === child) this.child = null; this.starting = false })
      this.child = child
    } finally {
      this.starting = false
    }
  }

  touch() {
    if (this.disposed) return
    this.start()
    try {
      mkdirSync(this.stateDir, { recursive: true })
      writeFileSync(path.join(this.stateDir, 'active'), String(Date.now()))
    } catch {}
  }

  cancelled() {
    return existsSync(path.join(this.stateDir, 'cancel'))
  }

  ready() {
    try {
      const ready = JSON.parse(readFileSync(path.join(this.stateDir, 'ready'), 'utf8'))
      if (!ready.pid) return false
      process.kill(Number(ready.pid), 0)
      return true
    } catch {
      return false
    }
  }

  dispose() {
    this.disposed = true
    const child = this.child
    this.child = null
    if (child) {
      try { child.kill() } catch {}
      try { child.stdin?.end() } catch {}
    }
    for (const name of ['ready', 'active', 'cancel', 'confirm-request.json', 'confirm-response.json']) {
      try { rmSync(path.join(this.stateDir, name), { force: true }) } catch {}
    }
  }
}

export function createIndicator(options) {
  return new Indicator(options)
}
