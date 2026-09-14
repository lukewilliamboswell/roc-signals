#!/usr/bin/env node
// Allocation traffic, unlike allocation call counts, catches directory-wide COW.
// Every measured action retains an independently readable previous generation.
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { instantiateSignalsBytes } from '../../www/static/signals.mjs';
import { findNode, fireEvent, installDomDouble } from './dom_double.mjs';
import { BenchmarkSignalsRuntime } from './wasm_benchmark_runtime.mjs';
import { readBenchmarkMetrics, resetBenchmarkMetrics } from './wasm_benchmark_metrics.mjs';

const [productionPath, diagnosticPath, ...options] = process.argv.slice(2);
if (!productionPath || !diagnosticPath) throw new Error('usage: run_rows_scaling.mjs production.wasm diagnostic.wasm [--samples N] [--no-check]');
let samples = 3;
let check = true;
let directoryOnly = false;
let bulkOnly = false;
let actionFilter = null;
for (let i = 0; i < options.length; i += 1) {
  if (options[i] === '--samples') samples = Number(options[++i]);
  else if (options[i] === '--no-check') check = false;
  else if (options[i] === '--directory-only') directoryOnly = true;
  else if (options[i] === '--bulk-only') bulkOnly = true;
  else if (options[i] === '--action') actionFilter = options[++i];
  else throw new Error(`unknown option ${options[i]}`);
}
if (actionFilter && check) throw new Error('--action attribution runs require --no-check');
assert(Number.isSafeInteger(samples) && samples > 0);
const files = { production: await readFile(productionPath), diagnostic: await readFile(diagnosticPath) };
const hashes = Object.fromEntries(Object.entries(files).map(([kind, bytes]) => [kind, createHash('sha256').update(bytes).digest('hex')]));
const find = (root, attr, value) => findNode(root, node => node.getAttribute?.(attr) === value);
const scenarios = [];
for (const size of (bulkOnly ? [] : [1000, 10000, 100000])) {
  for (const action of (directoryOnly ? ['update', 'history-update'] : ['update', 'key', 'move', 'append', 'history-update'])) scenarios.push({ size, action });
}
for (const size of (directoryOnly ? [] : [1000, 10000])) {
  for (const action of ['update-all', 'append-all', 'mixed', 'replace-all', 'snapshot-all', 'create']) scenarios.push({ size, action });
}

function expected(size, action) {
  if (action === 'create') return `${size}:0:0:${size - 1}:0:0`;
  if (action === 'append-all') return `${size * 2}:0:0:${size * 2 - 1}:0:0`;
  if (action === 'mixed') return `${size * 2}:1:1:0:0:0`;
  if (action === 'history-update') return '1:0:1:0:0:0';
  if (action === 'update' || action === 'update-all' || action === 'replace-all' || action === 'snapshot-all') return `${size}:0:1:${size - 1}:0:0`;
  if (action === 'key') return `${size}:changed:1:${size - 1}:0:0`;
  if (action === 'move') return `${size}:1:0:0:0:0`;
  return `${size + 1}:0:0:${size}:0:0`;
}

