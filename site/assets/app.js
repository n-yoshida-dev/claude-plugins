// 仕組みの図を描く。材料は data.js（generate.mjs の生成物）だけ。文章は図の脇の 1 行に留め、長い説明は各ページの「AI 向け説明」に置く
// ページは <body data-page="..."> で選ぶ。SVG は手で描ける形（rect・circle・line・path・text）だけで組み、色は CSS のトークンに任せる

const KIND = {
  hook: { label: 'フック', color: 'var(--k-hook)', hint: '出来事が起きたら自動で動く' },
  skill: { label: 'スキル', color: 'var(--k-skill)', hint: '手順書。Claude か本人が呼ぶ' },
  agent: { label: 'エージェント', color: 'var(--k-agent)', hint: '読み取り専用の検品役。スキルが呼ぶ' },
  script: { label: 'スクリプト', color: 'var(--k-script)', hint: 'スキルやフックの裏方' },
  config: { label: '設定の表', color: 'var(--k-config)', hint: '外部由来の値（モデル名・道具の版）' },
  prompt: { label: '写したプロンプト', color: 'var(--k-prompt)', hint: '外部のリポジトリから改変なしで写した文' },
  test: { label: 'テスト', color: 'var(--k-test)', hint: 'CI で回す回帰テスト' },
}
const KIND_ORDER = ['hook', 'skill', 'agent', 'script', 'config', 'prompt', 'test']
const STARTER = {
  auto: { label: '自動で動く', color: 'var(--c-auto)' },
  propose: { label: 'Claude が提案して OK 後', color: 'var(--c-propose)' },
  human: { label: '本人が打つ', color: 'var(--c-human)' },
  claude: { label: 'Claude が自分で呼ぶ', color: 'var(--c-claude)' },
  both: { label: '本人も Claude も', color: 'var(--c-both)' },
  internal: { label: '呼ばれるだけ（裏方）', color: 'var(--c-internal)' },
}
const STARTER_ORDER = ['auto', 'claude', 'propose', 'both', 'human', 'internal']

const data = window.SITE_DATA
const plugin = data?.plugins?.[0]
const parts = plugin?.parts ?? []
const byId = Object.fromEntries(parts.map((p) => [p.id, p]))

// ---------- 小さな道具 ----------

