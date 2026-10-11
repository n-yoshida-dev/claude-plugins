#!/usr/bin/env bash
# 編集後のフック（hooks/check-edited.sh）の回帰テスト
#
# 使い方： bash test-check-edited.sh
# 本物の npm・npx は呼ばない。呼ばれた引数を記録するだけの偽の npm・npx を PATH の先頭に置く
# 確かめること：lint スクリプトの中身に合わせて oxlint か eslint を呼び分けるか（oxlint のアプリで eslint を呼んで毎回失敗していたため）、
#               失敗したときだけ知らせるか、対象の外のファイルで何もしないか
# 出力：  1 件ごとに ok / NG。NG が 1 件でもあれば exit 1
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/../hooks/check-edited.sh"
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

# 偽の npm・npx：引数を記録し、FAKE_FAIL に書いた語が引数にあれば失敗する
mkdir -p "$WORK/bin"
for cmd in npm npx; do
  cat > "$WORK/bin/$cmd" <<'EOF'
#!/usr/bin/env bash
echo "$(basename "$0") $*" >> "$FAKE_LOG"
for word in ${FAKE_FAIL:-}; do
  case " $* " in *" $word "*) printf '\033[91m偽の %s のエラー\033[0m\n' "$word"; exit 1 ;; esac
done
exit 0
EOF
  chmod +x "$WORK/bin/$cmd"
done

# アプリの形を作る。$1 は package.json の scripts（JSON）
make_app() {
  local dir="$WORK/app-$RANDOM"
  mkdir -p "$dir/frontend/src"
  jq -n --argjson s "$1" '{scripts: $s}' > "$dir/frontend/package.json"
  echo "$dir"
}

# フックを動かす。出力（知らせの JSON か空）を返し、偽のコマンドの記録を $WORK/log に残す
run_hook() {
  local project="$1" file="$2" fail="${3:-}"
  : > "$WORK/log"
  jq -n --arg f "$file" '{tool_input: {file_path: $f}}' |
    PATH="$WORK/bin:$PATH" FAKE_LOG="$WORK/log" FAKE_FAIL="$fail" CLAUDE_PROJECT_DIR="$project" bash "$HOOK"
}

# 記録に指定の呼び出しがあるか
called() {
  grep -qF -- "$1" "$WORK/log"
}

# 記録に指定の呼び出しが無いか
not_called() {
  ! grep -qF -- "$1" "$WORK/log"
}

# 知らせの文に指定の文字列があるか（直前の run_hook の出力を $WORK/out から読む）
out_has() {
  jq -r '.hookSpecificOutput.additionalContext' "$WORK/out" | grep -qF -- "$1"
}

# 知らせが出ていないか
out_empty() {
  [ ! -s "$WORK/out" ]
}

OX=$(make_app '{"lint":"oxlint","typecheck":"tsc -b --noEmit"}')
run_hook "$OX" "$OX/frontend/src/App.tsx" > "$WORK/out"
check "oxlint のアプリでは oxlint を呼ぶ" called "npx --no-install oxlint $OX/frontend/src/App.tsx"
check "oxlint のアプリでは eslint を呼ばない" not_called "eslint"
check "typecheck スクリプトを呼ぶ" called "npm run --silent typecheck"
check "どれも通れば知らせない" out_empty

ES=$(make_app '{"lint":"eslint .","typecheck":"tsc -b --noEmit"}')
run_hook "$ES" "$ES/frontend/src/main.ts" > "$WORK/out"
check "eslint のアプリでは eslint を 1 ファイルに呼ぶ" called "npx --no-install eslint $ES/frontend/src/main.ts"
check "eslint のアプリでは oxlint を呼ばない" not_called "oxlint"

TSE=$(make_app '{"lint":"node check-typescript-eslint-rules.mjs","typecheck":"tsc"}')
run_hook "$TSE" "$TSE/frontend/src/a.ts" > "$WORK/out"
check "名前の一部に eslint を含むだけなら呼ばない" not_called "eslint"

BOTH=$(make_app '{"lint":"oxlint && eslint src","typecheck":"tsc"}')
run_hook "$BOTH" "$BOTH/frontend/src/a.ts" > "$WORK/out"
check "両方書いてあれば oxlint を呼ぶ" called "npx --no-install oxlint"
check "両方書いてあれば eslint も呼ぶ" called "npx --no-install eslint"

OTHER=$(make_app '{"lint":"biome lint","typecheck":"tsc"}')
run_hook "$OTHER" "$OTHER/frontend/src/a.ts" > "$WORK/out"
check "oxlint・eslint 以外の lint なら lint を呼ばない" bash -c "! grep -q 'oxlint\|eslint' '$WORK/log'"
check "oxlint・eslint 以外の lint なら知らせない" out_empty

