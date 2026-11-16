// file-effects-browser.mjs --wasm APP.wasm --runtime runtime.mjs --chrome PATH
//
// Browser contract test of operations on a file the app holds, with
// tests/apps/file-effects in headless Chrome (design.md, "Files"; Appendix
// B), for what specs cannot reach: the browser's own file failing, the
// runtime's bounds as mount options, the page's memory, and the ownership
// of each request's browser file through cancellation, poisoning and
// unmounting.
//
// Page reads: a read copies the file's range into the page's memory once, as
// the result, and the bytes are freed when the app lets them go; a range
// over the read's `max_bytes` or the page's `maxFileBytes` is refused
// unread; a file that can no longer be read
// is `Unreadable`; a read cancelled while the browser reads is dropped, with
// no stale turn; a read in flight when the instance is poisoned delivers
// nothing.
//
// In-place operations: an upload streams exactly the file's range to a real
// server without the page's memory holding it, and an unreadable file fails
// it as a network failure; a digest is WebCrypto's SHA-256 of the range,
// TooLarge over `maxFileBytes` and Unavailable without WebCrypto; a file URL
// is fetchable while the app holds the file, the same range gives the same
// URL, a handle gives at most 16 ranges URLs, and releasing the handle or
// unmounting revokes them.
import http from "node:http";
import fs from "node:fs";
import path from "node:path";
import os from "node:os";
import crypto from "node:crypto";
import { launch } from "./cdp.mjs";
import { parseArgs, runtimeFiles } from "./args.mjs";

const opts = parseArgs(process.argv.slice(2));
const files = { ...runtimeFiles(opts.runtime), "app.wasm": opts.wasm };
const server = http.createServer((req, res) => {
  const u = new URL(req.url, "http://x");
  if (u.pathname === "/upload") {
    // Answer with what arrived: the body's length and SHA-256, and the
    // header the app named the file in.
    const hash = crypto.createHash("sha256");
    let len = 0;
    req.on("data", (c) => {
      len += c.length;
      hash.update(c);
    });
    req.on("end", () => {
      res.writeHead(200, { "content-type": "text/plain" });
      res.end(`${req.method} ${req.headers["x-name"]} ${len} ${hash.digest("hex")}`);
    });
    return;
  }
  if (u.pathname === "/") {
    res.writeHead(200, { "content-type": "text/html" });
    res.end('<!doctype html><html><head><meta charset="utf-8"><title>file effects</title></head><body></body></html>');
    return;
  }
  const f = files[path.basename(u.pathname)];
  if (!f || !fs.existsSync(f)) {
    res.writeHead(404);
    res.end();
    return;
  }
  res.writeHead(200, { "content-type": f.endsWith(".wasm") ? "application/wasm" : "text/javascript" });
  res.end(fs.readFileSync(f));
});
await new Promise((r) => server.listen(0, "127.0.0.1", r));
const base = `http://127.0.0.1:${server.address().port}`;
const browser = await launch({ executablePath: opts.chrome });

