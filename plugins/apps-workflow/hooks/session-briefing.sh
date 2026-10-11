#!/usr/bin/env bash
# SessionStart — 進捗表と TODO.md の未完タスクを context に流し込む
#
# stdout に書いた内容がそのまま Claude の context に入る（ユーザーの画面には出ない）。
# 未完一覧は先頭レベルの `- [ ]` だけを数える。進捗表（progress.sh）は字下げした子項目も数えるので、件数は一致しないことがある。
# 一覧は、公開の節（見出しに「公開」を含む最初の節。「公開後」は除く）の未完を見出しを分けて先に出し、ほかは上から出す。
# 公開の節が TODO の末尾にあっても、Claude の目に入るようにするため（ops の docs/2026-10-11-apps-リリースまで届く開発の進め方.md の 5 節 2 と
# 7 節 Step 4 の 1。どちらも Claude が書いた提案と手順で、2026-10-11 にユーザーが OK した「決定」の 4 つには入っていない）。
# 見出しを分けるのは、着手の順（上から）と取り違えないようにするため（Claude の選択）。
# CLAUDE.md に「TODO.md を読め」と書くより確実で、ファイル読み込み1回分を節約できる。
# context を圧迫しないよう件数を絞る。
#
# 進捗表の集計は progress.sh（同じディレクトリ）が行う。ここは呼ぶだけ。
set -uo pipefail

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
TODO="$PROJECT_DIR/TODO.md"
[ -f "$TODO" ] || exit 0

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "## セッション開始時の状況（TODO.md より自動抽出）"
echo
echo "### 進捗"
echo
bash "$HERE/progress.sh" "$PROJECT_DIR"
echo
echo "**この進捗表は、最初の返答の冒頭にコードブロックのまま貼ってユーザーに見せること。** 数値を書き換えたり要約したりしない"
echo "（フックの出力はユーザーの画面に出ないため。ユーザーは「どこまで進み、何が残っているか」をこの表で把握する）。"
echo

# 先頭レベルの未完を「R:行番号:行」（公開の節）か「O:行番号:行」（ほか）の形で上から出し、最後の行に公開の節の見出し（無ければ空）を出す
TAGGED=$(awk '
  /^## / {
    s = $0; sub(/^## +/, "", s)
    in_release = (name == "" && s ~ /公開/ && s !~ /公開後/ && s !~ /確認待ち/ && s !~ /保留/)
    if (in_release) name = s
    next
  }
  /^- \[ \]/ { print (in_release ? "R" : "O") ":" NR ":" $0 }
  END { print "release=" name }
' "$TODO")
RELEASE_NAME=$(printf '%s\n' "$TAGGED" | tail -n 1 | sed 's/^release=//')
RELEASE_TASKS=$(printf '%s\n' "$TAGGED" | sed -n 's/^R://p' | head -12)
OTHER_TASKS=$(printf '%s\n' "$TAGGED" | sed -n 's/^O://p')
TOTAL=$(grep -c '^- \[ \]' "$TODO")
LIMIT=12
# 「行番号:- [ ] 本文」を「  - (TODO.md:行番号) 本文」にする
format_tasks() { sed 's/^\([0-9]*\):- \[ \] /  - (TODO.md:\1) /'; }
# 公開の節の未完を先に、見出しを分けて出す（着手の順ではなく、公開に何が残っているかを見せるため）
if [ -n "$RELEASE_TASKS" ]; then
  RELEASE_COUNT=$(printf '%s\n' "$RELEASE_TASKS" | grep -c .)
  echo "### 公開の節（${RELEASE_NAME}）の未完 ${RELEASE_COUNT} 件："
  echo
  printf '%s\n' "$RELEASE_TASKS" | format_tasks
  echo
  LIMIT=$((12 - RELEASE_COUNT))
fi
if [ -n "$OTHER_TASKS" ] && [ "$LIMIT" -gt 0 ]; then
  if [ -n "$RELEASE_TASKS" ]; then
    echo "### ほかの未完タスク（先頭レベルのみ。未完は全部で ${TOTAL} 件）。上から ${LIMIT} 件まで："
  else
    echo "### 未完タスク（先頭レベルのみ）${TOTAL} 件。先頭12件："
  fi
  echo
  printf '%s\n' "$OTHER_TASKS" | head -n "$LIMIT" | format_tasks
  echo
fi
# 公開の節が無いことは知らせるだけにする。並べ替えるかは apps ルートの CLAUDE.md の TODO.md の項に従う
# （ユーザーが今は動かさないとしたアプリがあるため、フックからは指示しない）
if [ -z "$RELEASE_NAME" ]; then
  echo "TODO.md に「公開」を含む見出しが無いので、進捗表に「公開まで残り」は出ない（並べ方は apps ルートの CLAUDE.md の TODO.md の項）。"
  echo
fi

echo "現在地と次の一手は HANDOFF.md にある。作業前に読むこと。"
# 判断台帳があるアプリでは、設計提案の前に読ませる（無いアプリでは何も言わない）
[ -f "$PROJECT_DIR/logs/decisions.md" ] && echo "ユーザーと合意済みの判断は logs/decisions.md にある。設計・方針を提案する前に読み、蒸し返さないこと。"
exit 0
