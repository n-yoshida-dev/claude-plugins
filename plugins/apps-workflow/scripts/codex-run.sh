#!/usr/bin/env bash
# Codex（既定は GPT-6 Astra）を毎回同じ条件で呼ぶ共通の入口
#
# 使い方：
#   新しく頼む：      bash codex-run.sh -s <サンドボックス> -f <依頼書.md> -o <結果.md> [任意の指定]
#   前回の続きを聞く：bash codex-run.sh --resume <thread_id> -s read-only -f <依頼書.md> -o <結果.md> [任意の指定]
#
# 必須：
#   -s <サンドボックス>  Codex が実行するコマンドの許す範囲。read-only か workspace-write。
#                        danger-full-access は受け付けない（Codex の中の操作には Claude 側のフックが効かないため）
#   -f <ファイル>        依頼文。標準入力から codex に渡す（コマンドの引数に本文を書くと、dangerous-bash-guard が本文の語に反応して止めることがあるため）
#   -o <ファイル>        Codex の最後の返答を書く先。codex が成功したときだけ書き換える
# 任意：
#   -e <effort>          考える深さ。既定 high（~/.codex/config.toml の既定は数日で変わった実績があるので頼らない）
#   -m <モデル>          既定 gpt-6-astra
#   -C <フォルダ>        Codex の作業フォルダ。既定は今いるフォルダ
#   --schema <ファイル>  最後の返答の形を JSON Schema で縛る（codex の --output-schema）
#   --events <ファイル>  codex が出す出来事（JSONL）を残す先。省略時は一時ファイルに書いて終わったら消す
#   --keep-session       会話の記録を ~/.codex/sessions に残す（--ephemeral を付けない）。あとで --resume するときに付ける
#   --skip-git-repo-check  Git の管理外のフォルダで動かす
#
# 必ず付けるもの：-m・-c model_reasoning_effort・サンドボックス・--ignore-user-config・--disable memories・--json。
#   --ignore-user-config で ~/.codex/config.toml（Codex 側のプラグインや既定のモデル）を読まない。認証は保たれる
#   resume には -s が無いので、サンドボックスは -c sandbox_mode で渡す
#
# 出力：
#   標準出力に「結果: <パス>」「thread_id: <id>」「使用量: <JSON>」の 3 行。Codex の返答の本文は -o のファイルにだけ書く
#   標準エラーに codex の警告と、失敗したときの理由
# 終了コード：0 成功 / 1 codex の失敗・返答なし / 2 指定の誤り（このときは codex を呼ばないので利用枠を使わない）
#
# 方針の出どころ：ops の docs/2026-10-04-マルチモデル協調の採用判断.md §7「共通の土台」と §8 手順 3
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 既定値。モデルと考える深さは呼ぶたびに明示する決まり（apps の CLAUDE.md）なので、ここで必ず値を持たせる
DEFAULT_MODEL="gpt-6-astra"
DEFAULT_EFFORT="high"

# 使い方を標準エラーに出して終了する
usage_error() {
  echo "codex-run.sh: $1" >&2
  echo "使い方: bash codex-run.sh [--resume <thread_id>] -s <read-only|workspace-write> -f <依頼書> -o <結果> [-e effort] [-m モデル] [-C フォルダ] [--schema <ファイル>] [--events <ファイル>] [--keep-session] [--skip-git-repo-check]" >&2
  exit 2
}

