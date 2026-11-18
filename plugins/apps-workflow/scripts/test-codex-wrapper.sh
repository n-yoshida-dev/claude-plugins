#!/usr/bin/env bash
# codex-bin.sh・codex-models.sh・codex-run.sh の回帰テスト
#
# 使い方： bash test-codex-wrapper.sh
# 本物の codex は呼ばない。受け取った引数と標準入力を記録するだけの偽の codex を CODEX_BIN で差し込むので、
# ChatGPT の利用枠を使わない。CI（.github/workflows/ci.yml）でも回す
# 本物のモデルの表と ~/.codex も読まない。CODEX_MODELS_FILE と CODEX_HOME をテスト用に差し替える
# （本物の表の中身を比べた結果で変えても、テストが壊れないようにするため。本物の表は形だけを確かめる）
# 出力：  1 件ごとに ok / NG。NG が 1 件でもあれば exit 1
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_SH="$SCRIPT_DIR/codex-bin.sh"
MODELS_SH="$SCRIPT_DIR/codex-models.sh"
RUN_SH="$SCRIPT_DIR/codex-run.sh"
REAL_TABLE="$SCRIPT_DIR/../config/codex-models.json"

T="$(mktemp -d "${TMPDIR:-/tmp}/test-codex-wrapper.XXXXXX")" || { echo "一時フォルダを作れません" >&2; exit 1; }
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

# Windows の Git Bash（uname -s が MINGW*・MSYS*）か。codex-run.sh と同じ見分け方
is_win() {
  case "$(uname -s)" in
    MINGW*|MSYS*) return 0 ;;
    *) return 1 ;;
  esac
}
# codex-run.sh が Codex に渡す読ませない場所の形。Windows では C:/…（cygpath -m -l）、Linux では渡した場所そのまま
wf() {
  if is_win; then
    cygpath -m -l -- "$1"
  else
    printf '%s' "$1"
  fi
}

# 偽の codex を作る。引数を 1 行 1 つで args に、標準入力を stdin に、作業フォルダを cwd に残し、本物に似た出来事（JSONL）を出す
FAKE="$T/fake"
mkdir -p "$FAKE"
cat > "$FAKE/codex" <<'EOS'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$FAKE_DIR/args"
cat > "$FAKE_DIR/stdin"
pwd > "$FAKE_DIR/cwd"
out=""; prev=""
for a in "$@"; do
  if [ "$prev" = "-o" ]; then out="$a"; fi
  prev="$a"
done
# JSON でない行が混ざっても、ラッパーが thread_id と使用量を拾えることを確かめるための 1 行
echo 'JSON でない行'
echo '{"type":"thread.started","thread_id":"fake-thread-1"}'
if [ -n "${FAKE_EMPTY:-}" ]; then
  # 成功したのに返答が空の場合を真似る
  : > "$out"
  exit 0
fi
if [ "${FAKE_EXIT:-0}" -ne 0 ]; then
  # 失敗しても途中の返答を書く場合を真似る（ラッパーがそれを -o に置かないことを確かめるため）
  printf '途中の返答\n' > "$out"
  echo '{"type":"turn.failed","error":{"message":"偽の失敗"}}'
  exit "$FAKE_EXIT"
fi
# 使用量の項目は codex-cli 0.160.0 の実機（2026-10-05）と同じ
echo '{"type":"turn.completed","usage":{"input_tokens":10,"cached_input_tokens":2,"cache_write_input_tokens":0,"output_tokens":5,"reasoning_output_tokens":1}}'
printf '偽の返答\n' > "$out"
EOS
chmod +x "$FAKE/codex"
export FAKE_DIR="$FAKE"

# テスト用のモデルの表。用途 review と screen で、モデルと考える深さを変えておく
cat > "$T/models.json" <<'EOS'
{
  "checkedAt": "2026-01-01",
  "knownModels": ["fake-astra", "fake-sol"],
  "uses": {
    "review": { "model": "fake-astra", "effort": "high", "status": "未比較", "why": "テスト" },
    "screen": { "model": "fake-sol", "effort": "medium", "status": "比較済み", "why": "テスト" }
  }
}
EOS
export CODEX_MODELS_FILE="$T/models.json"

# 偽の Codex のモデル一覧を、名前の付いたフォルダに作る（CODEX_HOME をそこに向けて使う）
make_cache() {
  mkdir -p "$T/$1"
  printf '%s\n' "$2" > "$T/$1/models_cache.json"
}
# 既定：表のモデルがそろっていて、知らせることが無い一覧（隠されたモデルは表に無くても数えない）
make_cache codex-home '{"models":[{"slug":"fake-astra","visibility":"list","upgrade":null},{"slug":"fake-sol","visibility":"list","upgrade":null},{"slug":"fake-hidden","visibility":"hide","upgrade":null}]}'
# 新しいモデルが出た一覧
make_cache codex-new '{"models":[{"slug":"fake-astra","visibility":"list","upgrade":null},{"slug":"fake-sol","visibility":"list","upgrade":null},{"slug":"fake-new","visibility":"list","upgrade":null},{"slug":"fake-hidden2","visibility":"hide","upgrade":null}]}'
# 表のモデル fake-astra が消えた一覧
make_cache codex-gone '{"models":[{"slug":"fake-sol","visibility":"list","upgrade":null}]}'
# 表のモデル fake-astra に廃止の予定が付いた一覧
make_cache codex-upgrade '{"models":[{"slug":"fake-astra","visibility":"list","upgrade":{"model":"fake-sol","migration_markdown":"偽の廃止のお知らせ","retirement_at":"2026-12-31T00:00:00Z"}},{"slug":"fake-sol","visibility":"list","upgrade":null}]}'
# JSON として壊れた一覧
make_cache codex-broken '{ 壊れている'
# JSON としては読めるが、形が変わった一覧（models の欄が無い）
make_cache codex-schema '{"items":[{"slug":"fake-astra","visibility":"list"}]}'
# models はあるが、slug の無いモデルが混ざった一覧
make_cache codex-noslug '{"models":[{"id":"fake-astra","visibility":"list"},{"slug":"fake-sol","visibility":"list","upgrade":null}]}'
# 一覧が無いフォルダ
mkdir -p "$T/codex-none"
export CODEX_HOME="$T/codex-home"

