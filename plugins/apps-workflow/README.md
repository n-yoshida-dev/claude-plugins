# apps-workflow

`~/workspace/apps/` 配下の自作アプリで共通に使う開発ワークフロー。
HANDOFF / PLAN / SPEC / TODO / KNOWLEDGE / `logs/decisions.md` のドキュメント体系と、`frontend/`（React + TS）/ `backend/`（Go）の
ディレクトリ構成を前提にしている。

## 中身

| 種別 | 名前 | 何をするか |
|---|---|---|
| フック（PreToolUse: Bash） | `hooks/guard-secrets.sh` | `git add` / `commit` / `stash` の直前にステージ済みファイルを検査し、秘密情報・ローカル専用ファイルがあれば exit 2 でブロックする |
| フック（PostToolUse: Edit/Write） | `hooks/check-edited.sh` | `frontend/*.ts(x)` を編集したら typecheck と eslint、`backend/*.go` なら `go vet`。結果は `additionalContext` で返すだけでブロックしない |
| フック（SessionStart） | `hooks/session-briefing.sh` | `TODO.md` の `- [ ]` 行を先頭12件まで context に流し込む。`logs/decisions.md` があればその案内も出す |
| スキル | `/apps-workflow:handoff` | セッションの区切りに HANDOFF（現在地のみ）/ TODO / KNOWLEDGE / `logs/decisions.md` を更新する |
| スキル | `/apps-workflow:pr-check` | CI と同じ検査（`scripts/check-*.sh` → 秘密情報 → frontend → backend）をローカルでまとめて回す |
| スキル | `/apps-workflow:pr-flow` | PR の作成からマージまでの手順（検査 → PR 本文 → CI の待ち方 → acceptance-reviewer → マージ → 後始末）。Claude が PR を作る・マージするときに呼ぶ。ルール本体は apps ルート CLAUDE.md |
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

## 前提

- `jq`・`git` がある
- フックは `${CLAUDE_PROJECT_DIR}`（プロジェクトルート）を基準に `frontend/` `backend/` `TODO.md` を探す。
  無いものは黙ってスキップするので、初期化前のリポジトリに入れても害はない

## アプリ固有の検査を足したいとき

このプラグインは変更せず、アプリ側の `.claude/settings.json` にフックを追加する
（例：babyfood-check の `check-safety-words.sh`）。プラグインのフックとアプリのフックは両方動く。
