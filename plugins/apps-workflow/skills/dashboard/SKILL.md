---
name: dashboard
description: 人間が Claude Code に任せた開発の状況（進捗・あなた待ち・今のタスク・CI・最近の変更）を 1 画面で見る「開発ダッシュボード」を、そのリポジトリ用に作る・直す。「ダッシュボードを作りたい」「開発状況を見える化したい」「観測画面がほしい」「dashboard を足して」と言われたら呼ぶ。設計方針・手順・テンプレート（update.mjs / index.html）を持っていて、リポジトリごとの固有指標だけを書き足せば数十分で出せる。
---

# 開発ダッシュボード（作り方の手順）

skill-matrix で 2026-09-26〜27 に作ったもの（PR #47〜#55）を元にした型。決めることを減らして「ポン出し」するためのスキル。
**画面の中身とデザインはリポジトリごとに変えてよい。守るのは下の「方針」だけ。**

## 方針（全リポジトリ共通。ここは変えない）

1. **観測画面であって管理画面ではない。** 正本（TODO.md / HANDOFF.md / logs/decisions.md / git / GitHub / Beads / そのリポジトリのデータ）を
   読んで描くだけ。ダッシュボード独自の状態を持たない。人が画面から書き込む機能を付けない。同じ数字を正本と二重に持たない
2. **文章は最低限。** 一覧は 1 項目 1 行（括弧書き・Markdown 記法・2 文目以降を落とす）。全文はマウスを載せるか押したときだけ出す。
   段落の文章（引き継ぎメモ全文・合意の本文）は最下部の折りたたみに置く
3. **上から「数字のタイル → あなた待ち・今のタスク → CI・コミット・固有の指標 → 折りたたみ」。** 重要なものほど上。
   異常（CI 失敗・検証失敗・引き継ぎの遅れ・取得失敗）は最上段に赤／黄の帯で出し、異常が無いときは帯を出さない
4. **状態は記号と色と文字の 3 つで示す**（✓ 成功 / ✕ 失敗 / ! 注意 / – 取得できず）。色だけに頼らない
5. **ヘッダーに「起動方法」と「更新」ボタン。** 起動は `node dashboard/update.mjs --serve --open` の 1 コマンド。起動方法は
   `cd <リポジトリの場所>` から始まるコマンドをコピーボタン付きで画面に出す。更新に失敗したら理由と同じ案内を出す
6. **依存 0・ビルド無し・数ファイル。** Node 標準ライブラリと素の HTML/CSS/JS だけ。生成物（`dashboard/data.js`）は `.gitignore`。
   `data.js` は `window.DASHBOARD_DATA = {...}` の JS にして、`index.html` をダブルクリックで開いても読めるようにする
7. **無いものは黙って飛ばし、壊れているものは画面に出す。** `gh` や `bd` が無ければ「取得できず」、JSON が壊れていれば赤い帯。握りつぶさない
8. **人が今見る価値のある項目だけ。** 項目数を増やさない。候補は下の「表示項目の選び方」

## 手順

### 1. 調べる（10 分）

- `CLAUDE.md` / `HANDOFF.md` / `TODO.md` / `logs/decisions.md` / `.github/workflows/` / `.beads/` の有無と形を見る。
  apps 配下のアプリなら全部同じ規約なので、テンプレートの読み取りがそのまま動く
- **そのリポジトリ固有の「人が今見る価値のある数字と状態」を 1〜2 個だけ決める。** 例：データファイルの件数と検証コマンドの成否（skill-matrix）、
  マイグレーションの適用状態、商品データの登録件数、E2E の最終結果。**数十秒かかるコマンドは選ばない**（正本は CI の結果）
- 別セッションが同じチェックアウトで作業中なら、`git worktree add` で別ディレクトリに分けて作業する（ブランチ切り替え・stash をしない）

### 2. テンプレートを写す（5 分）

