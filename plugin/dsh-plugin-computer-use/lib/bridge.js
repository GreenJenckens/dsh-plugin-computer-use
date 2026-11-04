import { spawn } from 'node:child_process'
import path from 'node:path'
import os from 'node:os'
import { fileURLToPath } from 'node:url'

const here = path.dirname(fileURLToPath(import.meta.url))

/**
 * Persistent Windows PowerShell host for computer-use operations.
 * One process stays warm, so UI Automation and Win32 initialization happen once
 * instead of on every tool call. Requests are JSON lines over stdin/stdout.
 */
export class ComputerUseHost {
  constructor(options = {}) {
    this.powershell = options.powershell
      || path.join(process.env.WINDIR || 'C:\\Windows', 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe')
    this.script = options.script || path.join(here, 'scripts', 'bridge.ps1')
    this.tempDir = options.tempDir || path.join(os.tmpdir(), 'dsh-cu')
    this.timeoutMs = options.timeoutMs || 60000
    this.retentionHours = options.retentionHours ?? 2
    this.maxFiles = options.maxFiles ?? 150
    this.env = options.env || null
    this.child = null
    this.buffer = ''
    this.pending = new Map()
    this.nextId = 1
    this.chain = Promise.resolve()
    this.disposed = false
    this.lastStderr = ''
  }

  enqueue(op, args, options = {}) {
    const run = () => this.dispatch(op, args, options)
    const result = this.chain.then(run, run)
    this.chain = result.then(() => undefined, () => undefined)
    return result
  }

  ensureChild() {
    if (this.child && this.child.exitCode === null && !this.child.killed) return this.child
    const child = spawn(this.powershell, [
      '-NoLogo',
      '-NoProfile',
      '-NonInteractive',
      '-STA',
      '-ExecutionPolicy', 'Bypass',
      '-File', this.script,
      '-TempDir', this.tempDir,
      '-RetentionHours', String(this.retentionHours),
      '-MaxFiles', String(this.maxFiles),
    ], {
      windowsHide: true,
      cwd: os.tmpdir(),
      stdio: ['pipe', 'pipe', 'pipe'],
      ...(this.env ? { env: { ...process.env, ...this.env } } : {}),
    })
    child.stdout.setEncoding('utf8')
    child.stderr.setEncoding('utf8')
    child.stdout.on('data', (chunk) => this.onData(chunk))
    child.stderr.on('data', (chunk) => {
      const text = String(chunk).trim()
      if (text) this.lastStderr = text.slice(0, 2000)
    })
    child.on('exit', (code) => {
      if (this.child !== child) return // a stale process from before a restart
      this.child = null
      this.failAll(new Error(`computer-use host exited (${code ?? 'null'})${this.lastStderr ? ': ' + this.lastStderr : ''}`))
    })
    child.on('error', (error) => {
      if (this.child !== child) return
      this.child = null
      this.failAll(new Error(`cannot start the computer-use host: ${error.message}`))
    })
    this.child = child
    this.buffer = ''
    this.lastStderr = ''
    return child
  }

  onData(chunk) {
    this.buffer += chunk
    let index
    while ((index = this.buffer.indexOf('\n')) >= 0) {
      const line = this.buffer.slice(0, index).trim()
      this.buffer = this.buffer.slice(index + 1)
      if (!line) continue
      let response
      try { response = JSON.parse(line) } catch { continue }
      const id = Number(response.id)
      if (!id) continue // readiness probe
      const entry = this.pending.get(id)
      if (!entry) continue
      this.pending.delete(id)
      clearTimeout(entry.timer)
      entry.cleanup()
      entry.resolve(response)
    }
  }

  dispatch(op, args, options = {}) {
    if (this.disposed) return Promise.reject(new Error('computer-use host is disposed'))
    if (process.platform !== 'win32') return Promise.reject(new Error('computer use is only implemented for Windows'))
    const signal = options.signal
    if (signal?.aborted) return Promise.reject(new Error('computer-use call aborted'))
    const child = this.ensureChild()
    const id = this.nextId++
    return new Promise((resolve, reject) => {
      const onAbort = () => {
        this.pending.delete(id)
        clearTimeout(timer)
        this.restart(new Error('computer-use call aborted'))
        reject(new Error('computer-use call aborted'))
      }
      const cleanup = () => {
        try { signal?.removeEventListener('abort', onAbort) } catch {}
      }
      const timer = setTimeout(() => {
        this.pending.delete(id)
        cleanup()
        this.restart(new Error(`computer-use host timed out after ${this.timeoutMs} ms`))
        reject(new Error(`computer-use host timed out after ${this.timeoutMs} ms; the host was restarted`))
      }, this.timeoutMs)
      this.pending.set(id, {
        timer,
        cleanup,
        resolve: (response) => {
          if (response.ok) {
            resolve(response)
            return
          }
          const extra = Array.isArray(response.matches) && response.matches.length > 0
            ? '\n' + response.matches.join('\n')
            : ''
          reject(new Error(`${response.error || 'computer-use operation failed'}${extra}`))
        },
        reject,
      })
      try { signal?.addEventListener('abort', onAbort, { once: true }) } catch {}
      const line = JSON.stringify({ id, op, args: args || {} })
      try {
        child.stdin.write(line + '\n')
      } catch (error) {
        clearTimeout(timer)
        cleanup()
        this.pending.delete(id)
        reject(new Error(`cannot write to the computer-use host: ${error.message}`))
      }
    })
  }

  failAll(error) {
    for (const [, entry] of this.pending) {
      clearTimeout(entry.timer)
      entry.cleanup()
      entry.reject(error)
    }
    this.pending.clear()
  }

  restart(error) {
    const child = this.child
    this.child = null
    this.buffer = ''
    this.lastStderr = ''
    if (child) {
      try { child.stdin.end() } catch {}
      try { child.kill() } catch {}
    }
    this.failAll(error)
  }

  async dispose() {
    this.disposed = true
    const child = this.child
    this.restart(new Error('computer-use host disposed'))
    if (!child) return
    await new Promise((resolve) => {
      const timer = setTimeout(resolve, 1000)
      child.once('close', () => { clearTimeout(timer); resolve() })
    })
  }
}

export function createHost(options) {
  return new ComputerUseHost(options)
}

export const hostScriptPath = path.join(here, 'scripts', 'bridge.ps1')
