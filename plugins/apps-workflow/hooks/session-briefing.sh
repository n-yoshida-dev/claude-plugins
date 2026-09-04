#!/usr/bin/env bash
# SessionStart — TODO.md の未完タスクを context に流し込む
#
# stdout に書いた内容がそのまま Claude の context に入る。
# CLAUDE.md に「TODO.md を読め」と書くより確実で、ファイル読み込み1回分を節約できる。
# context を圧迫しないよう件数を絞る。
set -uo pipefail

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
TODO="$PROJECT_DIR/TODO.md"
[ -f "$TODO" ] || exit 0

PENDING=$(grep -n '^- \[ \]' "$TODO" | head -12)
[ -n "$PENDING" ] || exit 0

TOTAL=$(grep -c '^- \[ \]' "$TODO")

echo "## セッション開始時の状況（TODO.md より自動抽出）"
echo
echo "未完タスク ${TOTAL} 件。先頭12件："
printf '%s\n' "$PENDING" | sed 's/^\([0-9]*\):- \[ \] /  - (TODO.md:\1) /'
echo
echo "現在地と次の一手は HANDOFF.md にある。作業前に読むこと。"
# 判断台帳があるアプリでは、設計提案の前に読ませる（無いアプリでは何も言わない）
[ -f "$PROJECT_DIR/logs/decisions.md" ] && echo "ユーザーと合意済みの判断は logs/decisions.md にある。設計・方針を提案する前に読み、蒸し返さないこと。"
exit 0
