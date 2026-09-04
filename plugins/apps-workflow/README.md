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

## 前提

- `jq`・`git` がある
- フックは `${CLAUDE_PROJECT_DIR}`（プロジェクトルート）を基準に `frontend/` `backend/` `TODO.md` を探す。
  無いものは黙ってスキップするので、初期化前のリポジトリに入れても害はない

## アプリ固有の検査を足したいとき

このプラグインは変更せず、アプリ側の `.claude/settings.json` にフックを追加する
（例：babyfood-check の `check-safety-words.sh`）。プラグインのフックとアプリのフックは両方動く。
