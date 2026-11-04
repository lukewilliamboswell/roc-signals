// jfb-check.mjs DIST_DIR -- the js-framework-benchmark keyed operations on a
// built jfb app (jfb/roc-d-each/build.sh output) in headless Chrome, with
// DOM checks after each: run, update every 10th, select, swap, remove,
// clear, runlots, add, plus row identity (keyed) across swap and update.
import http from "node:http";
import fs from "node:fs";
import path from "node:path";
import { createRequire } from "node:module";

const puppeteer = createRequire(path.join(process.env.NODE_PATH ?? ".", "x.js"))("puppeteer-core");
const dist = process.argv[2];
const page0 = `<!doctype html><html><body><div id="main"></div><script type="module" src="./main.mjs"></script></body></html>`;
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
await new Promise((r) => server.listen(0, "127.0.0.1", r));
const browser = await puppeteer.launch({ executablePath: "/usr/bin/google-chrome", headless: true, args: ["--no-sandbox"] });
const page = await browser.newPage();
const errors = [];
page.on("pageerror", (e) => errors.push(String(e)));
await page.goto(`http://127.0.0.1:${server.address().port}/index.html`);
await page.waitForSelector("#run");
let failures = 0;
const check = (name, ok, detail = "") => {
  if (!ok) failures += 1;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok ? "" : " " + detail}`);
};
const rows = () => page.evaluate(() => document.querySelectorAll("tbody tr").length);
const label = (i) => page.evaluate((i) => document.querySelectorAll("tbody tr")[i].querySelector("td:nth-child(2) a").textContent, i);
const time = async (name, sel) => {
  const t0 = Date.now();
  await page.click(sel);
  await page.evaluate(() => new Promise((r) => requestAnimationFrame(() => r())));
  return Date.now() - t0;
};
let t = await time("run", "#run");
check(`run: 1000 rows (${t} ms)`, (await rows()) === 1000);
const tr5 = await page.evaluateHandle(() => document.querySelectorAll("tbody tr")[4]);
await time("update", "#update");
check("update: every 10th label ends with !!!", (await label(0)).endsWith(" !!!") && (await label(10)).endsWith(" !!!") && !(await label(1)).endsWith(" !!!"));
check("update keeps row identity", await page.evaluate((r) => r === document.querySelectorAll("tbody tr")[4], tr5));
await page.click("tbody tr:nth-child(3) td:nth-child(2) a");
check("select: row 3 has class danger", await page.evaluate(() => document.querySelectorAll("tbody tr")[2].className === "danger" && document.querySelectorAll("tr.danger").length === 1));
const l1 = await label(1);
const l998 = await label(998);
const tr2 = await page.evaluateHandle(() => document.querySelectorAll("tbody tr")[1]);
await time("swap", "#swaprows");
check("swap: rows 2 and 999 swapped", (await label(1)) === l998 && (await label(998)) === l1);
check("swap moves the row element (keyed)", await page.evaluate((r) => r === document.querySelectorAll("tbody tr")[998], tr2));
const l4 = await label(4);
// The remove glyph has no size without the jfb CSS: dispatch the click on it.
await page.evaluate(() => document.querySelectorAll("tbody tr")[3].querySelector("td:nth-child(3) span").click());
check("remove: 999 rows, row 4 gone", (await rows()) === 999 && (await label(3)) === l4);
t = await time("clear", "#clear");
check(`clear: 0 rows (${t} ms)`, (await rows()) === 0);
t = await time("runlots", "#runlots");
check(`runlots: 10000 rows (${t} ms)`, (await rows()) === 10000);
t = await time("add", "#add");
check(`add: 11000 rows (${t} ms)`, (await rows()) === 11000);
await time("clear", "#clear");
check("clear after runlots: 0 rows", (await rows()) === 0);
check("no page errors", errors.length === 0, errors.join("; "));
await browser.close();
server.close();
console.log(failures === 0 ? "== jfb: all pass" : `== jfb: ${failures} failures`);
process.exit(failures === 0 ? 0 : 1);
