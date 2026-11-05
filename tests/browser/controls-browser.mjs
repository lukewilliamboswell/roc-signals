// controls-browser.mjs --wasm APP.wasm --runtime runtime.mjs --chrome PATH -- controlled
// inputs, focus and containment in headless Chrome against tests/apps/controls (design.md "Controlled inputs",
// "Memory management and allocation failure", "Diagnostics contract").
import http from "node:http";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { launch } from "./cdp.mjs";
import { parseArgs } from "./args.mjs";

const here = path.dirname(fileURLToPath(import.meta.url));
const opts = parseArgs(process.argv.slice(2));
const files = {
  "index.html": path.join(here, "index.html"),
  "runtime.mjs": opts.runtime,
  "app.wasm": opts.wasm,
};
const server = http.createServer((req, res) => {
  const u = new URL(req.url, "http://x");
  const f = u.pathname.endsWith("/") ? files["index.html"] : files[path.basename(u.pathname)];
  if (!f) {
    res.writeHead(404);
    res.end();
    return;
  }
  res.writeHead(200, { "content-type": f.endsWith(".wasm") ? "application/wasm" : f.endsWith("html") ? "text/html" : "text/javascript" });
  res.end(fs.readFileSync(f));
});
await new Promise((r) => server.listen(0, "127.0.0.1", r));
const base = `http://127.0.0.1:${server.address().port}/app/`;
const browser = await launch({ executablePath: opts.chrome });
let failures = 0;
const check = (name, got, want) => {
  const ok = JSON.stringify(got) === JSON.stringify(want);
  if (!ok) failures += 1;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok ? "" : `: got ${JSON.stringify(got)}, want ${JSON.stringify(want)}`}`);
};
async function open() {
  const ctx = await browser.createBrowserContext();
  const page = await ctx.newPage();
  const errors = [];
  page.on("pageerror", (e) => errors.push(String(e)));
  page.on("console", (m) => {
    if (m.type() === "error") errors.push(m.text());
  });
  await page.goto(base);
  await page.waitForFunction("window.__ready || window.__error");
  return { page, ctx, errors };
}
const input = (page, label) => page.$(`[aria-label="${label}"]`);
const val = (page, label) => page.$eval(`[aria-label="${label}"]`, (e) => [e.value, e.selectionStart, e.selectionEnd]);
const text = (page, id) => page.$eval(`[data-testid="${id}"]`, (e) => e.textContent);

{
  const { page, ctx } = await open();
  // 1. Typing in the middle of existing text keeps the caret.
  const plain = await input(page, "Plain");
  await plain.focus();
  await page.evaluate(() => document.querySelector('[aria-label="Plain"]').setSelectionRange(5, 5));
  await page.keyboard.type("XYZ");
  check("typing mid-text: value and caret preserved", await val(page, "Plain"), ["helloXYZ world", 8, 8]);
  check("engine state follows", await text(page, "state"), "helloXYZ world|");
  await page.keyboard.press("ArrowLeft");
  await page.keyboard.press("ArrowLeft");
  await page.keyboard.press("Backspace");
  check("deleting mid-text keeps the caret", await val(page, "Plain"), ["helloYZ world", 5, 5]);
  // A selection survives an equal echo.
  await page.evaluate(() => document.querySelector('[aria-label="Plain"]').setSelectionRange(0, 5));
  await page.keyboard.type("Hi");
  check("replacing a selection keeps the caret", await val(page, "Plain"), ["HiYZ world", 2, 2]);

  // 2. A differing engine value is deferred while focused, applied on blur.
  const upper = await input(page, "Upper");
  await upper.focus();
  await page.keyboard.type("ab");
  check("differing value deferred while focused", [await val(page, "Upper"), await text(page, "state")], [["ab", 2, 2], "HiYZ world|AB"]);
  await plain.focus();
  check("deferred value applied on blur", (await val(page, "Upper"))[0], "AB");
  // A later input echo that matches the deferred value cancels it.
  await upper.focus();
  await page.keyboard.press("End");
  await page.keyboard.type("c");
  await page.keyboard.press("Backspace");
  await page.keyboard.down("Shift");
  await page.keyboard.type("C");
  await page.keyboard.up("Shift");
  check("matching echo leaves nothing deferred", await page.$eval('[aria-label="Upper"]', (e) => [e.value, e.__deferred === undefined]), ["ABC", true]);
  await plain.focus();
  check("value after blur", (await val(page, "Upper"))[0], "ABC");

  // 3. IME composition: never overwritten while composing.
  const cdp = await page.createCDPSession();
  await upper.focus();
  await page.keyboard.press("End");
  await cdp.send("Input.imeSetComposition", { text: "ka", selectionStart: 2, selectionEnd: 2 });
  check("during composition: typed text kept, engine upper-cased", [(await val(page, "Upper"))[0], await page.$eval('[aria-label="Upper"]', (e) => e.__composing === true), await text(page, "state")], ["ABCka", true, "HiYZ world|ABCKA"]);
  await cdp.send("Input.imeSetComposition", { text: "kan", selectionStart: 3, selectionEnd: 3 });
  check("composition update not overwritten", (await val(page, "Upper"))[0], "ABCkan");
  await cdp.send("Input.insertText", { text: "かん" });
  check("composition committed, still focused: equal echo, nothing deferred", [await val(page, "Upper"), await page.$eval('[aria-label="Upper"]', (e) => [e.__composing, e.__deferred === undefined])], [["ABCかん", 5, 5], [false, true]]);
  await plain.focus();
  check("after blur", (await val(page, "Upper"))[0], "ABCかん");
  await ctx.close();
}
{
  // 4. Focus commands and focus/blur events.
  const { page, ctx } = await open();
  const active = () => page.evaluate(() => document.activeElement.getAttribute("aria-label") ?? document.activeElement.tagName);
  const clickButton = (name) => page.evaluate((n) => [...document.querySelectorAll("button")].find((b) => b.textContent === n).click(), name);
  await clickButton("Focus upper");
  check("Focus command focuses the referenced input", await active(), "Upper");
  await clickButton("Select plain");
  check("SelectText focuses and selects", [await active(), await val(page, "Plain")], ["Plain", ["hello world", 0, 11]]);
  check("focus event delivered with the value payload", (await text(page, "log")).split("|").includes("focus:hello world"), true);
  await clickButton("Blur plain");
  check("Blur command blurs it; blur event delivered", [await active() !== "Plain", (await text(page, "log")).split("|").includes("blur:hello world")], [true, true]);
  await clickButton("Focus missing");
  check("missing reference: no focus change, no error", await active() !== "Plain", true);
  await ctx.close();
}
{
  // 5. Containment: a contract error poisons the instance; it is reported,
  // refuses further work without re-entering Wasm, keeps the last DOM, and a
  // fresh instance recovers.
  const { page, ctx, errors } = await open();
  const clickButton = (name) => page.evaluate((n) => [...document.querySelectorAll("button")].find((b) => b.textContent === n).click(), name);
  await page.evaluate(() => {
    window.__faults = [];
    window.__rt.onFault = (f) => window.__faults.push(f);
  });
  await clickButton("Add row");
  await clickButton("Add row");
  check("rows render", await text(page, "rows"), "r0r1");
  await clickButton("Duplicate row");
  const f = await page.evaluate(() => window.__faults);
  check("one fault reported with class and construction-site path", [f.length, f[0] && f[0].class, f[0] && /^contract: duplicate key "r0" in each at site \/\d/.test(f[0].message)], [1, "contract", true]);
  check("host reports the poisoned class; staged commands discarded", await page.evaluate(() => [window.__rt.x.fault(), window.__rt.x.cmd_len()]), [1, 0]);
  check("last committed DOM kept as fallback", await text(page, "rows"), "r0r1");
  const before = await text(page, "state");
  await clickButton("Add row");
  await (await input(page, "Plain")).type("zz");
  await page.evaluate(() => window.__rt.dispatch(1, 0, ""));
  check("listeners detached; later events and direct dispatch refused", [await text(page, "rows"), await text(page, "state"), await page.evaluate(() => [window.__rt.listening.size, window.__rt.refused])], ["r0r1", before, [0, 1]]);
  const reentry = await page.evaluate(() => {
    try {
      window.__rt.x.event(1, 0);
      return "entered";
    } catch (e) {
      return "trapped";
    }
  });
  check("the poisoned host itself refuses engine entry", reentry, "trapped");
  check("fault printed to the console", errors.some((e) => e.includes("roc engine fault [contract]")), true);
  await page.evaluate(() => window.__rt.recover());
  check("recover(): fresh instance, initial state", [await text(page, "rows"), (await val(page, "Plain"))[0], await page.evaluate(() => window.__rt.x.fault())], ["", "hello world", 0]);
  await clickButton("Add row");
  check("recovered instance handles events", await text(page, "rows"), "r0");
  await ctx.close();
}
await browser.close();
server.close();
console.log(failures === 0 ? "== controls: all pass" : `== controls: ${failures} failures`);
process.exit(failures === 0 ? 0 : 1);
