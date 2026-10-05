#!/usr/bin/env bash
# 外部から写したプロンプト（prompts/）の出典とライセンスの表示を確かめるテスト
#
# 使い方： bash test-prompts.sh
# 確かめること（prompts/sources.json に載っているファイルごと）：
#   - ファイル・ライセンスの写し（licenseFile）・NOTICE の写し（noticeFile。あれば）がある
#   - .md の冒頭に注記（<!-- 〜 -->）があり、出典の URL がリポジトリ・コミット・元のパスと合っている
#   - 改変なし（modified が false）なら、注記に「改変: なし」とあり、本文の sha256 が bodySha256 と同じ
# あわせて、prompts/ の中のプロンプト・スキーマが、すべて sources.json に載っていることも確かめる（出典の無い写しを残さないため）
# 出力：  1 件ごとに ok / NG。NG が 1 件でもあれば exit 1
# 写した本文を書き換えたら、注記の「改変」を「あり（何を変えたか）」に、sources.json の modified を true に直す
# （Apache-2.0 は、変更したファイルに変更した旨の表示を求めるため）
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROMPTS="$SCRIPT_DIR/../prompts"
MANIFEST="$PROMPTS/sources.json"
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

# .md の注記の終わり（--> の行）の行番号を出す。注記が無ければ何も出さない
header_end() {
  awk 'NR == 1 && $0 != "<!--" { exit } $0 == "-->" { print NR; exit }' "$1"
}

# 本文（.md は注記とその次の空行を除いた部分、それ以外はファイル全体）の sha256 を出す
body_sha256() {
  local file="$1" end
  case "$file" in
    *.md)
      end="$(header_end "$file")"
      [ -n "$end" ] || return 1
      tail -n +"$((end + 2))" "$file" | sha256sum | cut -c1-64
      ;;
    *) sha256sum < "$file" | cut -c1-64 ;;
  esac
}

# 注記に指定の文字列があるか
header_has() {
  local file="$1" text="$2" end
  end="$(header_end "$file")"
  [ -n "$end" ] && head -n "$end" "$file" | grep -qF -- "$text"
}

# 注記の次の行が空行か（本文との区切り。本文の sha256 の取り方の前提）
blank_after_header() {
  local file="$1" end
  end="$(header_end "$file")"
  [ -n "$end" ] && [ -z "$(sed -n "$((end + 1))p" "$file")" ]
}

if ! jq empty "$MANIFEST"; then
  echo "NG  sources.json が JSON として読めません: $MANIFEST"
  exit 1
fi

while IFS= read -r entry; do
  path="$(jq -r '.path' <<< "$entry")"
  file="$PROMPTS/$path"
  repo="$(jq -r '.repo' <<< "$entry")"
  commit="$(jq -r '.commit' <<< "$entry")"
  upstream="$(jq -r '.upstreamPath' <<< "$entry")"
  license_file="$(jq -r '.licenseFile' <<< "$entry")"
  notice_file="$(jq -r '.noticeFile // empty' <<< "$entry")"
  modified="$(jq -r '.modified' <<< "$entry")"
  expected="$(jq -r '.bodySha256' <<< "$entry")"

  echo "--- $path ---"
  check "ファイルがある" test -f "$file"
  check "ライセンスの写しがある（$license_file）" test -f "$PROMPTS/$license_file"
  [ -z "$notice_file" ] || check "NOTICE の写しがある（$notice_file）" test -f "$PROMPTS/$notice_file"
  if [ "${path##*.}" = "md" ]; then
    check "冒頭に注記がある" test -n "$(header_end "$file")"
    check "注記の出典がリポジトリ・コミット・元のパスと合う" header_has "$file" "出典: https://github.com/$repo/blob/$commit/$upstream"
    check "注記の次の行が空行" blank_after_header "$file"
    [ "$modified" != "false" ] || check "注記に「改変: なし」とある" header_has "$file" "改変: なし"
  fi
  if [ "$modified" = "false" ]; then
    check "本文が元と同じ（sha256）" test "$(body_sha256 "$file")" = "$expected"
  fi
done < <(jq -c '.files[]' "$MANIFEST")

echo "--- sources.json に載っていない写し ---"
listed="$(jq -r '.files[].path' "$MANIFEST")"
unlisted=""
while IFS= read -r f; do
  rel="${f#"$PROMPTS"/}"
  grep -qxF -- "$rel" <<< "$listed" || unlisted="$unlisted $rel"
done < <(find "$PROMPTS" -type f \( -name '*.md' -o -name '*.json' \) ! -name 'README.md' ! -name 'sources.json' | sort)
check "prompts/ のプロンプト・スキーマはすべて sources.json に載っている${unlisted:+（載っていない:$unlisted）}" test -z "$unlisted"

echo
if [ "$failures" -eq 0 ]; then
  echo "すべて ok"
else
  echo "NG が $failures 件"
  exit 1
fi
