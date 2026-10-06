#!/usr/bin/env node
// 伏せた案を節ごとに見比べて選ぶ比較ページ（HTML 1 枚）を作る
//
// 使い方： node compete-page.mjs --run <作業場所 RUN> --out <書き出す HTML> --title <ページの名前>
// 呼び元： compete スキル（9 節）。できた HTML は非公開の Artifact に載せ、claude.ai の URL を本人に渡す
// 読むもの（作り手の情報は読まない。RUN/makers と RUN/rebuttal は開かない）：
//   RUN/kind・RUN/input/brief.md・RUN/input/parts.txt・RUN/blind/labels.txt
//   RUN/blind/<伏せ字>/（design.md、または index.html と aim.md。あれば rebuttal.md）
//   RUN/reviews/<伏せ字>.md（あれば）・RUN/judges/<審査役>.md（あれば）
// ページの作り：
//   - 審査役のおすすめ → 節ごとの比較と選択 → 返す言葉（コピーできる）→ 案ごとのレビュー・反論 → ブリーフ
//   - design は design.md を「## 節の名前」で切り、節ごとに案を横に並べる。screen は見本を枠（iframe）の中に出し、幅を 1280px と 375px で切り替える
//     （単独のタブで開くと Artifact の中では止められるため。試行 3）
//   - どの案も同じ色・同じ形で出す（色や位置で有利・不利を作らない）
//   - Markdown は cdnjs の marked と DOMPurify で表示する。読み込めなければ文字のまま出す
// 終了コード：0 成功 / 1 書き込みの失敗 / 2 指定の誤り・材料の欠け
import { readFileSync, writeFileSync, existsSync, readdirSync } from "node:fs";
import { join, resolve } from "node:path";

// 指定の誤りを出して終了する
function usageError(message) {
  process.stderr.write(`compete-page.mjs: ${message}\n`);
  process.exit(2);
}

// 引数を読む
function parseArgs(argv) {
  const args = {};
  for (let i = 0; i < argv.length; i += 2) {
    const key = argv[i];
    const value = argv[i + 1];
    if (!["--run", "--out", "--title"].includes(key)) usageError(`知らない指定です: ${key}`);
    if (value === undefined) usageError(`${key} に値がありません`);
    args[key.slice(2)] = value;
  }
  for (const key of ["run", "out", "title"]) {
    if (!args[key]) usageError(`--${key} がありません。使い方: node compete-page.mjs --run <RUN> --out <HTML> --title <ページの名前>`);
  }
  return args;
}

// ファイルを読む。無ければ null
function readOptional(path) {
  return existsSync(path) ? readFileSync(path, "utf8") : null;
}

// ファイルを読む。無ければ止める
function readRequired(path, what) {
  if (!existsSync(path)) usageError(`${what}がありません: ${path}`);
  return readFileSync(path, "utf8");
}

// 行の一覧にする（空行を除く）
function lines(text) {
  return text.split(/\r?\n/).map((s) => s.trim()).filter(Boolean);
}

// HTML の中の <script type="application/json"> に安全に埋めるため、< を逃がす
function embedJson(value) {
  // JSON の中の行区切りの文字（U+2028・U+2029）も逃がす。古い JavaScript では文字列の中で改行として扱われるため
  const lineSep = String.fromCharCode(0x2028);
  const paraSep = String.fromCharCode(0x2029);
  return JSON.stringify(value).replace(/</g, "\\u003c").split(lineSep).join("\\u2028").split(paraSep).join("\\u2029");
}

// HTML の文字を逃がす
function escapeHtml(text) {
  return text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
}

