// services-browser.mjs --wasm services.wasm --runtime runtime.mjs --chrome PATH
// -- runtime and host contract cases for the protocol additions of versions 2
// and 3 with tests/apps/services in headless Chrome:
// - the protocol version: the host reports it and the runtime refuses any
//   other version before running anything;
// - malformed boot bytes and a non-UTF-8 effect result poison the instance
//   with class `contract`, and a one-byte template count above 255 with
//   `resource_limit`;
// - the ingress queue is bounded: overflow poisons with `resource_limit`;
// - a submit is default-prevented (no navigation);
// - the boot bytes carry connectivity and visibility, and the subscriptions
//   follow the browser's `online`/`offline` and `visibilitychange` events;
// - the boot bytes say whether local storage is available: a page whose
//   `localStorage` throws boots with the storage flag clear;
// - a <select> re-applies its value when options are inserted or change;
// - the work record: `metric(16 + k)` and `workRecord()` agree, and count
//   the commands the batch applied.
import http from "node:http";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { launch } from "./cdp.mjs";
import { parseArgs, runtimeFiles } from "./args.mjs";

const here = path.dirname(fileURLToPath(import.meta.url));
const opts = parseArgs(process.argv.slice(2));
const files = { "index.html": path.join(here, "index.html"), ...runtimeFiles(opts.runtime), "app.wasm": opts.wasm };
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
const base = `http://127.0.0.1:${server.address().port}`;
const browser = await launch({ executablePath: opts.chrome });

