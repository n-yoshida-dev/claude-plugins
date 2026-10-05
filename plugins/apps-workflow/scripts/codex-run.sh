#!/usr/bin/env bash
# Codex を毎回同じ条件で呼ぶ共通の入口。どのモデルで動くかは、呼ぶたびに用途かモデルで決める
#
# 使い方：
#   新しく頼む：      bash codex-run.sh --use <用途> -s <サンドボックス> -f <依頼書.md> -o <結果.md> [任意の指定]
#   前回の続きを聞く：bash codex-run.sh --use <用途> --resume <thread_id> -s read-only -f <依頼書.md> -o <結果.md> [任意の指定]
#
# 必須：
#   --use <用途>         用途ごとのモデルの表（config/codex-models.json）からモデルと考える深さを引く。用途は design / screen / review / implement
#     または -m と -e    表を使わずにモデル（-m）と考える深さ（-e）を両方指定する
#                        どちらも無ければ codex を呼ばずに止める（~/.codex/config.toml の既定は数日で変わった実績があり、頼らないため）
#   -s <サンドボックス>  Codex が実行するコマンドの許す範囲。read-only か workspace-write。
#                        danger-full-access は受け付けない（Codex の中の操作には Claude 側のフックが効かないため）
#   -f <ファイル>        依頼文。標準入力から codex に渡す（コマンドの引数に本文を書くと、dangerous-bash-guard が本文の語に反応して止めることがあるため）
#   -o <ファイル>        Codex の最後の返答を書く先。codex が成功したときだけ書き換える
# 任意：
#   -m <モデル>          --use と一緒に使うと、表のモデルを上書きする
#   -e <effort>          --use と一緒に使うと、表の考える深さを上書きする
#   -C <フォルダ>        Codex の作業フォルダ。既定は今いるフォルダ
#   --schema <ファイル>  最後の返答の形を JSON Schema で縛る（codex の --output-schema）
#   --events <ファイル>  codex が出す出来事（JSONL）を残す先。省略時は一時ファイルに書いて終わったら消す
#   --keep-session       会話の記録を ~/.codex/sessions に残す（--ephemeral を付けない）。あとで --resume するときに付ける。
#                        --resume した回は、--ephemeral を付けても元の会話の記録に追記される（2026-10-05 に実機で確認）
#   --skip-git-repo-check  Git の管理外のフォルダで動かす
#   --deny-read-list <ファイル>  Codex に読ませない場所の一覧（例: config/codex-review-deny-read.txt）。-s read-only のときだけ使える。
#                        権限のプロファイル（全体は読み取りだけ、一覧の場所は deny）を -c で組み立てて渡す。
#                        Codex の読み取り専用は、そのままだと作業フォルダの外もどこでも読めるため（2026-10-05 に codex sandbox で確かめた）。
#                        一覧は 1 行 1 つの絶対パス。~ はホーム、{uid} はユーザー ID、* はその場所にあるものすべて（. で始まるものも）、
#                        先頭の ! は除外。# から後ろと空行は読まない。リンクは行き先に置き換え、ほかの場所の中に重なるものは省く。
#                        作業フォルダ（-C）や codex の実行ファイルが一覧の場所の中にあるときは止める（親の deny が勝ち、読めなくなるため）
#
# 必ず付けるもの：-m・-c model_reasoning_effort・サンドボックス・--ignore-user-config・--disable memories・--json。
#   --ignore-user-config で ~/.codex/config.toml（Codex 側のプラグインや既定のモデル）を読まない。認証は保たれる
#   resume には -s が無いので、サンドボックスは -c sandbox_mode で渡す
#
# 呼ぶ前に、表と Codex の手元のモデル一覧を照らす（codex-models.sh check）。新しいモデルが出た・表のモデルが消えた・廃止の予定が付いた、
#   を知らせるだけで、表は書き換えず、呼び出しも止めない。知らせを見たら、比べてから人が表を直す
#
# 出力：
#   標準出力に「結果: <パス>」「thread_id: <id>」「使用量: <JSON>」の 3 行。モデルの知らせがあれば「知らせ: <n> 件」を 4 行目に足す。
#   Codex の返答の本文は -o のファイルにだけ書く
#   標準エラーに、使ったモデルと出どころ、モデルの知らせの本文、codex の警告、失敗したときの理由
# 終了コード：0 成功 / 1 codex の失敗・返答なし / 2 指定の誤り（このときは codex を呼ばないので利用枠を使わない）
#
# 方針の出どころ：ops の docs/2026-10-04-マルチモデル協調の採用判断.md §7「共通の土台」と §8 手順 3
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 使い方を標準エラーに出して終了する
usage_error() {
  echo "codex-run.sh: $1" >&2
  echo "使い方: bash codex-run.sh (--use <用途> | -m <モデル> -e <effort>) [--resume <thread_id>] -s <read-only|workspace-write> -f <依頼書> -o <結果> [-C フォルダ] [--schema <ファイル>] [--events <ファイル>] [--keep-session] [--skip-git-repo-check] [--deny-read-list <ファイル>]" >&2
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

use=""
model=""
effort=""
sandbox=""
prompt_file=""
out_file=""
workdir=""
schema_file=""
events_file=""
resume_id=""
keep_session=0
deny_list_file=""
skip_git_check=0

while [ $# -gt 0 ]; do
  case "$1" in
    --use) need_value "$1" $#; use="$2"; shift 2 ;;
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
    --deny-read-list) need_value "$1" $#; deny_list_file="$2"; shift 2 ;;
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