// 案の材料を集める
function collect(run) {
  const kind = readRequired(join(run, "kind"), "kind ").trim();
  if (!["design", "screen"].includes(kind)) usageError(`kind が design でも screen でもありません: ${kind}`);
  const parts = lines(readRequired(join(run, "input", "parts.txt"), "節の一覧 "));
  if (parts.length === 0) usageError("節の一覧が空です");
  const labels = lines(readRequired(join(run, "blind", "labels.txt"), "伏せ字の一覧（compete-blind.sh のあとに使います）"));
  if (labels.length < 2) usageError("伏せた案が 2 つ未満です");
  const candidates = labels.map((label) => {
    const dir = join(run, "blind", label);
    const item = {
      label,
      review: readOptional(join(run, "reviews", `${label}.md`)),
      rebuttal: readOptional(join(dir, "rebuttal.md")),
    };
    if (kind === "design") {
      item.design = readRequired(join(dir, "design.md"), `案 ${label} の design.md `);
    } else {
      item.html = readRequired(join(dir, "index.html"), `案 ${label} の index.html `);
      item.aim = readRequired(join(dir, "aim.md"), `案 ${label} の aim.md `);
    }
    return item;
  });
  const judgesDir = join(run, "judges");
  const judges = existsSync(judgesDir)
    ? readdirSync(judgesDir).filter((f) => f.endsWith(".md")).sort().map((f) => ({
        name: f.replace(/\.md$/, ""),
        text: readFileSync(join(judgesDir, f), "utf8"),
      }))
    : [];
  return { kind, parts, candidates, judges, brief: readRequired(join(run, "input", "brief.md"), "ブリーフ ") };
}

