#!/usr/bin/env node
// 開発ダッシュボードのハブ。複数リポジトリのダッシュボードを 1 つのプロセスでまとめて配信する。
//
//   node hub.mjs [--root ~/workspace/apps] [--port 8790] [--host 127.0.0.1] [--interval 300] [--open]
//
// - <root>/*/dashboard/update.mjs があるリポジトリを自動で拾う（設定ファイルは無い）
// - 各リポジトリのデータは、そのリポジトリ自身の update.mjs を子プロセスで実行して作る（リポジトリごとの固有指標がそのまま効く）。
//   全リポジトリを並列に回すので、待ち時間はいちばん遅い 1 本ぶん
// - http://<host>:<port>/            一覧（1 アプリ 1 枚のカード：進捗・あなた待ち・CI・作業ツリー・今のタスク）
//   http://<host>:<port>/<app>/      そのリポジトリのダッシュボード（dashboard/index.html をそのまま配信）
//   GET  /<app>/data.js              手元の data.js をすぐ返す。60 秒より古ければ裏で作り直す（待たせない）。--interval 秒ごとにも 60 秒より古いアプリを裏で作り直す
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
// 作り直しは 1 アプリ 7〜8 秒かかる（大半は gh と bd の問い合わせ）。画面を開くたびに待たせないよう、
// 開いたときは手元の data.js をすぐ返し、STALE_MS より古ければ裏で作り直す。加えて REFRESH_MS ごとに全アプリを裏で作り直す
const STALE_MS = 60_000
// --interval 秒ごとに、60 秒より古いアプリを裏で作り直す。既定 300（5 分）、0 で定期の作り直しをしない。数でなければ既定に戻して知らせる
const INTERVAL_ARG = Number(flag('--interval', '300'))
if (!Number.isFinite(INTERVAL_ARG) || INTERVAL_ARG < 0) console.error(`--interval は 0 以上の秒数で指定する（"${flag('--interval')}" は使えないので 300 にする）`)
const REFRESH_MS = (Number.isFinite(INTERVAL_ARG) && INTERVAL_ARG >= 0 ? INTERVAL_ARG : 300) * 1000

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
    // spawn がその場で例外を投げても（ファイル記述子の枯渇など）拒否にせず、error に理由を残して resolve する。
    // 拒否にすると裏の作り直しでは受け手が無く、プロセスごと落ちたり running が残って二度と作り直されなくなる
    let child
    try {
      child = spawn(process.execPath, [path.join(app.dash, 'update.mjs'), '--quiet'], {
        cwd: app.dir,
        stdio: ['ignore', 'ignore', 'pipe'],
        timeout: 180_000,
      })
    } catch (e) {
      s.at = Date.now()
      s.error = `update.mjs を起動できない（${e.message}）`
      s.running = null
      console.error(`[${app.name}] ${s.error}`)
      return resolve(s)
    }
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

/** 古ければ裏で作り直しを始める（待たない）。作り直しの完了は、画面の 60 秒ごとの再読込か「更新」で反映される */
function refreshInBackground(app) {
  const s = state.get(app.name)
  if (s?.running) return
  if (!s || Date.now() - s.at > STALE_MS) regenerate(app).catch((e) => console.error(`[${app.name}] 裏の作り直しに失敗: ${e.message}`))
}

/** 「更新」ボタン用：押した時点より後に始まった作り直しの結果を返す（走っている回が押す前に始まっていれば、終わるのを待ってもう一度） */
async function regenerateNow(app) {
  const running = state.get(app.name)?.running
  if (running) await running
  return regenerate(app)
}