NOLINT=$(make_app '{}')
run_hook "$NOLINT" "$NOLINT/frontend/src/a.ts" > "$WORK/out"
check "lint スクリプトが無ければ lint を呼ばない" bash -c "! grep -q 'oxlint\|eslint' '$WORK/log'"
check "typecheck スクリプトが無ければ tsc を直接呼ぶ" called "npx --no-install tsc --noEmit"

run_hook "$OX" "$OX/frontend/src/App.tsx" "oxlint" > "$WORK/out"
check "oxlint が失敗したら知らせる" out_has "[oxlint 失敗]"
check "知らせに lint の出力を入れる" out_has "偽の oxlint のエラー"
check "frontend/ のアプリでも知らせから色付けの制御文字を外す" bash -c "! jq -r '.hookSpecificOutput.additionalContext' '$WORK/out' | grep -q \$'\\x1b'"

run_hook "$OX" "$OX/frontend/src/App.tsx" "typecheck" > "$WORK/out"
check "typecheck が失敗したら知らせる" out_has "[typecheck 失敗]"

run_hook "$OX" "$OX/frontend/src/index.css" > "$WORK/out"
check "CSS では何も呼ばない" bash -c "[ ! -s '$WORK/log' ]"

run_hook "$OX" "$WORK/elsewhere/a.ts" > "$WORK/out"
check "frontend の外の .ts では何も呼ばない" bash -c "[ ! -s '$WORK/log' ]"

BARE="$WORK/bare"
mkdir -p "$BARE/frontend/src"
run_hook "$BARE" "$BARE/frontend/src/a.ts" > "$WORK/out"
check "package.json が無ければ何も呼ばない" bash -c "[ ! -s '$WORK/log' ]"
jq -n '{scripts: {typecheck: "tsc", lint: "oxlint"}}' > "$BARE/package.json"
run_hook "$BARE" "$BARE/src/a.ts" > "$WORK/out"
check "frontend/ があれば、直下に package.json（typecheck・lint 付き）があっても直下は見ない" bash -c "[ ! -s '$WORK/log' ]"

# サイトがリポジトリ直下にあるアプリ（portfolio の形：frontend/ が無く、直下に package.json）
make_root_site() {
  local dir="$WORK/site-$RANDOM"
  mkdir -p "$dir/src/pages"
  jq -n --argjson s "$1" '{scripts: $s}' > "$dir/package.json"
  echo "$dir"
}
SITE=$(make_root_site '{"typecheck":"astro check","lint":"node scripts/check-public-profile.mjs"}')
run_hook "$SITE" "$SITE/src/pages/index.astro" > "$WORK/out"
check "直下のサイトで .astro を変えたら typecheck を呼ぶ" called "npm run --silent typecheck"
check "直下のサイトで lint が oxlint・eslint でなければ lint を呼ばない" bash -c "! grep -q 'oxlint\|eslint' '$WORK/log'"
check "直下のサイトで通れば知らせない" out_empty
run_hook "$SITE" "$SITE/src/lib/a.ts" "typecheck" > "$WORK/out"
check "直下のサイトで .ts の typecheck が失敗したら知らせる" out_has "[typecheck 失敗]"
check "知らせから色付けの制御文字を外す" bash -c "! jq -r '.hookSpecificOutput.additionalContext' '$WORK/out' | grep -q \$'\\x1b'"
run_hook "$SITE" "$SITE/.astro/types.d.ts" > "$WORK/out"
check "直下のサイトでも Astro が作る型（.astro/）は見ない" bash -c "[ ! -s '$WORK/log' ]"
run_hook "$SITE" "$SITE/node_modules/x/index.d.ts" > "$WORK/out"
check "直下のサイトでも依存（node_modules）は見ない" bash -c "[ ! -s '$WORK/log' ]"
run_hook "$SITE" "$SITE/dist/_astro/a.ts" > "$WORK/out"
check "直下のサイトでもビルドの成果物（dist）は見ない" bash -c "[ ! -s '$WORK/log' ]"
TOOLS=$(make_root_site '{"format":"prettier --write ."}')
run_hook "$TOOLS" "$TOOLS/src/a.ts" > "$WORK/out"
check "直下の package.json に typecheck が無ければ tsc を呼ばない" bash -c "[ ! -s '$WORK/log' ]"

echo
if [ "$failures" -gt 0 ]; then
  echo "NG が $failures 件"
  exit 1
fi
echo "すべて ok"