# 相対パスを、呼ばれた時点のフォルダを基準に絶対パスへ直す（-C で作業フォルダが変わっても同じファイルを指すため）
to_abs() {
  case "$1" in
    /*) printf '%s' "$1" ;;
    *) printf '%s/%s' "$PWD" "$1" ;;
  esac
}

# 値を取る指定の、値が欠けていないかを確かめる
need_value() {
  [ "$2" -ge 2 ] || usage_error "$1 に値がありません"
}

model="$DEFAULT_MODEL"
effort="$DEFAULT_EFFORT"
sandbox=""
prompt_file=""
out_file=""
workdir=""
schema_file=""
events_file=""
resume_id=""
keep_session=0
skip_git_check=0

while [ $# -gt 0 ]; do
  case "$1" in
    -s) need_value "$1" $#; sandbox="$2"; shift 2 ;;
    -f) need_value "$1" $#; prompt_file="$2"; shift 2 ;;
    -o) need_value "$1" $#; out_file="$2"; shift 2 ;;
    -e) need_value "$1" $#; effort="$2"; shift 2 ;;
    -m) need_value "$1" $#; model="$2"; shift 2 ;;
    -C) need_value "$1" $#; workdir="$2"; shift 2 ;;
    --schema) need_value "$1" $#; schema_file="$2"; shift 2 ;;
    --events) need_value "$1" $#; events_file="$2"; shift 2 ;;
    --resume) need_value "$1" $#; resume_id="$2"; shift 2 ;;
    --keep-session) keep_session=1; shift ;;
    --skip-git-repo-check) skip_git_check=1; shift ;;
    # 冒頭のコメント（使い方）だけを出す
    -h|--help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) usage_error "知らない指定です: $1" ;;
  esac
done

# --- 指定の検査（codex を呼ぶ前に止めて、利用枠を無駄にしない） ---
case "$sandbox" in
  read-only|workspace-write) ;;
  "") usage_error "-s（サンドボックス）は必須です。read-only か workspace-write" ;;
  *) usage_error "-s は read-only か workspace-write だけを受け付けます（指定: $sandbox）" ;;
esac
[ -n "$prompt_file" ] || usage_error "-f（依頼書）は必須です"
[ -n "$out_file" ] || usage_error "-o（結果の書き先）は必須です"
if [ ! -f "$prompt_file" ] || [ ! -r "$prompt_file" ]; then
  usage_error "依頼書が読めません: $prompt_file"
fi
[ -s "$prompt_file" ] || usage_error "依頼書が空です: $prompt_file"
# -c に TOML の値として埋め込むので、引用符などが混ざらないよう文字の種類を絞る
[[ "$effort" =~ ^[a-z]+$ ]] || usage_error "-e は英小文字だけで指定してください（指定: $effort）"
[[ "$model" =~ ^[A-Za-z0-9._-]+$ ]] || usage_error "-m に使えない文字があります（指定: $model）"
[[ -z "$resume_id" || "$resume_id" =~ ^[A-Za-z0-9._-]+$ ]] || usage_error "--resume の thread_id に使えない文字があります（指定: $resume_id）"

prompt_file="$(to_abs "$prompt_file")"
out_file="$(to_abs "$out_file")"
[ -d "$(dirname "$out_file")" ] || usage_error "-o の置き場所のフォルダがありません: $(dirname "$out_file")"
if [ -n "$schema_file" ]; then
  schema_file="$(to_abs "$schema_file")"
  [ -f "$schema_file" ] || usage_error "--schema のファイルがありません: $schema_file"
fi
if [ -n "$events_file" ]; then
  events_file="$(to_abs "$events_file")"
  [ -d "$(dirname "$events_file")" ] || usage_error "--events の置き場所のフォルダがありません: $(dirname "$events_file")"
fi
workdir="$(to_abs "${workdir:-$PWD}")"
[ -d "$workdir" ] || usage_error "-C のフォルダがありません: $workdir"

bin="$(bash "$SCRIPT_DIR/codex-bin.sh")" || exit 2

# --- 一時ファイル（返答の受け皿と、出来事の記録の既定の置き場） ---
tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/codex-run.XXXXXX")" || { echo "codex-run.sh: 一時フォルダを作れません" >&2; exit 1; }
trap 'rm -rf "$tmp_dir"' EXIT
tmp_out="$tmp_dir/last-message.md"
[ -n "$events_file" ] || events_file="$tmp_dir/events.jsonl"

# --- codex に渡す引数を組み立てる ---
args=(exec)
[ -n "$resume_id" ] && args+=(resume)
args+=(-m "$model" -c "model_reasoning_effort=\"$effort\"")
if [ -n "$resume_id" ]; then
  # exec resume には -s と -C が無い。サンドボックスは設定の上書きで渡し、作業フォルダは cd で合わせる
  args+=(-c "sandbox_mode=\"$sandbox\"")
else
  args+=(-s "$sandbox" -C "$workdir")
fi
args+=(--ignore-user-config --disable memories --json -o "$tmp_out")
[ "$keep_session" -eq 1 ] || args+=(--ephemeral)
[ "$skip_git_check" -eq 1 ] && args+=(--skip-git-repo-check)
[ -n "$schema_file" ] && args+=(--output-schema "$schema_file")
[ -n "$resume_id" ] && args+=("$resume_id")
# 最後の「-」は「依頼文を標準入力から読む」の意味
args+=(-)

echo "codex-run.sh: $bin / model=$model / effort=$effort / sandbox=$sandbox${resume_id:+ / resume=$resume_id}" >&2

cd "$workdir" || { echo "codex-run.sh: 作業フォルダに移れません: $workdir" >&2; exit 1; }
"$bin" "${args[@]}" < "$prompt_file" > "$events_file"
status=$?

# 失敗したときは、出来事の記録からエラーの行を拾って理由を見せる（--json では理由が標準出力側に出るため）
if [ "$status" -ne 0 ] || [ ! -f "$tmp_out" ]; then
  echo "codex-run.sh: codex が失敗しました（終了コード $status）。-o のファイルは書き換えていません" >&2
  jq -rc 'select(.type == "error" or .type == "turn.failed")' "$events_file" 2>/dev/null | tail -n 5 >&2
  [ "$status" -ne 0 ] || status=1
  exit "$status"
fi

mv "$tmp_out" "$out_file" || { echo "codex-run.sh: 結果を $out_file に置けません" >&2; exit 1; }

# 要約。thread_id は --resume に、使用量は記録に使う
thread_id="$(jq -r 'select(.type == "thread.started") | .thread_id' "$events_file" 2>/dev/null | tail -n 1)"
usage="$(jq -c 'select(.type == "turn.completed") | .usage' "$events_file" 2>/dev/null | tail -n 1)"
echo "結果: $out_file"
if [ "$keep_session" -eq 1 ]; then
  echo "thread_id: ${thread_id:-（出来事の記録に見当たらない）}"
else
  echo "thread_id: ${thread_id:-（出来事の記録に見当たらない）}（--ephemeral のため記録は残していない。続きを聞くなら次から --keep-session）"
fi
echo "使用量: ${usage:-（出来事の記録に見当たらない）}"
