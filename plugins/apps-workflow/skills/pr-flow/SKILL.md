---
name: pr-flow
description: PR の作成からマージまでの手順（コミット前の検査、PR 本文の完了条件と証拠、CI の待ち方、acceptance-reviewer の呼び方、マージ、ブランチの後始末、ユーザーに頼むときの URL の取り方）。apps 配下のアプリで PR を作る・CI を待つ・マージするときに必ず呼ぶ。
---

# PR からマージまでの手順

何を守るか（ルール）は apps ルートの `CLAUDE.md`「Git運用ルール」にある。ここはどう動くか（手順）。
**push・マージの判断は Claude が行い、事後報告する**（2026-09-03 にユーザーから委任。止まる条件は CLAUDE.md の限定列挙だけ）。

## 1. コミット前

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

## 5. マージ

CI が通り、レビュー判定が「マージ可」なら `gh pr merge <番号> --squash --delete-branch` を実行し、PR の URL を添えて事後報告する。
CI が落ちたら `gh run view <run-id> --log-failed` で失敗箇所を特定して直し、push し直す。
直せないとき・原因がユーザーにしか決められない前提に関わるときだけ報告して止まる。

## 6. 後始末

- `--delete-branch` を作業ブランチ上で実行すると、リモート・ローカルの作業ブランチ削除と `main` への切り替えまで gh がやる。あとは `git pull`
- 別の理由で残ったマージ済みブランチは、squash マージなので `-d` では消えない。`gh pr view <番号> --json state` で MERGED を確認してから `-D` で消す（削除前にユーザーに確認）
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
