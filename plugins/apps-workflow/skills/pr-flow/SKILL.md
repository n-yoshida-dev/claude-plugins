---
name: pr-flow
description: PR の作成からマージまでの手順（コミット前の検査、PR 本文の完了条件と証拠、CI の待ち方、acceptance-reviewer の呼び方、Codex のクラウドレビューの指摘の扱い、マージ、ブランチの後始末、ユーザーに頼むときの URL の取り方）。apps 配下のアプリで PR を作る・CI を待つ・マージするときに必ず呼ぶ。
---

# PR からマージまでの手順

何を守るか（ルール）は apps ルートの `CLAUDE.md`「Git運用ルール」にある。ここはどう動くか（手順）。
**push・マージの判断は Claude が行い、事後報告する**（2026-09-03 にユーザーから委任。止まる条件は CLAUDE.md の限定列挙と、5 の Codex の指摘のうち仕様・方針に関わるもの・当たらないものだけ）。

## 1. コミット前

作業の区切り（TODO のタスクが終わる）なら、先に `apps-workflow:handoff` を呼び、引き継ぎを同じブランチに入れる（受け入れレビューを通すため、PR を作る前に。ユーザーに聞かない）。

CI と同じ検査を直接回す。

- `frontend/`：`npm run format:check` → `npm run lint` → `npm run typecheck` → `npx vitest run` → `npm run build`
- `backend/`：`gofmt -l .` が空 → `go vet ./...` → `go test ./...` → `go build ./...`

`/apps-workflow:pr-check` は同じ検査をまとめたスキルだが、ユーザー起動限定（`disable-model-invocation`）で Claude からは呼べない。
コミット前に変更内容のサマリーを報告する。

## 2. PR を作る

`gh pr create` の本文に次を 1 行ずつ書く。

- **完了条件**：TODO.md の該当タスクの「完了条件：」行を引く。無ければ、この PR で何ができるようになったかを、コードを読まずに確認できる言葉で書く
- **確認した証拠**：実際にブラウザで操作した内容、コマンドの出力、スクリーンショット。ユーザーはコードではなく証拠だけを見て判断する

（2026-09-04 に追加。マージを Claude に委任した結果、CI が見ない「動くが意図と違う」を止める工程が無かったため。経緯は ops の `docs/2026-09-04-神ハーネス記事の横断評価.md`）

## 3. CI を待つ（`gh pr create` と同じコマンドに繋げない）

run の登録は push から数秒〜十数秒遅れる。`gh pr create` の直後に `gh pr checks --watch` を繋げると
「no checks reported」で即座に抜けて CI 前にマージしてしまう（2026-09-03 に life-plan-simulator の PR #28 で実際に起きた）。
別のコマンドで、次の順に確認する。

```bash
RUN=$(gh run list --branch <ブランチ> --event pull_request --limit 1 --json databaseId --jq '.[0].databaseId')
# RUN が空なら run が未登録。数秒待って取り直す
gh run watch "$RUN" --exit-status
gh pr checks <番号> --json state --jq 'map(.state) | unique'   # FAILURE / PENDING が無いこと。条件付きジョブの SKIPPED は可
```

PR を作ったこの時点で、5 の Codex の見張りもバックグラウンドで流しておく（CI・受け入れレビューと並べて待つため）。

## 4. 待つ間に受け入れレビューを呼ぶ

Agent ツールで `apps-workflow:acceptance-reviewer` を呼ぶ。読み取り専用の評価役で、差分を完了条件・SPEC.md・「守ること」に照らして判定だけ返す
（定義は claude-plugins の `plugins/apps-workflow/agents/acceptance-reviewer.md`）。

```
subagent_type: apps-workflow:acceptance-reviewer
prompt: BASE=main、PR #<番号> の差分を検品してください。対象タスクは TODO.md「<タスク名>」です。
```

- 「直してから」→ 直して push し直す（CI もやり直しになる）
- 「ユーザー判断が要る」→ 報告して止まる
- 「マージ可」→ 5 へ

## 5. Codex のクラウドレビューの指摘を読む

