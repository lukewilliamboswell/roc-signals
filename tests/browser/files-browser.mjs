// files-browser.mjs --wasm APP.wasm --runtime runtime.mjs --chrome PATH --
// browser contract test of file handles with tests/apps/files in headless
// Chrome (design.md, "Files"; Appendix B). It drives the host's exports and
// the runtime directly, for the ownership transitions specs cannot reach:
// handles minted for an event on a removed node are released by Roc when the
// event is dropped; staging again releases an undelivered set; minting stops
// at the handle bound; a drop that carries no files dispatches nothing; a
// handle released in a call keeps its file until that call's effects are
// performed; poisoning and unmounting let go of every file the runtime holds.
import http from "node:http";
import fs from "node:fs";
import path from "node:path";
import { launch } from "./cdp.mjs";
import { parseArgs, runtimeFiles } from "./args.mjs";

const opts = parseArgs(process.argv.slice(2));
const files = { ...runtimeFiles(opts.runtime), "app.wasm": opts.wasm };
const server = http.createServer((req, res) => {
  const u = new URL(req.url, "http://x");
  if (u.pathname === "/") {
    res.writeHead(200, { "content-type": "text/html" });
    res.end('<!doctype html><html><head><meta charset="utf-8"><title>files</title></head><body></body></html>');
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
  window.__mount = async () => {
    const { mountRocEngineApp } = await import("/runtime.mjs");
    const root = document.createElement("div");
    document.body.append(root);
    window.__root = root;
    window.__rt = await mountRocEngineApp({ wasmUrl: "/app.wasm", root, onFault: () => {} });
    return true;
  };
  window.__live = () => Number(window.__rt.x.metric(6));
  window.__held = () => window.__rt.files.size;
  window.__list = () => window.__root.querySelector("[data-testid=files]").textContent;
  window.__drop = (label, names) => {
    const dt = new DataTransfer();
    for (const n of names) dt.items.add(new File(["x"], n, { type: "text/plain" }));
    const el = window.__root.querySelector(`[aria-label="${label}"]`);
    el.dispatchEvent(new DragEvent("dragover", { dataTransfer: dt, bubbles: true, cancelable: true }));
    el.dispatchEvent(new DragEvent("drop", { dataTransfer: dt, bubbles: true, cancelable: true }));
  };
  window.__click = (label) => [...window.__root.querySelectorAll("button")].find((b) => b.textContent === label).click();
}

async function open() {
  const ctx = await browser.createBrowserContext();
  const page = await ctx.newPage();
  page.on("pageerror", (e) => console.log("pageerror", String(e)));
  await page.evaluateOnNewDocument(install);
  await page.goto(`${base}/`);
  await page.evaluate(() => window.__mount());
  return { page, ctx };
}

// Handles minted for an event that reaches no node go with the event: Roc
// drops them, and the next drain lists them. Staging again first releases
// a staged set no call took.
{
  const { page, ctx } = await open();
  const r = await page.evaluate(() => {
    const x = window.__rt.x;
    const minted = x.files_stage(2);
    const staged = window.__live();
    // A record for two files, delivered to a node id nothing holds.
    const rec = new Uint8Array([2, 0, 0, 0, 0, 0, 0, 0, ...[1, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 97, 0, 0, 0, 0], ...[1, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 98, 0, 0, 0, 0]]);
    const p = x.payload_reserve(rec.length);
    new Uint8Array(x.memory.buffer, p, rec.length).set(rec);
    x.event_files(4000000, 0);
    // Retired, not yet drained: still counted until the runtime drains.
    const retired = window.__live();
    const released = x.files_released();
    const after = window.__live();
    const again = x.files_stage(3);
    const restaged = x.files_stage(1);
    const freed = x.files_released();
    x.files_stage(0);
    const last = x.files_released();
    return { minted, staged, retired, released, after, again, restaged, freed, last, end: window.__live() };
  });
  check("an event for no node releases its handles", [r.minted, r.staged, r.retired, r.released, r.after], [2, 2, 2, 2, 0]);
  check("staging again releases the undelivered set", [r.again, r.restaged, r.freed, r.last, r.end], [3, 1, 3, 1, 0]);
  await ctx.close();
}

// The bound: 64 handles live at once; the rest of an event's files are
// refused, and a drop that carries no files dispatches nothing.
{
  const { page, ctx } = await open();
  const r = await page.evaluate(() => {
    window.__drop("Drop", Array.from({ length: 70 }, (_, i) => `f${i}.txt`));
    const refused = window.__root.querySelector("[data-testid=refused]").textContent;
    const live = window.__live();
    const held = window.__held();
    const turns = window.__rt.workRecord().counters[30];
    window.__drop("Drop", []);
    return { refused, live, held, same: window.__rt.workRecord().counters[30] === turns };
  });
  check("files beyond the bound are refused and counted", r, { refused: "refused 6", live: 64, held: 64, same: true });
  await ctx.close();
}

// The runtime holds exactly the files whose handles are live, releasing a
// file after the call whose batch dropped its last handle.
{
  const { page, ctx } = await open();
  const r = await page.evaluate(() => {
    window.__drop("Drop", ["a.txt", "b.txt", "c.txt"]);
    const before = [window.__live(), window.__held()];
    window.__click("Keep first");
    const kept = [window.__live(), window.__held(), [...window.__rt.files.values()].map((f) => f.name)];
    window.__click("Clear");
    return { before, kept, cleared: [window.__live(), window.__held()] };
  });
  check("the runtime holds the files of live handles", r, { before: [3, 3], kept: [1, 1, ["a.txt"]], cleared: [0, 0] });
  await ctx.close();
}

// Poisoning and unmounting let go of every file.
{
  const { page, ctx } = await open();
  const r = await page.evaluate(() => {
    window.__drop("Drop", ["a.txt", "b.txt"]);
    const held = window.__held();
    try {
      window.__rt.x.event(0xffffffff, 0);
    } catch (e) {
      window.__rt.contain(e);
    }
    return { held, poisoned: !!window.__rt.poisoned, after: window.__held() };
  });
  check("poisoning lets go of every file", r, { held: 2, poisoned: true, after: 0 });
  await ctx.close();
}
{
  const { page, ctx } = await open();
  const r = await page.evaluate(() => {
    window.__drop("Drop", ["a.txt", "b.txt"]);
    const held = window.__held();
    window.__rt.unmount();
    return { held, after: window.__held() };
  });
  check("unmounting lets go of every file", r, { held: 2, after: 0 });
  await ctx.close();
}

await browser.close();
server.close();
console.log(failures === 0 ? "== files-browser: all pass" : `== files-browser: ${failures} failed`);
process.exit(failures === 0 ? 0 : 1);
