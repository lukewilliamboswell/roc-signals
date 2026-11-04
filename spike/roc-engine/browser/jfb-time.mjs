// jfb-time.mjs DIST_A DIST_B [RUNS] -- js-framework-benchmark create 1k (#run)
// and create 10k (#runlots) in headless Chrome, alternating two builds, one
// fresh page per sample; median ms from the click to the next frame.
import http from "node:http";
import fs from "node:fs";
import path from "node:path";
import { createRequire } from "node:module";

const puppeteer = createRequire(path.join(process.env.NODE_PATH ?? ".", "x.js"))("puppeteer-core");
const [a, b, runsArg] = process.argv.slice(2);
const RUNS = Number(runsArg ?? 9);
const page0 = `<!doctype html><html><body><div id="main"></div><script type="module" src="./main.mjs"></script></body></html>`;
function serve(dist) {
  const server = http.createServer((req, res) => {
    const name = path.basename(new URL(req.url, "http://x").pathname) || "index.html";
    if (name === "index.html") {
      res.writeHead(200, { "content-type": "text/html" });
      res.end(page0);
      return;
    }
    const f = path.join(dist, name);
    if (!fs.existsSync(f)) {
      res.writeHead(404);
      res.end();
      return;
    }
    res.writeHead(200, { "content-type": name.endsWith(".wasm") ? "application/wasm" : "text/javascript" });
    res.end(fs.readFileSync(f));
  });
  return new Promise((r) => server.listen(0, "127.0.0.1", () => r(server)));
}
const servers = [await serve(a), await serve(b)];
const browser = await puppeteer.launch({ executablePath: "/usr/bin/google-chrome", headless: true, args: ["--no-sandbox", "--js-flags=--no-wasm-lazy-compilation"] });
const out = [{ run: [], runlots: [] }, { run: [], runlots: [] }];
for (let i = 0; i < RUNS; i += 1) {
  for (let k = 0; k < 2; k += 1) {
    for (const op of ["run", "runlots"]) {
      const page = await browser.newPage();
      await page.goto(`http://127.0.0.1:${servers[k].address().port}/index.html`);
      await page.waitForSelector(`#${op}`);
      const ms = await page.evaluate((op) => new Promise((r) => {
        const t0 = performance.now();
        document.getElementById(op).click();
        requestAnimationFrame(() => setTimeout(() => r(performance.now() - t0), 0));
      }), op);
      const rows = await page.evaluate(() => document.querySelectorAll("tbody tr").length);
      if (rows !== (op === "run" ? 1000 : 10000)) throw new Error(`${op}: ${rows} rows`);
      out[k][op].push(ms);
      await page.close();
    }
  }
}
await browser.close();
for (const s of servers) s.close();
const med = (xs) => [...xs].sort((x, y) => x - y)[Math.floor(xs.length / 2)];
for (const [k, label] of [[0, "A " + a], [1, "B " + b]]) console.log(`${label}: create 1k ${med(out[k].run).toFixed(1)} ms, create 10k ${med(out[k].runlots).toFixed(1)} ms (median of ${RUNS})`);
