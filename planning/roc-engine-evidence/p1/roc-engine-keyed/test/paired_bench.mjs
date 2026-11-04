#!/usr/bin/env node
// Paired Node + DOM-double timing of the current engine (platform-web, through
// the same BenchmarkSignalsRuntime that `scripts/test.py wasm-bench` uses) and
// the pure Roc engine (platform-roc). Each iteration instantiates a fresh
// module, runs the case's setup, then times one marked click. Engines
// alternate iteration by iteration (order flipped every iteration) so drift
// and thermal effects hit both equally.
//
// usage: node --expose-gc paired_bench.mjs --current A.wasm --new B.wasm
//          [--iterations N] [--warmups N] [--case pattern]... [--json out.json]
import { readFile, writeFile } from "node:fs/promises";
import process from "node:process";

import { instantiateSignalsBytes } from "../../../../www/static/signals.mjs";
import { BenchmarkSignalsRuntime } from "../../../../scripts/browser/wasm_benchmark_runtime.mjs";
import { instantiateEngineBytes, RocEngineRuntime } from "../../../../platform-roc/runtime.mjs";
import { findAll, findNode, fireEvent, installDomDouble } from "./dom_double_ext.mjs";

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

const clock = () => process.hrtime.bigint();
const byId = (root, id) => findNode(root, (node) => node.getAttribute?.("id") === id);
const gc = globalThis.gc ?? (() => {});

// ---- current engine adapter ------------------------------------------------
const current = {
  name: "current",
  async start(bytes) {
    const root = installDomDouble();
    const { instance } = await instantiateSignalsBytes(bytes);
    const crypto = { getRandomValues(values) { values[0] = 0x12345678; return values; } };
    const runtime = new BenchmarkSignalsRuntime(instance.exports, root, { crypto, onError: (e) => { throw e; } });
    runtime.mount();
    return { root, runtime, instance };
  },
  node(ctx, action) {
    const attr = (name, value) => findNode(ctx.root, (node) => node.getAttribute?.(name) === value);
    if (action.startsWith("select:")) return attr("aria-label", `Select row ${action.slice(7)}`);
    if (action.startsWith("remove:")) return attr("aria-label", `Remove row ${action.slice(7)}`);
    return attr("id", action);
  },
  rows(ctx) {
    return findAll(ctx.root, (node) => node.tagName === "TR").length;
  },
  measure(ctx, target) {
    ctx.runtime.benchmarkRecorder.begin();
    ctx.runtime.benchmarkRecorder.measureEvent(() => fireEvent(target, "click", { bubbles: true }));
    const m = ctx.runtime.benchmarkRecorder.finish();
    return {
      total_ns: Number(m.event_total_ns),
      wasm_ns: Number(m.wasm_event_ns),
      apply_ns: Number(m.command_execute_ns + m.command_read_ns + m.command_snapshot_ns + m.command_acknowledge_ns),
      bytes: Number(m.fixed_record_bytes + m.fixed_string_bytes + m.dynamic_bytes),
      commands: m.command_count,
    };
  },
  pages(ctx) {
    return ctx.instance.exports.memory.buffer.byteLength / 65536;
  },
  stop(ctx) {
    ctx.runtime.unmount();
  },
};

// ---- pure Roc engine adapter -----------------------------------------------
const fresh = {
  name: "new",
  async start(bytes) {
    const root = installDomDouble();
    const { instance } = await instantiateEngineBytes(bytes);
    const timing = {
      clock,
      last: null,
      record(wasm, apply, bytes) { this.last = { wasm_ns: Number(wasm), apply_ns: Number(apply), bytes }; },
    };
    const runtime = new RocEngineRuntime(instance.exports, root, { timing });
    runtime.mount();
    return { root, runtime, instance, timing };
  },
  node(ctx, action) {
    if (action.startsWith("select:") || action.startsWith("remove:")) {
      const id = action.slice(7);
      const tbody = byId(ctx.root, "tbody");
      const tr = tbody.childNodes.find((row) => row.childNodes[0].textContent === id);
      return tr?.childNodes[action.startsWith("select:") ? 1 : 2].childNodes[0];
    }
    return byId(ctx.root, action);
  },
  rows(ctx) {
    return byId(ctx.root, "tbody").childNodes.length;
  },
  measure(ctx, target) {
    ctx.timing.last = null;
    const t0 = clock();
    fireEvent(target, "click", { bubbles: true });
    const total = Number(clock() - t0);
    const last = ctx.timing.last;
    if (last === null) throw new Error("click did not reach the engine");
    return { total_ns: total, wasm_ns: last.wasm_ns, apply_ns: last.apply_ns, bytes: last.bytes, commands: 0 };
  },
  pages(ctx) {
    return ctx.instance.exports.memory.buffer.byteLength / 65536;
  },
  stop(ctx) {
    ctx.runtime.unmount();
  },
};

