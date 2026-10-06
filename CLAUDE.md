# claude-plugins

自作アプリ共通の Claude Code プラグインを置くリポジトリ。アプリではないので、
`../CLAUDE.md` の frontend/backend 構成・4ファイル体系（PLAN/SPEC/TODO/KNOWLEDGE）は適用しない。

## 構成

- `.claude-plugin/marketplace.json` — カタログ。プラグインを増やしたらここに1行足す
- `plugins/<name>/` — プラグイン本体。`.claude-plugin/plugin.json` / `hooks/hooks.json` / `skills/<skill>/SKILL.md`

## 守ること

- **フックの検査ロジックはシェルスクリプトに置き、`hooks.json` は登録だけにする。** スクリプト単体で
  `echo '<json>' | bash hooks/xxx.sh` と叩いて検証できる状態を保つ
- **フックはプロジェクトに無いものを黙ってスキップする。** `frontend/` `backend/` `TODO.md` が無いリポジトリで
  エラーを出さない
- **利用側に配る変更は `plugin.json` の `version` を上げる。** 上げないと利用側に届かない
- **版を上げただけでは、利用側には届かない。** マージしたら Claude が、`claude plugin marketplace update n-yoshida-dev` のあと、
  apps-workflow を入れている全アプリで `claude plugin update apps-workflow@n-yoshida-dev --scope <project か local>` を実行する
  （どのアプリにどの範囲で入っているかは `~/.claude/plugins/installed_plugins.json`。app-template だけ local）。
  終わったら `installed_plugins.json` で全部が新しい版になったことを確かめる。動いているセッションには開き直したときに効く。
  `claude` は PATH に無いので、VS Code 拡張の中の `~/.vscode-server/extensions/anthropic.claude-code-<版>-linux-x64/resources/native-binary/claude` をフルパスで呼ぶ
  （2026-10-06 に、全アプリが 1.5.6（portfolio だけ 1.9.0）のまま止まっていて、compete（1.10.0）はどのアプリにも、codex-run.sh（1.6.0〜）は portfolio 以外に届いていなかったと判明。本人の承認「昇格してOKですよ」）
- 変更したら `claude plugin validate . --strict` と `claude plugin validate plugins/<name> --strict` を通す
- シェルスクリプトを変えたら `bash -n` と shellcheck も通す。shellcheck はこのマシンに入っていないが、
  `npx --yes shellcheck <ファイル>` でほぼ CI と同じ検査ができる（初回だけバイナリを取得する。2026-09-04 に確認）。
  ただし版が違い、手元（0.11.0）で通っても CI で SC2015（`A && B || C` は if の代わりにならない）に止められたことがある（2026-10-06、PR #27）。
  条件で止める行は `if ! …; then …; fi` か `if [ … ] || [ … ]; then …; fi` の形で書く。CI はこの検査で最初に落ちたファイルで止まり、後ろのファイルを見ないので、1 件直したら全部を見直す
- **スキルのシェル埋め込み（感嘆符 + バッククォートの事前実行）には、単純な 1 コマンドだけを書く。** 変数代入・`$( )`・
  `;` での連結を入れない。ユーザーがスラッシュコマンドで起動すると会話の前に実行され、許可プロンプトを出せないため、
  事前検査に通らないと**スキル全体が中止になる**（VSCode 拡張・Auto モードで 2026-09-18 に handoff が 2 回中止。ヘッドレス実行では再現しない）。
  複雑な処理は本文の手順に書いて Claude に Bash ツールで実行させる。説明文の中でも感嘆符の直後にバッククォートを置かない。
  通った実績があるのは、読み取りコマンド 1 つに `2>/dev/null || echo "…"` の予備を付けた形まで（handoff と pr-check の既存行。v1.3.2 以前から）
- **スキル本文からプラグイン内のファイルを指すときは `${CLAUDE_PLUGIN_ROOT}` をそのまま書く。** 読み込み時に絶対パスへ文字列置換される。
  `${CLAUDE_PLUGIN_ROOT:-}` のように `:-` を付けると置換の対象から外れ、シェルでは未設定の変数になる（v1.4.0 で踏んだ）
- スキル名はプラグイン名で名前空間化される（`/apps-workflow:handoff`）。スキルを改名したら、
  利用側の CLAUDE.md の記述も直す必要があることを報告に含める
- コメント・ドキュメントは日本語で書く
