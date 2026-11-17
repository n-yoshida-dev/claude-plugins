# shellcheck shell=bash
# check-edited.sh・look-notice.sh が読み込む共通の小さな関数（単体では動かさない。フックとしては登録しない）
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
