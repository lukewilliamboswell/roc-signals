// THROWAWAY (fork task E): does a full idle ingress queue plus one
// synchronous re-entrant event during the early drain's initiating turn
// poison the runtime? Only the Wasm call (`deliver`) is replaced; the queue,
// scheduler, listeners and `handle` are the real runtime's.
import http from "node:http";
import fs from "node:fs";
import path from "node:path";
import { launch } from "./cdp.mjs";
import { parseArgs, runtimeFiles } from "./args.mjs";
import { installProtocolFixture } from "./protocol-fixture.mjs";

const opts = parseArgs(process.argv.slice(2), [], ["runtime"]);
const files = runtimeFiles(opts.runtime);
const server = http.createServer((req, res) => {
  if (req.url === "/") { res.writeHead(200, { "content-type": "text/html" }); res.end('<!doctype html><html><head><meta charset="utf-8"></head><body></body></html>'); return; }
  const file = files[path.basename(new URL(req.url, "http://x").pathname)];
  if (!file) { res.writeHead(404); res.end(); return; }
  res.writeHead(200, { "content-type": "text/javascript" });
  res.end(fs.readFileSync(file));
});
await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
const browser = await launch({ executablePath: opts.chrome });
const ctx = await browser.createBrowserContext();
const page = await ctx.newPage();
await page.goto(`http://127.0.0.1:${server.address().port}/`);
await installProtocolFixture(page);