let failures = 0;
const check = (name, got, want) => {
  const ok = JSON.stringify(got) === JSON.stringify(want);
  if (!ok) failures += 1;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok ? "" : `: got ${JSON.stringify(got)}, want ${JSON.stringify(want)}`}`);
};

function install() {
  window.__mount = async (options = {}) => {
    const { mountRocEngineApp } = await import("/runtime.mjs");
    const root = document.createElement("div");
    document.body.append(root);
    window.__root = root;
    window.__rt = await mountRocEngineApp({ wasmUrl: "/app.wasm", root, onFault: () => {}, ...options });
    return true;
  };
  // Choose files of `size` bytes each (every byte 1) in the file input, as
  // the browser's chooser does.
  window.__choose = (specs) => {
    const dt = new DataTransfer();
    for (const [name, size] of specs) dt.items.add(new File([new Uint8Array(size).fill(1)], name, { type: "application/octet-stream" }));
    const input = window.__root.querySelector('[aria-label="Upload"]');
    input.files = dt.files;
    input.dispatchEvent(new Event("change", { bubbles: true }));
  };
  window.__click = (label) => [...window.__root.querySelectorAll("button")].find((b) => b.textContent === label).click();
  window.__text = (id) => window.__root.querySelector(`[data-testid=${id}]`).textContent;
  window.__until = (id, pred) =>
    new Promise((resolve, reject) => {
      const t = setTimeout(() => reject(new Error(`timed out: ${window.__text(id)}`)), 20000);
      const tick = () => {
        if (pred(window.__text(id))) {
          clearTimeout(t);
          resolve(window.__text(id));
        } else setTimeout(tick, 5);
      };
      tick();
    });
  window.__liveBytes = () => Number(window.__rt.x.metric(5));
  window.__counter = (i) => Number(window.__rt.workRecord().counters[i]);
}

async function open(options = {}) {
  const ctx = await browser.createBrowserContext();
  const page = await ctx.newPage();
  page.on("pageerror", (e) => console.log("pageerror", String(e)));
  await page.evaluateOnNewDocument(install);
  await page.goto(`${base}/`);
  await page.evaluate((o) => window.__mount(o), options);
  return { page, ctx };
}

// A page read copies the range into the page's memory once, as the result
// the app keeps; the bytes go when the app lets the answer go, and the
// runtime lets the file go when the app does.
{
  const { page, ctx } = await open();
  const r = await page.evaluate(async () => {
    window.__choose([["four.bin", 4 << 20]]);
    const before = window.__liveBytes();
    window.__click("Read bytes");
    const text = await window.__until("read", (t) => t.startsWith("bytes"));
    const held = window.__liveBytes() - before;
    window.__click("Forget");
    const after = window.__liveBytes() - before;
    window.__click("Clear");
    return { text, held: held >= 4 << 20 && held < (4 << 20) + 65536, freed: after < 65536, files: window.__rt.files.size };
  });
  check("a read copies the file into the page once and frees it with the answer", r, { text: `bytes ${4 << 20} sum ${4 << 20}`, held: true, freed: true, files: 0 });
  await ctx.close();
}

// A range over maxFileBytes is refused before anything is read, whatever
// the read accepts; a smaller range of the file reads.
{
  const { page, ctx } = await open({ maxFileBytes: 2 });
  const r = await page.evaluate(async () => {
    window.__choose([["three.bin", 3]]);
    window.__click("Read large");
    const big = await window.__until("read", (t) => t.startsWith("failed"));
    window.__click("Read tail");
    const tail = await window.__until("read", (t) => t.startsWith("bytes"));
    return { big, tail };
  });
  check("a range over maxFileBytes is TooLarge whatever the read accepts, a smaller range of the file reads", r, { big: "failed TooLarge", tail: "bytes 2 sum 2" });
  await ctx.close();
}

// A range over the read's max_bytes is refused before anything is read.
{
  const { page, ctx } = await open();
  const r = await page.evaluate(async () => {
    window.__choose([["nine.bin", (8 << 20) + 1]]);
    window.__click("Read bytes");
    return window.__until("read", (t) => t.startsWith("failed"));
  });
  check("a range over the read's max_bytes is TooLarge", r, "failed TooLarge");
  await ctx.close();
}

// A file the browser can no longer read: its disk file was deleted after it
// was chosen.
{
  const { page, ctx } = await open();
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "roc-signals-file-effects-"));
  const file = path.join(dir, "gone.txt");
  fs.writeFileSync(file, "soon gone");
  const input = await page.evaluateHandle(() => window.__root.querySelector('[aria-label="Upload"]'));
  await page.send("DOM.setFileInputFiles", { files: [file], objectId: input.objectId });
  fs.rmSync(dir, { recursive: true, force: true });
  const r = await page.evaluate(async () => {
    window.__click("Read text");
    return window.__until("read", (t) => t.startsWith("failed"));
  });
  check("a file that can no longer be read is Unreadable", r, "failed Unreadable");
  await ctx.close();
}

// A read given up while the browser reads is dropped: no stale turn, and
// the next read answers with its own file.
{
  const { page, ctx } = await open();
  const r = await page.evaluate(async () => {
    window.__choose([["big.bin", 32 << 20]]);
    const stale = window.__counter(34);
    const turns = window.__counter(30);
    window.__click("Read large");
    window.__click("Forget");
    await new Promise((r) => setTimeout(r, 300));
    const quiet = window.__counter(30) - turns;
    window.__click("Clear");
    window.__choose([["small.bin", 2]]);
    window.__click("Read bytes");
    const text = await window.__until("read", (t) => t.startsWith("bytes"));
    return { text, quiet, stale: window.__counter(34) - stale, cancelled: window.__counter(36) };
  });
  check("a cancelled read is dropped without a turn", r, { text: "bytes 2 sum 2", quiet: 2, stale: 0, cancelled: 1 });
  await ctx.close();
}

// A read in flight when the instance is poisoned delivers nothing.
{
  const { page, ctx } = await open();
  const r = await page.evaluate(async () => {
    window.__choose([["big.bin", 32 << 20]]);
    window.__click("Read large");
    try {
      window.__rt.x.event(0xffffffff, 0);
    } catch (e) {
      window.__rt.contain(e);
    }
    await new Promise((r) => setTimeout(r, 300));
    return { poisoned: !!window.__rt.poisoned, refused: window.__rt.refused, live: window.__rt.live.size, files: window.__rt.files.size };
  });
  check("a read in flight at poisoning delivers nothing", r, { poisoned: true, refused: 0, live: 0, files: 0 });
  await ctx.close();
}

const sha = (buf) => crypto.createHash("sha256").update(buf).digest("hex");

// An upload streams the file, or its range, to the server: the server
// receives exactly those bytes, and the page's memory does not hold them.
{
  const { page, ctx } = await open();
  const size = 8 << 20;
  const r = await page.evaluate(async (size) => {
    window.__choose([["up.bin", size]]);
    const before = window.__liveBytes();
    window.__click("Send");
    const whole = await window.__until("sent", (t) => t !== "waiting");
    const grew = window.__liveBytes() - before;
    window.__click("Send tail");
    const tail = await window.__until("sent", (t) => t !== "waiting" && t !== whole);
    return { whole, tail, small: grew < 65536 };
  }, size);
  const ones = (n) => Buffer.alloc(n, 1);
  check("an upload sends the file's bytes, and a range's", r, { whole: `sent POST up.bin ${size} ${sha(ones(size))}`, tail: `sent POST up.bin ${size / 2} ${sha(ones(size / 2))}`, small: true });
  await ctx.close();
}

// An upload of a file the browser can no longer read fails as the browser
// reports it: a network failure.
{
  const { page, ctx } = await open();
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "roc-signals-file-effects-"));
  const file = path.join(dir, "gone.txt");
  fs.writeFileSync(file, "soon gone");
  const input = await page.evaluateHandle(() => window.__root.querySelector('[aria-label="Upload"]'));
  await page.send("DOM.setFileInputFiles", { files: [file], objectId: input.objectId });
  fs.rmSync(dir, { recursive: true, force: true });
  const r = await page.evaluate(async () => {
    window.__click("Send");
    return window.__until("sent", (t) => t !== "waiting");
  });
  check("an upload of an unreadable file is a network failure", r.startsWith("send failed Network("), true);
  await ctx.close();
}

// A digest is WebCrypto's SHA-256 of the range; a range over maxFileBytes
// is TooLarge unread, and an absent digest service is Unavailable.
{
  const { page, ctx } = await open();
  const r = await page.evaluate(async () => {
    window.__choose([["d.bin", 3 << 20]]);
    window.__click("Digest");
    return window.__until("digest", (t) => t !== "waiting");
  });
  check("a digest is the file's SHA-256", r, `sha256 ${sha(Buffer.alloc(3 << 20, 1))}`);
  await ctx.close();
}
{
  const { page, ctx } = await open({ maxFileBytes: 2 });
  const r = await page.evaluate(async () => {
    window.__choose([["d.bin", 3]]);
    window.__click("Digest");
    return window.__until("digest", (t) => t !== "waiting");
  });
  check("a digest over maxFileBytes is TooLarge", r, "digest failed TooLarge");
  await ctx.close();
}
{
  const ctx = await browser.createBrowserContext();
  const page = await ctx.newPage();
  await page.evaluateOnNewDocument(install);
  await page.evaluateOnNewDocument(() => {
    // Mount still needs entropy; remove only the digest service this case tests.
    const getRandomValues = window.crypto.getRandomValues.bind(window.crypto);
    Object.defineProperty(window, "crypto", { value: { getRandomValues }, configurable: true });
  });
  await page.goto(`${base}/`);
  await page.evaluate(() => window.__mount({}));
  const r = await page.evaluate(async () => {
    window.__choose([["d.bin", 3]]);
    window.__click("Digest");
    return window.__until("digest", (t) => t !== "waiting");
  });
  check("a digest without SubtleCrypto is Unavailable", r, "digest failed Unavailable");
  await ctx.close();
}

// A file URL shows the file while the app holds it: the same range gives
// the same URL, a handle gives at most 16 ranges URLs, and releasing the
// handle (or unmounting) revokes them.
{
  const { page, ctx } = await open();
  const r = await page.evaluate(async () => {
    window.__choose([["u.txt", 5]]);
    window.__click("Show");
    await window.__until("shown", (t) => t === "shown");
    const url = window.__root.querySelector("[data-testid=preview]").getAttribute("href");
    const body = await (await fetch(url)).arrayBuffer();
    window.__click("Hide");
    window.__click("Show");
    await window.__until("shown", (t) => t === "shown");
    const again = window.__root.querySelector("[data-testid=preview]").getAttribute("href");
    const rt = window.__rt;
    const token = [...rt.files.keys()][0];
    const file = rt.files.get(token);
    const answers = [];
    for (let i = 0; i < 16; i += 1) {
      const a = await rt.fileAnswer({ op: "url", token, start: i % 5, len: 1 + Math.floor(i / 5), blob: file.slice(0, 1) });
      answers.push(a[0]);
    }
    const counts = { urls: answers.filter((t) => t === 19).length, refused: answers.filter((t) => t === 13).length };
    window.__click("Hide");
    window.__click("Clear");
    let revoked = false;
    try {
      await fetch(url);
    } catch (_) {
      revoked = true;
    }
    return { size: body.byteLength, same: url === again, counts, revoked, urls: rt.urls.size };
  });
  // The whole file's URL is one of the 16; the loop makes 15 more ranges and
  // the 16th it asks for is refused.
  check("a file URL lives exactly as long as its handle", r, { size: 5, same: true, counts: { urls: 15, refused: 1 }, revoked: true, urls: 0 });
  await ctx.close();
}
{
  const { page, ctx } = await open();
  const r = await page.evaluate(async () => {
    window.__choose([["u.txt", 5]]);
    window.__click("Show");
    await window.__until("shown", (t) => t === "shown");
    const url = window.__root.querySelector("[data-testid=preview]").getAttribute("href");
    window.__rt.unmount();
    try {
      await fetch(url);
      return false;
    } catch (_) {
      return true;
    }
  });
  check("unmounting revokes every file URL", r, true);
  await ctx.close();
}

await browser.close();
server.close();
console.log(failures === 0 ? "== file-effects-browser: all pass" : `== file-effects-browser: ${failures} failed`);
process.exit(failures === 0 ? 0 : 1);