/** data.js（window.DASHBOARD_DATA = {...}）を読んで JSON にする。無ければ value=null、壊れていれば error に理由（握りつぶさず一覧に出す） */
function readData(app) {
  const p = path.join(app.dash, 'data.js')
  if (!fs.existsSync(p)) return { value: null, error: null }
  try {
    const t = fs.readFileSync(p, 'utf8')
    return { value: JSON.parse(t.slice(t.indexOf('{'))), error: null }
  } catch (e) {
    return { value: null, error: `data.js を読めない（${e.message}）` }
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

/** 全角の括弧書き（…）を入れ子ごと取り除く */
function dropParens(s) {
  let out = ''
  let depth = 0
  for (const ch of s) {
    if (ch === '（') depth++
    else if (ch === '）') depth = Math.max(0, depth - 1)
    else if (depth === 0) out += ch
  }
  return out
}

/** 一覧用の短い題名（各ダッシュボードの short() と同じ）：記法・括弧書き・注記・2 文目以降を落とし、長ければ「…」で切る */
function short(s, max = 60) {
  let t = String(s ?? '').replace(/^【[^】]+】\s*/, '')
  t = t.replace(/([）。])\s*\*\*.*$/, '$1').replace(/`|\*\*/g, '')
  t = dropParens(t).split('。')[0]
  const c = t.indexOf('：')
  if (c >= 8) t = t.slice(0, c)
  t = t.replace(/\s+/g, ' ').trim()
  return t.length > max ? t.slice(0, max - 1) + '…' : t
}

/** 全文を見せるときの軽い整形：先頭の【…】・記法・括弧書きだけを落とし、空白を詰める。文や「：」では切らない */
function plain(s) {
  return dropParens(String(s ?? '').replace(/^【[^】]+】\s*/, '').replace(/`|\*\*/g, ''))
    .replace(/\s+/g, ' ')
    .trim()
}

/** 先頭の【…】を種類の札にする（「ユーザー確認」→「確認」） */
const bracketTag = (s) => (String(s).match(/^【([^】]+)】/)?.[1] ?? '').replace(/^ユーザー/, '')
const KIND = { decision: '判断', review: '確認', action: '作業' }

/**
 * そのアプリの「あなた待ち」（Beads の human、TODO の確認待ち、固有の human）。各ダッシュボードと同じ数え方。
 * 優先度の高い順に並べる：Beads は priority（0 が最優先）、固有の human は 2 相当、TODO の確認待ちは優先度を持たないので最後
 */
function humanItems(d) {
  const items = []
  for (const b of d.beads?.human ?? []) {
    const full = String(b.title ?? '').replace(/^\[[^\]]+\]\s*/, '')
    items.push({ kind: (b.labels ?? []).map((l) => KIND[l]).find(Boolean) ?? '確認', text: short(full, 80), full, src: b.id, pri: Number.isFinite(Number(b.priority)) ? Number(b.priority) : 4 })
  }
  // 固有の human は update.mjs が既に短い文で返す前提（テンプレートの index.html と同じく縮めない）
  for (const h of d.specific?.human ?? []) items.push({ kind: h.kind ?? '判断', text: h.text, full: h.full ?? h.text, src: h.src ?? '', pri: 2 })
  for (const a of d.todo?.askItems ?? []) {
    const full = String(a.text ?? '').replace(/\s*完了条件：.*$/, '')
    items.push({ kind: bracketTag(full) || '確認', text: short(full, 80), full, src: `TODO.md:${a.line}`, pri: 5 })
  }
  // sort は安定なので、同じ優先度の中では元の並び（Beads の並び・TODO の上から順）が保たれる
  return items.sort((a, b) => a.pri - b.pri)
}

const TOP_HUMAN = 3 // 一覧の各アプリの枠に出す「あなた待ち」の件数。残りはそのアプリのダッシュボードで見る

/** 1 アプリ分のカードに使う要約を data.js から取る */
function summarize(app) {
  const { value: d, error: readError } = readData(app)
  const s = state.get(app.name)
  if (!d) return { name: app.name, ok: false, error: readError ?? s?.error ?? 'data.js がまだ無い' }
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
  const humanList = humanItems(d)
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
    // 今のタスクは全文を見せる。short() は「：」「。」の後ろを落とすので使わず、記法と括弧書きだけを落とす
    now: plain(first),
    nowFull: first,
    humanList,
    generatedAt: d.generatedAt,
  }
}

