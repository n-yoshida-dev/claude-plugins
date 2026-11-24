# 角の丸さの決め方と、AI が作ったように見える形

見た目を決める（look の A）・点検する（look の B・look-reviewer）ときに読む。
2026-11-24 に life-plan-simulator の T24（ボタンの角）で調べた物（調べ係の Web 調査）と、そのときの本人の選択から作った。
**アプリの `DESIGN.md` と、本人が選んだ形がいつも先。** ここは、決まりがまだ無いときの出発点と、点検の物差し。

## 1. 角は「小さい物ほど小さい角」の段にする

- **段にする。** 入れる欄・ボタン・まとめる枠（カード・パネル）の角を、物の大きさの順に段にする。
  life-plan-simulator の例：入れる欄 4px → ボタン 8px（高さ 44px）→ まとめる枠 12px。段ごとに意味を一言で言える
- **全部を同じ角にしない。** 同じ大きな角（16px など）をカード・ボタン・入れる欄・画像の全部に使うと強弱が無くなり、AI が作ったように見える（下の 3）
- **段を足すときは、その意味を一言で言えること。** 言えない差（4px と 6px が混ざる、など）は 1 つにまとめる（判断基準 P4「意味を言えない線・枠・色は外す」）
- **入れ子の角**：枠の中に物を入れるときは、外の角 ＝ 中の角 ＋ 間の余白（0 未満は 0）。中と外を同じ角にすると、角の所だけ余白が太って見える
  （https://jakub.kr/work/concentric-border-radius 、 https://cloudfour.com/thinks/the-math-behind-nesting-rounded-corners/ ）
- **フォーカスの輪**の角は、要素の角＋輪までのすき間（Atlassian は ＋2px）

## 2. ボタンの角の定石（高さ 36〜48px）

| 出どころ | ボタンの角 | 確かめ方 |
|---|---|---|
| Microsoft Fluent 2 | ふつう 4px、大きいボタン 8px、32px 未満の形は 2px | 公式 https://fluent2.microsoft.design/shapes |
| Atlassian | ボタン・入れる欄 6px、小さいボタンと札 4px、カード 8px、モーダル 12px。丸い端は顔の絵・絵文字の反応など | 公式 https://atlassian.design/foundations/radius |
| GitHub Primer | 段 3px / 6px / 12px / 丸い端。既定は 6px | 公式（ボタンへの割り当ては未確認） https://primer.style/foundations/primitives/size |
| shadcn/ui | 既定 10px、段 6 / 8 / 10px | 公式 https://ui.shadcn.com/docs/theming |
| 英国 Co-op | ボタン・カード 8px | 検索結果の抜粋だけ |
| Google Material 3 | ボタンは丸い端（高さの半分） | 二次情報（公式の本文は取れなかった） |
| Apple（iOS 26） | 大きさに合わせた角。丸い端（capsule）はツールバーや下の主な操作に | WWDC25 の説明。値は未確認 |

- 主流は 4〜8px。高さ 44px 前後は「大きいボタン」にあたり、8px が筋が通る
- **入れる欄とボタンを同じ角にそろえる**システムが多い（Atlassian・Fluent 2・Primer）。同じ「操作する物」として扱う考え方。
  ただし本人は、高さ 44px のボタンを入れる欄と同じ 4px にした案を「尖りすぎてて、ボタンっぽくない」と退けた（下の 4）。そろえるか段を分けるかは、見本を並べて本人に選んでもらう
- **丸い端（pill）は使う所を絞る。** 札・チップ・顔の絵、スマホの下の主な操作 1 つなど。角の付いた枠の中に丸い端のボタンを置くと、2 つの製品を貼り合わせたように見える、という指摘がある
  （https://dev.to/kiwibreaksme/why-ai-generated-uis-look-off-and-the-one-principle-that-fixes-it-4j20 ）
- 固い・柔らかいの性格（0〜4px は事務的、大きい角は親しみやすい）は一般論で、公式の文書は見つかっていない

## 3. AI が作ったように見える形（2024〜2026 年の指摘。デザイナーや開発者の意見で、研究ではない）

- **角**：同じ大きな角を全部の部品に使い、強弱が無い（Kosta Canatselis https://world.hey.com/kostac/spot-the-slop-a-ui-designer-s-guide-to-fixing-ai-defaults-4c448c9c ）
- **色**：紫から青のグラデーション（#667eea→#764ba2 など）、主なボタンのグラデーション、淡い青の差し色
  （同上、 https://dev.to/kenimo49/why-ai-generated-uis-are-all-the-same-color-and-the-data-to-prove-it-12oe ）
- **カード**：丸いカードの繰り返し、カードの中のカード、左端に色の帯を引いた枠（ https://noqta.tn/en/blog/ai-design-slop-overused-ui-patterns-fix-2026 ）
- **字と並べ方**：Inter、中央寄せの大きな見出しに同じ大きさのカード 3 つ、どこも同じ余白
- 「丸い端や大きい角そのものが AI っぽい」という根拠は見つからなかった。原因は**全部を同じにして強弱が無いこと**と、色・グラデーション
- ほかの一覧は look-reviewer の「B. AI がよく作る形」と、frontend-design のスキル

## 4. 本人の選択（角）

- **life-plan-simulator（2026-11-24。D50）**：ボタン（高さ 44px）の角を 3 案で比べ、丸い端（22px）でも、入れる欄と同じ 4px でもなく、8px を選んだ。
  4px には「それはそれでなんかボタンっぽくない気がすんだよな。尖りすぎてて」。調べた定石を聞いたうえで「B で OK です」
- **photo-prompt-builder（2026-10-11）**：見本 A（罫線と余白で区切り、角を付けない形）を選んだ。アプリの方向として角を付けないこともある
- 新しいアプリで角を決めるときは、上の段の考え方で 2〜3 案（例：丸い端・8px・4px）を同じ画面で撮って並べ、本人に選んでもらう（判断基準 P15）。
  Claude のおすすめは、本人が選ぶまで「おすすめ」に留める（T24 では Claude のおすすめ 4px が退けられた）
