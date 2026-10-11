#!/usr/bin/env bash
# PostToolUse(Edit|Write) — 編集した直後に、その言語のチェックを回す
#
# frontend/ の .ts・.tsx・.astro を触ったら typecheck と lint（package.json の lint スクリプトに書かれた oxlint・eslint。両方あれば両方）、backend/*.go を触ったら go vet。
# frontend/ が無く、リポジトリ直下に package.json があるアプリ（portfolio）は、直下を frontend/ の代わりに見る。
# lint スクリプトのオプション（--deny-warnings など）は引き継がない。名前だけを見て、編集した 1 ファイルに当てる。
# 対象のディレクトリがまだ無い間（プロジェクト初期化より前）は何もしない。
# 同じリポジトリの別の作業フォルダ（git worktree）での編集も、その作業フォルダの中で検査する（別のセッションと重ならないよう
# worktree で直したとき、検査が回っていなかった。2026-10-11）。ただし画面側は、その作業フォルダに node_modules が無ければ回さない
# （依存が入っていないと型チェックが必ず失敗し、編集のたびに同じ失敗を知らせてしまうため。npm ci すれば回る）。
#
# 結果は hookSpecificOutput.additionalContext で返し、意図的にブロックはしない。
# 複数ファイルにまたがるリファクタの途中で型エラーが出るのは正常なため。
# 強制的に直させたい場合は decision:"block" に変える。
#
# 入力：標準入力に PostToolUse イベントの JSON（.tool_input.file_path に編集したファイル）
# 出力：問題があれば JSON を stdout に出して exit 0
set -uo pipefail

# 編集したファイルが、同じリポジトリの別の作業フォルダ（git worktree）か、プロジェクトの中にあれば、
# ROOT（その作業フォルダかプロジェクトの一番上）・REL（そこからの相対パス）・WORKTREE（別の作業フォルダなら 1）を決めて成功を返す。
# どちらでもなければ失敗を返す。look-notice.sh にも同じ関数がある（直すときは両方）
locate_in_repo() {
  local file="$1" project="$2" dir mine theirs top ptop prefix
  WORKTREE=0
  dir=$(dirname "$file")
  if [ -d "$dir" ] \
    && mine=$(git -C "$dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) \
    && theirs=$(git -C "$project" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) \
    && [ "$mine" = "$theirs" ] \
    && top=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null) \
    && ptop=$(git -C "$project" rev-parse --show-toplevel 2>/dev/null) \
    && [ "$top" != "$ptop" ] \
    && prefix=$(git -C "$dir" rev-parse --show-prefix 2>/dev/null); then
    ROOT="$top"
    REL="${prefix}$(basename "$file")"
    WORKTREE=1
    return 0
  fi
  case "$file" in
    "$project"/*) ROOT="$project"; REL=${file#"$project"/}; return 0 ;;
  esac
  return 1
}

INPUT=$(cat)
FILE=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
[ -n "$FILE" ] || exit 0

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
locate_in_repo "$FILE" "$PROJECT_DIR" || exit 0
# 別の作業フォルダなら、そこをプロジェクトとみなして検査する（パスの書き方を揃え、下の case で当てられるようにする）
if [ "$WORKTREE" -eq 1 ]; then
  PROJECT_DIR="$ROOT"
  FILE="$ROOT/$REL"
fi
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
    # 別の作業フォルダで依存が入っていなければ回さない（上の説明）
    if [ "$WORKTREE" -eq 1 ] && [ ! -d "$FRONTEND/node_modules" ]; then
      exit 0
    fi

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
