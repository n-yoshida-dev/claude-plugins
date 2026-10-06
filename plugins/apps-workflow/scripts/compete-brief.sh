#!/usr/bin/env bash
# コンペの作り手・レビュー役・審査役に渡す依頼書を作る
#
# 使い方：
#   bash compete-brief.sh maker  <作業場所 RUN> <札> <claude|codex>     → RUN/makers/<札>/task.md
#   bash compete-brief.sh review <作業場所 RUN> <伏せ字>                 → RUN/briefs/review-<伏せ字>.md
#   bash compete-brief.sh judge  <作業場所 RUN> <審査役の名前> <claude|codex> → RUN/briefs/judge-<名前>.md
# 呼び元： compete スキル（4・7・8 節）
#
# claude / codex は、受け取る側がファイルを書けるかで「書き方」を変えるための指定。
#   claude … Agent ツールで動く。成果物・レビュー・判定をファイルに書き、返事は「書いた」だけ
#   codex  … codex-run.sh を読み取り専用で動かす。ファイルを書けないので、返事に本文を書かせ、codex-run.sh の -o でファイルにする
# レビュー役は Claude 側だけ（Agent ツールで、案ごとに新しい文脈）。
# 審査役は、依頼書ごとにレビューの並び順を乱数で変える（並び順で有利・不利が出ないため。pairmark の考え方。判断文書 §2 の問い 1）
# 使うプロンプト：
#   作り手   skills/compete/maker-brief.md（自作）
#   レビュー prompts/slot-machine/writing-2-reviewer.md（写し）＋ skills/compete/reviewer-rules.md（自作の追加の決まり）
#   審査     prompts/slot-machine/writing-3-judge.md（写し）＋ skills/compete/judge-rules.md（自作の追加の決まり）
# 出力：  作った依頼書のパスを 1 行。judge は 2 行目に「並び順: A C B」
# 終了コード：0 成功 / 1 書き込みの失敗 / 2 指定の誤り・前の手順の成果物が無い
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SKILL_DIR="$PLUGIN_ROOT/skills/compete"
FILL="$SCRIPT_DIR/fill-prompt.sh"

# 指定の誤りを標準エラーに出して終了する
usage_error() {
  echo "compete-brief.sh: $1" >&2
  exit 2
}

# 書き込みの失敗を標準エラーに出して終了する
write_error() {
  echo "compete-brief.sh: $1" >&2
  exit 1
}

# 受け取る側の指定を確かめる
check_side() {
  case "$1" in claude|codex) ;; *) usage_error "受け取る側は claude か codex です（指定: ${1:-なし}）" ;; esac
}

[ $# -ge 3 ] || usage_error "使い方: bash compete-brief.sh <maker|review|judge> <作業場所 RUN> ..."
mode="$1"
run="$(realpath -e -- "$2")" || usage_error "作業場所がありません: $2"
[ -f "$run/kind" ] || usage_error "作業場所に kind がありません（compete-setup.sh で作ったものですか）: $run"
kind="$(cat -- "$run/kind")"
case "$kind" in design|screen) ;; *) usage_error "kind が design でも screen でもありません: $kind" ;; esac
mkdir -p -- "$run/briefs" || write_error "フォルダを作れません: $run/briefs"

