// 仕組みの図の材料（site/data.js）を、部品のファイルから作り直す
//
// 使い方： node site/build/generate.mjs [--out site/data.js] [--local]
//   --local  手元だけの材料（~/.claude/plugins/installed_plugins.json から「どのアプリに入っているか」）も足す。
//            公開（GitHub Actions）では付けない。本人の環境の情報はコミットしない
// 呼び元： GitHub Actions（pages.yml。main にマージしたとき）、手元で図を見るとき
//
// 読むもの（図の中身は手で書かない。ここで読んだ物だけが図になる）：
//   .claude-plugin/marketplace.json                  カタログ
//   plugins/*/.claude-plugin/plugin.json             名前・版・説明
//   plugins/*/hooks/hooks.json                       フックの登録（いつ・どの道具で動くか）
//   plugins/*/hooks/*.sh, scripts/*.sh, scripts/*.mjs 先頭のコメント（1 行目の役割、「使い方：」「呼び元：」）
//   plugins/*/skills/*/SKILL.md                      frontmatter（name / description / argument-hint / disable-model-invocation / allowed-tools）
//   plugins/*/agents/*.md                            frontmatter（name / description / tools / model）
//   plugins/*/config/*, plugins/*/prompts/sources.json  設定の表と外部から写したプロンプト
//   git log（plugin.json を変えたコミット）           版ごとに増えた・直した・外した部品
//   site/build/flow.json                             1 回の作業の流れ（部品に関わる材料で唯一の手書き。参照する部品が無ければここで止める）
//
// 手で書いてよいのは、Claude Code の仕様で部品のファイルから導けない物だけ：置き場所の図（where）の段の名前と効く範囲。
// 部品の名前・出来事・誰が始めるかは、必ず data から導く（app.js に直書きしない）
//
// 「誰が始めるか」は frontmatter の文から決める（手で分類しない）：
//   フック → 自動 / disable-model-invocation: true → 本人が打つ / 説明に「OK をもらう」→ Claude が提案して OK 後 /
//   説明に「聞かずに呼ぶ」「自分で」→ Claude が自分で / それ以外 → 本人も Claude も

import fs from 'node:fs'
import path from 'node:path'
import os from 'node:os'
import { execFileSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'

const HERE = path.dirname(fileURLToPath(import.meta.url))
const ROOT = path.resolve(HERE, '..', '..')

/** コマンドラインの --名前 値 を読む */
function flag(name, fallback) {
  const i = process.argv.indexOf(name)
  return i >= 0 && process.argv[i + 1] ? process.argv[i + 1] : fallback
}
const OUT = path.resolve(ROOT, flag('--out', 'site/data.js'))
const LOCAL = process.argv.includes('--local')

/** JSON を読む。壊れていればファイル名を添えて止める */
function readJson(file) {
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8'))
  } catch (e) {
    throw new Error(`${path.relative(ROOT, file)} を読めない: ${e.message}`)
  }
}

/** Markdown の frontmatter（--- で囲まれた先頭の部分）を { キー: 値 } で返す。値は 1 行の文字列だけを扱う */
function frontmatter(file) {
  const text = fs.readFileSync(file, 'utf8')
  const m = text.match(/^---\n([\s\S]*?)\n---/)
  if (!m) throw new Error(`${path.relative(ROOT, file)} に frontmatter が無い`)
  const out = {}
  for (const line of m[1].split('\n')) {
    const k = line.match(/^([A-Za-z-]+):\s*(.*)$/)
    if (k) out[k[1]] = k[2].trim()
  }
  if (!out.name || !out.description) throw new Error(`${path.relative(ROOT, file)} の frontmatter に name か description が無い`)
  return out
}

