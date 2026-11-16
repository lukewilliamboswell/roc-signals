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
    // Localize navigation and assets without rewriting a published URL that
    // appears as text inside a source sample: that text is the fidelity oracle.
    if (ext === ".html") data = Buffer.from(data.toString().replace(/(\b(?:href|src)=["'])([^"']*)/g, (attribute, prefix, value) =>
      value.startsWith(`${published}/`) ? `${prefix}${origin}/roc-signals${value.slice(published.length)}` : attribute));
    res.writeHead(200, { "content-type": ({ ".css": "text/css", ".js": "text/javascript", ".mjs": "text/javascript", ".html": "text/html; charset=utf-8" })[ext] ?? "application/octet-stream" }).end(data);
  } catch (_) { res.writeHead(404).end("not found"); }
});
await new Promise(resolve => server.listen(0, "127.0.0.1", resolve));
origin = `http://127.0.0.1:${server.address().port}`;
// The checked corpus currently uses one simple local platform declaration.
// This independent oracle permits only that header URL to change; every other
// byte of every raw download must match its checked source.
const placeholder = "<package release URL here>";
const publishedSample = (name, bytes) => name.endsWith(".roc")
  ? Buffer.from(bytes.toString("utf8").replace(/^(app \[main\] \{ pf: platform )"(?:\.\.\/)+platform\/main\.roc"/, `$1"${placeholder}"`))
  : bytes;
let downloads = 0;
async function checkDownloads(directory, prefix = "") {
  for (const entry of await fs.readdir(directory, { withFileTypes: true })) {
    if (entry.name.startsWith(".") || entry.name === "dist") continue;
    const name = prefix + entry.name;
    if (entry.isDirectory()) await checkDownloads(path.join(directory, entry.name), `${name}/`);
    else if ([".roc", ".scm", ".html", ".mjs"].some(suffix => name.endsWith(suffix))) {
      const checked = await fs.readFile(path.join(directory, entry.name));
      const output = await fs.readFile(path.join(root, "samples", name));
      assert.deepEqual(output, publishedSample(name, checked), `${name} published download changes only its header package URL`);
      if (name.endsWith(".roc")) assert(!output.includes(Buffer.from('platform "../../')), `${name} has no checkout platform URL`);
      downloads++;
    }
  }
}
await checkDownloads("www/samples");
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
  await page.$eval("[data-theme-select]", select => {
    select.focus();
    window.themeKeyboardEvents = [];
    for (const type of ["input", "change"]) select.addEventListener(type, event => {
      window.themeKeyboardEvents.push({ type, trusted: event.isTrusted, value: select.value });
    }, { once: true });
  });
  // Native typeahead selects Light without depending on a platform's popup
  // navigation keys. The browser must perform the choice and emit its events.
  await page.keyboard.press("l");
  assert.deepEqual(await page.evaluate(() => window.themeKeyboardEvents), [
    { type: "input", trusted: true, value: "light" },
    { type: "change", trusted: true, value: "light" },
  ]);
  assert.equal(await theme(), "light");
  // The copy action occupies the code corner rather than a toolbar row.
  // A keyboard user can reveal and activate the otherwise quiet control.
  await page.$eval("pre.sample-code", pre => pre.focus());
  await page.keyboard.down("Shift");
  await page.keyboard.press("Tab");
  await page.keyboard.up("Shift");
  // Read the visibility after the authored opacity transition has settled.
  await page.waitForFunction(() => getComputedStyle(document.querySelector(".code-copy")).opacity === "1");
  const copyControl = await page.evaluate(() => {
    const button = document.querySelector(".code-copy");
    const wrapper = button.closest(".code-sample");
    const b = button.getBoundingClientRect(), w = wrapper.getBoundingClientRect();
    const pre = wrapper.querySelector("pre").getBoundingClientRect();
    return { active: document.activeElement === button, label: button.getAttribute("aria-label"), text: button.textContent.trim(), opacity: getComputedStyle(button).opacity, top: b.top - w.top, right: w.right - b.right, preTop: pre.top - w.top, preRight: pre.right, buttonLeft: b.left, width: b.width, height: b.height };
  });
  assert.equal(copyControl.active, true, "Tab reaches the copy action");
  assert.equal(copyControl.label, "Copy code sample");
  assert.equal(copyControl.text, "");
  assert.equal(copyControl.opacity, "1", "keyboard focus reveals copy");
  assert(copyControl.top >= 0 && copyControl.top < 16 && copyControl.right >= 0 && copyControl.right < 16);
  assert(copyControl.preTop <= 2, "copy action adds no toolbar above the code");
  assert(copyControl.preRight <= copyControl.buttonLeft, "code content never passes under copy");
  assert(copyControl.width >= 32 && copyControl.height >= 32);
  await page.evaluate(() => document.activeElement.blur());
  await page.send("Input.dispatchMouseEvent", { type: "mouseMoved", x: 0, y: 0 });
  await page.waitForFunction(() => getComputedStyle(document.querySelector(".code-copy")).opacity === (matchMedia("(hover: hover)").matches ? "0" : "1"));
  const quiet = await page.evaluate(() => ({ hover: matchMedia("(hover: hover)").matches, opacity: getComputedStyle(document.querySelector(".code-copy")).opacity }));
  assert.equal(quiet.opacity, quiet.hover ? "0" : "1");
  await page.click(".code-copy");
  await page.waitForFunction(() => typeof window.copied === "string");
  assert.equal(await page.evaluate(() => window.copied), await page.$eval("pre.sample-code code", code => code.textContent));
  assert.equal(await page.$eval(".copy-status", status => status.textContent), "Copied");
  await page.evaluate(() => { navigator.clipboard.writeText = async () => { throw Error("denied"); }; });
  await page.click(".code-copy");
  await page.waitForFunction(() => document.querySelector(".copy-status").textContent.includes("Copy failed"));
  assert.match(await page.$eval(".copy-status", status => status.textContent), /Copy failed/);
  await page.evaluate(() => document.activeElement.blur());
  await page.send("Input.dispatchMouseEvent", { type: "mouseMoved", x: 0, y: 0 });
  await page.send("Emulation.setTouchEmulationEnabled", { enabled: true, maxTouchPoints: 1 });
  await page.send("Emulation.setDeviceMetricsOverride", { width: 390, height: 844, deviceScaleFactor: 1, mobile: true });
  await page.waitForFunction(() => getComputedStyle(document.querySelector(".code-copy")).opacity === "1");
  assert.equal(await page.evaluate(() => matchMedia("(hover: none)").matches), true);
  assert.equal(await page.$eval(".code-copy", button => getComputedStyle(button).opacity), "1", "touch users always see copy");
  await page.send("Emulation.setTouchEmulationEnabled", { enabled: false });
  await page.send("Emulation.clearDeviceMetricsOverride");
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
  // Exercise a real pointer hover with live transitions before the bulk
  // endpoint checks disable them. Sampling the first animation frame hid a
  // primary-link hover color that settled to dark green on dark green.
  const hoverEndpoints = {};
  for (const mode of ["light", "dark"]) {
    await choose(mode);
    await page.goto(`${origin}/roc-signals/`);
    const point = await page.$eval("a.button-primary", button => {
      const rect = button.getBoundingClientRect();
      return { x: rect.x + rect.width / 2, y: rect.y + rect.height / 2 };
    });
    await page.send("Input.dispatchMouseEvent", { type: "mouseMoved", ...point });
    const endpoint = await page.evaluate(async () => {
      const button = document.querySelector("a.button-primary");
      // Flush hover styles, then await every CSS transition's final frame.
      getComputedStyle(button).color;
      await Promise.all(button.getAnimations().map(animation => animation.finished));
      const style = getComputedStyle(button);
      const ink = document.createElement("span");
      ink.style.color = "var(--site-accent-ink)";
      document.body.append(ink);
      const expected = getComputedStyle(ink).color;
      ink.remove();
      return { color: style.color, background: style.backgroundColor, expected };
    });
    assert.equal(endpoint.color, endpoint.expected, `${mode} real primary hover after transitions finish`);
    hoverEndpoints[mode] = endpoint;
    await page.send("Input.dispatchMouseEvent", { type: "mouseMoved", x: 0, y: 0 });
  }

  await page.send("DOM.enable");
  await page.send("CSS.enable");
  let samples = 0;
  let schemeSamples = 0;
  let htmlSamples = 0;
  const schemeCopied = {};
  const htmlCopied = {};
  const palettes = {};
  let colors = 0;
  let minimum = Infinity;
  for (const mode of ["light", "dark"]) {
    await choose(mode);
    for (const name of pages) {
      await page.goto(`${origin}/roc-signals/${name}`);
      await page.waitForFunction(() => document.querySelector("[data-theme-select]")?.closest("label").hidden === false);
      for (const sample of await page.evaluate(() => Array.from(document.querySelectorAll("pre[data-sample-file]"), pre => ({ file: pre.dataset.sampleFile, region: pre.dataset.sampleRegion, text: pre.querySelector("code").textContent, categories: Array.from(pre.querySelectorAll("span"), span => span.className) })))) {
        let source = await fs.readFile(path.join(root, "samples", sample.file), "utf8");
        if (sample.region) source = `${source}\n`.split(`# region ${sample.region}\n`)[1].split(`# endregion ${sample.region}\n`)[0];
        const lines = source.split("\n");
        const visible = lines.map((line, i) => /^# (?:end)?region /.test(line.trim()) ? "" : line + (i + 1 < lines.length ? "\n" : "")).join("");
        assert.equal(sample.text, visible, `${sample.file} ${sample.region} source fidelity`);
        if (sample.file.endsWith(".scm")) {
          for (const category of ["syntax-keyword", "syntax-string", "syntax-symbol"]) assert(sample.categories.includes(category), `${sample.file} highlights ${category}`);
          schemeSamples++;
          if (!schemeCopied[mode]) {
            await page.click('.code-sample:has(pre[data-sample-file$=".scm"]) .code-copy');
            await page.waitForFunction(expected => window.copied === expected, {}, sample.text);
            assert.equal(await page.evaluate(() => window.copied), sample.text, `${mode} Scheme copy preserves source`);
            schemeCopied[mode] = true;
          }
        }
        if (sample.file.endsWith(".html")) {
          for (const category of ["syntax-keyword", "syntax-name", "syntax-string", "syntax-symbol"]) assert(sample.categories.includes(category), `${sample.file} highlights HTML ${category}`);
          htmlSamples++;
          if (!htmlCopied[mode]) {
            await page.click('.code-sample:has(pre[data-sample-file$=".html"]) .code-copy');
            await page.waitForFunction(expected => window.copied === expected, {}, sample.text);
            assert.equal(await page.evaluate(() => window.copied), sample.text, `${mode} HTML copy preserves source`);
            const response = await fetch(`${origin}/roc-signals/samples/${sample.file}`);
            assert.equal(response.status, 200);
            assert.equal(await response.text(), sample.text, "HTML download matches visible and copied source");
            htmlCopied[mode] = true;
          }
        }
        samples++;
      }
      // Contrast belongs to the settled CSS states. Suppress transitions for
      // this exhaustive pass so forcePseudoState cannot sample an earlier
      // frame and accidentally accept an inaccessible destination color.
      await page.evaluate(() => {
        const style = document.createElement("style");
        style.textContent = "*, *::before, *::after { transition: none !important; animation: none !important; }";
        document.head.append(style);
      });
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
          // The ground behind an element, as the foreground `against` meets
          // it. A ground drawn with a gradient (the page's grid of dots, a
          // legend split between page and panel) is taken at the stop that
          // contrasts least with that foreground, so the bound holds wherever
          // on the gradient the foreground falls.
          const background = (element, against) => {
            const chain = [];
            for (let current = element; current; current = current.parentElement) chain.unshift(getComputedStyle(current));
            const over = (behind, color) => {
              const alpha = color[3] ?? 1;
              return color.slice(0, 3).map((value, i) => value * alpha + behind[i] * (1 - alpha));
            };
            const text = value => `rgb(${value.join(",")})`;
            const result = chain.reduce((behind, style) => {
              const ground = over(behind, rgb(style.backgroundColor));
              const stops = style.backgroundImage.match(/rgba?\([^)]+\)/g);
              if (!stops) return ground;
              return stops.map(stop => over(ground, rgb(stop))).reduce((a, b) => ratio(against, text(a)) <= ratio(against, text(b)) ? a : b);
            }, [255, 255, 255]);
            return text(result);
          };
          const failures = [];
          let count = 0, min = Infinity;
          const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
          while (walker.nextNode()) {
            const node = walker.currentNode, element = node.parentElement;
            if (!node.textContent.trim() || element.closest("script,style,select,[aria-hidden=true]")) continue;
            const range = document.createRange(); range.selectNode(node);
            if (!range.getBoundingClientRect().width) continue;
            const color = getComputedStyle(element).color, bg = background(element, color);
            const value = ratio(color, bg);
            count++; min = Math.min(min, value);
            if (value < 4.5) failures.push(`${element.className}: ${color} on ${bg} = ${value}`);
          }
          for (const element of document.querySelectorAll(".theme-control select,.code-copy")) {
            const style = getComputedStyle(element);
            for (const [label, value] of [["control text", ratio(style.color, background(element, style.color))], ["control border", ratio(style.borderTopColor, background(element, style.borderTopColor))]]) {
              if (value < (label === "control text" ? 4.5 : 3)) failures.push(`${label}: ${value}`);
            }
            element.focus();
            const focused = getComputedStyle(element);
            if (focused.outlineStyle === "none" || parseFloat(focused.outlineWidth) < 3) failures.push("missing visible focus outline");
            const focus = focused.outlineColor;
            const focusRatio = ratio(focus, background(element.parentElement, focus));
            if (focusRatio < 3) failures.push(`focus: ${focusRatio}`);
          }
          const tokens = Object.fromEntries(Array.from(document.querySelectorAll("body > .prose-signals pre span"), element => {
            const foreground = getComputedStyle(element).color, bg = background(element, foreground);
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
  await fs.writeFile(".build/site-contrast.json", JSON.stringify({ textMinimum: 4.5, controlMinimum: 3, palettes, hoverEndpoints }, null, 2) + "\n");
  await page.goto(`${origin}/roc-signals/__fixture.html`);
  assert.equal(await page.$eval("#roc-fixture code", code => code.textContent), '# café & <script>alert(1)</script>\r\n\tvalue = "<&>"  \n\nunterminated = "\u0301\n');
  assert.equal(await page.$eval("#scm-fixture code", code => code.textContent), '; café & <script>alert(1)</script>\r\n\t(test "a\\\"; <&>" :name #t false -12 symbol)  \n(unfinished "e\u0301\n');
  const scmCategories = await page.evaluate(() => Array.from(document.querySelectorAll("#scm-fixture span"), span => span.className));
  for (const category of ["comment", "keyword", "string", "type", "number", "name", "symbol", "invalid"]) assert(scmCategories.includes(`syntax-${category}`));
  assert.equal(await page.$eval("#html-fixture code", code => code.textContent), '<!doctype html>\r\n<!-- café & <script>alert(1)</script> -->\r\n\t<x-card data-note="😀 &amp; <&>" disabled data-id=\'a>b\' count=12>&lt; e\u0301</x-card>  \n<script>if (a < b) window.__highlightExecuted = true;</script>\n<input title="unfinished');
  const htmlCategories = await page.evaluate(() => Array.from(document.querySelectorAll("#html-fixture span"), span => span.className));
  for (const category of ["comment", "keyword", "string", "type", "name", "symbol", "invalid"]) assert(htmlCategories.includes(`syntax-${category}`));
  assert.equal(await page.evaluate(() => document.querySelector("#html-fixture script, #html-fixture input, #html-fixture x-card")), null, "highlighted HTML creates no source elements");
  assert.equal(await page.evaluate(() => window.__highlightExecuted), undefined, "highlighted script stays inert");
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
  // Show an actual highlighted spec in both themes at both viewport sizes.
  await page.goto(`${origin}/roc-signals/docs/getting-started/`);
  for (const [width, height, label] of [[1365, 1000, "desktop"], [390, 844, "mobile"]]) {
    await page.send("Emulation.setDeviceMetricsOverride", { width, height, deviceScaleFactor: 1, mobile: width < 600 });
    for (const mode of ["light", "dark"]) {
      await choose(mode);
      await page.$eval('pre[data-sample-file$=".scm"]', pre => pre.scrollIntoView({ block: "center" }));
      assert.equal(await page.$eval('pre[data-sample-file$=".scm"]', pre => {
        const button = pre.closest(".code-sample").querySelector(".code-copy");
        return pre.getBoundingClientRect().right <= button.getBoundingClientRect().left;
      }), true, `${label} code stays outside the copy control`);
      assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true);
      const { data } = await page.send("Page.captureScreenshot", { format: "png" });
      await fs.writeFile(`.build/site-screenshots/${label}-${mode}-scm.png`, Buffer.from(data, "base64"));
    }
  }
  // HTML uses the same palette, code layout and source-copy controls as Roc
  // and Scheme, including the embedded script in the real mounting page.
  for (const [width, height, label] of [[1365, 1000, "desktop"], [390, 844, "mobile"]]) {
    await page.send("Emulation.setDeviceMetricsOverride", { width, height, deviceScaleFactor: 1, mobile: width < 600 });
    for (const mode of ["light", "dark"]) {
      await choose(mode);
      await page.$eval('pre[data-sample-file$=".html"]', pre => pre.scrollIntoView({ block: "center" }));
      assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true, `${label} HTML has no page overflow`);
      const { data } = await page.send("Page.captureScreenshot", { format: "png" });
      await fs.writeFile(`.build/site-screenshots/${label}-${mode}-html.png`, Buffer.from(data, "base64"));
    }
  }
  // The real introductory entry point copies the visible release placeholder,
  // and the raw download matches it apart from display-only region markers.
  await page.send("Emulation.setDeviceMetricsOverride", { width: 1365, height: 1000, deviceScaleFactor: 1, mobile: false });
  await page.goto(`${origin}/roc-signals/docs/getting-started/`);
  const mainSelector = 'pre[data-sample-file="counter/main.roc"]';
  const displayedMain = await page.$eval(mainSelector, pre => pre.querySelector("code").textContent);
  assert(displayedMain.includes(`platform "${placeholder}"`));
  assert(!displayedMain.includes("../platform/main.roc"));
  await page.click('.code-sample:has(pre[data-sample-file="counter/main.roc"]) .code-copy');
  await page.waitForFunction(expected => window.copied === expected, {}, displayedMain);
  assert.equal(await page.evaluate(() => window.copied), displayedMain);
  const response = await fetch(`${origin}/roc-signals/samples/counter/main.roc`);
  assert.equal(response.status, 200);
  const downloadedMain = await response.text();
  const rawLines = downloadedMain.split("\n");
  assert.equal(rawLines.map((line, i) => /^# (?:end)?region /.test(line.trim()) ? "" : line + (i + 1 < rawLines.length ? "\n" : "")).join(""), displayedMain);
  await page.$eval(mainSelector, pre => pre.scrollIntoView({ block: "center" }));
  const { data: mainImage } = await page.send("Page.captureScreenshot", { format: "png" });
  await fs.writeFile(".build/site-screenshots/desktop-package-placeholder.png", Buffer.from(mainImage, "base64"));
  assert(schemeSamples > 0 && schemeCopied.light && schemeCopied.dark);
  assert(htmlSamples > 0 && htmlCopied.light && htmlCopied.dark);
  console.log(`site browser: passed ${samples} sample renderings (${schemeSamples} highlighted Scheme, ${htmlSamples} highlighted HTML), ${downloads} published source downloads, ${colors} text colors; minimum contrast ${minimum}:1; both themes, real settled hover, system changes, storage, keyboard, copy, escaping and mobile layout`);
} finally {
  await browser.close();
  await new Promise(resolve => server.close(resolve));
}