/** HTML の要素を作る */
function el(tag, attrs = {}, children = []) {
  const e = document.createElement(tag)
  for (const [k, v] of Object.entries(attrs)) {
    if (v == null) continue
    if (k === 'text') e.textContent = v
    else if (k === 'html') e.innerHTML = v
    else e.setAttribute(k, v)
  }
  for (const c of [].concat(children)) if (c) e.append(c)
  return e
}
/** SVG の要素を作る */
function svg(tag, attrs = {}, children = []) {
  const e = document.createElementNS('http://www.w3.org/2000/svg', tag)
  for (const [k, v] of Object.entries(attrs)) {
    if (v == null) continue
    if (k === 'text') e.textContent = v
    else e.setAttribute(k, v)
  }
  for (const c of [].concat(children)) if (c) e.append(c)
  return e
}
/** 矢印の先（marker）の定義。1 つの SVG に 1 回入れる */
function defs(id = 'arrow') {
  return svg('defs', {}, [
    svg('marker', { id, viewBox: '0 0 10 10', refX: 9, refY: 5, markerWidth: 7, markerHeight: 7, orient: 'auto-start-reverse' }, [
      svg('path', { d: 'M0,0 L10,5 L0,10 z', fill: 'currentColor' }),
    ]),
  ])
}
/** 角丸の箱と中央の文字 */
function box(x, y, w, h, label, opts = {}) {
  const g = svg('g', { class: opts.cls ?? '' })
  g.append(svg('rect', { x, y, width: w, height: h, rx: 6, class: `box ${opts.soft ? 'soft' : ''}`, style: opts.stroke ? `stroke:${opts.stroke}` : null }))
  if (opts.bar) g.append(svg('rect', { x, y, width: w, height: 4, rx: 2, fill: opts.bar }))
  const lines = [].concat(label)
  lines.forEach((t, i) => {
    g.append(svg('text', { x: x + w / 2, y: y + h / 2 + (i - (lines.length - 1) / 2) * 15 + 4, 'text-anchor': 'middle', class: `label ${i === 0 ? (opts.strong ? 'strong' : '') : 'small'}`, text: t }))
  })
  return g
}
/** 色付きの小さな札（部品の名前） */
function chip(x, y, w, text, color, opts = {}) {
  const g = svg('g', { class: 'chip-g' })
  g.append(svg('rect', { x, y, width: w, height: 20, class: 'chip', style: `fill:${color};fill-opacity:.14;stroke:${color}`, 'stroke-dasharray': opts.dashed ? '3 3' : null }))
  g.append(svg('text', { x: x + w / 2, y: y + 14, 'text-anchor': 'middle', class: 'label', style: 'font-size:10.5px', text: fit(text, w) }))
  if (opts.title) g.append(svg('title', { text: opts.title }))
  return g
}
/** 幅に入らない文字は途中で切る（1 文字 6.4px の見積もり） */
function fit(text, w) {
  const max = Math.floor((w - 10) / 6.4)
  return text.length > max ? text.slice(0, Math.max(1, max - 1)) + '…' : text
}
/** 線と矢印、途中の文字 */
function edge(d, label, opts = {}) {
  const g = svg('g')
  const p = svg('path', { d, class: `edge ${opts.flow ? 'flow' : ''} ${opts.faint ? 'faint' : ''}`, 'marker-end': opts.noArrow ? null : 'url(#arrow)' })
  g.append(p)
  if (label) {
    // 文字の位置は呼ぶ側が lx / ly で渡す
    g.append(svg('text', { x: opts.lx, y: opts.ly, 'text-anchor': opts.anchor ?? 'middle', class: 'edge-label', text: label }))
  }
  return g
}
/** 部品の名前の短い形（id の種類の接頭辞を外す） */
function shortName(id) {
  return id.replace(/^[a-z]+:/, '')
}
/** 長い見出しを 2 行に割る。区切り（・、 空白）があればそこで、無ければ真ん中で */
function wrap2(text, max) {
  if (text.length <= max) return [text]
  const cut = Math.max(...[...text].map((ch, i) => (/[・、 ]/.test(ch) && i > 2 && i < text.length - 2 ? i : -1)))
  const at = cut > 0 ? cut + 1 : Math.ceil(text.length / 2)
  return [text.slice(0, at), text.slice(at)]
}
/** 説明の最初の 1 文だけ */
function firstSentence(text = '') {
  const m = text.match(/^(.*?[。.])(\s|$)/)
  return (m ? m[1] : text).slice(0, 80)
}

// ---------- 図の書き出し（Qiita / note に貼る用） ----------

/** 画面で解決された色や文字の大きさを属性に写し、外に出しても同じ見た目になる SVG を作る */
function flattenSvg(src) {
  const clone = src.cloneNode(true)
  const srcAll = [src, ...src.querySelectorAll('*')]
  const dstAll = [clone, ...clone.querySelectorAll('*')]
  const props = ['fill', 'stroke', 'stroke-width', 'stroke-dasharray', 'font-size', 'font-weight', 'font-family', 'opacity', 'fill-opacity']
  srcAll.forEach((s, i) => {
    const cs = getComputedStyle(s)
    for (const p of props) {
      const v = cs.getPropertyValue(p)
      if (v && v !== 'none' || (p === 'fill' && v === 'none')) dstAll[i].setAttribute(p, v)
    }
    dstAll[i].removeAttribute('class')
    dstAll[i].removeAttribute('style')
  })
  clone.setAttribute('xmlns', 'http://www.w3.org/2000/svg')
  clone.removeAttribute('class')
  const bg = getComputedStyle(document.body).backgroundColor
  const vb = (clone.getAttribute('viewBox') || '0 0 100 100').split(/\s+/).map(Number)
  clone.insertBefore(svg('rect', { x: vb[0], y: vb[1], width: vb[2], height: vb[3], fill: bg }), clone.firstChild)
  clone.setAttribute('width', vb[2])
  clone.setAttribute('height', vb[3])
  return clone
}
/** ファイルを落とす */
function download(name, blob) {
  const a = el('a', { href: URL.createObjectURL(blob), download: name })
  document.body.append(a)
  a.click()
  setTimeout(() => { URL.revokeObjectURL(a.href); a.remove() }, 1000)
}
/** SVG の書き出し */
function exportSvg(src, name) {
  const text = new XMLSerializer().serializeToString(flattenSvg(src))
  download(`${name}.svg`, new Blob([text], { type: 'image/svg+xml' }))
}
/** PNG の書き出し（2 倍の大きさ）。Qiita・note は SVG を受け付けないため */
function exportPng(src, name) {
  const flat = flattenSvg(src)
  const w = Number(flat.getAttribute('width')), h = Number(flat.getAttribute('height'))
  const url = URL.createObjectURL(new Blob([new XMLSerializer().serializeToString(flat)], { type: 'image/svg+xml' }))
  const img = new Image()
  img.onload = () => {
    const c = el('canvas', { width: w * 2, height: h * 2 })
    const ctx = c.getContext('2d')
    ctx.scale(2, 2)
    ctx.drawImage(img, 0, 0)
    c.toBlob((b) => { download(`${name}.png`, b); URL.revokeObjectURL(url) }, 'image/png')
  }
  img.onerror = () => { URL.revokeObjectURL(url); alert('PNG に変換できませんでした。SVG で書き出してください') }
  img.src = url
}
/** 図を <figure> に包み、説明と書き出しボタンを付ける */
function figure(svgEl, caption, name, extraTools = []) {
  const fig = el('figure')
  svgEl.setAttribute('role', 'img')
  svgEl.setAttribute('aria-label', caption)
  fig.append(svgEl)
  const tools = el('div', { class: 'tools' }, [
    ...extraTools,
    el('button', { type: 'button', text: 'SVG を書き出す' }),
    el('button', { type: 'button', text: 'PNG を書き出す' }),
  ])
  tools.children[tools.children.length - 2].onclick = () => exportSvg(svgEl, name)
  tools.children[tools.children.length - 1].onclick = () => exportPng(svgEl, name)
  fig.append(el('figcaption', {}, [el('span', { text: caption }), tools]))
  return fig
}
/** 動く図の「止める／動かす」ボタン */
function playButton(svgEl) {
  const b = el('button', { type: 'button', text: '止める', 'aria-pressed': 'false' })
  b.onclick = () => {
    const paused = b.getAttribute('aria-pressed') === 'true'
    if (paused) { svgEl.unpauseAnimations?.(); svgEl.classList.remove('paused') } else { svgEl.pauseAnimations?.(); svgEl.classList.add('paused') }
    b.setAttribute('aria-pressed', String(!paused))
    b.textContent = paused ? '止める' : '動かす'
  }
  return b
}

