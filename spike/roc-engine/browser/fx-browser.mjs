// fx-browser.mjs APP_DIR -- browser contract test of the effect channel with
// apps/effects in headless Chrome: manual mode (pending list, answer, cancel
// on dispose, injected stale result dropped, saturation refusal, popstate
// subscription, follow-up self-dispose) and automatic mode (real fetch
// against this server, including an aborted in-flight request).
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
  "runtime.mjs": path.join(here, "..", "platform", "runtime.mjs"),
  "app.wasm": path.join(appDir, "app.wasm"),
};
let slowRelease = null;
const server = http.createServer((req, res) => {
  const u = new URL(req.url, "http://x");
  const m = /^\/s(\d)\/(\d+)$/.exec(u.pathname);
  if (m) {
    const send = () => {
      res.writeHead(200, { "content-type": "text/plain" });
      res.end(`srv${m[1]}.${m[2]}`);
    };
    // /s2/* is held until released (to test abort on dispose).
    if (m[1] === "2") slowRelease = send;
    else send();
    return;
  }
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
const base = `http://127.0.0.1:${server.address().port}`;
const browser = await puppeteer.launch({ executablePath: "/usr/bin/google-chrome", headless: true, args: ["--no-sandbox"] });

let failures = 0;
const check = (name, got, want) => {
  const ok = JSON.stringify(got) === JSON.stringify(want);
  if (!ok) failures += 1;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok ? "" : `: got ${JSON.stringify(got)}, want ${JSON.stringify(want)}`}`);
};

async function open(manual) {
  const ctx = await browser.createBrowserContext();
  const page = await ctx.newPage();
  page.on("pageerror", (e) => console.log("pageerror", String(e)));
  if (manual) await page.evaluateOnNewDocument("window.__manualFx = true");
  await page.goto(`${base}/app/`);
  await page.waitForFunction("window.__ready || window.__error");
  return { page, ctx };
}
const click = (page, label) => page.evaluate((l) => [...document.querySelectorAll("button")].find((b) => b.textContent === l).click(), label);
const log = (page) => page.evaluate(() => document.querySelector("[data-testid=log]").textContent);
const pending = (page) => page.evaluate(() => window.__rt.pendingEffects().map((r) => `${r.id} ${r.method} ${r.url}`));
const stats = (page) => page.evaluate(() => ({ live: [...window.__rt.live.keys()] }));

{
  const { page, ctx } = await open(true);
  check("mount: popstate + one interval per shown site", await stats(page), { live: [1, 2, 3, 4] });
  const svg = () => page.evaluate(() => {
    const c = document.querySelector("[aria-label=badge] circle");
    return [document.querySelector("[aria-label=badge]").namespaceURI, c.namespaceURI, c.getAttribute("class"), c.getBBox().width];
  });
  check("svg elements in the SVG namespace, class attribute set", await svg(), ["http://www.w3.org/2000/svg", "http://www.w3.org/2000/svg", "idle", 8]);
  const hits = (k) => page.evaluate((k) => {
    const e = document.querySelector(`[data-testid="hits ${k}"]`);
    return e ? e.textContent : null;
  }, k);
  await click(page, "issue 0");
  await click(page, "issue 0");
  check("G and H requests pending in issue order", await pending(page), ["5 GET /s0/1", "6 GET /h0/1", "7 GET /s0/2", "8 GET /h0/2"]);
  await page.evaluate(() => window.__rt.runEffect(7, { status: 201, body: "second" }));
  await page.evaluate(() => window.__rt.runEffect(6, { status: 200, body: "" }));
  check("answer out of order (log and branch-local hits)", [await log(page), await hits(0)], ["0:2:201:second", "1"]);
  check("svg class updated", (await svg())[2], "busy");
  await page.evaluate(() => window.__rt.tick(3));
  check("interval tick through the subscription", await log(page), "0:2:201:second|1:0:other");
  await click(page, "issue 1");
  await click(page, "issue 1");
  check("bound 8 reached: G and H refused in follow-up turns", [await log(page), await hits(1)], ["0:2:201:second|1:0:other|1:2:refused", "1"]);
  await click(page, "toggle 0");
  check("dispose stops the interval, keeps admitted requests", [(await stats(page)).live.includes(2), await pending(page)], [false, ["5 GET /s0/1", "8 GET /h0/2", "9 GET /s1/1", "10 GET /h1/1"]]);
  await page.evaluate(() => window.__rt.runEffect(5, { status: 200, body: "after" }));
  check("reparented G result still applies to the surviving log", (await log(page)).endsWith("|0:1:200:after"), true);
  const before = await log(page);
  await page.evaluate(() => window.__rt.runEffect(8, { status: 200, body: "" }));
  check("reparented H result is a skipped write (branch gone)", [await log(page), await hits(0)], [before, null]);
  await page.evaluate(() => window.__rt.injectResult(2, 200, "late"));
  check("result for a stopped interval is dropped", await log(page), before);
  await page.evaluate(() => window.__rt.injectResult(99, 200, "never"));
  check("result for a never-issued id is dropped", await log(page), before);
  await page.evaluate(() => history.pushState(null, "", "/app/#/a"));
  await page.evaluate(() => history.pushState(null, "", "/app/#/b"));
  await page.evaluate(() => history.back());
  await page.waitForFunction(() => document.querySelector("[data-testid=log]").textContent.includes("pop:"));
  check("popstate delivered through the subscription", (await log(page)).endsWith("|pop:/app/#/a"), true);
  for (let i = 0; i < 6; i += 1) await click(page, "issue 2");
  const l = (await log(page)).split("|");
  check("count 6: Self hides the site mid-drain, second Self dropped", [l[l.length - 1], l.filter((x) => x === "2:6:self").length, l.includes("2:3:self")], ["2:6:self", 1, true]);
  check("site 2 hidden", await page.evaluate(() => document.body.textContent.includes("site 2")), false);
  await ctx.close();
}
{
  const { page, ctx } = await open(false);
  await click(page, "issue 0");
  await page.waitForFunction(() => document.querySelector("[data-testid=log]").textContent.length > 0);
  check("auto mode: real fetch result", await log(page), "0:1:200:srv0.1");
  await click(page, "issue 2");
  await new Promise((r) => setTimeout(r, 100));
  check("slow request in flight", (await stats(page)).live.includes(7), true);
  await click(page, "toggle 2");
  check("dispose keeps the admitted fetch (reparented), stops the interval", [(await stats(page)).live.includes(7), (await stats(page)).live.includes(4)], [true, false]);
  slowRelease && slowRelease();
  await page.waitForFunction(() => document.querySelector("[data-testid=log]").textContent.includes("srv2.1"));
  check("reparented fetch result applied after dispose", (await log(page)).split("|").includes("2:1:200:srv2.1"), true);
  await ctx.close();
}
await browser.close();
server.close();
console.log(failures === 0 ? "== fx browser contract: all pass" : `== fx browser contract: ${failures} failures`);
process.exit(failures === 0 ? 0 : 1);
