#!/usr/bin/env node
// One Wasm instance and one mounted SignalsRuntime across a repeated event
// sequence. wasm-bench builds a fresh instance per iteration, so it cannot see
// growth that accumulates across events.
//
// usage: node one_instance.mjs <tree> <artifact.wasm> <sequence> <warmup> <cycles> <checkpoints,comma>
// Imports the harness from <tree>, so each tree is measured with its own runtime.
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { pathToFileURL } from "node:url";

const [tree, wasmPath, sequence, warmupText, cyclesText, checkpointText] = process.argv.slice(2);
const load = (relative) => import(pathToFileURL(`${tree}/${relative}`).href);
const { instantiateSignalsBytes } = await load("www/static/signals.mjs");
const { findAll, findNode, fireEvent, installDomDouble } = await load("scripts/browser/dom_double.mjs");
const { readBenchmarkMetrics } = await load("scripts/browser/wasm_benchmark_metrics.mjs");
const { BenchmarkSignalsRuntime } = await load("scripts/browser/wasm_benchmark_runtime.mjs");

const warmup = Number(warmupText);
const cycles = Number(cyclesText);
const checkpoints = new Set(checkpointText.split(",").map(Number));

const root = installDomDouble();
const { instance } = await instantiateSignalsBytes(await readFile(wasmPath));
// The same fixed entropy the paired benchmark uses, so both trees do identical work.
const crypto = { getRandomValues(values) { values[0] = 0x12345678; return values; } };
const runtime = new BenchmarkSignalsRuntime(instance.exports, root, { crypto, onError: (error) => { throw error; } });
runtime.mount();

const diagnostic = instance.exports.roc_ui_debug_live_allocation_count() !== 0;
const rows = () => findAll(root, (node) => typeof node.getAttribute === "function" && node.getAttribute("data-row-id") !== null);
const click = (id) => {
  const node = findNode(root, (entry) => entry.getAttribute?.("id") === id);
  assert.ok(node, `missing action ${id}`);
  fireEvent(node, "click", { bubbles: true });
};
const selectFirst = () => {
  const node = findNode(root, (entry) => entry.getAttribute?.("aria-label")?.startsWith("Select row "));
  assert.ok(node, "missing select action");
  fireEvent(node, "click", { bubbles: true });
};

const SEQUENCES = {
  // Replaces every row, so row count and label length stay bounded.
  "bounded-1k": {
    setup() {},
    cycle() {
      click("run");
      assert.equal(rows().length, 1000);
      click("update");
      selectFirst();
      click("swaprows");
      click("clear");
      assert.equal(rows().length, 0);
    },
  },
  // The plan's update_10k. Each event appends " !!!" to every tenth label, so
  // application state grows by design and these pages cannot be flat.
  "update-10k": {
    setup() { click("runlots"); },
    cycle() {
      click("update");
      assert.equal(rows().length, 10000);
    },
  },
};
const chosen = SEQUENCES[sequence];
assert.ok(chosen, `unknown sequence ${sequence}`);

function checkpoint(label, cycle) {
  const row = {
    label,
    cycle,
    wasm_pages: instance.exports.memory.buffer.byteLength / 65536,
    host_values: instance.exports.roc_ui_live_host_values(),
    live_nodes: runtime.nodes.size,
  };
  if (diagnostic) {
    const metrics = readBenchmarkMetrics(instance.exports);
    for (const name of ["host_live_bytes", "host_live_count", "host_peak_live_bytes", "roc_live_bytes", "roc_live_count", "command_buffer_capacity_bytes"]) {
      row[name] = String(metrics[name]);
    }
  }
  console.log(JSON.stringify(row));
}

const started = Date.now();
chosen.setup();
for (let index = 0; index < warmup; index += 1) chosen.cycle();
checkpoint("start", 0);
for (let cycle = 1; cycle <= cycles; cycle += 1) {
  chosen.cycle();
  if (checkpoints.has(cycle)) checkpoint("after", cycle);
}
console.error(`${sequence} ${diagnostic ? "diagnostic" : "production"}: ${cycles} cycles in ${((Date.now() - started) / 1000).toFixed(1)}s`);
runtime.unmount();
assert.equal(instance.exports.roc_ui_live_host_values(), 0);
