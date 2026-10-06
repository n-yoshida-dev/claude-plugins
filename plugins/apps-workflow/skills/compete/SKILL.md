---
name: compete
description: 設計案・画面案のコンペを回す。同じブリーフから Opus・Fable（Agent ツール）と Codex（用途 design / screen の表のモデル。2026-10-06 から GPT-6.1 Sol）が独立に 1 案ずつ作り、作り手を伏せて A・B・C… にし、作り手を知らない AI のレビュー役と審査役がおすすめを出し、利用者が節ごとに選ぶ。比較ページは非公開の Artifact。利用者が /apps-workflow:compete <お題> と打ったときだけ動く。コード実装のコンペは今はしない（判断文書「決定」節の問い 6）。
disable-model-invocation: true
argument-hint: <お題（何を決めたいか）>
---

# 設計案・画面案のコンペ

お題：$ARGUMENTS

流れは「お題と形を決める → ブリーフを書いて点検 → 作業場所 → 3 者が独立に作る → 伏せて検査 →（設計案なら）割れた点だけ反論 1 回 → レビュー役 → 審査役 2 つ → 比較ページで利用者が節ごとに選ぶ → 明かして記録」。
方針の出どころは ops の `docs/2026-10-04-マルチモデル協調の採用判断.md` §7「目的 1: コンペ」と §8 手順 7、試行 1〜3 の振り返り（Beads ops-h49 のコメント）。
決まっていること：採点のプロンプトは slot-machine から借りる（問い 1）、作り手を知らない AI の審査役がおすすめを出し利用者が採否を決める（問い 8）、コード実装のコンペは今はしない（問い 6）。

## 0. 前提

- **ChatGPT の利用枠を使うが、動かす前に了承は取らない**（apps の CLAUDE.md、2026-10-06）。使うのは Codex の作り手 1 回・審査役 1 回・（設計案なら）反論 1 回。
  利用上限に当たって止まったら、そこで止めて報告する
- お題が空（`$ARGUMENTS` が空）なら、何を決めたいかを利用者に普通の文で聞いて止まる
- **調整役（このセッション）は案を作らない・比べない・おすすめを出さない。** 経緯を全部見ているので独立にならないため。調整役の仕事は、ブリーフ・作業場所・起動・検査・記録
- **作り手は Agent ツールで起動する。Workflow ツールは使わない。** Workflow は起動した回の利用者の発言を全員に「この依頼が優先」として中継し、
  試行 3 で作り手が読んではいけない資料を読んだため（ops-h49 の 2026-10-04 のコメント。判断文書 §7 は Workflow と書いていたが、これで変えた。Claude の判断）
- 2 つのフォルダを使う。どちらもリポジトリの外
  - **調整役のフォルダ `COORD`**：Claude の scratchpad（無ければ `mktemp -d`）の中に `compete-<YYYYMMDD>-<短い英字の題>/` を作る。ブリーフの下書き・作り手と札の対応・伏せ字の対応・使用量。
    Codex には読ませない（scratchpad は共通の「読ませない場所」の一覧に入っている。`mktemp -d` に作った場合も、`compete-setup.sh` が Codex に渡す一覧に足す）
  - **作業場所 `RUN`**：`RUN="$(mktemp -d /tmp/compete.XXXXXX)"`。ブリーフの写し・材料・作り手のフォルダ・伏せた案・レビュー・判定。
    Codex にも読ませるので scratchpad の外に置く。中身は Git で管理しているファイルと、調整役が撮った画像だけ
- 伏せ字の対応（`COORD/labels.local.tsv`）と、`RUN/rebuttal/` の中は、**利用者が選び終えるまで調整役は開かない**
- **伏せる・互いに見せないの強さは、Codex と Claude 側で違う。** Codex は読ませない場所の一覧（OS の権限）で止まる。
  Claude 側の作り手・レビュー役・審査役（Agent ツール）にはサンドボックスが無く、隣の作り手のフォルダも `COORD` の対応表も読めて、**指示だけで縛っている**
  （試行 3 で Opus の作り手が作業フォルダの外の対応表を開いた。ops-h49 の 2026-10-04・2026-10-05 のコメント）。
  そのため伏せ字の対応（`labels.local.tsv`）は作り手が終わってから作り（`compete-blind.sh`）、依頼書には `COORD` のパスを書かない。
  画面案の `aim.md` などで、作り手が `COORD` や隣のフォルダを開いたと書いていたら、`COORD/redactions.md` と 10 節の記録の README に書く

## 1. お題・形・節を決める

形は 2 つ。お題から決まらなければ、どちらにするかを利用者に普通の文で聞く。

