#!/usr/bin/env bash
# Codex に読ませる作業フォルダを、Git で管理しているファイルだけで作る
#
# 使い方： bash codex-review-export.sh <文書のパス> <リポジトリのルート> <書き出し先（無いか、空のフォルダ）>
# 呼び元： codex-review スキル（codex-review-target.sh を通したあと。Codex の -C にはリポジトリでなく、ここで作ったフォルダを渡す）
# 作るもの：
#   - 書き出し先に、リポジトリの HEAD の中身を展開する（git archive。gitignore の対象やコミットしていないファイルは入らない）
#   - レビューする文書だけは、今の中身で上書きする（未コミットの変更を含めてレビューするため）
#   - PRIVATE.md・*.local.*・.env* という名前のファイルは、Git で管理していても書き出しから外す（見本の .env.example なども外れる）
# 出力：  標準出力に書き出し先の絶対パスを 1 行。外したファイルがあれば、標準エラーに 1 行ずつ
# 終了コード：0 成功 / 1 書き出しの失敗 / 2 指定の誤り（書き出し先が空でない・文書がリポジトリの外・コミットが無いなど）
#
# なぜ：Codex は読み取り専用でも、作業フォルダのファイルを読みに行ける。借りてきた plan-review.md は「計画が触れるファイルを道具で確かめよ」と指示する。
#   リポジトリそのものを作業フォルダにすると、gitignore の PRIVATE.md などの実データが OpenAI に渡りうる（2026-10-05、PR #26 の受け入れレビュー）
# 残る穴：Codex の読み取り専用が、作業フォルダの外を絶対パスで読めるかは確かめていない（判断文書 §9）。
#   文書が非公開の場所を絶対パスで書いていれば、そこが読まれうる
set -uo pipefail

# 指定の誤りを標準エラーに出して終了する
usage_error() {
  echo "codex-review-export.sh: $1" >&2
  exit 2
}

[ $# -eq 3 ] || usage_error "使い方: bash codex-review-export.sh <文書のパス> <リポジトリのルート> <書き出し先>"
doc="$(realpath -e -- "$1")" || usage_error "文書のパスを解決できません: $1"
root="$(realpath -e -- "$2")" || usage_error "リポジトリのルートを解決できません: $2"
out="$(realpath -m -- "$3")"
case "$doc" in
  "$root"/*) ;;
  *) usage_error "文書がリポジトリの外です: $doc" ;;
esac
if [ -e "$out" ] && [ -n "$(ls -A -- "$out" 2>/dev/null)" ]; then
  usage_error "書き出し先が空ではありません: $out"
fi
git -C "$root" rev-parse --verify -q HEAD > /dev/null || usage_error "リポジトリにコミットがありません: $root"

mkdir -p -- "$out" || { echo "codex-review-export.sh: 書き出し先を作れません: $out" >&2; exit 1; }
if ! git -C "$root" archive --format=tar HEAD | tar -x -C "$out"; then
  echo "codex-review-export.sh: リポジトリの中身を書き出せませんでした: $root" >&2
  exit 1
fi

# レビューする文書は今の中身にする
rel="${doc#"$root"/}"
if ! mkdir -p -- "$out/$(dirname -- "$rel")" || ! cp -- "$doc" "$out/$rel"; then
  echo "codex-review-export.sh: 文書を書き出せません: $rel" >&2
  exit 1
fi

# 非公開の置き場の名前のファイルを外す
while IFS= read -r -d '' f; do
  rm -f -- "$f" || { echo "codex-review-export.sh: 外せません: $f" >&2; exit 1; }
  echo "codex-review-export.sh: 書き出しから外した: ${f#"$out"/}" >&2
done < <(find "$out" -type f \( -name 'PRIVATE.md' -o -name '*.local.*' -o -name '.env*' \) -print0)

printf '%s\n' "$out"
