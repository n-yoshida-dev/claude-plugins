#!/usr/bin/env bash
# 起動時の知らせ（hooks/session-briefing.sh）の回帰テスト
#
# 使い方： bash test-session-briefing.sh
# 見本の TODO.md を一時フォルダに作ってフックを動かす。
# 進捗表と未完タスクの一覧は公開版の todo-progress に移したので（v2.0.0）、ここでは apps-workflow に残した知らせだけを確かめる：
#   公開の節が無いときだけ知らせの 1 行を出すか（並べ替えは指示しない。「公開後」だけの節は公開の節と見なさない）、
#   HANDOFF.md を読む 1 行を出すか、logs/decisions.md があるときだけ台帳の 1 行を出すか、
#   進捗表を出さないか（todo-progress と二重に出さない）、TODO.md が無ければ何も出さないか、フックの入力の cwd を優先するか
# 出力：  1 件ごとに ok / NG。NG が 1 件でもあれば exit 1
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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
# フックを動かす。引数はプロジェクトのフォルダ。フックの入力は空の JSON にする（cwd を渡さない）
brief() { echo '{}' | CLAUDE_PROJECT_DIR="$1" bash "$BRIEFING"; }

# 公開の節がある TODO（判断台帳あり）
mkdir -p "$WORK/release/logs"
cat > "$WORK/release/TODO.md" <<'EOF'
# TODO

## フェーズ1：設計

- [x] PLAN.md を書く
- [ ] SPEC.md を書く

## フェーズ2：公開

- [ ] Pages に出す

## 公開後の改善

- [ ] あとで足す
EOF
touch "$WORK/release/logs/decisions.md"
OUT="$(brief "$WORK/release")"
check "公開の節があれば、無いという知らせを出さない" lacks "$OUT" "「公開」を含む見出しが無い"
check "HANDOFF.md を読む 1 行を出す" has "$OUT" "現在地と次の一手は HANDOFF.md にある"
check "判断台帳があれば、設計の前に読む 1 行を出す" has "$OUT" "logs/decisions.md にある"
check "進捗表を出さない（todo-progress と二重に出さない）" lacks "$OUT" "合計"
check "未完タスクの一覧を出さない（todo-progress と二重に出さない）" lacks "$OUT" "SPEC.md を書く"

# 公開の節が無い TODO（判断台帳なし）
mkdir -p "$WORK/norelease"
cat > "$WORK/norelease/TODO.md" <<'EOF'
# TODO

## フェーズ1：作る

- [ ] 作る
EOF
OUT="$(brief "$WORK/norelease")"
check "公開の節が無ければ、そのことを知らせる" has "$OUT" "「公開」を含む見出しが無いので"
check "公開の節が無くても、並べ替えを指示しない" lacks "$OUT" "並びに直す"
check "判断台帳が無ければ、台帳の 1 行を出さない" lacks "$OUT" "logs/decisions.md"

# 公開後の節だけがあり、公開の節が無い。公開後は公開の節と見なさない
mkdir -p "$WORK/afteronly"
cat > "$WORK/afteronly/TODO.md" <<'EOF'
# TODO

## フェーズ1：作る

- [ ] 作る

## 公開後の改善

- [ ] あとで
EOF
check "公開後の節だけなら、公開の節が無いと知らせる" has "$(brief "$WORK/afteronly")" "「公開」を含む見出しが無いので"

# TODO.md が無いフォルダでは何も出さない
mkdir -p "$WORK/empty"
check "TODO.md が無ければ何も出さない" test -z "$(brief "$WORK/empty")"

# フックの入力の cwd に TODO.md があれば、CLAUDE_PROJECT_DIR より優先する（worktree のセッション）
OUT="$(printf '{"cwd":"%s"}' "$WORK/norelease" | CLAUDE_PROJECT_DIR="$WORK/release" bash "$BRIEFING")"
check "フックの入力の cwd を CLAUDE_PROJECT_DIR より優先する" has "$OUT" "「公開」を含む見出しが無いので"

if [ "$failures" -gt 0 ]; then
  echo "NG が ${failures} 件"
  exit 1
fi
echo "すべて ok"
