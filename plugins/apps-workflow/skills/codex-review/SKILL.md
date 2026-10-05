---
name: codex-review
description: 設計書・計画・仕様の文書を Codex（用途 review の表のモデル。2026-10 時点は GPT-6 Astra）に読み取り専用で厳しくレビューさせ、指摘を別の系統（Fable）が文書と照らして確かめ、利用者が採否を決めて台帳 logs/codex-review/ に残す。利用者が /apps-workflow:codex-review <文書のパス> と打ったときだけ動く。コードの差分のレビューは GitHub の Codex クラウドレビュー（pr-flow 5 節）の担当で、ここでは扱わない。GitHub への投稿も自動の修正もしない。
disable-model-invocation: true
argument-hint: <レビューする文書のパス>
---

# Codex に設計書をレビューさせる

対象の文書：$ARGUMENTS

流れは「対象の確認 → Codex がレビュー → 別の系統が指摘を確かめる → 利用者が採否 → 台帳 → （頼まれたら）直して再レビュー」。
方針の出どころは ops の `docs/2026-10-04-マルチモデル協調の採用判断.md` §7「目的 2: 相互レビュー」と §8 手順 6。

## 0. 前提

- **ChatGPT の利用枠を使う。** 利用者がこのスキルを打ったことを、この文書のレビューで Codex を使う了承とみなす。
  使うのは、2 のレビュー 1 回と、利用者が頼んだときの 6 の再レビューだけ
- 対象の文書が空（`$ARGUMENTS` が空）なら、どの文書をレビューするかを利用者に普通の文で聞いて止まる
- 作業ファイル（依頼書・結果・出来事の記録）は、Claude の scratchpad（無ければ `mktemp -d`）にレビューごとのフォルダを作って置く。リポジトリには置かない。
  以下、そのフォルダを `W` と書く

## 1. 対象を確かめる

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/codex-review-target.sh" "<文書のパス>"
```

- 終了コード 0 なら、標準出力の「文書の絶対パス<TAB>リポジトリのルート」を控える。以下 `DOC` と `ROOT`
- 終了コード 2 なら、表示された理由を利用者にそのまま伝えて止まる。**別のパスやコピーで送り直さない**
  （ops の中・ルートに `data/` のあるリポジトリ・PRIVATE.md・`*.local.*`・`.env*`・gitignore の対象・文書でないファイルを止めている）

## 2. Codex にレビューさせる

依頼書を作る（借りてきた `plan-review.md` の `{{PLAN_CONTENT}}` に文書の中身を入れる。冒頭の出典の注記は外れる）。

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/fill-prompt.sh" "${CLAUDE_PLUGIN_ROOT}/prompts/crazytieguy-codex-plugin-cc/plan-review.md" PLAN_CONTENT=@"$DOC" > "$W/brief.md"
```

Codex を呼ぶ。**Bash のバックグラウンド実行**で流し、完了の通知を待つ。通知が届く前に結果を書いたり、終わったと言ったりしない。

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/codex-run.sh" --use review -s read-only -f "$W/brief.md" -o "$W/review.md" -C "$ROOT" --keep-session --events "$W/events.jsonl"
```

- `--keep-session` は 6 の再レビュー（同じ会話の続き）のため。標準出力の `thread_id` と `使用量` を控える
- 標準出力に「知らせ: n 件」が出たら（新しいモデル・廃止の予定など）、標準エラーの本文を利用者に伝え、Beads に付箋を作る（`config/codex-models.json` を比べて直すかの判断）
- 失敗したら（終了コード 1）、理由を伝えて止まる。勝手に考える深さやモデルを変えてやり直さない

## 3. 指摘を分けて、別の系統に確かめさせる

`$W/review.md` を読み、指摘を `R1`・`R2`… に分ける。指摘ごとに、重さ（P0〜P2）・引用された文・何が起きるか・直し方を控える。
指摘が無ければ（「そのまま進めてよい」という返事なら）、4 を飛ばして 5 の台帳に「指摘なし」と書く。

指摘ごとに確かめ役の依頼書を作る。

1. 引用された文が文書の何行目にあるかを `grep -n` で探す。見つからなければ、行番号は 0 にする（確かめ役が「引用が文書に無い」と判断できるように）
2. `$W/R<n>.json` に指摘を書く：
   `{"id":"R1","severity":"P1","code_location":{"path":"<ROOT からの相対パス>","line_start":12,"line_end":14},"quote":"<引用>","body":"<何が起きるか・直し方>"}`
3. 行番号つきの文書を `cat -n "$DOC" > "$W/doc-numbered.txt"` で作る。差分の欄には `printf '差分なし（文書の今の中身をレビューした）\n' > "$W/no-diff.txt"` を使う
4. 依頼書を作る：

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/fill-prompt.sh" "${CLAUDE_PLUGIN_ROOT}/prompts/codex-pr-review/verifier-claude-prompt.md" REVIEW_RULES=@"${CLAUDE_PLUGIN_ROOT}/skills/codex-review/verify-rules.md" FINDING=@"$W/R1.json" FILE_PATH="<ROOT からの相対パス>" FILE_CONTENT=@"$W/doc-numbered.txt" DIFF_HUNK=@"$W/no-diff.txt" > "$W/verify-R1.md"
```