function parseArgs(argv) {
  const o = { iterations: 15, warmups: 2, cases: [], json: null };
  for (let i = 0; i < argv.length; i += 1) {
    const v = argv[++i];
    switch (argv[i - 1]) {
      case "--current": o.current = v; break;
      case "--new": o.fresh = v; break;
      case "--iterations": o.iterations = Number(v); break;
      case "--warmups": o.warmups = Number(v); break;
      case "--case": o.cases.push(v); break;
      case "--json": o.json = v; break;
      default: throw new Error(`unknown option ${argv[i - 1]}`);
    }
  }
  return o;
}

async function runOnce(engine, bytes, scenario) {
  const ctx = await engine.start(bytes);
  for (const action of scenario.setup) {
    const node = engine.node(ctx, action);
    if (!node) throw new Error(`${engine.name}: setup ${action} has no node`);
    fireEvent(node, "click", { bubbles: true });
  }
  const target = engine.node(ctx, scenario.marked);
  if (!target) throw new Error(`${engine.name}: ${scenario.marked} has no node`);
  gc();
  const result = engine.measure(ctx, target);
  const rows = engine.rows(ctx);
  if (rows !== scenario.rows) throw new Error(`${engine.name} ${scenario.id}: ${rows} rows, expected ${scenario.rows}`);
  result.pages = engine.pages(ctx);
  engine.stop(ctx);
  gc();
  return result;
}

async function pagesSession(engine, bytes) {
  const ctx = await engine.start(bytes);
  const click = (a) => fireEvent(engine.node(ctx, a), "click", { bubbles: true });
  const mount = engine.pages(ctx);
  click("runlots");
  const afterCreate = engine.pages(ctx);
  click("clear");
  const afterClear = engine.pages(ctx);
  for (let i = 0; i < 5; i += 1) { click("runlots"); click("clear"); }
  const afterSix = engine.pages(ctx);
  engine.stop(ctx);
  return { mount, after_create_10k: afterCreate, after_clear: afterClear, after_6_cycles: afterSix };
}

function stats(values) {
  const s = [...values].sort((a, b) => a - b);
  const mid = s.length >> 1;
  const median = s.length % 2 ? s[mid] : (s[mid - 1] + s[mid]) / 2;
  return { median, min: s[0], max: s[s.length - 1], n: s.length };
}

const matches = (pattern, id) => new RegExp(`^${pattern.replaceAll("*", ".*")}$`).test(id);

async function main() {
  const o = parseArgs(process.argv.slice(2));
  const bytes = { current: await readFile(o.current), new: await readFile(o.fresh) };
  const engines = [current, fresh];
  const selected = CASES.filter((c) => o.cases.length === 0 || o.cases.some((p) => matches(p, c.id)));
  const out = { cases: {}, pages: {} };
  for (const scenario of selected) {
    for (let w = 0; w < o.warmups; w += 1) for (const e of engines) await runOnce(e, bytes[e.name], scenario);
    const samples = { current: [], new: [] };
    for (let i = 0; i < o.iterations; i += 1) {
      const order = i % 2 === 0 ? engines : [...engines].reverse();
      for (const e of order) samples[e.name].push(await runOnce(e, bytes[e.name], scenario));
    }
    const summary = {};
    for (const name of ["current", "new"]) {
      summary[name] = {};
      for (const field of ["total_ns", "wasm_ns", "apply_ns"]) summary[name][field] = stats(samples[name].map((r) => r[field] / 1e6));
      summary[name].bytes = samples[name][0].bytes;
      summary[name].pages = samples[name][0].pages;
    }
    summary.ratio_median_total = summary.new.total_ns.median / summary.current.total_ns.median;
    out.cases[scenario.id] = { summary, samples };
    const f = (s) => `${s.median.toFixed(3)} [${s.min.toFixed(3)}-${s.max.toFixed(3)}]`;
    console.log(`${scenario.id.padEnd(17)} current ${f(summary.current.total_ns)} ms (wasm ${summary.current.wasm_ns.median.toFixed(3)}, js ${summary.current.apply_ns.median.toFixed(3)}) | new ${f(summary.new.total_ns)} ms (wasm ${summary.new.wasm_ns.median.toFixed(3)}, js ${summary.new.apply_ns.median.toFixed(3)}) | ratio ${(summary.ratio_median_total * 100).toFixed(1)}% n=${o.iterations}`);
  }
  for (const e of engines) out.pages[e.name] = await pagesSession(e, bytes[e.name]);
  console.log("wasm pages", JSON.stringify(out.pages));
  if (o.json) await writeFile(o.json, JSON.stringify(out, null, 1));
}

main().catch((error) => {
  for (let e = error; e; e = e.cause) console.error(e?.stack ?? e);
  process.exitCode = 1;
});