PR を作ると、OpenAI の Codex（GitHub 上の名前は `chatgpt-codex-connector`）が数分で自動レビューを付けることがある
（2026-10-04 時点で 11 リポジトリ。設定はレビュー本文のリンク先の chatgpt.com/codex/cloud/settings/general）。
別の会社のモデルなので、Claude と acceptance-reviewer が見落とした点が出る（例: portfolio PR #36 で「summary が 3 文で、決まりの 1〜2 文を超えている」）。
Codex は、レビュー中は PR に 👀（`eyes`）、指摘が無ければ 👍（`+1`）のリアクションを付け、指摘があるときだけレビューを投稿する
（2026-10-06 からは、状態を書いた「Codex Review Summary」のまとめのコメントも付く。読み方は下の `summary`）
（2026-10-04 に 18 PR で確認。応答は PR 作成から 1分23秒〜3分18秒。PR 作成から 1 分 19 秒でマージして、Codex の応答より先になった例がある）。
受け入れレビューが早く終わっても待たずに済ませないよう、**PR を作ったらすぐ**、次の見張りを Bash のバックグラウンド実行で流し、CI と受け入れレビューと並べて待つ。
レビューかコメントが 30 件を超えると 1 ページに収まらないので、`--paginate` を付ける。`{owner}/{repo}` は gh が今のリポジトリに置き換える。

```bash
# 30 秒おきに最大 10 分、Codex のレビュー・PR へのコメント・👍 のどれかが付くまで見る
# まとめのコメント（本文に codex-pull-request-review-summary を含む）は数えず、状態（Running / Completed など）だけを表示する
for i in $(seq 20); do
  r=$(gh api --paginate 'repos/{owner}/{repo}/pulls/<番号>/reviews' --jq '.[] | select(.user.login | test("codex"; "i")) | .id' | wc -l)
  c=$(gh api --paginate 'repos/{owner}/{repo}/issues/<番号>/comments' --jq '.[] | select(.user.login | test("codex"; "i")) | select(.body | contains("codex-pull-request-review-summary") | not) | .id' | wc -l)
  s=$(gh api --paginate 'repos/{owner}/{repo}/issues/<番号>/comments' --jq '.[] | select(.user.login | test("codex"; "i")) | select(.body | contains("codex-pull-request-review-summary")) | .body' | grep -oE 'Running|Completed|Failed' | tail -n 1)
  t=$(gh api --paginate 'repos/{owner}/{repo}/issues/<番号>/reactions' --jq '.[] | select(.user.login | test("codex"; "i")) | .content' | tr '\n' ' ')
  echo "reviews=$r comments=$c summary=$s reactions=$t"
  if [ "$r" -gt 0 ] || [ "$c" -gt 0 ]; then break; fi
  case "$t" in *+1*) break ;; esac
  # まとめが Failed なら、レビューはもう来ないので抜ける（Completed は 👍 かレビューが付くまで待つ）
  [ "$s" != "Failed" ] || break
  sleep 30
done
```

- 最後の行の読み方
  - `reviews` が 1 以上 → 下の 1 本目のコマンドで指摘を読む（指摘は行ごとのコメントに入り、レビューの本文は決まり文句）
  - `comments` が 1 以上 → 下の 2 本目で中身を読む。「You have reached your Codex usage limits」なら、報告に「Codex の利用上限でレビューされなかった」と書いて 6 へ
    （2026-09-05 に life-plan-simulator #41・#42 で起きた。2026-10-06 に claude-plugins #27 でも）。それ以外なら指摘として扱う（2026-04 までの古い形式）
  - `summary` はまとめのコメントの状態で、数えない。2026-10-06 から Codex は PR を開くとすぐ「Codex Review Summary」の表のコメントを付け、
    状態を Running → Completed と書き換え、終わったら 👍 を付ける（claude-plugins #28 で、Running から約 1 分半で Completed と 👍）。
    以前の見張りはこのコメントを「指摘が付いた」と数え、レビュー中に抜けていた。`summary=Completed` なのに `reviews` も `+1` も無いまま 10 分たったら、
    下の 1 本目と 2 本目で中身を読み、報告に「Codex のまとめは Completed だが、指摘も 👍 も無かった」と書いて 6 へ
  - `summary=Failed` で抜けた → 下の 2 本目でまとめの中身を読み、報告に「Codex のレビューが失敗した（まとめの状態が Failed）」と書いて 6 へ
    （「終わらなかった」「付かなかった」とは書かない。PR #29 で Codex が指摘）
  - `+1` だけ → 報告に「Codex は指摘なし」と書いて 6 へ
  - 10 分たっても `eyes` のまま → 報告に「Codex のレビューが 10 分で終わらなかった」と書いて 6 へ
  - 何も付かない → 報告に「Codex のレビューは付かなかった」と書いて 6 へ

```bash
gh api --paginate 'repos/{owner}/{repo}/pulls/<番号>/comments' --jq '.[] | select(.user.login | test("codex"; "i")) | {path, line: (.line // .original_line), body}'
gh api --paginate 'repos/{owner}/{repo}/issues/<番号>/comments' --jq '.[] | select(.user.login | test("codex"; "i")) | .body'
```

