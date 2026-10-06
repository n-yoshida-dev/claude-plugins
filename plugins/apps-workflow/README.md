# apps-workflow

`~/workspace/apps/` 配下の自作アプリで共通に使う開発ワークフロー。
HANDOFF / PLAN / SPEC / TODO / KNOWLEDGE / `logs/decisions.md` のドキュメント体系と、`frontend/`（React + TS）/ `backend/`（Go）の
ディレクトリ構成を前提にしている。

## 中身

| 種別 | 名前 | 何をするか |
|---|---|---|
| フック（PreToolUse: Bash） | `hooks/guard-secrets.sh` | `git add` / `commit` / `stash` の直前にステージ済みファイルを検査し、秘密情報・ローカル専用ファイルがあれば exit 2 でブロックする |
| フック（PostToolUse: Edit/Write） | `hooks/check-edited.sh` | `frontend/*.ts(x)` を編集したら typecheck と eslint、`backend/*.go` なら `go vet`。結果は `additionalContext` で返すだけでブロックしない |
| フック（SessionStart） | `hooks/session-briefing.sh` | `hooks/progress.sh` の進捗表と `TODO.md` の `- [ ]` 行（先頭12件）を context に流し込み、進捗表を最初の返答で見せるよう指示する。`logs/decisions.md` があればその案内も出す |
| 集計（フックとスキルから呼ぶ） | `hooks/progress.sh` | `TODO.md` のチェックボックスをフェーズ（`##` 見出し）ごとに数え、進捗バー・残り件数・前回の区切り（HANDOFF.md の最終コミット）からの増減をコードブロックで出す。見出しに「確認待ち」「保留」を含む節は合計に入れず別枠。単体で `bash hooks/progress.sh <dir>` と叩ける |
| スキル | `/apps-workflow:progress` | 進捗表をその場で見せる。「どこまで進んだ？」「残りは？」に答える |
| スキル | `/apps-workflow:handoff` | セッションの区切りに HANDOFF（進捗表 + 現在地）/ TODO / KNOWLEDGE / `logs/decisions.md` を更新する。進捗表は TODO 更新後に集計して「## 進捗」節を丸ごと置き換える。**Claude が区切りで、ユーザーに聞かずに自分で呼ぶ**（作業の PR の受け入れレビューを呼ぶ前に同じ PR へ入れる・判断待ちで止まるときや分けたほうがよいとき・ユーザーが区切りを告げたとき。引き継ぎだけの PR は区切りに数えない。書き終えて続けられるならそのまま次へ進む。v1.4.2 でユーザー起動限定を外し、v1.5.6 で「分割の提案に同意したとき」から「区切りごと」に変えた。きっかけの利用者の発言の原文は skill-matrix の `logs/decisions.md` 2026-10-04。呼ぶ場面の切り方と「作業の PR に入れる」形は、その発言から Claude が選んだもので、利用者は未確認。作業の PR に入れるのは、引き継ぎだけの PR を別に作ると PR・CI・レビュー・ブランチ削除の承認が倍になり、発言の「やり取り増えるだけでは？」に反するため）。ユーザーが `/apps-workflow:handoff` と打ってもよい |
| スキル | `/apps-workflow:pr-check` | CI と同じ検査（`scripts/check-*.sh` → 秘密情報 → frontend → backend）をローカルでまとめて回す |
| スキル | `/apps-workflow:pr-flow` | PR の作成からマージまでの手順（検査 → PR 本文 → CI の待ち方 → acceptance-reviewer → Codex のクラウドレビューの指摘 → マージ → 後始末）。Codex の指摘は Claude がコードで確かめ、明らかな誤りは直して報告、仕様・方針に関わるものと当たらないものはユーザーに聞く（v1.5.7）。Codex の見張りは「Codex Review Summary」のまとめのコメントを指摘に数えず、状態だけ表示する（v1.10.1。数えるとレビュー中に抜けていた）。Claude が PR を作る・マージするときに呼ぶ。ルール本体は apps ルート CLAUDE.md |
| スキル | `/apps-workflow:dashboard` | 人間が開発状況（進捗・あなた待ち・今のタスク・CI・最近の変更・固有の指標）を 1 画面で見る「開発ダッシュボード」を、そのリポジトリ用に作る手順とテンプレート（`skills/dashboard/template/` の `update.mjs` / `index.html` / `README.md`）。「ダッシュボードを作りたい」「開発状況を見える化したい」で呼ぶ。方針（正本を読んで描くだけ・文章は 1 行・起動方法と更新ボタンをヘッダーに・依存 0）は共通で、見た目と固有の指標はリポジトリごとに変えてよい（v1.5.0）。`skills/dashboard/hub.mjs` を 1 本起動すると、全リポジトリのダッシュボードを `http://localhost:8790/` にまとめて配信する（v1.5.1） |
| スクリプト | `scripts/codex-run.sh` | Codex を毎回同じ条件で呼ぶ共通の入口。モデルと考える深さは、用途（`--use design` など）で下の表から引くか、`-m` と `-e` で両方指定する。どちらも無ければ codex を呼ばずに止める（v1.7.0。v1.6.0 の既定 `gpt-6-astra` はやめた）。サンドボックス（`read-only` か `workspace-write`。必須）も必ず明示し、`--ignore-user-config --disable memories` で Codex 側の設定とメモリを切り離す。依頼文はファイルから標準入力で渡し、返答は codex が成功したときだけ `-o` のファイルに置く。標準出力は「結果・thread_id・使用量」の 3 行（モデルの知らせがあれば 4 行目に件数）。既定で `--ephemeral`（記録を残さない）。続きを聞く（`--resume <thread_id>`）予定の回は `--keep-session` を付ける。指定の誤りは codex を呼ぶ前に終了コード 2 で止める（v1.6.0）。`--deny-read-list <一覧>`（`-s read-only` のときだけ）で、一覧の場所を Codex に読ませない権限のプロファイル（全体は読み取りだけ、一覧の場所は deny）を渡す。Codex の読み取り専用は、そのままだと作業フォルダの外もどこでも読めるため（2026-10-05 に確かめた。v1.9.0）。`-i <画像>`（何回でも）で依頼に画像を添える。新しく頼むときだけで、codex の `-i` が複数のファイルを受け取るので `--` で区切ってから標準入力の `-` を渡す（v1.10.0。実機では未確認） |
| スクリプト | `scripts/codex-bin.sh` | codex の実行ファイルの場所を返す。環境変数 `CODEX_BIN` があればそれ、無ければ VS Code 拡張機能（openai.chatgpt）の中の最新版。PATH の codex は見ない（PATH に置くとラッパーを通らない呼び出しが Codex の既定の設定で走るため） |
| 一覧 | `config/codex-review-deny-read.txt` | codex-review で Codex に読ませない場所。ホームの直下すべて（`.vscode-server` は、codex の実行ファイルのある `extensions` だけ読める。編集の履歴のある `data` などは読ませない）・Windows のドライブ（`/mnt`）・Claude の作業用フォルダ（`/tmp/claude-<uid>`）。2026-10-06 に本番の `codex exec` で、一覧の場所を指すリンクの読み取りが「Permission denied」で止まることを確かめた。`*`・`!`（除外）・`~`・`{uid}` が使える（v1.9.0） |
| 表 | `config/codex-models.json` | 用途（`design` 設計の案・`screen` 画面の見本・`review` レビュー・`implement` 実装を任せる）ごとに、Codex のモデル・考える深さ・状態（未比較など）・理由と、確認日・出典を書く。モデル名は OpenAI が決める外部の値なので、スクリプトに直書きせずここに置く（v1.7.0） |
| スクリプト | `scripts/codex-models.sh` | 上の表を引く（`resolve <用途>`・`uses`）。`check` で表と Codex の手元のモデル一覧（`~/.codex/models_cache.json`）を照らし、新しいモデルが出た・表のモデルが消えた・表のモデルに廃止の予定が付いた、を知らせる。知らせるだけで表は書き換えない（v1.7.0） |
| プロンプト | `prompts/` | マルチモデル協調のスキルが使う、外部のリポジトリから写したプロンプトとスキーマ 7 つ（slot-machine のレビュー役 2・審査役 2（審査役の文章・設計案用は v1.10.0 で compete のために足した）、0-to-1-Labs/codex-pr-review の検証プロンプトと出力の形、Crazytieguy/codex-plugin-cc の plan-review）。本文は改変なしで、冒頭に出典の注記、各フォルダに元のライセンスの写し。一覧と使うときの注意は `prompts/README.md`、コミットと本文の sha256 は `prompts/sources.json`（v1.8.0） |
| テスト | `scripts/test-prompts.sh` | `prompts/` の出典とライセンスの表示を確かめる。ライセンスの写しがある・注記の出典がコミットと合う・改変なしのファイルの本文が元と同じ（sha256）・`sources.json` に載っていない写しが無い。CI でも回す（v1.8.0） |
| テスト | `scripts/test-codex-wrapper.sh` | 上の 3 本の回帰テスト。引数を記録するだけの偽の codex と、テスト用の表・モデル一覧を差し込むので、ChatGPT の利用枠を使わず、本物の表の中身にも左右されない（本物の表は形だけを確かめる）。CI でも回す |
| スキル | `/apps-workflow:codex-review <文書>` | 設計書・計画・仕様の文書を Codex（用途 `review` の表のモデル）に読み取り専用でレビューさせる（借りてきた `plan-review.md`）→ 指摘ごとに Fable が新しい文脈で文書と照らして確かめる（借りてきた検証プロンプト）→ 利用者が採否を決める → `logs/codex-review/` の台帳に残す → 頼まれたら同じ会話の続きで再レビュー。**利用者が打ったときだけ動く**（`disable-model-invocation`）。ops・personal の中・ルートに `data/` のあるリポジトリ・PRIVATE.md・`*.local.*`・`.env*`・gitignore の対象・文書でないファイルは送らない。**Codex の作業フォルダはリポジトリそのものではなく、Git で管理しているファイルだけの書き出し（/tmp/codex-review.…）で、`config/codex-review-deny-read.txt` の場所は読ませない**（Codex の読み取り専用は、そのままだと作業フォルダの中も外もどこでも読めるため。一覧の外の `/etc`・`/usr` などは読める）。コードの差分は GitHub の Codex クラウドレビューの担当で扱わない。GitHub への投稿も自動の修正もしない（v1.9.0） |
| スクリプト | `scripts/fill-prompt.sh` | プロンプトのテンプレートの差し込み口（`{{名前}}`）を、値かファイルの中身で埋める。冒頭の出典の注記を外し、埋め残し・テンプレートに無い名前があれば何も出さずに止める（v1.9.0） |
| スクリプト | `scripts/codex-review-target.sh` | codex-review に渡された文書が Codex に送ってよいものかを確かめ、文書とリポジトリのルートの絶対パスを返す。送らない場所は `~/workspace/ops` と `~/workspace/personal` がいつも入り、環境変数 `CODEX_DENY_ROOTS`（: 区切り）で足せる。シンボリックリンクは行き先で判定する（v1.9.0） |
| スクリプト | `scripts/codex-review-export.sh` | Codex に読ませる作業フォルダを、リポジトリの HEAD（`git archive`。gitignore の対象やコミットしていないファイルは入らない）に、レビューする文書の今の中身を重ねて作る。PRIVATE.md・`*.local.*`・`.env*` の名前のファイルとリンクは、管理している見本も外す（v1.9.0） |
| テスト | `scripts/test-codex-review.sh` | 上の 3 本と、codex-review の手順書の回帰テスト（手順書が指すファイルがある・Codex にリポジトリそのものを渡していない・引用の場所の扱いがそろっている）。CI でも回す（v1.9.0） |
| スキル | `/apps-workflow:compete <お題>` | 設計案（`design`）・画面案（`screen`）のコンペ。ブリーフを書いて Fable が点検 → Opus・Fable（Agent ツール）と Codex（用途 `design` / `screen`。読み取り専用で、ほかの作り手のフォルダは読ませない）が独立に 1 案ずつ → 作り手を伏せて A・B・C… → （設計案なら）割れた点だけ全員に同じ質問で反論 1 回 → 案ごとに Fable のレビュー役（借りてきた `writing-2-reviewer.md`）→ 系統の違う審査役 2 つ（Fable と Codex。借りてきた `writing-3-judge.md`。審査役ごとにレビューの並び順を乱数で変える）→ 節ごとに選べる比較ページ（非公開の Artifact）→ 利用者が選んだら作り手を明かして `docs/design-candidates/` と `logs/decisions.md` に残す。**利用者が打ったときだけ動く**。作り手は Workflow ツールでなく Agent ツールで起動する（Workflow は利用者の発言を全員に中継し、試行 3 で作り手が読んではいけない資料を読んだため）。Codex は OS の権限で読む場所を止めるが、Claude 側の作り手・レビュー役・審査役は指示だけで縛っている。コード実装のコンペは今はしない（判断文書の問い 6）（v1.10.0） |
| スクリプト | `scripts/compete-setup.sh` | コンペの作業場所（/tmp/compete.…）を作り、作り手ごとのフォルダ（名前は乱数の札。作り手の名前を出さない）にブリーフと材料を複製する。材料は Git で管理しているファイルと、調整役が撮った画像だけ。Codex の作り手と審査役に渡す「読ませない場所」の一覧（共通の一覧＋ほかの作り手のフォルダなど）も作る（v1.10.0） |
| スクリプト | `scripts/compete-blind.sh` | 作り手の成果物を乱数で A・B・C… に写し、元と写しの sha256 を比べる。伏せ字の対応は調整役のフォルダにだけ書く。成果物がそろわない案は外す。伏せ字どうしで中身が同じなら止める（試行 1 で 3 枠とも同じ案になったため）（v1.10.0） |
| スクリプト | `scripts/compete-check.sh` | 伏せた案に、モデル・会社の名前、禁止語（Private の原文の言い回しなど）、設計案の見出しの崩れが無いかを調べる。見つけても自動では消さない（v1.10.0） |
| スクリプト | `scripts/compete-brief.sh` | 作り手・レビュー役・審査役の依頼書を作る（自作の指示、または借りてきたプロンプト＋自作の追加の決まり）。受け取る側がファイルを書けない Codex なら、返事に本文を書かせる（v1.10.0） |
| スクリプト | `scripts/compete-rebuttal.sh` | 反論 1 回の依頼書を作り（作り手には自分の伏せ字だけを知らせる）、答えを伏せた案の横に集める。調整役は伏せ字の対応を見ずに回せる（v1.10.0） |
| スクリプト | `scripts/compete-unpack.sh` | Codex の画面案の返事（JSON）を `index.html` と `aim.md` に書く（v1.10.0） |
| スクリプト | `scripts/compete-page.mjs` | 節ごとに選べる比較ページを作る。設計案は見出しで節に切って横に並べ、画面案は枠の中で 1280px と 375px を切り替える。選ぶと「返す言葉」ができ、コピーできる。どの案も同じ色・同じ形（v1.10.0） |
| テスト | `scripts/test-compete.sh` | 上の 7 本と、compete の手順書の回帰テスト（93 件。Codex もモデルも呼ばない）。CI でも回す（v1.10.0） |
| エージェント | `apps-workflow:acceptance-reviewer` | マージ前に差分を TODO.md の「完了条件：」・SPEC.md・CLAUDE.md「守ること」に照らして検品する読み取り専用の評価役。判定（マージ可／直してから／ユーザー判断が要る）を返すだけで、直すのは呼び出し側 |

