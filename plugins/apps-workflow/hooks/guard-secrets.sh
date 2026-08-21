#!/usr/bin/env bash
# PreToolUse(Bash) — 秘密情報・ローカル専用ファイルが Git にコミットされるのを止める
#
# .gitignore は `git add -f` で貫通できる。履歴に一度でも入ると取り返しがつかないため、
# コミット直前でも機械的に止める。強制 add の禁止は .claude/settings.json の
# permissions.deny 側で行う（あちらはシェル演算子を解釈したうえで判定するので、文字列 grep より正確）。
#
# 検査するのは「実際にステージされているファイル」だけ。コマンド文字列そのものは検査しない。
# ヒアドキュメントやコミットメッセージに git のサブコマンドを書いただけで誤検知するため。
#
# 個人データ（家計・健康など）を扱うアプリでは SECRET_RE に固有のファイル名を足すこと。
#
# 入力：標準入力に PreToolUse イベントの JSON（.tool_input.command に実行予定のコマンド）
# 出力：問題なければ exit 0。ブロックするときは理由を stderr に書いて exit 2
set -uo pipefail

INPUT=$(cat)
COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
[ -n "$COMMAND" ] || exit 0

# git のステージング／コミット系を含まないコマンドは検査しない（安価な足切り）
case "$COMMAND" in
  *"git add"*|*"git commit"*|*"git stash"*) ;;
  *) exit 0 ;;
esac

# コミット禁止のパターン。.gitignore と同じ対象をここでも明示的に定義する
SECRET_RE='(^|/)(PRIVATE\.md|CLAUDE\.local\.md|\.env(\..+)?)$|\.local\.(json|md)$|(^|/)(secrets|data/private)/|(^|/)credentials\.json$|\.(pem|key|p12|keystore)$'

STAGED=$(git diff --cached --name-only 2>/dev/null) || exit 0
[ -n "$STAGED" ] || exit 0

# .env.example は雛形なのでコミットしてよい
HITS=$(printf '%s\n' "$STAGED" | grep -E "$SECRET_RE" | grep -v '\.env\.example$' || true)
[ -n "$HITS" ] || exit 0

{
  echo "BLOCKED: 秘密情報・ローカル専用ファイルがステージされています。"
  printf '%s\n' "$HITS" | sed 's/^/  - /'
  echo "git restore --staged <file> で外してから再実行してください。"
} >&2
exit 2
