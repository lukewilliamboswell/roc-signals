// tool-dist.mjs --dist DIR --chrome PATH
//
// The `dist/` that `roc signals.roc build` made for the Worker Lab, served
// by a plain static file server (`www/serve.mjs`, which knows nothing of
// the app or the tool) and opened in headless Chrome. It checks that the
// page loads the module, the runtime and the style it links from the hashed
// directory, that a file from `public/` is served under its own name, that
// the app mounts, and that a run of jobs is answered by real Web Workers
// started from the `worker.mjs` beside the runtime in that directory.
import { spawn } from "node:child_process";
import net from "node:net";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { launch } from "./cdp.mjs";

const opts = {};
const argv = process.argv.slice(2).filter((a) => a !== "--");
for (let i = 0; i < argv.length; i += 2) opts[argv[i].replace(/^--/, "")] = argv[i + 1];
for (const k of ["dist", "chrome"]) if (!opts[k]) throw new Error(`--${k} is required`);
const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");

let failures = 0;
const check = (ok, label) => {
  console.log(`${ok ? "ok  " : "FAIL"} ${label}`);
  if (!ok) failures += 1;
};

// A free port for the static server.
const probe = net.createServer();
await new Promise((r) => probe.listen(0, "127.0.0.1", r));
const port = probe.address().port;
await new Promise((r) => probe.close(r));
const server = spawn(process.execPath, [path.join(repo, "www/serve.mjs"), path.resolve(opts.dist), "--port", String(port)], { stdio: ["ignore", "pipe", "inherit"] });
await new Promise((resolve, reject) => {
  server.stdout.on("data", (d) => (d.toString().includes("serving") ? resolve() : null));
  server.on("exit", (code) => reject(new Error(`the static server exited with ${code}`)));
});
process.on("exit", () => server.kill("SIGKILL"));

let browser = null;
try {
  browser = await launch({ executablePath: opts.chrome });
  const page = await browser.newPage();
  const errors = [];
  page.on("pageerror", (e) => errors.push(String(e)));
  // Record every worker the page starts, by its script's URL.
  await page.evaluateOnNewDocument(() => {
    window.__workers = [];
    const Native = window.Worker;
    window.Worker = class extends Native {
      constructor(url, options) {
        super(url, options);
        window.__workers.push(String(url));
      }
    };
  });
  await page.goto(`http://127.0.0.1:${port}/`);
  await page.waitForFunction(() => document.querySelector('input[aria-label="Jobs"]') !== null, { timeout: 30000 });
  const loaded = await page.evaluate(() => performance.getEntriesByType("resource").map((e) => new URL(e.name).pathname));
  const hashed = /^\/assets\/[0-9a-f]{16}\//;
  check(["app.wasm", "runtime.mjs", "style.css"].every((f) => loaded.some((p) => hashed.test(p) && p.endsWith(`/${f}`))), "the page loads app.wasm, runtime.mjs and its style from the hashed directory");
  const robots = await fetch(`http://127.0.0.1:${port}/robots.txt`);
  check(robots.status === 200, "a file from public/ is served under its own name");

  await page.evaluate(() => {
    const set = (label, value) => {
      const el = document.querySelector(`input[aria-label="${label}"]`);
      el.value = String(value);
      el.dispatchEvent(new Event("input", { bubbles: true }));
    };
    set("Jobs", 4);
    set("Weight", 1);
    [...document.querySelectorAll("button")].find((b) => b.textContent === "Start").click();
  });
  await page.waitForFunction(
    () => {
      const rows = [...document.querySelectorAll("[data-testid^='job-']")].map((e) => e.textContent);
      return rows.length === 4 && rows.every((r) => r.startsWith("done:"));
    },
    { timeout: 60000 },
  );
  check(true, "a run of four jobs is answered");
  const workers = await page.evaluate(() => window.__workers);
  check(workers.length > 0 && workers.every((u) => hashed.test(new URL(u).pathname) && u.endsWith("/worker.mjs")), `the jobs ran in Web Workers started from the hashed worker.mjs (${workers.length})`);
  check(errors.length === 0, `no page errors (${errors.join("; ")})`);
} catch (e) {
  console.error(e);
  failures += 1;
} finally {
  if (browser) await browser.close();
  server.kill("SIGKILL");
}
console.log(failures === 0 ? "tool-dist: passed" : `tool-dist: ${failures} failed`);
process.exit(failures === 0 ? 0 : 1);
