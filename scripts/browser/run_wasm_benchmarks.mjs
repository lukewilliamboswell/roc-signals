#!/usr/bin/env node

import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import os from "node:os";
import process from "node:process";

import { instantiateSignalsBytes } from "../../www/static/signals.mjs";
import { findAll, findNode, fireEvent, installDomDouble } from "./dom_double.mjs";
import { readBenchmarkMetrics, resetBenchmarkMetrics } from "./wasm_benchmark_metrics.mjs";
import { BenchmarkSignalsRuntime } from "./wasm_benchmark_runtime.mjs";

const CASES = [
  { id: "create_1k", marked: "run", validate: (root) => rows(root).length === 1000 && present(root, "row-1000") },
  { id: "replace_1k", setup: ["run"], marked: "run", validate: (root) => rows(root).length === 1000 && absent(root, "row-1") && present(root, "row-2000") },
  { id: "update_10k", setup: ["runlots"], marked: "update", validate: (root) => rows(root).length === 10000 && row(root, "1")?.textContent.includes("!!!") === true && row(root, "11")?.textContent.includes("!!!") === true },
  { id: "select_1k", setup: ["run", "select:2"], marked: "select:3", validate: (root) => row(root, "2")?.className === "" && row(root, "3")?.className === "danger" },
  { id: "swap_1k", setup: ["run"], marked: "swaprows", validate: (root) => rows(root).length === 1000 && rows(root)[1]?.getAttribute("data-row-id") === "999" && rows(root)[998]?.getAttribute("data-row-id") === "2" },
  { id: "remove_1k", setup: ["run"], marked: "remove:2", validate: (root) => rows(root).length === 999 && absent(root, "row-2") },
  { id: "create_10k", marked: "runlots", validate: (root) => rows(root).length === 10000 && present(root, "row-10000") },
  { id: "append_1k_to_10k", setup: ["runlots"], marked: "add", validate: (root) => rows(root).length === 11000 && present(root, "row-11000") },
  { id: "clear_10k", setup: ["runlots"], marked: "clear", validate: (root) => rows(root).length === 0 && absent(root, "row-1") },
];

export const DEFAULT_METADATA = {
  roc_compiler: "",
  wasm_host_optimization: "",
  roc_app_optimization: "",
  fixture: "",
  fixture_sha256: "",
  production_host_sha256: "",
  diagnostic_host_sha256: "",
};

function nodeByAttr(root, name, value) {
  return findNode(root, (node) => node.getAttribute?.(name) === value);
}

function row(root, id) {
  return nodeByAttr(root, "data-testid", `row-${id}`);
}

function rows(root) {
  return findAll(root, (node) => typeof node.getAttribute === "function" && node.getAttribute("data-row-id") !== null);
}

function present(root, testId) {
  return nodeByAttr(root, "data-testid", testId) !== null;
}

function absent(root, testId) {
  return !present(root, testId);
}

function actionNode(root, action) {
  if (action.startsWith("select:")) return nodeByAttr(root, "aria-label", `Select row ${action.slice(7)}`);
  if (action.startsWith("remove:")) return nodeByAttr(root, "aria-label", `Remove row ${action.slice(7)}`);
  return nodeByAttr(root, "id", action);
}

function runAction(root, action) {
  const node = actionNode(root, action);
  if (!node) throw new Error(`benchmark action ${action} has no matching DOM node`);
  fireEvent(node, "click", { bubbles: true });
}

function runtimeSignature(root, runtime) {
  const rowNodes = rows(root);
  const { wasm_pages: _allocatorDependentPages, ...semanticRuntimeState } = runtime.benchmarkRuntimeState();
  return JSON.stringify({
    rowCount: rowNodes.length,
    first: rowNodes[0]?.getAttribute("data-row-id") ?? "",
    second: rowNodes[1]?.getAttribute("data-row-id") ?? "",
    penultimate: rowNodes.at(-2)?.getAttribute("data-row-id") ?? "",
    last: rowNodes.at(-1)?.getAttribute("data-row-id") ?? "",
    selected: rowNodes.find((entry) => entry.className === "danger")?.getAttribute("data-row-id") ?? "",
    row1: row(root, "1")?.textContent ?? "",
    ...semanticRuntimeState,
  });
}

