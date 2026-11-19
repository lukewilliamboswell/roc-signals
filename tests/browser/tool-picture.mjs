// The released tool's complete entry catalogue, served without rewriting.
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
let refusedRequests = 0;
const check = (pass, label, detail = "") => {
  console.log(`${pass ? "ok  " : "FAIL"} ${label}${pass ? "" : ` ${detail}`}`);
  if (!pass) failures++;
};
const server = http.createServer(async (request, response) => {
  try {
    if (new URL(request.url, "http://local").pathname === "/must-not-start") refusedRequests++;
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
    window.beforeRetained = root.querySelector('[data-testid="retained"]');
    window.beforePhase = root.querySelector('[data-testid="phase"]');
    const button = root.querySelector('[aria-label="Increment"]'); button.focus();
    return { count: root.querySelector('[data-testid="count"]').textContent, phase: window.beforePhase.textContent, assetText: window.beforeRetained.title, inert: root.inert, buttonInert: button.inert, frame: root.getAttribute("data-roc-frame"), suppressed: document.activeElement !== button };
  });
  check(before.count === "0" && before.phase === "cold home" && before.assetText === "app.wasm" && !before.inert && before.buttonInert && /^1:0:[a-f0-9]{16}$/.test(before.frame) && before.suppressed, "tool output paints the cold home entry and gates its control before Wasm", JSON.stringify(before));
  release();
  await page.waitForFunction(() => window.__ready || window.__fault);
  const after = await page.evaluate(() => {
    const root = document.getElementById("app"); root.querySelector('[aria-label="Increment"]').click();
    return { count: root.querySelector('[data-testid="count"]').textContent, retained: root.firstChild === window.beforePicture && root.querySelector('[data-testid="retained"]') === window.beforeRetained, newPhase: root.querySelector('[data-testid="phase"]') !== window.beforePhase, phase: root.querySelector('[data-testid="phase"]').textContent, refusal: root.querySelector('[data-testid="refusal"]').textContent, buttonInert: root.querySelector('[aria-label="Increment"]').inert, fault: window.__fault ?? null };
  });
  check(after.count === "1" && after.retained && after.newPhase && after.phase === "active home" && after.refusal === "refused" && !after.buttonInert && after.fault === null, "binding retains ordinary content before Self replaces its scope and refusal settles", JSON.stringify(after));
  await page.goto(`${origin}/tasks/?live=1#list`);
  await page.waitForFunction(() => window.__ready || window.__fault);
  const nested = await page.evaluate(() => ({ phase: document.querySelector('[data-testid="phase"]')?.textContent, frame: document.getElementById("app").getAttribute("data-roc-frame"), fault: window.__fault ?? null, loaded: performance.getEntriesByType("resource").map(entry => ({ path: new URL(entry.name).pathname, receipt: new URL(entry.name).searchParams.get("roc-build") })) }));
  check(nested.phase === "active tasks" && nested.fault === null && /^1:1:/.test(nested.frame), "direct nested load selects its fixed entry despite live query/fragment", JSON.stringify(nested));
  check(["app.wasm", "runtime.mjs"].every(name => nested.loaded.some(url => /^\/assets\/[0-9a-f]{16}\//.test(url.path) && url.path.endsWith(`/${name}`))) && nested.loaded.some(url => url.path.endsWith("/app.wasm") && url.receipt === nested.frame.split(":")[2]), "nested page loads shared immutable assets with its explicit matching receipt", JSON.stringify(nested.loaded));
  check(refusedRequests === 0, "initial refusal starts no HTTP request");
  check(errors.length === 0, "tool pictures report no page errors", JSON.stringify(errors));
} finally {
  release();
  if (browser) await browser.close();
  await new Promise(resolve => server.close(resolve));
}
process.exitCode = failures ? 1 : 0;