| 形 | 成果物 | Codex の用途 | 向くお題 |
|---|---|---|---|
| `design`（設計案） | `design.md` 1 枚。見出しは節の一覧で固定 | `--use design` | 仕組み・回し方・データの持ち方（試行 2） |
| `screen`（画面案） | 見本の `index.html` 1 枚と、狙いの `aim.md` | `--use screen` | 画面の並べ方・見せ方（試行 1・3） |

節の一覧を決め、`COORD/parts.txt` に 1 行 1 つで書く。利用者が節ごとに選ぶ単位になる。

- design の既定は「問題の捉え方 / 提案 / 捨てた案 / リスク / 移行の手順」（試行 2 と同じ。お題に合わせて変えてよい）
- screen は画面の部分（例：「最初の画面」「About」「Skills」）。お題の対象を、利用者が選び分けたい単位で切る

## 2. ブリーフを書いて点検する

`${CLAUDE_PLUGIN_ROOT}/skills/compete/brief-template.md` を `COORD/brief.md` に写して埋める。冒頭のコメントの決まり（事実と決まりだけ・調整役の意見を入れない・数字はコマンドの出力を貼る・
Private の原文を引かない・文面を変えたら差分・調整役が確かめていないことは「未確認メモ」）に従い、コメントは消す。
「節」の節は `COORD/parts.txt` と同じ言葉・同じ並びにする。

材料を決める。リポジトリの中のファイル（PLAN.md・正本の文面・今のソースなど）は Git で管理しているものだけ。画面のお題では、今の画面を Playwright で 1280px と 375px で撮り、`COORD/` に置く
（アプリに Playwright が無ければ撮らずに、ブリーフの「材料」に「スクリーンショットなし」と書く）。

点検役を 1 体、**Agent ツールで、`model` に `fable`、`subagent_type` に `general-purpose`、新しい文脈で**呼ぶ。依頼書はこう作る：

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/fill-prompt.sh" "${CLAUDE_PLUGIN_ROOT}/skills/compete/brief-check.md" BRIEF=@"$COORD/brief.md" PARTS=@"$COORD/parts.txt" INPUT_DIR="<材料のパスを、読点で区切って 1 行で>" > "$COORD/brief-check-prompt.md"
```

プロンプトは `$COORD/brief-check-prompt.md` の中身。指摘を読んでブリーフを直す（試行 3 で点検役は、調整役の見立てが選択肢の形で入っていたことを見つけた）。
直したら、指摘と直した所を `COORD/brief-check-result.md` に残す。

## 3. 作業場所を作る

```bash
RUN="$(mktemp -d /tmp/compete.XXXXXX)"
bash "${CLAUDE_PLUGIN_ROOT}/scripts/compete-setup.sh" --kind <design|screen> --root "<リポジトリのルート>" --run "$RUN" --coord "$COORD" --brief "$COORD/brief.md" --parts "$COORD/parts.txt" <材料のファイル ...>
```

- 標準出力の「札<TAB>作り手」（`COORD/workers.tsv` と同じ）を控える。札（`w-` と乱数）は、作り手の名前をフォルダ名に出さないためのもの
- 作り手は既定で `opus fable codex`。名前は呼び方で、Codex の中で動くモデルは表（`config/codex-models.json`）の用途で決まる（2026-10-06 から GPT-6.1 Sol。それまで名前を `astra` にしていたが、モデルを変えたので取り違えないよう `codex` にした）。
  記録の README には、名前ではなく、その回に実際に動いたモデル（codex-run.sh の標準エラーの `model=` の行）を書く。条件を変えた版も比べるとき（試行 3 の「人物像を考慮する版／しない版」）は `--makers "opus fable astra opus-ctx fable-ctx astra-ctx"` のように足し、
  版ごとにブリーフを分ける（このスキルの骨組みでは 1 つのブリーフを全員に渡す。版を分けるなら、作り手のフォルダの `input/brief.md` を調整役が差し替える）
- 終了コード 2 なら、理由を利用者に伝えて止まる（ops・personal の中、`data/` のあるリポジトリ、Git で管理していない材料、非公開の置き場の名前を止めている）

## 4. 作り手に頼む（3 者を同時に）

作り手ごとに依頼書を作る（`<札>` は `workers.tsv` から。Claude の作り手は `claude`、Codex の作り手は `codex`）：

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/compete-brief.sh" maker "$RUN" <札> <claude|codex>
```

**1 つのメッセージで、次の 3 つを同時に起動する**（どれもバックグラウンド）。起動した時刻を `COORD/usage.tsv` に書く（`役<TAB>作り手<TAB>始め<TAB>終わり<TAB>使用量<TAB>メモ`）。

