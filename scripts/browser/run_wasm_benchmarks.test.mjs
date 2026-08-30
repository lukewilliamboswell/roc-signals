import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

import { CASES, DEFAULT_METADATA, parityFacts } from "./run_wasm_benchmarks.mjs";
import { RUNTIME_METRIC_FIELDS } from "./wasm_benchmark_metrics.mjs";
import { OPCODE_NAMES } from "./wasm_benchmark_runtime.mjs";

function captureBlock(source, start, end) {
  const from = source.indexOf(start);
  const to = source.indexOf(end, from + start.length);
  assert.notEqual(from, -1, `authoritative source is missing ${start}`);
  assert.notEqual(to, -1, `authoritative source is missing ${end}`);
  return source.slice(from + start.length, to);
}

test("Wasm benchmark corpus covers every required js-framework operation", () => {
  assert.deepEqual(CASES.map((entry) => entry.id), [
    "create_1k", "replace_1k", "update_10k", "select_1k", "swap_1k",
    "remove_1k", "create_10k", "append_1k_to_10k", "clear_10k",
  ]);
});

test("production/diagnostic parity includes behavior wire opcodes and decode work", () => {
  const result = {
    signature: "final-state",
    measured: {
      command_count: 1,
      fixed_record_bytes: 24,
      fixed_string_bytes: 3,
      dynamic_bytes: 0,
      opcode_counts: { set_text: 1 },
      decode: { fixedStringDecodes: 1, fixedStringBytes: 3 },
    },
  };
  assert.equal(parityFacts(result), parityFacts(structuredClone(result)));
  const changed = structuredClone(result);
  changed.measured.fixed_string_bytes = 4;
  assert.notEqual(parityFacts(result), parityFacts(changed));
});

test("opcode columns are a stable complete protocol registry", () => {
  assert.equal(OPCODE_NAMES.length, 32);
  assert.equal(new Set(OPCODE_NAMES).size, OPCODE_NAMES.length);
  assert.deepEqual(OPCODE_NAMES.slice(0, 4), ["reset_dom", "create_element", "create_text", "append_child"]);
  assert.equal(OPCODE_NAMES.at(-1), "set_document_title");
});

test("comparison metadata columns stay present even in direct investigative runs", () => {
  assert.deepEqual(Object.keys(DEFAULT_METADATA), [
    "roc_compiler", "wasm_host_optimization", "roc_app_optimization", "fixture",
    "fixture_sha256", "production_host_sha256", "diagnostic_host_sha256",
  ]);
});

test("JavaScript opcode registry exactly follows the authoritative Zig wire enum", async () => {
  const source = await readFile("src/signals/render_commands.zig", "utf8");
  const block = captureBlock(source, "pub const Op = enum(u32) {", "};");
  const authoritative = [...block.matchAll(/^\s*([a-z][a-z0-9_]*)\s*=\s*\d+,/gm)].map((match) => match[1]);
  assert.deepEqual(OPCODE_NAMES, authoritative);
});

test("JavaScript metrics schema exactly follows authoritative shared RuntimeMetrics order", async () => {
  const source = await readFile("src/signals/engine_metrics.zig", "utf8");
  const block = captureBlock(source, "pub const RuntimeMetrics = struct {", "    pub const Field =");
  const authoritative = [...block.matchAll(/^\s*([a-z][a-z0-9_]*):\s*[ui]64,/gm)].map((match) => match[1]);
  assert.deepEqual(RUNTIME_METRIC_FIELDS, authoritative);
});

test("Node scenarios exactly cover the authoritative benchmark manifest operations", async () => {
  const source = await readFile("examples/_fixtures/js-framework-benchmark/benchmarks.toml", "utf8");
  const operationBlock = source.split("[[memory_scenarios]]", 1)[0];
  const authoritative = [...operationBlock.matchAll(/^id\s*=\s*"([^"]+)"/gm)].map((match) => match[1]);
  assert.deepEqual(CASES.map((entry) => entry.id), authoritative);
});

test("Node setup and marked actions exactly follow each authoritative semantic spec", async () => {
  const actionForLabel = (label) => {
    const fixed = new Map([
      ["Create 1,000 rows", "run"], ["Create 10,000 rows", "runlots"],
      ["Append 1,000 rows", "add"], ["Update every 10th row", "update"],
      ["Clear", "clear"], ["Swap Rows", "swaprows"],
    ]);
    if (fixed.has(label)) return fixed.get(label);
    if (label.startsWith("Select row ")) return `select:${label.slice(11)}`;
    if (label.startsWith("Remove row ")) return `remove:${label.slice(11)}`;
    throw new Error(`semantic spec introduced unknown benchmark action ${label}`);
  };
  for (const scenario of CASES) {
    const source = await readFile(`examples/_fixtures/js-framework-benchmark/specs/${scenario.id}.scm`, "utf8");
    const labels = [...source.matchAll(/\(click \(role (?:button|link) :name "([^"]+)"\)\)/g)].map((match) => match[1]);
    const actions = labels.map(actionForLabel);
    assert.deepEqual(actions, [...(scenario.setup ?? []), scenario.marked], scenario.id);
  }
});