// ---------- 1. 全体の概念図 ----------

function pageIndex(root) {
  const W = 960, H = 540
  const s = svg('svg', { viewBox: `0 0 ${W} ${H}` }, [defs()])
  const n = (k) => parts.filter((p) => p.kind === k)
  const hooks = n('hook'), skills = n('skill'), agents = n('agent')
  // 出来事の名前はフックの登録（event と matcher）から、「打つ」の例は本人だけが呼べるスキルから組む
  // 道具に紐づく出来事は matcher（Edit・Write など）で、それ以外は日本語名、表に無い出来事は英語名のまま出す（黙って落とさない）
  const EVENT = { SessionStart: 'セッション開始', Stop: '応答の終わり', UserPromptSubmit: '本人の入力' }
  const events = [...new Set(hooks.map((h) => (h.matcher.length ? h.matcher.join('・') : (EVENT[h.event] ?? h.event))))]
  const humanOnly = skills.filter((p) => p.starter === 'human').map((p) => p.name)

  // 上の段：誰が、何をきっかけに
  s.append(box(40, 24, 160, 56, ['本人', 'スラッシュコマンドを打つ'], { strong: true, bar: 'var(--c-human)' }))
  s.append(box(400, 24, 160, 56, ['Claude', '手順書を読んで呼ぶ'], { strong: true, bar: 'var(--c-claude)' }))
  s.append(box(700, 24, 220, 56, ['出来事', events.join('・')], { strong: true, bar: 'var(--c-auto)' }))

  // 中の段：スキル・エージェント・フック
  const skillBox = { x: 300, y: 170, w: 360, h: 120 }
  s.append(box(skillBox.x, skillBox.y, skillBox.w, skillBox.h, '', { stroke: 'var(--k-skill)' }))
  s.append(svg('text', { x: skillBox.x + 10, y: skillBox.y + 18, class: 'label strong', text: `スキル ${skills.length}` }))
  skills.forEach((p, i) => {
    const col = i % 4, row = Math.floor(i / 4)
    s.append(chip(skillBox.x + 12 + col * 85, skillBox.y + 34 + row * 30, 78, p.name, STARTER[p.starter]?.color ?? 'var(--k-skill)', { title: `${p.command}：${STARTER[p.starter]?.label}` }))
  })
  s.append(svg('text', { x: skillBox.x + skillBox.w - 10, y: skillBox.y + 18, 'text-anchor': 'end', class: 'label small', text: '色＝誰が始めるか（who.html）' }))

  const agentBox = { x: 40, y: 170, w: 200, h: 120 }
  s.append(box(agentBox.x, agentBox.y, agentBox.w, agentBox.h, '', { stroke: 'var(--k-agent)' }))
  s.append(svg('text', { x: agentBox.x + 10, y: agentBox.y + 18, class: 'label strong', text: `エージェント ${agents.length}` }))
  agents.forEach((p, i) => s.append(chip(agentBox.x + 12, agentBox.y + 34 + i * 30, 176, p.name, 'var(--k-agent)', { title: '読み取り専用の検品役' })))

  const hookBox = { x: 720, y: 170, w: 200, h: 176 }
  s.append(box(hookBox.x, hookBox.y, hookBox.w, hookBox.h, '', { stroke: 'var(--k-hook)' }))
  s.append(svg('text', { x: hookBox.x + 10, y: hookBox.y + 18, class: 'label strong', text: `フック ${hooks.length}` }))
  hooks.forEach((p, i) => {
    const y = hookBox.y + 30 + i * 36
    s.append(chip(hookBox.x + 12, y, 176, p.name, 'var(--k-hook)', { title: p.role }))
    s.append(svg('text', { x: hookBox.x + 100, y: y + 31, 'text-anchor': 'middle', class: 'label small', text: `${p.event}${p.matcher.length ? '（' + p.matcher.join(' | ') + '）' : ''}` }))
  })

  // 下の段：裏方
  const back = [
    ['script', 60], ['config', 290], ['prompt', 520], ['test', 750],
  ]
  for (const [k, x] of back) {
    const list = n(k)
    s.append(box(x, 410, 180, 60, [`${KIND[k].label} ${list.length}`, KIND[k].hint], { stroke: KIND[k].color }))
  }

  // 線：誰が誰を使うか
  const L = (d, label, lx, ly, flow = true) => s.append(edge(d, label, { lx, ly, flow }))
  L('M120,80 L120,120 L300,120 L330,170', humanOnly.length ? `打つ（${humanOnly.join('・')} など）` : '打つ', 200, 112)
  L('M480,80 L480,170', '呼ぶ', 505, 130)
  L('M810,80 L810,170', 'きっかけ', 850, 130)
  L('M300,230 L240,230', '検品を頼む', 270, 222)
  L('M400,290 L150,410', '使う', 260, 345)
  L('M480,290 L380,410', '使う', 450, 345)
  L('M560,290 L610,410', '読む', 612, 330)
  L('M760,346 L200,410', '使う', 500, 392)
  L('M230,440 L290,440', '読む', 260, 432, false)
  L('M840,410 L840,346', 'CI で確かめる', 900, 385, false)
  L('M750,440 L660,300', '', 0, 0, false)

  root.append(figure(s, `${plugin.displayName}（v${plugin.version}）の部品 ${parts.length} 個が、誰に呼ばれ、何を使うか`, 'overview', [playButton(s)]))
  root.append(el('p', { class: 'legend' }, STARTER_ORDER.filter((k) => k !== 'internal').map((k) => el('span', { style: `--c:${STARTER[k].color}`, text: STARTER[k].label }))))
}

