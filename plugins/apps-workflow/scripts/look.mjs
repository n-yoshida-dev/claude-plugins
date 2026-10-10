#!/usr/bin/env node
// 画面の見た目を撮る・確かめる・見せるための道具（apps-workflow の look スキルから使う）。
// 撮影（shoot）・Impeccable の検出器（detect）・DESIGN.md の検査（lint）・比較ページ（page）・画素と濃さの差の測定（pixel / contrast）を 1 本にまとめる。
// 外部の道具の版と画面の大きさは ../config/look-tools.json にある。使い方は `node look.mjs --help`
import { createRequire } from 'node:module'
import { readFileSync, writeFileSync, mkdirSync, existsSync, statSync } from 'node:fs'
import { dirname, join, resolve, basename } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'
import { spawnSync } from 'node:child_process'
import { homedir } from 'node:os'

const here = dirname(fileURLToPath(import.meta.url))
const configPath = join(here, '..', 'config', 'look-tools.json')

const HELP = `使い方: node look.mjs <命令> ...

  shoot <URL> <出力フォルダ> [--name 接頭辞] [--sizes wide,phone] [--schemes light,dark]
        [--screens 4] [--wait セレクタ] [--css 見本のCSS] [--setup 準備.mjs] [--full]
      画面を 1 画面分ずつ上から撮り（PNG・2 倍）、横のはみ出し・画面のエラー・外部への通信を数える。
      ファイル名は <接頭辞><大きさ>[-dark]-<番号>.png（例: current-wide-dark-1.png）。
      --css は、ビルドの CSS を外して見本の CSS を入れてから撮る（見た目の方向の見本を作るとき）。
      --setup は default export の関数 (page, { size, scheme, viewport }) を撮る前に呼ぶ。
      お気に入りを 1 件入れるなど、画面に中身を出す操作に使う。文字列を返すと結果の行に足す。
      撮る前にマウスを左上の隅へ動かす（行の上に残ると hover の色が写り、選んでいない行が選ばれて見えるため）。

  detect <URL> [<出力フォルダ>] [--sizes wide,phone]
      Impeccable の検出器を、表の版で画面の大きさごとに当てる。Chromium は Playwright のものを使う。

  lint [DESIGN.md]
      Google の DESIGN.md の検査を表の版で当て、エラーと警告を出す。エラーがあれば終了コード 1。

  page <内容.json> <出力.html>
      見本・前と後を縦に並べた比較ページを作る。画像は縮めて JPEG にし、data URI で埋める（Artifact に 1 枚で載せるため）。
      内容の形は look スキルの「比較ページ」の節。画像のパスは内容.json の場所から見た相対パスでよい。

  pixel <画像.png> <x>,<y> [<x>,<y> ...]
      画像の画素の色を出す（座標は画像の画素。2 倍で撮った画像は CSS の 2 倍）。

  contrast <色> <色>
      2 色の濃さの差（WCAG 2 のコントラスト比）を出す。例: contrast '#757575' '#f3f4f1'

大きさの名前（wide・laptop・phone）と既定は ${configPath} にある。名前の代わりに 1280x800 のようにも書ける。
Playwright は表の dir（環境変数 LOOK_PLAYWRIGHT_DIR で変えられる）から読む。Chromium の場所は環境変数 CHROME_PATH で変えられる。`

// 引数の誤り。終了コード 2 で止める
class UsageError extends Error {}

// 表を読む。壊れていたら理由を添えて止める
function loadConfig() {
  try {
    return JSON.parse(readFileSync(configPath, 'utf8'))
  } catch (e) {
    throw new Error(`表 ${configPath} を読めなかった: ${e.message}`)
  }
}

// 先頭の ~ をホームに置き換える
function expandHome(p) {
  return p.startsWith('~/') ? join(homedir(), p.slice(2)) : p
}

// --名前 値 と --旗 を読み分ける。spec は { 名前: 'string' | 'bool' }
function parseArgs(argv, spec) {
  const positional = []
  const opts = {}
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i]
    if (!a.startsWith('--')) {
      positional.push(a)
      continue
    }
    const key = a.slice(2)
    if (!(key in spec)) throw new UsageError(`知らない指定: ${a}`)
    if (spec[key] === 'bool') {
      opts[key] = true
    } else {
      const v = argv[++i]
      if (v === undefined || v.startsWith('--')) throw new UsageError(`${a} の値が無い`)
      opts[key] = v
    }
  }
  return { positional, opts }
}

