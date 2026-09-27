#!/usr/bin/env node
// 開発ダッシュボードのハブ。複数リポジトリのダッシュボードを 1 つのプロセスでまとめて配信する。
//
//   node hub.mjs [--root ~/workspace/apps] [--port 8790] [--host 127.0.0.1] [--open]
//
// - <root>/*/dashboard/update.mjs があるリポジトリを自動で拾う（設定ファイルは無い）
// - 各リポジトリのデータは、そのリポジトリ自身の update.mjs を子プロセスで実行して作る（リポジトリごとの固有指標がそのまま効く）。
//   全リポジトリを並列に回すので、待ち時間はいちばん遅い 1 本ぶん
// - http://<host>:<port>/            一覧（進捗・あなた待ち・CI・作業ツリー を 1 行ずつ）
//   http://<host>:<port>/<app>/      そのリポジトリのダッシュボード（dashboard/index.html をそのまま配信）
//   GET  /<app>/data.js              10 秒より古ければ作り直してから返す
//   POST /<app>/update, /update-all  作り直す（画面の「更新」「全部更新」ボタン）
// - 各リポジトリの `node dashboard/update.mjs --serve` はそのまま単独でも使える。ハブはその上に被せるだけ
//
// 依存: Node 標準ライブラリだけ。ダッシュボード独自の状態は持たない（ここに書き込むものは無い）。

import { spawn, spawnSync } from 'node:child_process'
import fs from 'node:fs'
import http from 'node:http'
import os from 'node:os'
import path from 'node:path'

const argv = process.argv.slice(2)
const flag = (k, def) => {
  const i = argv.indexOf(k)
  return i >= 0 ? argv[i + 1] : def
}
const ROOT = path.resolve(flag('--root', path.join(os.homedir(), 'workspace', 'apps')))
const PORT = Number(flag('--port', '8790'))
const HOST = flag('--host', '127.0.0.1')
const STALE_MS = 10_000 // これより古ければ、開くたびに作り直す（配信モードの update.mjs と同じ）

// ---------- リポジトリの発見 ----------

/** root 直下の各ディレクトリのうち dashboard/update.mjs があるものを拾う。一覧は毎回ディスクを見る（新しいアプリにダッシュボードを足したら再起動不要） */
function discover() {
  if (!fs.existsSync(ROOT)) return []
  return fs
    .readdirSync(ROOT, { withFileTypes: true })
    .filter((d) => d.isDirectory() && !d.name.startsWith('.'))
    .map((d) => ({ name: d.name, dir: path.join(ROOT, d.name), dash: path.join(ROOT, d.name, 'dashboard') }))
    .filter((a) => fs.existsSync(path.join(a.dash, 'update.mjs')) && fs.existsSync(path.join(a.dash, 'index.html')))
    .sort((a, b) => a.name.localeCompare(b.name))
}

// ---------- データの生成 ----------

/** アプリごとの生成の状態。running は進行中の Promise（同じアプリを同時に 2 回走らせない） */
const state = new Map() // name -> { at, error, running }

/** そのリポジトリの update.mjs を子プロセスで実行して data.js を作り直す */
function regenerate(app) {
  const s = state.get(app.name) ?? { at: 0, error: null, running: null }
  state.set(app.name, s)
  if (s.running) return s.running
  s.running = new Promise((resolve) => {
    const child = spawn(process.execPath, [path.join(app.dash, 'update.mjs'), '--quiet'], {
      cwd: app.dir,
      stdio: ['ignore', 'ignore', 'pipe'],
      timeout: 180_000,
    })
    let stderr = ''
    child.stderr.on('data', (c) => (stderr += c))
    child.on('close', (code) => {
      s.at = Date.now()
      s.error = code === 0 ? null : `update.mjs が終了コード ${code}（${stderr.trim().split('\n').at(-1) ?? ''}）`
      if (s.error) console.error(`[${app.name}] ${s.error}`)
      s.running = null
      resolve(s)
    })
    child.on('error', (e) => {
      s.at = Date.now()
      s.error = `update.mjs を起動できない（${e.message}）`
      s.running = null
      resolve(s)
    })
  })
  return s.running
}