// ---------- 2＋6. 組み合わせと 1 回の作業の流れ ----------

function pageFlow(root) {
  const flow = data.flow
  if (!flow) { root.append(el('p', { class: 'empty', text: 'site/build/flow.json が無いので、この図は作れません' })); return }
  const steps = flow.steps
  const colW = 124, W = 40 + steps.length * colW, H = 80 + 40 + Math.max(...steps.map((st) => st.parts.length)) * 26 + 40
  const s = svg('svg', { viewBox: `0 0 ${W} ${H}` }, [defs()])
  const lineY = 48
  s.append(svg('line', { x1: 20, y1: lineY, x2: W - 20, y2: lineY, class: 'edge', 'marker-end': 'url(#arrow)' }))
  const dur = steps.length * 2.2
  steps.forEach((st, i) => {
    const cx = 40 + i * colW + colW / 2
    const g = svg('g')
    const color = STARTER[st.actor]?.color ?? 'currentColor'
    g.append(svg('circle', { cx, cy: lineY, r: 9, class: 'box', style: `stroke:${color};stroke-width:2`, 'stroke-dasharray': st.optional ? '3 3' : null }))
    g.append(svg('text', { x: cx, y: lineY + 4, 'text-anchor': 'middle', class: 'label small', text: String(i + 1) }))
    const title = wrap2(st.title, 10)
    title.forEach((t, k) => g.append(svg('text', { x: cx, y: lineY + 28 + k * 14, 'text-anchor': 'middle', class: 'label', style: 'font-size:11.5px', text: t })))
    if (st.optional) g.append(svg('text', { x: cx, y: lineY + 28 + title.length * 14, 'text-anchor': 'middle', class: 'label small', text: '必要なときだけ' }))
    st.parts.forEach((id, j) => {
      const p = byId[id]
      g.append(chip(cx - colW / 2 + 8, lineY + 70 + j * 26, colW - 16, shortName(id), KIND[p.kind].color, { title: `${KIND[p.kind].label}：${p.role ?? firstSentence(p.description)}` }))
    })
    // 今どの手順かを明るさで示す（SMIL。script は使わない）
    const t0 = i / steps.length, t1 = (i + 1) / steps.length
    const e = 0.02
    g.append(svg('animate', { attributeName: 'opacity', values: '0.35;0.35;1;1;0.35;0.35', keyTimes: `0;${Math.max(0, t0 - e)};${t0};${t1 - e};${Math.min(1, t1)};1`, dur: `${dur}s`, repeatCount: 'indefinite' }))
    s.append(g)
  })
  // 流れを示す玉
  const dot = svg('circle', { cy: lineY, r: 5, fill: 'var(--accent)', class: 'pulse' })
  dot.append(svg('animate', { attributeName: 'cx', values: steps.map((_, i) => 40 + i * colW + colW / 2).join(';'), keyTimes: steps.map((_, i) => (i / (steps.length - 1)).toFixed(3)).join(';'), dur: `${dur}s`, repeatCount: 'indefinite', calcMode: 'linear' }))
  s.append(dot)
  root.append(figure(s, '1 回の作業の流れ。手順ごとに、どの部品が組み合わさって動くか', 'flow', [playButton(s)]))
  root.append(el('p', { class: 'legend' }, [
    ...['auto', 'claude', 'propose', 'both', 'human'].map((k) => el('span', { style: `--c:${STARTER[k].color}`, text: `丸＝${STARTER[k].label}` })),
    ...['hook', 'skill', 'agent', 'script', 'config'].map((k) => el('span', { style: `--c:${KIND[k].color}`, text: `札＝${KIND[k].label}` })),
  ]))
  const notes = el('ol', { class: 'meta' })
  steps.forEach((st) => notes.append(el('li', { text: `${st.title}：${st.note}` })))
  root.append(notes)
}

