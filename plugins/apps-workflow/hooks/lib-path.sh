# shellcheck shell=bash
# check-edited.sh・look-notice.sh と、scripts/ の codex-run.sh などが読み込む共通の小さな関数
# （単体では動かさない。フックとしては登録しない）
#
# normalize_path <場所>：Windows（Git Bash）で渡る場所の書き方を、bash で比べられる形（/c/…）にそろえて標準出力に出す。
#   Windows の Claude Code は、編集したファイルを C:\Users\…\x.tsx の形で渡す。フックは /c/… や /home/… の形で
#   「プロジェクトの中か」を前方一致で比べているので、そのままだと一致せず、検査が黙って外れていた（2026-11-18）。
#   \ を / にそろえ、C:/… の形（ドライブ文字で始まる）なら cygpath -u で /c/… に直す。
#   cygpath がある所（Git Bash などの Windows）でだけ動かす。Linux（WSL）では、渡された場所をそのまま出す
#   （Linux では \ もファイル名に使える文字なので、置き換えると別の場所を指してしまうため）。
normalize_path() {
  local p="$1"
  if command -v cygpath >/dev/null 2>&1; then
    p="${p//\\//}"
    case "$p" in
      [A-Za-z]:/*|[A-Za-z]:) p=$(cygpath -u -- "$p") ;;
    esac
  fi
  printf '%s' "$p"
}

# is_windows_bash：Windows の Git Bash（uname -s が MINGW*・MSYS*）のときだけ真。
#   答えは最初の 1 回だけ uname で調べて変数に覚える（Windows ではコマンドを起こすのが遅いため）。
#   $( ) の中で呼ぶと覚えたことが外に残らないので、何度も呼ぶスクリプトは先に外で 1 回呼んでおく
is_windows_bash() {
  if [ -z "${_LIB_PATH_IS_WIN:-}" ]; then
    case "$(uname -s 2>/dev/null)" in
      MINGW*|MSYS*) _LIB_PATH_IS_WIN=1 ;;
      *) _LIB_PATH_IS_WIN=0 ;;
    esac
  fi
  [ "$_LIB_PATH_IS_WIN" = 1 ]
}

# windows_form <場所>：Windows の Git Bash では、場所を C:/… の形（Windows の書き方で、区切りは /）にそろえて標準出力に出す。
#   同じ場所が /c/…・/tmp/…（Git Bash が Temp に付けた名前）・C:\…・c:/… のどれで来ても同じ文字列になる
#   （cygpath -m -l。実在する場所は大文字・小文字も実物に合わせる）。git が返すルートも、Codex が受け付ける読ませない場所もこの形で、
#   /c/… の形のまま渡すと Codex は「絶対パスでない」と止まる（2026-11-18）。前方一致で比べる前と、Codex に渡す前にそろえる。
#   Linux（WSL）では、渡された場所をそのまま出す
windows_form() {
  if is_windows_bash; then
    cygpath -m -l -- "$1"
  else
    printf '%s' "$1"
  fi
}