/** 1 アプリ分のカード。上段に名前と状態、下段に「今のタスク」（全文）と「あなた待ち」（優先度の高い TOP_HUMAN 件） */
function appCard(r) {
  const head = `<div class="head"><a class="name" href="/${esc(r.name)}/">${esc(r.name)}</a>${r.ok ? `<span class="mono sub">${esc(r.branch)}</span>` : ''}
    <span class="grow"></span><span class="sub">${r.ok ? ago(r.generatedAt) : ''}</span><button type="button" data-app="${esc(r.name)}">更新</button></div>`
  if (!r.ok) return `<section class="app">${head}<div class="s-bad">! ${esc(r.error)}</div></section>`
  const top = r.humanList.slice(0, TOP_HUMAN)
  const rest = r.humanList.length - top.length
  const youList = top.length
    ? `<ul class="list">${top
        .map((it) => `<li><span class="tag k-${esc(it.kind)}">${esc(it.kind)}</span><span class="txt" title="${esc(it.full)}">${esc(it.text)}</span><span class="src">${esc(it.src)}</span></li>`)
        .join('')}</ul>${rest > 0 ? `<a class="more" href="/${esc(r.name)}/">ほか ${rest} 件 →</a>` : ''}`
    : '<div class="sub">なし</div>'
  return `<section class="app ${r.human ? 'you' : ''}">${head}
    <div class="stats">
      <div><div class="kl">進捗</div>${r.pct == null ? '<span class="s-na">–</span>' : `<b>${r.pct}%</b><div class="bar"><i style="width:${r.pct}%"></i></div><div class="sub">残り ${r.open} / ${r.total}</div>`}</div>
      <div><div class="kl">あなた待ち</div><b class="${r.human ? 'you-n' : ''}">${r.human}</b> <span class="sub">件</span></div>
      <div><div class="kl">CI（main）</div>${st(...r.ci)}</div>
      <div><div class="kl">作業ツリー</div>${st(...r.tree)}${r.bad ? `<div class="sub s-bad">✕ 異常 ${r.bad}</div>` : ''}</div>
    </div>
    <div class="body">
      <div><div class="kl">今のタスク</div>${r.now ? `<div class="now txt" title="${esc(r.nowFull)}">${esc(r.now)}</div>` : '<div class="sub">未完タスクなし</div>'}</div>
      <div><div class="kl">あなた待ち（優先度の高い ${TOP_HUMAN} 件）</div>${youList}</div>
    </div>
    ${r.error ? `<div class="sub s-bad">! ${esc(r.error)}</div>` : ''}
  </section>`
}