// ---------- 3＋4. 各機能の概念図と仕様 ----------

function miniGraph(p) {
  const ins = plugin.edges.filter((e) => e.to === p.id).map((e) => byId[e.from]).filter(Boolean)
  const outs = plugin.edges.filter((e) => e.from === p.id).map((e) => byId[e.to]).filter(Boolean)
  const rows = Math.max(ins.length, outs.length, 1)
  const W = 300, H = 20 + rows * 26
  const s = svg('svg', { viewBox: `0 0 ${W} ${H}` }, [defs(`a-${p.id.replace(/[^a-z0-9]/gi, '')}`)])
  const marker = `url(#a-${p.id.replace(/[^a-z0-9]/gi, '')})`
  const cy = H / 2
  s.append(chip(105, cy - 10, 90, p.name, KIND[p.kind].color))
  ins.forEach((q, i) => {
    const y = 10 + i * 26
    s.append(chip(4, y, 84, shortName(q.id), KIND[q.kind].color, { title: KIND[q.kind].label }))
    s.append(svg('path', { d: `M88,${y + 10} L105,${cy}`, class: 'edge faint', 'marker-end': marker }))
  })
  outs.forEach((q, i) => {
    const y = 10 + i * 26
    s.append(chip(212, y, 84, shortName(q.id), KIND[q.kind].color, { title: KIND[q.kind].label }))
    s.append(svg('path', { d: `M195,${cy} L212,${y + 10}`, class: 'edge faint', 'marker-end': marker }))
  })
  if (!ins.length && !outs.length) s.append(svg('text', { x: W / 2, y: H - 4, 'text-anchor': 'middle', class: 'label small', text: '単独で動く' }))
  s.setAttribute('role', 'img')
  s.setAttribute('aria-label', `${p.name} を呼ぶもの ${ins.length}、${p.name} が使うもの ${outs.length}`)
  const f = el('figure')
  f.append(s)
  return f
}
function spec(p) {
  const dl = el('dl')
  const add = (k, v) => { if (v != null && v !== '' && !(Array.isArray(v) && !v.length)) { dl.append(el('dt', { text: k }), el('dd', { text: Array.isArray(v) ? v.join('、') : String(v) })) } }
  if (p.kind === 'hook') { add('いつ', `${p.event}${p.matcher.length ? '（' + p.matcher.join(' | ') + '）' : ''}`); add('制限時間', p.timeout ? `${p.timeout} 秒` : null) }
  if (p.kind === 'skill') { add('呼び方', p.command + (p.argumentHint ? ' ' + p.argumentHint : '')); add('誰が始める', STARTER[p.starter]?.label); add('Claude から', p.userOnly ? '呼べない（本人だけ）' : '呼べる'); add('事前に許す道具', p.allowedTools); add('同じフォルダの物', p.files) }
  if (p.kind === 'agent') { add('使える道具', p.tools); add('モデル', p.model === 'inherit' ? '呼び元と同じ' : p.model) }
  if (p.kind === 'script' || p.kind === 'test') { add('使い方', p.usage); add('呼び元', p.calledBy) }
  if (p.kind === 'prompt') { add('出どころ', p.origin); add('ライセンス', p.license); add('改変', p.modified ? 'あり' : 'なし') }
  add('ファイル', p.file)
  return dl
}
function pageParts(root) {
  for (const k of KIND_ORDER) {
    const list = parts.filter((p) => p.kind === k)
    if (!list.length) continue
    root.append(el('h2', { id: k, text: `${KIND[k].label} ${list.length}`, style: `border-left:4px solid ${KIND[k].color};padding-left:8px` }))
    root.append(el('p', { class: 'claim', text: KIND[k].hint }))
    const grid = el('div', { class: 'cards' })
    for (const p of list) {
      const card = el('div', { class: 'card', id: p.id, style: `--k:${KIND[k].color}` })
      card.append(el('h3', {}, [el('span', { text: p.name }), p.command ? el('code', { text: p.command }) : null]))
      card.append(el('p', { class: 'role', text: p.role || firstSentence(p.description) }))
      card.append(miniGraph(p))
      card.append(spec(p))
      if (p.description && p.description.length > 80) card.append(el('details', {}, [el('summary', { text: '説明の全文（AI 向け）' }), el('p', { text: p.description })]))
      grid.append(card)
    }
    root.append(grid)
  }
}

