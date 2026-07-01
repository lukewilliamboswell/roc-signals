#!/usr/bin/env node

import { readFile } from "node:fs/promises";
import { basename } from "node:path";

import {
  SignalsRuntime,
  publicExampleTaskHandler,
} from "../../www/static/signals.mjs";
import { installDomDouble } from "./dom_double.mjs";

const [, , wasmPath, rawName] = process.argv;

if (!wasmPath) {
  console.error("usage: mount_wasm_example.mjs <wasm-path> [name]");
  process.exit(2);
}

const name = rawName ?? basename(wasmPath);
const settleMs = 50;

function hostError(exports) {
  const ptr = exports.roc_ui_last_error_ptr?.() ?? 0;
  const len = exports.roc_ui_last_error_len?.() ?? 0;
  if (ptr === 0 || len === 0) {
    return "";
  }
  return new TextDecoder().decode(new Uint8Array(exports.memory.buffer, ptr, len));
}

function fail(message) {
  console.error(message);
  process.exit(1);
}

const bytes = await readFile(wasmPath);
const { instance } = await WebAssembly.instantiate(bytes, {});
const root = installDomDouble();
const errors = [];
const runtime = new SignalsRuntime(instance.exports, root, {
  taskHandler: publicExampleTaskHandler,
  telemetry: false,
  onError: (err) => errors.push(err),
});

try {
  runtime.mount();
} catch (err) {
  const detail = hostError(instance.exports);
  const suffix = detail === "" ? "" : `\nHost error: ${detail}`;
  fail(`failed to mount ${name}: ${err?.stack ?? err}${suffix}`);
}

await new Promise((resolve) => setTimeout(resolve, settleMs));

if (errors.length !== 0) {
  const details = errors.map((err) => err?.stack ?? err).join("\n");
  fail(`runtime reported errors while mounting ${name}:\n${details}`);
}

if (root.textContent.trim() === "") {
  fail(`mounted ${name}, but no DOM text was rendered`);
}

try {
  runtime.unmount();
} catch (err) {
  const detail = hostError(instance.exports);
  const suffix = detail === "" ? "" : `\nHost error: ${detail}`;
  fail(`failed to unmount ${name}: ${err?.stack ?? err}${suffix}`);
}

const liveHostValues = runtime.liveHostValues();
if (liveHostValues !== 0) {
  fail(`mounted ${name}, but ${liveHostValues} host values are still live after unmount`);
}

console.log(`mounted ${name}`);