function hubPage(apps) {
  const rows = apps.map(summarize)
  const startCmd = `node ${process.argv[1]}${HOST !== '127.0.0.1' ? ` --host ${HOST}` : ''}${PORT !== 8790 ? ` --port ${PORT}` : ''} --open`
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
  /* アプリごとのカード */
  .app { background:var(--card); border:1px solid var(--line); border-radius:10px; padding:12px 16px; margin-bottom:12px; }
  .app.you { box-shadow: inset 3px 0 var(--you); }
  .head { display:flex; align-items:baseline; gap:10px; flex-wrap:wrap; }
  .name { font-size:17px; font-weight:700; } .grow { flex:1; }
  .stats { display:grid; grid-template-columns:repeat(4, 1fr); gap:10px; margin:10px 0; padding:10px 0; border-top:1px solid var(--line); border-bottom:1px solid var(--line); }
  .stats b { font-size:20px; font-variant-numeric:tabular-nums; } .you-n { color:var(--you); }
  .body { display:grid; grid-template-columns:2fr 3fr; gap:16px; }
  /* 空白を含まない長い文字列（パス・URL）でも枠からはみ出さないように */
  .body > div, .stats > div { min-width:0; } .now, ul.list .txt { overflow-wrap:anywhere; }
  .kl { font-size:12px; color:var(--sub); margin-bottom:2px; }
  .sub { font-size:12px; color:var(--faint); } .mono { font-family:ui-monospace,Menlo,Consolas,monospace; font-size:12px; }
  .bar { height:5px; background:var(--track); border-radius:3px; overflow:hidden; margin:3px 0; width:110px; } .bar i { display:block; height:100%; background:var(--l3); }
  /* 今のタスクは切らずに折り返して全文を見せる */
  .now { font-size:15px; font-weight:600; line-height:1.45; }
  /* あなた待ちの題名。折り返して見せ、押すと括弧書きまで含めた全文に切り替わる */
  .txt { cursor:pointer; }
  ul.list { list-style:none; margin:0; padding:0; }
  ul.list li { display:flex; align-items:baseline; gap:8px; padding:4px 0; border-top:1px solid var(--line); min-width:0; font-size:14px; }
  ul.list li:first-child { border-top:0; } ul.list .txt { flex:1; min-width:0; }
  .tag { flex:none; font-size:11px; line-height:20px; padding:0 8px; border-radius:4px; background:var(--tag); color:var(--sub); white-space:nowrap; }
  .tag.k-判断 { background:var(--you-bg); color:var(--you); }
  .src { flex:none; font-size:12px; color:var(--faint); white-space:nowrap; }
  .more { display:inline-block; font-size:13px; margin-top:4px; }
  .s-good{color:var(--good)} .s-bad{color:var(--bad)} .s-warn{color:var(--warn)} .s-run{color:var(--link)} .s-na{color:var(--faint)}
  a { color:var(--link); text-decoration:none; } a:hover { text-decoration:underline; }
  .empty { padding:24px; color:var(--faint); }
  @media (max-width: 860px) {
    /* スマートフォン幅：状態は 2 列、今のタスクとあなた待ちは縦に並べ、付箋 ID は隠す */
    .stats { grid-template-columns:1fr 1fr; } .body { grid-template-columns:1fr; } .src { display:none; }
  }
</style></head><body><div class="wrap">
<header><h1>開発ダッシュボード</h1><span class="meta">${apps.length} アプリ · ${esc(ROOT)}</span>
  <button id="howto" type="button">起動方法</button><button id="all" type="button">全部更新</button><div id="hint" hidden></div></header>
${
  apps.length
    ? rows.map(appCard).join('')
    : `<div class="empty">${esc(ROOT)} の直下に dashboard/update.mjs と dashboard/index.html を持つリポジトリがありません。各リポジトリで /apps-workflow:dashboard を呼んで作ってください。</div>`
}
</div>
<script>
const startCmd = ${JSON.stringify(startCmd)}
const hint = document.getElementById('hint')
document.getElementById('howto').addEventListener('click', () => {
  if (!hint.hidden) { hint.hidden = true; return }
  hint.innerHTML = '<div>ターミナルで次を実行すると、このページが開きます（起動したまま置いておく。閉じたら再実行）。各アプリのカードの「更新」でそのアプリだけ、「全部更新」で全部を作り直します。</div><pre>' + startCmd.replace(/[&<>]/g, (c) => ({'&':'&amp;','<':'&lt;','>':'&gt;'}[c])) + '</pre>'
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
// 縮めた題名を押すと全文に切り替わる（もう一度押すと戻る）
document.addEventListener('click', (e) => {
  const el = e.target.closest('.txt[title]')
  if (!el) return
  if (el.dataset.short == null) { el.dataset.short = el.textContent; el.textContent = el.title; el.classList.add('full') }
  else { el.textContent = el.dataset.short; delete el.dataset.short; el.classList.remove('full') }
})
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
      await Promise.all(apps.map(regenerateNow))
      return send(res, 200, JSON.stringify({ ok: true, apps: apps.map((a) => ({ name: a.name, error: state.get(a.name)?.error ?? null })) }), 'application/json')
    }
    const m = url.pathname.match(/^\/([^/]+)(\/.*)?$/)
    // 壊れた % 表記（/%zz/ など）は decode が例外を投げるので、500 ではなく 404 にする
    let wanted = null
    try {
      wanted = m && decodeURIComponent(m[1])
    } catch {
      wanted = null
    }
    const app = wanted && apps.find((a) => a.name === wanted)
    if (!app) return send(res, 404, 'not found', 'text/plain')
    const rest = m[2] ?? ''
    if (rest === '') {
      res.writeHead(302, { location: `/${m[1]}/` })
      return res.end()
    }
    if (rest === '/update' && req.method === 'POST') {
      const s = await regenerateNow(app)
      return send(res, s.error ? 500 : 200, JSON.stringify({ ok: !s.error, error: s.error }), 'application/json')
    }
    if (rest === '/data.js') {
      const p = path.join(app.dash, 'data.js')
      // まだ一度も作っていないときだけ、できるのを待つ。あればすぐ返し、古ければ裏で作り直す
      if (!fs.existsSync(p)) await regenerate(app)
      else refreshInBackground(app)
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
  // 以後は REFRESH_MS ごとに全アプリを裏で作り直す（画面を開いたときに新しいデータがもうある状態にする）
  if (REFRESH_MS > 0) {
    setInterval(() => {
      // ROOT が読めなくなった等で例外が出ても、ハブ自体は落とさず次の回に持ち越す
      try {
        discover().forEach((a) => refreshInBackground(a))
      } catch (e) {
        console.error(`定期の作り直しで失敗（次の回にもう一度試す）: ${e.message}`)
      }
    }, REFRESH_MS)
  }
})
