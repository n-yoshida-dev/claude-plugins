#!/usr/bin/env bash
# コンペの作業場所を作る。作り手ごとのフォルダに、ブリーフと材料を同じように複製する
#
# 使い方： bash compete-setup.sh --kind <design|screen> --root <リポジトリのルート> --run <作業場所> --coord <調整役のフォルダ>
#                                --brief <ブリーフ.md> --parts <節の一覧.txt> [--makers "opus fable astra"] [材料のファイル ...]
# 呼び元： compete スキル（3 節）
#
# 作るもの（作業場所 RUN。Codex にも読ませるので、Claude の作業用フォルダの外に置く）：
#   RUN/kind               お題の形（design / screen）
#   RUN/input/             brief.md・parts.txt・材料（ファイル名だけで平らに置く）
#   RUN/makers/<札>/input/ 作り手ごとの複製。<札> は w- と乱数 6 桁で、作り手の名前を含まない
#                          （レビュー役・審査役がフォルダの名前から作り手を知らないため）
#   RUN/makers/<札>/out/   作り手が成果物を置く空のフォルダ
# 調整役のフォルダ COORD（Claude の作業用フォルダの中。Codex には読ませない）：
#   COORD/workers.tsv           札<TAB>作り手（調整役が作り手を起動するときに読む）
#   COORD/deny-read-<作り手>.txt  Codex の作り手に渡す「読ませない場所」の一覧。共通の一覧に、ほかの作り手のフォルダ・RUN/rebuttal・COORD を足したもの
#   COORD/deny-read-judge.txt   Codex の審査役に渡す一覧。共通の一覧に、RUN/makers・RUN/rebuttal・RUN/judges・COORD を足したもの
#   COORD を足すのは、scratchpad が無く mktemp -d（/tmp/tmp.…）に作ったときも、対応表を Codex に読ませないため
#
# 材料の決まり：
#   - リポジトリの中のファイルは、Git で管理していて gitignore の対象でないものだけ（コミットしない＝外に出さない前提のため）
#   - リポジトリの外のファイルは、調整役が撮った画像（.png / .jpg / .jpeg / .webp）だけ
#   - PRIVATE.md・*.local.*・.env* はどこにあっても止める。同じファイル名が 2 つあっても止める
# 止める場所：~/workspace/ops・~/workspace/personal（と環境変数 CODEX_DENY_ROOTS に : 区切りで足した場所）の中、ルートに data/ のあるリポジトリ
#   （Codex の中の操作には Claude 側のフックが効かないため。ops の docs/2026-10-04-マルチモデル協調の採用判断.md §7。codex-review-target.sh と同じ）
# 出力：  標準出力に「札<TAB>作り手」を作り手ごとに 1 行
# 終了コード：0 成功 / 1 書き込みの失敗 / 2 指定の誤り・止める場所や材料（このときは作業場所を作らない）
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DENY="$SCRIPT_DIR/../config/codex-review-deny-read.txt"

# 指定の誤りを標準エラーに出して終了する
usage_error() {
  echo "compete-setup.sh: $1" >&2
  exit 2
}

# 書き込みの失敗を標準エラーに出して終了する
write_error() {
  echo "compete-setup.sh: $1" >&2
  exit 1
}

kind=""; root=""; run=""; coord=""; brief=""; parts=""; makers="opus fable astra"
materials=()
while [ $# -gt 0 ]; do
  case "$1" in
    --kind|--root|--run|--coord|--brief|--parts|--makers)
      [ $# -ge 2 ] || usage_error "$1 に値がありません"
      case "$1" in
        --kind) kind="$2" ;; --root) root="$2" ;; --run) run="$2" ;; --coord) coord="$2" ;;
        --brief) brief="$2" ;; --parts) parts="$2" ;; --makers) makers="$2" ;;
      esac
      shift 2 ;;
    --) shift; materials+=("$@"); break ;;
    -*) usage_error "知らない指定です: $1" ;;
    *) materials+=("$1"); shift ;;
  esac
done

case "$kind" in design|screen) ;; *) usage_error "--kind は design か screen です（指定: ${kind:-なし}）" ;; esac
for v in root run coord brief parts; do
  [ -n "${!v}" ] || usage_error "--$v がありません"
done
if [ ! -f "$brief" ] || [ ! -s "$brief" ]; then usage_error "ブリーフが無いか空です: $brief"; fi
if [ ! -f "$parts" ] || [ ! -s "$parts" ]; then usage_error "節の一覧が無いか空です: $parts"; fi
[ -f "$BASE_DENY" ] || usage_error "共通の「読ませない場所」の一覧がありません: $BASE_DENY"

