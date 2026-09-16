#!/usr/bin/env bash
# 進捗表 — TODO.md のチェックボックスをフェーズ（## 見出し）ごとに数え、進捗バーと残り件数を出す
#
# 使い方： bash progress.sh [プロジェクトのディレクトリ]
#          省略時は $CLAUDE_PROJECT_DIR、それも無ければカレントディレクトリ
# 呼び元： SessionStart フック（session-briefing.sh）、/apps-workflow:handoff、/apps-workflow:progress
# 出力：  Markdown のコードブロック 1 つ。そのままユーザーの画面や HANDOFF.md に貼れる形。TODO.md が無ければ何も出さない
#
# 数え方：
#   - `## ` 見出しを 1 フェーズとする。`### ` 以下の小見出しは親フェーズに含める
#   - `- [x]` を完了、`- [ ]` を未完として数える。字下げした子項目も 1 件と数える
#   - 見出しに「確認待ち」を含む節はユーザーの回答待ちなので、合計に入れず別枠で出す
#   - 見出しに「保留」を含む節は急がない持ち越しなので、合計に入れず別枠で出す
#   - タスクが 0 件のフェーズは「タスク未定義」と表示し、合計の隣に数を添える（100% でも後ろに未定義の段階が残ることを見せる）
#   - 「前回の区切りから」は、HANDOFF.md を最後にコミットした時点の TODO.md と比べる。
#     区切り以降に TODO.md が変わっていなければ（セッション開始直後など）、ひとつ前の区切りと比べて前回のセッション分を出す
#
# 件数は工数ではない。「1 タスク = PR 1 本の大きさ」に揃える規約（TODO.md 冒頭）とセットで意味を持つ。
set -uo pipefail

DIR="${1:-${CLAUDE_PROJECT_DIR:-$(pwd)}}"
TODO="$DIR/TODO.md"
[ -f "$TODO" ] || exit 0

# フェーズ別に集計して表を描く。フェーズ名は全角で幅が揃わないので行末に置く
render_table() {
  awk '
    function bar(d, t,    f, k, s) {
      f = (t > 0) ? int(W * d / t) : 0; s = ""
      for (k = 0; k < W; k++) s = s (k < f ? "█" : "░")
      return s
    }
    function pct(d, t) { return (t > 0) ? int(100 * d / t) : 0 }
    function register(s) { if (!(s in seen)) { seen[s] = 1; order[++n] = s } }
    BEGIN { W = 20; kind = "phase"; sec = "（見出しなし）" }
    /^## / {
      sec = $0; sub(/^## +/, "", sec)
      kind = (sec ~ /確認待ち/) ? "ask" : (sec ~ /保留/) ? "hold" : "phase"
      if (kind == "phase") register(sec)
      next
    }
    /^[ \t]*- \[[xX]\]/ {
      if (kind == "ask") ask_done++; else if (kind == "hold") hold_done++; else { register(sec); done[sec]++ }
      next
    }
    /^[ \t]*- \[ \]/ {
      if (kind == "ask") ask_open++; else if (kind == "hold") hold_open++; else { register(sec); open[sec]++ }
      next
    }
    END {
      for (i = 1; i <= n; i++) {
        s = order[i]; d = done[s] + 0; o = open[s] + 0; t = d + o
        if (t == 0) { undefined++; printf "%s   -   （タスク未定義）  %s\n", bar(0, 0), s; continue }
        td += d; to += o
        printf "%s %3d%%  残り %2d / %2d  %s\n", bar(d, t), pct(d, t), o, t, s
      }
      t = td + to
      printf "%s %3d%%  残り %2d / %2d  合計", bar(td, t), pct(td, t), to, t
      if (undefined > 0) printf "（ほかに未定義のフェーズ %d）", undefined
      printf "\n"
      if (ask_open + ask_done > 0) printf "あなたの回答待ち：%d 件（回答済み %d 件）\n", ask_open, ask_done
      if (hold_open + hold_done > 0) printf "保留（合計に含めない）：%d 件（済み %d 件）\n", hold_open, hold_done
    }
  ' "$1"
}

# 引数のファイル（- なら標準入力）について「完了 未完」の 2 数を出す。確認待ち・保留は除く
count_phase() {
  awk '
    BEGIN { kind = "phase" }
    /^## / { kind = ($0 ~ /確認待ち/) ? "ask" : ($0 ~ /保留/) ? "hold" : "phase"; next }
    kind == "phase" && /^[ \t]*- \[[xX]\]/ { d++ }
    kind == "phase" && /^[ \t]*- \[ \]/ { o++ }
    END { print d + 0, o + 0 }
  ' "$1"
}

# 前回の区切り（HANDOFF.md の最終コミット）からの増減を 1 行で出す。Git 管理外・区切りが無いときは何も出さない
delta_line() {
  git -C "$DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
  local marks=()
  mapfile -t marks < <(git -C "$DIR" log -2 --format=%H -- HANDOFF.md 2>/dev/null)
  [ "${#marks[@]}" -ge 1 ] || return 0

  local base label now_file
  now_file="$TODO"
  # 区切り以降に TODO.md が変わっていなければ、ひとつ前の区切りと比べて「前回のセッション分」を出す
  if [ "${#marks[@]}" -ge 2 ] && git -C "$DIR" show "${marks[0]}:TODO.md" 2>/dev/null | cmp -s - "$TODO"; then
    base="${marks[1]}"
    label="前回のセッション（$(git -C "$DIR" log -1 --format=%cd --date=short "${marks[1]}") → $(git -C "$DIR" log -1 --format=%cd --date=short "${marks[0]}")）で"
  else
    base="${marks[0]}"
    label="前回の区切り（$(git -C "$DIR" log -1 --format=%cd --date=short "${marks[0]}")）から"
  fi

  local base_counts now_counts
  base_counts=$(git -C "$DIR" show "$base:TODO.md" 2>/dev/null | count_phase -) || return 0
  [ -n "$base_counts" ] || return 0
  now_counts=$(count_phase "$now_file")

  local bd bo nd no
  read -r bd bo <<< "$base_counts"
  read -r nd no <<< "$now_counts"
  printf '%s：完了 +%d 件、新たに見つかったタスク +%d 件\n' "$label" $((nd - bd)) $(((nd + no) - (bd + bo)))
}

echo '```'
echo "進捗（TODO.md より自動集計・$(date +%Y-%m-%d)）"
echo
render_table "$TODO"
DELTA=$(delta_line)
if [ -n "$DELTA" ]; then
  echo
  echo "$DELTA"
fi
echo '```'