## 受け入れレビューの呼び方（マージ前）

CI は整形・型・テスト・ビルドしか見ないので、「動くが意図と違う」「未完成なのに完了扱い」は止められない。
それを止めるのが `acceptance-reviewer`。PR を作って CI を待つ間に、メインの Claude が Agent ツールで呼ぶ。

```
subagent_type: apps-workflow:acceptance-reviewer
prompt: BASE=main、PR #12 の差分を検品してください。対象タスクは TODO.md「年収の入力欄を変えると総資産グラフが再計算される」です。
```

- 読み取り専用。`tools` に Edit / Write が無く、Bash は `git diff` / `git log` / `gh pr view` などの読み取りに限る
  （定義ファイルの指示による制約。Bash 自体を機械的に読み取り専用にする仕組みは Claude Code に無い）
- 一般的なバグ探し・命名・性能は見ない。それは `/code-review` と `/simplify` の担当
- 判定が「直してから」なら直して push、「ユーザー判断が要る」なら報告して止まる。前後の手順は `/apps-workflow:pr-flow`

## Codex の呼び方（codex-run.sh）

```
bash "${CLAUDE_PLUGIN_ROOT}/scripts/codex-run.sh" --use review -s read-only -f 依頼書.md -o 結果.md -C <作業フォルダ>
```

