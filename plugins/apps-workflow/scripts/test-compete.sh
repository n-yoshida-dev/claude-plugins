#!/usr/bin/env bash
# compete スキルのスクリプト（compete-setup・blind・check・unpack・brief・rebuttal・page）と手順書の回帰テスト
#
# 使い方： bash test-compete.sh
# Codex もモデルも呼ばない。一時フォルダに Git のリポジトリと作り手の成果物を作って確かめる。CI でも回す
# 出力：  1 件ごとに ok / NG。NG が 1 件でもあれば exit 1
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SKILL_DIR="$PLUGIN_ROOT/skills/compete"

T="$(mktemp -d "${TMPDIR:-/tmp}/test-compete.XXXXXX")" || { echo "一時フォルダを作れません" >&2; exit 1; }
T="$(realpath -e "$T")"
trap 'rm -rf "$T"' EXIT
failures=0

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

# スクリプトを動かし、標準出力・標準エラー・終了コードを残す（止める場所はテスト用に差し替える）
sh_run() {
  local script="$1"; shift
  CODEX_DENY_ROOTS="$T/deny" bash "$SCRIPT_DIR/$script" "$@" > "$T/out" 2> "$T/err"
  echo $? > "$T/status"
}
# 直前の終了コードが指定の値か
status_is() { [ "$(cat "$T/status")" = "$1" ]; }
# 直前の標準出力・標準エラーに、指定の文字列があるか
out_has() { grep -qF -- "$1" "$T/out"; }
err_has() { grep -qF -- "$1" "$T/err"; }
# ファイルに指定の文字列があるか・無いか
file_has() { grep -qF -- "$2" "$1"; }
file_lacks() { ! grep -qF -- "$2" "$1"; }
# 2 つのファイルの中身が同じか
same() { cmp -s "$1" "$2"; }
# ファイルに作り手の札（w- と 16 進 6 桁）が無いか
no_tag() { ! grep -qE 'w-[0-9a-f]{6}' "$1"; }

# テスト用のリポジトリ
REPO="$T/repo"
mkdir -p "$REPO/docs"
git -C "$REPO" init -q
printf '# 計画\n' > "$REPO/PLAN.md"
printf '正本の文\n' > "$REPO/docs/canon.md"
printf '秘密\n' > "$REPO/PRIVATE.md"
printf '未追跡\n' > "$REPO/untracked.md"
git -C "$REPO" add PLAN.md docs/canon.md PRIVATE.md
git -C "$REPO" -c user.name=t -c user.email=t@example.com commit -q -m init
printf 'png' > "$T/shot.png"
printf 'text' > "$T/note.txt"
mkdir -p "$T/coord-src"
printf '# お題\n\nテストのお題\n' > "$T/coord-src/brief.md"
printf '問題の捉え方\n提案\n' > "$T/coord-src/parts.txt"

# 作業場所を作る（成功する指定）
setup_ok() {
  sh_run compete-setup.sh --kind "$1" --root "$REPO" --run "$2" --coord "$3" --brief "$T/coord-src/brief.md" --parts "$T/coord-src/parts.txt" "${@:4}"
}

echo "--- compete-setup.sh ---"

