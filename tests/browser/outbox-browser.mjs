// outbox-browser.mjs --wasm APP.wasm --runtime runtime.mjs --chrome PATH -- the
// contract error of an outbox posted twice in one turn, in headless Chrome
// against tests/apps/outbox (design.md "Supersession and asynchronous
// layers", "Error containment"). The outbox's ordinary behaviour is in the
// app's specs; a native spec cannot observe this, since a contract error
// ends the native runner's process with the page.
import http from "node:http";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { launch } from "./cdp.mjs";
import { parseArgs, runtimeFiles } from "./args.mjs";

const here = path.dirname(fileURLToPath(import.meta.url));
const opts = parseArgs(process.argv.slice(2));
const files = {
  "index.html": path.join(here, "index.html"),
  ...runtimeFiles(opts.runtime),
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

{
  const ctx = await browser.createBrowserContext();
  const page = await ctx.newPage();
  const errors = [];
  page.on("pageerror", (e) => errors.push(String(e)));
  page.on("console", (m) => {
    if (m.type() === "error") errors.push(m.text());
  });
  // Effects stay manual, so the one request sent below stays in flight.
  await page.evaluateOnNewDocument(() => {
    window.__manualFx = true;
  });
  await page.goto(base);
  await page.waitForFunction("window.__ready || window.__error");
  check("mounted", await page.evaluate(() => window.__error ?? "ready"), "ready");
  await page.evaluate(() => {
    window.__faults = [];
    window.__rt.onFault = (f) => window.__faults.push(f);
  });
  const clickButton = (name) => page.evaluate((n) => [...document.querySelectorAll("button")].find((b) => b.textContent === n).click(), name);
  const log = () => page.$eval('[data-testid="log"]', (e) => e.textContent);

  // One post per turn is sent.
  await clickButton("Send");
  check("one post sends one request", await page.evaluate(() => window.__rt.live.size), 1);
  check("no fault yet", await page.evaluate(() => window.__faults.length), 0);

  // Two posts in one turn: the first would never be sent, so the instance
  // is poisoned with a classified contract error naming the site.
  await clickButton("Send twice");
  const f = await page.evaluate(() => window.__faults);
  check(
    "a second post in one turn is a contract error naming the site",
    [f.length, f[0] && f[0].class, f[0] && /^contract: on_post's outbox was posted 2 times in one turn, so only the last post would be sent; post a list to send several things at once \(site \/[\d/]+\)$/.test(f[0].message)],
    [1, "contract", true],
  );
  check("the fault reaches the console", errors.some((e) => e.includes("roc engine fault [contract]")), true);
  check("nothing of the faulty turn is applied", await log(), "");
  await ctx.close();
}
await browser.close();
server.close();
console.log(failures === 0 ? "== outbox: all pass" : `== outbox: ${failures} failures`);
process.exit(failures === 0 ? 0 : 1);
