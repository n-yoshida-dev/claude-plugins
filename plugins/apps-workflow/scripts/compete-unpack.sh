#!/usr/bin/env bash
# Codex の画面案の返事（JSON）を、成果物のファイル index.html と aim.md に書く
#
# 使い方： bash compete-unpack.sh <返事の JSON> <作り手の out フォルダ>
# 呼び元： compete スキル（4 節。画面のお題で、Codex の作り手を読み取り専用で動かしたあと）
# なぜ：  Codex は読み取り専用で動かす（--deny-read-list でホームの直下などを読ませないため。この指定は書き込みありでは使えない）。
#         ファイルを書けないので、返事の形を skills/compete/screen-output.schema.json で {"html": …, "aim": …} に縛り、ここでファイルにする
# 出力：  書いたファイルのパスを 1 行ずつ
# 終了コード：0 成功 / 1 書き込みの失敗 / 2 指定の誤り・JSON の形の誤り（このときは何も書かない）
set -uo pipefail

# 指定の誤りを標準エラーに出して終了する
usage_error() {
  echo "compete-unpack.sh: $1" >&2
  exit 2
}

[ $# -eq 2 ] || usage_error "使い方: bash compete-unpack.sh <返事の JSON> <作り手の out フォルダ>"
json="$1"; out="$2"
if [ ! -f "$json" ] || [ ! -s "$json" ]; then usage_error "返事の JSON が無いか空です: $json"; fi
[ -d "$out" ] || usage_error "out フォルダがありません: $out"
command -v jq > /dev/null || usage_error "jq がありません"
jq -e 'type == "object" and (.html | type == "string" and length > 0) and (.aim | type == "string" and length > 0)' "$json" > /dev/null 2>&1 \
  || usage_error "返事の形が {\"html\": 空でない文字列, \"aim\": 空でない文字列} ではありません: $json"
if [ -e "$out/index.html" ] || [ -e "$out/aim.md" ]; then usage_error "out フォルダにもう成果物があります: $out"; fi

jq -j '.html' "$json" > "$out/index.html" || { echo "compete-unpack.sh: 書けません: $out/index.html" >&2; exit 1; }
jq -r '.aim' "$json" > "$out/aim.md" || { echo "compete-unpack.sh: 書けません: $out/aim.md" >&2; exit 1; }
printf '%s\n' "$out/index.html" "$out/aim.md"
