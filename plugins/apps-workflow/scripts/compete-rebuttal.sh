#!/usr/bin/env bash
# 割れた点だけの「反論 1 回」の依頼書を作り（prepare）、答えを伏せた案の横に集める（collect）
#
# 使い方：
#   bash compete-rebuttal.sh prepare <作業場所 RUN> <調整役のフォルダ COORD> <割れた点.md>
#   bash compete-rebuttal.sh collect <作業場所 RUN> <調整役のフォルダ COORD>
# 呼び元： compete スキル（6 節）
#
# prepare：伏せ字を付けた作り手ごとに RUN/rebuttal/<札>/brief.md を作る。作り手には「あなたの案は B」と自分の伏せ字だけを知らせる。
#   全員に同じ質問文を渡す（判断文書 §10「反論は全員新しい文脈＋同じ質問文」）。
#   標準出力は「作り手<TAB>依頼書<TAB>答えの置き場」を workers.tsv の順で（伏せ字の順ではない）。
#   調整役は対応表（labels.local.tsv）を開かずに、作り手ごとに依頼書を渡せる。依頼書の中身（伏せ字が書いてある）は調整役が読まない
# collect：RUN/rebuttal/<札>/answer.md を RUN/blind/<伏せ字>/rebuttal.md に写す。調整役は RUN/rebuttal/ の中を読まない
#   （答えの中に「私の案 B では」とあり、作り手と伏せ字の対応が分かるため）
# 出力：  collect は集めた数と欠けた数。欠けた作り手は標準エラーに 1 行ずつ
# 終了コード：0 成功 / 1 書き込みの失敗 / 2 指定の誤り・前の手順の成果物が無い・前の回の残り
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$SCRIPT_DIR/../skills/compete"
FILL="$SCRIPT_DIR/fill-prompt.sh"

# 指定の誤りを標準エラーに出して終了する
usage_error() {
  echo "compete-rebuttal.sh: $1" >&2
  exit 2
}

# 書き込みの失敗を標準エラーに出して終了する
write_error() {
  echo "compete-rebuttal.sh: $1" >&2
  exit 1
}

[ $# -ge 3 ] || usage_error "使い方: bash compete-rebuttal.sh <prepare|collect> <作業場所 RUN> <調整役のフォルダ COORD> [割れた点.md]"
mode="$1"
run="$(realpath -e -- "$2")" || usage_error "作業場所がありません: $2"
coord="$(realpath -e -- "$3")" || usage_error "調整役のフォルダがありません: $3"
[ -f "$coord/workers.tsv" ] || usage_error "調整役のフォルダに workers.tsv がありません: $coord"
[ -f "$coord/labels.local.tsv" ] || usage_error "対応表 labels.local.tsv がありません（compete-blind.sh のあとに使います）: $coord"

# 札から伏せ字を引く（伏せ字が無い＝欠けた札なら空）
declare -A label_of=()
while IFS=$'\t' read -r label tag; do
  [ -n "$tag" ] && [ "$label" != "-" ] && label_of[$tag]="$label"
done < "$coord/labels.local.tsv"

case "$mode" in
  prepare)
    [ $# -eq 4 ] || usage_error "使い方: bash compete-rebuttal.sh prepare <作業場所 RUN> <調整役のフォルダ COORD> <割れた点.md>"
    questions="$4"
    if [ ! -f "$questions" ] || [ ! -s "$questions" ]; then usage_error "割れた点のファイルが無いか空です: $questions"; fi
    if [ -n "$(ls -A -- "$run/rebuttal" 2>/dev/null)" ]; then usage_error "前の回の反論が残っています: $run/rebuttal"; fi
    while IFS=$'\t' read -r tag maker; do
      [ -n "$tag" ] || continue
      [ -n "${label_of[$tag]+x}" ] || continue
      dir="$run/rebuttal/$tag"
      mkdir -p -- "$dir" || write_error "フォルダを作れません: $dir"
      bash "$FILL" "$SKILL_DIR/rebuttal-brief.md" OWN_LABEL="${label_of[$tag]}" BRIEF_PATH="$run/input/brief.md" \
        BLIND_DIR="$run/blind" QUESTIONS=@"$questions" \
        WRITE_RULE="答えを \`$dir/answer.md\` に書き、最後の返事は「書いた」の 1 語だけにする。ファイルを書けない（読み取り専用で動いている）ときは、最後の返事に答えの本文だけを書く（調整役がそのファイルに置く）" \
        > "$dir/brief.md" || write_error "反論の依頼書を作れません: $maker"
      printf '%s\t%s\t%s\n' "$maker" "$dir/brief.md" "$dir/answer.md"
    done < "$coord/workers.tsv"
    ;;

  collect)
    [ $# -eq 3 ] || usage_error "使い方: bash compete-rebuttal.sh collect <作業場所 RUN> <調整役のフォルダ COORD>"
    got=0; lack=0
    while IFS=$'\t' read -r tag maker; do
      [ -n "$tag" ] || continue
      [ -n "${label_of[$tag]+x}" ] || continue
      src="$run/rebuttal/$tag/answer.md"
      dst="$run/blind/${label_of[$tag]}/rebuttal.md"
      [ ! -e "$dst" ] || usage_error "前の回の反論の答えが残っています: $dst"
      if [ -s "$src" ]; then
        cp -- "$src" "$dst" || write_error "写せません: $src"
        got=$((got + 1))
      else
        echo "compete-rebuttal.sh: 答えがありません: $maker" >&2
        lack=$((lack + 1))
      fi
    done < "$coord/workers.tsv"
    echo "集めた答え: $got 件"
    echo "欠けた答え: $lack 件"
    ;;

  *) usage_error "知らない手順です: $mode（prepare / collect）" ;;
esac
