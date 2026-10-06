# 外部から写したプロンプト

マルチモデル協調（コンペ・相互レビュー）のスキルが使う、外部のリポジトリのプロンプトとスキーマの写し。
何を写すかは、ops の `docs/2026-10-04-マルチモデル協調の採用判断.md`「決定」節の問い 1・2・4 で決まった（本人の回答は Beads ops-h49.4）。
写したのは 2026-10-05。本文は 1 文字も変えていない（`scripts/test-prompts.sh` が sha256 で確かめる）。
`slot-machine/writing-3-judge.md` だけは 2026-10-06 に、compete スキルの審査役として Claude が足した（§2 の一覧には無かった。出どころは問い 1 で決まった slot-machine のまま。
コード用の `coding-3-judge.md` は「実装を 1 つ選ぶ」作りで、設計案・画面案を節ごとに組み合わせて選ぶ使い方に合わないため）。

## 一覧

| ファイル | 出どころ（元のパス） | ライセンス | 何に使うか（予定） | 埋める差し込み口 |
|---|---|---|---|---|
| `slot-machine/coding-2-reviewer.md` | pejmanjohn/slot-machine `profiles/coding/2-reviewer.md` | MIT | 実装 1 案のレビュー役。証拠（ファイル:行）を必須にし、作り手の自己申告を信じず、重大度で絞る | `{{SPEC}}` `{{IMPLEMENTER_REPORT}}` `{{PRE_CHECK_RESULTS}}` `{{WORKTREE_PATH}}` `{{SLOT_NUMBER}}` `{{APPROACH_HINT_USED}}` |
| `slot-machine/coding-3-judge.md` | 同 `profiles/coding/3-judge.md` | MIT | 審査役。仕様で足切り → 重大な問題の数で比べる → 複数のレビューで一致した指摘を重く見る → 全案不適格も選べる | `{{SLOT_COUNT}}` `{{SPEC}}` `{{ALL_SCORECARDS}}` `{{WORKTREE_PATHS}}` |
| `slot-machine/writing-2-reviewer.md` | 同 `profiles/writing/2-reviewer.md` | MIT | 文章・設計案 1 案のレビュー役。該当箇所の引用を必須にする。compete スキルのレビュー役（設計案・画面案） | `{{SPEC}}` `{{IMPLEMENTER_REPORT}}` `{{PROJECT_CONTEXT}}` `{{WORKTREE_PATH}}` `{{SLOT_NUMBER}}` `{{APPROACH_HINT_USED}}` |
| `slot-machine/writing-3-judge.md` | 同 `profiles/writing/3-judge.md` | MIT | 文章・設計案の審査役。ブリーフで足切り → 重大な問題の数で比べる → 複数案の良い所を節ごとに組み合わせる計画（SYNTHESIZE）も出せる。compete スキルの審査役 | `{{SLOT_COUNT}}` `{{SPEC}}` `{{ALL_SCORECARDS}}` `{{WORKTREE_PATHS}}` |
| `codex-pr-review/verifier-claude-prompt.md` | 0-to-1-Labs/codex-pr-review `scripts/verifier-claude-prompt.md` | MIT | 別の系統のモデル（例: Codex）の指摘 1 件を、原典の行と照らして confirmed / refuted / inconclusive で確かめる | `{{REVIEW_RULES}}` `{{FINDING}}` `{{FILE_PATH}}` `{{FILE_CONTENT}}` `{{DIFF_HUNK}}` |
| `codex-pr-review/verifier-output-schema.json` | 同 `scripts/verifier-output-schema.json` | MIT | 上の検証の出力の形（JSON Schema）。`codex-run.sh --schema` に渡す想定（実機では未確認） | なし |
| `crazytieguy-codex-plugin-cc/plan-review.md` | Crazytieguy/codex-plugin-cc `plugins/codex/prompts/plan-review.md` | Apache-2.0 | 設計書・計画を Codex に厳しく読ませる（相互レビューの設計書向け、コンペの反論の土台） | `{{PLAN_CONTENT}}` |

コミットと本文の sha256 は `sources.json`。ライセンスの全文は各フォルダの `LICENSE.<出どころ>`（Crazytieguy の分は著作権の表示 `NOTICE.crazytieguy-codex-plugin-cc` も）。

## 使うときの注意

- `.md` の冒頭の注記（`<!--` 〜 `-->`）は出典の記録で、モデルへの指示ではない。渡すときは外す
- `{{…}}` は呼ぶ側のスキルが埋める。埋めずに渡さない
- slot-machine の審査役（`coding-3-judge.md`・`writing-3-judge.md`）は、勝者を選ぶ（PICK）か、複数案を組み合わせる計画（SYNTHESIZE）を出す前提で書かれている。
  ここでは審査役は**おすすめを出すだけ**で、採否は本人が決める（「決定」節の問い 8）。組み合わせやマージを自動では進めない
- slot-machine の 4 本は、作り手を伏せる前提では書かれていない（元のリポジトリはモデル名を表示する）。伏せるのは呼ぶ側の手順で行う
- 検証プロンプト（`verifier-claude-prompt.md`）は「書いていない別の系統のモデルが疑ってかかる」前提。
  自分のコードへの指摘を自分で確かめると偏るおそれがある（判断文書 §5.2.4 の「反論 1 回の結果」の評価者 1（Claude）と §2 の問い 2。同じ §5.2.4 の「Claude の評価」の欄は、反論の前の「取り込む」立場）。確かめ役は書き手と別の文脈にする（Claude の案）
- `plan-review.md` の続き（`plan-review-followup.md`）は写していない（問い 4 で `plan-review.md` だけと決めた）

## 写さなかったもの

- Crazytieguy/codex-plugin-cc の `plan-review-followup.md`・`adversarial-review.md`・`review-output.schema.json`・`skills/codex-prompting/`（問い 4）
- raghubetina/cross-review の採否の台帳の文面（問い 3 で「作り直す」と決めた）
- pairmark の採点（問い 1 で slot-machine に決めた。考え方は借りてよい）

## 直すときの決まり

- 写した本文を書き換えたら、冒頭の注記の「改変」を「あり（何を変えたか）」に、`sources.json` の `modified` を `true` に直す（Apache-2.0 は、変更したファイルに変更した旨の表示を求める）
- 新しく写すときは、`sources.json` に 1 件足し、ライセンスの写しを置く。載せずに置くと `test-prompts.sh` が NG を出す