RUN="$T/run1"; COORD="$T/coord1"
setup_ok design "$RUN" "$COORD" "$REPO/PLAN.md" "$REPO/docs/canon.md" "$T/shot.png"
check "作業場所を作れる" status_is 0
check "作り手 3 つの札を出す" test "$(wc -l < "$COORD/workers.tsv")" -eq 3
check "札は w- と乱数" test "$(grep -cE '^w-[0-9a-f]{6}	(opus|fable|astra)$' "$COORD/workers.tsv")" -eq 3
check "作業場所のパスに作り手の名前が出ない" test -z "$(find "$RUN" | grep -iE 'opus|fable|astra')"
check "kind を書く" test "$(cat "$RUN/kind")" = design
tag_opus="$(awk -F'\t' '$2 == "opus" { print $1 }' "$COORD/workers.tsv")"
tag_fable="$(awk -F'\t' '$2 == "fable" { print $1 }' "$COORD/workers.tsv")"
tag_astra="$(awk -F'\t' '$2 == "astra" { print $1 }' "$COORD/workers.tsv")"
check "作り手のフォルダにブリーフ・節・材料を複製する" test -f "$RUN/makers/$tag_opus/input/brief.md" -a -f "$RUN/makers/$tag_opus/input/parts.txt" -a -f "$RUN/makers/$tag_opus/input/canon.md" -a -f "$RUN/makers/$tag_opus/input/shot.png"
check "作り手のフォルダに空の out/ を作る" test -d "$RUN/makers/$tag_astra/out" -a -z "$(ls -A "$RUN/makers/$tag_astra/out")"
check "Codex の一覧に、ほかの作り手のフォルダを足す" file_has "$COORD/deny-read-astra.txt" "$RUN/makers/$tag_opus"
check "Codex の一覧に、自分のフォルダは入れない" file_lacks "$COORD/deny-read-astra.txt" "$RUN/makers/$tag_astra"
check "Codex の一覧に、反論の置き場を足す" grep -qxF "$RUN/rebuttal" "$COORD/deny-read-astra.txt"
check "Codex の一覧は共通の一覧を含む" file_has "$COORD/deny-read-astra.txt" "/tmp/claude-{uid}"
check "審査役の一覧に、作り手のフォルダ全体を足す" grep -qxF "$RUN/makers" "$COORD/deny-read-judge.txt"
check "審査役の一覧に、ほかの審査役の判定の置き場を足す" grep -qxF "$RUN/judges" "$COORD/deny-read-judge.txt"
coord_abs="$(realpath -m "$COORD")"
check "作り手の一覧に、調整役のフォルダを足す（scratchpad の外に作っても読ませない）" grep -qxF "$coord_abs" "$COORD/deny-read-astra.txt"
check "審査役の一覧に、調整役のフォルダを足す" grep -qxF "$coord_abs" "$COORD/deny-read-judge.txt"

sh_run compete-setup.sh --kind design --root "$REPO" --run "$T/run2" --coord "$T/coord2" --brief "$T/coord-src/brief.md" --parts "$T/coord-src/parts.txt" "$REPO/untracked.md"
check "Git で管理していない材料は止める（終了コード 2）" status_is 2
check "止めたときは作業場所を作らない" test ! -e "$T/run2"
sh_run compete-setup.sh --kind design --root "$REPO" --run "$T/run2" --coord "$T/coord2" --brief "$T/coord-src/brief.md" --parts "$T/coord-src/parts.txt" "$REPO/PRIVATE.md"
check "PRIVATE.md は Git で管理していても止める" status_is 2
sh_run compete-setup.sh --kind design --root "$REPO" --run "$T/run2" --coord "$T/coord2" --brief "$T/coord-src/brief.md" --parts "$T/coord-src/parts.txt" "$T/note.txt"
check "リポジトリの外の画像でない材料は止める" status_is 2
sh_run compete-setup.sh --kind other --root "$REPO" --run "$T/run2" --coord "$T/coord2" --brief "$T/coord-src/brief.md" --parts "$T/coord-src/parts.txt"
check "kind が design・screen 以外なら止める" status_is 2
sh_run compete-setup.sh --kind design --root "$REPO" --run "$RUN" --coord "$T/coord2" --brief "$T/coord-src/brief.md" --parts "$T/coord-src/parts.txt"
check "空でない作業場所には作らない" status_is 2
sh_run compete-setup.sh --kind design --root "$REPO" --run "$T/coord3/run" --coord "$T/coord3" --brief "$T/coord-src/brief.md" --parts "$T/coord-src/parts.txt"
check "作業場所を調整役のフォルダの中に置かせない" status_is 2
sh_run compete-setup.sh --kind design --root "$REPO" --run "$T/run2" --coord "$T/coord2" --brief "$T/coord-src/brief.md" --parts "$T/coord-src/parts.txt" --makers "opus"
check "作り手が 1 つなら止める" status_is 2
mkdir -p "$T/deny/app"
git -C "$T/deny/app" init -q
sh_run compete-setup.sh --kind design --root "$T/deny/app" --run "$T/run2" --coord "$T/coord2" --brief "$T/coord-src/brief.md" --parts "$T/coord-src/parts.txt"
check "コンペをしない場所の中のリポジトリは止める" status_is 2
mkdir -p "$T/dataapp/data"
git -C "$T/dataapp" init -q
sh_run compete-setup.sh --kind design --root "$T/dataapp" --run "$T/run2" --coord "$T/coord2" --brief "$T/coord-src/brief.md" --parts "$T/coord-src/parts.txt"
check "ルートに data/ のあるリポジトリは止める" status_is 2

