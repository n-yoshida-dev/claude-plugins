---
name: pr-check
description: コミット・PR の前に、CI と同じ検査をローカルでまとめて実行する。
disable-model-invocation: true
---

## 現在の状態

- ブランチ: !`git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "(不明)"`
- 変更のあったファイル: !`git status --short 2>/dev/null || echo "(なし)"`
- アプリ固有の検査スクリプト: !`ls scripts/check-*.sh 2>/dev/null | tr '\n' ' ' || echo "(なし)"`
- DB コンテナ: !`docker compose ps --status running --format '{{.Service}}' 2>/dev/null | tr '\n' ' ' || echo "(未起動)"`

## やること

下の検査を上から順に実行し、**失敗したらそこで止めて原因を報告する**。
勝手に直さない。何をどう直すかを提示してから、ユーザーの指示で直す。

対象が無い検査は飛ばす（`frontend/` や `scripts/` がまだ無い段階があるため）。
飛ばしたことは報告に必ず書く。

### 1. アプリ固有の検査（`scripts/check-*.sh` がある場合・最優先）

`scripts/check-*.sh` を名前順にすべて実行する。これらは CI でも同じものが呼ばれる前提のスクリプト。

```bash
for f in scripts/check-*.sh; do echo "== $f"; bash "$f" || exit 1; done
```

### 2. 秘密情報の混入

```bash
git ls-files | grep -E '(^|/)(PRIVATE\.md|CLAUDE\.local\.md|\.env(\..+)?)$|\.local\.(json|md)$|(^|/)(secrets|data/private)/|(^|/)credentials\.json$|\.(pem|key|p12|keystore)$' | grep -v '\.env\.example$'
```

何も出力されなければ問題なし（正規表現は CI の no-secrets ジョブおよび guard-secrets フックと同じ）。

### 3. frontend（`frontend/package.json` がある場合・`frontend/` で実行）

```bash
npm run format:check && npm run lint && npm run typecheck && npm run test && npm run build
```

### 4. backend（`backend/go.mod` がある場合・`backend/` で実行）

```bash
test -z "$(gofmt -l .)" && go vet ./... && go build ./...
```

テストは DB 接続の有無で実行方法が変わる。

- ルートの `.env` に `TEST_DATABASE_URL` がある場合：DB を使うテストを含む。
  DB が起動していなければ `docker compose up -d --wait` を先に実行してよいか確認する。
  `.env` の中身は**表示せず**、読み込むだけにする

  ```bash
  set -a && . ../.env && set +a && go test ./...
  ```

- それ以外：そのまま実行する

  ```bash
  go test ./...
  ```

## 報告のしかた

- 全部通ったら「すべて通過」と、実行したコマンドの一覧を書く
- 失敗したら、失敗したコマンドと出力をそのまま示す。「たぶん大丈夫」で済ませない
- 検査を飛ばした場合は、何をなぜ飛ばしたかを必ず書く
