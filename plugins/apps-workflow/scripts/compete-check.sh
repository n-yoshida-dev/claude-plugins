#!/usr/bin/env bash
# 伏せた案（RUN/blind/）に、作り手の名乗り・禁止語の混入・見出しの崩れが無いかを調べる
#
# 使い方： bash compete-check.sh <作業場所 RUN> [禁止語の一覧.txt]
# 呼び元： compete スキル（5 節。compete-blind.sh のあと）
#
# 調べること：
#   1. モデル・会社の名前（Opus・Fable・Astra・Sol・Luna・Terra・Sonnet・Haiku・Claude・Anthropic・OpenAI・GPT・ChatGPT・Codex・Gemini）。大文字小文字は区別しない
#      Sol・Luna・Terra は前後が英字でないときだけ当てる（solution などを拾わないため）
#      お題によっては中身として正しく出てくる（例：Claude Code を使った作品の紹介）ので、見つけても自動では消さない。
#      調整役が行を読み、作り手の名乗りなら伏せ字にする
#   1b. 作り手の札（w- と 16 進 6 桁）と、作り手のフォルダのパス（/makers/）。作り手が材料のパスを案に引くと入る。見つけたら必ず伏せ字にする
#   2. 禁止語の一覧（任意。1 行 1 語、# から後ろと空行は読まない）。Private リポジトリの原文の言い回しや、本人の非公開の事実の語を入れる
#      （試行 2 で作り手が Private の学習ログの 1 行を案に引いたため）。一覧はリポジトリにも RUN にも置かない（調整役のフォルダに置く）
#   3. design のとき：RUN/input/parts.txt の節が、design.md に「## 節の名前」の行としてちょうど 1 回ずつあるか
#      （比較ページが見出しで節を切り分けるため）
# 出力：  見つけたものを「伏せ字/ファイル:行: 種類: 中身」で 1 行ずつ。最後に件数
# 終了コード：0 何も見つからない / 1 見つかった（調整役が中身を読んで判断する） / 2 指定の誤り
set -uo pipefail

# 指定の誤りを標準エラーに出して終了する
usage_error() {
  echo "compete-check.sh: $1" >&2
  exit 2
}

if [ $# -lt 1 ] || [ $# -gt 2 ]; then usage_error "使い方: bash compete-check.sh <作業場所 RUN> [禁止語の一覧.txt]"; fi
run="$(realpath -e -- "$1")" || usage_error "作業場所がありません: $1"
words_file="${2:-}"
[ -f "$run/blind/labels.txt" ] || usage_error "伏せた案がありません（compete-blind.sh のあとに使います）: $run/blind"
if [ -n "$words_file" ] && [ ! -r "$words_file" ]; then usage_error "禁止語の一覧が読めません: $words_file"; fi
kind="$(cat -- "$run/kind" 2>/dev/null)" || usage_error "作業場所に kind がありません: $run"

# Sol・Luna・Terra（GPT のモデル名の後ろ半分）は短く、solution・console などに含まれるので、前後が英字でないときだけ当てる
NAMES='opus|fable|astra|sonnet|haiku|claude|anthropic|openai|chatgpt|gpt|codex|gemini|(^|[^a-z])(sol|luna|terra)([^a-z]|$)'
found=0

# 見つけたものを 1 行出して数える
report() {
  echo "$1"
  found=$((found + 1))
}

words=()
if [ -n "$words_file" ]; then
  while IFS= read -r w || [ -n "$w" ]; do
    w="${w%%#*}"
    w="$(printf '%s' "$w" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    [ -n "$w" ] && words+=("$w")
  done < "$words_file"
fi

while IFS= read -r label; do
  [ -n "$label" ] || continue
  dir="$run/blind/$label"
  for f in "$dir"/*; do
    [ -f "$f" ] || continue
    name="$(basename -- "$f")"
    while IFS= read -r hit; do
      [ -n "$hit" ] && report "$label/$name:${hit%%:*}: 作り手・会社の名前: ${hit#*:}"
    done < <(grep -n -i -E -- "$NAMES" "$f" | cut -c1-200)
    # 作り手の札（w- と 16 進 6 桁）と作り手のフォルダのパス。作り手が材料のパスを案に引くと入り、調整役の workers.tsv と結び付いて作り手が分かるため
    while IFS= read -r hit; do
      [ -n "$hit" ] && report "$label/$name:${hit%%:*}: 作り手の札・フォルダ: ${hit#*:}"
    done < <(grep -n -E -- 'w-[0-9a-f]{6}|/makers/' "$f" | cut -c1-200)
    for w in "${words[@]}"; do
      while IFS= read -r hit; do
        [ -n "$hit" ] && report "$label/$name:${hit%%:*}: 禁止語「$w」: ${hit#*:}"
      done < <(grep -n -F -- "$w" "$f" | cut -c1-200)
    done
  done
  if [ "$kind" = "design" ]; then
    while IFS= read -r part || [ -n "$part" ]; do
      [ -n "$part" ] || continue
      n="$(grep -c -x -F -- "## $part" "$dir/design.md")"
      [ "$n" -eq 1 ] || report "$label/design.md: 見出し: 「## $part」が $n 回あります（ちょうど 1 回のはず）"
    done < "$run/input/parts.txt"
  fi
done < "$run/blind/labels.txt"

echo "見つかったもの: $found 件"
[ "$found" -eq 0 ]
