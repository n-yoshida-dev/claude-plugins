#!/usr/bin/env bash
# レビューする文書が、Codex（OpenAI）に送ってよいものかを確かめる
#
# 使い方： bash codex-review-target.sh <文書のパス>
# 呼び元： codex-review スキル（Codex を呼ぶ前に必ず通す）
# 出力：  送ってよければ、標準出力に「文書の絶対パス<TAB>リポジトリのルート」を 1 行。exit 0
#         送ってはいけなければ、理由を標準エラーに出して exit 2
#
# 止めるもの：
#   - ファイルが無い・読めない・空
#   - 文書でない（拡張子が .md / .txt 以外）。コードの差分は GitHub の Codex クラウドレビューの担当（pr-flow 5 節）
#   - Git のリポジトリの外（Codex の作業フォルダと、読み取りの範囲を決められないため）
#   - 送ってはいけない場所（環境変数 CODEX_DENY_ROOTS に : 区切りで並べる。既定は ~/workspace/ops）の中と、
#     リポジトリのルートに data/ があるもの（Codex の中の操作には Claude 側のフックが効かないため。
#     ops の docs/2026-10-04-マルチモデル協調の採用判断.md §7）
#   - PRIVATE.md・*.local.*・.env*（生活の事実や秘密の置き場。apps の CLAUDE.md「個人情報の取り扱い」）
#   - Git の管理から外したファイル（gitignore の対象。コミットしない＝外に出さない前提のファイルのため）
# シンボリックリンクは行き先で判定する（リンクを通して止める場所の中を送らないため）
set -uo pipefail

# 送ってはいけない理由を標準エラーに出して終了する
deny() {
  echo "codex-review-target.sh: Codex に送りません: $1" >&2
  exit 2
}

[ $# -eq 1 ] || { echo "使い方: bash codex-review-target.sh <文書のパス>" >&2; exit 2; }
[ -e "$1" ] || deny "ファイルがありません: $1"
doc="$(realpath -e -- "$1")" || deny "パスを解決できません: $1"
[ -f "$doc" ] && [ -r "$doc" ] || deny "読めるファイルではありません: $doc"
[ -s "$doc" ] || deny "空のファイルです: $doc"

name="$(basename -- "$doc")"
case "$name" in
  *.md|*.txt) ;;
  *) deny "文書（.md / .txt）ではありません: $name。コードの差分は GitHub の Codex クラウドレビューの担当です" ;;
esac
case "$name" in
  PRIVATE.md|*.local.*|.env*) deny "非公開の置き場のファイルです: $name" ;;
esac

root="$(git -C "$(dirname -- "$doc")" rev-parse --show-toplevel 2>/dev/null)" || deny "Git のリポジトリの外です: $doc"
root="$(realpath -e -- "$root")" || deny "リポジトリのルートを解決できません: $root"

IFS=':' read -r -a deny_roots <<< "${CODEX_DENY_ROOTS:-$HOME/workspace/ops}"
for d in "${deny_roots[@]}"; do
  [ -n "$d" ] || continue
  d="$(realpath -m -- "$d")"
  case "$doc/" in
    "$d"/*) deny "送らない場所（$d）の中です: $doc" ;;
  esac
done
[ ! -e "$root/data" ] || deny "リポジトリのルートに data/ があります: $root"

if git -C "$root" check-ignore -q -- "$doc"; then
  deny "Git の管理から外したファイル（gitignore の対象）です: $doc"
fi

printf '%s\t%s\n' "$doc" "$root"
