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
  （ops・personal の中・ルートに `data/` のあるリポジトリ・PRIVATE.md・`*.local.*`・`.env*`・gitignore の対象・文書でないファイルを止めている）

続けて、Codex に読ませる作業フォルダを、Git で管理しているファイルだけで作る。**Codex の作業フォルダにリポジトリそのものを渡さない。**
Codex は読み取り専用でも、作業フォルダの中も外もどこでも読める（2026-10-05 に `codex sandbox -P :read-only` で確かめた）。
そこで、作業フォルダは書き出しにし、さらに 2 で読ませない場所の一覧（`config/codex-review-deny-read.txt`。ホームの直下・Windows のドライブ・Claude の作業用フォルダ）を渡して、そこを読めなくする。

```bash
TREE="$(mktemp -d /tmp/codex-review.XXXXXX)"
bash "${CLAUDE_PLUGIN_ROOT}/scripts/codex-review-export.sh" "$DOC" "$ROOT" "$TREE"
```

- 書き出しは Claude の作業用フォルダ（scratchpad）の**外**に作る。作業用フォルダは読ませない場所に入っていて、その中に作ると Codex が書き出しも読めなくなるため
- 中身はリポジトリの HEAD に、レビューする文書の今の中身を重ねたもの（PRIVATE.md・`*.local.*`・`.env*` の名前のファイルは、見本も含めて外れる）。書き出しは /tmp に残るが、Git で管理しているファイルだけなので消さなくてよい
- 読ませない場所の一覧の外（`/etc`・`/usr`・`/tmp` のほかのフォルダなど）は、Codex が読める
- レビューした時点の文書の写しを残す（6 の再レビューで差分を取るため）：`cp "$DOC" "$W/doc-reviewed.md"`

## 2. Codex にレビューさせる

依頼書を作る（借りてきた `plan-review.md` の `{{PLAN_CONTENT}}` に文書の中身を入れる。冒頭の出典の注記は外れる）。

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/fill-prompt.sh" "${CLAUDE_PLUGIN_ROOT}/prompts/crazytieguy-codex-plugin-cc/plan-review.md" PLAN_CONTENT=@"$DOC" > "$W/brief.md"
```

Codex を呼ぶ。**Bash のバックグラウンド実行**で流し、完了の通知を待つ。通知が届く前に結果を書いたり、終わったと言ったりしない。

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/codex-run.sh" --use review -s read-only -f "$W/brief.md" -o "$W/review.md" -C "$TREE" --skip-git-repo-check --keep-session --events "$W/events.jsonl" --deny-read-list "${CLAUDE_PLUGIN_ROOT}/config/codex-review-deny-read.txt"
```

- `-C` は書き出し（`TREE`）。書き出しは Git のリポジトリではないので `--skip-git-repo-check` を付ける
- `--deny-read-list` で、一覧の場所を Codex に読ませない（全体は読み取りだけ、一覧の場所は deny の権限のプロファイルを渡す）。外して呼ばない
- `--keep-session` は 6 の再レビュー（同じ会話の続き）のため。標準出力の `thread_id` と `使用量` を控える
- 標準出力に「知らせ: n 件」が出たら（新しいモデル・廃止の予定など）、標準エラーの本文を利用者に伝え、Beads に付箋を作る（`config/codex-models.json` を比べて直すかの判断）
- 失敗したら（終了コード 1）、理由を伝えて止まる。勝手に考える深さやモデルを変えてやり直さない

## 3. 指摘を分けて、別の系統に確かめさせる

`$W/review.md` を読み、指摘を `R1`・`R2`… に分ける。指摘ごとに、重さ（P0〜P2）・引用された文・何が起きるか・直し方を控える。
指摘が無ければ（「そのまま進めてよい」という返事なら）、4 を飛ばして 5 の台帳に「指摘なし」と書く。

指摘ごとに確かめ役の依頼書を作る。