# モデルと考える深さを決める。用途があれば表から引き、-m・-e があればそれで上書きする
if [ -n "$use" ]; then
  resolved="$(bash "$SCRIPT_DIR/codex-models.sh" resolve "$use")" || exit 2
  IFS=$'\t' read -r table_model table_effort <<< "$resolved"
  [ -n "$model" ] || model="$table_model"
  [ -n "$effort" ] || effort="$table_effort"
  model_source="表の用途 $use"
else
  [ -n "$model" ] || usage_error "用途（--use）か、モデル（-m）と考える深さ（-e）を指定してください。用途: $(bash "$SCRIPT_DIR/codex-models.sh" uses)"
  [ -n "$effort" ] || usage_error "-m で指定するときは -e（考える深さ）も指定してください"
  model_source="-m・-e の指定"
fi
# -c に TOML の値として埋め込むので、引用符などが混ざらないよう文字の種類を絞る
[[ "$effort" =~ ^[a-z]+$ ]] || usage_error "-e は英小文字だけで指定してください（指定: $effort）"
[[ "$model" =~ ^[A-Za-z0-9._-]+$ ]] || usage_error "-m に使えない文字があります（指定: $model）"
[[ -z "$resume_id" || "$resume_id" =~ ^[A-Za-z0-9._-]+$ ]] || usage_error "--resume の thread_id に使えない文字があります（指定: $resume_id）"

prompt_file="$(to_abs "$prompt_file")"
out_file="$(to_abs "$out_file")"
[ -d "$(dirname "$out_file")" ] || usage_error "-o の置き場所のフォルダがありません: $(dirname "$out_file")"
[ ! -d "$out_file" ] || usage_error "-o にフォルダが指定されています。ファイルのパスを指定してください: $out_file"
if [ -n "$schema_file" ]; then
  schema_file="$(to_abs "$schema_file")"
  [ -f "$schema_file" ] || usage_error "--schema のファイルがありません: $schema_file"
fi
if [ -n "$events_file" ]; then
  events_file="$(to_abs "$events_file")"
  [ -d "$(dirname "$events_file")" ] || usage_error "--events の置き場所のフォルダがありません: $(dirname "$events_file")"
  [ ! -d "$events_file" ] || usage_error "--events にフォルダが指定されています。ファイルのパスを指定してください: $events_file"
fi
workdir="$(to_abs "${workdir:-$PWD}")"
[ -d "$workdir" ] || usage_error "-C のフォルダがありません: $workdir"
workdir="$(realpath -e -- "$workdir")" || usage_error "-C のフォルダを解決できません: $workdir"