async function run(kind, { size, action }) {
  const root = installDomDouble();
  const { instance } = await instantiateSignalsBytes(files[kind]);
  const runtime = new BenchmarkSignalsRuntime(instance.exports, root, {
    crypto: { getRandomValues(values) { values[0] = 123456; return values; } },
    onError(error) { throw error; },
  });
  const click = id => {
    const button = find(root, 'id', id);
    assert(button, `missing ${id} button`);
    fireEvent(button, 'click', { bubbles: true });
  };
  runtime.mount();
  const ledger = instance.exports.roc_ui_debug_live_allocation_count();
  if (kind === 'production') assert.equal(ledger, 0, 'production artifact enabled diagnostic allocation tracking');
  else assert(ledger > 0, 'diagnostic artifact omitted allocation tracking');
  if (action !== 'create') click(`create-${size}`);
  const summary = find(root, 'data-testid', 'summary');
  assert.equal(summary.textContent, action === 'create' ? 'empty' : `${size}:0:0:${size - 1}:0:0`);
  if (action === 'history-update') {
    click('clear');
    assert.equal(summary.textContent, 'empty');
    click('append');
    assert.equal(summary.textContent, '1:0:0:0:0:0');
  }
  if (kind === 'diagnostic') resetBenchmarkMetrics(instance.exports);
  // Locate the button before timing: only dispatch, Roc work and one scalar
  // command belong to the measured operation.
  const button = find(root, 'id', action === 'create' ? `create-${size}` : action === 'history-update' ? 'update' : action);
  runtime.benchmarkRecorder.begin();
  runtime.benchmarkRecorder.measureEvent(() => fireEvent(button, 'click', { bubbles: true }));
  const measured = runtime.benchmarkRecorder.finish();
  assert.equal(summary.textContent, expected(size, action));
  const metrics = kind === 'diagnostic' ? readBenchmarkMetrics(instance.exports) : null;
  if (metrics) {
    assert.equal(metrics.runtime_events_processed, 1n);
    assert.equal(metrics.runtime_patches_emitted, 1n);
    assert.equal(metrics.runtime_derived_calls_into_roc, 1n);
  }
  const { wasm_pages: _pages, ...state } = runtime.benchmarkRuntimeState();
  const parity = {
    summary: summary.textContent, commands: runtime.lastCommands, state,
    command_count: measured.command_count, fixed_record_bytes: measured.fixed_record_bytes,
    fixed_string_bytes: measured.fixed_string_bytes, dynamic_bytes: measured.dynamic_bytes,
    opcode_counts: measured.opcode_counts, decode: measured.decode,
  };
  click('validate');
  runtime.unmount();
  assert.equal(runtime.liveHostValues(), 0, 'unmount retained HostValues');
  if (metrics) {
    instance.exports.roc_ui_benchmark_metrics_checkpoint();
    const after = readBenchmarkMetrics(instance.exports);
    assert.equal(after.roc_live_count, 0n, 'unmount retained Roc allocations');
    assert.equal(after.roc_live_bytes, 0n, 'unmount retained Roc bytes');
  }
  return { measured, metrics, parity };
}

const traffic = new Map();
for (const scenario of scenarios.filter(scenario => !actionFilter || scenario.action === actionFilter)) {
  for (let sample = -1; sample < samples; sample += 1) {
    const production = await run('production', scenario);
    const diagnostic = await run('diagnostic', scenario);
    assert.deepEqual(production.parity, diagnostic.parity, 'production/diagnostic semantic or wire mismatch');
    if (sample < 0) continue;
    const bytes = diagnostic.metrics.roc_allocated_bytes + diagnostic.metrics.roc_realloc_copied_bytes;
    const key = `${scenario.action}:${scenario.size}`;
    if (traffic.has(key)) assert.equal(bytes, traffic.get(key), 'allocation traffic changed between identical fresh instances');
    traffic.set(key, bytes);
    console.log(JSON.stringify({ ...scenario, sample, hashes, node: process.version, node_flags: process.execArgv, production: production.measured, diagnostic: diagnostic.metrics, parity: production.parity }, (_key, value) => typeof value === 'bigint' ? value.toString() : value));
  }
}
if (check) {
  for (const action of (bulkOnly ? [] : ['update', 'history-update'])) {
    const small = traffic.get(`${action}:1000`);
    for (const size of [10000, 100000]) assert(traffic.get(`${action}:${size}`) <= small + 4096n, `${action} copied storage proportional to total/history size`);
  }
  // Structural edits include AVL search/rotation paths; their modest depth
  // growth is allowed, but copying a flat 100k-entry key/order table is not.
  for (const action of (directoryOnly || bulkOnly ? [] : ['key', 'move', 'append'])) {
    const small = traffic.get(`${action}:1000`);
    assert(traffic.get(`${action}:100000`) <= small * 4n + 65536n, `${action} exceeded changed-path allocation growth`);
  }
  for (const action of (directoryOnly ? [] : ['update-all', 'append-all', 'mixed', 'replace-all', 'snapshot-all', 'create'])) {
    assert(traffic.get(`${action}:10000`) <= traffic.get(`${action}:1000`) * 16n, `${action} normalization allocation growth exceeded its edit-count budget`);
  }
}
