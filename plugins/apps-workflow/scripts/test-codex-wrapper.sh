#!/usr/bin/env bash
# codex-bin.sh と codex-run.sh の回帰テスト
#
# 使い方： bash test-codex-wrapper.sh
# 本物の codex は呼ばない。受け取った引数と標準入力を記録するだけの偽の codex を CODEX_BIN で差し込むので、
# ChatGPT の利用枠を使わない。CI（.github/workflows/ci.yml）でも回す
# 出力：  1 件ごとに ok / NG。NG が 1 件でもあれば exit 1
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_SH="$SCRIPT_DIR/codex-bin.sh"
RUN_SH="$SCRIPT_DIR/codex-run.sh"

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
echo '{"type":"thread.started","thread_id":"fake-thread-1"}'
if [ "${FAKE_EXIT:-0}" -ne 0 ]; then
  # 失敗しても途中の返答を書く場合を真似る（ラッパーがそれを -o に置かないことを確かめるため）
  printf '途中の返答\n' > "$out"
  echo '{"type":"turn.failed","error":{"message":"偽の失敗"}}'
  exit "$FAKE_EXIT"
fi
echo '{"type":"turn.completed","usage":{"input_tokens":10,"cached_input_tokens":2,"output_tokens":5}}'
printf '偽の返答\n' > "$out"
EOS
chmod +x "$FAKE/codex"
export FAKE_DIR="$FAKE"

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

status_is() { [ "$(cat "$T/status")" = "$1" ]; }
stdout_has() { grep -qF -- "$1" "$T/stdout"; }

# codex-bin.sh がエラーで終わるか（CODEX_BIN の指定あり／HOME を差し替えて拡張機能を探す、の 2 通り）
bin_fails_with() { ! CODEX_BIN="$1" bash "$BIN_SH" > /dev/null 2>&1; }
bin_fails_in_home() { ! env -u CODEX_BIN HOME="$1" bash "$BIN_SH" > /dev/null 2>&1; }

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

echo "--- codex-run.sh：新しく頼む ---"

run -s read-only -f "$T/prompt.md" -o "$T/out.md" -C "$T/work"
check "成功すると終了コード 0" status_is 0
check "exec で呼ぶ" has_seq exec
check "モデルを gpt-6-astra で明示する" has_seq -m gpt-6-astra
check "考える深さを high で明示する" has_seq -c 'model_reasoning_effort="high"'
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
check "標準出力に使用量" stdout_has '使用量: {"input_tokens":10,"cached_input_tokens":2,"output_tokens":5}'
check "--schema が無ければ --output-schema を付けない" lacks --output-schema
check "一時フォルダを残さない" test -z "$(ls -A "$T/tmp")"

# 相対パスは呼んだ場所を基準にする（-C で移っても同じファイルを指す）
(cd "$T" && run -s workspace-write -f prompt.md -o out-rel.md -C work)
check "相対パスの依頼書と結果を、呼んだ場所から解決する" test "$(cat "$T/out-rel.md")" = "偽の返答"
check "workspace-write を渡せる" has_seq -s workspace-write

run -s read-only -f "$T/prompt.md" -o "$T/out.md" -C "$T/work" -e medium -m other-model --schema "$T/schema.json" --keep-session --skip-git-repo-check --events "$T/events.jsonl"
check "-e で考える深さを変えられる" has_seq -c 'model_reasoning_effort="medium"'
check "-m でモデルを変えられる" has_seq -m other-model
check "--schema を --output-schema で渡す" has_seq --output-schema "$T/schema.json"
check "--keep-session なら --ephemeral を付けない" lacks --ephemeral
check "--skip-git-repo-check を渡す" has_seq --skip-git-repo-check
check "--events のファイルに出来事を残す" grep -qF '"thread.started"' "$T/events.jsonl"

echo "--- codex-run.sh：前回の続きを聞く ---"

run --resume fake-thread-1 -s read-only -f "$T/prompt.md" -o "$T/out.md" -C "$T/work" --keep-session
check "exec resume で呼ぶ" has_seq exec resume
check "resume ではサンドボックスを -c sandbox_mode で渡す" has_seq -c 'sandbox_mode="read-only"'
check "resume には -s を付けない（codex に無い）" lacks -s
check "resume には -C を付けない（codex に無い）" lacks -C
check "resume でも作業フォルダで codex が動く" test "$(cat "$FAKE/cwd")" = "$T/work"
check "thread_id のあとに -（標準入力）" test "$(tail -n 2 "$FAKE/args" | tr '\n' ' ')" = "fake-thread-1 - "
check "resume でもモデルと考える深さを明示する" has_seq -m gpt-6-astra -c 'model_reasoning_effort="high"'

echo "--- codex-run.sh：codex の失敗 ---"

printf '前の結果\n' > "$T/keep.md"
FAKE_EXIT=3 run -s read-only -f "$T/prompt.md" -o "$T/keep.md" -C "$T/work"
check "codex の終了コードを返す" status_is 3
check "失敗したら -o のファイルを書き換えない" test "$(cat "$T/keep.md")" = "前の結果"
check "失敗の理由を標準エラーに出す" grep -qF '偽の失敗' "$T/stderr"
check "失敗しても一時フォルダを残さない" test -z "$(ls -A "$T/tmp")"

echo "--- codex-run.sh：指定の誤り（codex を呼ばない） ---"

run -f "$T/prompt.md" -o "$T/out.md"
check "-s が無ければ終了コード 2" status_is 2
check "-s が無ければ codex を呼ばない" not_called

run -s danger-full-access -f "$T/prompt.md" -o "$T/out.md"
check "danger-full-access は受け付けない" status_is 2
check "danger-full-access では codex を呼ばない" not_called

run -s read-only -f "$T/no-such.md" -o "$T/out.md"
check "依頼書が無ければ終了コード 2" status_is 2

: > "$T/empty.md"
run -s read-only -f "$T/empty.md" -o "$T/out.md"
check "依頼書が空なら終了コード 2" status_is 2

run -s read-only -f "$T/prompt.md"
check "-o が無ければ終了コード 2" status_is 2

run -s read-only -f "$T/prompt.md" -o "$T/no-dir/out.md"
check "-o のフォルダが無ければ終了コード 2" status_is 2

run -s read-only -f "$T/prompt.md" -o "$T/out.md" -e 'high" sandbox_mode="danger-full-access'
check "-e に引用符を混ぜられない" status_is 2
check "-e が不正なら codex を呼ばない" not_called

run -s read-only -f "$T/prompt.md" -o "$T/out.md" --schema "$T/no-such.json"
check "--schema のファイルが無ければ終了コード 2" status_is 2

run -s read-only -f "$T/prompt.md" -o "$T/out.md" --unknown
check "知らない指定は終了コード 2" status_is 2

run -s read-only -f "$T/prompt.md" -o
check "値の欠けた指定は終了コード 2" status_is 2

echo
if [ "$failures" -eq 0 ]; then
  echo "すべて ok"
else
  echo "NG が $failures 件"
  exit 1
fi
