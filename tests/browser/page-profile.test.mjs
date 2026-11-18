import assert from "node:assert/strict";
import { parseArgs } from "./args.mjs";
import { launch } from "./cdp.mjs";
import { configureSpecPage, readySpecPage, viewport } from "./page-profile.mjs";
import { observeManualScrolls } from "./scroll-observation.mjs";

const options = parseArgs(process.argv.slice(2), [], []);
const browser = await launch({ executablePath: options.chrome });
try {
  const page = await browser.newPage();
  const other = await browser.newPage();
  await other.send("Page.bringToFront");
  await page.send("Emulation.setDeviceMetricsOverride", { width: 320, height: 200, deviceScaleFactor: 3, mobile: true });
  await configureSpecPage(page);
  const document = "<!doctype html><body><button>Button</button><div style='height:90px;width:120px;overflow:scroll'><div style='height:1000px'>scroll</div></div><pre>monospace</pre>";
  for (let load = 0; load < 2; load += 1) {
    await page.goto(`data:text/html,${encodeURIComponent(document)}`);
    await readySpecPage(page);
    const state = await page.evaluate(async () => {
      let timer;
      try {
        await Promise.race([new Promise(resolve => requestAnimationFrame(resolve)), new Promise((_, reject) => { timer = setTimeout(() => reject(new Error("foreground profile received no frame")), 20000); })]);
      } finally { clearTimeout(timer); }
      const scroller = document.querySelector("div");
      scroller.scrollTop = 500;
      return {
        width: innerWidth, height: innerHeight, scale: devicePixelRatio,
        family: getComputedStyle(document.body).fontFamily,
        button: getComputedStyle(document.querySelector("button")).fontFamily,
        scrollbar: scroller.offsetWidth - scroller.clientWidth,
        scroll: scroller.scrollTop,
        fonts: [...document.fonts].map(font => font.status),
        styles: document.querySelectorAll("[data-signals-spec-profile]").length,
        visibility: document.visibilityState, focused: document.hasFocus(),
      };
    });
    assert.deepEqual(state, { width: viewport.width, height: viewport.height, scale: 1, family: "SignalsSpec", button: "SignalsSpec", scrollbar: 0, scroll: 500, fonts: ["loaded", "loaded"], styles: 1, visibility: "visible", focused: true });
  }
  // A stalled frame must fail without inventing a scroll observation.
  await page.evaluate(() => {
    window.__realRAF = requestAnimationFrame;
    window.__scrollChecks = 0;
    window.__rt = { manualScrollers: new Set([1]), checkManualScrolls() { window.__scrollChecks += 1; } };
    window.requestAnimationFrame = () => 0;
  });
  await assert.rejects(page.evaluate(observeManualScrolls, Date.now() + 100), /scroll observation received no animation frame before its idle deadline/);
  assert.equal(await page.evaluate(() => window.__scrollChecks), 0);
  await page.evaluate(() => { window.requestAnimationFrame = window.__realRAF; });
  await page.evaluate(observeManualScrolls, Date.now() + 20000);
  assert.equal(await page.evaluate(() => window.__scrollChecks), 1);
  await other.close();
  console.log("spec page profile: foreground frames, viewport, scale, bundled fonts and scrollbar geometry survive navigation");
} finally {
  await browser.close();
}
