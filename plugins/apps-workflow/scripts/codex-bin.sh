#!/usr/bin/env bash
# codex の実行ファイルの場所を 1 行で出す
#
# 使い方： bash codex-bin.sh
# 呼び元： codex-run.sh。単体で叩いて、どの codex が使われるかを確かめてもよい
# 出力：  標準出力に絶対パスを 1 行。見つからなければ標準エラーに理由を出して exit 1
#
# 探す順：
#   1. 環境変数 CODEX_BIN（実行できないファイルを指していたら、ほかを探さずにエラーにする。指定の誤りを黙って隠さないため）
#   2. VS Code 拡張機能（openai.chatgpt）の中の codex。拡張機能の更新で版ごとのフォルダが増えるので、版の順に並べて最新を使う
#
# PATH の codex は見ない。PATH に codex を置くと、このラッパーを通らない呼び出しが
# ~/.codex/config.toml の既定のモデル・考える深さで走るため、置かない方針にしている
# （ops の docs/2026-10-04-マルチモデル協調の採用判断.md §6 論点 7・§7）
set -uo pipefail

# 拡張機能の入る場所と、その中の codex の位置（このマシンは WSL の linux x64）
EXT_DIR="$HOME/.vscode-server/extensions"
BIN_IN_EXT="bin/linux-x86_64/codex"

# 環境変数で指定されていれば、それだけを確かめて返す。
# 相対パスは呼ばれた時点のフォルダを基準に絶対パスへ直す（codex-run.sh は作業フォルダへ移ってから実行するため）
if [ -n "${CODEX_BIN:-}" ]; then
  case "$CODEX_BIN" in
    /*) given="$CODEX_BIN" ;;
    *) given="$PWD/$CODEX_BIN" ;;
  esac
  if [ -x "$given" ] && [ ! -d "$given" ]; then
    printf '%s\n' "$given"
    exit 0
  fi
  echo "codex-bin.sh: CODEX_BIN（$CODEX_BIN）が実行できるファイルではありません" >&2
  exit 1
fi

# 拡張機能の版ごとのフォルダから、実行できる codex を集めて最新の版を選ぶ
shopt -s nullglob
latest=$(for f in "$EXT_DIR"/openai.chatgpt-*/"$BIN_IN_EXT"; do
  if [ -x "$f" ]; then printf '%s\n' "$f"; fi
done | sort -V | tail -n 1)

if [ -z "$latest" ]; then
  echo "codex-bin.sh: codex が見つかりません（$EXT_DIR/openai.chatgpt-*/$BIN_IN_EXT が無い）。VS Code に拡張機能 openai.chatgpt を入れるか、CODEX_BIN に絶対パスを入れてください" >&2
  exit 1
fi
printf '%s\n' "$latest"