```bash
mkdir -p dashboard
cp ${CLAUDE_PLUGIN_ROOT}/skills/dashboard/template/update.mjs dashboard/
cp ${CLAUDE_PLUGIN_ROOT}/skills/dashboard/template/index.html dashboard/
cp ${CLAUDE_PLUGIN_ROOT}/skills/dashboard/template/README.md dashboard/
```

上のパスはスキルの読み込み時にプラグインの置き場所（絶対パス）へ置き換わる。`$` で始まる文字列のまま見えている場合は
`ls -d ~/.claude/plugins/cache/n-yoshida-dev/apps-workflow/*/skills/dashboard/template` で探し、いちばん新しいバージョンを使う。

`.gitignore` に次の 2 行を足す。

```
dashboard/data.js
dashboard/data.js.tmp
```

### 3. 固有の指標を書く（10〜20 分）

`dashboard/update.mjs` の **★ の節 `readProjectSpecific()` だけ**を書き換える。返す形はその関数のコメントにある
（`title` / `status`（タイルに出す状態 1 つ）/ `stats`（数字 4 つまで）/ `bars` / `note` / `output` / `alerts` / `human`）。
`index.html` はその形をそのまま描くので、原則触らない。見た目を変えたいときは `index.html` の CSS の変数（`:root`）から変える。

固有の指標が本当に無いなら `null` のままでよい（タイル 4 枚・カード 2 枚で描かれる）。

### 4. 動かして確かめる（10 分）

```bash
node dashboard/update.mjs                      # data.js ができ、1 行の要約が出る
node dashboard/update.mjs --serve --port 8791  # 配信。--open は付けない（確認はヘッドレスで）
curl -s -X POST http://127.0.0.1:8791/update   # {"ok":true,...}
```

ヘッドレス Chromium があれば（`ls ~/.cache/ms-playwright/chromium_headless_shell-*/chrome-headless-shell-linux64/chrome-headless-shell`）、
1400px と 390px で撮って見る。無ければ `--dump-dom` 相当の確認をせず、ユーザーに開いてもらう。

```bash
C=$(ls ~/.cache/ms-playwright/chromium_headless_shell-*/chrome-headless-shell-linux64/chrome-headless-shell | tail -1)
"$C" --headless --no-sandbox --disable-gpu --hide-scrollbars --virtual-time-budget=4000 --window-size=1400,1100 --screenshot=/tmp/pc.png http://127.0.0.1:8791/
"$C" --headless --no-sandbox --disable-gpu --hide-scrollbars --virtual-time-budget=4000 --window-size=390,1600 --screenshot=/tmp/phone.png http://127.0.0.1:8791/
```

確かめること：描画エラーが無い（`#err` が hidden）／一覧が 1 行に収まっている／スマホ幅で横にはみ出さない／
`git status` に `data.js` が出ない／ファイルを直接開いても描ける（`file://`）。終わったらプロセスを止める。

### 5. 文書に 1 節ずつ足す（5 分）

- そのリポジトリの `CLAUDE.md` に「## 開発ダッシュボード（`dashboard/`）」を 5 行以内で。起動コマンド、独自の状態を持たないこと、
  「TODO の見出し規約・HANDOFF の節名・CI のジョブ名・Beads の題名規約を変えたら `update.mjs` も直す」の 1 行
- `HANDOFF.md` の動作確認コマンドに `node dashboard/update.mjs --serve --open` を 1 行
- `TODO.md` に完了条件つきで 1 タスク（`[x]`）。完了条件は「起動して、進捗・あなた待ち・今のタスク・CI・固有の指標が 1 画面に出る。独自の状態を持たない。PC とスマホ幅で崩れない」
- `dashboard/README.md`（テンプレートを写したもの）の固有指標の行を、そのリポジトリの内容に直す

### 6. PR にする

`apps-workflow:pr-flow` の手順どおり。PR 本文の「確認した証拠」は**必ず先端のコードで取り直した結果**を書く
（レビュー指摘で直したあと古い証拠を残すと、acceptance-reviewer に止められる。skill-matrix PR #55 で 2 回）。

