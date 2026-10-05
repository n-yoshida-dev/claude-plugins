#!/usr/bin/env bash
# fill-prompt.sh・codex-review-target.sh と codex-review スキルの手順書の回帰テスト
#
# 使い方： bash test-codex-review.sh
# Codex は呼ばない。一時フォルダにテンプレートと Git のリポジトリを作って確かめる。CI でも回す
# 出力：  1 件ごとに ok / NG。NG が 1 件でもあれば exit 1
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FILL_SH="$SCRIPT_DIR/fill-prompt.sh"
TARGET_SH="$SCRIPT_DIR/codex-review-target.sh"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROMPTS="$PLUGIN_ROOT/prompts"
SKILL_DIR="$PLUGIN_ROOT/skills/codex-review"

T="$(mktemp -d "${TMPDIR:-/tmp}/test-codex-review.XXXXXX")" || { echo "一時フォルダを作れません" >&2; exit 1; }
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

# fill-prompt.sh を動かし、標準出力・標準エラー・終了コードを残す
fill() {
  bash "$FILL_SH" "$@" > "$T/fill.out" 2> "$T/fill.err"
  echo $? > "$T/fill.status"
}
# codex-review-target.sh を動かし、標準出力・標準エラー・終了コードを残す（送らない場所はテスト用に差し替える）
target() {
  CODEX_DENY_ROOTS="$T/deny" bash "$TARGET_SH" "$@" > "$T/target.out" 2> "$T/target.err"
  echo $? > "$T/target.status"
}

# 直前の fill の終了コードが指定の値か
fill_status_is() { [ "$(cat "$T/fill.status")" = "$1" ]; }
# 直前の fill の出力が、指定のファイルの中身と同じか
fill_out_is() { cmp -s "$T/fill.out" "$1"; }
# 直前の fill の出力が空か
fill_out_empty() { [ ! -s "$T/fill.out" ]; }
# 直前の fill の出力に、指定の文字列が無いか
fill_out_lacks() { ! grep -qF -- "$1" "$T/fill.out"; }
# 直前の fill の標準エラーに、指定の文字列があるか
fill_err_has() { grep -qF -- "$1" "$T/fill.err"; }
# 直前の target の終了コードが指定の値か
target_status_is() { [ "$(cat "$T/target.status")" = "$1" ]; }
# 直前の target の標準エラーに、指定の文字列があるか
target_err_has() { grep -qF -- "$1" "$T/target.err"; }
# 直前の target の出力が「文書<TAB>ルート」か
target_out_is() { [ "$(cat "$T/target.out")" = "$(printf '%s\t%s' "$1" "$2")" ]; }

echo "--- fill-prompt.sh ---"

# 注記つきのテンプレート（写したプロンプトと同じ形）
cat > "$T/tpl.md" <<'EOS'
<!--
出典: テスト
-->

Role: {{ROLE}} / again {{ROLE}}
Path: `{{FILE_PATH}}`
<content>
{{CONTENT}}
</content>
EOS
printf '一行目\n{{SPEC}} という書き方を説明する文書\n' > "$T/doc.md"
# 値の & \ $ がそのまま入ることを確かめるため、わざと展開しない単引用符で渡す
# shellcheck disable=SC2016
fill "$T/tpl.md" ROLE='a&b \1 $x' FILE_PATH=docs/plan.md CONTENT=@"$T/doc.md"
cat > "$T/expected.md" <<'EOS'
Role: a&b \1 $x / again a&b \1 $x
Path: `docs/plan.md`
<content>
一行目
{{SPEC}} という書き方を説明する文書
</content>
EOS
check "差し込み口を埋めて、冒頭の注記と次の空行を外す" fill_out_is "$T/expected.md"
check "成功すると終了コード 0" fill_status_is 0

fill "$T/tpl.md" ROLE=r FILE_PATH=p
check "埋め残しがあれば終了コード 2" fill_status_is 2
check "埋め残しがあれば何も出さない" fill_out_empty
check "埋め残しの名前を示す" fill_err_has "{{CONTENT}}"

fill "$T/tpl.md" ROLE=r FILE_PATH=p CONTENT=@"$T/doc.md" EXTRA=x
check "テンプレートに無い名前は終了コード 2" fill_status_is 2
check "テンプレートに無い名前を示す" fill_err_has "{{EXTRA}}"

fill "$T/tpl.md" ROLE=@"$T/doc.md" FILE_PATH=p CONTENT=@"$T/doc.md"
check "行の途中の差し込み口にファイルは入れられない" fill_status_is 2

fill "$T/tpl.md" ROLE=r FILE_PATH=p CONTENT=@"$T/no-such.md"
check "差し込むファイルが無ければ終了コード 2" fill_status_is 2

fill "$T/tpl.md" ROLE=r ROLE=s FILE_PATH=p CONTENT=@"$T/doc.md"
check "同じ名前を 2 回指定したら終了コード 2" fill_status_is 2

fill "$T/tpl.md" role=r
check "小文字の名前は終了コード 2" fill_status_is 2

printf '<!--\n閉じていない注記\n' > "$T/open.md"
fill "$T/open.md"
check "閉じていない注記は終了コード 2" fill_status_is 2