const out = await page.evaluate(async () => {
  const { RocEngineRuntime, MAX_QUEUED } = await import("/runtime.mjs");
  const encoder = new TextEncoder();
  const join = (...parts) => { const o = new Uint8Array(parts.reduce((n, p) => n + p.length, 0)); let at = 0; for (const p of parts) { o.set(p, at); at += p.length; } return o; };
  const u32 = (n) => { const o = new Uint8Array(4); new DataView(o.buffer).setUint32(0, n, true); return o; };
  const str = (text) => { const b = encoder.encode(text); return join(u32(b.length), b); };
  const elem = (id, parent, tag) => join([8], u32(id), u32(parent), u32(0), [0], str(""), str(tag), [0]);
  const listen = (id, handler, type, kind, policies) => join([11], u32(id), u32(handler), str(type), [kind], u32(policies));
  // A runtime whose reports wait for a frame this fixture never supplies
  // within the scenario (not manualEffects: the production scheduler runs).
  const fixture = () => {
    const root = document.createElement("main"); document.body.append(root);
    const memory = new WebAssembly.Memory({ initial: 2 }); let length = 0;
    const exports = { memory, cmd_ptr: () => 0, cmd_len: () => length, keys_released: () => 0, files_released: () => 0, metric: () => 0n, work_len: () => 0, fault: () => 0, drop: () => {} };
    const frames = new Map(); let frameId = 0;
    const win = { requestAnimationFrame: (cb) => { frames.set(++frameId, cb); return frameId; }, cancelAnimationFrame: (id) => frames.delete(id) };
    const rt = new RocEngineRuntime(exports, root, { window: win, environment: { visible: () => true } });
    __bindProtocolFixture(rt);
    const raw = (...parts) => { const bytes = join([0], ...parts); new Uint8Array(memory.buffer).set(bytes); length = bytes.length; rt.busy = true; try { rt.apply(); } finally { rt.busy = false; length = 0; } rt.drainQueue(); };
    // One real button with a real click LISTEN (kind 10 = CLICK, no policy).
    // A second button for re-entrant clicks: HTMLElement.click() is a no-op
    // while the same element's click() is already in progress.
    raw(elem(1, 0, "button"), listen(1, 7, "click", 10, 0), elem(2, 0, "button"), listen(2, 8, "click", 10, 0));
    const button = rt.statics[1], other = rt.statics[2];
    const calls = [];
    let during = null;   // what the first delivered turn raises synchronously
    rt.deliver = (node, handler, payload) => {
      const act = during; during = null;
      calls.push(typeof payload === "string" ? payload : `bytes@${node}/${handler}`);
      if (act) act();
    };
    const add = (id) => rt.live.set(id, { cancel: () => {} });
    const state = () => ({ poisoned: rt.poisoned ? [rt.poisoned.class, rt.poisoned.message] : null, delivered: calls.length, first: calls[0] ?? null, queue: rt.queue.length, sources: rt.reportSources.size });
    return { rt, root, button, other, frame: () => { for (const cb of [...frames.values()]) cb(); }, calls, add, state, set during(fn) { during = fn; }, end: () => { rt.unmount(); root.remove(); } };
  };
  const fill = (f, count) => { for (let id = 100; id < 100 + count; id += 1) { f.add(id); f.rt.report(id, `r${id}`); } };
  const result = {};

  // A. 4096 distinct sources report in one task (as one observer callback
  //    does); the 4097th report's early drain delivers the oldest; that turn
  //    raises ONE real click on a listening button.
  { const f = fixture(); fill(f, MAX_QUEUED); const before = f.state();
    f.add(9000); f.during = () => f.button.click();
    f.rt.report(9000, "the 4097th report");
    result.A = { before, after: f.state() }; f.end(); }

  // B. Same queue; the input is an occurrence (a real user click).
  { const f = fixture(); fill(f, MAX_QUEUED);
    f.during = () => f.other.click();
    f.button.click();
    result.B = f.state(); f.end(); }

  // C. Control: 4095 waiting reports, the same occurrence and re-entrant click.
  { const f = fixture(); fill(f, MAX_QUEUED - 1);
    f.during = () => f.other.click();
    f.button.click();
    result.C = f.state(); f.end(); }

  // D. Control: full queue, 4097th report, no re-entrant event.
  { const f = fixture(); fill(f, MAX_QUEUED); f.add(9000);
    f.rt.report(9000, "the 4097th report");
    result.D = f.state(); f.end(); }

  // E. Full queue; the initiating turn raises a report from a NEW source
  //    (another element's observer, another subscription) instead of a click.
  { const f = fixture(); fill(f, MAX_QUEUED); f.add(9000); f.add(9001);
    f.during = () => f.rt.report(9001, "re-entrant report");
    f.rt.report(9000, "the 4097th report");
    result.E = f.state(); f.end(); }

  // F. Full queue; the initiating turn raises a report from a source that is
  //    already waiting (a replacement): no new entry is needed.
  { const f = fixture(); fill(f, MAX_QUEUED); f.add(9000);
    f.during = () => f.rt.report(200, "replacement");
    f.rt.report(9000, "the 4097th report");
    result.F = f.state(); f.end(); }

  // C2. Control: 4094 waiting reports, the same occurrence and re-entrant click.
  { const f = fixture(); fill(f, MAX_QUEUED - 2);
    f.during = () => f.other.click();
    f.button.click();
    result.C2 = f.state(); f.end(); }

  // G. No new input at all: exactly 4096 waiting reports, the frame arrives,
  //    and the first report's turn raises one click.
  { const f = fixture(); fill(f, MAX_QUEUED);
    f.during = () => f.other.click();
    f.frame();
    result.G = f.state(); f.end(); }

  // H. Control: 4096 waiting reports, the frame arrives, nothing re-entrant.
  { const f = fixture(); fill(f, MAX_QUEUED);
    f.frame();
    result.H = f.state(); f.end(); }

  // I. 4095 waiting reports, the frame arrives, one re-entrant click.
  { const f = fixture(); fill(f, MAX_QUEUED - 1);
    f.during = () => f.other.click();
    f.frame();
    result.I = f.state(); f.end(); }
  return result;
});
for (const [name, value] of Object.entries(out)) console.log(name, JSON.stringify(value));
await ctx.close(); await browser.close();
await new Promise((resolve) => server.close(resolve));
