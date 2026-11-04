#!/usr/bin/env node
// Roc allocation counts per transaction in the Wasm host, for the same event
// sequence as the native roc-fuzz `jfb-host-path` example. Engine only: the
// command bytes are not applied to a DOM (the host counts Roc allocations).
import { readFile } from "node:fs/promises";

import { instantiateEngineBytes } from "../../../../platform-roc/runtime.mjs";

const { instance } = await instantiateEngineBytes(await readFile(process.argv[2]));
const x = instance.exports;
const steps = [
  ["jfb-create-10k", 1000, 1],
  ["jfb-update-every-10th", 1000, 3],
  ["jfb-select", 16777221, 1],
  ["jfb-select-other", 16777223, 1],
  ["jfb-swap", 1000, 5],
  ["jfb-remove", 16777219, 2],
  ["jfb-append-1k", 1000, 2],
  ["jfb-clear", 1000, 4],
  ["jfb-create-1k", 1000, 0],
  ["jfb-replace-1k", 1000, 0],
  ["jfb-clear-1k", 1000, 4],
];
x.reset_metrics();
x.init();
const row = (name) => console.log(`${name.padEnd(24)} allocs=${x.metric(0)} deallocs=${x.metric(1)} bytes=${x.metric(2)} reallocs=${x.metric(3)} live=${x.metric(4)} live_bytes=${x.metric(5)} cmd_bytes=${x.cmd_len()} pages=${x.memory.buffer.byteLength / 65536}`);
row("mount");
for (const [name, node, handler] of steps) {
  x.reset_metrics();
  x.event(node, handler);
  row(name);
}
x.reset_metrics();
x.drop();
row("drop");