root="$(realpath -e -- "$root")" || usage_error "リポジトリのルートを解決できません: $root"
[ "$(git -C "$root" rev-parse --show-toplevel 2>/dev/null)" = "$root" ] || usage_error "Git のリポジトリのルートではありません: $root"
IFS=':' read -r -a extra_roots <<< "${CODEX_DENY_ROOTS:-}"
for d in "$HOME/workspace/ops" "$HOME/workspace/personal" "${extra_roots[@]}"; do
  [ -n "$d" ] || continue
  d="$(realpath -m -- "$d")"
  case "$root/" in "$d"/*) usage_error "コンペをしない場所（$d）の中です: $root" ;; esac
done
[ ! -e "$root/data" ] || usage_error "リポジトリのルートに data/ があります: $root"

read -r -a maker_list <<< "$makers"
[ "${#maker_list[@]}" -ge 2 ] || usage_error "作り手は 2 つ以上です（指定: $makers）"
declare -A seen_maker=()
for m in "${maker_list[@]}"; do
  [[ "$m" =~ ^[a-z][a-z0-9-]*$ ]] || usage_error "作り手の名前は英小文字・数字・- だけです: $m"
  [ -z "${seen_maker[$m]+x}" ] || usage_error "同じ作り手が 2 回あります: $m"
  seen_maker[$m]=1
done

run="$(realpath -m -- "$run")"
coord="$(realpath -m -- "$coord")"
if [ -e "$run" ] && [ -n "$(ls -A -- "$run" 2>/dev/null)" ]; then usage_error "作業場所が空ではありません: $run"; fi
if [ -e "$coord/workers.tsv" ]; then usage_error "調整役のフォルダに前の回の workers.tsv があります: $coord"; fi
case "$run/" in "$coord"/*) usage_error "作業場所を調整役のフォルダの中に置かないでください（作り手が対応表に届くため）: $run" ;; esac
case "$coord/" in "$run"/*) usage_error "調整役のフォルダを作業場所の中に置かないでください（作り手が対応表に届くため）: $coord" ;; esac

# 材料を確かめる（作業場所を作る前に、すべて確かめる）
declare -A seen_name=()
material_paths=()
for f in "${materials[@]}"; do
  if [ ! -f "$f" ] || [ ! -r "$f" ]; then usage_error "材料が読めません: $f"; fi
  p="$(realpath -e -- "$f")" || usage_error "材料のパスを解決できません: $f"
  name="$(basename -- "$p")"
  case "$name" in
    PRIVATE.md|*.local.*|.env*) usage_error "非公開の置き場のファイルは材料にできません: $name" ;;
    brief.md|parts.txt) usage_error "材料の名前が作業場所のファイルとぶつかります: $name" ;;
  esac
  [ -z "${seen_name[$name]+x}" ] || usage_error "同じファイル名の材料が 2 つあります: $name"
  seen_name[$name]=1
  case "$p" in
    "$root"/*)
      rel="${p#"$root"/}"
      git -C "$root" ls-files --error-unmatch -- "$rel" > /dev/null 2>&1 || usage_error "Git で管理していないファイルは材料にできません: $rel"
      if git -C "$root" check-ignore -q --no-index -- "$rel"; then usage_error "gitignore の対象は材料にできません: $rel"; fi
      ;;
    *)
      case "$name" in
        *.png|*.jpg|*.jpeg|*.webp) ;;
        *) usage_error "リポジトリの外の材料は画像（.png / .jpg / .jpeg / .webp）だけです: $p" ;;
      esac
      ;;
  esac
  material_paths+=("$p")
done

mkdir -p -- "$run/input" "$coord" || write_error "フォルダを作れません: $run / $coord"
printf '%s\n' "$kind" > "$run/kind" || write_error "書けません: $run/kind"
cp -- "$brief" "$run/input/brief.md" || write_error "ブリーフを写せません"
cp -- "$parts" "$run/input/parts.txt" || write_error "節の一覧を写せません"
for p in "${material_paths[@]}"; do
  cp -- "$p" "$run/input/" || write_error "材料を写せません: $p"
done

# 作り手ごとのフォルダ。札は乱数で、作り手の名前を含めない
: > "$coord/workers.tsv" || write_error "書けません: $coord/workers.tsv"
declare -A tag_of=()
for m in "${maker_list[@]}"; do
  while :; do
    tag="w-$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')"
    [ ! -e "$run/makers/$tag" ] && break
  done
  tag_of[$m]="$tag"
  mkdir -p -- "$run/makers/$tag/out" || write_error "作り手のフォルダを作れません: $tag"
  cp -R -- "$run/input" "$run/makers/$tag/input" || write_error "材料を複製できません: $tag"
  printf '%s\t%s\n' "$tag" "$m" >> "$coord/workers.tsv" || write_error "書けません: $coord/workers.tsv"
done

# Codex に渡す「読ませない場所」の一覧
for m in "${maker_list[@]}"; do
  out="$coord/deny-read-$m.txt"
  {
    cat -- "$BASE_DENY"
    echo ""
    echo "# compete-setup.sh が足した：ほかの作り手のフォルダ（案をお互いに見せないため）と、反論の置き場（ほかの作り手の答えを見せないため。依頼書は codex-run.sh が標準入力で渡す）"
    for o in "${maker_list[@]}"; do
      [ "$o" = "$m" ] || echo "$run/makers/${tag_of[$o]}"
    done
    echo "$run/rebuttal"
    echo "# 調整役のフォルダ（作り手と札・伏せ字の対応がある。scratchpad の外に作った場合も読ませないため）"
    echo "$coord"
  } > "$out" || write_error "書けません: $out"
done
{
  cat -- "$BASE_DENY"
  echo ""
  echo "# compete-setup.sh が足した：作り手のフォルダと反論の置き場と調整役のフォルダ（審査役が作り手を知らないため）、"
  echo "# ほかの審査役の判定の置き場（審査役どうしが独立に判定するため）"
  echo "$run/makers"
  echo "$run/rebuttal"
  echo "$run/judges"
  echo "$coord"
} > "$coord/deny-read-judge.txt" || write_error "書けません: $coord/deny-read-judge.txt"
mkdir -p -- "$run/rebuttal" "$run/judges" || write_error "フォルダを作れません: $run/rebuttal / $run/judges"

cat -- "$coord/workers.tsv"