1. 引用された文が文書の何行目にあるかを `grep -n -F` で探す。引用が複数行にまたがる・「…」で縮めてある・言い回しが少し違うときは、引用の中の特徴のある短い一節（10〜20 字）で探し直す
2. `$W/R<n>.json` に指摘を書く：
   `{"id":"R1","severity":"P1","code_location":{"path":"<ROOT からの相対パス>","line_start":12,"line_end":14},"quote":"<引用>","body":"<何が起きるか・直し方>"}`
   - 探し直しても見つからなければ、`line_start` を 1、`line_end` を文書の最終行にし、`"location_note":"引用の場所を特定できなかった。文書全体から探して確かめる"` を足す。
     **行番号を 0 などの範囲外にしない**（借りてきた検証プロンプトは、範囲外の行を指す指摘を当たっていないとするため、正しい指摘が捨てられる。PR #26 の Codex のクラウドレビュー）
3. 行番号つきの文書を `cat -n "$DOC" > "$W/doc-numbered.txt"` で作る。差分の欄には `printf '差分なし（文書の今の中身をレビューした）\n' > "$W/no-diff.txt"` を使う
4. 依頼書を作る：

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/fill-prompt.sh" "${CLAUDE_PLUGIN_ROOT}/prompts/codex-pr-review/verifier-claude-prompt.md" REVIEW_RULES=@"${CLAUDE_PLUGIN_ROOT}/skills/codex-review/verify-rules.md" FINDING=@"$W/R1.json" FILE_PATH="<ROOT からの相対パス>" FILE_CONTENT=@"$W/doc-numbered.txt" DIFF_HUNK=@"$W/no-diff.txt" > "$W/verify-R1.md"
```

確かめ役は **Agent ツールで、`model` に `fable` を指定し、指摘 1 件につき 1 体を新しい文脈で**呼ぶ（全件を 1 つのメッセージで並べて同時に）。
`subagent_type` は `general-purpose`、プロンプトは `$W/verify-R<n>.md` の中身に「作業フォルダは <ROOT>。ファイルは読むだけで、書かない。最終メッセージは JSON 1 つだけ」を添える。

- 確かめ役が読むのは本物のリポジトリ（`ROOT`）でよい（Claude 側なのでフックが効く）。Codex に渡すのは書き出しだけ
- この会話で Fable に書かせた文書だと分かっているときだけ、`model` を `opus` にする（書き手と確かめ役を分けるため。prompts/README.md「使うときの注意」）。分からなければ `fable`
- 返ってきた JSON が `prompts/codex-pr-review/verifier-output-schema.json` の形（`verdict` が confirmed / refuted / inconclusive、`evidence` が文字列、`adjusted_confidence` が数）でなければ、同じ確かめ役に 1 回だけ直させる。それでも違えば「確かめられなかった」として扱う

## 4. 利用者に採否を聞く

指摘ごとに、Claude のおすすめを付けて表にする。

- 当たっている（confirmed）→ 採用をすすめる
- 当たっていない（refuted）→ 却下をすすめる
- 決めきれない（inconclusive）→ Claude が文書を読んで採用・却下・保留のどれかをすすめ、「Claude の推定」と書く

利用者に見せる言葉は、やさしい日本語にする（利用者の決まり「新しい言葉は説明してから使う」「中身が分からないまま承認させない」）。

- 重さ：P0 →「とても重い」、P1 →「重い」、P2 →「軽い」
- 確かめ：confirmed →「当たっている」、refuted →「当たっていない」、inconclusive →「決めきれない」
- Codex の指摘（英語のことが多い）は、指摘ごとに「何が困るか」を具体例つきの日本語 1 行に直す。専門用語を使うなら、その場で一言説明する

聞き方は利用者の決まりに合わせる。答えを求めるメッセージは頼みごと 1 つ、冒頭に「やってほしいこと」を 1 行、選択肢の画面は使わず普通の文で、返す言葉を指定する。
**このメッセージには、作業の報告や次のアクションを書かない**（答えをもらってから書く）。

```
やってほしいこと：指摘ごとの採否を「R1 採用、R2 却下（理由）」の形で返してください。おすすめどおりでよければ「おすすめどおり」とだけ返してください。