# 偽の codex が受け取った引数に、指定の並び（連続した行）があるか
has_seq() {
  local -a got want=("$@")
  mapfile -t got < "$FAKE/args"
  local n=$# i j
  for ((i = 0; i + n <= ${#got[@]}; i++)); do
    for ((j = 0; j < n; j++)); do
      [ "${got[i + j]}" = "${want[j]}" ] || continue 2
    done
    return 0
  done
  return 1
}

# 偽の codex が受け取った引数に、指定の語が無いか
lacks() {
  ! grep -qxF -- "$1" "$FAKE/args"
}

# 偽の codex が受け取った引数のどこにも、指定の文字列が無いか（行の一部でも見る）
args_lack() {
  ! grep -qF -- "$1" "$FAKE/args"
}

# 偽の codex が呼ばれていないか（前回の記録を消してから実行する前提）
not_called() {
  [ ! -e "$FAKE/args" ]
}

# 偽の codex を差し込んで codex-run.sh を動かす。標準出力・標準エラー・終了コードを残す
run() {
  rm -f "$FAKE/args" "$FAKE/stdin" "$FAKE/cwd"
  CODEX_BIN="$FAKE/codex" TMPDIR="$T/tmp" bash "$RUN_SH" "$@" > "$T/stdout" 2> "$T/stderr"
  echo $? > "$T/status"
}

# 直前の run の終了コードが指定の値か
status_is() { [ "$(cat "$T/status")" = "$1" ]; }
# 直前の run の標準出力に、指定の文字列があるか
stdout_has() { grep -qF -- "$1" "$T/stdout"; }
# 直前の run の標準出力に、指定の文字列が無いか
stdout_lacks() { ! grep -qF -- "$1" "$T/stdout"; }
# 直前の run の標準エラーに、指定の文字列があるか
stderr_has() { grep -qF -- "$1" "$T/stderr"; }
# 直前の run の標準エラーに、指定の文字列が無いか
stderr_lacks() { ! grep -qF -- "$1" "$T/stderr"; }

# codex-bin.sh がエラーで終わるか（CODEX_BIN の指定あり／HOME を差し替えて拡張機能を探す、の 2 通り）
# HOME を差し替えるときは、偽の powershell.exe（何も返さない）を PATH の先頭に置く。
# Windows では拡張機能が無いと Store 版の Codex を探しに行くので、本物の Codex アプリを見つけないようにするため
bin_fails_with() { ! CODEX_BIN="$1" bash "$BIN_SH" > /dev/null 2>&1; }
bin_fails_in_home() { ! env -u CODEX_BIN HOME="$1" PATH="$FAKE_PS:$PATH" FAKE_PS_OUT="$T/ps-none.txt" bash "$BIN_SH" > /dev/null 2>&1; }

# 拡張機能の無い HOME で、偽の powershell.exe に $1 のファイルの中身を返させて codex-bin.sh を呼ぶ（Store 版の探し方を確かめる）
bin_with_ps() { env -u CODEX_BIN HOME="$T/empty-home" PATH="$FAKE_PS:$PATH" FAKE_PS_OUT="$1" bash "$BIN_SH" 2> "$T/stderr"; }
bin_ps_fails() { ! bin_with_ps "$1" > /dev/null; }

# codex-models.sh resolve <用途> の終了コードが指定の値か
resolve_status_is() {
  bash "$MODELS_SH" resolve "$1" > /dev/null 2>&1
  [ "$?" -eq "$2" ]
}

# 本物のモデルの表の形が正しいか（確認日・用途ごとのモデル・考える深さ・状態・理由がそろい、モデルが knownModels にある）
real_table_ok() {
  jq -e '
    (.checkedAt | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$"))
    and ((.uses | length) > 0)
    and (.knownModels as $k
      | [.uses[]
          | (.model | type == "string" and test("^[A-Za-z0-9._-]+$"))
            and (.effort | type == "string" and test("^[a-z]+$"))
            and ((.status // "") != "")
            and ((.why // "") != "")
            and (.model as $m | $k | index($m) != null)]
      | all)
  ' "$REAL_TABLE" > /dev/null
}

mkdir -p "$T/tmp" "$T/work" "$T/empty-home"
printf 'テスト用の依頼文\n2 行目\n' > "$T/prompt.md"

# 偽の powershell.exe：FAKE_PS_OUT のファイルの中身を、本物と同じく CRLF で返すだけ（Get-AppxPackage は呼ばない）
FAKE_PS="$T/fake-ps"
mkdir -p "$FAKE_PS"
cat > "$FAKE_PS/powershell.exe" <<'EOS'
#!/usr/bin/env bash
if [ -f "${FAKE_PS_OUT:-}" ]; then sed 's/$/\r/' "$FAKE_PS_OUT"; fi
exit 0
EOS
chmod +x "$FAKE_PS/powershell.exe"
: > "$T/ps-none.txt"
printf '{"type":"object"}\n' > "$T/schema.json"

echo "--- codex-bin.sh ---"

# CODEX_BIN が実行できるファイルなら、それをそのまま返す
check "CODEX_BIN を優先する" \
  test "$(CODEX_BIN="$FAKE/codex" bash "$BIN_SH")" = "$FAKE/codex"

# CODEX_BIN が実行できないなら、ほかを探さずにエラー
touch "$T/not-exec"
check "実行できない CODEX_BIN はエラー" bin_fails_with "$T/not-exec"

# 相対パスの CODEX_BIN は、呼んだ場所を基準に絶対パスで返す
check "相対パスの CODEX_BIN を絶対パスにして返す" \
  test "$(cd "$T" && CODEX_BIN=fake/codex bash "$BIN_SH")" = "$T/fake/codex"

# Windows の書き方（C:\… と C:/…）の CODEX_BIN も絶対パスとして受け、/c/… の形で返す。
# cygpath がある所（Windows の Git Bash）でだけ流す（Linux には cygpath が無く、C:\… は絶対パスではないため）
if command -v cygpath >/dev/null 2>&1; then
  check "Windows の書き方（C:\\…）の CODEX_BIN を受ける" \
    test "$(CODEX_BIN="$(cygpath -w "$FAKE/codex")" bash "$BIN_SH")" = "$(cygpath -u "$FAKE/codex")"
  check "Windows の書き方（C:/…）の CODEX_BIN を受ける" \
    test "$(cd "$T" && CODEX_BIN="$(cygpath -m "$FAKE/codex")" bash "$BIN_SH")" = "$(cygpath -u "$FAKE/codex")"
  check "Windows の書き方でも実行できない CODEX_BIN はエラー" bin_fails_with "$(cygpath -w "$T/not-exec")"
fi

# 拡張機能の版が複数あれば、版の順で最新を選ぶ（文字の順では 26.930.9 が最後になるので、版の順と区別できる）
EXT="$T/home/.vscode-server/extensions"
for v in 26.930.9 26.930.41038 26.1000.1; do
  mkdir -p "$EXT/openai.chatgpt-$v-linux-x64/bin/linux-x86_64"
  cp "$FAKE/codex" "$EXT/openai.chatgpt-$v-linux-x64/bin/linux-x86_64/codex"
done
# 実行権の無い新しい版は選ばない
mkdir -p "$EXT/openai.chatgpt-27.1.1-linux-x64/bin/linux-x86_64"
touch "$EXT/openai.chatgpt-27.1.1-linux-x64/bin/linux-x86_64/codex"
check "拡張機能の中の最新版を版の順で選ぶ" \
  test "$(env -u CODEX_BIN HOME="$T/home" bash "$BIN_SH")" = "$EXT/openai.chatgpt-26.1000.1-linux-x64/bin/linux-x86_64/codex"

# 拡張機能が無ければエラー
check "codex が見つからなければエラー" bin_fails_in_home "$T/empty-home"

# Store 版の Codex アプリ（Windows の Git Bash だけ）。偽の powershell.exe が「版<タブ>場所」を返す
APPS="$T/apps"
for v in 26.930.9 26.1000.1 26.1111.2228.0; do
  mkdir -p "$APPS/OpenAI.Codex_${v}_x64__fake/app/resources"
  : > "$APPS/OpenAI.Codex_${v}_x64__fake/app/resources/codex.exe"
done
mkdir -p "$APPS/OpenAI.Codex_27.1.0_x64__fake"
if command -v cygpath >/dev/null 2>&1; then
  printf '26.1000.1\t%s\n' "$(cygpath -w "$APPS/OpenAI.Codex_26.1000.1_x64__fake")" > "$T/ps-one.txt"
  check "Store 版：Get-AppxPackage の場所の中の codex.exe を返す" \
    test "$(bin_with_ps "$T/ps-one.txt")" = "$APPS/OpenAI.Codex_26.1000.1_x64__fake/app/resources/codex.exe"
  check "Store 版：何も返らなければエラー" bin_ps_fails "$T/ps-none.txt"
  check "Store 版：エラーの文に CODEX_BIN で場所を渡すやり方を出す" stderr_has "CODEX_BIN に codex.exe の場所"
  # 文字の順では 26.930.9 が最後になるので、版の順と区別できる
  { printf '26.930.9\t%s\n' "$(cygpath -w "$APPS/OpenAI.Codex_26.930.9_x64__fake")"
    printf '26.1111.2228.0\t%s\n' "$(cygpath -w "$APPS/OpenAI.Codex_26.1111.2228.0_x64__fake")"
    printf '26.1000.1\t%s\n' "$(cygpath -w "$APPS/OpenAI.Codex_26.1000.1_x64__fake")"; } > "$T/ps-many.txt"
  check "Store 版：複数返れば版のいちばん新しい物" \
    test "$(bin_with_ps "$T/ps-many.txt")" = "$APPS/OpenAI.Codex_26.1111.2228.0_x64__fake/app/resources/codex.exe"
  printf '27.1.0\t%s\n' "$(cygpath -w "$APPS/OpenAI.Codex_27.1.0_x64__fake")" > "$T/ps-noexe.txt"
  check "Store 版：場所に codex.exe が無ければエラー" bin_ps_fails "$T/ps-noexe.txt"
else
  # Linux（WSL）では Store 版の探し方に入らない。偽の powershell.exe が場所を返しても使わない
  printf '26.1000.1\t%s\n' "$APPS/OpenAI.Codex_26.1000.1_x64__fake" > "$T/ps-one.txt"
  check "Linux では Store 版を探さない（偽の powershell.exe が場所を返してもエラー）" bin_ps_fails "$T/ps-one.txt"
fi

echo "--- codex-models.sh ---"

check "用途からモデルと考える深さを引く" test "$(bash "$MODELS_SH" resolve screen)" = "$(printf 'fake-sol\tmedium')"
check "表にある用途を並べる" test "$(bash "$MODELS_SH" uses)" = "review screen"
check "表に無い用途は終了コード 2" resolve_status_is nope 2
check "知らせることが無ければ何も出さない" test -z "$(bash "$MODELS_SH" check)"
check "本物の表の形が正しい（確認日・用途ごとのモデル・深さ・状態・理由、モデルが knownModels にある）" real_table_ok

echo "--- codex-run.sh：新しく頼む ---"

run --use review -s read-only -f "$T/prompt.md" -o "$T/out.md" -C "$T/work"
check "成功すると終了コード 0" status_is 0
check "exec で呼ぶ" has_seq exec
check "用途 review の表のモデルを明示する" has_seq -m fake-astra
check "用途 review の表の考える深さを明示する" has_seq -c 'model_reasoning_effort="high"'
check "使ったモデルの出どころを標準エラーに出す" stderr_has "（表の用途 review）"
check "サンドボックスを -s で明示する" has_seq -s read-only
# 作業フォルダは codex の -C では渡さず、作業フォルダへ移ってから呼ぶ（Windows の codex.exe に /c/… の形を渡さないため）
check "作業フォルダは -C で渡さない" lacks -C
check "呼ばれたときの今いるフォルダが作業フォルダと同じ" test "$(cat "$FAKE/cwd")" = "$T/work"
check "ユーザー設定を読まない" has_seq --ignore-user-config
check "ユーザーとプロジェクトの .rules を読まない" has_seq --ignore-rules
check "memories を切る" has_seq --disable memories
check "記録を残さない（--ephemeral）" has_seq --ephemeral
check "出来事を JSONL で受け取る" has_seq --json
check "依頼文は標準入力から（最後の引数が -）" test "$(tail -n 1 "$FAKE/args")" = "-"
check "依頼書の中身がそのまま標準入力に届く" cmp -s "$T/prompt.md" "$FAKE/stdin"
check "作業フォルダで codex が動く" test "$(cat "$FAKE/cwd")" = "$T/work"
check "返答を -o のファイルに置く" test "$(cat "$T/out.md")" = "偽の返答"
check "標準出力に結果のパス" stdout_has "結果: $T/out.md"
check "標準出力に thread_id" stdout_has "thread_id: fake-thread-1"
check "標準出力に使用量" stdout_has '使用量: {"input_tokens":10,"cached_input_tokens":2,"cache_write_input_tokens":0,"output_tokens":5,"reasoning_output_tokens":1}'
check "--ephemeral の回は「記録は残していない」と表示する" stdout_has "記録は残していない"
check "モデルの知らせが無ければ、標準出力に知らせの行を出さない" stdout_lacks "知らせ"
check "--schema が無ければ --output-schema を付けない" lacks --output-schema
check "一時フォルダを残さない" test -z "$(ls -A "$T/tmp")"

# 相対パスは呼んだ場所を基準にする（-C で移っても同じファイルを指す）
(cd "$T" && run --use review -s workspace-write -f prompt.md -o out-rel.md -C work)
check "相対パスの依頼書と結果を、呼んだ場所から解決する" test "$(cat "$T/out-rel.md")" = "偽の返答"
check "workspace-write を渡せる" has_seq -s workspace-write

# 相対パスの CODEX_BIN でも、-C で別のフォルダに移ってから codex を動かせる
(cd "$T" && CODEX_BIN=fake/codex TMPDIR="$T/tmp" bash "$RUN_SH" --use review -s read-only -f prompt.md -o out-relbin.md -C work > /dev/null 2>&1)
check "相対パスの CODEX_BIN で -C の先でも動く" test "$(cat "$T/out-relbin.md")" = "偽の返答"

run --use review -s read-only -f "$T/prompt.md" -o "$T/out.md" -C "$T/work" -e medium -m other-model --schema "$T/schema.json" --keep-session --skip-git-repo-check --events "$T/events.jsonl"
check "-e で表の考える深さを上書きできる" has_seq -c 'model_reasoning_effort="medium"'
check "-m で表のモデルを上書きできる" has_seq -m other-model
check "--schema を --output-schema で渡す" has_seq --output-schema "$T/schema.json"
check "--keep-session なら --ephemeral を付けない" lacks --ephemeral
check "--skip-git-repo-check を渡す" has_seq --skip-git-repo-check
check "--events のファイルに出来事を残す" grep -qF '"thread.started"' "$T/events.jsonl"

echo "--- codex-run.sh：用途とモデルの決め方 ---"

run --use screen -s read-only -f "$T/prompt.md" -o "$T/out.md" -C "$T/work"
check "用途 screen なら表の別のモデルを使う" has_seq -m fake-sol -c 'model_reasoning_effort="medium"'

run -m direct-model -e low -s read-only -f "$T/prompt.md" -o "$T/out.md" -C "$T/work"
check "表を使わず -m と -e で指定できる" has_seq -m direct-model -c 'model_reasoning_effort="low"'
check "-m・-e で指定したことを標準エラーに出す" stderr_has "（-m・-e の指定）"

run -s read-only -f "$T/prompt.md" -o "$T/out.md"
check "用途もモデルも無ければ終了コード 2" status_is 2
check "用途もモデルも無ければ codex を呼ばない" not_called
check "用途もモデルも無ければ、使える用途を示す" stderr_has "review screen"

run -m direct-model -s read-only -f "$T/prompt.md" -o "$T/out.md"
check "-m だけで -e が無ければ終了コード 2" status_is 2
check "-m だけでは codex を呼ばない" not_called

run -e low -s read-only -f "$T/prompt.md" -o "$T/out.md"
check "-e だけで -m が無ければ終了コード 2" status_is 2

run --use nope -s read-only -f "$T/prompt.md" -o "$T/out.md"
check "表に無い用途は終了コード 2" status_is 2
check "表に無い用途では codex を呼ばない" not_called
check "表に無い用途だと標準エラーに出す" stderr_has "表にありません"

printf '{ 壊れている\n' > "$T/broken-table.json"
CODEX_MODELS_FILE="$T/broken-table.json" run --use review -s read-only -f "$T/prompt.md" -o "$T/out.md"
check "表が壊れていれば終了コード 2" status_is 2
check "表が壊れていれば codex を呼ばない" not_called

echo "--- codex-run.sh：モデルの知らせ（呼び出しは止めない） ---"

CODEX_HOME="$T/codex-new" run --use review -s read-only -f "$T/prompt.md" -o "$T/out.md" -C "$T/work"
check "新しいモデルが出ても呼び出しは続ける" status_is 0
check "新しいモデルが出たことを知らせる" stderr_has "表に無いモデルがあります: fake-new"
check "隠されたモデルは知らせない" stderr_lacks "fake-hidden2"
check "知らせがあったことを標準出力にも出す" stdout_has "知らせ: 1 件"

CODEX_HOME="$T/codex-gone" run --use screen -s read-only -f "$T/prompt.md" -o "$T/out.md" -C "$T/work"
check "表のモデルが一覧から消えたら知らせる" stderr_has "表の用途 review が使う fake-astra が、Codex のモデル一覧にありません"
check "モデルが消えても呼び出しは続ける" status_is 0

CODEX_HOME="$T/codex-upgrade" run --use review -s read-only -f "$T/prompt.md" -o "$T/out.md" -C "$T/work"
check "表のモデルに廃止の予定が付いたら知らせる" stderr_has "fake-astra に乗り換えの案内があります: 偽の廃止のお知らせ"
check "廃止の日と乗り換え先も知らせる" stderr_has "廃止 2026-12-31T00:00:00Z・乗り換え先 fake-sol"

CODEX_HOME="$T/codex-none" run --use review -s read-only -f "$T/prompt.md" -o "$T/out.md" -C "$T/work"
check "一覧が無ければ確認を飛ばしたと知らせる" stderr_has "確認を飛ばしました"
check "一覧が無くても呼び出しは続ける" status_is 0

CODEX_HOME="$T/codex-broken" run --use review -s read-only -f "$T/prompt.md" -o "$T/out.md" -C "$T/work"
check "一覧が壊れていれば照合に失敗したと知らせる" stderr_has "照合に失敗しました"
check "一覧が壊れていても呼び出しは続ける" status_is 0

CODEX_HOME="$T/codex-schema" run --use review -s read-only -f "$T/prompt.md" -o "$T/out.md" -C "$T/work"
check "一覧の形が変わったら照合に失敗したと知らせる" stderr_has "照合に失敗しました"
check "一覧の形が変わっても「一覧にありません」と誤って知らせない" stderr_lacks "一覧にありません"
check "一覧の形が変わっても呼び出しは続ける" status_is 0

CODEX_HOME="$T/codex-noslug" run --use review -s read-only -f "$T/prompt.md" -o "$T/out.md" -C "$T/work"
check "slug の無いモデルが混ざったら照合に失敗したと知らせる" stderr_has "照合に失敗しました"
check "slug の無いモデルが混ざっても「一覧にありません」と誤って知らせない" stderr_lacks "一覧にありません"

echo "--- codex-run.sh：読ませない場所（--deny-read-list） ---"

cat > "$T/deny.txt" <<'EOS'
# コメントの行
~/secret-a   # 行の後ろのコメント

/var/tmp/deny-{uid}
EOS
UID_NOW="$(id -u)"
run --use review -s read-only -f "$T/prompt.md" -o "$T/out.md" -C "$T/work" --deny-read-list "$T/deny.txt"
check "読ませない場所の一覧を渡せる" status_is 0
check "権限のプロファイルを既定にする" has_seq -c 'default_permissions="codex_run_read_limited"'
check "全体は読み取りだけ、一覧の場所は deny の表を渡す（~ と {uid} を置き換え、コメントと空行は読まない）" \
  has_seq -c "permissions.codex_run_read_limited.filesystem={\":root\"=\"read\",\"$(wf "$HOME/secret-a")\"=\"deny\",\"$(wf "/var/tmp/deny-$UID_NOW")\"=\"deny\"}"
check "読ませない場所の件数を標準エラーに出す" stderr_has "読ませない場所 2 件"
# -s を付けると権限のプロファイルが捨てられる（2026-10-06 に実機で確かめた）ので、サンドボックスは -c で渡す
check "読ませない場所を渡すときは -s を付けない" lacks -s
check "読ませない場所を渡すときはサンドボックスを -c sandbox_mode で渡す" has_seq -c 'sandbox_mode="read-only"'
check "読ませない場所を渡すときも作業フォルダは -C で渡さない" lacks -C
check "読ませない場所を渡すときも、呼ばれたときの今いるフォルダが作業フォルダと同じ" test "$(cat "$FAKE/cwd")" = "$T/work"

run --use review --resume fake-thread-1 -s read-only -f "$T/prompt.md" -o "$T/out.md" -C "$T/work" --deny-read-list "$T/deny.txt"
check "resume でも権限のプロファイルを渡す" has_seq -c 'default_permissions="codex_run_read_limited"'

run --use review -s read-only -f "$T/prompt.md" -o "$T/out.md" -C "$T/work"
check "一覧を渡さなければ権限のプロファイルを付けない" lacks 'default_permissions="codex_run_read_limited"'

run --use review -s workspace-write -f "$T/prompt.md" -o "$T/out.md" -C "$T/work" --deny-read-list "$T/deny.txt"
check "workspace-write とは一緒に使えない（終了コード 2）" status_is 2
check "workspace-write と一緒なら codex を呼ばない" not_called

printf 'relative/path\n' > "$T/deny-rel.txt"
run --use review -s read-only -f "$T/prompt.md" -o "$T/out.md" -C "$T/work" --deny-read-list "$T/deny-rel.txt"
check "相対パスの場所は終了コード 2" status_is 2

printf '/tmp/a"b\n' > "$T/deny-quote.txt"
run --use review -s read-only -f "$T/prompt.md" -o "$T/out.md" -C "$T/work" --deny-read-list "$T/deny-quote.txt"
check "引用符の入った場所は終了コード 2" status_is 2
check "引用符の入った場所では codex を呼ばない" not_called

printf '%s\n' "$T" > "$T/deny-parent.txt"
run --use review -s read-only -f "$T/prompt.md" -o "$T/out.md" -C "$T/work" --deny-read-list "$T/deny-parent.txt"
check "作業フォルダが読ませない場所の中なら終了コード 2" status_is 2
check "作業フォルダが読ませない場所の中なら codex を呼ばない" not_called

printf '# コメントだけ\n' > "$T/deny-empty.txt"
run --use review -s read-only -f "$T/prompt.md" -o "$T/out.md" -C "$T/work" --deny-read-list "$T/deny-empty.txt"
check "場所が 1 つも無い一覧は終了コード 2" status_is 2

run --use review -s read-only -f "$T/prompt.md" -o "$T/out.md" -C "$T/work" --deny-read-list "$T/no-such.txt"
check "一覧のファイルが無ければ終了コード 2" status_is 2

# * と ! とリンクと重なり：偽のホームで確かめる
FH="$T/fakehome"
mkdir -p "$FH/a/inner" "$FH/keep" "$T/elsewhere"
: > "$FH/.b"
ln -s "$FH/a/inner" "$FH/link-inside"
ln -s "$T/elsewhere" "$FH/link-outside"
cat > "$T/deny-glob.txt" <<'EOS'
~/*
!~/keep
EOS
HOME="$FH" run --use review -s read-only -f "$T/prompt.md" -o "$T/out.md" -C "$T/work" --deny-read-list "$T/deny-glob.txt"
check "* と ! の一覧を渡せる" status_is 0
check "* は . で始まるものも含めて広げる" grep -qF -- "\"$(wf "$FH/.b")\"=\"deny\"" "$FAKE/args"
check "* で広げたフォルダを読ませない" grep -qF -- "\"$(wf "$FH/a")\"=\"deny\"" "$FAKE/args"
check "! で除外したものは読ませない場所に入れない" args_lack "\"$(wf "$FH/keep")\"=\"deny\""
if [ -L "$FH/link-outside" ] || ! is_win; then
  check "外を指すリンクは行き先を読ませない" grep -qF -- "\"$(wf "$T/elsewhere")\"=\"deny\"" "$FAKE/args"
  check "リンクそのものの名前では書かない" args_lack "link-outside"
else
  echo "skip  外を指すリンクは行き先を読ませない（Windows の Git Bash の ln -s はリンクでなく写しを作るので、この形では試せない。下のジャンクションで確かめる）"
  echo "skip  リンクそのものの名前では書かない（同上）"
fi
check "ほかの読ませない場所の中に重なるものは省く" args_lack "\"$(wf "$FH/a/inner")\"=\"deny\""
if is_win; then
  # Windows：同じ守りを、Windows で作れるリンク（ジャンクション。フォルダを指す）で確かめる
  FHJ="$T/fakehome-j"
  mkdir -p "$FHJ/a" "$T/elsewhere-j"
  MSYS_NO_PATHCONV=1 cmd.exe /d /c mklink /J "$(cygpath -w "$FHJ/jlink-outside")" "$(cygpath -w "$T/elsewhere-j")" > /dev/null 2>&1
  HOME="$FHJ" run --use review -s read-only -f "$T/prompt.md" -o "$T/out.md" -C "$T/work" --deny-read-list "$T/deny-glob.txt"
  check "Windows：外を指すジャンクションは行き先を読ませない" grep -qF -- "\"$(wf "$T/elsewhere-j")\"=\"deny\"" "$FAKE/args"
  check "Windows：ジャンクションそのものの名前では書かない" args_lack "jlink-outside"
fi

# 空白を含むパスの * は、空白で割らずに広げる
mkdir -p "$T/sp ace/x" "$T/sp ace/y"
printf '%s\n' "$T/sp ace/*" > "$T/deny-space.txt"
run --use review -s read-only -f "$T/prompt.md" -o "$T/out.md" -C "$T/work" --deny-read-list "$T/deny-space.txt"
check "空白を含むパスの * を割らずに広げる" grep -qF -- "\"$(wf "$T/sp ace/x")\"=\"deny\",\"$(wf "$T/sp ace/y")\"=\"deny\"" "$FAKE/args"

# * で広げた名前に引用符があれば、TOML を壊すので止める
mkdir -p "$T/fakehome-q/a\"b"
HOME="$T/fakehome-q" run --use review -s read-only -f "$T/prompt.md" -o "$T/out.md" -C "$T/work" --deny-read-list "$T/deny-glob.txt"
check "* で広げた名前に引用符があれば終了コード 2" status_is 2
check "* で広げた名前に引用符があれば codex を呼ばない" not_called

# codex の実行ファイルが読ませない場所の中なら止める
mkdir -p "$T/fakehome2/bin"
cp "$FAKE/codex" "$T/fakehome2/bin/codex"
rm -f "$FAKE/args"
HOME="$T/fakehome2" CODEX_BIN="$T/fakehome2/bin/codex" TMPDIR="$T/tmp" bash "$RUN_SH" --use review -s read-only -f "$T/prompt.md" -o "$T/out.md" -C "$T/work" --deny-read-list "$T/deny-glob.txt" > "$T/stdout" 2> "$T/stderr"
echo $? > "$T/status"
check "codex の実行ファイルが読ませない場所の中なら終了コード 2" status_is 2
check "codex の実行ファイルが読ませない場所の中なら codex を呼ばない" not_called

# 本物の一覧（config/codex-review-deny-read.txt）も読める。ホームの作りは機械ごとに違う（CI の機械には ~/workspace が無い）ので、
# この PC と同じ作りの偽のホームで確かめる。作業フォルダは一覧の外の / にする
FH3="$T/fakehome3"
mkdir -p "$FH3/workspace" "$FH3/.ssh" "$FH3/.vscode-server/extensions" "$FH3/.vscode-server/data" "$FH3/.vscode-server/bin"
HOME="$FH3" run --use review -s read-only -f "$T/prompt.md" -o "$T/out.md" -C / --deny-read-list "$SCRIPT_DIR/../config/codex-review-deny-read.txt"
check "本物の読ませない場所の一覧を読める" status_is 0
check "本物の一覧で ~/workspace を読ませない" grep -qF -- "\"$(wf "$FH3/workspace")\"=\"deny\"" "$FAKE/args"
check "本物の一覧で ~/.ssh を読ませない" grep -qF -- "\"$(wf "$FH3/.ssh")\"=\"deny\"" "$FAKE/args"
check "本物の一覧で Claude の作業用フォルダを読ませない" grep -qF -- "\"$(wf "/tmp/claude-$UID_NOW")\"=\"deny\"" "$FAKE/args"
check "本物の一覧で Windows のドライブ（/mnt）を読ませない" grep -qF -- "\"$(wf /mnt)\"=\"deny\"" "$FAKE/args"
check "本物の一覧で .vscode-server そのものは丸ごとは塞がない" args_lack "\"$(wf "$FH3/.vscode-server")\"=\"deny\""
check "本物の一覧で codex の実行ファイルのある .vscode-server/extensions は読める" args_lack "\"$(wf "$FH3/.vscode-server/extensions")\"=\"deny\""
check "本物の一覧で編集の履歴のある .vscode-server/data は読ませない" grep -qF -- "\"$(wf "$FH3/.vscode-server/data")\"=\"deny\"" "$FAKE/args"
check "本物の一覧で .vscode-server/bin は読ませない" grep -qF -- "\"$(wf "$FH3/.vscode-server/bin")\"=\"deny\"" "$FAKE/args"

# Windows 版の一覧（config/codex-review-deny-read.windows.txt）も、この PC と同じ作りの偽のホームで確かめる。
# 中身の組み立ては OS によらないので、Linux でも流す（Codex に渡す形だけが OS で違う）。
# 作業フォルダは、Windows の Git Bash の /tmp と同じ ~/AppData/Local/Temp の中に作る
FHW="$T/fakehome-win"
mkdir -p "$FHW/workspace" "$FHW/.ssh" "$FHW/Documents" "$FHW/AppData/Roaming" "$FHW/AppData/LocalLow" \
  "$FHW/AppData/Local/Packages" "$FHW/AppData/Local/Temp/claude" "$FHW/AppData/Local/Temp/codex-review.test"
: > "$FHW/NTUSER.DAT"; : > "$FHW/ntuser.dat.LOG1"; : > "$FHW/ntuser.dat.LOG2"; : > "$FHW/ntuser.ini"
HOME="$FHW" run --use review -s read-only -f "$T/prompt.md" -o "$T/out.md" -C "$FHW/AppData/Local/Temp/codex-review.test" \
  --deny-read-list "$SCRIPT_DIR/../config/codex-review-deny-read.windows.txt"
check "Windows 版の一覧を読める（作業フォルダの Temp の中は読ませない場所に入らない）" status_is 0
check "Windows 版の一覧で ~/workspace を読ませない" grep -qF -- "\"$(wf "$FHW/workspace")\"=\"deny\"" "$FAKE/args"
check "Windows 版の一覧で ~/.ssh を読ませない" grep -qF -- "\"$(wf "$FHW/.ssh")\"=\"deny\"" "$FAKE/args"
check "Windows 版の一覧で ~/Documents を読ませない" grep -qF -- "\"$(wf "$FHW/Documents")\"=\"deny\"" "$FAKE/args"
check "Windows 版の一覧で AppData/Roaming を読ませない" grep -qF -- "\"$(wf "$FHW/AppData/Roaming")\"=\"deny\"" "$FAKE/args"
check "Windows 版の一覧で AppData/Local/Packages を読ませない" grep -qF -- "\"$(wf "$FHW/AppData/Local/Packages")\"=\"deny\"" "$FAKE/args"
check "Windows 版の一覧で Claude の作業用フォルダ（Temp/claude）を読ませない" grep -qF -- "\"$(wf "$FHW/AppData/Local/Temp/claude")\"=\"deny\"" "$FAKE/args"
check "Windows 版の一覧で AppData そのものは丸ごとは塞がない" args_lack "\"$(wf "$FHW/AppData")\"=\"deny\""
check "Windows 版の一覧で AppData/LocalLow を読ませない" grep -qF -- "\"$(wf "$FHW/AppData/LocalLow")\"=\"deny\"" "$FAKE/args"
check "Windows 版の一覧で AppData/Local そのものは丸ごとは塞がない" args_lack "\"$(wf "$FHW/AppData/Local")\"=\"deny\""
check "Windows 版の一覧で Temp（Git Bash の /tmp。作業フォルダの置き場）は読める" args_lack "\"$(wf "$FHW/AppData/Local/Temp")\"=\"deny\""
check "Windows 版の一覧で、作業フォルダは読ませない場所に入らない" args_lack "codex-review.test"
# Windows が開いたままのレジストリのファイルを渡すと、mxc が共有違反で起動しないので外す（ほかのファイルは読ませない）
check "Windows 版の一覧で、使用中のレジストリのファイル（NTUSER.DAT・LOG1・LOG2）は渡さない" \
  test -z "$(grep -oiE 'ntuser\.dat(\.LOG[12])?"="deny"' "$FAKE/args")"
check "Windows 版の一覧で、ほかの直下のファイル（ntuser.ini）は読ませない" grep -qF -- "\"$(wf "$FHW/ntuser.ini")\"=\"deny\"" "$FAKE/args"

echo "--- codex-run.sh：一覧の選び方と、OS ごとの違い ---"

# 一覧は codex-deny-list.sh が OS で選ぶ（Claude への指示の文の中で OS を見分けさせない）
if is_win; then
  check "Windows では Windows 版の一覧を選ぶ" test "$(bash "$SCRIPT_DIR/codex-deny-list.sh")" = "$(cd "$SCRIPT_DIR/../config" && pwd)/codex-review-deny-read.windows.txt"
else
  check "Linux では WSL・Linux 版の一覧を選ぶ" test "$(bash "$SCRIPT_DIR/codex-deny-list.sh")" = "$(cd "$SCRIPT_DIR/../config" && pwd)/codex-review-deny-read.txt"
fi

# 一覧の値が空なら止める（一覧を選ぶスクリプトが何も出さなかったときに、一覧なしで呼ばないため）
run --use review -s read-only -f "$T/prompt.md" -o "$T/out.md" -C "$T/work" --deny-read-list ""
check "--deny-read-list の値が空なら終了コード 2" status_is 2
check "--deny-read-list の値が空なら codex を呼ばない" not_called

if is_win; then
  # Windows：Codex に渡す読ませない場所は C:/… の形だけにし、囲いの種類 mxc を渡す（2026-11-18）
  run --use review -s read-only -f "$T/prompt.md" -o "$T/out.md" -C "$T/work"
  check "Windows では囲いの種類 mxc を渡す" has_seq -c 'windows.sandbox="mxc"'
  check "Windows でも -s で読み取りだけにする" has_seq -s read-only
  run --use review -s read-only -f "$T/prompt.md" -o "$T/out.md" -C "$T/work" --deny-read-list "$T/deny.txt"
  check "Windows では読ませない場所を渡すときも mxc を渡す" has_seq -c 'windows.sandbox="mxc"'
  check "Windows では読ませない場所を C:/… の形で渡す" grep -qF -- "\"$(cygpath -m -- "$HOME")/secret-a\"=\"deny\"" "$FAKE/args"
  check "Windows では読ませない場所に /c/… や /tmp/… の形を残さない" args_lack "\"/"
  check "Windows では elevated を渡さない" args_lack "elevated"
  run --use review --resume fake-thread-1 -s read-only -f "$T/prompt.md" -o "$T/out.md" -C "$T/work" --deny-read-list "$T/deny.txt"
  check "Windows では resume でも mxc を渡す" has_seq -c 'windows.sandbox="mxc"'

  # 一覧に C:\… と C:/… の形で書いても受け、C:/… の形で渡す
  mkdir -p "$T/win-a" "$T/win-b"
  { cygpath -w -- "$T/win-a"; cygpath -m -- "$T/win-b"; } > "$T/deny-winform.txt"
  run --use review -s read-only -f "$T/prompt.md" -o "$T/out.md" -C "$T/work" --deny-read-list "$T/deny-winform.txt"
  check "Windows では一覧に C:\\… と C:/… の形で書ける" status_is 0
  check "Windows では C:\\… の形で書いた場所も C:/… の形で渡す" grep -qF -- "\"$(cygpath -m -l -- "$T/win-a")\"=\"deny\"" "$FAKE/args"
  check "Windows では C:/… の形で書いた場所もそのまま渡す" grep -qF -- "\"$(cygpath -m -l -- "$T/win-b")\"=\"deny\"" "$FAKE/args"

  # 作業フォルダを /c/…/Temp/… の形、一覧を /tmp/… の形で書いても、同じ場所として比べて止める
  # （Git Bash の /tmp は ~/AppData/Local/Temp の別名。形が違うまま比べると、作業フォルダが読ませない場所の中でも通ってしまう）
  wt="$(cygpath -m -- "$T")"
  c_form="/$(printf '%s' "${wt:0:1}" | tr '[:upper:]' '[:lower:]')/${wt:3}"
  printf '%s\n' "$T" > "$T/deny-tmpform.txt"
  run --use review -s read-only -f "$T/prompt.md" -o "$T/out.md" -C "$c_form/work" --deny-read-list "$T/deny-tmpform.txt"
  check "Windows では /c/… と /tmp/… の形が違っても、作業フォルダが読ませない場所の中なら終了コード 2" status_is 2
  check "Windows では形が違っても、作業フォルダが読ませない場所の中なら codex を呼ばない" not_called
else
  # Linux（WSL）：引数は前と同じ（囲いの種類を足さず、読ませない場所は / で始まる形のまま）
  run --use review -s read-only -f "$T/prompt.md" -o "$T/out.md" -C "$T/work"
  check "Linux では囲いの種類（windows.sandbox）を渡さない" args_lack "windows.sandbox"
  run --use review -s read-only -f "$T/prompt.md" -o "$T/out.md" -C "$T/work" --deny-read-list "$T/deny.txt"
  check "Linux では読ませない場所を渡すときも windows.sandbox を渡さない" args_lack "windows.sandbox"
  check "Linux では読ませない場所を / で始まる形のまま渡す" grep -qF -- "\"$HOME/secret-a\"=\"deny\"" "$FAKE/args"
  run --use review --resume fake-thread-1 -s read-only -f "$T/prompt.md" -o "$T/out.md" -C "$T/work" --deny-read-list "$T/deny.txt"
  check "Linux では resume でも windows.sandbox を渡さない" args_lack "windows.sandbox"
fi

echo "--- codex-run.sh：前回の続きを聞く ---"

run --use review --resume fake-thread-1 -s read-only -f "$T/prompt.md" -o "$T/out.md" -C "$T/work" --keep-session
check "exec resume で呼ぶ" has_seq exec resume
check "resume ではサンドボックスを -c sandbox_mode で渡す" has_seq -c 'sandbox_mode="read-only"'
check "resume には -s を付けない（codex に無い）" lacks -s
check "resume には -C を付けない（codex に無い）" lacks -C
check "resume でも作業フォルダで codex が動く" test "$(cat "$FAKE/cwd")" = "$T/work"
check "thread_id のあとに -（標準入力）" test "$(tail -n 2 "$FAKE/args" | tr '\n' ' ')" = "fake-thread-1 - "
check "resume でもモデルと考える深さを明示する" has_seq -m fake-astra -c 'model_reasoning_effort="high"'

# resume は --ephemeral でも元の記録に追記される（2026-10-05 実機）ので、「残していない」と表示しない
run --use review --resume fake-thread-1 -s read-only -f "$T/prompt.md" -o "$T/out.md" -C "$T/work"
check "resume では「記録は残していない」と表示しない" stdout_lacks "記録は残していない"

echo "--- codex-run.sh：codex の失敗 ---"

printf '前の結果\n' > "$T/keep.md"
FAKE_EXIT=3 run --use review -s read-only -f "$T/prompt.md" -o "$T/keep.md" -C "$T/work"
check "codex の終了コードを返す" status_is 3
check "失敗したら -o のファイルを書き換えない" test "$(cat "$T/keep.md")" = "前の結果"
check "失敗の理由を標準エラーに出す" stderr_has '偽の失敗'
check "失敗しても一時フォルダを残さない" test -z "$(ls -A "$T/tmp")"

FAKE_EMPTY=1 run --use review -s read-only -f "$T/prompt.md" -o "$T/keep.md" -C "$T/work"
check "返答が空なら終了コード 1" status_is 1
check "返答が空なら -o のファイルを書き換えない" test "$(cat "$T/keep.md")" = "前の結果"
check "返答が空だったことを標準エラーに出す" stderr_has '返答が空'

echo "--- codex-run.sh：指定の誤り（codex を呼ばない） ---"

run --use review -f "$T/prompt.md" -o "$T/out.md"
check "-s が無ければ終了コード 2" status_is 2
check "-s が無ければ codex を呼ばない" not_called

run --use review -s danger-full-access -f "$T/prompt.md" -o "$T/out.md"
check "danger-full-access は受け付けない" status_is 2
check "danger-full-access では codex を呼ばない" not_called

run --use review -s read-only -f "$T/no-such.md" -o "$T/out.md"
check "依頼書が無ければ終了コード 2" status_is 2

: > "$T/empty.md"
run --use review -s read-only -f "$T/empty.md" -o "$T/out.md"
check "依頼書が空なら終了コード 2" status_is 2

run --use review -s read-only -f "$T/prompt.md"
check "-o が無ければ終了コード 2" status_is 2

run --use review -s read-only -f "$T/prompt.md" -o "$T/no-dir/out.md"
check "-o のフォルダが無ければ終了コード 2" status_is 2

run --use review -s read-only -f "$T/prompt.md" -o "$T/work"
check "-o にフォルダを指定したら終了コード 2" status_is 2
check "-o がフォルダなら codex を呼ばない" not_called

run --use review -s read-only -f "$T/prompt.md" -o "$T/out.md" --events "$T/work"
check "--events にフォルダを指定したら終了コード 2" status_is 2

run --use review -s read-only -f "$T/prompt.md" -o "$T/out.md" -e 'high" sandbox_mode="danger-full-access'
check "-e に引用符を混ぜられない" status_is 2
check "-e が不正なら codex を呼ばない" not_called

run --use review -s read-only -f "$T/prompt.md" -o "$T/out.md" --schema "$T/no-such.json"
check "--schema のファイルが無ければ終了コード 2" status_is 2

run --use review -s read-only -f "$T/prompt.md" -o "$T/out.md" --unknown
check "知らない指定は終了コード 2" status_is 2

run --use review -s read-only -f "$T/prompt.md" -o
check "値の欠けた指定は終了コード 2" status_is 2

echo "--- codex-run.sh：画像を添える（-i） ---"

printf 'png' > "$T/shot-1.png"
printf 'png' > "$T/shot-2.png"
(cd "$T" && run --use screen -s read-only -f prompt.md -o out-img.md -C work -i shot-1.png -i "$T/shot-2.png")
check "-i の画像を絶対パスにして codex の -i で渡す" has_seq -i "$T/shot-1.png" -i "$T/shot-2.png"
check "-i のあとは -- で区切ってから「-」を渡す" has_seq -i "$T/shot-2.png" -- -
check "-i を付けても返答を受け取れる" test "$(cat "$T/out-img.md")" = "偽の返答"

run --use review -s read-only -f "$T/prompt.md" -o "$T/out.md"
check "-i が無ければ -- を付けない" lacks --

run --use screen -s read-only -f "$T/prompt.md" -o "$T/out.md" -i "$T/no-such.png"
check "-i の画像が無ければ終了コード 2" status_is 2
check "-i の画像が無ければ codex を呼ばない" not_called

run --use review --resume fake-thread-1 -s read-only -f "$T/prompt.md" -o "$T/out.md" -i "$T/shot-1.png"
check "-i と --resume は一緒に使えない（終了コード 2）" status_is 2
check "-i と --resume のときは codex を呼ばない" not_called

echo
if [ "$failures" -eq 0 ]; then
  echo "すべて ok"
else
  echo "NG が $failures 件"
  exit 1
fi