# 読ませない場所の一覧から、権限のプロファイルの filesystem の表（TOML のインライン表）を組み立てる
deny_paths=()
if [ -n "$deny_list_file" ]; then
  [ "$sandbox" = "read-only" ] || usage_error "--deny-read-list は -s read-only のときだけ使えます（指定: $sandbox）"
  if [ ! -f "$deny_list_file" ] || [ ! -r "$deny_list_file" ]; then
    usage_error "--deny-read-list のファイルが読めません: $deny_list_file"
  fi
  uid="$(id -u)"
  candidates=()
  excludes=()
  shopt -s dotglob nullglob
  while IFS= read -r raw || [ -n "$raw" ]; do
    entry="${raw%%#*}"
    entry="${entry#"${entry%%[![:space:]]*}"}"
    entry="${entry%"${entry##*[![:space:]]}"}"
    [ -n "$entry" ] || continue
    exclude=0
    if [ "${entry:0:1}" = "!" ]; then exclude=1; entry="${entry:1}"; fi
    # 先頭の ~ をホームにする（一覧の文字そのものの ~ なので、シェルの展開ではなく文字として比べる）
    case "$entry" in \~|\~/*) entry="$HOME${entry:1}" ;; esac
    entry="${entry//\{uid\}/$uid}"
    case "$entry" in /*) ;; *) usage_error "--deny-read-list の場所は絶対パスで書いてください: $raw" ;; esac
    # TOML の文字列に埋め込むので、引用符・バックスラッシュ・制御文字を入れない
    [[ "$entry" =~ ^[^\"\\[:cntrl:]]+$ ]] || usage_error "--deny-read-list の場所に使えない文字があります: $raw"
    if [ "$exclude" -eq 1 ]; then
      excludes+=("$(realpath -m -- "$entry")")
    elif [[ "$entry" == *"*"* ]]; then
      # * はその場所にあるもの（. で始まるものも含む）すべてに広げる
      # shellcheck disable=SC2206
      matched=($entry)
      for m in "${matched[@]}"; do candidates+=("$m"); done
    else
      candidates+=("$entry")
    fi
  done < "$deny_list_file"
  shopt -u dotglob nullglob

  # リンクは行き先に置き換える（bwrap はリンクの上に「読めない」を重ねられないため）。除外したものは外す
  resolved=()
  for c in "${candidates[@]}"; do
    r="$(realpath -m -- "$c")"
    skip=0
    for x in "${excludes[@]}"; do [ "$r" != "$x" ] || skip=1; done
    [ "$skip" -eq 1 ] || resolved+=("$r")
  done
  # ほかの読ませない場所の中にあるものは省く（親を読めなくすると、子に重ねて書けないため）。同じものも 1 つにする
  for p in "${resolved[@]}"; do
    keep=1
    for q in "${resolved[@]}"; do
      [ "$p" != "$q" ] || continue
      case "$p/" in "$q"/*) keep=0 ;; esac
    done
    for d in "${deny_paths[@]}"; do [ "$d" != "$p" ] || keep=0; done
    [ "$keep" -eq 0 ] || deny_paths+=("$p")
  done
  [ "${#deny_paths[@]}" -gt 0 ] || usage_error "--deny-read-list に場所が 1 つもありません: $deny_list_file"

  for d in "${deny_paths[@]}"; do
    case "$workdir/" in
      "$d"/*) usage_error "作業フォルダ（-C）が、読ませない場所（$d）の中にあります。作業フォルダはその外に作ってください" ;;
    esac
  done
fi

bin="$(bash "$SCRIPT_DIR/codex-bin.sh")" || exit 2
# Codex 本体が読ませない場所の中にあると、サンドボックスの中で Codex が自分を起動できない（2026-10-05 に確かめた）
for d in "${deny_paths[@]}"; do
  case "$(realpath -m -- "$bin")" in
    "$d"/*) usage_error "codex の実行ファイル（$bin）が読ませない場所（$d）の中にあります。一覧に ! で除外を足してください" ;;
  esac
done

# --- 一時ファイル（返答の受け皿と、出来事の記録の既定の置き場） ---
tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/codex-run.XXXXXX")" || { echo "codex-run.sh: 一時フォルダを作れません" >&2; exit 1; }
trap 'rm -rf "$tmp_dir"' EXIT
tmp_out="$tmp_dir/last-message.md"
[ -n "$events_file" ] || events_file="$tmp_dir/events.jsonl"

# --- codex に渡す引数を組み立てる ---
args=(exec)
[ -n "$resume_id" ] && args+=(resume)
args+=(-m "$model" -c "model_reasoning_effort=\"$effort\"")
if [ "${#deny_paths[@]}" -gt 0 ]; then
  # 全体は読み取りだけ（":root"="read"）にし、一覧の場所を読めなくする。exec でも resume でも -c で渡せる
  fs_table="{\":root\"=\"read\""
  for p in "${deny_paths[@]}"; do fs_table+=",\"$p\"=\"deny\""; done
  fs_table+="}"
  args+=(-c 'default_permissions="codex_run_read_limited"' -c "permissions.codex_run_read_limited.filesystem=$fs_table")
fi
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

echo "codex-run.sh: $bin / model=$model / effort=$effort（$model_source）/ sandbox=$sandbox${resume_id:+ / resume=$resume_id}${deny_list_file:+ / 読ませない場所 ${#deny_paths[@]} 件}" >&2

# 表と Codex の手元のモデル一覧を照らす。知らせるだけで、呼び出しは止めない
notice_count=0
if notices="$(bash "$SCRIPT_DIR/codex-models.sh" check)"; then
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    echo "codex-run.sh: 知らせ: $line" >&2
    notice_count=$((notice_count + 1))
  done <<< "$notices"
else
  echo "codex-run.sh: 知らせ: モデルの表と一覧の照合に失敗しました（理由は上の行。呼び出しは続けます）" >&2
  notice_count=1
fi

cd "$workdir" || { echo "codex-run.sh: 作業フォルダに移れません: $workdir" >&2; exit 1; }
"$bin" "${args[@]}" < "$prompt_file" > "$events_file"
status=$?

# 失敗したときは、出来事の記録からエラーの行を拾って理由を見せる（--json では理由が標準出力側に出るため）
# 出来事の記録は 1 行 1 つの JSON。JSON として読めない行が混ざっても止まらないよう、読めない行は飛ばす
if [ "$status" -ne 0 ] || [ ! -s "$tmp_out" ]; then
  if [ "$status" -eq 0 ]; then
    echo "codex-run.sh: codex の返答が空でした。-o のファイルは書き換えていません" >&2
  else
    echo "codex-run.sh: codex が失敗しました（終了コード $status）。-o のファイルは書き換えていません" >&2
  fi
  jq -rcR 'fromjson? | select(.type == "error" or .type == "turn.failed")' "$events_file" | tail -n 5 >&2
  [ "$status" -ne 0 ] || status=1
  exit "$status"
fi

mv "$tmp_out" "$out_file" || { echo "codex-run.sh: 結果を $out_file に置けません" >&2; exit 1; }

# 要約。thread_id は --resume に、使用量は記録に使う
thread_id="$(jq -rR 'fromjson? | select(.type == "thread.started") | .thread_id' "$events_file" | tail -n 1)"
usage="$(jq -cR 'fromjson? | select(.type == "turn.completed") | .usage' "$events_file" | tail -n 1)"
echo "結果: $out_file"
# resume した回は --ephemeral でも元の記録に追記されるので、「残していない」とは書かない
if [ "$keep_session" -eq 1 ] || [ -n "$resume_id" ]; then
  echo "thread_id: ${thread_id:-（出来事の記録に見当たらない）}"
else
  echo "thread_id: ${thread_id:-（出来事の記録に見当たらない）}（--ephemeral のため記録は残していない。続きを聞くなら次から --keep-session）"
fi
echo "使用量: ${usage:-（出来事の記録に見当たらない）}"
# 標準エラーを捨てる呼び方でも、知らせがあったことには気づけるようにする
[ "$notice_count" -eq 0 ] || echo "知らせ: $notice_count 件（モデルの表と一覧の照合。本文は標準エラー）"
