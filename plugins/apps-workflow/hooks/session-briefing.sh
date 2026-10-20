#!/usr/bin/env bash
# SessionStart — apps の開発ドキュメントの型に合わせた、起動時の知らせ（自分用の数行）を context に流し込む
#
# stdout に書いた内容がそのまま Claude の context に入る（ユーザーの画面には出ない）。
# 進捗表と未完タスクの一覧は、公開版の todo-progress（n-yoshida-dev/claude-code-toolkit）の SessionStart フックが出す。
# apps-workflow は plugin.json の dependencies でそれに依存している（v2.0.0 で切り替え。2026-10-20、ops の成果物公開の計画 6-2 の #7）。
# ここに残すのは、公開版に入れなかった apps の型に固有の知らせだけ：
#   - TODO.md に公開の節が無いことの知らせ（並べ替えは指示しない）
#   - HANDOFF.md を読むこと、logs/decisions.md があれば設計の前に読むこと
# 残すかどうかは Claude の選択（本人は未確認）。消すと切り替えの前と動きが変わるため、残した。
set -uo pipefail

# 読むプロジェクトを決める。todo-progress と同じく、フックの入力（標準入力の JSON）の cwd を優先する。
# worktree に入ったセッションでは、/clear・再開・要約のあとも CLAUDE_PROJECT_DIR が元のフォルダを指したままで、cwd だけが今の作業フォルダを指すため。
# cwd とその Git のルートに TODO.md が無ければ、CLAUDE_PROJECT_DIR（無ければカレントディレクトリ）を使う
hook_cwd() {
  [ -t 0 ] && return 0
  local input
  input="$(cat)"
  if command -v jq >/dev/null 2>&1; then
    jq -r '.cwd // empty' <<< "$input" 2>/dev/null || true
  else
    sed -n 's/.*"cwd"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' <<< "$input" | head -n 1
  fi
}
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
CWD="$(hook_cwd)"
if [ -n "$CWD" ] && [ -d "$CWD" ]; then
  for candidate in "$CWD" "$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null)"; do
    if [ -n "$candidate" ] && [ -f "$candidate/TODO.md" ]; then
      PROJECT_DIR="$candidate"
      break
    fi
  done
fi
TODO="$PROJECT_DIR/TODO.md"
[ -f "$TODO" ] || exit 0

# 公開の節（見出しに「公開」を含み、「公開後」「確認待ち」「保留」を含まない節）があるか
HAS_RELEASE=$(awk '
  /^## / {
    s = $0; sub(/^## +/, "", s)
    if (s ~ /公開/ && s !~ /公開後/ && s !~ /確認待ち/ && s !~ /保留/) { print "yes"; exit }
  }
' "$TODO")

echo "## apps の開発ドキュメントについての知らせ（apps-workflow）"
echo
# 公開の節が無いことは知らせるだけにする。並べ替えるかは apps ルートの CLAUDE.md の TODO.md の項に従う
# （ユーザーが今は動かさないとしたアプリがあるため、フックからは指示しない）
if [ -z "$HAS_RELEASE" ]; then
  echo "TODO.md に「公開」を含む見出しが無いので、進捗表に「公開まで残り」は出ない（並べ方は apps ルートの CLAUDE.md の TODO.md の項）。"
fi
echo "現在地と次の一手は HANDOFF.md にある。作業前に読むこと。"
# 判断台帳があるアプリでは、設計提案の前に読ませる（無いアプリでは何も言わない）
if [ -f "$PROJECT_DIR/logs/decisions.md" ]; then
  echo "ユーザーと合意済みの判断は logs/decisions.md にある。設計・方針を提案する前に読み、蒸し返さないこと。"
fi
exit 0