# 写したプロンプトそのものを埋められる（差し込み口の名前がテンプレートと合っている）
printf '# 計画\n- 手順 1\n' > "$T/plan.md"
fill "$PROMPTS/crazytieguy-codex-plugin-cc/plan-review.md" PLAN_CONTENT=@"$T/plan.md"
check "plan-review.md を埋められる" fill_status_is 0
check "plan-review.md の注記を外す" fill_out_lacks "出典:"
check "plan-review.md に文書の中身が入る" grep -qxF -- "- 手順 1" "$T/fill.out"
printf '{"id":"R1"}\n' > "$T/finding.json"
fill "$PROMPTS/codex-pr-review/verifier-claude-prompt.md" REVIEW_RULES=@"$T/plan.md" FINDING=@"$T/finding.json" FILE_PATH=docs/plan.md FILE_CONTENT=@"$T/plan.md" DIFF_HUNK=@"$T/plan.md"
check "verifier-claude-prompt.md を埋められる" fill_status_is 0
# 逆引用符は Markdown の書き方そのもので、コマンドの置き換えではない
# shellcheck disable=SC2016
check "verifier-claude-prompt.md の File 行に文書のパスが入る" grep -qxF -- 'File: `docs/plan.md`' "$T/fill.out"

# codex-review スキルの自作の再レビューの依頼文も埋められる
printf 'R1: 採用\n' > "$T/decisions.md"
printf '%s\n' '-旧' '+新' > "$T/diff.txt"
fill "$SKILL_DIR/followup.md" DECISIONS=@"$T/decisions.md" DIFF=@"$T/diff.txt" PLAN_CONTENT=@"$T/plan.md"
check "followup.md を埋められる" fill_status_is 0
check "followup.md に差分が入る" grep -qxF -- "+新" "$T/fill.out"

echo "--- codex-review スキルの手順書 ---"

# 手順書が \${CLAUDE_PLUGIN_ROOT} で指すファイルが、すべてプラグインの中にある
missing=""
# ${CLAUDE_PLUGIN_ROOT} という文字そのものを探すので、わざと展開しない単引用符で書く
# shellcheck disable=SC2016
while IFS= read -r rel; do
  [ -e "$PLUGIN_ROOT/$rel" ] || missing="$missing $rel"
done < <(grep -oE '\$\{CLAUDE_PLUGIN_ROOT\}/[A-Za-z0-9._/-]+' "$SKILL_DIR/SKILL.md" | sed 's|^\${CLAUDE_PLUGIN_ROOT}/||' | sort -u)
check "手順書が指すファイルがすべてある${missing:+（無い:$missing）}" test -z "$missing"
check "手順書は利用者が打ったときだけ動く（disable-model-invocation）" grep -qxF -- "disable-model-invocation: true" "$SKILL_DIR/SKILL.md"

echo "--- codex-review-target.sh ---"

# テスト用のリポジトリ
R="$T/repo"
mkdir -p "$R/docs" "$T/deny"
git -C "$R" init -q
printf 'ignored.md\n' > "$R/.gitignore"
printf '# 計画\n' > "$R/docs/plan.md"
printf '# メモ\n' > "$R/docs/notes.txt"
printf 'x\n' > "$R/ignored.md"
printf 'x\n' > "$R/PRIVATE.md"
printf 'x\n' > "$R/docs/plan.local.md"
printf 'x\n' > "$R/.env.md"
printf 'x\n' > "$R/main.go"
: > "$R/docs/empty.md"

target "$R/docs/plan.md"
check "送ってよい文書は終了コード 0" target_status_is 0
check "文書の絶対パスとリポジトリのルートを出す" target_out_is "$R/docs/plan.md" "$R"
(cd "$R" && target docs/plan.md)
check "相対パスでも絶対パスにして出す" target_out_is "$R/docs/plan.md" "$R"
target "$R/docs/notes.txt"
check ".txt も送ってよい" target_status_is 0

target "$R/docs/no-such.md"
check "ファイルが無ければ終了コード 2" target_status_is 2
target "$R/docs/empty.md"
check "空のファイルは終了コード 2" target_status_is 2
target "$R/main.go"
check "文書でないファイルは終了コード 2" target_status_is 2
check "文書でないとクラウドレビューの担当だと示す" target_err_has "クラウドレビュー"
target "$R/PRIVATE.md"
check "PRIVATE.md は終了コード 2" target_status_is 2
target "$R/docs/plan.local.md"
check "*.local.* は終了コード 2" target_status_is 2
target "$R/.env.md"
check ".env* は終了コード 2" target_status_is 2
target "$R/ignored.md"
check "gitignore の対象は終了コード 2" target_status_is 2
check "gitignore の対象だと示す" target_err_has "gitignore"

mkdir -p "$T/outside"
printf '# 外\n' > "$T/outside/plan.md"
target "$T/outside/plan.md"
check "Git のリポジトリの外は終了コード 2" target_status_is 2

# 送らない場所の中のリポジトリ
D="$T/deny/ops"
mkdir -p "$D/docs"
git -C "$D" init -q
printf '# 計画\n' > "$D/docs/plan.md"
target "$D/docs/plan.md"
check "送らない場所の中は終了コード 2" target_status_is 2
# 送らない場所の中を指すシンボリックリンクも止める
ln -s "$D/docs/plan.md" "$R/docs/link.md"
target "$R/docs/link.md"
check "送らない場所を指すリンクは終了コード 2" target_status_is 2

# ルートに data/ があるリポジトリ
R2="$T/repo-data"
mkdir -p "$R2/docs" "$R2/data"
git -C "$R2" init -q
printf '# 計画\n' > "$R2/docs/plan.md"
target "$R2/docs/plan.md"
check "ルートに data/ があれば終了コード 2" target_status_is 2
check "data/ があると示す" target_err_has "data/"

echo
if [ "$failures" -eq 0 ]; then
  echo "すべて ok"
else
  echo "NG が $failures 件"
  exit 1
fi
