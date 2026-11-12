// The built site is the fixture: check source fidelity, controls and computed
// colors in Chrome, without mounting an app or changing engine semantics.
import assert from "node:assert/strict";
import fs from "node:fs/promises";
import path from "node:path";
import { createServer } from "node:http";
import { launch } from "./cdp.mjs";

const root = path.resolve(process.argv[2] ?? "dist");
const index = await fs.readFile(path.join(root, "index.html"), "utf8");
assert(index.indexOf("/appearance.js") < index.indexOf("/signals.css"), "theme initializes before styles paint");
const published = index.match(/href="([^"]+)\/signals.css"/)[1];
let origin;
const server = createServer(async (req, res) => {
  try {
    const name = decodeURIComponent(new URL(req.url, "http://localhost").pathname).replace(/^\/roc-signals\//, "");
    const filename = name === "__fixture.html" ? path.resolve(".build/site-code-fixture.html") : path.resolve(root, !name || name.endsWith("/") ? `${name}index.html` : name);
    if (name !== "__fixture.html" && !filename.startsWith(`${root}/`)) throw Error("outside site");
    let data = await fs.readFile(filename);
    const ext = path.extname(filename);
    if (ext === ".html") data = Buffer.from(data.toString().replaceAll(published, `${origin}/roc-signals`));
    res.writeHead(200, { "content-type": ({ ".css": "text/css", ".js": "text/javascript", ".mjs": "text/javascript", ".html": "text/html; charset=utf-8" })[ext] ?? "application/octet-stream" }).end(data);
  } catch (_) { res.writeHead(404).end("not found"); }
});
await new Promise(resolve => server.listen(0, "127.0.0.1", resolve));
origin = `http://127.0.0.1:${server.address().port}`;
const browser = await launch({ executablePath: process.env.CHROME ?? "google-chrome" });
const page = await browser.newPage();
const emulate = scheme => page.send("Emulation.setEmulatedMedia", { features: [{ name: "prefers-color-scheme", value: scheme }] });
const theme = () => page.evaluate(() => document.documentElement.dataset.theme);
const choose = async value => {
  await page.evaluate(value => {
    const select = document.querySelector("[data-theme-select]");
    select.value = value;
    select.dispatchEvent(new Event("change", { bubbles: true }));
  }, value);
};

try {
  await page.evaluateOnNewDocument(() => {
    Object.defineProperty(navigator, "clipboard", { value: { writeText: async text => { window.copied = text; } } });
  });
  await emulate("dark");
  const url = `${origin}/roc-signals/docs/state-and-events/`;
  await page.goto(url);
  await page.waitForFunction(() => document.querySelector(".code-copy"));
  assert.equal(await theme(), "dark");
  assert.equal(await page.$eval("[data-theme-select]", select => select.value), "system");
  await emulate("light");
  await page.waitForFunction(() => document.documentElement.dataset.theme === "light");
  await choose("dark");
  await emulate("light");
  assert.equal(await theme(), "dark");
  await page.goto(url);
  assert.equal(await theme(), "dark");
  assert.equal(await page.evaluate(() => localStorage.getItem("roc-signals-theme")), "dark");
  await choose("light");
  await emulate("dark");
  assert.equal(await theme(), "light");
  await choose("system");
  assert.equal(await theme(), "dark");
  assert.equal(await page.evaluate(() => localStorage.getItem("roc-signals-theme")), null);
  // Real keyboard operation of the native select and a visible focus ring.
  await page.$eval("[data-theme-select]", select => select.focus());
  await page.keyboard.press("Home");
  await page.keyboard.press("ArrowDown");
  await page.keyboard.press("Enter");
  assert.equal(await theme(), "light");
  await page.click(".code-copy");
  assert.equal(await page.evaluate(() => window.copied), await page.$eval("pre.sample-code code", code => code.textContent));
  assert.equal(await page.$eval(".copy-status", status => status.textContent), "Copied");
  await page.evaluate(() => { navigator.clipboard.writeText = async () => { throw Error("denied"); }; });
  await page.click(".code-copy");
  assert.match(await page.$eval(".copy-status", status => status.textContent), /Copy failed/);
  await page.evaluate(() => {
    localStorage.setItem("roc-signals-theme", "invalid");
  });
  await page.goto(url);
  assert.equal(await page.$eval("[data-theme-select]", select => select.value), "system");
  await page.evaluate(() => dispatchEvent(new StorageEvent("storage", { key: "roc-signals-theme", newValue: "light" })));
  assert.equal(await theme(), "light");
  await page.evaluate(() => dispatchEvent(new StorageEvent("storage", { key: null, newValue: null })));
  assert.equal(await theme(), "dark");

  // The same shared panel/control classes appear inside mounted apps. A site
  // preference must not change the example's authored palette or native inputs.
  await page.evaluate(() => {
    for (const boundary of ["data-signals-wasm", "data-signals-upload-root"]) {
      const root = document.createElement("div");
      root.setAttribute(boundary, "");
      root.dataset.paletteFixture = "";
      root.innerHTML = '<section class="panel"><p class="text-zinc-900">App text</p><button class="button">App button</button><select><option>App input</option></select></section>';
      document.body.append(root);
    }
  });
  const appPalette = () => page.evaluate(() => Array.from(document.querySelectorAll("[data-palette-fixture], [data-palette-fixture] *"), element => {
    const style = getComputedStyle(element);
    return { background: style.backgroundColor, color: style.color, border: style.borderTopColor, scheme: style.colorScheme };
  }));
  await choose("light");
  const lightApp = await appPalette();
  await choose("dark");
  assert.deepEqual(await appPalette(), lightApp, "site themes preserve mounted/uploaded app palettes");
  await page.evaluate(() => document.querySelectorAll("[data-palette-fixture]").forEach(element => element.remove()));

  const pages = ["", "docs/", "examples/"];
  for (const entry of await fs.readdir(path.join(root, "docs"), { withFileTypes: true })) {
    if (entry.isDirectory()) pages.push(`docs/${entry.name}/`);
  }
  await page.send("DOM.enable");
  await page.send("CSS.enable");
  let samples = 0;
  const palettes = {};
  let colors = 0;
  let minimum = Infinity;
  for (const mode of ["light", "dark"]) {
    await choose(mode);
    for (const name of pages) {
      await page.goto(`${origin}/roc-signals/${name}`);
      await page.waitForFunction(() => document.querySelector("[data-theme-select]")?.closest("label").hidden === false);
      for (const sample of await page.evaluate(() => Array.from(document.querySelectorAll("pre[data-sample-file]"), pre => ({ file: pre.dataset.sampleFile, region: pre.dataset.sampleRegion, text: pre.querySelector("code").textContent })))) {
        let source = await fs.readFile(path.join("www/samples", sample.file), "utf8");
        if (sample.region) source = `${source}\n`.split(`# region ${sample.region}\n`)[1].split(`# endregion ${sample.region}\n`)[0];
        const lines = source.split("\n");
        const visible = lines.map((line, i) => /^# (?:end)?region /.test(line.trim()) ? "" : line + (i + 1 < lines.length ? "\n" : "")).join("");
        assert.equal(sample.text, visible, `${sample.file} ${sample.region} source fidelity`);
        samples++;
      }
      // Include every lexer category, even when the current page has none.
      await page.evaluate(() => {
        const fixture = document.createElement("div");
        fixture.className = "prose-signals";
        fixture.innerHTML = `<pre><code>${["plain", "comment", "name", "type", "keyword", "number", "string", "symbol", "invalid"].map(name => `<span class="syntax-${name}">${name} </span>`).join("")}</code></pre>`;
        document.body.append(fixture);
      });
      const documentNode = await page.send("DOM.getDocument");
      const { nodeIds } = await page.send("DOM.querySelectorAll", { nodeId: documentNode.root.nodeId, selector: "a,button,select,pre.sample-code" });
      for (const hovered of [false, true]) {
        for (const nodeId of nodeIds) await page.send("CSS.forcePseudoState", { nodeId, forcedPseudoClasses: hovered ? ["hover", "focus-visible"] : ["focus-visible"] });
        const checked = await page.evaluate(() => {
          const rgb = value => value.match(/[\d.]+/g).map(Number);
          const luminance = value => rgb(value).slice(0, 3).map(c => { const x = c / 255; return x <= .04045 ? x / 12.92 : ((x + .055) / 1.055) ** 2.4; }).reduce((sum, c, i) => sum + c * [.2126, .7152, .0722][i], 0);
          // WCAG 2.2 relative luminance: compare the unrounded ratio.
          // https://www.w3.org/WAI/WCAG22/Understanding/contrast-minimum.html
          const ratio = (a, b) => { const x = luminance(a), y = luminance(b); return (Math.max(x, y) + .05) / (Math.min(x, y) + .05); };
          const background = element => {
            const layers = [];
            for (let current = element; current; current = current.parentElement) {
              const style = getComputedStyle(current);
              // Featured cards have pale text over a dark gradient. Its lightest
              // endpoint is the conservative contrast bound for the whole card.
              const stops = style.backgroundImage.match(/rgba?\([^)]+\)/g);
              const color = stops ? stops.reduce((a, b) => luminance(a) > luminance(b) ? a : b) : style.backgroundColor;
              layers.unshift(rgb(color));
            }
            const result = layers.reduce((behind, color) => {
              const alpha = color[3] ?? 1;
              return color.slice(0, 3).map((value, i) => value * alpha + behind[i] * (1 - alpha));
            }, [255, 255, 255]);
            return `rgb(${result.join(",")})`;
          };
          const failures = [];
          let count = 0, min = Infinity;
          const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
          while (walker.nextNode()) {
            const node = walker.currentNode, element = node.parentElement;
            if (!node.textContent.trim() || element.closest("script,style,select,[aria-hidden=true]")) continue;
            const range = document.createRange(); range.selectNode(node);
            if (!range.getBoundingClientRect().width) continue;
            const color = getComputedStyle(element).color, bg = background(element);
            const value = ratio(color, bg);
            count++; min = Math.min(min, value);
            if (value < 4.5) failures.push(`${element.className}: ${color} on ${bg} = ${value}`);
          }
          for (const element of document.querySelectorAll(".theme-control select,.code-copy")) {
            const style = getComputedStyle(element), bg = background(element);
            for (const [label, value] of [["control text", ratio(style.color, bg)], ["control border", ratio(style.borderTopColor, bg)]]) {
              if (value < (label === "control text" ? 4.5 : 3)) failures.push(`${label}: ${value}`);
            }
            element.focus();
            const focused = getComputedStyle(element);
            if (focused.outlineStyle === "none" || parseFloat(focused.outlineWidth) < 3) failures.push("missing visible focus outline");
            const focus = focused.outlineColor;
            const focusRatio = ratio(focus, background(element.parentElement));
            if (focusRatio < 3) failures.push(`focus: ${focusRatio}`);
          }
          const tokens = Object.fromEntries(Array.from(document.querySelectorAll("body > .prose-signals pre span"), element => {
            const foreground = getComputedStyle(element).color, bg = background(element);
            return [element.className, { foreground, background: bg, contrast: ratio(foreground, bg) }];
          }));
          return { failures, count, min, tokens };
        });
        assert.deepEqual(checked.failures, [], `${mode} ${name} ${hovered ? "hover" : "normal"} contrast`);
        palettes[mode] = checked.tokens;
        colors += checked.count;
        minimum = Math.min(minimum, checked.min);
      }
      for (const nodeId of nodeIds) await page.send("CSS.forcePseudoState", { nodeId, forcedPseudoClasses: [] });
    }
  }
  await fs.writeFile(".build/site-contrast.json", JSON.stringify({ textMinimum: 4.5, controlMinimum: 3, palettes }, null, 2) + "\n");
  await page.goto(`${origin}/roc-signals/__fixture.html`);
  assert.equal(await page.$eval("code", code => code.textContent), '# café & <script>alert(1)</script>\r\n\tvalue = "<&>"  \n\nunterminated = "\u0301\n');
  assert.equal(await page.evaluate(() => document.scripts.length), 0);
  // Invalid and unavailable storage still leave a working system preference.
  await page.evaluateOnNewDocument(() => { Object.defineProperty(window, "localStorage", { get() { throw Error("storage unavailable"); } }); });
  await emulate("dark");
  await page.goto(url);
  assert.equal(await theme(), "dark");
  await choose("light");
  assert.equal(await theme(), "light");
  await fs.mkdir(".build/site-screenshots", { recursive: true });
  for (const [width, height, label] of [[1365, 1000, "desktop"], [390, 844, "mobile"]]) {
    await page.send("Emulation.setDeviceMetricsOverride", { width, height, deviceScaleFactor: 1, mobile: width < 600 });
    for (const mode of ["light", "dark"]) {
      await choose(mode);
      assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true, `${label} horizontal overflow`);
      const { data } = await page.send("Page.captureScreenshot", { format: "png" });
      await fs.writeFile(`.build/site-screenshots/${label}-${mode}.png`, Buffer.from(data, "base64"));
    }
  }
  console.log(`site browser: passed ${samples} sample renderings, ${colors} text colors; minimum contrast ${minimum}:1; both themes, system changes, storage, keyboard, copy, escaping and mobile layout`);
} finally {
  await browser.close();
  await new Promise(resolve => server.close(resolve));
}