- **Opus**：Agent ツール、`model` に `opus`、`subagent_type` に `general-purpose`、`run_in_background: true`。プロンプトは「`<RUN>/makers/<札>/task.md` を読み、その指示どおりに作業する。」の 1 行だけ
- **Fable**：同じく `model` に `fable`
- **Codex**：Bash のバックグラウンド実行。読み取り専用で、ほかの作り手のフォルダを読ませない一覧を渡す
  - design：
    ```bash
    bash "${CLAUDE_PLUGIN_ROOT}/scripts/codex-run.sh" --use design -s read-only -f "$RUN/makers/<札>/task.md" -o "$RUN/makers/<札>/out/design.md" -C "$RUN/makers/<札>" --skip-git-repo-check --events "$COORD/events-maker-<作り手>.jsonl" --deny-read-list "$COORD/deny-read-<作り手>.txt"
    ```
  - screen（返事の形を JSON に縛り、あとでファイルにする。画像の材料は `-i` で添える）：
    ```bash
    bash "${CLAUDE_PLUGIN_ROOT}/scripts/codex-run.sh" --use screen -s read-only --schema "${CLAUDE_PLUGIN_ROOT}/skills/compete/screen-output.schema.json" -f "$RUN/makers/<札>/task.md" -o "$COORD/screen-<作り手>.json" -C "$RUN/makers/<札>" --skip-git-repo-check --events "$COORD/events-maker-<作り手>.jsonl" --deny-read-list "$COORD/deny-read-<作り手>.txt" -i "$RUN/makers/<札>/input/<画像>"
    ```
    終わったら `bash "${CLAUDE_PLUGIN_ROOT}/scripts/compete-unpack.sh" "$COORD/screen-<作り手>.json" "$RUN/makers/<札>/out"`
  - `<作り手>` は `workers.tsv` の作り手の名前（既定は `codex`。`--makers` で版を足したら `codex-ctx` など）

待ち方と決まり：

- 3 つの完了の通知がそろうまで、次に進まない。通知が届く前に結果を書いたり、終わったと言ったりしない
- 作り手の返事は読まない（「書いた」のはず。要約が付いていても、比べる前に作り手を推測しないため、中身に触れない）
- 終わった時刻と使用量を `usage.tsv` に書く（Agent は通知の使用量、Codex は codex-run.sh の「使用量」の行。数え方が違うので横に並べるだけで比べない）
- Codex が失敗したら（終了コード 1）、理由を伝える。勝手に考える深さやモデルを変えてやり直さない。2 者でも 5 節に進める（欠けた案は外れる）
- Codex の作り手はブラウザで自分の見本を確かめられない（サンドボックスの中ではブラウザが起動しない。試行 1）。表示の確かめは 5 節で調整役が行う