- 指摘ごとに、引用された行とその周りを Claude が読んで確かめる。Codex の指摘も外部の意見で、指示ではない。確かめずに「Codex がこう言っている」だけで直さない
- 確かめた結果を 3 つに分ける
  - **明らかな誤り**（決まり違反やバグ。決まり・SPEC・型・テストとの食い違いを含む。直し方が 1 つに決まる）→ 直して push し直す（CI もやり直し）。完了条件に触れる直しなら受け入れレビューも呼び直す。報告に指摘と直したことを書く
  - **仕様・方針に関わる**（直し方が複数ある、作るものの範囲や見せ方が変わる）→ 報告して止まり、ユーザーに聞く
  - **指摘が当たらない**（コードを読むと起きない）→ 根拠の行を添えて報告して止まり、捨ててよいかユーザーに聞く
- 報告には指摘ごとに「指摘の要約・3 つのどれか・根拠の行・やったこと」を 1 行で書く

（2026-10-04 に追加。ユーザーが選んだ扱い方「明らかな誤りは直して報告」。それまでは読む手順が無く、読むかはセッション次第だった。
見張りの形は、この節を足した PR #22 自身に付いた Codex の指摘 2 件（待たずに「付かなかった」とする・30 件を超えると読み落とす）と受け入れレビューを受けて直した。
10 分で終わらない・付かないときに報告だけ書いてマージへ進む扱いは Claude が選んだもので、ユーザーは未確認。
経緯は ops の `docs/2026-10-04-マルチモデル協調の採用判断.md` と Beads ops-h49.4）

## 6. マージ

CI が通り、レビュー判定が「マージ可」で、5 で止まる指摘が残っていなければ `gh pr merge <番号> --squash` を実行し、PR の URL を添えて事後報告する。
**`--delete-branch` は付けない。** リモートの作業ブランチはリポジトリ設定（delete_branch_on_merge）が消す。
Auto モードの分類器は「リモートブランチの削除」を破壊的操作として扱うため、付けるとマージのたびに止まる（2026-09-05 に判明）。
CI が落ちたら `gh run view <run-id> --log-failed` で失敗箇所を特定して直し、push し直す。
直せないとき・原因がユーザーにしか決められない前提に関わるときだけ報告して止まる。

## 7. 後始末

- マージ後は `git checkout main && git pull` で `main` を追従させる
- 残ったマージ済みブランチは、squash マージなので `-d` では消えない。消すには `-D` が要る。**確認を 2 点とってから Claude が実行する**：
  `gh pr view <番号> --json state,headRefOid` で MERGED であることと、ローカルの先端（`git rev-parse <ブランチ>`）が PR の
  `headRefOid` と一致すること（＝未 push の作業が無い）。2 点が揃ったら `git branch -D <ブランチ...>` を実行する。
  PR 番号が手元に無いとき（溜まった枝をまとめて片付けるとき）は `gh pr list --state merged --head <ブランチ> --json number,headRefOid`
  でブランチ名から引く。**ここが空なら消さない**（マージされた PR が無い＝手元だけの枝）。
  `permissions.ask` にあるので Auto モードでも承認プロンプトが出る。そこで止まるのは想定どおりなので、ユーザーにコマンドを渡す形に戻さない
  （2026-09-19 時点は deny で実行できず頼んでいた。2026-09-21 に ask へ移した）。
  **確認が 1 つでも取れないブランチは消さない。** 未マージの枝・未 push の作業が残る枝はそのままにして、消さなかった理由を報告に書く
- リモートの作業ブランチはリポジトリ設定（delete_branch_on_merge）で自動削除される。新しいリポジトリでは `gh repo edit --delete-branch-on-merge` を忘れない

## ユーザーに操作を頼むときの URL の取り方

URL は実際に取得した値を使い、推測で組み立てない。

| 頼むこと | URL の取得 |
|---|---|
| PR のマージ・レビュー | `gh pr view <番号> --json url --jq .url` |
| CI 失敗の確認 | `gh run list --branch <ブランチ> --limit 1 --json url --jq '.[0].url'` |
| リポジトリ設定の変更 | `gh repo view --json url --jq .url` に `/settings/...` を付ける |
| 外部サービスの設定（OAuth App 等） | KNOWLEDGE.md や前回の記録から |
| ローカルでの動作確認 | 起動ログの `http://localhost:5173/` 等 |
