#!/usr/bin/env bash
# PostToolUse(Edit|Write) — 画面のファイルを変えたら、DESIGN.md と見た目の点検を知らせる（1 セッションに 1 回）
#
# frontend-design は Claude が要ると判断したときだけ呼ばれ、画面のファイルを書き換えた作業 19 回のうち 3 回しか使われなかった
# （ops の docs/2026-10-10-apps-デザイン改善の進め方.md 3-2 節）。見た目の決まりを読むかを Claude の判断に任せないために、ここで知らせる。
#
# 画面のファイル：.css .scss .sass .less .tsx .jsx .astro .vue .svelte .html。
# テスト・ビルドの成果物・依存・開発ダッシュボード（dashboard/。見た目は apps-workflow:dashboard の方針に従う）は外す。
# 知らせるのは同じセッションで 1 回だけ（編集のたびに同じ文が流れ込むと context を圧迫するため）。
# 印は ${TMPDIR:-/tmp}/apps-workflow-look-notice/<session_id> に置く。
#
# 入力：標準入力に PostToolUse イベントの JSON（.tool_input.file_path・.session_id）
# 出力：知らせるときだけ JSON を stdout に出す。いつも exit 0（ブロックしない）
set -uo pipefail

INPUT=$(cat)
FILE=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
SESSION=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
[ -n "$FILE" ] || exit 0

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
case "$FILE" in
  "$PROJECT_DIR"/*) REL=${FILE#"$PROJECT_DIR"/} ;;
  *) exit 0 ;;
esac

# 画面のファイルでなければ何もしない
case "$REL" in
  node_modules/*|*/node_modules/*|dist/*|*/dist/*|build/*|*/build/*|coverage/*|*/coverage/*|.git/*|.claude/*|dashboard/*) exit 0 ;;
  *.test.*|*.spec.*|test/*|*/test/*|tests/*|*/tests/*|e2e/*|*/e2e/*|*/__tests__/*) exit 0 ;;
  *.css|*.scss|*.sass|*.less|*.tsx|*.jsx|*.astro|*.vue|*.svelte|*.html) ;;
  *) exit 0 ;;
esac

# 同じセッションで知らせ済みなら何もしない。session_id が無いときは毎回知らせる（黙って止めるより重複のほうが害が小さい）
if [ -n "$SESSION" ]; then
  MARK_DIR="${TMPDIR:-/tmp}/apps-workflow-look-notice"
  MARK="$MARK_DIR/$(printf '%s' "$SESSION" | tr -c 'A-Za-z0-9_-' '_')"
  [ -e "$MARK" ] && exit 0
  if ! mkdir -p "$MARK_DIR" || ! : > "$MARK"; then
    echo "look-notice: 印 $MARK を書けなかった。このセッションでは知らせが繰り返し出ることがある" >&2
  fi
fi

if [ -f "$PROJECT_DIR/DESIGN.md" ]; then
  MSG="画面のファイル（$REL）を変えました。このアプリの見た目の決まりは DESIGN.md にあります。このセッションでまだ読んでいなければ先に読み、今の変更が決まりとずれていないかを見直してください。新しい画面か大きな作り替えなら frontend-design のスキルも呼びます。PR を作る前に、apps-workflow:look のスキルの「B 毎回の点検」（撮影・look-reviewer・Impeccable の検出器）を回します（この知らせはこのセッションで 1 回だけ出ます）"
else
  MSG="画面のファイル（$REL）を変えました。このアプリには見た目の決まり（DESIGN.md）がまだありません。見た目を変える作業なら、apps-workflow:look のスキルを呼び、先に DESIGN.md を作ります（今ある CSS・SPEC・logs/decisions.md の決まりを写し、決まっていないところは空けて、新しい決定はしない）。ユーザーが見た目の作り替えを保留しているアプリや、文言・不具合だけの小さな直しなら作らずに進めます（この知らせはこのセッションで 1 回だけ出ます）"
fi

jq -n --arg ctx "$MSG" '{hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: $ctx}}'
exit 0
