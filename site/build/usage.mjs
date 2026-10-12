// 使用状況（図 5）の材料（site/usage.js）を、本人のセッション記録から数えて作る
//
// 使い方： node site/build/usage.mjs [--out site/usage.js] [--store <積む場所>] [--projects <セッション記録の置き場>] [--apps-root <apps のフォルダ>] [--full]
//   --full  積んだ値を使い回さず、残っている記録を全部読み直す（記録が消えたセッションの値は、それでも残す）
// 呼び元： systemd のタイマー（~/.config/systemd/user/claude-plugins-usage.timer、週 1 回）、手元で図を見るとき
//
// 読むもの：
//   ${CLAUDE_CONFIG_DIR:-~/.claude}/projects/ の apps のフォルダのセッション記録（*.jsonl と */subagents/*.jsonl。既定 30 日で消える）
//   plugins/*/ の skills・agents・hooks・scripts のファイル名   部品ごとの回数の数え先（id は generate.mjs と同じ「種類:名前」）
//   site/build/usage.json                                   3 節・11 節の切り口（手で書く材料）
// 積む場所： ${XDG_DATA_HOME:-~/.local/share}/claude-plugins/usage-store.json（リポジトリの外。本人の環境の集計なのでコミットしない）
//   セッションごと・日ごとの回数だけを持つ（入力の文やコマンドの中身は持たない）。
//   記録が残っているセッションは数え直して置き換え、記録が消えたセッションは積んだ値を残す。記録は 30 日で消えるので、週 1 回で間に合う
// 書くもの： site/usage.js（window.SITE_USAGE。.gitignore 済みで公開版には出ない）
//
// 数え方の限り：
//   フックは「Claude に何か渡した回数」。黙って終わった回は記録に残らない（check-edited.sh ならエラーを知らせた回数）
//   スクリプトは Claude が Bash で直接動かした回数。スクリプトの中から呼ばれた分（compete-blind.sh の中の codex-run.sh など）は数えない
//   usage.json に切り口を足しても、記録が消えたセッションには遡らない

import fs from 'node:fs'
import path from 'node:path'
import os from 'node:os'
import crypto from 'node:crypto'
import readline from 'node:readline'
import { execFileSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'

const HERE = path.dirname(fileURLToPath(import.meta.url))
const ROOT = path.resolve(HERE, '..', '..')

const ROOT_LABEL = '(apps ルート)'

/** コマンドラインの --名前 値 を読む */
function flag(name, fallback) {
  const i = process.argv.indexOf(name)
  return i >= 0 && process.argv[i + 1] ? process.argv[i + 1] : fallback
}

/** apps のフォルダ。claude-plugins の本体のリポジトリ（別の作業フォルダからでも同じ）の 1 つ上 */
function defaultAppsRoot() {
  try {
    const common = execFileSync('git', ['rev-parse', '--path-format=absolute', '--git-common-dir'], { cwd: ROOT, encoding: 'utf8' }).trim()
    return path.dirname(path.dirname(common))
  } catch {
    return path.dirname(ROOT)
  }
}

const CONFIG_DIR = process.env.CLAUDE_CONFIG_DIR || path.join(os.homedir(), '.claude')
const DATA_HOME = process.env.XDG_DATA_HOME || path.join(os.homedir(), '.local', 'share')
const OUT = path.resolve(ROOT, flag('--out', 'site/usage.js'))
const STORE = path.resolve(flag('--store', path.join(DATA_HOME, 'claude-plugins', 'usage-store.json')))
const PROJECTS = path.resolve(flag('--projects', path.join(CONFIG_DIR, 'projects')))
const APPS_ROOT = path.resolve(flag('--apps-root', defaultAppsRoot()))
const FULL = process.argv.includes('--full')

/** JSON を読む。壊れていればファイル名を添えて止める */
function readJson(file) {
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8'))
  } catch (e) {
    throw new Error(`${file} を読めない: ${e.message}`)
  }
}

