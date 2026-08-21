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
- スキル名はプラグイン名で名前空間化される（`/apps-workflow:handoff`）。スキルを改名したら、
  利用側の CLAUDE.md の記述も直す必要があることを報告に含める
- コメント・ドキュメントは日本語で書く
