#!/usr/bin/env node
// codeshot: render an .egg file, and what `eggc run` prints, as a PNG.
//
//   codeshot FILE.egg [-o OUT.png] [--no-run]
//
// Highlighting uses the VS Code grammar (../vscode/syntaxes), so the picture
// matches the editor. The leading comment block (description and expect:
// lines) is left out. Needs Chrome; set CHROME to its path if it is not in
// the usual place.
import { createHighlighter } from 'shiki'
import { execFileSync } from 'node:child_process'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const here = path.dirname(fileURLToPath(import.meta.url))
const root = path.resolve(here, '../..')

const args = process.argv.slice(2)
let src = null, out = null, run = true, bad = false
for (let i = 0; i < args.length; i++) {
  if (args[i] === '-o' && i + 1 < args.length) out = args[++i]
  else if (args[i] === '--no-run') run = false
  else if (args[i].startsWith('-') || src) bad = true
  else src = args[i]
}
if (bad || !src) {
  console.error('usage: codeshot FILE.egg [-o OUT.png] [--no-run]')
  process.exit(2)
}
out ??= path.basename(src, '.egg') + '.png'

const lines = fs.readFileSync(src, 'utf8').split('\n')
let start = 0
while (start < lines.length && (lines[start].startsWith('//') || lines[start].trim() === '')) start++
const code = lines.slice(start).join('\n').trimEnd()

let output = null
if (run) {
  try {
    output = execFileSync(path.join(root, 'bin/eggc'), ['run', src], { encoding: 'utf8' })
  } catch (e) {
    output = (e.stdout || '') + (e.stderr || '') || e.message
  }
  output = output.replace(/\n$/, '')
}

const grammar = JSON.parse(fs.readFileSync(path.join(here, '../vscode/syntaxes/egg.tmLanguage.json'), 'utf8'))
const hl = await createHighlighter({ themes: ['github-dark'], langs: [{ ...grammar, name: 'egg' }] })
const codeHtml = hl.codeToHtml(code, { lang: 'egg', theme: 'github-dark' })
const esc = s => s.replace(/&/g, '&amp;').replace(/</g, '&lt;')
const label = path.relative(root, path.resolve(src)).startsWith('..') ? path.basename(src) : path.relative(root, path.resolve(src))

// Panels are sized from the longest line, so nothing is clipped; the page is
// at least 1240 px wide.
const charW = 9.1
const lineH = 22.5
const longest = s => Math.max(...s.split('\n').map(l => [...l].length))
const outW = output === null ? 0 : Math.max(240, Math.ceil(longest(output) * charW + 46))
const codeW = Math.ceil(longest(code) * charW + 46)
const width = Math.max(1240, 56 + codeW + (outW ? 24 + outW : 0))
const panelH = n => 36 + 30 + n * lineH + 2
const height = Math.ceil(56 + Math.max(panelH(code.split('\n').length), output === null ? 0 : panelH(output.split('\n').length)))

const outputPanel = output === null ? '' :
  `<div class=p style="width:${outW}px;flex:none;align-self:flex-start"><div class=h>$ eggc run</div><pre>${esc(output)}</pre></div>`
const page = `<!doctype html><meta charset=utf-8><style>
body{margin:0;background:#0d1117;font:15px/1.5 "SF Mono",Menlo,monospace;color:#e6edf3}
.w{display:flex;gap:24px;padding:28px;width:${width}px;box-sizing:border-box}
.p{background:#161b22;border:1px solid #30363d;border-radius:10px;padding:18px 22px;box-sizing:border-box}
.h{color:#8b949e;font-size:13px;line-height:20px;margin-bottom:10px}
pre{margin:0;background:transparent!important;font:inherit}
</style><div class=w><div class=p style="flex:1"><div class=h>${esc(label)}</div>${codeHtml}</div>${outputPanel}</div>`

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'codeshot-'))
const html = path.join(tmp, 'shot.html')
fs.writeFileSync(html, page)
const chrome = process.env.CHROME || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'
try {
  execFileSync(chrome, ['--headless=new', '--disable-gpu', '--hide-scrollbars', '--force-device-scale-factor=2',
    `--window-size=${width},${height}`, `--screenshot=${path.resolve(out)}`, 'file://' + html], { stdio: 'ignore' })
} finally {
  fs.rmSync(tmp, { recursive: true, force: true })
}
console.log(out)