/** スクリプトの先頭コメントから、役割（1 行目）・使い方・呼び元を拾う */
function scriptHeader(file) {
  const lines = fs.readFileSync(file, 'utf8').split('\n').slice(0, 40)
  const comment = lines
    .filter((l) => /^(#|\/\/)/.test(l) && !l.startsWith('#!'))
    .map((l) => l.replace(/^(#|\/\/)\s?/, ''))
  const role = comment.find((l) => l.trim()) ?? ''
  const pick = (label) => {
    const i = comment.findIndex((l) => l.startsWith(label))
    if (i < 0) return ''
    const rest = comment[i].slice(label.length).trim()
    if (rest) return rest
    const next = comment[i + 1] ?? ''
    return next.trim()
  }
  return { role: role.trim(), usage: pick('使い方：'), calledBy: pick('呼び元：') }
}

/** 説明の文から「誰が始めるか」を決める。フックは呼ぶ側で auto を付ける */
function starter(fm) {
  if (fm['disable-model-invocation'] === 'true') return 'human'
  const d = fm.description
  if (/OK をもらう|OK をもらって/.test(d)) return 'propose'
  if (/聞かずに呼ぶ|自分で/.test(d)) return 'claude'
  return 'both'
}

/** フックの matcher（Edit|Write など）を見やすい配列にする */
function matcherList(m) {
  return m ? m.split('|') : []
}

/** 1 つのプラグインの部品を集める */
function collectPlugin(dir) {
  const manifest = readJson(path.join(dir, '.claude-plugin', 'plugin.json'))
  const parts = []
  const rel = (f) => path.relative(ROOT, f)

  // フック：hooks.json の登録を 1 件ずつ。本体のスクリプトの役割も付ける
  const hooksFile = path.join(dir, 'hooks', 'hooks.json')
  if (fs.existsSync(hooksFile)) {
    const hooks = readJson(hooksFile)
    for (const [event, entries] of Object.entries(hooks.hooks ?? {})) {
      for (const entry of entries) {
        for (const h of entry.hooks ?? []) {
          const scriptName = (h.command.match(/\/([^/"]+\.sh)/) ?? [])[1]
          const scriptPath = scriptName ? path.join(dir, 'hooks', scriptName) : null
          const header = scriptPath && fs.existsSync(scriptPath) ? scriptHeader(scriptPath) : { role: '', usage: '', calledBy: '' }
          parts.push({
            id: `hook:${scriptName ?? h.command}`,
            kind: 'hook',
            name: scriptName ?? h.command,
            event,
            matcher: matcherList(entry.matcher),
            timeout: h.timeout ?? null,
            role: header.role,
            starter: 'auto',
            file: scriptPath ? rel(scriptPath) : rel(hooksFile),
          })
        }
      }
    }
  }

  // スキル：skills/*/SKILL.md
  const skillsDir = path.join(dir, 'skills')
  if (fs.existsSync(skillsDir)) {
    for (const s of fs.readdirSync(skillsDir).sort()) {
      const f = path.join(skillsDir, s, 'SKILL.md')
      if (!fs.existsSync(f)) continue
      const fm = frontmatter(f)
      parts.push({
        id: `skill:${fm.name}`,
        kind: 'skill',
        name: fm.name,
        command: `/${manifest.name}:${fm.name}`,
        description: fm.description,
        argumentHint: fm['argument-hint'] ?? null,
        userOnly: fm['disable-model-invocation'] === 'true',
        allowedTools: fm['allowed-tools'] ?? null,
        starter: starter(fm),
        file: rel(f),
        files: fs.readdirSync(path.join(skillsDir, s)).filter((x) => x !== 'SKILL.md'),
      })
    }
  }

  // エージェント：agents/*.md
  const agentsDir = path.join(dir, 'agents')
  if (fs.existsSync(agentsDir)) {
    for (const a of fs.readdirSync(agentsDir).filter((x) => x.endsWith('.md')).sort()) {
      const f = path.join(agentsDir, a)
      const fm = frontmatter(f)
      parts.push({
        id: `agent:${fm.name}`,
        kind: 'agent',
        name: fm.name,
        description: fm.description,
        tools: fm.tools ? fm.tools.split(',').map((t) => t.trim()) : [],
        model: fm.model ?? null,
        starter: 'claude',
        file: rel(f),
      })
    }
  }

  // スクリプト：scripts/*.sh, *.mjs（テストは kind を分ける）と hooks/ の登録されていない補助スクリプト
  const scriptFiles = []
  for (const sub of ['scripts', 'hooks']) {
    const d = path.join(dir, sub)
    if (!fs.existsSync(d)) continue
    for (const f of fs.readdirSync(d).sort()) {
      if (!/\.(sh|mjs)$/.test(f)) continue
      const full = path.join(d, f)
      if (parts.some((p) => p.file === rel(full))) continue // 登録済みのフック本体
      scriptFiles.push(full)
    }
  }
  for (const full of scriptFiles) {
    const name = path.basename(full)
    const header = scriptHeader(full)
    parts.push({
      id: `${name.startsWith('test-') ? 'test' : 'script'}:${name}`,
      kind: name.startsWith('test-') ? 'test' : 'script',
      name,
      role: header.role,
      usage: header.usage,
      calledBy: header.calledBy,
      starter: 'internal',
      file: rel(full),
    })
  }

  // 設定の表：config/*
  const configDir = path.join(dir, 'config')
  if (fs.existsSync(configDir)) {
    for (const c of fs.readdirSync(configDir).sort()) {
      const full = path.join(configDir, c)
      let role = ''
      if (c.endsWith('.json')) {
        const j = readJson(full)
        role = j.about ?? j.description ?? ''
      } else {
        role = scriptHeader(full).role
      }
      parts.push({ id: `config:${c}`, kind: 'config', name: c, role, starter: 'internal', file: rel(full) })
    }
  }

  // 外部から写したプロンプト：prompts/sources.json
  const sources = path.join(dir, 'prompts', 'sources.json')
  if (fs.existsSync(sources)) {
    const j = readJson(sources)
    const list = Array.isArray(j) ? j : (j.sources ?? j.files ?? [])
    // 役割は prompts/README.md の表（| ファイル | 出どころ | ライセンス | 役割 |）の 4 列目から拾う
    const readme = path.join(dir, 'prompts', 'README.md')
    const roles = {}
    if (fs.existsSync(readme)) {
      for (const line of fs.readFileSync(readme, 'utf8').split('\n')) {
        const cells = line.split('|').map((c) => c.trim())
        const m = cells[1]?.match(/^`([^`]+)`$/)
        if (m && cells[4]) roles[m[1]] = cells[4].replace(/\*\*/g, '')
      }
    }
    for (const s of list) {
      parts.push({
        id: `prompt:${s.path ?? s.file ?? s.name}`,
        kind: 'prompt',
        name: s.path ?? s.file ?? s.name,
        role: roles[s.path ?? s.file ?? s.name] ?? s.usedBy ?? '',
        origin: s.repo ? `${s.repo}/${s.upstreamPath ?? ''}` : (s.url ?? ''),
        license: s.license ?? '',
        modified: s.modified ?? false,
        starter: 'internal',
        file: rel(sources),
      })
    }
  }

  // 部品どうしのつながり（誰が誰を使うか）を、先頭コメントと説明の文から拾う
  // 向き：「呼び元：」に q があれば q → p。それ以外は、設定・プロンプトは使われる側、スクリプトはスキルに使われる側、エージェントはスキルに呼ばれる側
  const edges = []
  const add = (from, to) => {
    if (from !== to && !edges.some((e) => e.from === from && e.to === to)) edges.push({ from, to })
  }
  const mentions = (q, text) => {
    if (!text) return false
    if (q.kind === 'skill') {
      // look-tools.json・look.mjs・compete-blind.sh のような別の部品の名前の一部には当てない
      const re = new RegExp(`(?<![\\w-])${q.name}(?![\\w.-])`)
      return re.test(text) || text.includes(`/${manifest.name}:${q.name}`)
    }
    return text.includes(q.name)
  }
  const passive = (k) => k === 'config' || k === 'prompt'
  for (const p of parts) {
    const body = [p.role, p.usage, p.description].filter(Boolean).join(' ')
    for (const q of parts) {
      if (q.id === p.id) continue
      if (mentions(q, p.calledBy)) {
        add(q.id, p.id)
        continue
      }
      if (!mentions(q, body)) continue
      if (q.kind === 'test') continue
      if (passive(p.kind)) add(q.id, p.id)
      else if (passive(q.kind)) add(p.id, q.id)
      else if (p.kind === 'agent' && q.kind === 'skill') add(q.id, p.id)
      else if (p.kind === 'test') add(p.id, q.id)
      else if (p.kind === 'script' && (q.kind === 'skill' || q.kind === 'hook')) add(q.id, p.id)
      else add(p.id, q.id)
    }
  }

  return {
    name: manifest.name,
    displayName: manifest.displayName ?? manifest.name,
    version: manifest.version,
    description: manifest.description,
    repository: manifest.repository ?? null,
    dir: rel(dir),
    parts,
    edges,
  }
}

/** 版の履歴：plugin.json を変えたコミットごとに、版・日付・件名・増えた/直した/外した部品のファイル */
function history(pluginDir) {
  const manifestRel = path.relative(ROOT, path.join(pluginDir, '.claude-plugin', 'plugin.json'))
  let log
  try {
    log = execFileSync('git', ['log', '--format=%H%x09%ad%x09%s', '--date=short', '--', manifestRel], { cwd: ROOT, encoding: 'utf8' })
  } catch (e) {
    throw new Error(`git log を読めない（履歴の浅い checkout では fetch-depth: 0 が要る）: ${e.message}`)
  }
  const commits = log.trim().split('\n').filter(Boolean).map((l) => {
    const [hash, date, subject] = l.split('\t')
    return { hash, date, subject }
  })
  const rel = path.relative(ROOT, pluginDir)
  return commits.map((c, i) => {
    let version = null
    try {
      version = JSON.parse(execFileSync('git', ['show', `${c.hash}:${manifestRel}`], { cwd: ROOT, encoding: 'utf8' })).version
    } catch {
      version = null
    }
    const prev = commits[i + 1]
    const changes = { added: [], modified: [], removed: [] }
    if (prev) {
      const diff = execFileSync('git', ['diff', '--name-status', '-M', prev.hash, c.hash, '--', rel], { cwd: ROOT, encoding: 'utf8' })
      for (const line of diff.trim().split('\n').filter(Boolean)) {
        const [status, a, b] = line.split('\t')
        const f = (b ?? a).replace(`${rel}/`, '')
        if (f.startsWith('.claude-plugin/')) continue
        if (status.startsWith('A')) changes.added.push(f)
        else if (status.startsWith('D')) changes.removed.push(f)
        else changes.modified.push(f)
      }
    }
    return { hash: c.hash.slice(0, 7), date: c.date, subject: c.subject, version, ...changes }
  })
}

/** 手元だけの材料：どのアプリにどの版が入っているか（installed_plugins.json） */
function localInstalls(pluginNames) {
  const f = path.join(os.homedir(), '.claude', 'plugins', 'installed_plugins.json')
  if (!fs.existsSync(f)) return []
  const j = readJson(f)
  const out = []
  const walk = (obj) => {
    if (!obj || typeof obj !== 'object') return
    if (Array.isArray(obj)) return obj.forEach(walk)
    for (const [k, v] of Object.entries(obj)) {
      const base = k.split('@')[0]
      if (pluginNames.includes(base) && Array.isArray(v)) {
        for (const inst of v) out.push({ plugin: base, version: inst.version ?? null, scope: inst.scope ?? null, project: inst.projectPath ? path.basename(inst.projectPath) : null })
      } else if (pluginNames.includes(base) && v && typeof v === 'object') {
        out.push({ plugin: base, version: v.version ?? null, scope: v.scope ?? null, project: v.projectPath ? path.basename(v.projectPath) : null })
      } else walk(v)
    }
  }
  walk(j)
  return out
}

/** 1 回の作業の流れ（site/build/flow.json）。参照する部品が無ければ止める（部品を消したら流れも直す） */
function flow(allParts) {
  const f = path.join(HERE, 'flow.json')
  if (!fs.existsSync(f)) throw new Error('site/build/flow.json が無い（作業の流れの図の材料。消すなら flow.html と generate.mjs の flow() も外す）')
  const j = readJson(f)
  const ids = new Set(allParts.map((p) => p.id))
  for (const step of j.steps) {
    for (const id of step.parts ?? []) {
      if (!ids.has(id)) throw new Error(`site/build/flow.json の手順「${step.title}」が、無い部品 ${id} を指している。部品を消したか改名したなら flow.json も直す`)
    }
  }
  return j
}

// ---------- 本体 ----------

const marketplace = readJson(path.join(ROOT, '.claude-plugin', 'marketplace.json'))
const plugins = marketplace.plugins.map((p) => collectPlugin(path.resolve(ROOT, p.source)))
const allParts = plugins.flatMap((p) => p.parts)

const data = {
  generatedAt: new Date().toISOString(),
  local: LOCAL,
  marketplace: { name: marketplace.name, description: marketplace.description, repository: plugins[0]?.repository ?? null },
  plugins,
  history: Object.fromEntries(plugins.map((p) => [p.name, history(path.resolve(ROOT, p.dir))])),
  flow: flow(allParts),
  installs: LOCAL ? localInstalls(plugins.map((p) => p.name)) : [],
}

fs.mkdirSync(path.dirname(OUT), { recursive: true })
fs.writeFileSync(OUT, `// 自動生成。手で直さない。作り直すには node site/build/generate.mjs\nwindow.SITE_DATA = ${JSON.stringify(data, null, 2)}\n`)
const counts = allParts.reduce((m, p) => ((m[p.kind] = (m[p.kind] ?? 0) + 1), m), {})
console.log(`${path.relative(ROOT, OUT)} を書いた: ${Object.entries(counts).map(([k, v]) => `${k} ${v}`).join(', ')}; 版の履歴 ${Object.values(data.history).flat().length} 件${LOCAL ? `; 導入 ${data.installs.length} 件` : ''}`)
