// tool-serve.mjs --app DIR --roc ROC --package URL --package-main PATH --platform PATH --chrome PATH
//
// `roc signals.roc serve` on a freshly created counter app (DIR), in headless
// Chrome. The tool runs as an author runs it, except that its package is the
// staged one (`roc --replace-dep URL PATH`) and its builds use the working
// tree's platform (`ROC_SIGNALS_PLATFORM`). It checks that a busy port falls
// back to the next free one and says so; the content types, the reload
// script in the page's head, and the refusals of paths outside the app and
// of other methods; the app mounting and counting; a page reload after an
// edit to a Roc module, with the time from the save to the reloaded page
// printed (not asserted); the overlay for a build error, while the page keeps
// the last build; the overlay for a mount refusal (a port handler the app
// does not declare) after an edit to index.html; the overlay for an engine
// fault; and a clean stop on SIGINT. Every file it edits is restored.
import { spawn } from "node:child_process";
import fs from "node:fs";
import net from "node:net";
import path from "node:path";
import { launch } from "./cdp.mjs";

const opts = {};
const argv = process.argv.slice(2).filter((a) => a !== "--");
for (let i = 0; i < argv.length; i += 2) opts[argv[i].replace(/^--/, "")] = argv[i + 1];
for (const k of ["app", "roc", "package", "package-main", "platform", "chrome"]) if (!opts[k]) throw new Error(`--${k} is required`);
// `--screenshots DIR` keeps a picture of each overlay, for reviewing its look.
const screenshot = async (tab, name) => {
  if (!opts.screenshots) return;
  const { data } = await tab.send("Page.captureScreenshot", { format: "png" });
  fs.mkdirSync(opts.screenshots, { recursive: true });
  fs.writeFileSync(path.join(opts.screenshots, name), Buffer.from(data, "base64"));
};
const app = path.resolve(opts.app);

let failures = 0;
const check = (ok, label) => {
  console.log(`${ok ? "ok  " : "FAIL"} ${label}`);
  if (!ok) failures += 1;
};

// Files the test edits, restored however it ends.
const originals = new Map();
const edit = (file, from, to) => {
  const full = path.join(app, file);
  const text = fs.readFileSync(full, "utf8");
  if (!originals.has(full)) originals.set(full, text);
  if (!text.includes(from)) throw new Error(`${file} does not contain ${from}`);
  fs.writeFileSync(full, text.replace(from, to));
};
const restore = (file) => {
  const full = path.join(app, file);
  fs.writeFileSync(full, originals.get(full));
};
const restoreAll = () => {
  for (const [full, text] of originals) fs.writeFileSync(full, text);
};

// A port another server holds, so `serve` must move to the next one.
const blocker = net.createServer();
await new Promise((r) => blocker.listen(0, "127.0.0.1", r));
const busy = blocker.address().port;

const child = spawn(opts.roc, ["--replace-dep", opts.package, opts["package-main"], "signals.roc", "serve", "--port", String(busy)], {
  cwd: app,
  env: { ...process.env, ROC_SIGNALS_PLATFORM: opts.platform },
  stdio: ["ignore", "pipe", "pipe"],
  detached: true,
});
let output = "";
let printed = 0;
const waiters = [];
const hear = (d) => {
  output += d.toString();
  // Echo whole lines only, marked as the tool's.
  const end = output.lastIndexOf("\n") + 1;
  if (end > printed) {
    const lines = output.slice(printed, end - 1).split("\n");
    process.stdout.write(lines.map((line) => `  serve| ${line}\n`).join(""));
    printed = end;
  }
  for (const w of [...waiters]) w();
};
child.stdout.on("data", hear);
child.stderr.on("data", hear);
let exited = null;
child.on("close", (code, signal) => {
  exited = { code, signal };
  for (const w of [...waiters]) w();
});
const stop = (signal) => {
  try {
    process.kill(-child.pid, signal);
  } catch (_) {
    // already gone
  }
};
process.on("exit", () => {
  restoreAll();
  if (exited === null) stop("SIGKILL");
});