// ---------- 7. 誰が始めるか ----------

function pageWho(root) {
  const cols = STARTER_ORDER.map((k) => ({ k, list: parts.filter((p) => (p.starter ?? 'internal') === k && p.kind !== 'test') }))
  const colW = 156, W = 20 + cols.length * colW, rows = Math.max(...cols.map((c) => c.list.length))
  const H = 70 + rows * 26 + 10
  const s = svg('svg', { viewBox: `0 0 ${W} ${H}` })
  cols.forEach((c, i) => {
    const x = 10 + i * colW
    s.append(svg('rect', { x, y: 10, width: colW - 10, height: 36, rx: 6, fill: STARTER[c.k].color, 'fill-opacity': 0.18 }))
    const label = wrap2(STARTER[c.k].label, 11)
    label.forEach((t, j) => s.append(svg('text', { x: x + (colW - 10) / 2, y: 24 + j * 13 + (label.length === 1 ? 7 : 0), 'text-anchor': 'middle', class: 'label', style: 'font-size:11.5px;font-weight:700', text: t })))
    s.append(svg('text', { x: x + (colW - 10) / 2, y: 62, 'text-anchor': 'middle', class: 'label small', text: `${c.list.length} 個` }))
    c.list.forEach((p, j) => s.append(chip(x + 4, 70 + j * 26, colW - 18, p.name, KIND[p.kind].color, { title: `${KIND[p.kind].label}：${p.role ?? firstSentence(p.description)}` })))
  })
  root.append(figure(s, '部品ごとに、誰がきっかけで動くか。列が始める人、札の色が部品の種類', 'who'))
  root.append(el('p', { class: 'legend' }, KIND_ORDER.filter((k) => k !== 'test').map((k) => el('span', { style: `--c:${KIND[k].color}`, text: KIND[k].label }))))
  root.append(el('p', { class: 'meta', text: '分け方は手で決めていない。フックは自動、disable-model-invocation が true なら本人だけ、説明に「OK をもらう」があれば提案して OK 後、「聞かずに呼ぶ」「自分で」があれば Claude が自分で、それ以外は両方。' }))
}

// ---------- 8. 置き場所 ----------

