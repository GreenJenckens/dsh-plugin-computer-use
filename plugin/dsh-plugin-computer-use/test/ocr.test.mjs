import { test } from 'node:test'
import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { spawnSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'
import { createHost } from '../lib/bridge.js'

const hostScript = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', 'lib', 'scripts', 'bridge.ps1')

function makePng(file, width, height, text) {
  const script = `Add-Type -AssemblyName System.Drawing
$bmp = New-Object System.Drawing.Bitmap ${width}, ${height}
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.Clear([System.Drawing.Color]::White)
$font = New-Object System.Drawing.Font 'Segoe UI', 14
$g.DrawString('${text.replaceAll("'", "''")}', $font, [System.Drawing.Brushes]::Black, 10, 10)
$g.Dispose()
$bmp.Save('${file.replaceAll("'", "''")}', [System.Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose()`
  const result = spawnSync('powershell.exe', ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', script], { encoding: 'utf8' })
  assert.equal(result.status, 0, result.stderr)
}

test('ocr _image is dev-only and cannot read arbitrary files in production', { timeout: 30000 }, async () => {
  const file = path.join(os.tmpdir(), `dsh-cu-ocr-${process.pid}.png`)
  makePng(file, 400, 80, '0123456789')
  const host = createHost({ script: hostScript, timeoutMs: 30000 })
  try {
    await assert.rejects(host.enqueue('ocr', { _image: file, ocrScale: 2 }), /development-only/)
  } finally {
    await host.dispose()
    fs.rmSync(file, { force: true })
  }
})

test('ocr clamps the upscale so images above the 10 000 px engine limit still work', { timeout: 45000 }, async () => {
  const file = path.join(os.tmpdir(), `dsh-cu-ocr-big-${process.pid}.png`)
  makePng(file, 11000, 200, '0123456789 OCR TEST')
  const host = createHost({ script: hostScript, timeoutMs: 30000, env: { DSH_CU_OCR_EVAL: '1' } })
  try {
    const result = await host.enqueue('ocr', { _image: file, ocrScale: 3, ocrBoxes: false, ocrLang: 'en-US' })
    assert.match(result.text, /clamped=1/)
    assert.match(result.text, /scale=0\.909/)
    assert.match(result.text, /0123456789/)
  } finally {
    await host.dispose()
    fs.rmSync(file, { force: true })
  }
})