// Wait until the tool's output, after `from`, matches `pattern`.
const hearing = (pattern, { from = 0, timeout = 120000 } = {}) =>
  new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error(`serve did not print ${pattern} within ${timeout} ms`)), timeout);
    const look = () => {
      const m = output.slice(from).match(pattern);
      if (m) {
        clearTimeout(timer);
        waiters.splice(waiters.indexOf(look), 1);
        resolve(m);
      } else if (exited !== null) {
        clearTimeout(timer);
        waiters.splice(waiters.indexOf(look), 1);
        reject(new Error(`serve exited (${JSON.stringify(exited)}) before printing ${pattern}`));
      }
    };
    waiters.push(look);
    look();
  });

const raw = (port, request) =>
  new Promise((resolve, reject) => {
    const socket = net.connect(port, "127.0.0.1", () => socket.write(request));
    let text = "";
    socket.on("data", (d) => (text += d.toString()));
    socket.on("end", () => resolve(text));
    socket.on("error", reject);
  });

let browser = null;
try {
  const [, portText] = await hearing(/Serving the app at http:\/\/127\.0\.0\.1:(\d+)\//);
  const port = Number(portText);
  const base = `http://127.0.0.1:${port}/`;
  check(port !== busy && output.includes(`Port ${busy} is in use, so the app is served on port ${port} instead.`), `a busy port ${busy} falls back to ${port}, and says so`);
  blocker.close();

  // What the server answers.
  const page = await fetch(base);
  const html = await page.text();
  check(page.status === 200 && page.headers.get("content-type") === "text/html; charset=utf-8", "the page is text/html");
  check(html.includes("/__signals/events") && html.indexOf("roc-signals-overlay") < html.indexOf("<title>"), "the reload script is the first thing in the page's head");
  check(!fs.readFileSync(path.join(app, "index.html"), "utf8").includes("__signals"), "the app's own index.html is untouched");
  for (const [file, type] of [
    ["runtime.mjs", "text/javascript; charset=utf-8"],
    ["worker.mjs", "text/javascript; charset=utf-8"],
    ["app.wasm", "application/wasm"],
  ]) {
    const r = await fetch(base + file);
    await r.arrayBuffer();
    check(r.status === 200 && r.headers.get("content-type") === type, `${file} is ${type}`);
  }
  const missing = await fetch(base + "nothing-here.css");
  check(missing.status === 404 && (await missing.text()).includes("There is no file nothing-here.css"), "a missing file is 404 with a sentence");
  check((await raw(port, "GET /../index.html HTTP/1.1\r\nHost: x\r\n\r\n")).startsWith("HTTP/1.1 404 Not Found"), "a path leaving the app is refused");
  check((await raw(port, "GET /.gitignore HTTP/1.1\r\nHost: x\r\n\r\n")).startsWith("HTTP/1.1 404 Not Found"), "a hidden file is refused");
  check((await raw(port, "POST / HTTP/1.1\r\nHost: x\r\ncontent-length: 0\r\n\r\n")).startsWith("HTTP/1.1 405"), "a POST is refused");

  browser = await launch({ executablePath: opts.chrome });
  const tab = await browser.newPage();
  const errors = [];
  tab.on("pageerror", (e) => errors.push(String(e)));
  await tab.goto(base);
  const count = () => tab.evaluate(() => document.querySelector('[data-testid="count"]')?.textContent ?? null);
  const overlay = () =>
    tab.evaluate(() => {
      const o = document.querySelector("roc-signals-overlay");
      if (!o || !o.isConnected) return null;
      return { kind: o.dataset.kind, title: o.shadowRoot.getElementById("title").textContent, text: o.shadowRoot.getElementById("text").textContent };
    });
  await tab.waitForFunction(() => document.querySelector('[data-testid="count"]')?.textContent === "0", { timeout: 30000 });
  await tab.click('button[aria-label="Increment"]');
  await tab.waitForFunction(() => document.querySelector('[data-testid="count"]')?.textContent === "1");
  check(true, "the app mounts and counts");

  // An edit to a Roc module rebuilds the app and reloads the page.
  await tab.evaluate(() => (window.__beforeReload = true));
  let mark = output.length;
  const saved = Date.now();
  edit("Counter.roc", "Engine.state(0,", "Engine.state(10,");
  await tab.waitForFunction(() => window.__beforeReload === undefined && document.querySelector('[data-testid="count"]')?.textContent === "10", { timeout: 120000 });
  const reloadMs = Date.now() - saved;
  check(/Counter\.roc changed; rebuilding\.\.\.[\s\S]*Built in [\d.]+ s\.[\s\S]*Reloading the open pages\./.test(output.slice(mark)), "the terminal says what changed, the build, and the reload");
  console.log(`measure: save to reloaded page ${reloadMs} ms`);

  // A build error shows over the page, which keeps the last build.
  mark = output.length;
  edit("Counter.roc", "Engine.state(10,", 'Engine.state("ten",');
  await tab.waitForFunction(() => document.querySelector("roc-signals-overlay")?.isConnected === true, { timeout: 120000 });
  const failed = await overlay();
  await screenshot(tab, "overlay-build.png");
  check(failed.kind === "build" && failed.title === "The build failed" && failed.text.includes("Counter.roc") && !failed.text.includes("\u001b"), "a build error shows in the overlay as plain text");
  check((await count()) === "10", "the page keeps the last build while the build fails");
  await hearing(/The build failed after [\d.]+ s\. Open pages show the errors above/, { from: mark });
  // A page opened while the build is failing shows the error at once.
  const second = await browser.newPage();
  await second.goto(base);
  await second.waitForFunction(() => document.querySelector("roc-signals-overlay")?.isConnected === true, { timeout: 30000 });
  check(true, "a page opened during a failed build shows the overlay");
  await second.close();

  // Fixing it reloads the page without the overlay.
  await tab.evaluate(() => (window.__beforeReload = true));
  restore("Counter.roc");
  edit("Counter.roc", "Engine.state(0,", "Engine.state(10,");
  await tab.waitForFunction(() => window.__beforeReload === undefined && document.querySelector('[data-testid="count"]')?.textContent === "10", { timeout: 120000 });
  check((await overlay()) === null, "a successful build reloads the page without the overlay");

  // A page the runtime refuses to mount shows why, after an edit that
  // needs no build.
  mark = output.length;
  await tab.evaluate(() => (window.__beforeReload = true));
  edit("index.html", 'root: document.getElementById("app"),', 'root: document.getElementById("app"), ports: { nope: { command() {} } },');
  await tab.waitForFunction(() => window.__beforeReload === undefined && document.querySelector("roc-signals-overlay")?.isConnected === true, { timeout: 30000 });
  const refused = await overlay();
  await screenshot(tab, "overlay-mount.png");
  check(refused.kind === "page" && refused.text.includes('options.ports has a handler for port "nope"'), "a mount refusal shows in the overlay");
  check(/index\.html changed; reloading the open pages\./.test(output.slice(mark)), "a change to the page reloads without a build");
  await tab.evaluate(() => (window.__beforeReload = true));
  restore("index.html");
  await tab.waitForFunction(() => window.__beforeReload === undefined && document.querySelector('[data-testid="count"]')?.textContent === "10", { timeout: 30000 });

  // An engine fault shows in the overlay.
  edit("Counter.roc", "count.update(|n| n + 1)", 'count.update(|n| if (n >= 10) crash "the counter went past ten" else n + 1)');
  await tab.evaluate(() => (window.__beforeReload = true));
  await tab.waitForFunction(() => window.__beforeReload === undefined && document.querySelector('[data-testid="count"]')?.textContent === "10", { timeout: 120000 });
  await tab.click('button[aria-label="Increment"]');
  await tab.waitForFunction(() => document.querySelector("roc-signals-overlay")?.isConnected === true, { timeout: 30000 });
  const fault = await overlay();
  check(fault.kind === "fault" && fault.text.includes("the counter went past ten"), "an engine fault shows in the overlay");
  restoreAll();

  // Ctrl-C stops the server.
  mark = output.length;
  stop("SIGINT");
  await hearing(/Stopped serving the app\./, { from: mark, timeout: 20000 });
  check(true, "SIGINT stops the server");
  check(errors.every((e) => e.includes("nope") || e.includes("went past ten")), `no unexpected page errors (${errors.length})`);
} catch (e) {
  console.error(e);
  failures += 1;
} finally {
  restoreAll();
  if (browser) await browser.close();
  stop("SIGKILL");
  blocker.close();
}
console.log(failures === 0 ? "tool-serve: passed" : `tool-serve: ${failures} failed`);
process.exit(failures === 0 ? 0 : 1);