## 5. 伏せて検査する

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/compete-blind.sh" "$RUN" "$COORD"
bash "${CLAUDE_PLUGIN_ROOT}/scripts/compete-check.sh" "$RUN" "$COORD/forbidden.txt"
```

- `compete-blind.sh` が乱数で A・B・C… を割り当て、写しを sha256 で確かめる。成果物がそろわない作り手は外れる（欠けた数は標準出力）
- `forbidden.txt` は任意。Private のリポジトリの原文の言い回しや、生活の事実の語を 1 行 1 つで `COORD/` に書く（リポジトリにも RUN にも置かない）。無ければ引数を省く
- `compete-check.sh` が何か見つけたら（終了コード 1）、`RUN/blind/` の該当の行を読む。**作り手の札・フォルダのパスは必ず伏せ字にする**（`workers.tsv` と結び付いて作り手が分かるため）。作り手の名乗り・非公開の語なら、伏せた写しのその語を「（伏せ字）」に直し、直したことを `COORD/redactions.md` に書く。
  お題の中身として正しく出てくる名前（例：Claude Code を使った作品の紹介）は直さない
- screen のとき、アプリに Playwright があれば、各見本を 1280px と 375px で開いて横のはみ出し（`document.documentElement.scrollWidth - innerWidth`）を測り、`COORD/checks.md` に書く。
  無ければ「表示は確かめていない」と書く

## 6. 割れた点だけ反論 1 回（design のときだけ）

`RUN/blind/*/design.md` を読み、案どうしで考えが割れた点を 4 つまで選ぶ（調整役は伏せ字しか知らないので、読んでよい）。
割れていない点・好みの差だけの点は入れない。割れた点が無ければ、この節を飛ばす。

`COORD/questions.md` に、割れた点ごとに「## 割れた点 <番号>」と、案ごとの立場を引用つきで 1〜2 行ずつ書く（調整役の意見は書かない）。

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/compete-rebuttal.sh" prepare "$RUN" "$COORD" "$COORD/questions.md"
```

標準出力の「作り手<TAB>依頼書<TAB>答えの置き場」ごとに、**3 者とも新しい文脈で**同時に起動する（ops-h49 の 2026-10-04 のコメント「反論は全員新しい文脈＋同じ質問文、を標準にする」）。依頼書の中身は調整役が読まない（作り手の伏せ字が書いてある）。

- Opus・Fable：Agent ツール（4 節と同じ `model`）、プロンプトは「`<依頼書>` を読み、その指示どおりに答える。」の 1 行だけ
- Codex：`bash "${CLAUDE_PLUGIN_ROOT}/scripts/codex-run.sh" --use design -s read-only -f "<依頼書>" -o "<答えの置き場>" -C "$RUN" --skip-git-repo-check --events "$COORD/events-rebuttal-<作り手>.jsonl" --deny-read-list "$COORD/deny-read-<作り手>.txt"`
- 始めと終わりの時刻・使用量を `usage.tsv` に書く（役は「反論」）

全員の通知がそろったら集め、もう一度検査する（答えの中の名乗りを見つけるため）。
答えが欠けた作り手があっても、**利用者が選ぶ前に、どの作り手の反論が欠けたかを言わない**（比較ページで反論の無い伏せ字と結び付くため。「反論が 1 件欠けた」とだけ言う）。
このとき調整役自身には、どのプロセスが失敗したかと比較ページから対応が分かってしまう（防げない限界）。調整役は比べない・おすすめを出さない役なので、選択には響かないが、記録の README に書く：

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/compete-rebuttal.sh" collect "$RUN" "$COORD"
bash "${CLAUDE_PLUGIN_ROOT}/scripts/compete-check.sh" "$RUN" "$COORD/forbidden.txt"
```

## 7. レビュー役（案ごとに 1 体）

伏せ字ごとに依頼書を作る：`bash "${CLAUDE_PLUGIN_ROOT}/scripts/compete-brief.sh" review "$RUN" <伏せ字>`

案ごとに 1 体、**Agent ツールで、`model` に `fable`、`subagent_type` に `general-purpose`、新しい文脈で**、1 つのメッセージで全員を同時に呼ぶ。
プロンプトは「`<RUN>/briefs/review-<伏せ字>.md` を読み、その指示どおりにレビューする。」の 1 行だけ。レビューは `RUN/reviews/<伏せ字>.md` に入る。

- 全部の案を同じ系統の同じ条件でレビューする（比べる条件をそろえるため）。Fable も作り手の 1 つだが、伏せてあるので自分の案かは分からない
- レビューが欠けたら、その伏せ字だけ 1 回呼び直す
- 始めと終わりの時刻・使用量を `usage.tsv` に書く（役は「レビュー」、作り手の欄は伏せ字）

## 8. 審査役（系統の違う 2 つ）

審査役ごとにレビューの並び順を乱数で変えた依頼書を作る：

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/compete-brief.sh" judge "$RUN" fable claude
bash "${CLAUDE_PLUGIN_ROOT}/scripts/compete-brief.sh" judge "$RUN" codex codex
```

同時に起動する。

- Fable：Agent ツール、`model` に `fable`、新しい文脈。プロンプトは「`<RUN>/briefs/judge-fable.md` を読み、その指示どおりに判定する。」の 1 行だけ。判定は `RUN/judges/fable.md` に入る
- Codex：作り手のフォルダと反論の置き場を読ませない一覧（`deny-read-judge.txt`）を渡す
  ```bash
  bash "${CLAUDE_PLUGIN_ROOT}/scripts/codex-run.sh" --use review -s read-only -f "$RUN/briefs/judge-codex.md" -o "$RUN/judges/codex.md" -C "$RUN" --skip-git-repo-check --events "$COORD/events-judge-astra.jsonl" --deny-read-list "$COORD/deny-read-judge.txt"
  ```

審査役を 2 つにするのは、Fable の審査役が Fable の作った案を（伏せてあっても）好む偏りを、系統の違う審査役と比べて見えるようにするため（Claude の判断）。
2 つの判定が割れたら、割れたまま比較ページに出す。調整役がどちらかに寄せない。
Codex の審査役には `RUN/judges/` も読ませない（Fable の判定を先に見ないため）。Fable の審査役は指示だけで縛っている（0 節）。
始めと終わりの時刻・使用量を `usage.tsv` に書く（役は「審査」）。

## 9. 比較ページを見せて、利用者に選んでもらう

```bash
node "${CLAUDE_PLUGIN_ROOT}/scripts/compete-page.mjs" --run "$RUN" --out "$COORD/compare.html" --title "<お題の短い名前> 案くらべ"
```

`COORD/compare.html` を Artifact ツールで**非公開**のまま公開し（`icon` は `compare`）、claude.ai の URL を渡す（scratchpad のパスは VS Code で開けないため。apps の CLAUDE.md）。
ページは、審査役の判定 → 節ごとの比較と選択 → 「返す言葉」（選ぶとできあがる。コピーできる）→ 案ごとのレビューと反論 → ブリーフ、の並び。

聞き方は利用者の決まりに合わせる。答えを求めるメッセージは頼みごと 1 つ、冒頭に「やってほしいこと」を 1 行、選択肢の画面は使わず普通の文で、返す言葉を指定する。
**このメッセージには、作業の報告や次のアクションを書かない**（答えをもらってから書く）。審査役の判定は、ページに任せずメッセージにも 2〜3 行のやさしい日本語でまとめる。

```
やってほしいこと：比較ページで節ごとに案を選び、ページの下の「返す言葉」をコピーして貼ってください。
<URL>

審査役 2 つのおすすめ（作り手を知らない AI。参考です）：
- 審査役 1：…
- 審査役 2：…
```

人間待ちの付箋も作る（ラベル `human`・`review`、`--assignee n-yoshida-dev`、タイトル `[<アプリ名>] <お題> の案を節ごとに選ぶ`、説明に URL）。

## 10. 明かして記録する（利用者が選んだあと）

1. 返事の言葉をそのまま控える。返事に出てこなかった節は「未回答」にする（審査役のおすすめで埋めない）
2. ここで初めて `COORD/labels.local.tsv` と `COORD/workers.tsv` を読み、伏せ字と作り手を突き合わせる
3. 利用者のリポジトリの作業ブランチに、`docs/design-candidates/<YYYY-MM-DD>-<題>/` を作って写す：
   `brief.md`・`parts.txt`・伏せた案（`A/` `B/` …）・`reviews/`・`judges/`・（あれば）反論・`checks.md`・`redactions.md`、と `README.md`。
   `README.md` には、伏せ字と作り手の対応・利用者の選択（言葉のまま）・審査役 2 つのおすすめの要約・所要時間と使用量（`usage.tsv`。物差しが違うことを書く）・うまくいかなかったこと
4. コミットの前に、写したファイルを `compete-check.sh` の禁止語と同じ語で検査する（`grep -rnF -f "$COORD/forbidden.txt" docs/design-candidates/<…>/`。一覧が無ければ省く）。
   生活の事実が入っていれば伏せ字にし、言葉そのものは PRIVATE.md に置く（apps の CLAUDE.md「個人情報の取り扱い」）
5. 利用者の選択を `logs/decisions.md` に、利用者の言葉のまま書く（言っていない理由を足さない）。付箋は `bd human respond` か close で閉じる
6. ops-h49 にコメントを残す：お題・形・作り手と伏せ字・選ばれた案・所要時間と使用量・うまくいかなかったこと・手順の直し案（`bd comments add ops-h49 "..."`）
7. 選んだ案を実装するなら、ふつうの作業として PR で進める（`apps-workflow:pr-flow`）。見本から実装に写すとき、文面を勝手に変えない（試行 1 で受け入れレビューに 2 回止められた）

## 11. 片付け

- `RUN`（`/tmp/compete.…`）は、記録を写し終えたら残しておいてよい（Git で管理しているファイルと、伏せた案だけ）。消すかは利用者が決める
- 自分で起動した Playwright のブラウザ・開発サーバーが残っていないことを `ps` で確かめる

## しないこと

- 調整役が案を作る・比べる・おすすめを出すこと（審査役の仕事）。利用者が選ぶ前に `labels.local.tsv` と `RUN/rebuttal/` の中を開くこと
- Workflow ツールで作り手を起動すること（0 節）。Codex の作り手・審査役を `--deny-read-list` なしで、または書き込みありで動かすこと
- 作り手に、ほかの作り手の案を反論の前に見せること。反論を 2 回以上回すこと
- 審査役のおすすめで、利用者の選択を埋めること。選ばれた案の合成・実装を、利用者の返事の前に始めること
- コード実装のコンペ（問い 6「今はしない」。やるなら作り手ごとの worktree が要り、このスキルの外）
- 利用者の頼みなしのやり直し、モデルや考える深さを変えたやり直し（どちらも利用枠を使うため）
