# claude-plugins

[n-yoshida-dev](https://github.com/n-yoshida-dev) の自作アプリ（`~/workspace/apps/`）で使い回す
Claude Code プラグインのマーケットプレイス。

## なぜプラグインにするか

`.claude/settings.json`・`hooks/`・`skills/` は**親ディレクトリを遡って読まれない**（遡るのは `CLAUDE.md` だけ）。
そのため `~/workspace/apps/.claude/` に共通設定を置いてもアプリからは効かない。
各アプリに同じファイルをコピーすると、直すたびに全リポジトリを回ることになる。
プラグインにすれば、直すのはここ1か所で済む。

## プラグイン一覧

| 名前 | 内容 |
|---|---|
| [apps-workflow](plugins/apps-workflow/) | フック3種（秘密情報のコミット阻止・編集直後の typecheck/lint/vet・起動時の TODO 提示）＋ `/handoff` ＋ `/pr-check` |

## 使い方（アプリ側）

各アプリの `.claude/settings.json` に書く。フォルダを信頼すると Claude Code がマーケットプレイスを自動登録する。

```json
{
  "extraKnownMarketplaces": {
    "n-yoshida-dev": {
      "source": { "source": "github", "repo": "n-yoshida-dev/claude-plugins" }
    }
  },
  "enabledPlugins": {
    "apps-workflow@n-yoshida-dev": true
  }
}
```

**マシンごとに初回だけ**、プラグイン本体を取得する必要がある（外部ソースのプラグインは自動では落ちてこない）。

```bash
claude plugin marketplace add n-yoshida-dev/claude-plugins
claude plugin install apps-workflow@n-yoshida-dev
```

プラグインを更新したら、利用側は `/plugin marketplace update n-yoshida-dev` →
`/plugin update apps-workflow@n-yoshida-dev` で取り込む（`version` を上げた変更だけが配られる）。

## 開発

```bash
# 構文・スキーマの検証（CI でも同じことをする）
claude plugin validate . --strict
claude plugin validate plugins/apps-workflow --strict

# 公開せずに手元で試す
claude --plugin-dir ./plugins/apps-workflow
```

変更を配るときは `plugins/<name>/.claude-plugin/plugin.json` の `version` を上げる。
