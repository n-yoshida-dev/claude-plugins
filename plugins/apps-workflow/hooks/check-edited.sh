#!/usr/bin/env bash
# PostToolUse(Edit|Write) — 編集した直後に、その言語のチェックを回す
#
# frontend/ の .ts・.tsx・.astro を触ったら typecheck と lint（package.json の lint スクリプトに書かれた oxlint・eslint。両方あれば両方）、backend/*.go を触ったら go vet。
# frontend/ が無く、リポジトリ直下に package.json があるアプリ（portfolio）は、直下を frontend/ の代わりに見る。
# lint スクリプトのオプション（--deny-warnings など）は引き継がない。名前だけを見て、編集した 1 ファイルに当てる。
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
BACKEND="$PROJECT_DIR/backend"

# 画面側（Node のプロジェクト）の場所。frontend/ があればそこ。
# frontend/ が無く、リポジトリ直下に package.json があるときだけ直下をサイトの場所とみなす
# （portfolio はサイトがリポジトリ直下にあり、以前はこのフックが何も回していなかった。2026-10-11 に直した）
if [ ! -d "$PROJECT_DIR/frontend" ] && [ -f "$PROJECT_DIR/package.json" ]; then
  FRONTEND="$PROJECT_DIR"
  ROOT_SITE=1
else
  FRONTEND="$PROJECT_DIR/frontend"
  ROOT_SITE=0
fi

REPORT=""

case "$FILE" in
  # 依存・ビルドの成果物・Astro が作る型の置き場は見ない（直下がサイトのときに拾わないため）
  "$FRONTEND"/node_modules/*|"$FRONTEND"/dist/*|"$FRONTEND"/.astro/*)
    exit 0
    ;;

  "$FRONTEND"/*.ts|"$FRONTEND"/*.tsx|"$FRONTEND"/*.astro)
    [ -f "$FRONTEND/package.json" ] || exit 0

    # 型チェック：typecheck スクリプトがあればそれを、無ければ tsc を直接叩く。
    # 直下がサイトのときは typecheck スクリプトがある場合だけ（道具のためだけの package.json で tsc を呼んで失敗を出さないため）
    if jq -e '.scripts.typecheck' "$FRONTEND/package.json" >/dev/null 2>&1; then
      OUT=$(cd "$FRONTEND" && npm run --silent typecheck 2>&1) || \
        REPORT="${REPORT}[typecheck 失敗]"$'\n'"$OUT"$'\n'
    elif [ "$ROOT_SITE" -eq 0 ]; then
      OUT=$(cd "$FRONTEND" && npx --no-install tsc --noEmit 2>&1) || \
        REPORT="${REPORT}[tsc --noEmit 失敗]"$'\n'"$OUT"$'\n'
    fi

    # lint：編集した1ファイルだけを対象にする（全体を回すと編集のたびに遅くなる）。
    # どの lint を呼ぶかは package.json の lint スクリプトに書かれた名前で決める。oxlint・eslint のどちらも無ければ呼ばない
    # （以前は lint スクリプトがあれば eslint を決め打ちで呼び、oxlint のアプリで毎回「eslint 失敗」を出していた。2026-10-11 に直した）
    LINT_SCRIPT=$(jq -r '.scripts.lint // empty' "$FRONTEND/package.json" 2>/dev/null)
    for LINTER in oxlint eslint; do
      # 前後が英数字・_・- でない所だけを名前とみなす（typescript-eslint などの一部を拾わないため）
      if printf '%s' "$LINT_SCRIPT" | grep -qE "(^|[^[:alnum:]_-])${LINTER}([^[:alnum:]_-]|\$)"; then
        OUT=$(cd "$FRONTEND" && npx --no-install "$LINTER" "$FILE" 2>&1) || \
          REPORT="${REPORT}[${LINTER} 失敗] $FILE"$'\n'"$OUT"$'\n'
      fi
    done
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

# 色付けの制御文字（astro check はパイプの先でも色を付ける）を外し、長すぎる出力は context を圧迫するので先頭だけ返す
REPORT=$(printf '%s' "$REPORT" | sed $'s/\x1b\\[[0-9;]*m//g' | head -c 4000)

jq -n --arg ctx "編集後の自動チェックでエラーが出ました。続行前に修正してください。"$'\n'"$REPORT" \
  '{hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: $ctx}}'
exit 0
