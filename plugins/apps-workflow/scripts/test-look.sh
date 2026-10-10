#!/usr/bin/env bash
# 見た目の点検の道具（hooks/look-notice.sh・scripts/look.mjs・config/look-tools.json・look スキル）の回帰テスト
#
# 使い方： bash test-look.sh
# ブラウザも外部の道具（Impeccable・Google の DESIGN.md の検査）も呼ばない。撮影の本番は look スキルの手順で、手元で確かめる
# 出力：  1 件ごとに ok / NG。NG が 1 件でもあれば exit 1
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN="$SCRIPT_DIR/.."
HOOK="$PLUGIN/hooks/look-notice.sh"
LOOK="$SCRIPT_DIR/look.mjs"
failures=0
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# 結果を 1 行で出し、NG を数える
check() {
  local name="$1"; shift
  if "$@"; then
    echo "ok  $name"
  else
    echo "NG  $name"
    failures=$((failures + 1))
  fi
}

# フックに編集のイベントを渡し、出力（知らせの JSON か空）を返す
run_hook() {
  local project="$1" file="$2" session="$3"
  jq -n --arg f "$file" --arg s "$session" '{tool_input: {file_path: $f}, session_id: $s}' |
    CLAUDE_PROJECT_DIR="$project" TMPDIR="$WORK/tmp" bash "$HOOK"
}

# 知らせが出たか
notified() {
  [ -n "$(run_hook "$@")" ]
}

# 知らせが出なかったか
silent() {
  [ -z "$(run_hook "$@")" ]
}

# 知らせの文に指定の文字列があるか
notice_has() {
  local text="$1"; shift
  run_hook "$@" | jq -r '.hookSpecificOutput.additionalContext' | grep -qF -- "$text"
}

# jq の条件が真か（結果の true は出さない）
jq_true() {
  jq -e "$@" > /dev/null
}

# 知らせが PostToolUse の additionalContext の形か
notice_shape() {
  run_hook "$@" | jq -e '.hookSpecificOutput.hookEventName == "PostToolUse" and (.hookSpecificOutput.additionalContext | length > 0)' > /dev/null
}

# コマンドの終了コードが期待どおりか
exit_is() {
  local want="$1"; shift
  "$@" > /dev/null 2>&1
  [ "$?" -eq "$want" ]
}

# コマンドの出力に指定の文字列があるか
output_has() {
  local text="$1"; shift
  "$@" 2>&1 | grep -qF -- "$text"
}

# --- フック ---
APP="$WORK/app"
BARE="$WORK/bare"
mkdir -p "$APP/frontend/src" "$BARE/src" "$WORK/tmp"
: > "$APP/DESIGN.md"

check "画面の CSS を変えたら知らせる" notified "$APP" "$APP/frontend/src/index.css" s1
check "知らせは PostToolUse の additionalContext" notice_shape "$APP" "$APP/frontend/src/App.tsx" s2
check "同じセッションの 2 回目は知らせない" silent "$APP" "$APP/frontend/src/App.tsx" s1
check "別のセッションではまた知らせる" notified "$APP" "$APP/frontend/src/App.tsx" s3
check "DESIGN.md があれば、読むことを知らせる" notice_has "DESIGN.md にあります" "$APP" "$APP/frontend/src/App.tsx" s4
check "知らせに点検のスキル名がある" notice_has "apps-workflow:look" "$APP" "$APP/frontend/src/App.tsx" s5
check "DESIGN.md が無ければ、作ることを知らせる" notice_has "DESIGN.md）がまだありません" "$BARE" "$BARE/src/pages/index.astro" s6
check "リポジトリ直下のサイト（astro）でも知らせる" notified "$BARE" "$BARE/src/layouts/Base.astro" s7
check "TypeScript だけのファイル（.ts）は知らせない" silent "$APP" "$APP/frontend/src/prompt/build.ts" s8
check "テスト（.test.tsx）は知らせない" silent "$APP" "$APP/frontend/src/App.test.tsx" s9
check "E2E のフォルダは知らせない" silent "$APP" "$APP/frontend/e2e/page.tsx" s10
check "ビルドの成果物（dist）は知らせない" silent "$APP" "$APP/frontend/dist/index.html" s11
check "依存（node_modules）は知らせない" silent "$APP" "$APP/frontend/node_modules/x/a.css" s12
check "開発ダッシュボード（dashboard/）は知らせない" silent "$APP" "$APP/dashboard/index.html" s13
check "Markdown は知らせない" silent "$APP" "$APP/DESIGN.md" s14
check "プロジェクトの外は知らせない" silent "$APP" "$WORK/other/index.css" s15
check "file_path が無ければ何もしない" silent "$APP" "" s16
check "session_id が無ければ毎回知らせる（1 回目）" notified "$APP" "$APP/frontend/src/a.css" ""
check "session_id が無ければ毎回知らせる（2 回目）" notified "$APP" "$APP/frontend/src/a.css" ""