// 大きさの名前（wide など）か 1280x800 の形を、{ name, width, height } にする
function sizeOf(config, token) {
  const m = /^(\d+)x(\d+)$/.exec(token)
  if (m) return { name: token, width: Number(m[1]), height: Number(m[2]) }
  const s = config.sizes[token]
  if (!s) throw new UsageError(`大きさ ${token} は表に無い（${Object.keys(config.sizes).join('・')} か 1280x800 の形）`)
  return { name: token, width: s.width, height: s.height }
}

// Playwright を表の dir から読む。見つからなければ入れ方を添えて止める
function loadPlaywright(config) {
  const dirs = [process.env.LOOK_PLAYWRIGHT_DIR, expandHome(config.playwright.dir)].filter(Boolean)
  const tried = []
  for (const d of dirs) {
    try {
      return createRequire(join(d, 'package.json'))('playwright')
    } catch (e) {
      tried.push(`${d}: ${e.code ?? e.message}`)
    }
  }
  throw new Error(
    `Playwright が見つからない（${tried.join(' / ')}）。初回だけ次で入れる:\n` +
      `  npm install --prefix ${expandHome(config.playwright.dir)} --no-audit --no-fund playwright@${config.playwright.version}\n` +
      `  npx --prefix ${expandHome(config.playwright.dir)} playwright install chromium`,
  )
}

// Chromium を起動する。場所は CHROME_PATH があればそれ、無ければ Playwright の既定
async function launch(chromium) {
  const executablePath = process.env.CHROME_PATH || undefined
  try {
    return await chromium.launch({ executablePath })
  } catch (e) {
    throw new Error(
      `Chromium を起動できなかった: ${e.message.split('\n')[0]}\n` +
        '  ブラウザが無いなら `npx --prefix <Playwright の dir> playwright install chromium`、別の場所にあるなら CHROME_PATH で渡す',
    )
  }
}

