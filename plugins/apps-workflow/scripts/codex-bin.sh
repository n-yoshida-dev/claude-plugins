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
#   3. 2 で見つからず、Windows の Git Bash（uname -s が MINGW*・MSYS*）のときだけ、Microsoft Store 版の Codex アプリの中の codex.exe。
#      入っている場所は powershell.exe の Get-AppxPackage で引く（C:\Program Files\WindowsApps は中の一覧が読めず、* で集められないため。
#      2026-11-18 に確かめた）。複数あれば版のいちばん新しい物。Linux（WSL）ではこの探し方に入らない
#
# CODEX_BIN は Windows の書き方（C:\… や C:/…）でも受ける。Git Bash の cygpath で /c/… に直してから確かめる
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
    # Windows の絶対パス（C:\… や C:/…）。cygpath がある所（Git Bash）でだけ /c/… に直す。無い所（Linux）では今までどおり相対パスとして扱う
    [A-Za-z]:[\\/]*)
      if command -v cygpath >/dev/null 2>&1; then
        given=$(cygpath -u -- "$CODEX_BIN")
      else
        given="$PWD/$CODEX_BIN"
      fi
      ;;
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

# Windows の Git Bash だけ：Store 版の Codex アプリの場所を Get-AppxPackage で引く（探す順の 3）
if [ -z "$latest" ]; then
  case "$(uname -s)" in
    MINGW*|MSYS*)
      hint="Codex アプリ（Microsoft Store 版）を入れるか、CODEX_BIN に codex.exe の場所を入れてください（例: CODEX_BIN='C:\\Program Files\\WindowsApps\\OpenAI.Codex_<版>_x64__<発行元>\\app\\resources\\codex.exe'）"
      if ! command -v powershell.exe >/dev/null 2>&1; then
        echo "codex-bin.sh: codex が見つかりません（powershell.exe が無く、Codex アプリの場所を引けない）。$hint" >&2
        exit 1
      fi
      # 1 行に「版<タブ>場所」を出させ、版の順に並べて最新を選ぶ。powershell.exe の出力は CRLF なので \r を外す
      # $_ は PowerShell の変数で、bash では広げない（だから一重の引用符）
      # shellcheck disable=SC2016
      found=$(powershell.exe -NoProfile -Command 'Get-AppxPackage -Name OpenAI.Codex | ForEach-Object { [string]$_.Version + [char]9 + $_.InstallLocation }' 2>/dev/null \
        | tr -d '\r' | grep -F "$(printf '\t')" | sort -t "$(printf '\t')" -k1,1V | tail -n 1 | cut -f2-)
      if [ -z "$found" ]; then
        echo "codex-bin.sh: codex が見つかりません（Get-AppxPackage に OpenAI.Codex が無い）。$hint" >&2
        exit 1
      fi
      exe="$(cygpath -u -- "$found")/app/resources/codex.exe"
      if [ ! -f "$exe" ]; then
        echo "codex-bin.sh: codex が見つかりません（$exe が無い）。$hint" >&2
        exit 1
      fi
      printf '%s\n' "$exe"
      exit 0
      ;;
  esac
fi

if [ -z "$latest" ]; then
  echo "codex-bin.sh: codex が見つかりません（$EXT_DIR/openai.chatgpt-*/$BIN_IN_EXT が無い）。VS Code に拡張機能 openai.chatgpt を入れるか、CODEX_BIN に絶対パスを入れてください" >&2
  exit 1
fi
printf '%s\n' "$latest"
