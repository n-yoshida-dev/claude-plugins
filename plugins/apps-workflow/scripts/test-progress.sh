#!/usr/bin/env bash
# 進捗表（hooks/progress.sh）と起動時の知らせ（hooks/session-briefing.sh）の回帰テスト
#
# 使い方： bash test-progress.sh
# 見本の TODO.md を一時フォルダに作って 2 本を動かす。Git の履歴は作らないので「前回の区切りから」の行は出ない
# 確かめること：「公開まで残り」が公開の節とその上の節の未完を数えるか（公開の節の後ろと「公開後」は数えない）、
#               「公開後」「保留」「確認待ち」の節が合計から外れるか、公開の節が無ければ「公開まで残り」を出さないか、
#               起動時の一覧が公開の節の未完を先に出すか、公開の節が無いときに並べ替えを促す 1 行を出すか
# 出力：  1 件ごとに ok / NG。NG が 1 件でもあれば exit 1
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROGRESS="$SCRIPT_DIR/../hooks/progress.sh"
BRIEFING="$SCRIPT_DIR/../hooks/session-briefing.sh"
failures=0
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

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

# 出力に指定の文字列があるか
has() { grep -qF -- "$2" <<< "$1"; }
# 出力に指定の文字列が無いか
lacks() { ! grep -qF -- "$2" <<< "$1"; }

# 雛形の並び（設計 → 最初の画面 → 公開 → 公開後 → 確認待ち）。公開の後ろに、公開後でない節も 1 つ置く
mkdir -p "$WORK/ordered"
cat > "$WORK/ordered/TODO.md" <<'EOF'
# TODO

## フェーズ1：設計

- [x] PLAN.md を書く
- [ ] SPEC.md を書く
  - [ ] 子項目も数える

## フェーズ2：最初の画面を 1 つ通す

- [ ] 画面の骨組み

## フェーズ3：公開

- [ ] Pages に出す
- [x] README を書く

## フェーズ4：公開のあとに足す機能

- [ ] 公開の節の後ろなので「公開まで」には数えない

## 公開後の改善

- [ ] 色を直す
- [x] 余白を直す

## 小さな候補（保留）

- [ ] いつか

## 確認待ち

- [ ] 名前を決める
EOF

OUT=$(bash "$PROGRESS" "$WORK/ordered")
check "公開まで残り：公開の節とその上の未完（子項目を含む 4 件）を数える" has "$OUT" "公開まで残り 4 件（TODO の上から「フェーズ3：公開」の節までの未完）"
check "合計：公開後・保留・確認待ちを外し、公開の後ろの節は入れる（未完 5 / 7）" has "$OUT" "残り  5 /  7  合計"
check "公開後の節を別枠で出す" has "$OUT" "公開後（合計に含めない）：1 件（済み 1 件）"
check "公開後の節をフェーズの行に出さない" lacks "$OUT" "公開後の改善"
check "保留の別枠はこれまでどおり" has "$OUT" "保留（合計に含めない）：1 件（済み 0 件）"
check "確認待ちの別枠はこれまでどおり" has "$OUT" "あなたの回答待ち：1 件（回答済み 0 件）"

BRIEF=$(CLAUDE_PROJECT_DIR="$WORK/ordered" bash "$BRIEFING")
FIRST=$(grep -m 1 '(TODO.md:' <<< "$BRIEF")
check "起動時の一覧：公開の節の未完を先頭に出す" has "$FIRST" "Pages に出す"
check "起動時の一覧：見出しで公開の節を先に出すと書く" has "$BRIEF" "公開の節を先に、ほかは上から 12 件"
check "起動時の一覧：公開の節があれば並べ替えを促さない" lacks "$BRIEF" "「公開」を含む見出しが無い"
check "起動時の一覧：子項目は一覧に出さない" lacks "$BRIEF" "子項目も数える"

# 公開の節が末尾にある古い並び。公開の節の未完は先に出し、「公開まで」は全部を数える
mkdir -p "$WORK/old"
cat > "$WORK/old/TODO.md" <<'EOF'
## フェーズ1：実装

- [ ] 機能 A
- [ ] 機能 B

## フェーズ2：公開・記事化

- [ ] 公開する
EOF
OUT=$(bash "$PROGRESS" "$WORK/old")
check "古い並び：公開まで残りは上の節を含めて数える" has "$OUT" "公開まで残り 3 件（TODO の上から「フェーズ2：公開・記事化」の節までの未完）"
BRIEF=$(CLAUDE_PROJECT_DIR="$WORK/old" bash "$BRIEFING")
FIRST=$(grep -m 1 '(TODO.md:' <<< "$BRIEF")
check "古い並び：末尾の公開の節の未完を先頭に出す" has "$FIRST" "(TODO.md:8) 公開する"

# 公開の節が無い TODO。公開まで残りは出さず、起動時に並べ替えを促す
mkdir -p "$WORK/none"
cat > "$WORK/none/TODO.md" <<'EOF'
## フェーズ1：実装

- [x] 機能 A
- [ ] 機能 B
EOF
OUT=$(bash "$PROGRESS" "$WORK/none")
check "公開の節が無ければ公開まで残りを出さない" lacks "$OUT" "公開まで残り"
check "公開の節が無くても表はこれまでどおり（未完 1 / 2）" has "$OUT" "残り  1 /  2  合計"
BRIEF=$(CLAUDE_PROJECT_DIR="$WORK/none" bash "$BRIEFING")
check "公開の節が無ければ並べ替えを促す" has "$BRIEF" "「公開」を含む見出しが無い"
check "公開の節が無ければ一覧の見出しはこれまでどおり" has "$BRIEF" "1 件。先頭12件："

# 公開後の節だけがあり、公開の節が無い。公開後は公開の節と見なさない
mkdir -p "$WORK/after-only"
cat > "$WORK/after-only/TODO.md" <<'EOF'
## フェーズ1：実装

- [ ] 機能 A

## 公開後の改善

- [ ] 色を直す
EOF
OUT=$(bash "$PROGRESS" "$WORK/after-only")
check "公開後の節は公開の節と見なさない" lacks "$OUT" "公開まで残り"
BRIEF=$(CLAUDE_PROJECT_DIR="$WORK/after-only" bash "$BRIEFING")
check "公開後の節だけなら並べ替えを促す" has "$BRIEF" "「公開」を含む見出しが無い"

# TODO.md が無いフォルダでは、どちらも何も出さない
mkdir -p "$WORK/empty"
check "TODO.md が無ければ進捗表は何も出さない" test -z "$(bash "$PROGRESS" "$WORK/empty")"
check "TODO.md が無ければ起動時の知らせも何も出さない" test -z "$(CLAUDE_PROJECT_DIR="$WORK/empty" bash "$BRIEFING")"

if [ "$failures" -gt 0 ]; then
  echo "NG が $failures 件"
  exit 1
fi
echo "すべて ok"