// 画面を撮り、数値の確かめを出す
async function shoot(config, argv) {
  const { positional, opts } = parseArgs(argv, {
    name: 'string',
    sizes: 'string',
    schemes: 'string',
    screens: 'string',
    wait: 'string',
    css: 'string',
    setup: 'string',
    full: 'bool',
  })
  const [url, out] = positional
  if (!url || !out) throw new UsageError('shoot には URL と出力フォルダが要る')
  const origin = new URL(url).origin
  const sizes = (opts.sizes ?? config.defaultSizes.join(',')).split(',').map((t) => sizeOf(config, t))
  const schemes = (opts.schemes ?? config.defaultSchemes.join(',')).split(',')
  for (const s of schemes) if (s !== 'light' && s !== 'dark') throw new UsageError(`--schemes は light か dark: ${s}`)
  const maxScreens = Number(opts.screens ?? config.maxScreens)
  if (!Number.isInteger(maxScreens) || maxScreens < 1) throw new UsageError(`--screens は 1 以上の整数: ${opts.screens}`)
  const prefix = opts.name ? `${opts.name}-` : ''
  const css = opts.css ? readFileSync(opts.css, 'utf8') : null
  const setup = opts.setup ? (await import(pathToFileURL(resolve(opts.setup)).href)).default : null
  if (opts.setup && typeof setup !== 'function') throw new UsageError(`${opts.setup} に default export の関数が無い`)
  mkdirSync(out, { recursive: true })

  const { chromium } = loadPlaywright(config)
  const browser = await launch(chromium)
  const external = new Set()
  let attention = 0
  try {
    for (const size of sizes) {
      for (const scheme of schemes) {
        const viewport = { width: size.width, height: size.height }
        const page = await browser.newPage({ viewport, deviceScaleFactor: 2, colorScheme: scheme })
        const errors = []
        page.on('request', (r) => {
          const u = r.url()
          if (/^https?:/.test(u) && new URL(u).origin !== origin) external.add(u)
        })
        page.on('pageerror', (e) => errors.push(e.message))
        page.on('console', (m) => {
          if (m.type() === 'error') errors.push(m.text())
        })
        await page.goto(url, { waitUntil: 'load' })
        if (opts.wait) await page.waitForSelector(opts.wait)
        if (css) {
          // ビルドの CSS を外し、見本の CSS を入れる。画面の HTML は変えない（中身が変わると何を選んだのか分からなくなるため）
          await page.evaluate(() => document.querySelectorAll('link[rel="stylesheet"], style').forEach((el) => el.remove()))
          await page.addStyleTag({ content: css })
        }
        let note = ''
        if (setup) {
          const r = await setup(page, { size: size.name, scheme, viewport })
          if (typeof r === 'string' && r) note = ` / ${r}`
        }
        await page.mouse.move(1, 1)
        await page.evaluate(() => window.scrollTo(0, 0))
        await page.waitForTimeout(200)
        const overflow = await page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth)
        const total = await page.evaluate(() => document.documentElement.scrollHeight)
        const n = Math.min(maxScreens, Math.ceil(total / viewport.height))
        const stem = `${prefix}${size.name}${scheme === 'dark' ? '-dark' : ''}`
        for (let i = 0; i < n; i++) {
          await page.evaluate((y) => window.scrollTo(0, y), i * viewport.height)
          await page.waitForTimeout(150)
          await page.screenshot({ path: join(out, `${stem}-${i + 1}.png`) })
        }
        if (opts.full) await page.screenshot({ path: join(out, `${stem}-full.png`), fullPage: true })
        const rest = total - n * viewport.height
        const restNote = rest > 0 ? ` / 下の ${rest}px は撮っていない（--screens で増やす）` : ''
        console.log(
          `${stem}（${viewport.width}×${viewport.height}）: 高さ ${total}px・${n} 枚 / 横のはみ出し ${overflow}px / 画面のエラー ${errors.length} 件${note}${restNote}`,
        )
        for (const e of errors) console.log(`  エラー: ${e.slice(0, 300)}`)
        if (overflow > 0 || errors.length > 0) attention++
        await page.close()
      }
    }
  } finally {
    await browser.close()
  }
  console.log(`外部への通信: ${external.size} 件${external.size ? ` ${[...external].join(' ')}` : ''}`)
  console.log(`はみ出しかエラーのあった組: ${attention} / ${sizes.length * schemes.length}`)
}

// npx で外部の道具を呼ぶ。何を実行したかを標準エラーに出す
function runNpx(args, env = {}) {
  const shown = Object.entries(env).map(([k, v]) => `${k}=${v} `).join('')
  console.error(`実行: ${shown}npx ${args.join(' ')}`)
  const r = spawnSync('npx', args, {
    encoding: 'utf8',
    env: { ...process.env, ...env },
    maxBuffer: 64 * 1024 * 1024,
    timeout: 5 * 60 * 1000,
  })
  if (r.error) throw new Error(`npx を実行できなかった: ${r.error.message}`)
  return r
}

// Impeccable の検出器を画面の大きさごとに当てる
async function detect(config, argv) {
  const { positional, opts } = parseArgs(argv, { sizes: 'string' })
  const [url, out] = positional
  if (!url) throw new UsageError('detect には URL が要る（CSS のファイルに当てても 0 件になる。描いた画面を見る作りのため）')
  const sizes = (opts.sizes ?? config.defaultSizes.join(',')).split(',').map((t) => sizeOf(config, t))
  const { chromium } = loadPlaywright(config)
  const chrome = process.env.CHROME_PATH || chromium.executablePath()
  if (!existsSync(chrome)) throw new Error(`Chromium が ${chrome} に無い。CHROME_PATH で渡す`)
  if (out) mkdirSync(out, { recursive: true })
  const pkg = `${config.impeccable.package}@${config.impeccable.version}`
  let failed = false
  for (const size of sizes) {
    const r = runNpx(['--yes', pkg, 'detect', '--no-config', '--json', '--viewport', `${size.width}x${size.height}`, url], {
      CHROME_PATH: chrome,
    })
    // 終了コード: 0 = 指摘なし、2 = 指摘あり、1 = 調べられなかった（Impeccable の --help）
    if (r.status !== 0 && r.status !== 2) {
      console.log(`${size.name}: 調べられなかった（終了コード ${r.status}）`)
      console.log((r.stderr ?? '').slice(-1500))
      failed = true
      continue
    }
    let report
    try {
      report = JSON.parse(r.stdout)
    } catch (e) {
      console.log(`${size.name}: 結果を JSON として読めなかった（${e.message}）。先頭: ${(r.stdout ?? '').slice(0, 300)}`)
      failed = true
      continue
    }
    if (out) writeFileSync(join(out, `impeccable-${size.name}.json`), r.stdout)
    const findings = Array.isArray(report) ? report : (report.findings ?? [])
    console.log(`${size.name}（${size.width}×${size.height}）: ${findings.length} 件`)
    for (const f of findings) {
      const snippet = String(f.snippet ?? '').replace(/\s+/g, ' ').slice(0, 160)
      console.log(`  ${f.antipattern ?? f.rule ?? '?'} | ${f.severity ?? '?'} | ${f.selector ?? ''} | ${snippet}`)
    }
  }
  if (failed) process.exitCode = 1
}