- どのモデルで動くかは用途で決める。用途ごとのモデルは `config/codex-models.json`。表に無いモデルを試すときは `-m <モデル> -e <深さ>`
- 呼ぶたびに表と Codex の手元のモデル一覧を照らし、新しいモデルが出た・表のモデルが消えた・廃止の予定が付いたら、標準エラーに「知らせ」を出す
  （標準出力にも「知らせ: n 件」の 1 行）。**自動では乗り換えない**（新しいモデルが用途に合うとは限らず、使用量も変わるため。
  2026-10-02 に Codex の既定が Astra・最大の深さに変わり、1 回の依頼で利用上限に当たった例がある）。
  知らせを見た Claude は Beads に付箋を作り、用途ごとに比べてから表の model・effort・status・why と checkedAt を直す。
  比べ終えたモデルは、採らなかった場合も `knownModels` に足す（足さないと同じ知らせが出続ける）
- 2026-10-06 から、表は 4 用途とも `gpt-6.1-sol`・`medium`（v1.10.2）。それまでは 4 用途とも `gpt-6-astra`・`high` だった。
  本人の「Astraはやはりトークン使用量がとんでもないから、別のモデルを使う方針にしよう」と、Claude の提案への「OK」で変えた。
  根拠は Web の調べ（OpenAI のモデルの解説が Codex に `gpt-6.1-sol` を勧める・Astra とほぼ同じ賢さで単価は 1/5・Plus の 5 時間の目安は約 3 倍。Beads ops-h49.6）で、
  用途ごとに実物で比べてはいない。設計やレビューで見落としが目立ったら、その用途だけ考える深さを上げるか Astra に戻す