case "$mode" in
  maker)
    [ $# -eq 4 ] || usage_error "使い方: bash compete-brief.sh maker <作業場所 RUN> <札> <claude|codex>"
    tag="$3"; side="$4"; check_side "$side"
    if [[ ! "$tag" =~ ^w-[0-9a-f]+$ ]] || [ ! -d "$run/makers/$tag" ]; then usage_error "作り手の札がありません: $tag"; fi
    dir="$run/makers/$tag"
    if [ "$side" = "claude" ]; then
      if [ "$kind" = "design" ]; then files="design.md"; else files="index.html と aim.md"; fi
      rule="成果物（$files）を \`$dir/out/\` に書く。最後の返事は「書いた」の 1 語だけにする"
    elif [ "$kind" = "design" ]; then
      rule="あなたは読み取り専用で動いていて、ファイルを書けません。最後の返事に design.md の本文だけを書いてください（前置き・後書きを付けない）。調整役がそのままファイルにします"
    else
      rule="あなたは読み取り専用で動いていて、ファイルを書けません。最後の返事を、決められた JSON の形（html に index.html の中身、aim に aim.md の中身）で返してください。調整役がファイルにします"
    fi
    bash "$FILL" "$SKILL_DIR/maker-brief.md" BRIEF=@"$dir/input/brief.md" INPUT_DIR="$dir/input" \
      OUTPUT_FORM=@"$SKILL_DIR/output-$kind.md" WRITE_RULE="$rule" > "$dir/task.md" || write_error "作り手の依頼書を作れません: $tag"
    printf '%s\n' "$dir/task.md"
    ;;

  review)
    [ $# -eq 3 ] || usage_error "使い方: bash compete-brief.sh review <作業場所 RUN> <伏せ字>"
    label="$3"
    if [[ ! "$label" =~ ^[A-Z]$ ]] || [ ! -d "$run/blind/$label" ]; then usage_error "伏せた案がありません: $label"; fi
    draft_dir="$run/blind/$label"
    if [ "$kind" = "design" ]; then
      draft="$draft_dir/design.md"
      report="$run/briefs/no-report.md"
      printf '（作り手の自己申告は無い。案の本文だけを読む）\n' > "$report" || write_error "書けません: $report"
    else
      draft="$draft_dir/index.html"
      report="$draft_dir/aim.md"
    fi
    context="$run/briefs/context.md"
    # バッククォートは Markdown のコードの印として、そのまま書く
    # shellcheck disable=SC2016
    {
      printf '材料は `%s/input/` にある。ファイル：\n\n' "$run"
      for f in "$run/input"/*; do printf -- '- `%s`\n' "$(basename -- "$f")"; done
    } > "$context" || write_error "書けません: $context"
    out="$run/briefs/review-$label.md"
    rules="$(bash "$FILL" "$SKILL_DIR/reviewer-rules.md" INPUT_DIR="$run/input" DRAFT_DIR="$draft_dir" \
      WRITE_RULE="レビューを \`$run/reviews/$label.md\` に書き、最後の返事は「書いた」の 1 語だけにする")" || write_error "追加の決まりを埋められません"
    bash "$FILL" "$PLUGIN_ROOT/prompts/slot-machine/writing-2-reviewer.md" SPEC=@"$run/input/brief.md" IMPLEMENTER_REPORT=@"$report" \
      PROJECT_CONTEXT=@"$context" WORKTREE_PATH="$draft" SLOT_NUMBER="$label" \
      APPROACH_HINT_USED="なし（作り手に方向の指定はしていない）" > "$out" || write_error "レビューの依頼書を作れません: $label"
    printf '%s\n' "$rules" >> "$out" || write_error "書けません: $out"
    mkdir -p -- "$run/reviews" || write_error "フォルダを作れません: $run/reviews"
    printf '%s\n' "$out"
    ;;

  judge)
    [ $# -eq 4 ] || usage_error "使い方: bash compete-brief.sh judge <作業場所 RUN> <審査役の名前> <claude|codex>"
    name="$3"; side="$4"; check_side "$side"
    [[ "$name" =~ ^[a-z][a-z0-9-]*$ ]] || usage_error "審査役の名前は英小文字・数字・- だけです: $name"
    [ -f "$run/blind/labels.txt" ] || usage_error "伏せた案がありません（compete-blind.sh のあとに使います）"
    mapfile -t labels < "$run/blind/labels.txt"
    for label in "${labels[@]}"; do
      [ -s "$run/reviews/$label.md" ] || usage_error "案 $label のレビューがありません: $run/reviews/$label.md"
    done
    mapfile -t order < <(printf '%s\n' "${labels[@]}" | shuf)
    cards="$run/briefs/judge-$name-scorecards.md"
    paths="$run/briefs/judge-$name-paths.md"
    : > "$cards" || write_error "書けません: $cards"
    : > "$paths" || write_error "書けません: $paths"
    for label in "${order[@]}"; do
      {
        cat -- "$run/reviews/$label.md"
        printf '\n'
        if [ -s "$run/blind/$label/rebuttal.md" ]; then
          printf '### 反論 1 回の答え（案 %s の作り手）\n\n' "$label"
          cat -- "$run/blind/$label/rebuttal.md"
          printf '\n'
        fi
      } >> "$cards" || write_error "書けません: $cards"
      # バッククォートは Markdown のコードの印として、そのまま書く
      # shellcheck disable=SC2016
      printf -- '- 案 %s: `%s/blind/%s/`\n' "$label" "$run" "$label" >> "$paths" || write_error "書けません: $paths"
    done
    mkdir -p -- "$run/judges" || write_error "フォルダを作れません: $run/judges"
    if [ "$side" = "claude" ]; then
      rule="判定を \`$run/judges/$name.md\` に書き、最後の返事は「書いた」の 1 語だけにする"
    else
      rule="あなたは読み取り専用で動いていて、ファイルを書けません。最後の返事に判定の本文だけを書いてください（調整役がファイルにします）"
    fi
    out="$run/briefs/judge-$name.md"
    rules="$(bash "$FILL" "$SKILL_DIR/judge-rules.md" INPUT_DIR="$run/input" BLIND_DIR="$run/blind" REVIEWS_DIR="$run/reviews" \
      PARTS=@"$run/input/parts.txt" WRITE_RULE="$rule")" || write_error "追加の決まりを埋められません"
    bash "$FILL" "$PLUGIN_ROOT/prompts/slot-machine/writing-3-judge.md" SLOT_COUNT="${#order[@]}" SPEC=@"$run/input/brief.md" \
      ALL_SCORECARDS=@"$cards" WORKTREE_PATHS=@"$paths" > "$out" || write_error "審査役の依頼書を作れません: $name"
    printf '%s\n' "$rules" >> "$out" || write_error "書けません: $out"
    printf '%s\n' "$out"
    echo "並び順: ${order[*]}"
    ;;

  *) usage_error "知らない手順です: $mode（maker / review / judge）" ;;
esac