// DESIGN.md の検査を当てる
function lint(config, argv) {
  const { positional } = parseArgs(argv, {})
  const file = positional[0] ?? 'DESIGN.md'
  if (!existsSync(file)) throw new UsageError(`${file} が無い`)
  const r = runNpx(['--yes', `${config.designMd.package}@${config.designMd.version}`, 'lint', file])
  let report
  try {
    report = JSON.parse(r.stdout)
  } catch (e) {
    throw new Error(`検査の結果を読めなかった（${e.message}）。終了コード ${r.status}。${(r.stderr ?? '').slice(-800)}`)
  }
  const s = report.summary ?? {}
  console.log(`エラー ${s.errors ?? '?'} / 警告 ${s.warnings ?? '?'} / 情報 ${s.infos ?? s.info ?? 0}`)
  for (const f of report.findings ?? []) {
    if (f.severity === 'info') continue
    console.log(`  ${f.severity} | ${f.path ?? ''} | ${f.message}`)
  }
  if ((s.errors ?? 0) > 0 || r.status === 1) process.exitCode = 1
}

// HTML に入れる文字を逃がす
function esc(s) {
  return String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c])
}

// 比較ページを作る
async function buildPage(config, argv) {
  const { positional } = parseArgs(argv, {})
  const [specPath, outPath] = positional
  if (!specPath || !outPath) throw new UsageError('page には内容.json と出力.html が要る')
  let spec
  try {
    spec = JSON.parse(readFileSync(specPath, 'utf8'))
  } catch (e) {
    throw new UsageError(`${specPath} を読めなかった: ${e.message}`)
  }
  if (!spec.title || !Array.isArray(spec.sections)) throw new UsageError('内容には title と sections（配列）が要る')
  const base = dirname(resolve(specPath))
  const { chromium } = loadPlaywright(config)
  const browser = await launch(chromium)
  const embedded = new Map()
  try {
    const tab = await browser.newPage()
    // 画像を縮めて JPEG にする。横長（PC）は幅 1400px、縦長（スマホ）は 560px まで（試行で読めた大きさ）
    const toJpeg = async (src) => {
      const path = resolve(base, src)
      if (embedded.has(path)) return embedded.get(path)
      const type = path.endsWith('.jpg') || path.endsWith('.jpeg') ? 'image/jpeg' : 'image/png'
      const data = `data:${type};base64,${readFileSync(path).toString('base64')}`
      const result = await tab.evaluate(async (d) => {
        const img = new Image()
        img.src = d
        await img.decode()
        const max = img.naturalWidth >= img.naturalHeight ? 1400 : 560
        const scale = Math.min(1, max / img.naturalWidth)
        const canvas = document.createElement('canvas')
        canvas.width = Math.round(img.naturalWidth * scale)
        canvas.height = Math.round(img.naturalHeight * scale)
        canvas.getContext('2d').drawImage(img, 0, 0, canvas.width, canvas.height)
        return { url: canvas.toDataURL('image/jpeg', 0.85), w: canvas.width, h: canvas.height }
      }, data)
      embedded.set(path, result)
      return result
    }
    const sections = []
    for (const sec of spec.sections) {
      const rows = []
      for (const row of sec.rows ?? []) {
        const figs = []
        let portrait = true
        for (const fig of row) {
          const img = await toJpeg(fig.src)
          if (img.w >= img.h) portrait = false
          figs.push(
            `<figure><figcaption>${esc(fig.caption)}</figcaption><img src="${img.url}" width="${img.w}" height="${img.h}" alt="${esc(fig.alt ?? `${sec.heading ?? ''} ${fig.caption ?? ''}`)}" loading="lazy"></figure>`,
          )
        }
        rows.push(`<div class="row${portrait ? ' portrait' : ''}">${figs.join('')}</div>`)
      }
      const tag = sec.tag ? `<span class="tag">${esc(sec.tag)}</span>` : ''
      const points = (sec.points ?? []).length ? `<ul>${sec.points.map((p) => `<li>${esc(p)}</li>`).join('')}</ul>` : ''
      sections.push(
        `<section><h2>${tag}${esc(sec.heading)}</h2>${sec.lead ? `<p class="lead">${esc(sec.lead)}</p>` : ''}${points}${rows.join('')}</section>`,
      )
    }
    const ask = spec.ask ? `<p class="ask">${esc(spec.ask)}</p>` : ''
    const notes = (spec.notes ?? []).length ? `<ul class="notes">${spec.notes.map((n) => `<li>${esc(n)}</li>`).join('')}</ul>` : ''
    const html = `<title>${esc(spec.title)}</title>
<style>
/* 見本の画像を縦に並べて読む比較ページ。地は中立の灰に寄せ、見本の色を邪魔しない */
:root {
  --bg: #f1f1ee;
  --fg: #22262a;
  --muted: #5b6166;
  --line: #cfd2cc;
  --panel: #ffffff;
  --font: system-ui, -apple-system, 'Hiragino Sans', 'Noto Sans JP', 'Yu Gothic UI', sans-serif;
}
@media (prefers-color-scheme: dark) {
  :root:not([data-theme="light"]) { --bg: #17191b; --fg: #e6e7e3; --muted: #a6abaf; --line: #3a3e42; --panel: #202326; color-scheme: dark; }
}
:root[data-theme="dark"] { --bg: #17191b; --fg: #e6e7e3; --muted: #a6abaf; --line: #3a3e42; --panel: #202326; color-scheme: dark; }
body { background: var(--bg); color: var(--fg); font-family: var(--font); font-size: 1rem; line-height: 1.65; }
main { max-width: 78rem; margin: 0 auto; padding-inline: 1rem; padding-block: 2rem 4rem; display: grid; gap: 3rem; }
header { display: grid; gap: 0.75rem; max-width: 46rem; }
h1 { font-size: 1.6rem; line-height: 1.3; margin: 0; text-wrap: balance; }
h2 { font-size: 1.25rem; line-height: 1.4; margin: 0; display: flex; gap: 0.6rem; align-items: baseline; flex-wrap: wrap; text-wrap: balance; }
p, ul { margin: 0; }
.lead, .notes { color: var(--muted); }
.notes { padding-left: 1.2rem; font-size: 0.9rem; }
.ask { background: var(--panel); border: 1px solid var(--line); padding: 0.75rem 1rem; font-weight: 600; }
.tag { font-size: 0.95rem; padding: 0 0.5rem; border: 1px solid var(--fg); }
section { display: grid; gap: 1rem; border-top: 1px solid var(--line); padding-top: 1.5rem; }
section ul { padding-left: 1.2rem; max-width: 46rem; }
.row { display: grid; gap: 1rem; grid-template-columns: repeat(auto-fit, minmax(min(100%, 24rem), 1fr)); align-items: start; }
.row.portrait { grid-template-columns: repeat(auto-fit, minmax(min(100%, 12rem), 18rem)); }
figure { margin: 0; display: grid; gap: 0.35rem; min-width: 0; }
figcaption { font-size: 0.85rem; color: var(--muted); }
img { display: block; max-width: 100%; height: auto; border: 1px solid var(--line); background: var(--panel); }
</style>
<main>
<header><h1>${esc(spec.title)}</h1>${spec.lead ? `<p class="lead">${esc(spec.lead)}</p>` : ''}${ask}${notes}</header>
${sections.join('\n')}
${spec.ask ? `<footer>${ask}</footer>` : ''}
</main>
`
    writeFileSync(outPath, html)
  } finally {
    await browser.close()
  }
  const bytes = statSync(outPath).size
  console.log(`${outPath}: ${(bytes / 1024 / 1024).toFixed(1)}MB・画像 ${embedded.size} 枚`)
  // Artifact の上限は 16MB（埋めた画像も数える）
  if (bytes > 15 * 1024 * 1024) {
    console.log('15MB を超えた。Artifact の上限 16MB に近いので、画像を減らすか 2 ページに分ける')
    process.exitCode = 1
  }
}

