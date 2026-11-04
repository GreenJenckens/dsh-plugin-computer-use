import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { createHost } from '../plugin/dsh-plugin-computer-use/lib/bridge.js'

const here = path.dirname(fileURLToPath(import.meta.url))
const fixtureDir = path.join(here, '..', 'plugin', 'dsh-plugin-computer-use', 'test', 'fixtures', 'ocr')
const manifest = JSON.parse(fs.readFileSync(path.join(fixtureDir, 'manifest.json'), 'utf8'))
const args = process.argv.slice(2)
const quick = args.includes('--quick')
const outPath = path.join(here, '..', 'docs', 'v0.4-ocr-results.json')
const images = quick ? manifest.slice(0, 3) : manifest

function normalize(value) {
  return String(value).normalize('NFC').trim().replace(/\s+/g, ' ')
}

function editDistance(a, b) {
  const prev = new Array(b.length + 1)
  for (let j = 0; j <= b.length; j++) prev[j] = j
  for (let i = 1; i <= a.length; i++) {
    let diag = prev[0]
    prev[0] = i
    for (let j = 1; j <= b.length; j++) {
      const temp = prev[j]
      prev[j] = Math.min(prev[j] + 1, prev[j - 1] + 1, diag + (a[i - 1] === b[j - 1] ? 0 : 1))
      diag = temp
    }
  }
  return prev[b.length]
}

function zeroToD(reference, hypothesis) {
  const a = [...reference]
  const b = [...hypothesis]
  const dp = Array.from({ length: a.length + 1 }, () => new Array(b.length + 1).fill(0))
  for (let i = 1; i <= a.length; i++) dp[i][0] = i
  for (let j = 1; j <= b.length; j++) dp[0][j] = j
  for (let i = 1; i <= a.length; i++) {
    for (let j = 1; j <= b.length; j++) {
      dp[i][j] = Math.min(dp[i - 1][j] + 1, dp[i][j - 1] + 1, dp[i - 1][j - 1] + (a[i - 1] === b[j - 1] ? 0 : 1))
    }
  }
  let i = a.length
  let j = b.length
  let count = 0
  while (i > 0 && j > 0) {
    if (a[i - 1] === b[j - 1] && dp[i][j] === dp[i - 1][j - 1]) { i--; j--; continue }
    if (dp[i][j] === dp[i - 1][j - 1] + 1) {
      if (a[i - 1] === '0' && (b[j - 1] === 'D' || b[j - 1] === 'd')) count++
      i--; j--; continue
    }
    if (dp[i][j] === dp[i - 1][j] + 1) { i--; continue }
    j--
  }
  return count
}

function wordDistance(a, b) {
  const aw = a.split(/\s+/).filter(Boolean)
  const bw = b.split(/\s+/).filter(Boolean)
  return { distance: editDistance(aw, bw), length: aw.length }
}

async function runConfig(host, scale, lang, list) {
  const rows = []
  let refChars = 0
  let errors = 0
  let refWords = 0
  let wordErrors = 0
  let exact = 0
  let zeroD = 0
  let total = 0
  let failures = 0
  for (const image of list) {
    const file = path.join(fixtureDir, image.file)
    let text
    try {
      const result = await host.enqueue('ocr', { _image: file, ocrScale: scale, ocrLang: lang, ocrBoxes: false, maxLines: 20 })
      text = result.text.split('\n').slice(1).join('\n')
    } catch (error) {
      failures++
      rows.push({ image: image.id, error: error.message })
      continue
    }
    const hyp = normalize(text)
    const ref = normalize(image.lines.map((line) => line.text).join(' '))
    const dist = editDistance(ref, hyp)
    const words = wordDistance(ref, hyp)
    refChars += ref.length
    errors += dist
    refWords += words.length
    wordErrors += words.distance
    total++
    if (ref === hyp) exact++
    zeroD += zeroToD(ref, hyp)
    rows.push({
      image: image.id,
      cer: Number((dist / Math.max(1, ref.length)).toFixed(4)),
      exact: ref === hyp,
      zeroToD: zeroToD(ref, hyp),
      text: hyp.slice(0, 220),
    })
  }
  return {
    scale, lang,
    images: total, failures, exact,
    cerMicro: Number((errors / Math.max(1, refChars)).toFixed(4)),
    werMicro: Number((wordErrors / Math.max(1, refWords)).toFixed(4)),
    zeroToD: zeroD,
    exactRate: Number((exact / Math.max(1, total)).toFixed(4)),
    rows,
  }
}

const host = createHost({ env: { DSH_CU_OCR_EVAL: '1' }, timeoutMs: 60000 })
const configs = {}
try {
  for (const scale of [1, 2, 3]) {
    for (const lang of ['ru', 'en-US']) {
      const key = `scale${scale}-${lang}`
      configs[key] = await runConfig(host, scale, lang, images)
      console.log(`${key}: CER=${(configs[key].cerMicro * 100).toFixed(2)}% WER=${(configs[key].werMicro * 100).toFixed(2)}% exact=${(configs[key].exactRate * 100).toFixed(1)}% 0->D=${configs[key].zeroToD}`)
    }
  }
} finally {
  await host.dispose()
}

const report = {
  generatedAt: new Date().toISOString(),
  dataset: { images: images.length, linesPerImage: 3, manifest: path.relative(path.join(here, '..'), path.join(fixtureDir, 'manifest.json')) },
  configs,
}
fs.writeFileSync(outPath, JSON.stringify(report, null, 2) + '\n')
console.log('wrote', outPath)
