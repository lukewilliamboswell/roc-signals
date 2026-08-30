#!/usr/bin/env node

import { readFile } from "node:fs/promises";
import process from "node:process";

import { CASES, runIteration } from "./run_wasm_benchmarks.mjs";

function memoryRow(cycle) {
  globalThis.gc();
  const memory = process.memoryUsage();
  return {
    cycle,
    heap_used: memory.heapUsed,
    external: memory.external,
    array_buffers: memory.arrayBuffers,
    rss: memory.rss,
  };
}

async function main() {
  if (typeof globalThis.gc !== "function") throw new Error("retained-growth runner requires node --expose-gc");
  const [wasmPath, caseId = "create_1k", cyclesText = "100", checkpointText = "10"] = process.argv.slice(2);
  if (!wasmPath) throw new Error("usage: node --expose-gc run_wasm_retained_growth.mjs <production.wasm> [case] [cycles] [checkpoint]");
  const scenario = CASES.find((entry) => entry.id === caseId);
  if (!scenario) throw new Error(`unknown Wasm benchmark case ${caseId}`);
  const cycles = Number(cyclesText);
  const checkpoint = Number(checkpointText);
  if (!Number.isSafeInteger(cycles) || cycles <= 0 || !Number.isSafeInteger(checkpoint) || checkpoint <= 0) {
    throw new Error("cycles and checkpoint must be positive integers");
  }
  const bytes = await readFile(wasmPath);
  const rows = [memoryRow(0)];
  for (let cycle = 1; cycle <= cycles; cycle += 1) {
    await runIteration(bytes, scenario, false);
    if (cycle % checkpoint === 0 || cycle === cycles) rows.push(memoryRow(cycle));
  }
  process.stdout.write("cycle,heap_used,external,array_buffers,rss\n");
  for (const row of rows) process.stdout.write(`${Object.values(row).join(",")}\n`);
}

main().catch((error) => {
  console.error(error?.stack ?? error);
  process.exitCode = 1;
});
