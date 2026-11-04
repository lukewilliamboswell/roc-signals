// conduit-journey.mjs APP_DIR -- Conduit (apps/conduit Wasm build) in headless
// Chrome with automatic effects: real fetch against the deterministic
// RealWorld mock backend (www/static/conduit_backend.mjs, run in this Node
// server), real localStorage, history and popstate. A user journey with
// real clicks and typing: browse, sign in, favorite, filter by tag, open an
// article, comment, go back, sign out.
import http from "node:http";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { createRequire } from "node:module";

const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(here, "../../..");
const { createConduitHandler } = await import(path.join(repo, "www/static/conduit_backend.mjs"));
const puppeteer = createRequire(path.join(process.env.NODE_PATH ?? ".", "x.js"))("puppeteer-core");
const appDir = process.argv[2];
const handle = createConduitHandler({ latencyMs: 20 });
const files = {
  "index.html": path.join(here, "index.html"),
  "runtime.mjs": path.join(here, "..", "platform", "runtime.mjs"),
  "app.wasm": path.join(appDir, "app.wasm"),
};
const api = [];
const server = http.createServer(async (req, res) => {
  const u = new URL(req.url, "http://x");
  if (u.pathname.startsWith("/api/")) {
    let body = "";
    for await (const c of req) body += c;
    api.push(`${req.method} ${u.pathname}${u.search}`);
    const r = await handle({ method: req.method, uri: u.pathname + u.search, headers: req.headers, body });
    if (r === null) {
      res.writeHead(404);
      res.end();
      return;
    }
    res.writeHead(r.status, { "content-type": "application/json" });
    res.end(r.body);
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
const base = `http://127.0.0.1:${server.address().port}/roc-signals/examples-web/conduit/`;
const browser = await puppeteer.launch({ executablePath: "/usr/bin/google-chrome", headless: true, args: ["--no-sandbox"] });
const page = await browser.newPage();
const errors = [];
page.on("pageerror", (e) => errors.push(String(e)));
await page.evaluateOnNewDocument(fs.readFileSync(path.join(here, "locate.js"), "utf8"));
let failures = 0;
const step = async (name, f) => {
  try {
    await f();
    console.log(`ok   ${name}`);
  } catch (e) {
    failures += 1;
    console.log(`FAIL ${name}: ${e.message.split("\n")[0]}`);
  }
};
const nameOf = "(b) => b.getAttribute('aria-label') || b.textContent";
const until = (fn, arg) => page.waitForFunction(fn, { timeout: 5000 }, arg);
const el = async (loc) => {
  await until((l) => window.__loc(l) !== null, loc);
  return (await page.evaluateHandle((l) => window.__loc(l), loc)).asElement();
};
const type = async (loc, v) => {
  const e = await el(loc);
  await e.focus();
  await page.keyboard.down("Control");
  await page.keyboard.press("a");
  await page.keyboard.up("Control");
  await page.keyboard.press("Backspace");
  await page.keyboard.type(v);
};
const loc = () => page.evaluate(() => location.pathname + location.search + location.hash);

await page.goto(`${base}#/`);
await until("window.__ready || window.__error");
if (process.env.PEEK) {
  await new Promise((r) => setTimeout(r, 1500));
  console.log((await page.evaluate(() => document.getElementById("app").innerHTML)).slice(0, Number(process.env.PEEK)));
}
let favName = null;
await step("home: global feed loads from the backend", async () => {
  await until(() => [...document.querySelectorAll("a")].some((a) => (a.getAttribute("href") || "").includes("#/article/")));
  await el(["text", "Popular Tags"]);
});
await step("sign in with real typing", async () => {
  await (await el(["role", "link", "Sign in"])).click();
  await until(() => location.hash === "#/login");
  await type(["label", "Email"], "kim@conduit.test");
  await type(["label", "Password"], "secret-kim");
  await (await el(["role", "button", "Sign in"])).click();
  await el(["role", "link", "kim"]);
  if ((await page.evaluate(() => localStorage.getItem("conduit.jwt"))) === null) throw new Error("jwt not persisted");
  await until(() => location.hash === "#/" || location.hash === "");
});
await step("favorite a feed article (server-confirmed)", async () => {
  await until(() => [...document.querySelectorAll("button")].some((b) => /^Favorite .* \(\d+\)$/.test(b.getAttribute("aria-label") || b.textContent)));
  favName = await page.evaluate(() => [...document.querySelectorAll("button")].map((b) => b.getAttribute("aria-label") || b.textContent).find((n) => /^Favorite .* \(\d+\)$/.test(n)));
  const m = /^Favorite (.*) \((\d+)\)$/.exec(favName);
  await (await el(["role", "button", favName])).click();
  await el(["role", "button", `Unfavorite ${m[1]} (${Number(m[2]) + 1})`]);
});
await step("filter by a popular tag (pushState + new request)", async () => {
  const tag = await page.evaluate(() => {
    const h = [...document.querySelectorAll("*")].find((n) => n.childNodes.length === 1 && n.textContent === "Popular Tags");
    const a = h && h.parentElement.querySelector("a");
    return a ? a.textContent : null;
  });
  if (!tag) throw new Error("no popular tag link");
  await (await el(["role", "link", tag])).click();
  await until((t) => location.hash === `#/?tag=${t}`, tag);
  await el(["text", `Tag: ${tag}`]);
});
let before = null;
await step("open an article and post a comment", async () => {
  before = await loc();
  await until(() => [...document.querySelectorAll("a")].some((a) => (a.getAttribute("href") || "").includes("#/article/")));
  await page.evaluate(() => [...document.querySelectorAll("a")].find((a) => (a.getAttribute("href") || "").includes("#/article/")).click());
  await until(() => location.hash.startsWith("#/article/"));
  await type(["label", "Comment"], "Typed in a real browser.");
  await (await el(["role", "button", "Post Comment"])).click();
  await el(["text", "Typed in a real browser."]);
});
await step("history back returns to the tag feed (popstate)", async () => {
  await page.evaluate(() => history.back());
  await until((b) => location.pathname + location.search + location.hash === b, before);
  await until(() => [...document.querySelectorAll("button")].some((b) => /^(Un)?[Ff]avorite .* \(\d+\)$/.test(b.getAttribute("aria-label") || b.textContent)));
});
await step("settings: sign out clears the session keys", async () => {
  await (await el(["role", "link", "Settings"])).click();
  await (await el(["role", "button", "Sign out"])).click();
  await el(["role", "link", "Sign in"]);
  const keys = await page.evaluate(() => [localStorage.getItem("conduit.jwt"), localStorage.getItem("conduit.username")]);
  if (keys[0] !== null || keys[1] !== null) throw new Error(`keys left: ${keys}`);
});
await step("no page errors", async () => {
  if (errors.length) throw new Error(errors.join("; "));
});
console.log(`   api calls: ${api.length} (${[...new Set(api.map((a) => a.split("?")[0]))].join(", ")})`);
await browser.close();
server.close();
console.log(failures === 0 ? "== conduit journey: all pass" : `== conduit journey: ${failures} failures`);
process.exit(failures === 0 ? 0 : 1);