確かめ役は **Agent ツールで、`model` に `fable` を指定し、指摘 1 件につき 1 体を新しい文脈で**呼ぶ（全件を 1 つのメッセージで並べて同時に）。
`subagent_type` は `general-purpose`、プロンプトは `$W/verify-R<n>.md` の中身に「作業フォルダは <ROOT>。ファイルは読むだけで、書かない。最終メッセージは JSON 1 つだけ」を添える。

- 対象の文書を Fable が書いたときは、`model` を `opus` にする（書き手と確かめ役を分けるため。prompts/README.md「使うときの注意」）
- 返ってきた JSON が `prompts/codex-pr-review/verifier-output-schema.json` の形（`verdict` が confirmed / refuted / inconclusive、`evidence` が文字列、`adjusted_confidence` が数）でなければ、同じ確かめ役に 1 回だけ直させる。それでも違えば「確かめられなかった」として扱う

## 4. 利用者に採否を聞く

指摘ごとに、Claude のおすすめを付けて表にする。

- confirmed → 採用をすすめる
- refuted → 却下をすすめる
- inconclusive → Claude が文書を読んで採用・却下・保留のどれかをすすめ、「Claude の推定」と書く

聞き方は利用者の決まりに合わせる（答えを求めるメッセージは頼みごと 1 つ、冒頭に「やってほしいこと」を 1 行、選択肢の画面は使わず普通の文で）：

```
やってほしいこと：指摘ごとの採否を「R1 採用、R2 却下（理由）」の形で返してください。おすすめどおりでよければ「おすすめどおり」とだけ返してください。

| R | 重さ | 引用（短く） | Codex の指摘 | 確かめ（Fable） | おすすめ |
|---|---|---|---|---|---|
| R1 | P1 | 「…」 | … | confirmed：… | 採用 |
```

**返事が来るまで文書を直さない。**

## 5. 台帳に残す

`$ROOT/logs/codex-review/<YYYY-MM-DD>-<文書のファイル名（拡張子なし）>.md` に書く（同じ日に同じ文書なら末尾に `-2` などを付ける）。
台帳の形はこのスキルの自作（cross-review の台帳の文面は写さない。判断文書「決定」節の問い 3）。

```markdown
# Codex レビューの台帳：<ROOT からの文書のパス>

- 日付：YYYY-MM-DD
- 対象：<文書のパス>（コミット <短い SHA>。未コミットの変更があれば「未コミットの変更を含む」）
- レビュー役：<モデル>・<考える深さ>（codex-run.sh --use review、thread_id <id>）
- 確かめ役：<fable / opus>（Agent ツール、指摘ごとに新しい文脈）
- 使用量：<codex-run.sh の「使用量」の行>

## 指摘と採否

### R1 [P1] <短い題>
- 引用：「…」（<文書のパス>:<行>）
- Codex の指摘：<何が起きるか・直し方>
- 確かめ：<confirmed / refuted / inconclusive>（確信度 <0.0〜1.0>）— <evidence>
- Claude のおすすめ：<採用 / 却下 / 保留>
- 採否：<採用 / 却下 / 保留>（利用者の言葉：「…」）
- 対応：<直したこと / なし>
```

- 採否の欄には利用者の言葉をそのまま書く。言っていない理由を足さない。「おすすめどおり」なら「（利用者の言葉：「おすすめどおり」）」
- 採用した指摘だけ、Claude が文書を直す。直したら「対応」を埋める
- 台帳と文書の変更は、作業ブランチでコミットし、PR は `apps-workflow:pr-flow` の手順で進める

## 6. 再レビュー（利用者が頼んだときだけ）

同じ会話の続きで、直した文書を Codex にもう一度読ませる。

1. `$W/decisions.md` に、指摘ごとの採否と対応を書く（台帳の「指摘と採否」の写しでよい）
2. `git -C "$ROOT" diff -- "$DOC" > "$W/diff.txt"`（コミット済みなら、レビューしたコミットとの差分）。空なら再レビューしない
3. 依頼書を作る（このスキルの自作の `followup.md`。判断文書の問い 4 で `plan-review-followup.md` は写していない）：

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/fill-prompt.sh" "${CLAUDE_PLUGIN_ROOT}/skills/codex-review/followup.md" DECISIONS=@"$W/decisions.md" DIFF=@"$W/diff.txt" PLAN_CONTENT=@"$DOC" > "$W/followup-brief.md"
```

4. 2 と同じくバックグラウンドで、`thread_id` を続ける：

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/codex-run.sh" --use review --resume "<thread_id>" -s read-only -f "$W/followup-brief.md" -o "$W/review-2.md" -C "$ROOT" --keep-session --events "$W/events-2.jsonl"
```

5. 新しい指摘があれば 3〜5 をくり返し、台帳に「## 再レビュー（YYYY-MM-DD）」の節を足す。採用した指摘の「解消／未解消」もそこに書く

## しないこと

- GitHub への投稿（PR へのコメント・Issue・レビュー）
- 採否が決まる前の文書の修正。Codex に文書を直させること（Codex はいつも読み取り専用）
- コードの差分のレビュー（GitHub の Codex クラウドレビューの担当。pr-flow 5 節）
- 1 で止まった文書を、別のパスやコピーで送ること
- 利用者の頼みなしの再レビュー、モデルや考える深さを変えたやり直し（どちらも利用枠を使うため）
