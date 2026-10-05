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
bin_fails_with() { ! CODEX_BIN="$1" bash "$BIN_SH" > /dev/null 2>&1; }
bin_fails_in_home() { ! env -u CODEX_BIN HOME="$1" bash "$BIN_SH" > /dev/null 2>&1; }

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

mkdir -p "$T/tmp" "$T/work"
printf 'テスト用の依頼文\n2 行目\n' > "$T/prompt.md"
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
mkdir -p "$T/empty-home"
check "codex が見つからなければエラー" bin_fails_in_home "$T/empty-home"

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
check "作業フォルダを -C で渡す" has_seq -C "$T/work"
check "ユーザー設定を読まない" has_seq --ignore-user-config
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

echo
if [ "$failures" -eq 0 ]; then
  echo "すべて ok"
else
  echo "NG が $failures 件"
  exit 1
fi