/** 古ければ作り直す。作り直し中なら終わるのを待つ */
async function ensureFresh(app) {
  const s = state.get(app.name)
  if (s?.running) return s.running
  if (!s || Date.now() - s.at > STALE_MS) return regenerate(app)
  return s
}

/** data.js（window.DASHBOARD_DATA = {...}）を読んで JSON にする。無ければ null */
function readData(app) {
  const p = path.join(app.dash, 'data.js')
  if (!fs.existsSync(p)) return null
  try {
    const t = fs.readFileSync(p, 'utf8')
    return JSON.parse(t.slice(t.indexOf('{')))
  } catch {
    return null
  }
}

// ---------- 一覧ページ ----------

const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c])
const SYM = { good: '✓', bad: '✕', warn: '!', run: '●', na: '–' }
const st = (kind, label) => `<span class="s-${kind}">${SYM[kind]} ${esc(label)}</span>`

function ago(iso) {
  if (!iso) return ''
  const m = Math.max(0, Math.round((Date.now() - Date.parse(iso)) / 60000))
  if (m < 60) return `${m}分前`
  if (m < 60 * 48) return `${Math.round(m / 60)}時間前`
  return `${Math.round(m / 1440)}日前`
}

/** 1 アプリ分の 1 行に使う要約を data.js から取る */
function summarize(app) {
  const d = readData(app)
  const s = state.get(app.name)
  if (!d) return { name: app.name, ok: false, error: s?.error ?? 'data.js がまだ無い' }
  const t = d.todo
  const pct = t && t.total.total ? Math.floor((100 * t.total.done) / t.total.total) : null
  const human = (d.beads?.human?.length ?? 0) + (d.todo?.askItems?.length ?? 0) + (d.specific?.human?.length ?? 0)
  const mainRun = (d.github?.runs ?? []).find((r) => r.branch === 'main')
  const ci = !d.github?.available
    ? ['na', '取得できず']
    : !mainRun
      ? ['na', 'なし']
      : mainRun.status !== 'completed'
        ? ['run', '実行中']
        : mainRun.conclusion === 'success'
          ? ['good', '成功']
          : mainRun.conclusion === 'cancelled'
            ? ['warn', '中止']
            : ['bad', '失敗']
  const dirty = d.git?.dirty?.length ?? 0
  const tree = dirty ? ['warn', `未コミット ${dirty}`] : d.git?.ahead ? ['warn', `未push ${d.git.ahead}`] : ['good', 'クリーン']
  const bad = (d.alerts ?? []).filter((a) => a.level === 'error').length
  const first = t?.openTasks?.[0]?.text ?? ''
  return {
    name: app.name,
    ok: true,
    error: s?.error ?? null,
    pct,
    open: t?.total.open ?? null,
    total: t?.total.total ?? null,
    human,
    ci,
    tree,
    branch: d.git?.branch ?? '',
    bad,
    // 一覧用に縮める：先頭の【…】・記法・括弧書きを落とす（各ダッシュボードの short() と同じ考え方）
    now: first.replace(/^【[^】]+】\s*/, '').replace(/`|\*\*/g, '').replace(/（[^）]*）/g, '').split('。')[0].trim().slice(0, 40),
    generatedAt: d.generatedAt,
  }
}

function hubPage(apps) {
  const rows = apps.map(summarize)
  const startCmd = `node ${process.argv[1]}${HOST !== '127.0.0.1' ? ` --host ${HOST}` : ''}${PORT !== 8790 ? ` --port ${PORT}` : ''} --open`
  const tr = (r) =>
    r.ok
      ? `<tr class="${r.human ? 'you' : ''}">
      <td><a href="/${esc(r.name)}/"><b>${esc(r.name)}</b></a><div class="sub mono">${esc(r.branch)}</div></td>
      <td class="num">${r.pct == null ? '<span class="s-na">–</span>' : `<b>${r.pct}%</b><div class="bar"><i style="width:${r.pct}%"></i></div><div class="sub">残り ${r.open} / ${r.total}</div>`}</td>
      <td class="num ${r.human ? 'you-n' : ''}"><b>${r.human}</b><div class="sub">件</div></td>
      <td>${st(...r.ci)}</td>
      <td>${st(...r.tree)}${r.bad ? `<div class="sub s-bad">✕ 異常 ${r.bad}</div>` : ''}</td>
      <td class="now" title="${esc(r.now)}">${esc(r.now)}</td>
      <td class="sub">${ago(r.generatedAt)}${r.error ? `<div class="s-bad">! ${esc(r.error)}</div>` : ''}</td>
      <td><button type="button" data-app="${esc(r.name)}">更新</button></td>
    </tr>`
      : `<tr><td><b>${esc(r.name)}</b></td><td colspan="6" class="s-bad">! ${esc(r.error)}</td><td><button type="button" data-app="${esc(r.name)}">更新</button></td></tr>`
  return `<!doctype html>
<html lang="ja"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>開発ダッシュボード（全アプリ）</title>
<style>
  :root { --bg:#f4f5f7; --card:#fff; --line:#e4e7ec; --track:#e9ecf1; --ink:#172033; --sub:#566074; --faint:#8b93a3; --link:#1f63b8;
    --good:#1c7c4c; --warn:#93600a; --bad:#b93a2a; --you:#b8432a; --you-bg:#fcebe5; --tag:#eef1f5; --l3:#2a78d6; color-scheme: light dark; }
  @media (prefers-color-scheme: dark) { :root { --bg:#11151d; --card:#181e29; --line:#262e3d; --track:#232b39; --ink:#e7ebf3; --sub:#a3acbe; --faint:#737d90;
    --link:#8db6f2; --good:#6fd39a; --warn:#f0c050; --bad:#f28b74; --you:#f0906c; --you-bg:#3a2019; --tag:#242c3a; --l3:#3f88dd; } }
  * { box-sizing: border-box; }
  body { margin:0; background:var(--bg); color:var(--ink); font:15px/1.5 -apple-system,'Segoe UI','Hiragino Sans','Yu Gothic UI','Noto Sans JP',sans-serif; }
  .wrap { max-width:1180px; margin:0 auto; padding:16px; }
  header { display:flex; flex-wrap:wrap; align-items:baseline; gap:6px 14px; margin-bottom:12px; }
  h1 { font-size:20px; margin:0; } .meta { color:var(--faint); font-size:13px; }
  button { font:inherit; font-size:13px; padding:4px 12px; border-radius:6px; border:1px solid var(--line); background:var(--card); color:var(--ink); cursor:pointer; }
  button:disabled { opacity:.6; cursor:wait; } #all { margin-left:auto; } #howto { color:var(--link); background:none; border:0; padding:4px 2px; }
  #hint { width:100%; font-size:13px; background:var(--card); border:1px solid var(--line); border-radius:8px; padding:10px 14px; }
  #hint pre { margin:6px 0 0; padding:8px 10px; border-radius:6px; background:var(--tag); font-size:12px; white-space:pre-wrap; word-break:break-all; user-select:all; }
  table { width:100%; border-collapse:collapse; background:var(--card); border:1px solid var(--line); border-radius:10px; overflow:hidden; }
  th { text-align:left; font-size:12px; color:var(--sub); font-weight:500; padding:8px 10px; border-bottom:1px solid var(--line); }
  td { padding:10px; border-top:1px solid var(--line); vertical-align:top; }
  tr.you td:first-child { box-shadow: inset 3px 0 var(--you); }
  td.num b { font-size:18px; font-variant-numeric:tabular-nums; } td.you-n b { color:var(--you); }
  .sub { font-size:12px; color:var(--faint); } .mono { font-family:ui-monospace,Menlo,Consolas,monospace; font-size:12px; }
  .bar { height:5px; background:var(--track); border-radius:3px; overflow:hidden; margin:3px 0; width:110px; } .bar i { display:block; height:100%; background:var(--l3); }
  .now { max-width:260px; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; font-size:14px; }
  .s-good{color:var(--good)} .s-bad{color:var(--bad)} .s-warn{color:var(--warn)} .s-run{color:var(--link)} .s-na{color:var(--faint)}
  a { color:var(--link); text-decoration:none; } a:hover { text-decoration:underline; }
  .empty { padding:24px; color:var(--faint); }
  @media (max-width: 860px) {
    table, thead, tbody, tr, td { display:block; } thead { display:none; }
    tr { border-top:1px solid var(--line); padding:8px 0; } td { border:0; padding:4px 10px; } .now { max-width:none; white-space:normal; }
  }
</style></head><body><div class="wrap">
<header><h1>開発ダッシュボード</h1><span class="meta">${apps.length} アプリ · ${esc(ROOT)}</span>
  <button id="howto" type="button">起動方法</button><button id="all" type="button">全部更新</button><div id="hint" hidden></div></header>
${
  apps.length
    ? `<table><thead><tr><th>アプリ</th><th>進捗</th><th>あなた待ち</th><th>CI（main）</th><th>作業ツリー</th><th>今のタスク</th><th>更新</th><th></th></tr></thead>
<tbody>${rows.map(tr).join('')}</tbody></table>`
    : `<div class="empty">${esc(ROOT)} の直下に dashboard/update.mjs と dashboard/index.html を持つリポジトリがありません。各リポジトリで /apps-workflow:dashboard を呼んで作ってください。</div>`
}
</div>
<script>
const startCmd = ${JSON.stringify(startCmd)}
const hint = document.getElementById('hint')
document.getElementById('howto').addEventListener('click', () => {
  if (!hint.hidden) { hint.hidden = true; return }
  hint.innerHTML = '<div>ターミナルで次を実行すると、このページが開きます（起動したまま置いておく。閉じたら再実行）。各アプリの行の「更新」でそのアプリだけ、「全部更新」で全部を作り直します。</div><pre>' + startCmd.replace(/[&<>]/g, (c) => ({'&':'&amp;','<':'&lt;','>':'&gt;'}[c])) + '</pre>'
  hint.hidden = false
})
async function post(url, btn) {
  const label = btn.textContent
  btn.disabled = true; btn.textContent = '更新中…'
  try {
    const res = await fetch(url, { method: 'POST' })
    if (!res.ok) throw new Error('HTTP ' + res.status)
    location.reload()
  } catch (e) {
    btn.disabled = false; btn.textContent = label
    hint.hidden = false
    hint.innerHTML = '<div class="s-bad">更新できませんでした（' + e.message + '）。ハブのプロセスが止まっていれば、右上の「起動方法」のコマンドで起動し直してください。</div>'
  }
}
document.getElementById('all').addEventListener('click', (e) => post('/update-all', e.currentTarget))
for (const b of document.querySelectorAll('button[data-app]')) b.addEventListener('click', (e) => post('/' + e.currentTarget.dataset.app + '/update', e.currentTarget))
// 60 秒ごとに読み直す。ハブが止まっていたら、ブラウザのエラー画面にせずこの画面のまま案内を出す
setInterval(async () => {
  try { const r = await fetch('/', { method: 'HEAD', cache: 'no-store' }); if (!r.ok) throw new Error(); location.reload() }
  catch { hint.hidden = false; hint.innerHTML = '<div class="s-bad">ハブのプロセスが止まりました。右上の「起動方法」のコマンドで起動し直してください。</div>' }
}, 60_000)
</script></body></html>`
}

// ---------- 配信 ----------

const TYPES = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.json': 'application/json', '.svg': 'image/svg+xml', '.png': 'image/png' }

function send(res, status, body, type = 'text/html') {
  res.writeHead(status, { 'content-type': `${type}; charset=utf-8`, 'cache-control': 'no-store' })
  res.end(body)
}

const server = http.createServer(async (req, res) => {
  try {
    const url = new URL(req.url, 'http://x')
    const apps = discover()
    if (url.pathname === '/') return send(res, 200, hubPage(apps))
    if (url.pathname === '/update-all' && req.method === 'POST') {
      await Promise.all(apps.map(regenerate))
      return send(res, 200, JSON.stringify({ ok: true, apps: apps.map((a) => ({ name: a.name, error: state.get(a.name)?.error ?? null })) }), 'application/json')
    }
    const m = url.pathname.match(/^\/([^/]+)(\/.*)?$/)
    const app = m && apps.find((a) => a.name === decodeURIComponent(m[1]))
    if (!app) return send(res, 404, 'not found', 'text/plain')
    const rest = m[2] ?? ''
    if (rest === '') {
      res.writeHead(302, { location: `/${m[1]}/` })
      return res.end()
    }
    if (rest === '/update' && req.method === 'POST') {
      const s = await regenerate(app)
      return send(res, s.error ? 500 : 200, JSON.stringify({ ok: !s.error, error: s.error }), 'application/json')
    }
    if (rest === '/data.js') {
      await ensureFresh(app)
      const p = path.join(app.dash, 'data.js')
      if (!fs.existsSync(p)) return send(res, 500, `window.DASHBOARD_DATA = null // ${state.get(app.name)?.error ?? '生成できず'}`, 'text/javascript')
      return send(res, 200, fs.readFileSync(p), 'text/javascript')
    }
    // それ以外は dashboard/ の中の静的ファイル（index.html 等）。ディレクトリの外には出さない
    const file = rest === '/' ? 'index.html' : path.basename(rest)
    const p = path.join(app.dash, file)
    if (!fs.existsSync(p) || !fs.statSync(p).isFile()) return send(res, 404, 'not found', 'text/plain')
    return send(res, 200, fs.readFileSync(p), TYPES[path.extname(file)] ?? 'text/plain')
  } catch (e) {
    console.error(e)
    return send(res, 500, `error: ${e.message}`, 'text/plain')
  }
})

/** 既定のブラウザで URL を開く。WSL では Windows 側のブラウザを使う。開けなくても止めない */
function openBrowser(url) {
  const isWsl = /microsoft/i.test(fs.existsSync('/proc/version') ? fs.readFileSync('/proc/version', 'utf8') : '')
  const cmd = process.platform === 'win32' || isWsl ? ['cmd.exe', ['/c', 'start', '', url]] : process.platform === 'darwin' ? ['open', [url]] : ['xdg-open', [url]]
  const r = spawnSync(cmd[0], cmd[1], { stdio: 'ignore', timeout: 5_000 })
  if (r.error || r.status !== 0) console.log('ブラウザを開けなかったので、上の URL を手で開いてください')
}

server.listen(PORT, HOST, async () => {
  const url = `http://${HOST === '0.0.0.0' ? 'localhost' : HOST}:${PORT}/`
  const apps = discover()
  console.log(`ダッシュボードのハブ: ${url}  （${apps.length} アプリ: ${apps.map((a) => a.name).join(', ') || 'なし'}。このまま起動しておく。終了は Ctrl+C）`)
  if (argv.includes('--open')) openBrowser(url)
  // 起動時に全部を並列で作り直しておく（一覧を開いたときに古い data.js を見せない）
  await Promise.all(apps.map(regenerate))
  console.log(`初回の生成が終わりました（${apps.filter((a) => !state.get(a.name)?.error).length}/${apps.length} 成功）`)
})