## 複数のリポジトリをまとめて見る（ハブ）

リポジトリごとに `--serve` するとポートがぶつかり、起動コマンドも増える。`hub.mjs` を 1 本起動すれば、
`~/workspace/apps/*/dashboard/` を全部拾って `http://localhost:8790/` に一覧、`/<app>/` に各ダッシュボードを出す。

```bash
node "$(ls -d ~/.claude/plugins/cache/n-yoshida-dev/apps-workflow/*/skills/dashboard/hub.mjs | sort -V | tail -1)" --open
# オプション: --root <apps の場所>（既定 ~/workspace/apps）--port <n>（既定 8790）--host 0.0.0.0（LAN のスマホから）
```

- 各リポジトリの `update.mjs` を子プロセスで呼ぶので、リポジトリごとの固有指標がそのまま出る。全部を並列に回す
- 一覧の行の「更新」でそのアプリだけ、「全部更新」で全部を作り直す。各ダッシュボードの「更新」ボタンもハブ経由で効く
  （テンプレートの `fetch('update')` は相対パス。v1.5.0 以前に写した `index.html` は `fetch('/update')` なので、`'update'` に直す）
- ハブは各リポジトリの `--serve` を置き換えるものではない。単独で見たいときは今までどおり `--serve --open`
- ダッシュボードが無いリポジトリは一覧に出ない。足したいリポジトリで、このスキルの手順 2〜5 を行う

## 表示項目の選び方

| 出す | 出さない（または折りたたみ） |
|---|---|
| 進捗率と残り件数（TODO.md） | フェーズごとの長い表 |
| あなた待ち（Beads `human` ＋ TODO「確認待ち」＋固有の「人が決めるもの」） | Claude 側の付箋（折りたたみ） |
| 今のタスク 1 件と、この後 4 件 | 未完タスク全部 |
| main の CI の状態、開いている PR とその CI | PR 実行と main 実行の両方（同じ変更が 2 行になる） |
| 最近のコミット 6 件（種類の札・短い題名・PR 番号） | 変更ファイルの一覧（折りたたみ） |
| 固有の指標 1〜2 個 | セッション情報・コスト（正本が無い） |
| 引き継ぎメモ・合意（折りたたみ） | 同じものを本文に展開 |

## テンプレートの構成

| ファイル | 役割 | 触るか |
|---|---|---|
| `template/update.mjs` | 正本を読んで `data.js` を書く。`--serve` で配信し、`POST /update` で作り直す。`--open` でブラウザを開く | ★ `readProjectSpecific()` だけ |
| `template/index.html` | `data.js` を読んで描く。ヘッダー（起動方法・更新）、帯、タイル、カード、折りたたみ。題名を縮める `short()` | 原則触らない。色は `:root` |
| `template/README.md` | 目的・起動・更新・取得元・構成 | 固有指標の行だけ |
| `hub.mjs`（写さない） | 全リポジトリのダッシュボードを 1 本で配信するハブ。プラグインの置き場所から直接起動する | 触らない |

TODO.md の数え方は `hooks/progress.sh` と同じ（`##` = フェーズ、「確認待ち」「保留」は合計から外す）。
HANDOFF.md は「現在地」「次…やること／一手」を含む `##` 見出しの節を取る。Beads は題名がプロジェクト名（CLAUDE.md の先頭見出し）で始まる epic の配下。
この 3 つの規約を変えたら `update.mjs` の該当関数を直す。

## うまくいかないとき

- **`gh` の項目が「取得できず」**：`gh auth status` を見る。未ログインでもほかの項目は出る
- **Beads が「取得できず」**：`.beads/redirect` が無い（worktree に写していない）。`bd` はカレントディレクトリから探す
- **「更新」を押しても変わらない**：ファイルを直接開いている（`file://`）。画面の「起動方法」のとおり `--serve --open` で起動する
- **数字が progress.sh と違う**：`- [x]` の直後に空白が無い行や `##` 見出しの規約外の書き方。`readTodo()` の正規表現を見る