| 番号 | 重さ | 何が困るか（やさしく） | 確かめた結果（Fable） | おすすめ |
|---|---|---|---|---|
| R1 | 重い | 手順 3 の前に手順 4 の結果が要るので、書いた順に進めると途中で止まる | 当たっている（文書の 12〜14 行目） | 採用 |
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
- 返事に出てこなかった指摘は「未回答」と書く。**おすすめで埋めない**（答えをもらっていない問いは回答済みにしない）。未回答の指摘は直さない
- 利用者の言葉に生活の事実（家族・お金・住まい・健康・勤め先など）が入るときは、台帳と 6 の `decisions.md` には「PRIVATE.md 参照」とだけ書き、言葉そのものは PRIVATE.md に置く（apps の CLAUDE.md「個人情報の取り扱い」。台帳はコミットし、`decisions.md` は Codex に渡るため）
- 採用した指摘だけ、Claude が文書を直す。直したら「対応」を埋める
- 台帳と文書の変更は、作業ブランチでコミットし、PR は `apps-workflow:pr-flow` の手順で進める

## 6. 再レビュー（利用者が頼んだときだけ）

同じ会話の続きで、直した文書を Codex にもう一度読ませる。

1. `$W/decisions.md` に、指摘ごとの採否と対応を書く（台帳の「指摘と採否」の写しでよい）
2. 前に Codex に送った時点の写しと比べて差分を取る：`diff -u "$W/doc-reviewed.md" "$DOC" > "$W/diff.txt"`（コミットしたあとでも取れる。
   `diff` は差分があると終了コード 1 を返すが、失敗ではない）。`diff.txt` が空なら、まだ直していないので再レビューしない
3. 書き出しの中の文書と、写しを、今の中身にする（このあと Codex に送る中身を、次の再レビューの差分の起点にするため）：
   `cp "$DOC" "$TREE/<ROOT からの文書の相対パス>"` と `cp "$DOC" "$W/doc-reviewed.md"`
4. 依頼書を作る（このスキルの自作の `followup.md`。判断文書の問い 4 で `plan-review-followup.md` は写していない）：

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/fill-prompt.sh" "${CLAUDE_PLUGIN_ROOT}/skills/codex-review/followup.md" DECISIONS=@"$W/decisions.md" DIFF=@"$W/diff.txt" PLAN_CONTENT=@"$DOC" > "$W/followup-brief.md"
```

5. 2 と同じくバックグラウンドで、`thread_id` を続ける：

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/codex-run.sh" --use review --resume "<thread_id>" -s read-only -f "$W/followup-brief.md" -o "$W/review-2.md" -C "$TREE" --skip-git-repo-check --keep-session --events "$W/events-2.jsonl" --deny-read-list "${CLAUDE_PLUGIN_ROOT}/config/codex-review-deny-read.txt"
```

6. 新しい指摘があれば 3〜5 をくり返し、台帳に「## 再レビュー（YYYY-MM-DD）」の節を足す。採用した指摘の「解消／未解消」もそこに書く

別の会話で再レビューを頼まれたとき（`$W` と `TREE` が残っていない）は、1 からやり直して書き出しを作る。
差分は、台帳に書いたコミットと今の文書で取る（`git -C "$ROOT" diff <台帳の短い SHA> -- "$DOC"`）。`thread_id` は台帳から引く

## しないこと

- Codex の作業フォルダに、リポジトリそのものを渡すこと（いつも 1 で作った書き出しを渡す）。`--deny-read-list` を外して Codex を呼ぶこと
- GitHub への投稿（PR へのコメント・Issue・レビュー）
- 採否が決まる前の文書の修正。Codex に文書を直させること（Codex はいつも読み取り専用）
- コードの差分のレビュー（GitHub の Codex クラウドレビューの担当。pr-flow 5 節）
- 1 で止まった文書を、別のパスやコピーで送ること
- 利用者の頼みなしの再レビュー、モデルや考える深さを変えたやり直し（どちらも利用枠を使うため）