echo "--- compete-brief.sh maker ---"

sh_run compete-brief.sh maker "$RUN" "$tag_opus" claude
check "Claude の作り手の依頼書を作る" status_is 0
check "依頼書にブリーフが入る" file_has "$RUN/makers/$tag_opus/task.md" "テストのお題"
check "依頼書に out/ への書き方が入る" file_has "$RUN/makers/$tag_opus/task.md" "$RUN/makers/$tag_opus/out/"
check "依頼書に設計案の形が入る" file_has "$RUN/makers/$tag_opus/task.md" "設計案 1 枚"
check "依頼書に差し込み口が残らない" file_lacks "$RUN/makers/$tag_opus/task.md" "{{"
sh_run compete-brief.sh maker "$RUN" "$tag_astra" codex
check "Codex の作り手には返事に本文を書かせる" file_has "$RUN/makers/$tag_astra/task.md" "最後の返事に design.md の本文だけ"
sh_run compete-brief.sh maker "$RUN" w-000000 claude
check "無い札は止める" status_is 2
sh_run compete-brief.sh maker "$RUN" "$tag_opus" gemini
check "受け取る側が claude・codex 以外なら止める" status_is 2

echo "--- compete-blind.sh ---"

# 作り手の成果物（fable は欠けにする）
printf '# 案\n\n## 問題の捉え方\n\nopus の捉え方\n\n## 提案\n\n案その 1\n' > "$RUN/makers/$tag_opus/out/design.md"
printf '# 案\n\n## 問題の捉え方\n\n別の捉え方\n\n## 提案\n\n案その 2\n' > "$RUN/makers/$tag_astra/out/design.md"
sh_run compete-blind.sh "$RUN" "$COORD"
check "伏せられる" status_is 0
check "伏せた案は 2 つ" test "$(wc -l < "$RUN/blind/labels.txt")" -eq 2
check "欠けた案を数える" out_has "欠けた案: 1 件"
check "欠けた札を知らせる" err_has "$tag_fable"
check "対応表で欠けた札の伏せ字は -" grep -qxF -- "$(printf -- '-\t%s' "$tag_fable")" "$COORD/labels.local.tsv"
# 対応表のとおりに写したか
mapping_ok() {
  local label tag
  while IFS=$'\t' read -r label tag; do
    [ "$label" = "-" ] && continue
    same "$RUN/makers/$tag/out/design.md" "$RUN/blind/$label/design.md" || return 1
  done < "$COORD/labels.local.tsv"
}
check "対応表のとおりに写す（伏せ字ごとに中身が元と同じ）" mapping_ok
check "伏せ字の一覧に札を書かない" no_tag "$RUN/blind/labels.txt"
check "伏せた案のフォルダに札の名前が出ない" test -z "$(find "$RUN/blind" | grep -F 'w-')"
sh_run compete-blind.sh "$RUN" "$COORD"
check "前の回の blind/ が残っていれば止める" status_is 2

