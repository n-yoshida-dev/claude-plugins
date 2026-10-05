#!/usr/bin/env bash
# 用途ごとの Codex のモデルの表（config/codex-models.json）を引き、Codex の手元のモデル一覧と照らす
#
# 使い方：
#   bash codex-models.sh resolve <用途>   標準出力に「モデル<TAB>考える深さ」を 1 行。用途が表に無ければ exit 2
#   bash codex-models.sh uses             表にある用途を空白区切りで 1 行
#   bash codex-models.sh check            表とモデル一覧を照らし、知らせを標準出力に 1 行ずつ。何も無ければ何も出さない
# 呼び元： codex-run.sh。単体で叩いて、表の中身や新しいモデルの有無を確かめてもよい
# 表の場所：環境変数 CODEX_MODELS_FILE、無ければこのプラグインの config/codex-models.json
# モデル一覧：${CODEX_HOME:-~/.codex}/models_cache.json（Codex が自分で取りに行って保存するもの）
# 終了コード：0 成功 / 1 表かモデル一覧が JSON として読めない・一覧の形が想定と違う / 2 指定の誤り・用途が表に無い
#
# check が知らせること（どれも知らせるだけで、表は書き換えない）：
#   - 一覧に、表の knownModels に無いモデルがある（新しいモデルが出た）。一覧で隠されているモデル（visibility が list でない）は数えない
#   - 表の用途が使うモデルが、一覧に無い（廃止された可能性）
#   - 表の用途が使うモデルに、乗り換えの案内（upgrade）が付いている（廃止の予定）
# 自動で乗り換えないのは、新しいモデルが用途に合うとは限らず、使用量も変わるため。比べてから人が表を直す
# （2026-10-05 の利用者の問い「GPTのバージョンが上がってAstraよりいいものが出たときに困らない？」から。Beads ops-h49.6）
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TABLE="${CODEX_MODELS_FILE:-$SCRIPT_DIR/../config/codex-models.json}"
CACHE="${CODEX_HOME:-$HOME/.codex}/models_cache.json"

# 表が JSON として読めるかを確かめる。読めなければ理由を出して exit 1
require_table() {
  if [ ! -r "$TABLE" ]; then
    echo "codex-models.sh: モデルの表が読めません: $TABLE" >&2
    exit 1
  fi
  if ! jq empty "$TABLE"; then
    echo "codex-models.sh: モデルの表が JSON として読めません: $TABLE" >&2
    exit 1
  fi
}

# 用途からモデルと考える深さを引く
resolve() {
  local use="$1" line
  require_table
  line="$(jq -r --arg u "$use" '.uses[$u] // empty | "\(.model)\t\(.effort)"' "$TABLE")" || exit 1
  if [ -z "$line" ]; then
    echo "codex-models.sh: 用途「$use」は表にありません。使える用途: $(jq -r '.uses | keys | join(" ")' "$TABLE")" >&2
    exit 2
  fi
  printf '%s\n' "$line"
}

# 表にある用途を並べる
uses() {
  require_table
  jq -r '.uses | keys | join(" ")' "$TABLE"
}

# 表とモデル一覧を照らして、知らせを 1 行ずつ出す
check() {
  require_table
  if [ ! -r "$CACHE" ]; then
    echo "Codex のモデル一覧（$CACHE）が読めないので、新しいモデルが出ていないかの確認を飛ばしました"
    return 0
  fi
  # 一覧は Codex の内部のファイルで、形が変わることがある。models が配列でない・slug の無いモデルがあるときは、
  # 「全部消えた」と誤って知らせないよう、照合に失敗したとして扱う
  jq -r --slurpfile t "$TABLE" '
    if (.models | type) != "array" or any(.models[]; (.slug | type) != "string")
      then error("models が「slug を持つモデルの配列」になっていません") else . end
    | $t[0] as $tab
    | .models as $all
    | [$all[] | select(.visibility == "list") | .slug] as $listed
    | [$listed[] | . as $s | select(($tab.knownModels // []) | index($s) == null)] as $new
    | ($tab.uses | to_entries | group_by(.value.model)
        | map({model: .[0].value.model, uses: (map(.key) | join("・"))})) as $used
    | (if ($new | length) > 0
        then "Codex のモデル一覧に、表に無いモデルがあります: \($new | join(", "))（表の確認日 \($tab.checkedAt)）。用途に合うかを比べてから config/codex-models.json を直してください"
        else empty end),
      ($used[] | . as $u
        | ([$all[] | select(.slug == $u.model)] | first) as $m
        | if $m == null then
            "表の用途 \($u.uses) が使う \($u.model) が、Codex のモデル一覧にありません（廃止された可能性）"
          elif $m.upgrade != null then
            "表の用途 \($u.uses) が使う \($u.model) に乗り換えの案内があります: \($m.upgrade.migration_markdown // "（本文なし）")（廃止 \($m.upgrade.retirement_at // "日付なし")・乗り換え先 \($m.upgrade.model // "不明")）"
          else empty end)
  ' "$CACHE" || { echo "codex-models.sh: Codex のモデル一覧が読めないか、形が想定と違います: $CACHE" >&2; exit 1; }
}

case "${1:-}" in
  resolve)
    [ $# -eq 2 ] || { echo "使い方: bash codex-models.sh resolve <用途>" >&2; exit 2; }
    resolve "$2"
    ;;
  uses) uses ;;
  check) check ;;
  *)
    echo "使い方: bash codex-models.sh resolve <用途> | uses | check" >&2
    exit 2
    ;;
esac