async function runIteration(bytes, scenario, diagnostic) {
  const root = installDomDouble();
  const { instance } = await instantiateSignalsBytes(bytes);
  // Production and diagnostic instances must receive the same entropy so the
  // paired benchmark compares identical application work. Each fresh instance
  // deliberately starts from the same seed.
  const crypto = { getRandomValues(values) { values[0] = 0x12345678; return values; } };
  const runtime = new BenchmarkSignalsRuntime(instance.exports, root, {
    crypto,
    onError: (error) => { throw error; },
  });
  runtime.mount();
  for (const action of scenario.setup ?? []) runAction(root, action);
  if (diagnostic) resetBenchmarkMetrics(instance.exports);
  runtime.benchmarkRecorder.begin();
  runtime.benchmarkRecorder.measureEvent(() => runAction(root, scenario.marked));
  const measured = runtime.benchmarkRecorder.finish();
  if (!scenario.validate(root)) throw new Error(`benchmark case ${scenario.id} failed its final behavior assertion`);
  const state = runtime.benchmarkRuntimeState();
  const signature = runtimeSignature(root, runtime);
  const diagnostics = diagnostic ? readBenchmarkMetrics(instance.exports) : null;
  if (diagnostics !== null && diagnostics.runtime_events_processed !== 1n) {
    throw new Error(`benchmark case ${scenario.id} included setup in marked engine metrics: events=${diagnostics.runtime_events_processed}`);
  }
  const protocolVersion = instance.exports.roc_ui_protocol_version();
  const protocolFeatures = instance.exports.roc_ui_protocol_features();
  const metricsSchema = diagnostic ? instance.exports.roc_ui_benchmark_metrics_schema_version() : null;
  runtime.unmount();
  return { measured, diagnostics, signature, state, protocolVersion, protocolFeatures, metricsSchema };
}

function parityFacts(result) {
  const { measured } = result;
  return JSON.stringify({
    signature: result.signature,
    command_count: measured.command_count,
    fixed_record_bytes: measured.fixed_record_bytes,
    fixed_string_bytes: measured.fixed_string_bytes,
    dynamic_bytes: measured.dynamic_bytes,
    opcode_counts: measured.opcode_counts,
    decode: measured.decode,
  });
}

function addInto(target, source) {
  for (const [name, value] of Object.entries(source)) {
    if (typeof value === "bigint") target[name] = (target[name] ?? 0n) + value;
    else if (typeof value === "number") target[name] = (target[name] ?? 0) + value;
  }
}

function addDiagnostics(target, source) {
  for (const [name, value] of Object.entries(source)) {
    const isPeak = name.includes("peak_live_");
    const isStableGauge = /_(?:live_count|live_bytes|live_count_before|live_bytes_before)$/.test(name) || name.startsWith("wasm_pages_");
    if (isPeak) {
      target[name] = target[name] === undefined ? value : (value > target[name] ? value : target[name]);
    } else if (isStableGauge) {
      if (target[name] !== undefined && target[name] !== value) {
        throw new Error(`fresh diagnostic iterations disagree on ${name}: ${target[name]} vs ${value}`);
      }
      target[name] = value;
    } else {
      target[name] = (target[name] ?? 0n) + value;
    }
  }
}

function setStable(target, values) {
  for (const [name, value] of Object.entries(values)) {
    if (target[name] !== undefined && target[name] !== value) {
      throw new Error(`fresh benchmark iterations disagree on ${name}: ${target[name]} vs ${value}`);
    }
    target[name] = value;
  }
}

function parseArgs(argv) {
  const options = { cases: [], warmups: 1, iterations: 20, samples: 7, metadata: { ...DEFAULT_METADATA } };
  for (let index = 0; index < argv.length; index += 1) {
    const name = argv[index];
    if (name === "--production-only") {
      options.productionOnly = true;
      continue;
    }
    const value = argv[++index];
    if (name === "--production") options.production = value;
    else if (name === "--diagnostic") options.diagnostic = value;
    else if (name === "--case") options.cases.push(value);
    else if (name === "--warmups") options.warmups = Number(value);
    else if (name === "--iterations") options.iterations = Number(value);
    else if (name === "--samples") options.samples = Number(value);
    else if (name === "--metadata") options.metadata = { ...DEFAULT_METADATA, ...JSON.parse(value) };
    else throw new Error(`unknown benchmark option ${name}`);
  }
  if (!options.production || (!options.productionOnly && !options.diagnostic)) {
    throw new Error("--production and --diagnostic are required unless --production-only is selected");
  }
  for (const [name, value] of [["warmups", options.warmups], ["iterations", options.iterations], ["samples", options.samples]]) {
    if (!Number.isSafeInteger(value) || value < (name === "warmups" ? 0 : 1)) throw new Error(`--${name} must be a valid positive integer`);
  }
  return options;
}