RUN3="$T/run3"; COORD3="$T/coord-b"
setup_ok design "$RUN3" "$COORD3"
while IFS=$'\t' read -r tag _m; do printf '同じ\n' > "$RUN3/makers/$tag/out/design.md"; done < "$COORD3/workers.tsv"
sh_run compete-blind.sh "$RUN3" "$COORD3"
check "中身が同じ案が 2 つあれば止める（終了コード 1）" status_is 1
RUN4="$T/run4"; COORD4="$T/coord-c"
setup_ok design "$RUN4" "$COORD4"
printf 'ひとつ\n' > "$RUN4/makers/$(head -1 "$COORD4/workers.tsv" | cut -f1)/out/design.md"
sh_run compete-blind.sh "$RUN4" "$COORD4"
check "そろった案が 2 つ未満なら止める（終了コード 2）" status_is 2

echo "--- compete-check.sh ---"

sh_run compete-check.sh "$RUN"
check "作り手の名前を見つける（終了コード 1）" status_is 1
check "見つけた行を伏せ字・ファイル・行で出す" out_has "design.md:5: 作り手・会社の名前"
label_opus="$(awk -F'\t' -v t="$tag_opus" '$2 == t { print $1 }' "$COORD/labels.local.tsv")"
label_astra="$(awk -F'\t' -v t="$tag_astra" '$2 == t { print $1 }' "$COORD/labels.local.tsv")"
printf '# 案\n\n## 問題の捉え方\n\n（伏せ字）の捉え方\n\n## 提案\n\n案その 1\n' > "$RUN/blind/$label_opus/design.md"
sh_run compete-check.sh "$RUN"
check "名前が無ければ終了コード 0" status_is 0
printf '内緒の語 # 説明\n\n' > "$T/forbidden.txt"
printf '# 案\n\n## 問題の捉え方\n\n内緒の語を含む\n\n## 提案\n\n案その 2\n' > "$RUN/blind/$label_astra/design.md"
sh_run compete-check.sh "$RUN" "$T/forbidden.txt"
check "禁止語を見つける" out_has "禁止語「内緒の語」"
printf '# 案\n\n## 問題の捉え方\n\n材料 %s/input/canon.md を読んだ\n\n## 提案\n\n案その 2\n' "$RUN/makers/$tag_astra" > "$RUN/blind/$label_astra/design.md"
sh_run compete-check.sh "$RUN"
check "案に入った作り手の札・フォルダのパスを見つける" out_has "作り手の札・フォルダ"
printf '# 案\n\n## 問題の捉え方\n\nなし\n' > "$RUN/blind/$label_astra/design.md"
sh_run compete-check.sh "$RUN"
check "節の見出しの欠けを見つける" out_has "「## 提案」が 0 回"
printf '# 案\n\n## 問題の捉え方\n\n別の捉え方\n\n## 提案\n\n案その 2\n' > "$RUN/blind/$label_astra/design.md"

echo "--- compete-rebuttal.sh ---"