// ページの HTML を組み立てる
function render(title, data) {
  return `<title>${escapeHtml(title)}</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=BIZ+UDPGothic:wght@400;700&family=Zen+Kaku+Gothic+New:wght@700;900&family=IBM+Plex+Mono:wght@500&display=swap">
<style>
/* 投票用紙のように、どの案も同じ枠・同じ色で並べる。目を引く色は「選んだ所」だけに使う */
:root {
  --bg: #f3f5f8; --surface: #ffffff; --ink: #1c2230; --muted: #5a6476; --line: #d6dbe4;
  --accent: #2d55c8; --accent-soft: #e3e9f9; --warn: #9a5b00;
  --font-display: "Zen Kaku Gothic New", "Hiragino Sans", "Noto Sans JP", sans-serif;
  --font-body: "BIZ UDPGothic", "Hiragino Sans", "Noto Sans JP", "Yu Gothic", sans-serif;
  --font-mono: "IBM Plex Mono", ui-monospace, "SFMono-Regular", Menlo, monospace;
}
@media (prefers-color-scheme: dark) {
  :root:not([data-theme="light"]) {
    --bg: #11151c; --surface: #19202b; --ink: #e5e9f0; --muted: #9aa4b6; --line: #2b3444;
    --accent: #84a2f2; --accent-soft: #22304d; --warn: #e0a24a; color-scheme: dark;
  }
}
:root[data-theme="dark"] {
  --bg: #11151c; --surface: #19202b; --ink: #e5e9f0; --muted: #9aa4b6; --line: #2b3444;
  --accent: #84a2f2; --accent-soft: #22304d; --warn: #e0a24a; color-scheme: dark;
}
* { box-sizing: border-box; }
body { background: var(--bg); color: var(--ink); font-family: var(--font-body); font-size: 15px; line-height: 1.75; }
.wrap { max-width: 1240px; margin: 0 auto; padding-inline: 16px; padding-block: 28px 64px; display: grid; gap: 36px; }
h1, h2, h3 { font-family: var(--font-display); text-wrap: balance; line-height: 1.35; margin: 0; }
h1 { font-size: 1.75rem; font-weight: 900; }
h2 { font-size: 1.25rem; font-weight: 700; }
.lead { color: var(--muted); margin: 6px 0 0; max-width: 65ch; }
section { display: grid; gap: 14px; }
.eyebrow { font-family: var(--font-mono); font-size: 0.75rem; letter-spacing: 0.08em; color: var(--muted); text-transform: uppercase; }
details { background: var(--surface); border: 1px solid var(--line); border-radius: 8px; padding-inline: 16px; padding-block: 10px; }
details > summary { cursor: pointer; font-weight: 700; }
details[open] > summary { margin-bottom: 8px; }
.md { min-width: 0; overflow-wrap: anywhere; }
.md h1, .md h2, .md h3, .md h4 { font-size: 1rem; margin-block: 0.9em 0.3em; }
.md table { border-collapse: collapse; font-size: 0.9rem; }
.md th, .md td { border: 1px solid var(--line); padding: 4px 8px; vertical-align: top; text-align: left; }
.md pre { background: var(--bg); padding: 10px; border-radius: 6px; overflow-x: auto; white-space: pre-wrap; }
.md .tablebox { overflow-x: auto; }
.part { display: grid; gap: 12px; padding-block: 18px; border-top: 1px solid var(--line); }
.part-head { display: flex; flex-wrap: wrap; gap: 8px 16px; align-items: baseline; justify-content: space-between; }
.cols { display: grid; gap: 12px; grid-template-columns: repeat(auto-fit, minmax(280px, 1fr)); }
.col { min-width: 0; background: var(--surface); border: 1px solid var(--line); border-radius: 8px; padding-inline: 14px; padding-block: 10px; }
.tag { font-family: var(--font-mono); font-weight: 500; font-size: 0.85rem; display: inline-block; min-width: 2.2em; text-align: center;
  border: 1px solid var(--line); border-radius: 4px; padding-inline: 6px; color: var(--ink); background: var(--bg); }
.choices { display: flex; flex-wrap: wrap; gap: 8px; align-items: center; }
.choice { display: inline-flex; gap: 6px; align-items: center; border: 1px solid var(--line); border-radius: 999px; padding-inline: 12px; padding-block: 4px;
  background: var(--surface); cursor: pointer; }
.choice:has(input:checked) { border-color: var(--accent); background: var(--accent-soft); }
.choice input { accent-color: var(--accent); }
.note { flex: 1 1 220px; min-width: 0; font: inherit; padding-inline: 10px; padding-block: 4px; border: 1px solid var(--line); border-radius: 6px;
  background: var(--surface); color: var(--ink); }
.viewer { display: grid; gap: 10px; }
.toolbar { display: flex; flex-wrap: wrap; gap: 8px; align-items: center; }
button { font: inherit; border: 1px solid var(--line); background: var(--surface); color: var(--ink); border-radius: 6px; padding-inline: 12px; padding-block: 4px; cursor: pointer; }
button[aria-pressed="true"] { border-color: var(--accent); background: var(--accent-soft); }
button:focus-visible, input:focus-visible, textarea:focus-visible, summary:focus-visible { outline: 2px solid var(--accent); outline-offset: 2px; }
.frame-box { overflow-x: auto; border: 1px solid var(--line); border-radius: 8px; background: var(--surface); }
.frame-box iframe { display: block; border: 0; height: 78vh; background: #ffffff; }
.answer { display: grid; gap: 8px; }
.answer textarea { width: 100%; min-height: 6.5em; font-family: var(--font-mono); font-size: 0.9rem; padding: 10px; border: 1px solid var(--line);
  border-radius: 6px; background: var(--surface); color: var(--ink); resize: vertical; }
.status { color: var(--muted); font-size: 0.85rem; min-height: 1.2em; }
.warn { color: var(--warn); }
.fair { font-size: 0.85rem; color: var(--muted); }
@media (prefers-reduced-motion: reduce) { * { scroll-behavior: auto !important; } }
</style>
<script src="https://cdnjs.cloudflare.com/ajax/libs/marked/12.0.2/marked.min.js"></script>
<script src="https://cdnjs.cloudflare.com/ajax/libs/dompurify/3.1.6/purify.min.js"></script>
<script type="application/json" id="compete-data">${embedJson(data)}</script>
<div class="wrap">
  <header>
    <p class="eyebrow">コンペ ・ 案 <span id="count"></span> ・ 節 <span id="part-count"></span></p>
    <h1>${escapeHtml(title)}</h1>
    <p class="lead">作り手の名前を伏せて並べています。伏せ字（A・B・C…）の順番は乱数で決めたもので、作り手とは関係ありません。
    節ごとに 1 つ選ぶと、下の「返す言葉」ができあがります。</p>
  </header>
  <section id="judges" aria-labelledby="judges-h">
    <h2 id="judges-h">審査役のおすすめ</h2>
    <p class="fair">審査役は作り手を知らない AI です。おすすめは参考で、選ぶのはあなたです。</p>
    <div id="judge-list"></div>
  </section>
  <section id="compare" aria-labelledby="compare-h">
    <h2 id="compare-h">節ごとに選ぶ</h2>
    <div id="viewer" class="viewer" hidden></div>
    <div id="parts"></div>
  </section>
  <section class="answer" aria-labelledby="answer-h">
    <h2 id="answer-h">返す言葉</h2>
    <p class="fair">これをコピーして、そのまま会話に貼ってください。メモは空でかまいません。</p>
    <textarea id="answer" readonly aria-label="返す言葉"></textarea>
    <div class="toolbar"><button type="button" id="copy">コピー</button><span class="status" id="copy-status" role="status"></span></div>
  </section>
  <section aria-labelledby="detail-h">
    <h2 id="detail-h">案ごとのレビューと反論</h2>
    <div id="details" style="display:grid;gap:10px"></div>
  </section>
  <section aria-labelledby="brief-h">
    <h2 id="brief-h">お題の説明書（ブリーフ）</h2>
    <details><summary>ブリーフを読む</summary><div class="md" id="brief"></div></details>
  </section>
</div>
<script>
(function () {
  const data = JSON.parse(document.getElementById("compete-data").textContent);
  const canMd = typeof window.marked !== "undefined" && typeof window.DOMPurify !== "undefined";

  // Markdown を安全な HTML にして要素に入れる。ライブラリが無ければ文字のまま
  function putMd(el, text) {
    if (!text) { el.textContent = "（なし）"; return; }
    if (canMd) {
      el.innerHTML = window.DOMPurify.sanitize(window.marked.parse(text));
      el.querySelectorAll("table").forEach(function (t) {
        const box = document.createElement("div"); box.className = "tablebox";
        t.parentNode.insertBefore(box, t); box.appendChild(t);
      });
    } else {
      const pre = document.createElement("pre"); pre.textContent = text; el.replaceChildren(pre);
    }
  }

  // 要素を作る
  function make(tag, cls, text) {
    const el = document.createElement(tag);
    if (cls) el.className = cls;
    if (text !== undefined) el.textContent = text;
    return el;
  }

  // design.md を「## 節の名前」で切り分ける
  function splitSections(md) {
    const out = {}; let current = null; let buf = [];
    md.split(/\\r?\\n/).forEach(function (line) {
      const m = /^##\\s+(.+?)\\s*$/.exec(line);
      if (m && !line.startsWith("###")) {
        if (current !== null) out[current] = buf.join("\\n");
        current = m[1]; buf = [];
      } else if (current !== null) {
        buf.push(line);
      }
    });
    if (current !== null) out[current] = buf.join("\\n");
    return out;
  }

  document.getElementById("count").textContent = data.candidates.length;
  document.getElementById("part-count").textContent = data.parts.length;

  // 審査役のおすすめ
  const judgeList = document.getElementById("judge-list");
  if (data.judges.length === 0) {
    judgeList.append(make("p", "warn", "審査役の判定はまだありません。"));
  } else {
    judgeList.style.display = "grid"; judgeList.style.gap = "10px";
    data.judges.forEach(function (j, i) {
      const d = make("details"); if (i === 0) d.open = true;
      d.append(make("summary", "", "審査役 " + (i + 1) + "（" + j.name + "）の判定"));
      const body = make("div", "md"); putMd(body, j.text); d.append(body);
      judgeList.append(d);
    });
  }

  // 画面の見本の表示枠（screen のとき）
  if (data.kind === "screen") {
    const viewer = document.getElementById("viewer"); viewer.hidden = false;
    const bar = make("div", "toolbar");
    const box = make("div", "frame-box");
    const frame = document.createElement("iframe");
    frame.setAttribute("sandbox", "allow-scripts");
    frame.setAttribute("title", "見本");
    const aim = make("details"); aim.open = true;
    const aimBody = make("div", "md");
    let width = 1280; let current = data.candidates[0].label;
    const tabButtons = []; const widthButtons = [];
    function show() {
      const c = data.candidates.find(function (x) { return x.label === current; });
      frame.srcdoc = c.html; frame.style.width = width + "px";
      aim.querySelector("summary").textContent = "案 " + c.label + " の狙い"; putMd(aimBody, c.aim);
      tabButtons.forEach(function (b) { b.setAttribute("aria-pressed", String(b.dataset.label === current)); });
      widthButtons.forEach(function (b) { b.setAttribute("aria-pressed", String(Number(b.dataset.width) === width)); });
    }
    data.candidates.forEach(function (c) {
      const b = make("button", "", "案 " + c.label); b.type = "button"; b.dataset.label = c.label;
      b.addEventListener("click", function () { current = c.label; show(); }); tabButtons.push(b); bar.append(b);
    });
    bar.append(make("span", "fair", "　幅："));
    [[1280, "広い画面 1280px"], [375, "スマホ 375px"]].forEach(function (w) {
      const b = make("button", "", w[1]); b.type = "button"; b.dataset.width = String(w[0]);
      b.addEventListener("click", function () { width = w[0]; show(); }); widthButtons.push(b); bar.append(b);
    });
    aim.append(make("summary")); aim.append(aimBody);
    box.append(frame); viewer.append(bar, box, aim); show();
  }

  // 節ごとの比較と選択
  const partsEl = document.getElementById("parts");
  const sections = data.kind === "design" ? data.candidates.map(function (c) { return splitSections(c.design); }) : null;
  data.parts.forEach(function (part, pi) {
    const wrap = make("div", "part");
    const head = make("div", "part-head");
    head.append(make("h3", "", part));
    wrap.append(head);
    if (sections) {
      const cols = make("div", "cols");
      data.candidates.forEach(function (c, ci) {
        const col = make("div", "col");
        col.append(make("span", "tag", c.label));
        const body = make("div", "md");
        const text = sections[ci][part];
        if (text === undefined) { body.append(make("p", "warn", "この案にはこの節の見出しがありません。")); } else { putMd(body, text); }
        col.append(body); cols.append(col);
      });
      wrap.append(cols);
    }
    const choices = make("div", "choices");
    const opts = data.candidates.map(function (c) { return c.label; }).concat(["どれでもない"]);
    opts.forEach(function (o, oi) {
      const lab = make("label", "choice");
      const input = document.createElement("input");
      input.type = "radio"; input.name = "part-" + pi; input.value = o; input.id = "part-" + pi + "-" + oi;
      input.addEventListener("change", updateAnswer);
      lab.append(input, document.createTextNode(o === "どれでもない" ? o : "案 " + o));
      choices.append(lab);
    });
    const note = document.createElement("input");
    note.type = "text"; note.className = "note"; note.id = "note-" + pi; note.placeholder = "メモ（任意。例：見出しは C の太字にしたい）";
    note.setAttribute("aria-label", part + " のメモ");
    note.addEventListener("input", updateAnswer);
    choices.append(note);
    wrap.append(choices);
    partsEl.append(wrap);
  });

  // 返す言葉を組み立てる
  function updateAnswer() {
    const rows = data.parts.map(function (part, pi) {
      const picked = document.querySelector('input[name="part-' + pi + '"]:checked');
      const note = document.getElementById("note-" + pi).value.trim();
      return part + "=" + (picked ? picked.value : "未選択") + (note ? "（" + note + "）" : "");
    });
    document.getElementById("answer").value = rows.join("、");
  }
  updateAnswer();

  document.getElementById("copy").addEventListener("click", function () {
    const area = document.getElementById("answer"); const status = document.getElementById("copy-status");
    const fallback = function () { area.focus(); area.select(); status.textContent = "選択しました。コピーしてください。"; };
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(area.value).then(function () { status.textContent = "コピーしました。"; }, fallback);
    } else { fallback(); }
  });

  // 案ごとのレビューと反論
  const detailsEl = document.getElementById("details");
  data.candidates.forEach(function (c) {
    const d = make("details");
    d.append(make("summary", "", "案 " + c.label + " のレビュー" + (c.rebuttal ? "と反論" : "")));
    const r = make("div", "md"); putMd(r, c.review || "（レビューはまだありません）"); d.append(r);
    if (c.rebuttal) { d.append(make("h3", "", "反論 1 回の答え")); const rb = make("div", "md"); putMd(rb, c.rebuttal); d.append(rb); }
    detailsEl.append(d);
  });

  putMd(document.getElementById("brief"), data.brief);
})();
</script>
`;
}

const args = parseArgs(process.argv.slice(2));
const run = resolve(args.run);
const data = collect(run);
try {
  writeFileSync(resolve(args.out), render(args.title, data));
} catch (e) {
  process.stderr.write(`compete-page.mjs: 書けません: ${args.out}（${e.message}）\n`);
  process.exit(1);
}
process.stdout.write(`${resolve(args.out)}\n`);