// 画像の画素の色を出す
async function pixel(config, argv) {
  const { positional } = parseArgs(argv, {})
  const [png, ...points] = positional
  if (!png || points.length === 0) throw new UsageError('pixel には画像と座標（x,y）が要る')
  const coords = points.map((p) => {
    const m = /^(\d+),(\d+)$/.exec(p)
    if (!m) throw new UsageError(`座標は x,y の形: ${p}`)
    return [Number(m[1]), Number(m[2])]
  })
  const { chromium } = loadPlaywright(config)
  const browser = await launch(chromium)
  try {
    const tab = await browser.newPage()
    const data = `data:image/png;base64,${readFileSync(png).toString('base64')}`
    const result = await tab.evaluate(
      async ({ d, coords }) => {
        const img = new Image()
        img.src = d
        await img.decode()
        const canvas = document.createElement('canvas')
        canvas.width = img.naturalWidth
        canvas.height = img.naturalHeight
        const ctx = canvas.getContext('2d')
        ctx.drawImage(img, 0, 0)
        return {
          size: `${img.naturalWidth}×${img.naturalHeight}`,
          colors: coords.map(([x, y]) => {
            if (x >= img.naturalWidth || y >= img.naturalHeight) return null
            const [r, g, b] = ctx.getImageData(x, y, 1, 1).data
            return `#${[r, g, b].map((v) => v.toString(16).padStart(2, '0')).join('')}`
          }),
        }
      },
      { d: data, coords },
    )
    console.log(`${basename(png)}（${result.size}）`)
    coords.forEach(([x, y], i) => console.log(`  ${x},${y} ${result.colors[i] ?? '画像の外'}`))
  } finally {
    await browser.close()
  }
}