printf '## 割れた点 1\n\n- A は…、B は…\n' > "$COORD/questions.md"
sh_run compete-rebuttal.sh prepare "$RUN" "$COORD" "$COORD/questions.md"
check "反論の依頼書を作る" status_is 0
check "伏せ字を付けた作り手の分だけ出す" test "$(wc -l < "$T/out")" -eq 2
check "出力に伏せ字を出さない（作り手と依頼書のパスだけ）" test -z "$(cut -f1 "$T/out" | grep -vxE 'opus|astra')"
check "作り手に自分の伏せ字を知らせる" file_has "$RUN/rebuttal/$tag_opus/brief.md" "あなたの案は「$label_opus」"
check "全員に同じ質問を渡す" file_has "$RUN/rebuttal/$tag_astra/brief.md" "## 割れた点 1"
printf '## 割れた点 1\n\n維持\n' > "$RUN/rebuttal/$tag_opus/answer.md"
sh_run compete-rebuttal.sh collect "$RUN" "$COORD"
check "答えを伏せ字の横に集める" same "$RUN/rebuttal/$tag_opus/answer.md" "$RUN/blind/$label_opus/rebuttal.md"
check "欠けた答えを数える" out_has "欠けた答え: 1 件"
check "欠けた答えは札で知らせ、作り手の名前を出さない" grep -qF "$tag_astra" "$T/err"
check "欠けた答えの知らせに作り手の名前が無い" file_lacks "$T/err" "astra"
sh_run compete-rebuttal.sh prepare "$RUN" "$COORD" "$COORD/questions.md"
check "前の回の反論が残っていれば止める" status_is 2

echo "--- compete-brief.sh review / judge ---"

sh_run compete-brief.sh judge "$RUN" fable claude
check "レビューがそろう前の審査は止める" status_is 2
while IFS= read -r label; do
  sh_run compete-brief.sh review "$RUN" "$label"
  printf '## Slot %s Review\n\nレビュー本文 %s\n' "$label" "$label" > "$RUN/reviews/$label.md"
done < "$RUN/blind/labels.txt"
check "レビューの依頼書を作る" test -f "$RUN/briefs/review-$label_opus.md"
check "レビューの依頼書に写したプロンプトが入る（Slot を伏せ字にする）" file_has "$RUN/briefs/review-$label_opus.md" "## Slot $label_opus Review"
check "レビューの依頼書に追加の決まりが入る" file_has "$RUN/briefs/review-$label_opus.md" "申告されていない言い換えを探す"
check "レビューの依頼書に書き先が入る" file_has "$RUN/briefs/review-$label_opus.md" "$RUN/reviews/$label_opus.md"
check "レビューの依頼書に出典の注記が残らない" file_lacks "$RUN/briefs/review-$label_opus.md" "出典:"
check "レビューの依頼書に札を書かない" no_tag "$RUN/briefs/review-$label_opus.md"
sh_run compete-brief.sh judge "$RUN" fable claude
check "審査役の依頼書を作る" status_is 0
check "並び順を出す" out_has "並び順:"
check "審査役の依頼書に全部のレビューが入る" file_has "$RUN/briefs/judge-fable.md" "レビュー本文 $label_astra"
check "審査役の依頼書に反論の答えが入る" file_has "$RUN/briefs/judge-fable.md" "反論 1 回の答え（案 $label_opus の作り手）"
check "審査役の依頼書に節の一覧が入る" file_has "$RUN/briefs/judge-fable.md" "問題の捉え方"
check "審査役の依頼書に節ごとのおすすめの表を求める" file_has "$RUN/briefs/judge-fable.md" "### 節ごとのおすすめ"
check "審査役の依頼書に札を書かない" no_tag "$RUN/briefs/judge-fable.md"
sh_run compete-brief.sh judge "$RUN" astra codex
check "Codex の審査役には返事に本文を書かせる" file_has "$RUN/briefs/judge-astra.md" "最後の返事に判定の本文だけ"

echo "--- compete-page.mjs ---"

mkdir -p "$RUN/judges"
printf '## Slot Machine Verdict\n\n### 節ごとのおすすめ\n| 節 | おすすめの案 | 理由 |\n|---|---|---|\n| 提案 | A | 具体的 |\n' > "$RUN/judges/fable.md"
node "$SCRIPT_DIR/compete-page.mjs" --run "$RUN" --out "$T/page.html" --title "テスト 案くらべ" > /dev/null 2> "$T/err"
check "比較ページを作る" test -s "$T/page.html"
check "ページに title がある" file_has "$T/page.html" "<title>テスト 案くらべ</title>"
check "ページに節が入る" file_has "$T/page.html" "問題の捉え方"
check "ページに審査役の判定が入る" file_has "$T/page.html" "Slot Machine Verdict"
check "ページに札を書かない" no_tag "$T/page.html"
page_has_labels() {
  local label
  while IFS= read -r label; do grep -qF "\"label\":\"$label\"" "$T/page.html" || return 1; done < "$RUN/blind/labels.txt"
}
check "ページに伏せ字ごとの案が入る" page_has_labels

