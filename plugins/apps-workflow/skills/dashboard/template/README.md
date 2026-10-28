# 開発ダッシュボード

Claude Code に開発を任せているあいだ、人間がコードやログを追わずに「今どこ・何が終わった・何で止まっている・次は何・CI は緑か・自分の判断待ちは何か」を
1 画面で見るための観測画面。**ダッシュボード独自の状態は持たない。** 開くたびにリポジトリの正本を読み直して描くだけで、ここに書き込むものは無い。
型は apps-workflow の `dashboard` スキル（テンプレート）。

**普段の入口は横断タスクボード（ops）の「開発状況」タブ。** この画面はカードの「詳しく見る」の行き先で、ops の `snippets/build_board_dashboards.py` が
`update.mjs` を呼んで写す。下の起動は、手元で単独に見たいときだけ使う。

## 起動

```bash
node dashboard/update.mjs --serve --open   # ブラウザが開く。開き直すと最新になる（ターミナルは起動したまま置く）
node dashboard/update.mjs                  # データ（dashboard/data.js）を作り直すだけ → dashboard/index.html をダブルクリックで開く
node dashboard/update.mjs --serve --host 0.0.0.0 --port 8787   # 同じ LAN のスマートフォンから見るとき（認証は無いので LAN 内だけ）
```

依存は Node の標準ライブラリだけ（npm install 不要、ビルド不要）。`git` は必須。`gh`（GitHub CLI、ログイン済み）・`bd`（Beads）は
無ければその項目が「取得できず」になるだけで、ほかは表示される。1 回の生成は数秒。

**ターミナルが要る理由**：表示する中身（git の状態・CI・Beads）はブラウザからは読めない。`--serve` で起動した Node のプロセスがブラウザの代わりに
git / gh / bd を実行し、開き直し（10 秒より古ければ）とハブからの `POST /update` を受けて `data.js` を作り直す。起動は 1 回でよく、閉じるまで動き続ける。

**複数のリポジトリをまとめて見るとき**は、apps-workflow の `hub.mjs` を 1 本起動する（コマンドは apps-workflow の `dashboard` スキルにある）。
`http://localhost:8790/` に一覧、`/<このリポジトリのディレクトリ名>/` にこの画面が出る。ポートは 1 つで済み、このリポジトリで `--serve` する必要は無い。

## 画面の並び（上ほど重要）と取得元

説明の文・欄の名前・種類の札は出さず、並びと大きさで読ませる。文章は一覧用に短く縮めて 1 行で出す（括弧書き・記法・2 文目以降を落とす）。
全文・付箋 ID・行番号はマウスを載せると出る。押すと全文に切り替わる（スマートフォン向け）。

| 表示 | 取得元（正本） |
|---|---|
| 異常の帯（CI 失敗・HANDOFF の遅れ・取得失敗・固有の指標の異常）。異常が無ければ出ない | 下の各正本から機械的に導く |
| あなた待ち（判断・確認・作業のタグつき。上位 6 件、残りは「ほか N 件」） | Beads `bd list --json`（このプロジェクトの epic 配下でラベル `human`）、`TODO.md`「確認待ち」節の未完、固有の「人が決めるもの」 |
| 進捗の帯（済み／全体）・今のフェーズ・今のタスク（大きく）とこの後 4 件 | `TODO.md` の未完タスク（上から順） |
| 開いている PR とその CI、最近のコミット 6 件（main の CI の結果は行の先頭の記号 ✓ ✕ ● ） | `gh pr list` / `gh run list` / `gh run view --json jobs` / `git log` |
| 固有の指標 | **（ここをこのリポジトリの内容に書き換える。`update.mjs` の `readProjectSpecific()`）** |
| 折りたたみ：引き継ぎメモ全文・最近の合意・Claude 側の付箋・未コミットのファイル（あるときだけ）。固有の指標の出力はそのカードの中 | `HANDOFF.md`・`logs/decisions.md`・Beads・`git status` |

進捗の数え方は todo-progress（apps-workflow が依存する公開版）の `progress.sh` と同じ（`##` 見出し = フェーズ、「確認待ち」「保留」「公開後」の節は合計から外す）。

## 更新と自動化

- 横断タスクボード：ops の会話で「ダッシュボード更新して」と頼む（`build_board_dashboards.py` が作り直して載せ直す）
- 手元：`--serve` 中は開き直す。ファイルを直接開く使い方なら `node dashboard/update.mjs` を実行して再読込
- フック等での自動更新は入れていない。配信モードが開くたびに正本を読み直すので、別の更新経路を足しても同じ結果を二重に作るだけ
- `dashboard/data.js` は派生物なので `.gitignore` 済み。コミットしない

## 構成

```
dashboard/
  index.html   画面。data.js を読んで描く（HTML + CSS + 素の JS、ライブラリなし。ダブルクリックで開ける）。固有の指標の形が違うときは ★ specific() で変換
  update.mjs   データ生成と配信（Node 標準ライブラリだけ）。固有の指標は readProjectSpecific() に書く
  data.js      生成物（`window.DASHBOARD_DATA = {...}`。git 管理外）
  README.md    これ
```

## 直すとき

`TODO.md` の見出しの使い方（`##` = フェーズ、「確認待ち」「保留」）、`HANDOFF.md` の節名、CI のジョブ名、Beads の題名規約（`[<プロジェクト名>] ...`）を
変えたら `update.mjs` の該当する読み取り関数を直す。固有の指標を足すときは `readProjectSpecific()` の返す形に足す（`index.html` はその形をそのまま描く）。
