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
- 変更したら `claude plugin validate . --strict` と `claude plugin validate plugins/<name> --strict` を通す
- シェルスクリプトを変えたら `bash -n` と shellcheck も通す。shellcheck はこのマシンに入っていないが、
  `npx --yes shellcheck <ファイル>` で CI と同じ検査ができる（初回だけバイナリを取得する。2026-09-04 に確認）
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
