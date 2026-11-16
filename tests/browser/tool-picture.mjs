// The released tool's root and nested picture pages, served without rewriting.
// Wasm is held until the actual first paint is observed; this launches no compiler.
import http from "node:http";
import fs from "node:fs";
import path from "node:path";
import { launch } from "./cdp.mjs";
const options = {};
for (let i = 2; i < process.argv.length; i += 2) options[process.argv[i].replace(/^--/, "")] = process.argv[i + 1];
for (const name of ["dist", "chrome"]) if (!options[name]) throw new Error(`--${name} is required`);
const directory = path.resolve(options.dist);
let release;
const ready = new Promise(resolve => { release = resolve; });
let failures = 0;
const check = (pass, label, detail = "") => {
  console.log(`${pass ? "ok  " : "FAIL"} ${label}${pass ? "" : ` ${detail}`}`);
  if (!pass) failures++;
};
const server = http.createServer(async (request, response) => {
  try {
    let target = path.resolve(directory, `.${decodeURIComponent(new URL(request.url, "http://local").pathname)}`);
    if (target !== directory && !target.startsWith(`${directory}${path.sep}`)) { response.writeHead(404); response.end(); return; }
    if (fs.statSync(target).isDirectory()) target = path.join(target, "index.html");
    if (target.endsWith(".wasm")) await ready;
    const kind = target.endsWith(".mjs") ? "text/javascript" : target.endsWith(".wasm") ? "application/wasm" : "text/html";
    response.writeHead(200, { "content-type": kind }); response.end(fs.readFileSync(target));
  } catch { response.writeHead(404); response.end(); }
});
await new Promise(resolve => server.listen(0, "127.0.0.1", resolve));
let browser;
try {
  browser = await launch({ executablePath: options.chrome });
  const page = await browser.newPage(); const errors = [];
  page.on("pageerror", error => errors.push(String(error)));
  const origin = `http://127.0.0.1:${server.address().port}`;
  await page.send("Page.navigate", { url: `${origin}/` });
  await page.waitForFunction(() => document.querySelector('[data-testid="count"]') !== null);
  const before = await page.evaluate(() => {
    const root = document.getElementById("app"); window.beforePicture = root.firstChild;
    const button = root.querySelector('[aria-label="Increment"]'); button.focus();
    return { count: root.querySelector('[data-testid="count"]').textContent, inert: root.inert, fact: root.getAttribute("data-roc-picture-inert"), suppressed: document.activeElement !== button };
  });
  check(before.count === "0" && before.inert && before.fact === "added" && before.suppressed, "tool output paints a real inert counter before Wasm", JSON.stringify(before));
  release();
  await page.waitForFunction(() => !document.getElementById("app").hasAttribute("data-roc-picture"));
  const after = await page.evaluate(() => {
    const root = document.getElementById("app"); root.querySelector('[aria-label="Increment"]').click();
    return { count: root.querySelector('[data-testid="count"]').textContent, replaced: root.firstChild !== window.beforePicture, inert: root.inert, fact: root.hasAttribute("data-roc-picture-inert") };
  });
  check(after.count === "1" && after.replaced && !after.inert && !after.fact, "tool picture replacement lifts only producer-owned inertness and dispatches normally", JSON.stringify(after));
  await page.goto(`${origin}/nested/?open=1#list`);
  await page.waitForFunction(() => document.querySelector('[data-testid="count"]')?.textContent === "0" && !document.getElementById("app").hasAttribute("data-roc-picture"));
  const loaded = await page.evaluate(() => performance.getEntriesByType("resource").map(entry => new URL(entry.name).pathname));
  check(["app.wasm", "runtime.mjs"].every(name => loaded.some(url => /^\/assets\/[0-9a-f]{16}\//.test(url) && url.endsWith(`/${name}`))), "nested page loads hashed module/runtime from the same published tree", JSON.stringify(loaded));
  check(errors.length === 0, "tool pictures report no page errors", JSON.stringify(errors));
} finally {
  release();
  if (browser) await browser.close();
  await new Promise(resolve => server.close(resolve));
}
process.exitCode = failures ? 1 : 0;
