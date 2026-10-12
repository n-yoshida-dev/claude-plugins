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
| [apps-workflow](plugins/apps-workflow/) | フック4種（秘密情報のコミット阻止・編集直後の typecheck/lint/vet・起動時の進捗表と TODO 提示・画面のファイルを変えたときの DESIGN.md と見た目の点検の知らせ）＋ `/progress`（進捗表）＋ `/handoff` ＋ `/pr-check` ＋ `/pr-flow`（PR からマージまでの手順）＋ `/dashboard`（開発ダッシュボードの作り方とテンプレート）＋ `/codex-review` ＋ `/compete` ＋ `/look`（見た目の方向を決める・画面を変えた PR ごとの点検）＋ `acceptance-reviewer` エージェント（マージ前の受け入れレビュー）＋ `look-reviewer` エージェント（見た目の点検役）。一覧は [plugins/apps-workflow/README.md](plugins/apps-workflow/README.md) |

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

**マシン（WSL ディストリ）ごとに初回だけ**、プラグイン本体を取得する必要がある
（外部ソースのプラグインは自動では落ちてこない）。**Claude Code のセッション内**で実行する。

```
/plugin marketplace add n-yoshida-dev/claude-plugins
/plugin install apps-workflow@n-yoshida-dev
```

引数なしで `/plugin` を打つと対話メニューが開くので、そこから追加・導入してもよい。

**シェルの `claude` コマンドは PATH に無い前提で書くこと。** VSCode 拡張などは自前の実行環境を持っていて
`claude plugin install` は `command not found` になる。セッション内の `/plugin` から行うか、
拡張同梱のバイナリをフルパスで叩く（Claude 自身に代行させるときはこちら）。

```bash
CLI=$(ls -d ~/.vscode-server/extensions/anthropic.claude-code-*/resources/native-binary/claude | sort -V | tail -1)
"$CLI" plugin install apps-workflow@n-yoshida-dev --scope project   # 利用側アプリのディレクトリで実行
```

**`enabledPlugins` に書くだけでは読み込まれない。** 利用側アプリごとに project スコープで install して
`~/.claude/plugins/installed_plugins.json` に記録を作る必要がある（`claude plugin list` の「enabled」表示は
この記録を見ていないので当てにならない。2026-08-30 の棚卸しで 3 アプリが記録なしのまま 8 日間フックなしで動いていた）。

プラグインを更新したら、利用側は `/plugin marketplace update n-yoshida-dev` →
`/plugin update apps-workflow@n-yoshida-dev` で取り込む（`version` を上げた変更だけが配られる）。

## 仕組みの図（site/）

部品が誰に呼ばれ、何を使い、いつ動くかを図にしたページ。**https://n-yoshida-dev.github.io/claude-plugins/**

| ページ | 図 |
|---|---|
| `index.html` | 全体の概念図 |
| `flow.html` | 1 回の作業の流れ（どの手順でどの部品が組み合わさるか。動く） |
| `parts.html` | 部品ごとの概念図と仕様 |
| `who.html` | 誰が始めるか（自動／Claude／提案して OK 後／本人） |
| `where.html` | 置き場所と効く範囲 |
| `changes.html` | 版ごとに増えた・直した・外した部品 |
| `usage.html` | 使用回数（本人の環境でだけ中身が出る） |

図の中身は手で書かない。`site/build/generate.mjs` が部品のファイル（hooks.json・SKILL.md・agents・scripts の先頭コメント・config・prompts/sources.json・git の履歴）から `site/data.js` を作り、
main にマージすると GitHub Actions（`pages.yml`）が作り直して GitHub Pages に出す。手で書くのは作業の流れの手順 `site/build/flow.json` だけで、指した部品が無ければ生成が止まる。

```bash
node site/build/generate.mjs           # 手元で見る（site/data.js を作る。コミットしない）
node site/build/generate.mjs --local   # どのアプリに入っているかも足す（公開版には出さない）
```

各図は「SVG を書き出す」「PNG を書き出す」で画像にでき、記事に貼れる。

## 開発

```bash
# 構文・スキーマの検証（CI でも同じことをする）
claude plugin validate . --strict
claude plugin validate plugins/apps-workflow --strict

# 公開せずに手元で試す
claude --plugin-dir ./plugins/apps-workflow
```

変更を配るときは `plugins/<name>/.claude-plugin/plugin.json` の `version` を上げる。