// 色を [r, g, b]（0〜255）にする。#rgb と #rrggbb を受け付ける
function parseColor(s) {
  const m = /^#?([0-9a-f]{3}|[0-9a-f]{6})$/i.exec(s.trim())
  if (!m) throw new UsageError(`色は #rrggbb の形: ${s}`)
  const h = m[1].length === 3 ? [...m[1]].map((c) => c + c).join('') : m[1]
  return [0, 2, 4].map((i) => parseInt(h.slice(i, i + 2), 16))
}

// WCAG 2 の相対輝度
function luminance([r, g, b]) {
  const lin = (c) => {
    const v = c / 255
    return v <= 0.04045 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4
  }
  return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
}

// 2 色の濃さの差を出す
function contrast(_config, argv) {
  const { positional } = parseArgs(argv, {})
  if (positional.length !== 2) throw new UsageError('contrast には色が 2 つ要る')
  const [a, b] = positional.map((c) => luminance(parseColor(c)))
  const ratio = (Math.max(a, b) + 0.05) / (Math.min(a, b) + 0.05)
  const verdict = ratio >= 4.5 ? '本文の基準 4.5 以上' : ratio >= 3 ? '大きな文字・部品の基準 3 以上（本文には足りない）' : '3 未満'
  console.log(`${ratio.toFixed(2)}（${verdict}）`)
}

// 命令を振り分ける
async function main() {
  const [command, ...rest] = process.argv.slice(2)
  if (!command || command === '--help' || command === '-h') {
    console.log(HELP)
    return
  }
  const commands = { shoot, detect, lint, page: buildPage, pixel, contrast }
  const fn = commands[command]
  if (!fn) throw new UsageError(`知らない命令: ${command}`)
  await fn(loadConfig(), rest)
}

main().catch((e) => {
  if (e instanceof UsageError) {
    console.error(`${e.message}\n（node look.mjs --help で使い方）`)
    process.exit(2)
  }
  console.error(e.message)
  process.exit(1)
})
