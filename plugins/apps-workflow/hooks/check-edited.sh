#!/usr/bin/env bash
# PostToolUse(Edit|Write) — 編集した直後に、その言語のチェックを回す
#
# frontend/*.ts(x) を触ったら typecheck と eslint、backend/*.go を触ったら go vet。
# 対象のディレクトリがまだ無い間（プロジェクト初期化より前）は何もしない。
#
# 結果は hookSpecificOutput.additionalContext で返し、意図的にブロックはしない。
# 複数ファイルにまたがるリファクタの途中で型エラーが出るのは正常なため。
# 強制的に直させたい場合は decision:"block" に変える。
#
# 入力：標準入力に PostToolUse イベントの JSON（.tool_input.file_path に編集したファイル）
# 出力：問題があれば JSON を stdout に出して exit 0
set -uo pipefail

INPUT=$(cat)
FILE=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
[ -n "$FILE" ] || exit 0

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
FRONTEND="$PROJECT_DIR/frontend"
BACKEND="$PROJECT_DIR/backend"

REPORT=""

case "$FILE" in
  "$FRONTEND"/*.ts|"$FRONTEND"/*.tsx)
    [ -f "$FRONTEND/package.json" ] || exit 0

    # 型チェック：typecheck スクリプトがあればそれを、無ければ tsc を直接叩く
    if jq -e '.scripts.typecheck' "$FRONTEND/package.json" >/dev/null 2>&1; then
      OUT=$(cd "$FRONTEND" && npm run --silent typecheck 2>&1) || \
        REPORT="${REPORT}[typecheck 失敗]"$'\n'"$OUT"$'\n'
    else
      OUT=$(cd "$FRONTEND" && npx --no-install tsc --noEmit 2>&1) || \
        REPORT="${REPORT}[tsc --noEmit 失敗]"$'\n'"$OUT"$'\n'
    fi

    # lint：編集した1ファイルだけを対象にする（全体を回すと編集のたびに遅くなる）
    if jq -e '.scripts.lint' "$FRONTEND/package.json" >/dev/null 2>&1; then
      OUT=$(cd "$FRONTEND" && npx --no-install eslint "$FILE" 2>&1) || \
        REPORT="${REPORT}[eslint 失敗] $FILE"$'\n'"$OUT"$'\n'
    fi
    ;;

  "$BACKEND"/*.go)
    [ -f "$BACKEND/go.mod" ] || exit 0

    OUT=$(cd "$BACKEND" && go vet ./... 2>&1) || \
      REPORT="${REPORT}[go vet 失敗]"$'\n'"$OUT"$'\n'
    ;;

  *)
    exit 0
    ;;
esac

[ -n "$REPORT" ] || exit 0

# 長すぎる出力は context を圧迫するので先頭だけ返す
REPORT=$(printf '%s' "$REPORT" | head -c 4000)

jq -n --arg ctx "編集後の自動チェックでエラーが出ました。続行前に修正してください。"$'\n'"$REPORT" \
  '{hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: $ctx}}'
exit 0
