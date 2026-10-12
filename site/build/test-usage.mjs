// usage.mjs の回帰テスト。偽のセッション記録を一時フォルダに作って数えさせ、回数を確かめる（本人の記録と積む場所には触れない）
//
// 使い方： node site/build/test-usage.mjs
// 呼び元： CI（ci.yml）。usage.json の正規表現が壊れていないか、数え方が変わっていないかを見る

import fs from 'node:fs'
import path from 'node:path'
import os from 'node:os'
import { execFileSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'

const HERE = path.dirname(fileURLToPath(import.meta.url))
const TMP = fs.mkdtempSync(path.join(os.tmpdir(), 'usage-test-'))
const APPS = path.join(TMP, 'apps')
const PROJECTS = path.join(TMP, 'projects')
const STORE = path.join(TMP, 'store.json')
const OUT = path.join(TMP, 'usage.js')
const enc = (p) => p.replace(/[^a-zA-Z0-9]/g, '-')
let failed = 0

/** 期待どおりかを 1 行で出す */
function check(name, actual, expected) {
  const ok = JSON.stringify(actual) === JSON.stringify(expected)
  if (!ok) failed++
  console.log(`${ok ? 'OK ' : 'NG '} ${name}${ok ? '' : `（期待 ${JSON.stringify(expected)}、実際 ${JSON.stringify(actual)}）`}`)
}

/** 偽のセッション記録を 1 本書く。cwd を渡すと、apps の外の作業フォルダのセッションにできる */
function session(app, id, lines, subagent = null, cwd = path.join(APPS, app)) {
  const dir = path.join(PROJECTS, `${enc(APPS)}-${app}`)
  fs.mkdirSync(dir, { recursive: true })
  let n = 0
  const rec = (r) => JSON.stringify({ uuid: `${id}-${n++}`, cwd, sessionId: id, timestamp: '2026-10-12T03:00:00.000Z', ...r })
  fs.writeFileSync(path.join(dir, `${id}.jsonl`), lines.map(rec).join('\n') + '\n')
  if (subagent) {
    const sub = path.join(dir, id, 'subagents', 'workflows', 'wf_test')
    fs.mkdirSync(sub, { recursive: true })
    fs.writeFileSync(path.join(sub, 'agent-a.jsonl'), subagent.map(rec).join('\n') + '\n')
    fs.writeFileSync(path.join(sub, 'journal.jsonl'), subagent.map(rec).join('\n') + '\n') // 読まない物
  }
  return path.join(dir, `${id}.jsonl`)
}
const tool = (name, input) => ({ type: 'assistant', message: { content: [{ type: 'tool_use', id: `t-${Math.random()}`, name, input }] } })

/** usage.mjs を動かし、出力の 1 行目と window.SITE_USAGE を返す */
function run() {
  const log = execFileSync('node', [path.join(HERE, 'usage.mjs'), '--projects', PROJECTS, '--apps-root', APPS, '--store', STORE, '--out', OUT], { encoding: 'utf8' })
  const window = {}
  new Function('window', fs.readFileSync(OUT, 'utf8'))(window)
  return { log, u: window.SITE_USAGE }
}

try {
  fs.mkdirSync(path.join(APPS, 'myapp'), { recursive: true })
  fs.mkdirSync(path.join(APPS, 'claude-plugins'), { recursive: true })

  session('myapp', 's1', [
    { type: 'user', origin: { kind: 'human' }, message: { content: '画面を直して' } },
    { type: 'user', message: { content: '<command-name>/apps-workflow:handoff</command-name>' } },
    { type: 'attachment', attachment: { type: 'skill_listing', names: ['apps-workflow:look', 'apps-workflow:pr-flow', 'decide'] } },
    tool('Edit', { file_path: path.join(APPS, 'myapp', 'frontend', 'src', 'App.tsx') }),
    tool('Edit', { file_path: path.join(APPS, 'myapp', 'frontend', 'src', 'App.test.tsx') }),
    { type: 'attachment', attachment: { type: 'hook_success', command: 'bash "${CLAUDE_PLUGIN_ROOT}/hooks/check-edited.sh"', content: '' } },
    { type: 'attachment', attachment: { type: 'hook_success', command: 'bash "${CLAUDE_PLUGIN_ROOT}/hooks/sg-python.sh"', content: '' } },
    tool('Skill', { skill: 'apps-workflow:pr-flow' }),
    tool('Skill', { skill: 'decide' }),
    tool('Bash', { command: 'git add -A && git commit -m "x; git add -A" && gh pr create --title t' }),
    tool('Bash', { command: 'L=~/.claude/plugins/cache/n-yoshida-dev/apps-workflow/1.13.2/scripts/look.mjs; node "$L" shoot && node "$L" detect' }),
    tool('Bash', { command: 'bash -n plugins/apps-workflow/scripts/codex-run.sh; ps aux | grep "codex exec"' }),
    tool('Agent', { subagent_type: 'apps-workflow:acceptance-reviewer' }),
    tool('Bash', { command: 'cd frontend && npm run typecheck' }),
    { ...tool('AskUserQuestion', {}), timestamp: '2026-10-01T03:00:00.000Z' },
    { type: 'user', message: { content: [{ type: 'tool_result', is_error: true, content: 'PreToolUse:Bash hook error: 危険なコマンドを検知しました: [rm -rf]' }] } },
    { type: 'user', message: { content: [{ type: 'tool_result', is_error: true, content: 'Permission to use Bash with command cd x\nrm y has been denied.' }] } },
    { type: 'user', message: { content: [{ type: 'tool_result', is_error: true, content: '機密ファイルが含まれています: .env。git restore --staged で除外してください' }] } },
    { type: 'user', message: { content: [{ type: 'tool_result', is_error: false, content: '危険なコマンドを検知しました（ただの出力）' }] } },
  ], [tool('Bash', { command: 'bash ~/workspace/apps/claude-plugins/plugins/apps-workflow/scripts/codex-run.sh -m x "prompt"' })])
  const gone = session('claude-plugins', 's2', [
    { type: 'user', origin: { kind: 'human' }, message: { content: 'テスト' } },
    tool('Skill', { skill: 'apps-workflow:pr-flow' }),
  ], [tool('Skill', { skill: 'apps-workflow:progress' })])
  // 隣の apps-backup/x のセッション。記録のフォルダ名は apps のものと頭が同じになるが、数えない
  session('backup-x', 's3', [
    { type: 'user', origin: { kind: 'human' }, message: { content: '別の場所' } },
    tool('Skill', { skill: 'apps-workflow:pr-flow' }),
  ], null, path.join(TMP, 'apps-backup', 'x'))

  let { log, u } = run()
  check('セッション数（隣の apps-backup は数えない）', u.sessions, 2)
  check('pr-flow は全体 2・実アプリ 1', [u.counts['skill:pr-flow'], u.countsApps['skill:pr-flow']], [2, 1])
  check('本人が打った handoff', [u.counts['skill:handoff'], u.human['skill:handoff']], [1, 1])
  check('受け入れ役', u.counts['agent:acceptance-reviewer'], 1)
  check('フックはプラグインの物だけ', [u.counts['hook:check-edited.sh'], u.counts['hook:sg-python.sh']], [1, undefined])
  check('変数に入れて動かした look.mjs は 1 回', u.counts['script:look.mjs'], 1)
  check('ultracode の中の codex-run.sh は数え、bash -n は数えない', u.counts['script:codex-run.sh'], 1)
  const row = (sec, label) => u.sections.find((s) => s.id === sec).rows.find((r) => r.label.startsWith(label))?.n
  check('本人の入力（スラッシュコマンドを含む）', row('volume', '本人の入力'), 3)
  check('git add -A は 1 コマンドで 1 回', row('rules', 'git add -A'), 1)
  const rowOf = (sec, label) => u.sections.find((s) => s.id === sec).rows.find((r) => r.label.startsWith(label))
  check('since の行は、その日からの回数も出す', [rowOf('rules', 'git add -A').nSince, rowOf('rules', '選択肢の画面').n, rowOf('rules', '選択肢の画面').nSince], [1, 1, 0])
  check('改行の入ったコマンドを断った回も数える', row('guards', '許可が下りなかった'), 1)
  check('staged-secrets-guard が止めた回', row('guards', 'staged-secrets-guard'), 1)
  check('Codex の直接呼びは grep を数えない', row('rules', 'Codex を入口（codex-run.sh）を通さず'), 0)
  check('Codex の入口は部品の回数をそのまま出す', row('rules', 'Codex を入口（codex-run.sh）から'), 1)
  check('止めたのは失敗した結果だけ', row('guards', 'dangerous-bash-guard'), 1)
  check('外のスキル', row('outside', 'スキル decide'), 1)
  const scene = (id) => u.scenes.find((s) => s.id === id)
  check('look：使えた 1・場面 1・使った 0（テストのファイルは場面に入れない）', [scene('look').available, scene('look').scene, scene('look').usedInScene], [1, 1, 0])
  check('pr-flow：使えた 1・場面 1・場面で使った 1・使った 2', [scene('pr-flow').available, scene('pr-flow').scene, scene('pr-flow').usedInScene, scene('pr-flow').used], [1, 1, 1, 2])

  check('PR の前の検査：場面 1・使った 1', [scene('pr-check').scene, scene('pr-check').usedInScene], [1, 1])

  // 記録が消えても、積んだ値は残る（本体だけ消えた場合と、全部消えた場合）
  fs.rmSync(gone)
  ;({ log, u } = run())
  check('本体の記録だけ消えても積んだ値を残す', [u.sessions, u.counts['skill:pr-flow'], u.counts['skill:progress'], /積んだ値だけ 1/.test(log)], [2, 2, 1, true])
  fs.rmSync(path.join(path.dirname(gone), 's2'), { recursive: true })
  ;({ log, u } = run())
  check('記録が全部消えても積んだ値を残す', [u.sessions, u.counts['skill:pr-flow'], u.counts['skill:progress'], /積んだ値だけ 1/.test(log)], [2, 2, 1, true])
  ;({ log, u } = run())
  check('変わっていなければ読み直さない', /数え直し 0・変わらず 1/.test(log), true)
} finally {
  fs.rmSync(TMP, { recursive: true, force: true })
}

if (failed) {
  console.error(`${failed} 件 NG`)
  process.exit(1)
}
console.log('全部 OK')