let failures = 0;
const check = (name, got, want) => {
  const ok = JSON.stringify(got) === JSON.stringify(want);
  if (!ok) failures += 1;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok ? "" : `: got ${JSON.stringify(got)}, want ${JSON.stringify(want)}`}`);
};

async function open(prelude = "") {
  const ctx = await browser.createBrowserContext();
  const page = await ctx.newPage();
  page.on("pageerror", (e) => console.log("pageerror", String(e)));
  if (prelude) await page.evaluateOnNewDocument(prelude);
  await page.goto(`${base}/app/`);
  await page.waitForFunction("window.__ready || window.__error");
  return { page, ctx };
}

// Raw instances of the module, outside the runtime.
{
  const { page, ctx } = await open();
  const raw = await page.evaluate(async () => {
    const { RocEngineRuntime, PROTOCOL_VERSION, pageImports } = await import("./runtime.mjs");
    const module = await WebAssembly.compile(await (await fetch("app.wasm")).arrayBuffer());
    // Every module imports the worker effects, which the page's instance
    // answers with throwing stubs.
    const fresh = async () => (await WebAssembly.instantiate(module, pageImports(module))).exports;
    const text = (x) => new TextDecoder().decode(new Uint8Array(x.memory.buffer, x.err_ptr(), x.err_len()));
    const out = {};
    // The version.
    const x0 = await fresh();
    out.version = [x0.protocol_version(), PROTOCOL_VERSION];
    const fake = { ...x0, protocol_version: () => PROTOCOL_VERSION + 1 };
    const root = document.createElement("div");
    try {
      new RocEngineRuntime(fake, root).mount();
      out.refused = "mounted";
    } catch (e) {
      out.refused = [String(e.message).includes("is not the protocol"), root.childNodes.length];
    }
    // Malformed boot bytes: a URL length that runs past the end.
    const x1 = await fresh();
    x1.boot_keys();
    const p1 = x1.payload_reserve(3);
    new Uint8Array(x1.memory.buffer, p1, 3).set([9, 0, 0]);
    try {
      x1.init();
      out.boot = "accepted";
    } catch (_) {
      out.boot = [x1.fault(), text(x1).split(" ").slice(0, 3).join(" ")];
    }
    // Boot bytes without the online, visible and storage flags.
    const x2 = await fresh();
    x2.boot_keys();
    const p2 = x2.payload_reserve(8);
    new Uint8Array(x2.memory.buffer, p2, 8).set([0, 0, 0, 0, 0, 0, 0, 0]);
    try {
      x2.init();
      out.flags = "accepted";
    } catch (_) {
      out.flags = [x2.fault(), text(x2)];
    }
    // A storage value that is not UTF-8, on the effect node.
    const x3 = await fresh();
    x3.boot_keys();
    x3.payload_reserve(0);
    x3.init();
    const p3 = x3.payload_reserve(2);
    new Uint8Array(x3.memory.buffer, p3, 2).set([3, 0xff]);
    try {
      x3.event(0xffffffff, 1);
      out.utf8 = "accepted";
    } catch (_) {
      out.utf8 = [x3.fault(), text(x3)];
    }
    // A row template with 256 children: a resource limit, not a wrap.
    const x4 = await fresh();
    x4.boot_keys();
    const url = new TextEncoder().encode("/#limit-children");
    const boot = new Uint8Array(4 + url.length + 4 + 3);
    new DataView(boot.buffer).setUint32(0, url.length, true);
    boot.set(url, 4);
    boot.set([1, 1, 1], boot.length - 3);
    const p4 = x4.payload_reserve(boot.length);
    new Uint8Array(x4.memory.buffer, p4, boot.length).set(boot);
    try {
      x4.init();
      out.wide = "accepted";
    } catch (_) {
      out.wide = [x4.fault(), text(x4)];
    }
    return out;
  });
  check("host reports the protocol version the runtime implements", raw.version[0], raw.version[1]);
  check("a module of another protocol is refused before it runs", raw.refused, [true, 0]);
  check("truncated boot bytes: contract fault", raw.boot, [1, "contract: truncated boot"]);
  check("boot bytes without flags: contract fault", raw.flags, [1, "contract: boot bytes end without online, visible and storage flags (0 or 1)"]);
  check("non-UTF-8 effect result: contract fault", raw.utf8, [1, "contract: effect result text is not UTF-8"]);
  check("a row template with 256 children: resource_limit fault", raw.wide, [2, "resource_limit: a row template's children of one element is 256; the template encoding allows at most 255"]);
  await ctx.close();
}

// A page whose localStorage throws, as with site data disabled.
{
  const { page, ctx } = await open("Object.defineProperty(window, 'localStorage', { get: () => { throw new DOMException('denied', 'SecurityError'); }, configurable: true })");
  const got = await page.evaluate(() => document.querySelector('[data-testid="storage"]').textContent);
  check("boot carries storage availability (localStorage throws)", got, "storage unavailable");
  await ctx.close();
}

// The ingress bound.
{
  const { page, ctx } = await open();
  const r = await page.evaluate(async () => {
    const { MAX_QUEUED } = await import("./runtime.mjs");
    const rt = window.__rt;
    rt.busy = true;
    for (let i = 0; i <= MAX_QUEUED; i += 1) rt.dispatch(1, 0, "");
    rt.busy = false;
    return [rt.poisoned && rt.poisoned.class, rt.queue.length, rt.poisoned && rt.poisoned.message.startsWith("resource_limit:")];
  });
  check("queue overflow poisons with resource_limit and drops the queue", r, ["resource_limit", 0, true]);
  await ctx.close();
}

// Submit, selects, connectivity, visibility and the work record.
{
  const { page, ctx } = await open("Object.defineProperty(navigator, 'onLine', { get: () => false, configurable: true })");
  const text = (id) => page.evaluate((id) => document.querySelector(`[data-testid="${id}"]`).textContent, id);
  check("boot carries connectivity (booted offline)", await text("online"), "offline");
  check("boot carries storage availability (available)", await text("storage"), "storage available");
  await page.evaluate(() => {
    Object.defineProperty(navigator, "onLine", { get: () => true, configurable: true });
    window.dispatchEvent(new Event("online"));
  });
  check("online event reaches the subscription", await text("online"), "online");
  await page.evaluate(() => {
    Object.defineProperty(document, "visibilityState", { get: () => "hidden", configurable: true });
    document.dispatchEvent(new Event("visibilitychange"));
  });
  check("visibilitychange reaches the subscription and disposes the poll", [await text("visible"), await page.evaluate(() => window.__rt.intervals(5000).length)], ["hidden", 0]);
  const submit = await page.evaluate(() => {
    let prevented = null;
    window.addEventListener("submit", (e) => (prevented = e.defaultPrevented));
    const before = location.href;
    document.querySelector("form").requestSubmit();
    return [prevented, location.href === before, document.querySelector("[data-testid=submitted]").textContent];
  });
  check("submit is default-prevented and reaches the app", submit, [true, true, "1"]);
  const shade = await page.evaluate(() => {
    const sel = document.querySelector("[aria-label=Shade]");
    return [sel.value, sel.options.length];
  });
  check("select value re-applied after its options mount", shade, ["teal", 3]);
  const work = await page.evaluate(() => {
    const rt = window.__rt;
    const before = rt.workRecord().counters;
    document.querySelector("[aria-label=Press]").click();
    const after = rt.workRecord().counters;
    const viaMetric = rt.x.metric(16 + 12);
    return [after.length, String(after[12] - before[12]), String(viaMetric) === String(after[12]), String(after[1])];
  });
  check("work record: 41 counters (work, the effect counters, port commands sent); one SETTEXT for one click; metric(16 + k) reads counter k", work, [41, "1", true, "3"]);
  await ctx.close();
}

await browser.close();
server.close();
console.log(failures === 0 ? "== services contract: all pass" : `== services contract: ${failures} failures`);
process.exit(failures === 0 ? 0 : 1);