function matches(pattern, value) {
  const expression = `^${pattern.replace(/[.+?^${}()|[\]\\]/g, "\\$&").replaceAll("*", ".*")}$`;
  return new RegExp(expression).test(value);
}

function csvValue(value) {
  const text = typeof value === "bigint" ? value.toString() : String(value ?? "");
  return /[",\n]/.test(text) ? `"${text.replaceAll('"', '""')}"` : text;
}

function digest(bytes) {
  return createHash("sha256").update(bytes).digest("hex");
}

async function main() {
  const options = parseArgs(process.argv.slice(2));
  const productionBytes = await readFile(options.production);
  const diagnosticBytes = options.productionOnly ? null : await readFile(options.diagnostic);
  const selected = CASES.filter((entry) => options.cases.length === 0 || options.cases.some((pattern) => matches(pattern, entry.id)));
  if (selected.length === 0) throw new Error("no Wasm benchmark cases matched --case filters");

  for (let pass = 0; pass < options.warmups; pass += 1) {
    for (const scenario of selected) await runIteration(productionBytes, scenario, false);
  }

  const rows = [];
  for (const scenario of selected) {
    for (let sample = 1; sample <= options.samples; sample += 1) {
      const row = { case: scenario.id, sample, samples: options.samples, warmup_passes: options.warmups, iterations: options.iterations, actions: options.iterations };
      for (let iteration = 0; iteration < options.iterations; iteration += 1) {
        let production;
        let diagnostic;
        try {
          production = await runIteration(productionBytes, scenario, false);
          diagnostic = diagnosticBytes === null ? null : await runIteration(diagnosticBytes, scenario, true);
        } catch (error) {
          throw new Error(`benchmark ${scenario.id} sample ${sample} iteration ${iteration + 1} failed`, { cause: error });
        }
        if (diagnostic !== null && parityFacts(production) !== parityFacts(diagnostic)) {
          throw new Error(
            `production/instrumented parity failed for ${scenario.id} iteration ${iteration + 1}: ` +
            `production=${parityFacts(production)} diagnostic=${parityFacts(diagnostic)}`,
          );
        }
        addInto(row, production.measured);
        addInto(row, Object.fromEntries(Object.entries(production.measured.decode).map(([name, value]) => [`decode_${name}`, value])));
        addInto(row, Object.fromEntries(Object.entries(production.measured.opcode_counts).map(([name, value]) => [`opcode_${name}`, value])));
        if (diagnostic !== null) addDiagnostics(row, diagnostic.diagnostics);
        setStable(row, {
          live_runtime_nodes: production.state.live_nodes,
          live_runtime_listeners: production.state.listeners,
          live_runtime_behaviors: production.state.behaviors,
          live_runtime_tasks: production.state.tasks,
          live_runtime_intervals: production.state.intervals,
          live_runtime_host_values: production.state.host_values,
          live_runtime_wasm_pages: production.state.wasm_pages,
          protocol_version: production.protocolVersion,
          protocol_features: production.protocolFeatures,
          benchmark_metrics_schema_version: diagnostic?.metricsSchema ?? "",
        });
      }
      const cpu = os.cpus()[0]?.model ?? "unknown";
      Object.assign(row, {
        total_wire_bytes: row.fixed_record_bytes + row.fixed_string_bytes + row.dynamic_bytes,
        measurement_design: diagnosticBytes === null ? "production_profile" : "production_timing+instrumented_diagnostics",
        node_version: process.version,
        v8_version: process.versions.v8,
        os: `${os.platform()} ${os.release()}`,
        architecture: os.arch(),
        cpu,
        production_wasm_sha256: digest(productionBytes),
        diagnostic_wasm_sha256: diagnosticBytes === null ? "" : digest(diagnosticBytes),
        ...options.metadata,
      });
      rows.push(row);
    }
  }
  const headers = [...new Set(rows.flatMap((row) => Object.keys(row)))];
  process.stdout.write(`${headers.join(",")}\n`);
  for (const row of rows) process.stdout.write(`${headers.map((name) => csvValue(row[name])).join(",")}\n`);
}

if (import.meta.url === `file://${process.argv[1]}`) {
  main().catch((error) => {
    for (let current = error; current !== undefined; current = current?.cause) {
      console.error(current?.stack ?? current);
    }
    process.exitCode = 1;
  });
}

export { CASES, parityFacts, runIteration };