- スキルの本文からは上のように `${CLAUDE_PLUGIN_ROOT}` で指す。手で呼ぶときは、このリポジトリの写し
  `~/workspace/apps/claude-plugins/plugins/apps-workflow/scripts/codex-run.sh` を絶対パスで指す（導入先は版ごとにフォルダが変わるため）
- ChatGPT の利用枠を使うが、動かす前に了承は取らない（apps ルートの CLAUDE.md。2026-10-06 に「タスクごとに 1 回」からやめた）。利用上限に当たったら止めて報告する
- 時間がかかることがあるので、Claude は Bash のバックグラウンド実行で呼び、完了の通知を待つ
- ops と `data/` のある場所では使わない（Codex の中の操作には Claude 側のフックが効かない）
- 指定の一覧は `bash codex-run.sh --help`
- 実機で確かめたこと（2026-10-05、codex-cli 0.160.0）：読み取り専用の依頼、`--schema` 付きの依頼、`--resume` の 3 つが通る。
  会話の記録上もモデル `gpt-6-astra`・考える深さ `high`・サンドボックス `read-only`・承認 `never` で動いた。
  `--json` の出来事から thread_id（`thread.started`）と使用量（`turn.completed` の `usage`）を取り出せる。
  **`--resume` した回は `--ephemeral` を付けても元の会話の記録に追記される**（`~/.codex/sessions` に残る。消すかは利用者が決める）
- 未確認：サンドボックスが実際にどこまで書き込みを止めるか（以前 bubblewrap が無いという警告が出ていた。今回の 3 回では出ていない）

## 前提

- `jq`・`git` がある
- フックは `${CLAUDE_PROJECT_DIR}`（プロジェクトルート）を基準に `frontend/` `backend/` `TODO.md` を探す。
  無いものは黙ってスキップするので、初期化前のリポジトリに入れても害はない

## アプリ固有の検査を足したいとき

このプラグインは変更せず、アプリ側の `.claude/settings.json` にフックを追加する
（例：babyfood-check の `check-safety-words.sh`）。プラグインのフックとアプリのフックは両方動く。
