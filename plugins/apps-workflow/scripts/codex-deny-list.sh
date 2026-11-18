#!/usr/bin/env bash
# Codex に読ませない場所の一覧のうち、いま動いている OS に合う物の場所を 1 行で出す
#
# 使い方： bash codex-deny-list.sh
# 呼び元： codex-review スキル（codex-run.sh --deny-read-list に渡す）・compete-setup.sh（作り手と審査役の一覧の元にする）
# 出力：  標準出力に一覧のファイルの絶対パスを 1 行。一覧が無ければ標準エラーに理由を出して exit 1（何も出さない）
#
# 選び方：Windows の Git Bash（uname -s が MINGW*・MSYS*）なら config/codex-review-deny-read.windows.txt、
#   それ以外（WSL・Linux）なら config/codex-review-deny-read.txt。
#   Claude への指示の文の中で OS を見分けさせず、ここで機械的に決める（2026-11-18）
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/../hooks/lib-path.sh" || { echo "codex-deny-list.sh: hooks/lib-path.sh を読めません" >&2; exit 1; }

config_dir="$(cd "$SCRIPT_DIR/../config" && pwd)" || { echo "codex-deny-list.sh: config のフォルダがありません" >&2; exit 1; }
if is_windows_bash; then
  list="$config_dir/codex-review-deny-read.windows.txt"
else
  list="$config_dir/codex-review-deny-read.txt"
fi
if [ ! -f "$list" ] || [ ! -r "$list" ]; then
  echo "codex-deny-list.sh: 読ませない場所の一覧が読めません: $list" >&2
  exit 1
fi
printf '%s\n' "$list"