RUN5="$T/run5"; COORD5="$T/coord-d"
setup_ok screen "$RUN5" "$COORD5"
n=0
while IFS=$'\t' read -r tag _m; do
  n=$((n + 1))
  printf '<!doctype html><title>見本 %s</title><script>let a = 1;</script><p>見本</p>\n' "$n" > "$RUN5/makers/$tag/out/index.html"
  printf '## 狙い\n\n狙い %s\n' "$n" > "$RUN5/makers/$tag/out/aim.md"
done < "$COORD5/workers.tsv"
sh_run compete-blind.sh "$RUN5" "$COORD5"
check "画面案も伏せられる" status_is 0
node "$SCRIPT_DIR/compete-page.mjs" --run "$RUN5" --out "$T/page5.html" --title "画面 案くらべ" > /dev/null 2> "$T/err"
check "画面案の比較ページを作る" test -s "$T/page5.html"
check "見本の </script> がページのスクリプトを閉じない（ページの閉じタグは 4 つだけ）" test "$(grep -o '</script>' "$T/page5.html" | wc -l)" -eq 4
node "$SCRIPT_DIR/compete-page.mjs" --run "$T/no-run" --out "$T/page6.html" --title "x" > /dev/null 2>&1
check "作業場所が無ければ終了コード 2" test "$?" -eq 2

echo "--- compete-unpack.sh ---"

mkdir -p "$T/unpack-out"
printf '{"html":"<p>見本</p>","aim":"## 狙い\\n\\n3 行"}' > "$T/screen.json"
sh_run compete-unpack.sh "$T/screen.json" "$T/unpack-out"
check "JSON から index.html を書く" test "$(cat "$T/unpack-out/index.html")" = "<p>見本</p>"
check "JSON から aim.md を書く" file_has "$T/unpack-out/aim.md" "## 狙い"
sh_run compete-unpack.sh "$T/screen.json" "$T/unpack-out"
check "成果物があれば上書きしない" status_is 2
mkdir -p "$T/unpack-out2"
printf '{"html":""}' > "$T/bad.json"
sh_run compete-unpack.sh "$T/bad.json" "$T/unpack-out2"
check "形の違う JSON は止める" status_is 2
check "形の違う JSON のときは何も書かない" test -z "$(ls -A "$T/unpack-out2")"

echo "--- 手順書（SKILL.md） ---"

check "利用者が打ったときだけ動く" grep -qx 'disable-model-invocation: true' "$SKILL_DIR/SKILL.md"
skill_refs_exist() {
  local ref
  # 手順書の ${CLAUDE_PLUGIN_ROOT} は展開せず、文字として探す
  # shellcheck disable=SC2016
  while IFS= read -r ref; do
    [ -e "$PLUGIN_ROOT/$ref" ] || { echo "    無い: $ref" >&2; return 1; }
  done < <(grep -oE '\$\{CLAUDE_PLUGIN_ROOT\}/[A-Za-z0-9_./-]+' "$SKILL_DIR/SKILL.md" | sed 's|^\${CLAUDE_PLUGIN_ROOT}/||' | sort -u)
}
check "手順書が指すファイルがすべてある" skill_refs_exist
check "手順書は Workflow ツールで作り手を起動しない" grep -qF "Workflow ツールは使わない" "$SKILL_DIR/SKILL.md"

echo
if [ "$failures" -eq 0 ]; then
  echo "すべて ok"
else
  echo "NG が $failures 件"
  exit 1
fi
