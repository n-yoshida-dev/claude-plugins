#!/usr/bin/env bash
# プロンプトのテンプレートの差し込み口（{{名前}}）を埋めて、標準出力に出す
#
# 使い方： bash fill-prompt.sh <テンプレート> 名前=値 名前=@ファイル ...
#   名前=値        {{名前}} を値の文字列に置き換える（行の途中でもよい）。値は 1 行
#   名前=@ファイル {{名前}} だけの行を、ファイルの中身で置き換える（行の途中にあるときはエラー）
# 呼び元： codex-review スキル（このあと compete スキルも）
# 出力：  埋めたプロンプト。冒頭の出典の注記（1 行目の <!-- から --> まで、とその次の空行）は外す
#         （注記はモデルへの指示ではないため。prompts/README.md「使うときの注意」）
# 終了コード：0 成功 / 2 指定の誤り・埋め残し・テンプレートに無い名前（このときは何も出さない。埋めずにモデルへ渡さないため）
#
# 差し込み口の確かめはテンプレートの行だけで行う。ファイルから差し込んだ中身に {{…}} があっても、そのまま出す
# （レビューする文書が差し込み口の書き方そのものを説明していることがあるため）
set -uo pipefail

# 誤りを標準エラーに出して終了する
fail() {
  echo "fill-prompt.sh: $1" >&2
  exit 2
}

[ $# -ge 1 ] || fail "使い方: bash fill-prompt.sh <テンプレート> 名前=値 名前=@ファイル ..."
template="$1"; shift
[ -f "$template" ] && [ -r "$template" ] || fail "テンプレートが読めません: $template"

declare -A inline_values=()
declare -A file_values=()
declare -A used=()
for pair in "$@"; do
  name="${pair%%=*}"
  value="${pair#*=}"
  [ "$name" != "$pair" ] || fail "名前=値 の形ではありません: $pair"
  [[ "$name" =~ ^[A-Z][A-Z0-9_]*$ ]] || fail "差し込み口の名前は英大文字・数字・_ だけです: $name"
  if [ -n "${inline_values[$name]+x}" ] || [ -n "${file_values[$name]+x}" ]; then
    fail "同じ名前が 2 回指定されています: $name"
  fi
  if [ "${value:0:1}" = "@" ]; then
    file="${value:1}"
    [ -f "$file" ] && [ -r "$file" ] || fail "$name に差し込むファイルが読めません: $file"
    file_values[$name]="$file"
  else
    [[ "$value" != *$'\n'* ]] || fail "$name の値に改行があります。複数行はファイルにして 名前=@ファイル で渡してください"
    inline_values[$name]="$value"
  fi
done

out=""
line_no=0
in_header=0
skip_blank=0
while IFS= read -r line || [ -n "$line" ]; do
  line_no=$((line_no + 1))
  # 冒頭の出典の注記を外す
  if [ "$line_no" -eq 1 ] && [ "$line" = "<!--" ]; then in_header=1; continue; fi
  if [ "$in_header" -eq 1 ]; then
    if [ "$line" = "-->" ]; then in_header=0; skip_blank=1; fi
    continue
  fi
  if [ "$skip_blank" -eq 1 ]; then
    skip_blank=0
    [ -z "$line" ] && continue
  fi

  # ファイルで埋める差し込み口だけの行
  if [[ "$line" =~ ^\{\{([A-Z][A-Z0-9_]*)\}\}$ ]] && [ -n "${file_values[${BASH_REMATCH[1]}]+x}" ]; then
    name="${BASH_REMATCH[1]}"
    used[$name]=1
    out+="$(cat "${file_values[$name]}")"$'\n'
    continue
  fi

  # 行の中の差し込み口を、名前ごとに確かめてから置き換える
  rest="$line"
  while [[ "$rest" =~ \{\{([A-Z][A-Z0-9_]*)\}\} ]]; do
    name="${BASH_REMATCH[1]}"
    rest="${rest#*"{{$name}}"}"
    if [ -n "${file_values[$name]+x}" ]; then
      fail "{{$name}} はファイルで埋める指定ですが、テンプレートの $line_no 行目では行の途中にあります"
    fi
    [ -n "${inline_values[$name]+x}" ] || fail "テンプレートの $line_no 行目の {{$name}} を埋める値がありません"
    used[$name]=1
    # 置き換え後の値を引用符で囲むので、値の中の & や \ はそのまま入る（bash 5.2 の patsub_replacement でも化けない）
    line="${line//"{{$name}}"/"${inline_values[$name]}"}"
  done
  out+="$line"$'\n'
done < "$template"

[ "$in_header" -eq 0 ] || fail "テンプレートの冒頭の注記が --> で閉じていません: $template"
for name in "${!inline_values[@]}" "${!file_values[@]}"; do
  [ -n "${used[$name]+x}" ] || fail "テンプレートに {{$name}} がありません（名前の書き間違いの可能性）"
done
printf '%s' "$out"