function pageWhere(root) {
  const W = 960, H = 500
  const s = svg('svg', { viewBox: `0 0 ${W} ${H}` }, [defs()])
  const layer = (y, title, sub, right, color) => {
    s.append(svg('rect', { x: 40, y, width: 880, height: 84, rx: 8, class: 'box soft' }))
    s.append(svg('rect', { x: 40, y, width: 6, height: 84, rx: 3, fill: color }))
    s.append(svg('text', { x: 60, y: y + 24, class: 'label strong', text: title }))
    s.append(svg('text', { x: 60, y: y + 44, class: 'label small', text: sub }))
    s.append(svg('text', { x: 900, y: y + 24, 'text-anchor': 'end', class: 'label small', text: right }))
  }
  layer(20, '~/.claude/', 'CLAUDE.md（全プロジェクトの決まり）・settings.json（権限と全体のフック）・plugins/installed_plugins.json（導入の記録）', 'どのリポジトリでも効く', 'var(--c-human)')
  layer(130, '~/workspace/apps/CLAUDE.md', 'apps 共通の決まり（文書の型・PR の手順・公開の順番）', 'apps の下で効く', 'var(--c-both)')
  layer(240, `claude-plugins（このリポジトリ）`, `マーケットプレイス ${data.marketplace.name} → プラグイン ${plugin.name} v${plugin.version}：フック・スキル・エージェント・スクリプトの本体`, '導入したリポジトリで効く', 'var(--c-claude)')
  layer(350, '各アプリ/', '.claude/settings.json の enabledPlugins でプラグインを有効にする。CLAUDE.md にそのアプリ固有の決まり', 'そのアプリだけ', 'var(--c-auto)')
  // 読まれる順と、導入の線
  s.append(edge('M480,104 L480,130', '上から順に読まれ、下が上を細かくする', { lx: 495, ly: 122, anchor: 'start' }))
  s.append(edge('M480,214 L480,240', ''))
  s.append(edge('M480,324 L480,350', ''))
  s.append(edge('M860,104 C930,170 930,210 870,240', '導入の記録', { lx: 850, ly: 232, anchor: 'end' }))
  s.append(edge('M120,434 C60,380 60,320 110,324', 'enabledPlugins で読む', { lx: 60, ly: 342, anchor: 'start', flow: true }))
  // 手元の材料があれば、導入しているアプリを並べる
  const installs = data.installs ?? []
  if (installs.length) {
    installs.slice(0, 10).forEach((it, i) => {
      s.append(chip(60 + (i % 5) * 170, 448 + Math.floor(i / 5) * 24, 160, `${it.project ?? '?'} v${it.version ?? '?'}${it.scope ? '（' + it.scope + '）' : ''}`, it.version === plugin.version ? 'var(--c-auto)' : 'var(--c-human)'))
    })
  } else {
    s.append(svg('text', { x: 60, y: 462, class: 'label small', text: '公開版では、どのアプリに入っているかは出さない（手元で node site/build/generate.mjs --local）' }))
  }
  root.append(figure(s, '決まりと部品がどこに置かれ、どの範囲に効くか', 'where'))
}

// ---------- 9. 変わった記録 ----------