/** 日時の文字列を、この PC の時刻での日付（YYYY-MM-DD）にする */
function dayOf(ts) {
  const d = new Date(ts)
  if (Number.isNaN(d.getTime())) return null
  const p = (n) => String(n).padStart(2, '0')
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}`
}

/** その日を含む週の月曜日（YYYY-MM-DD） */
function mondayOf(day) {
  const d = new Date(`${day}T00:00:00`)
  d.setDate(d.getDate() - ((d.getDay() + 6) % 7))
  return dayOf(d)
}

// ---------- 部品の名前（数え先） ----------

/** プラグインごとに、スキル・エージェント・フック・スクリプトの名前を集める。id は generate.mjs と同じ */
function collectPartNames() {
  const marketplace = readJson(path.join(ROOT, '.claude-plugin', 'marketplace.json'))
  const plugins = []
  for (const entry of marketplace.plugins) {
    const dir = path.resolve(ROOT, entry.source)
    const manifest = readJson(path.join(dir, '.claude-plugin', 'plugin.json'))
    const ls = (sub, filter) => (fs.existsSync(path.join(dir, sub)) ? fs.readdirSync(path.join(dir, sub)).filter(filter).sort() : [])
    const skills = ls('skills', (s) => fs.existsSync(path.join(dir, 'skills', s, 'SKILL.md')))
    const agents = ls('agents', (a) => a.endsWith('.md')).map((a) => a.replace(/\.md$/, ''))
    // フックの登録（hooks.json）にある物は hook、それ以外の hooks/・scripts/ の物は script か test
    const hooksFile = path.join(dir, 'hooks', 'hooks.json')
    const registered = new Set()
    if (fs.existsSync(hooksFile)) {
      for (const entries of Object.values(readJson(hooksFile).hooks ?? {})) {
        for (const e of entries) for (const h of e.hooks ?? []) {
          const m = h.command?.match(/\/([^/"]+\.sh)/)
          if (m) registered.add(m[1])
        }
      }
    }
    const scripts = {}
    for (const sub of ['hooks', 'scripts']) {
      for (const f of ls(sub, (x) => /\.(sh|mjs)$/.test(x))) {
        scripts[f] = registered.has(f) ? `hook:${f}` : `${f.startsWith('test-') ? 'test' : 'script'}:${f}`
      }
    }
    plugins.push({ name: manifest.name, skills: new Set(skills), agents: new Set(agents), hooks: registered, scripts })
  }
  return plugins
}

// ---------- 切り口（usage.json） ----------

const KINDS = ['session', 'prompt', 'tool', 'bash', 'skill', 'command', 'agent', 'edit', 'blocked', 'context', 'screen']
const EACH = ['command', 'outside']

/** match を正規表現の形にする。知らない種類や壊れた正規表現はファイルの場所を添えて止める */
function compile(match, where) {
  if (!match || typeof match !== 'object') throw new Error(`usage.json の ${where} に match が無い`)
  const out = {}
  for (const [k, v] of Object.entries(match)) {
    if (!KINDS.includes(k)) throw new Error(`usage.json の ${where} に知らない種類 ${k}（使えるのは ${KINDS.join(' / ')}）`)
    if (v === true) {
      out[k] = true
      continue
    }
    out[k] = [].concat(v).map((s) => {
      try {
        return new RegExp(s)
      } catch (e) {
        throw new Error(`usage.json の ${where} の ${k} の正規表現が壊れている: ${e.message}`)
      }
    })
  }
  return out
}

/** usage.json を読み、数えるための形に直す */
function loadCuts() {
  const file = path.join(HERE, 'usage.json')
  const raw = fs.readFileSync(file, 'utf8')
  const j = readJson(file)
  const rx = (s, where) => {
    try {
      return new RegExp(s)
    } catch (e) {
      throw new Error(`usage.json の ${where} の正規表現が壊れている: ${e.message}`)
    }
  }
  const sections = (j.sections ?? []).map((s) => {
    if (s.each && !EACH.includes(s.each)) throw new Error(`usage.json の ${s.id} の each に知らない種類 ${s.each}（使えるのは ${EACH.join(' / ')}）`)
    return {
      id: s.id,
      title: s.title,
      ref: s.ref ?? '',
      each: s.each ?? null,
      // fromPart の行は部品ごとの回数をそのまま出す（同じ物を 2 通りに数えない）。part の行は、当たった回を部品の回数にも足す
      rows: (s.rows ?? []).map((r) => {
        if (r.since && !/^\d{4}-\d{2}-\d{2}$/.test(r.since)) throw new Error(`usage.json の ${s.id}/${r.id} の since は YYYY-MM-DD で書く（${r.since}）`)
        return {
          id: r.id,
          label: r.label,
          since: r.since ?? null,
          fromPart: r.fromPart ?? null,
          part: r.part ?? null,
          match: r.fromPart ? {} : compile(r.match, `${s.id}/${r.id}`),
        }
      }),
    }
  })
  const sc = j.scenes ?? { rows: [] }
  const scenes = {
    screenFile: rx(sc.screenFile ?? '$^', 'scenes.screenFile'),
    screenFileExclude: sc.screenFileExclude ? rx(sc.screenFileExclude, 'scenes.screenFileExclude') : null,
    rows: (sc.rows ?? []).map((r) => ({
      id: r.id,
      label: r.label,
      part: r.part ?? null,
      listed: r.listed ? rx(r.listed, `scenes/${r.id}.listed`) : null,
      scene: r.scene ? compile(r.scene, `scenes/${r.id}.scene`) : null,
      used: compile(r.used, `scenes/${r.id}.used`),
    })),
  }
  return { raw, notApps: new Set(j.notApps ?? []), sections, scenes }
}

// ---------- 1 本のセッションを数える ----------

/** Bash のコマンドを ; && || | 改行 $( などで区切り、先頭の環境変数の代入を外した 1 区切りずつにする */
function segments(cmd) {
  return cmd
    .split(/\|\||&&|;|\||\n|\$\(|`|\(|\)/)
    .map((s) => s.trim().replace(/^(?:[A-Za-z_][A-Za-z0-9_]*=(?:"[^"]*"|'[^']*'|\S*)\s+)+/, ''))
    .filter(Boolean)
}

/**
 * 1 区切りが、プラグインのスクリプトを動かしているなら、そのファイル名を返す（bash -n などの構文検査は外す）。
 * 変数に入れてから動かす形（L=…/look.mjs; node "$L" …）は、入れた所を 1 回と数える
 * （そのあとの使い方は追わないので、F=…; bash -n "$F" のような検査だけの回も 1 回に入る）
 */
function invokedScript(seg) {
  const tokens = seg.split(/\s+/).map((t) => t.replace(/^["']|["']$/g, ''))
  let target = tokens[0]
  const assign = target.match(/^[A-Za-z_][A-Za-z0-9_]*=["']?(.*?)["']?$/)
  if (assign) target = assign[1]
  else if (['bash', 'sh', 'zsh', 'node'].includes(tokens[0])) {
    const rest = tokens.slice(1)
    if (rest.some((t) => t === '-n' || t === '--check')) return null
    target = rest.find((t) => !t.startsWith('-'))
  }
  const m = target?.match(/(?:apps-workflow(?:\/[\w.-]+)?|CLAUDE_PLUGIN_ROOT\}?)\/(?:scripts|hooks)\/([\w.-]+\.(?:sh|mjs))$/)
  return m ? m[1] : null
}

/** 道具の結果やフックの文を 1 つの文字列にする */
function textOf(content) {
  if (typeof content === 'string') return content
  if (Array.isArray(content)) return content.map((c) => (typeof c === 'string' ? c : (c?.text ?? ''))).join('\n')
  return ''
}

/** 1 本のセッション（本体と、そのサブエージェントの記録）を読んで、日ごとの回数を返す */
async function scanSession(files, ctx) {
  const { plugins, cuts } = ctx
  const days = {}
  const listed = new Set()
  let cwd = null
  let first = null
  let last = null
  let lastDay = null
  const seen = new Set()

  const add = (day, key, n = 1) => {
    if (!day) return
    days[day] ??= {}
    days[day][key] = (days[day][key] ?? 0) + n
  }

  // 1 つの出来事（種類と値）が当たる、切り口の行と場面のキーを返す
  const rowKeys = (kind, value) => {
    const keys = []
    const hit = (match) => {
      const m = match?.[kind]
      return m && (m === true || m.some((re) => re.test(value)))
    }
    for (const s of cuts.sections) {
      for (const r of s.rows) {
        if (!hit(r.match)) continue
        keys.push(`r:${s.id}/${r.id}`)
        if (r.part) keys.push(`p:${r.part}`)
      }
    }
    for (const r of cuts.scenes.rows) {
      if (hit(r.scene)) keys.push(`s:${r.id}`)
      if (hit(r.used)) keys.push(`u:${r.id}`)
    }
    return keys
  }
  const rowHits = (kind, value, day) => {
    for (const k of rowKeys(kind, value)) add(day, k)
  }

  // プラグインの部品か。部品なら id を返す
  const pluginPart = (qualified, kind) => {
    const [pl, name] = qualified.split(':')
    const p = plugins.find((x) => x.name === pl)
    if (!p || !name) return null
    if (kind === 'skill' && p.skills.has(name)) return `skill:${name}`
    if (kind === 'agent' && p.agents.has(name)) return `agent:${name}`
    return null
  }

  const eachSection = (each) => cuts.sections.filter((s) => s.each === each)

  for (const { file, main } of files) {
    const rl = readline.createInterface({ input: fs.createReadStream(file, { encoding: 'utf8' }), crlfDelay: Infinity })
    for await (const line of rl) {
      // 数える物が無い行は JSON として読まない（記録の大半は道具の結果で、重い）
      if (!cwd && line.includes('"cwd"')) {
        try {
          cwd = JSON.parse(line).cwd ?? null
        } catch {
          // 壊れた行は飛ばす（書きかけの最後の行など）
        }
      }
      const interesting =
        line.includes('"tool_use"') ||
        line.includes('"is_error":true') ||
        line.includes('hook_success') ||
        line.includes('hook_additional_context') ||
        line.includes('skill_listing') ||
        (main && (line.includes('"kind":"human"') || line.includes('<command-name>')))
      if (!interesting) continue
      let rec
      try {
        rec = JSON.parse(line)
      } catch {
        continue
      }
      if (rec.uuid) {
        if (seen.has(rec.uuid)) continue
        seen.add(rec.uuid)
      }
      if (rec.timestamp) {
        lastDay = dayOf(rec.timestamp) ?? lastDay
        if (!first || rec.timestamp < first) first = rec.timestamp
        if (!last || rec.timestamp > last) last = rec.timestamp
      }
      const day = lastDay

      // Claude が使った道具
      if (rec.type === 'assistant') {
        for (const c of rec.message?.content ?? []) {
          if (c?.type !== 'tool_use') continue
          const input = c.input ?? {}
          rowHits('tool', c.name, day)
          if (c.name === 'Bash' && typeof input.command === 'string') {
            // 1 つのコマンドの中で同じスクリプト・同じ行に何度当たっても 1 回と数える
            const keys = new Set()
            for (const seg of segments(input.command)) {
              const f = invokedScript(seg)
              for (const p of plugins) if (f && p.scripts[f] && !p.scripts[f].startsWith('hook:')) keys.add(`p:${p.scripts[f]}`)
              for (const k of rowKeys('bash', seg)) keys.add(k)
            }
            for (const k of keys) add(day, k)
          }
          if (c.name === 'Skill' && typeof input.skill === 'string') {
            rowHits('skill', input.skill, day)
            const id = pluginPart(input.skill, 'skill')
            if (id) add(day, `p:${id}`)
            else for (const s of eachSection('outside')) add(day, `e:${s.id}/スキル ${input.skill}`)
          }
          if ((c.name === 'Agent' || c.name === 'Task') && input.subagent_type) {
            rowHits('agent', input.subagent_type, day)
            const id = pluginPart(input.subagent_type, 'agent')
            if (id) add(day, `p:${id}`)
            else for (const s of eachSection('outside')) add(day, `e:${s.id}/エージェント ${input.subagent_type}`)
          }
          if (['Edit', 'Write', 'NotebookEdit', 'MultiEdit'].includes(c.name)) {
            const f = input.file_path ?? input.notebook_path
            if (typeof f === 'string') {
              rowHits('edit', f, day)
              const sf = cuts.scenes
              if (sf.screenFile.test(f) && !sf.screenFileExclude?.test(f)) rowHits('screen', f, day)
            }
          }
          const mcp = c.name.match(/^mcp__(.+?)__/)
          if (mcp) for (const s of eachSection('outside')) add(day, `e:${s.id}/MCP ${mcp[1]}`)
        }
      }

      // 本人の入力・スラッシュコマンド・失敗した道具の結果
      if (rec.type === 'user') {
        const content = rec.message?.content
        if (Array.isArray(content)) {
          for (const c of content) {
            if (c?.type === 'tool_result' && c.is_error) rowHits('blocked', textOf(c.content), day)
          }
        }
        if (main && !rec.isMeta) {
          const text = typeof content === 'string' ? content : Array.isArray(content) ? content.filter((c) => c?.type === 'text').map((c) => c.text).join('\n') : ''
          const cmd = text.match(/<command-name>(\/[^<\s]+)<\/command-name>/)
          if (rec.origin?.kind === 'human' || (!rec.origin && cmd)) rowHits('prompt', '', day)
          if (cmd) {
            rowHits('command', cmd[1], day)
            for (const s of eachSection('command')) add(day, `e:${s.id}/${cmd[1]}`)
            const id = pluginPart(cmd[1].slice(1), 'skill')
            if (id) {
              add(day, `p:${id}`)
              add(day, `h:${id}`)
            }
          }
        }
      }

      // フックが Claude に渡した物・スキルの一覧
      if (rec.type === 'attachment') {
        const a = rec.attachment ?? {}
        if (a.type === 'hook_success') {
          const m = (a.command ?? '').match(/CLAUDE_PLUGIN_ROOT\}?\/hooks\/([\w.-]+\.sh)/)
          for (const p of plugins) if (m && p.hooks.has(m[1])) add(day, `p:hook:${m[1]}`)
        }
        if (a.type === 'hook_additional_context') rowHits('context', textOf(a.content), day)
        if (a.type === 'skill_listing') for (const n of a.names ?? []) listed.add(n)
      }
    }
  }

  // セッションごとに 1 回の行（session）は、始まった日に数える
  if (first) rowHits('session', '', dayOf(first))

  // スキルの一覧は、場面の「使えた」とプラグインのスキルに関わる名前だけを残す
  const keep = [...listed].filter((n) => cuts.scenes.rows.some((r) => r.listed?.test(n)) || pluginPart(n, 'skill'))
  return { cwd, first, last, listed: keep.sort(), days }
}

// ---------- セッションの一覧 ----------

/** Claude Code がセッション記録のフォルダ名にするときと同じく、英数字以外を - にする */
function encodeProjectDir(p) {
  return p.replace(/[^a-zA-Z0-9]/g, '-')
}

/** apps のフォルダに対応するセッション記録のフォルダから、セッションごとのファイルを集める */
function listSessions() {
  if (!fs.existsSync(PROJECTS)) throw new Error(`セッション記録の置き場 ${PROJECTS} が無い（--projects で指定できる）`)
  const prefix = encodeProjectDir(APPS_ROOT)
  const out = new Map()
  for (const dirName of fs.readdirSync(PROJECTS).sort()) {
    if (dirName !== prefix && !dirName.startsWith(`${prefix}-`)) continue
    const dir = path.join(PROJECTS, dirName)
    if (!fs.statSync(dir).isDirectory()) continue
    for (const entry of fs.readdirSync(dir)) {
      const full = path.join(dir, entry)
      const id = entry.replace(/\.jsonl$/, '')
      if (entry.endsWith('.jsonl')) {
        const s = out.get(id) ?? { id, dirName, files: [] }
        s.files.unshift({ file: full, main: true })
        out.set(id, s)
      } else if (fs.existsSync(path.join(full, 'subagents'))) {
        // サブエージェントの記録。ultracode（Workflow）の分は subagents/workflows/<実行>/agent-*.jsonl にある。
        // journal.jsonl は実行の進み具合の控えで、中身はサブエージェントの記録と重なるので読まない
        const s = out.get(id) ?? { id, dirName, files: [] }
        const subs = fs.readdirSync(path.join(full, 'subagents'), { recursive: true })
          .filter((x) => x.endsWith('.jsonl') && path.basename(x) !== 'journal.jsonl')
          .sort()
        for (const f of subs) s.files.push({ file: path.join(full, 'subagents', f), main: false })
        out.set(id, s)
      }
    }
  }
  return [...out.values()].filter((s) => s.files.length)
}

/** p が root そのものか、その中にあるか */
function inside(root, p) {
  const rel = path.relative(root, p)
  return rel === '' || (!rel.startsWith('..') && !path.isAbsolute(rel))
}

/** セッションの作業フォルダ（cwd）から、どのアプリのセッションかを決める。別の作業フォルダ（git worktree）は元のアプリにまとめる */
function projectOf(cwd, dirName, appDirs) {
  const fromDir = () => dirName.slice(encodeProjectDir(APPS_ROOT).length).replace(/^-/, '') || ROOT_LABEL
  if (!cwd || !inside(APPS_ROOT, cwd)) return fromDir()
  const rel = path.relative(APPS_ROOT, cwd)
  if (!rel) return ROOT_LABEL
  const seg = rel.split(path.sep)[0]
  const gitFile = path.join(APPS_ROOT, seg, '.git')
  try {
    if (fs.statSync(gitFile).isFile()) {
      const m = fs.readFileSync(gitFile, 'utf8').match(/^gitdir:\s*(.+?)\/\.git\/worktrees\//m)
      if (m) return path.basename(m[1])
    }
  } catch {
    // .git が無い（消えた作業フォルダ）。下で名前から決める
  }
  if (appDirs.includes(seg)) return seg
  const hit = appDirs.filter((a) => seg.startsWith(`${a}-`)).sort((a, b) => b.length - a.length)[0]
  return hit ?? seg
}

// ---------- まとめる ----------

/** 積んだセッションから、図の材料（window.SITE_USAGE）を作る */
function summarize(store, cuts, pluginNames) {
  const sessions = Object.values(store.sessions)
  const allDays = sessions.flatMap((s) => Object.keys(s.days)).sort()
  const from = allDays[0] ?? null
  const to = allDays[allDays.length - 1] ?? null
  const isApp = (p) => !cuts.notApps.has(p)

  // 週の並び（月曜始まり）
  const weeks = []
  if (from) {
    for (let w = mondayOf(from); w <= mondayOf(to); ) {
      weeks.push(w)
      const d = new Date(`${w}T00:00:00`)
      d.setDate(d.getDate() + 7)
      w = dayOf(d)
    }
  }

  const counts = {}
  const countsApps = {}
  const partByProject = {}
  const human = {}
  const weekly = {}
  const rowTotals = {}
  const rowByProject = {}
  // since のある行は、その日からの回数も別に数える（決まりが入る前の分が混ざり続けないように）
  const sinceOf = Object.fromEntries(cuts.sections.flatMap((sec) => sec.rows.filter((r) => r.since).map((r) => [`${sec.id}/${r.id}`, r.since])))
  const rowSince = {}
  const projects = {}
  for (const s of sessions) {
    projects[s.project] ??= { project: s.project, sessions: 0, prompts: 0, app: isApp(s.project) }
    projects[s.project].sessions++
    for (const [day, keys] of Object.entries(s.days)) {
      const wi = weeks.indexOf(mondayOf(day))
      for (const [k, n] of Object.entries(keys)) {
        if (k.startsWith('p:')) {
          const id = k.slice(2)
          counts[id] = (counts[id] ?? 0) + n
          if (isApp(s.project)) countsApps[id] = (countsApps[id] ?? 0) + n
          partByProject[id] ??= {}
          partByProject[id][s.project] = (partByProject[id][s.project] ?? 0) + n
          weekly[id] ??= weeks.map(() => 0)
          if (wi >= 0) weekly[id][wi] += n
        } else if (k.startsWith('h:')) {
          human[k.slice(2)] = (human[k.slice(2)] ?? 0) + n
        } else if (k.startsWith('r:') || k.startsWith('e:')) {
          const key = k.slice(2)
          rowTotals[key] = (rowTotals[key] ?? 0) + n
          if (sinceOf[key] && day >= sinceOf[key]) rowSince[key] = (rowSince[key] ?? 0) + n
          rowByProject[key] ??= {}
          rowByProject[key][s.project] = (rowByProject[key][s.project] ?? 0) + n
        }
      }
    }
    for (const sec of cuts.sections) {
      const prompt = sec.rows.find((r) => r.match.prompt)
      if (prompt) for (const keys of Object.values(s.days)) projects[s.project].prompts += keys[`r:${sec.id}/${prompt.id}`] ?? 0
    }
  }

  const sections = cuts.sections.map((sec) => {
    const rows = sec.each
      ? Object.keys(rowTotals)
          .filter((k) => k.startsWith(`${sec.id}/`))
          .map((k) => ({ label: k.slice(sec.id.length + 1), n: rowTotals[k], byProject: rowByProject[k] }))
          .sort((a, b) => b.n - a.n || a.label.localeCompare(b.label))
      : sec.rows.map((r) =>
          r.fromPart
            ? { label: r.label, n: counts[r.fromPart] ?? 0, byProject: partByProject[r.fromPart] ?? {} }
            : {
                label: r.label,
                n: rowTotals[`${sec.id}/${r.id}`] ?? 0,
                ...(r.since ? { since: r.since, nSince: rowSince[`${sec.id}/${r.id}`] ?? 0 } : {}),
                byProject: rowByProject[`${sec.id}/${r.id}`] ?? {},
              },
        )
    return { id: sec.id, title: sec.title, ref: sec.ref, rows }
  })

  // 場面：セッションを単位に、使えた・場面があった・使った。
  // 一覧に載る部品（listed がある物）は、場面を「使えたセッションの中で」数える（まだ無かったころの場面は、使わなくて当たり前なので外す）
  const sum = (s, key) => Object.values(s.days).reduce((m, keys) => m + (keys[key] ?? 0), 0)
  const scenes = cuts.scenes.rows.map((r) => {
    const out = { id: r.id, label: r.label, part: r.part, available: null, scene: null, usedInScene: null, used: 0, uses: 0, usedApps: 0 }
    if (r.listed) out.available = 0
    if (r.scene) {
      out.scene = 0
      out.usedInScene = 0
    }
    for (const s of sessions) {
      const avail = r.listed ? s.listed.some((n) => r.listed.test(n)) : true
      const u = sum(s, `u:${r.id}`)
      const sc = sum(s, `s:${r.id}`)
      if (r.listed && avail) out.available++
      out.uses += u
      if (u) out.used++
      if (u && isApp(s.project)) out.usedApps++
      if (r.scene && avail && sc) {
        out.scene++
        if (u) out.usedInScene++
      }
    }
    return out
  })

  // プラグインのスキルが一覧に初めて載った日（それより前は「まだ無かった」）
  const firstListed = {}
  for (const s of sessions) {
    for (const n of s.listed) {
      const [pl, name] = n.split(':')
      if (!name || !pluginNames.includes(pl) || !s.first) continue
      const id = `skill:${name}`
      const d = dayOf(s.first)
      if (!firstListed[id] || d < firstListed[id]) firstListed[id] = d
    }
  }

  return {
    generatedAt: new Date().toISOString(),
    from,
    to,
    days: from ? Math.round((new Date(`${to}T00:00:00`) - new Date(`${from}T00:00:00`)) / 86400000) + 1 : 0,
    sessions: sessions.length,
    notApps: [...cuts.notApps],
    counts,
    countsApps,
    human,
    weeks,
    weekly,
    firstListed,
    projects: Object.values(projects).sort((a, b) => b.sessions - a.sessions),
    sections,
    scenes,
  }
}

// ---------- 本体 ----------

const plugins = collectPartNames()
const cuts = loadCuts()
// 数え方（このファイル・usage.json・部品の名前）が変わったら、記録が残っているセッションを全部数え直す
const rulesHash = crypto
  .createHash('sha1')
  .update(fs.readFileSync(fileURLToPath(import.meta.url)))
  .update(cuts.raw)
  .update(JSON.stringify(plugins.map((p) => [p.name, [...p.skills], [...p.agents], [...p.hooks], p.scripts])))
  .digest('hex')
  .slice(0, 12)

let store = { about: 'claude-plugins の site/build/usage.mjs が積む使用回数（セッションごと・日ごと）。消すと、記録が消えた分は戻らない', version: 1, sessions: {} }
if (fs.existsSync(STORE)) store = readJson(STORE)

const appDirs = fs.readdirSync(APPS_ROOT).filter((d) => fs.statSync(path.join(APPS_ROOT, d)).isDirectory())
const found = listSessions()
let scanned = 0
let reused = 0
let partial = 0
for (const s of found) {
  const sig = `${rulesHash}|${s.files.map(({ file }) => {
    const st = fs.statSync(file)
    return `${path.basename(file)}:${st.size}:${Math.floor(st.mtimeMs)}`
  }).join('|')}`
  const prev = store.sessions[s.id]
  // 本体の記録が消えてサブエージェントの分だけ残ったセッションは、数え直すと小さくなるので積んだ値を残す
  if (prev && !s.files.some((f) => f.main)) {
    partial++
    continue
  }
  if (!FULL && prev?.sig === sig) {
    reused++
    continue
  }
  const r = await scanSession(s.files, { plugins, cuts })
  if (!r.first) continue // 数える物が 1 つも無い記録（開いてすぐ閉じたなど）
  // フォルダ名は英数字以外を - にしたものなので、apps-backup のような名前の頭が同じ隣のフォルダも当たる。作業フォルダで apps の中かを確かめる
  if (r.cwd && !inside(APPS_ROOT, r.cwd)) continue
  store.sessions[s.id] = { project: projectOf(r.cwd, s.dirName, appDirs), sig, first: r.first, last: r.last, listed: r.listed, days: r.days }
  scanned++
}
const foundIds = new Set(found.map((s) => s.id))
const kept = Object.keys(store.sessions).filter((id) => !foundIds.has(id)).length + partial

// 積む（途中で止まっても壊れないよう、別名で書いてから置き換える）
fs.mkdirSync(path.dirname(STORE), { recursive: true })
fs.writeFileSync(`${STORE}.tmp`, JSON.stringify(store))
fs.renameSync(`${STORE}.tmp`, STORE)

const usage = summarize(store, cuts, plugins.map((p) => p.name))
fs.mkdirSync(path.dirname(OUT), { recursive: true })
fs.writeFileSync(OUT, `// 自動生成。手で直さない。作り直すには node site/build/usage.mjs（本人の環境の集計なのでコミットしない）\nwindow.SITE_USAGE = ${JSON.stringify(usage, null, 2)}\n`)
const shown = OUT.startsWith(`${ROOT}${path.sep}`) ? path.relative(ROOT, OUT) : OUT
console.log(
  `${shown} を書いた: 期間 ${usage.from} 〜 ${usage.to}（${usage.days} 日）、セッション ${usage.sessions}` +
    `（数え直し ${scanned}・変わらず ${reused}・記録が消えて積んだ値だけ ${kept}）。積む場所 ${STORE}`,
)
