// Paired in-browser timing (real Chrome DOM) of the current engine and the
// pure Roc engine. Each iteration mounts a fresh instance into a fresh root,
// runs the case's setup clicks, then times one marked click:
//   script_ms = synchronous click handling (Wasm + JS command application + DOM mutation)
//   layout_ms = script_ms plus a forced style/layout read afterwards
// Engines alternate per iteration. Results are POSTed to /result.
import { instantiateSignalsBytes, SignalsRuntime } from "../../../../www/static/signals.mjs";
import { instantiateEngineBytes, RocEngineRuntime } from "../../../../platform-roc/runtime.mjs";

const params = new URLSearchParams(location.search);
const ITER = Number(params.get("iterations") ?? 10);
const WARM = Number(params.get("warmups") ?? 2);
const ONLY = params.get("cases")?.split(",") ?? null;

const CASES = [
  { id: "create_1k", setup: [], marked: "run", rows: 1000 },
  { id: "replace_1k", setup: ["run"], marked: "run", rows: 1000 },
  { id: "update_10k", setup: ["runlots"], marked: "update", rows: 10000 },
  { id: "select_1k", setup: ["run", "select:2"], marked: "select:3", rows: 1000 },
  { id: "swap_1k", setup: ["run"], marked: "swaprows", rows: 1000 },
  { id: "remove_1k", setup: ["run"], marked: "remove:2", rows: 999 },
  { id: "create_10k", setup: [], marked: "runlots", rows: 10000 },
  { id: "append_1k_to_10k", setup: ["runlots"], marked: "add", rows: 11000 },
  { id: "clear_10k", setup: ["runlots"], marked: "clear", rows: 0 },
];

const log = (s) => { document.getElementById("log").textContent += `${s}\n`; };
const now = () => performance.now();

function freshRoot() {
  const root = document.createElement("div");
  document.body.appendChild(root);
  return root;
}

const current = {
  name: "current",
  async start(bytes) {
    const root = freshRoot();
    const { instance } = await instantiateSignalsBytes(bytes);
    const ex = instance.exports;
    const timing = { wasm: 0 };
    const event = ex.roc_ui_event;
    const exports = { ...ex, roc_ui_event: (...a) => { const t = now(); try { return event(...a); } finally { timing.wasm += now() - t; } } };
    const crypto = { getRandomValues(values) { values[0] = 0x12345678; return values; } };
    const runtime = new SignalsRuntime(exports, root, { crypto, onError: (e) => { throw e; } });
    runtime.mount();
    return { root, runtime, instance, timing };
  },
  node(ctx, action) {
    if (action.startsWith("select:")) return ctx.root.querySelector(`[aria-label="Select row ${action.slice(7)}"]`);
    if (action.startsWith("remove:")) return ctx.root.querySelector(`[aria-label="Remove row ${action.slice(7)}"]`);
    return ctx.root.querySelector(`#${action}`);
  },
  stop(ctx) { ctx.runtime.unmount(); ctx.root.remove(); },
};

const fresh = {
  name: "new",
  async start(bytes) {
    const root = freshRoot();
    const { instance } = await instantiateEngineBytes(bytes);
    const timing = { wasm: 0, clock: now, record(w) { this.wasm += w; } };
    const runtime = new RocEngineRuntime(instance.exports, root, { timing });
    runtime.mount();
    return { root, runtime, instance, timing };
  },
  node(ctx, action) {
    if (action.startsWith("select:") || action.startsWith("remove:")) {
      const id = action.slice(7);
      for (const tr of ctx.root.querySelector("#tbody").children) {
        if (tr.firstChild.textContent === id) return tr.children[action.startsWith("select:") ? 1 : 2].firstChild;
      }
      return null;
    }
    return ctx.root.querySelector(`#${action}`);
  },
  stop(ctx) { ctx.runtime.unmount(); ctx.root.remove(); },
};

const pause = () => new Promise((resolve) => setTimeout(resolve, 0));

async function once(engine, bytes, scenario) {
  const ctx = await engine.start(bytes);
  for (const action of scenario.setup) engine.node(ctx, action).click();
  const target = engine.node(ctx, scenario.marked);
  if (!target) throw new Error(`${engine.name}: no node for ${scenario.marked}`);
  await pause();
  ctx.timing.wasm = 0;
  const t0 = now();
  target.click();
  const t1 = now();
  void ctx.root.offsetHeight;
  const t2 = now();
  let decode_ms = 0;
  if (engine.name === "new") {
    const t3 = now();
    ctx.runtime.scan();
    decode_ms = now() - t3;
  }
  const rows = ctx.root.querySelector("#tbody").children.length;
  if (rows !== scenario.rows) throw new Error(`${engine.name} ${scenario.id}: ${rows} rows`);
  const pages = ctx.instance.exports.memory.buffer.byteLength / 65536;
  engine.stop(ctx);
  return { script_ms: t1 - t0, layout_ms: t2 - t0, wasm_ms: ctx.timing.wasm, decode_ms, pages };
}

async function main() {
  const bytes = {
    current: await (await fetch("/wasm/current.wasm")).arrayBuffer(),
    new: await (await fetch("/wasm/new.wasm")).arrayBuffer(),
  };
  const engines = [current, fresh];
  const out = { userAgent: navigator.userAgent, iterations: ITER, warmups: WARM, cases: {} };
  for (const scenario of CASES.filter((c) => ONLY === null || ONLY.includes(c.id))) {
    for (let w = 0; w < WARM; w += 1) for (const e of engines) await once(e, bytes[e.name], scenario);
    const samples = { current: [], new: [] };
    for (let i = 0; i < ITER; i += 1) {
      for (const e of i % 2 === 0 ? engines : [...engines].reverse()) samples[e.name].push(await once(e, bytes[e.name], scenario));
    }
    out.cases[scenario.id] = samples;
    log(`${scenario.id} done`);
  }
  await fetch("/result", { method: "POST", body: JSON.stringify(out) });
  log("posted");
}

main().catch(async (error) => {
  log(String(error?.stack ?? error));
  await fetch("/result", { method: "POST", body: JSON.stringify({ error: String(error?.stack ?? error) }) });
});
