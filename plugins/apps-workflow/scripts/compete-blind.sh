#!/usr/bin/env bash
# 作り手の成果物を、作り手を伏せた A・B・C… に写す。札と伏せ字の対応は乱数で決め、調整役のフォルダにだけ書く
#
# 使い方： bash compete-blind.sh <作業場所 RUN> <調整役のフォルダ COORD>
# 呼び元： compete スキル（5 節。作り手が全員終わったあと）
# 前提：   compete-setup.sh で作った RUN と COORD
#
# 成果物（RUN/kind で決まる）：
#   design … out/design.md
#   screen … out/index.html と out/aim.md
# 成果物がそろわない作り手は「欠け」として外し、伏せ字を付けない（欠けた案を比べると不公平なため）
#
# 作るもの：
#   RUN/blind/<伏せ字>/   成果物の写し
#   RUN/blind/labels.txt  伏せ字の一覧（1 行 1 つ。作り手の情報は入れない）
#   COORD/labels.local.tsv 伏せ字<TAB>札（欠けた札は伏せ字の欄が -）。本人が選ぶまで調整役は開かない
# 写したあと、元と写しの sha256 を 1 つずつ比べる（試行 1 で、写す手順の誤りから 3 枠とも同じ案になったため）
# 出力：  標準出力に、伏せ字を付けた案の数と、欠けた案の数。欠けた札は標準エラーに 1 行ずつ
# 終了コード：0 成功 / 1 写しの失敗・sha256 の不一致 / 2 指定の誤り・前の回の残り・伏せ字を付けられる案が 2 つ未満
set -uo pipefail

# 指定の誤りを標準エラーに出して終了する
usage_error() {
  echo "compete-blind.sh: $1" >&2
  exit 2
}

# 写しの失敗を標準エラーに出して終了する
copy_error() {
  echo "compete-blind.sh: $1" >&2
  exit 1
}

[ $# -eq 2 ] || usage_error "使い方: bash compete-blind.sh <作業場所 RUN> <調整役のフォルダ COORD>"
run="$(realpath -e -- "$1")" || usage_error "作業場所がありません: $1"
coord="$(realpath -e -- "$2")" || usage_error "調整役のフォルダがありません: $2"
[ -f "$run/kind" ] || usage_error "作業場所に kind がありません（compete-setup.sh で作ったものですか）: $run"
[ -f "$coord/workers.tsv" ] || usage_error "調整役のフォルダに workers.tsv がありません: $coord"
[ ! -e "$run/blind" ] || usage_error "前の回の blind/ が残っています: $run/blind"
[ ! -e "$coord/labels.local.tsv" ] || usage_error "前の回の labels.local.tsv が残っています: $coord"

kind="$(cat -- "$run/kind")"
case "$kind" in
  design) files=(design.md) ;;
  screen) files=(index.html aim.md) ;;
  *) usage_error "kind が design でも screen でもありません: $kind" ;;
esac

# 成果物がそろった札と、欠けた札に分ける
complete=()
missing=()
while IFS=$'\t' read -r tag _maker; do
  [ -n "$tag" ] || continue
  ok=1
  for f in "${files[@]}"; do
    # -s は「あって空でない」。フォルダは -f で外す
    if [ ! -f "$run/makers/$tag/out/$f" ] || [ ! -s "$run/makers/$tag/out/$f" ]; then ok=0; fi
  done
  if [ "$ok" -eq 1 ]; then complete+=("$tag"); else missing+=("$tag"); fi
done < "$coord/workers.tsv"

[ "${#complete[@]}" -ge 2 ] || usage_error "成果物がそろった案が 2 つ未満です（${#complete[@]} 件）。比べられません"
[ "${#complete[@]}" -le 26 ] || usage_error "案が多すぎます（${#complete[@]} 件。伏せ字は A〜Z）"

# 並び順を乱数で決める。番号は配列の添え字で数える（サブシェルの中で数えると外に伝わらないため。試行 1 の誤り）
mapfile -t shuffled < <(printf '%s\n' "${complete[@]}" | shuf)
letters=(A B C D E F G H I J K L M N O P Q R S T U V W X Y Z)

mkdir -p -- "$run/blind" || copy_error "フォルダを作れません: $run/blind"
: > "$coord/labels.local.tsv" || copy_error "書けません: $coord/labels.local.tsv"
: > "$run/blind/labels.txt" || copy_error "書けません: $run/blind/labels.txt"
for i in "${!shuffled[@]}"; do
  tag="${shuffled[$i]}"
  label="${letters[$i]}"
  mkdir -p -- "$run/blind/$label" || copy_error "フォルダを作れません: $run/blind/$label"
  for f in "${files[@]}"; do
    src="$run/makers/$tag/out/$f"
    dst="$run/blind/$label/$f"
    cp -- "$src" "$dst" || copy_error "写せません: $src"
    a="$(sha256sum < "$src" | cut -c1-64)"
    b="$(sha256sum < "$dst" | cut -c1-64)"
    [ "$a" = "$b" ] || copy_error "写しの sha256 が元と違います: $label/$f"
  done
  printf '%s\t%s\n' "$label" "$tag" >> "$coord/labels.local.tsv" || copy_error "書けません: $coord/labels.local.tsv"
  printf '%s\n' "$label" >> "$run/blind/labels.txt" || copy_error "書けません: $run/blind/labels.txt"
done
for tag in "${missing[@]}"; do
  printf -- '-\t%s\n' "$tag" >> "$coord/labels.local.tsv" || copy_error "書けません: $coord/labels.local.tsv"
  echo "compete-blind.sh: 成果物がそろわないので外した: $tag" >&2
done

# 伏せ字どうしで中身が同じなら止める（写す先を取り違えたときに気づくため）
declare -A seen_sum=()
while IFS= read -r label; do
  sum="$(cat -- "${files[@]/#/$run/blind/$label/}" | sha256sum | cut -c1-64)"
  [ -z "${seen_sum[$sum]+x}" ] || copy_error "$label と ${seen_sum[$sum]} の中身が同じです。写す手順か作り手の成果物を確かめてください"
  seen_sum[$sum]="$label"
done < "$run/blind/labels.txt"

echo "伏せ字を付けた案: ${#shuffled[@]} 件"
echo "欠けた案: ${#missing[@]} 件"
