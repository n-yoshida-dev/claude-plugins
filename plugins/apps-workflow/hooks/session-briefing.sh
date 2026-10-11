#!/usr/bin/env bash
# SessionStart — 進捗表と TODO.md の未完タスクを context に流し込む
#
# stdout に書いた内容がそのまま Claude の context に入る（ユーザーの画面には出ない）。
# 未完一覧は先頭レベルの `- [ ]` だけを数える。進捗表（progress.sh）は字下げした子項目も数えるので、件数は一致しないことがある。
# 一覧は、公開の節（見出しに「公開」を含む最初の節。「公開後」は除く）の未完を先に出し、ほかは上から出す。
# 公開の節が TODO の末尾にあっても、Claude の目に入るようにするため（2026-10-11 の合意。ops の docs/2026-10-11-apps-リリースまで届く開発の進め方.md）。
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

# 先頭レベルの未完を「行番号:行」の形で出す。公開の節の分を先に、ほかを上から。最後の行に公開の節の有無（release=1 か 0）を出す
ORDERED=$(awk '
  /^## / {
    s = $0; sub(/^## +/, "", s)
    in_release = (!found && s ~ /公開/ && s !~ /公開後/ && s !~ /確認待ち/ && s !~ /保留/)
    if (in_release) found = 1
    next
  }
  /^- \[ \]/ { if (in_release) first[++nf] = NR ":" $0; else rest[++nr] = NR ":" $0 }
  END {
    for (i = 1; i <= nf; i++) print first[i]
    for (i = 1; i <= nr; i++) print rest[i]
    print "release=" (found ? 1 : 0)
  }
' "$TODO")
HAS_RELEASE=$(printf '%s\n' "$ORDERED" | tail -n 1)
PENDING=$(printf '%s\n' "$ORDERED" | sed '$d' | head -12)
if [ -n "$PENDING" ]; then
  TOTAL=$(grep -c '^- \[ \]' "$TODO")
  if [ "$HAS_RELEASE" = "release=1" ]; then
    echo "### 未完タスク（先頭レベルのみ）${TOTAL} 件。公開の節を先に、ほかは上から 12 件："
  else
    echo "### 未完タスク（先頭レベルのみ）${TOTAL} 件。先頭12件："
  fi
  echo
  printf '%s\n' "$PENDING" | sed 's/^\([0-9]*\):- \[ \] /  - (TODO.md:\1) /'
  echo
fi
if [ "$HAS_RELEASE" != "release=1" ]; then
  echo "TODO.md に「公開」を含む見出しが無い。このセッションの作業の PR で、見出しを「設計 → 最初の画面 → 公開 → 公開後の改善」の並びに直す（書き方は apps ルートの CLAUDE.md の TODO.md の項）。"
  echo
fi

echo "現在地と次の一手は HANDOFF.md にある。作業前に読むこと。"
# 判断台帳があるアプリでは、設計提案の前に読ませる（無いアプリでは何も言わない）
[ -f "$PROJECT_DIR/logs/decisions.md" ] && echo "ユーザーと合意済みの判断は logs/decisions.md にある。設計・方針を提案する前に読み、蒸し返さないこと。"
exit 0