function pageChanges(root) {
  const hist = data.history[plugin.name] ?? []
  if (!hist.length) { root.append(el('p', { class: 'empty', text: '版の履歴が無い（git の履歴を浅く取った checkout かもしれない）' })); return }
  const asc = [...hist].reverse()
  const W = 960, H = 150
  const s = svg('svg', { viewBox: `0 0 ${W} ${H}` }, [defs()])
  const t = (d) => new Date(d).getTime()
  const t0 = t(asc[0].date), t1 = t(asc[asc.length - 1].date) || t0 + 1
  const x = (d) => 40 + ((t(d) - t0) / Math.max(1, t1 - t0)) * 880
  s.append(svg('line', { x1: 30, y1: 90, x2: 940, y2: 90, class: 'edge', 'marker-end': 'url(#arrow)' }))
  asc.forEach((h, i) => {
    const n = h.added.length + h.modified.length + h.removed.length
    const r = 4 + Math.min(12, Math.sqrt(n) * 2)
    const g = svg('g')
    g.append(svg('circle', { cx: x(h.date), cy: 90, r, fill: h.removed.length ? 'var(--c-human)' : h.added.length ? 'var(--c-auto)' : 'var(--c-claude)', 'fill-opacity': 0.7 }))
    g.append(svg('title', { text: `${h.date} v${h.version ?? '?'}：${h.subject}` }))
    if (i % 3 === 0 || i === asc.length - 1) g.append(svg('text', { x: x(h.date), y: 90 + (i % 2 ? -22 : 34), 'text-anchor': 'middle', class: 'label small', text: `v${h.version ?? '?'}` }))
    s.append(g)
  })
  s.append(svg('text', { x: 40, y: 20, class: 'label small', text: asc[0].date }))
  s.append(svg('text', { x: 920, y: 20, 'text-anchor': 'end', class: 'label small', text: asc[asc.length - 1].date }))
  root.append(figure(s, `版の履歴 ${hist.length} 件。丸の大きさは変えたファイルの数、色は増えた（緑）・直した（青）・外した（赤）`, 'changes'))
  const list = el('div')
  for (const h of hist) {
    const row = el('div', { class: 'row' })
    row.append(el('div', { class: 'meta', text: h.date }), el('div', { text: `v${h.version ?? '?'}` }))
    const body = el('div', { class: 'subject' })
    body.append(el('div', { text: h.subject.replace(/\s*\(#\d+\)\s*$/, '') }))
    const bars = el('div', { class: 'bars' })
    const unit = 6
    if (h.added.length) bars.append(el('i', { class: 'add', style: `width:${h.added.length * unit}px`, title: `増えた ${h.added.length}` }))
    if (h.modified.length) bars.append(el('i', { class: 'mod', style: `width:${h.modified.length * unit}px`, title: `直した ${h.modified.length}` }))
    if (h.removed.length) bars.append(el('i', { class: 'del', style: `width:${h.removed.length * unit}px`, title: `外した ${h.removed.length}` }))
    body.append(bars)
    const ul = el('ul')
    h.added.forEach((f) => ul.append(el('li', { text: `＋ ${f}` })))
    h.removed.forEach((f) => ul.append(el('li', { text: `－ ${f}` })))
    h.modified.forEach((f) => ul.append(el('li', { text: `± ${f}` })))
    body.append(el('details', {}, [el('summary', { text: `ファイル ${h.added.length + h.modified.length + h.removed.length}` }), ul]))
    row.append(body)
    list.append(row)
  }
  root.append(list)
}

// ---------- 5. 使用状況 ----------

function pageUsage(root) {
  const u = window.SITE_USAGE
  if (!u) {
    root.append(el('p', { class: 'empty', html: '手元の集計がまだありません。集計は本人の環境のセッション記録から作るので、公開版には載せません。<br>作る： <code>node site/build/usage.mjs</code>（週 1 回。結果は site/usage.js で、コミット対象から外れている）' }))
    return
  }
  root.append(el('p', { class: 'meta', text: `集計期間 ${u.from} 〜 ${u.to}（${u.days} 日）。最終集計 ${u.generatedAt?.slice(0, 10)}` }))
  const rows = Object.entries(u.counts ?? {}).sort((a, b) => b[1] - a[1])
  const max = Math.max(1, ...rows.map((r) => r[1]))
  const W = 960, H = 20 + rows.length * 24
  const s = svg('svg', { viewBox: `0 0 ${W} ${H}` })
  rows.forEach(([id, n], i) => {
    const p = byId[id]
    const y = 10 + i * 24
    s.append(svg('text', { x: 230, y: y + 14, 'text-anchor': 'end', class: 'label', text: shortName(id) }))
    s.append(svg('rect', { x: 240, y: y + 2, width: Math.max(2, (n / max) * 620), height: 16, rx: 3, fill: p ? KIND[p.kind].color : 'var(--c-internal)', 'fill-opacity': 0.8 }))
    s.append(svg('text', { x: 248 + Math.max(2, (n / max) * 620), y: y + 14, class: 'label small', text: String(n) }))
  })
  root.append(figure(s, '部品ごとの使用回数（集計期間の合計）', 'usage'))
}

// ---------- 起動 ----------

const PAGES = { index: pageIndex, flow: pageFlow, parts: pageParts, who: pageWho, where: pageWhere, changes: pageChanges, usage: pageUsage }
const root = document.getElementById('fig')
if (!data || !plugin) {
  root.append(el('p', { class: 'empty', html: 'data.js が無い。<code>node site/build/generate.mjs</code> で作る' }))
} else {
  PAGES[document.body.dataset.page]?.(root)
  const meta = document.getElementById('meta')
  if (meta) meta.textContent = `${plugin.displayName} v${plugin.version} ・ 部品 ${parts.length} ・ 生成 ${data.generatedAt.slice(0, 16).replace('T', ' ')} UTC${data.local ? '（手元の材料あり）' : ''}`
}