# --- 表 ---
CONFIG="$PLUGIN/config/look-tools.json"
check "表の道具に版がある" jq_true '.playwright.version and .impeccable.version and .designMd.version and .impeccable.license and .designMd.license' "$CONFIG"
check "表の既定の大きさが sizes にある" jq_true '.defaultSizes - (.sizes | keys) == [] and (.defaultSizes | length > 0)' "$CONFIG"
check "表に確認日がある" jq_true '.checkedAt | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$")' "$CONFIG"

# --- look.mjs（ブラウザを使わない部分） ---
check "look.mjs の構文" node --check "$LOOK"
check "--help は終了コード 0" exit_is 0 node "$LOOK" --help
check "知らない命令は終了コード 2" exit_is 2 node "$LOOK" nope
check "shoot の引数が足りなければ終了コード 2" exit_is 2 node "$LOOK" shoot
check "知らない指定は終了コード 2" exit_is 2 node "$LOOK" shoot http://localhost:1/ "$WORK/out" --nope
check "表に無い大きさは終了コード 2" exit_is 2 node "$LOOK" shoot http://localhost:1/ "$WORK/out" --sizes huge
check "page の引数が足りなければ終了コード 2" exit_is 2 node "$LOOK" page
check "contrast：黒と白は 21" output_has "21.00" node "$LOOK" contrast '#000' '#ffffff'
check "contrast：#757575 と白は 4.6（本文の基準を満たす）" output_has "4.61（本文の基準 4.5 以上）" node "$LOOK" contrast '#757575' '#fff'
check "contrast：色の形の誤りは終了コード 2" exit_is 2 node "$LOOK" contrast 'red' '#fff'

# --- 手順書が指すファイル ---
for f in skills/look/SKILL.md agents/look-reviewer.md scripts/look.mjs config/look-tools.json hooks/look-notice.sh; do
  check "$f がある" test -f "$PLUGIN/$f"
done
check "hooks.json に look-notice.sh が登録されている" jq_true '[.hooks.PostToolUse[].hooks[].command] | any(test("look-notice.sh"))' "$PLUGIN/hooks/hooks.json"
check "スキルが撮影に look.mjs を使う" grep -qF 'scripts/look.mjs' "$PLUGIN/skills/look/SKILL.md"
check "スキルが点検役 look-reviewer を呼ぶ" grep -qF 'apps-workflow:look-reviewer' "$PLUGIN/skills/look/SKILL.md"
check "pr-flow が見た目の点検を指す" grep -qF 'apps-workflow:look' "$PLUGIN/skills/pr-flow/SKILL.md"
check "点検役は Edit / Write を持たない" bash -c "sed -n '/^---$/,/^---$/p' '$PLUGIN/agents/look-reviewer.md' | grep '^tools:' | grep -vqE 'Edit|Write'"

echo
if [ "$failures" -gt 0 ]; then
  echo "NG が $failures 件"
  exit 1
fi
echo "すべて ok"
