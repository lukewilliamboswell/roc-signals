// controls-browser.mjs APP_DIR -- controlled inputs, focus and containment
// in headless Chrome against apps/controls (design.md "Controlled inputs",
// "Memory management and allocation failure", "Diagnostics contract").
// RUNTIME=path serves an alternative runtime (mutation checks).
import http from "node:http";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { createRequire } from "node:module";

const here = path.dirname(fileURLToPath(import.meta.url));
const puppeteer = createRequire(path.join(process.env.NODE_PATH ?? ".", "x.js"))("puppeteer-core");
const appDir = process.argv[2];
const files = {
  "index.html": path.join(here, "index.html"),
  "runtime.mjs": process.env.RUNTIME ?? path.join(here, "..", "platform", "runtime.mjs"),
  "app.wasm": path.join(appDir, "app.wasm"),
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
const browser = await puppeteer.launch({ executablePath: "/usr/bin/google-chrome", headless: true, args: ["--no-sandbox"] });
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
await browser.close();
server.close();
console.log(failures === 0 ? "== controls: all pass" : `== controls: ${failures} failures`);
process.exit(failures === 0 ? 0 : 1);
