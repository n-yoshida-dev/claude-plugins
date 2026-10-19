#!/usr/bin/env bash
# 秘密情報のコミットを止めるフック（hooks/guard-secrets.sh）の回帰テスト
#
# 使い方： bash test-guard-secrets.sh
# 試験用のリポジトリを一時フォルダに作り、ファイルをステージしてからフックに git commit のイベントを渡す
# 確かめること：日本語を含むパスの .env・秘密鍵を止めるか（core.quotePath が既定の true でも）、
#               普通のファイル・.env.example・git 以外のコマンドを通すか
# 出力：  1 件ごとに ok / NG。NG が 1 件でもあれば exit 1
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/../hooks/guard-secrets.sh"
failures=0
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# 手元の ~/.gitconfig（core.quotePath=false など）に左右されないよう、git の既定の設定で動かす
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
REPO="$WORK/repo"
git init -q "$REPO"

# 結果を 1 行で出し、NG を数える
check() {
  local name="$1"; shift
  if "$@"; then
    echo "ok  $name"
  else
    echo "NG  $name"
    failures=$((failures + 1))
  fi
}

# ステージを空にしてから、引数のファイルを作ってステージする
stage() {
  git -C "$REPO" rm -q -r --cached . > /dev/null 2>&1
  local f
  for f in "$@"; do
    mkdir -p "$REPO/$(dirname "$f")"
    echo x > "$REPO/$f"
    git -C "$REPO" add -- "$f"
  done
}

# フックに Bash のイベントを渡し、終了コードが期待どおりか確かめる（$1=期待の終了コード $2=コマンド）
hook_exits() {
  local want="$1" cmd="$2" code
  (cd "$REPO" && jq -n --arg c "$cmd" '{tool_input:{command:$c}}' | bash "$HOOK" > /dev/null 2>&1)
  code=$?
  [ "$code" -eq "$want" ]
}

stage ascii/.env
check "英字のフォルダの .env を止める" hook_exits 2 "git commit -m x"
stage "メモ/.env"
check "日本語のフォルダの .env を止める" hook_exits 2 "git commit -m x"
stage "鍵/本番.pem"
check "日本語のファイル名の秘密鍵を止める" hook_exits 2 "git commit -m x"
stage secrets/a.txt
check "secrets/ の下を止める" hook_exits 2 "git commit -m x"
stage README.md
check "普通のファイルは通す" hook_exits 0 "git commit -m x"
stage "メモ/議事録.md"
check "日本語の普通のファイルは通す" hook_exits 0 "git commit -m x"
stage "メモ/.env.example"
check "雛形の .env.example は通す" hook_exits 0 "git commit -m x"
stage "メモ/.env"
check "git 以外のコマンドは検査しない" hook_exits 0 "ls -la"

echo
if [ "$failures" -gt 0 ]; then
  echo "NG が $failures 件"
  exit 1
fi
echo "すべて ok"
