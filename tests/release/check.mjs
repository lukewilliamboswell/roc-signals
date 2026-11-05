// The runtime helper of the release examples archive (`runtime/check.mjs`).
// The shared nightly-compatibility runner builds each archived app for
// wasm32 with the latest Roc nightly and runs `node check.mjs app.wasm`; the
// output must match the case recorded in `spec.json` exactly.
//
// It mounts the app the way platform/runtime.mjs does, without a DOM: it
// checks the protocol version, mounts with empty boot bytes (no storage,
// online, visible), and prints the fault state and the mount's commands by
// kind from the engine's work record (design.md, Appendix B). Those counts
// are decided by the engine and the app, not by the compiler, so a nightly
// that changes them has changed behaviour.
import { readFile } from "node:fs/promises";

const PROTOCOL_VERSION = 3;
const WORK_METRIC_BASE = 16;
const OPCODES = ["", "INST", "TEXT", "HATTR", "MOVE", "REMOVE", "CLEAR", "TEMPLATE", "ELEM", "ATTR", "TEXTNODE", "LISTEN", "SETTEXT", "FX", "CANCEL", "NAV", "STORE", "TITLE", "FOCUS"];
const FAULTS = ["none", "contract", "resource_limit", "out_of_memory", "app_crash", "expect_failed"];

const path = process.argv[2];
if (!path) {
  console.error("usage: node check.mjs app.wasm");
  process.exit(2);
}
const { instance } = await WebAssembly.instantiate(await readFile(path), { env: {} });
const x = instance.exports;

const version = x.protocol_version();
console.log(`protocol ${version}`);
if (version !== PROTOCOL_VERSION) process.exit(1);

let trapped = false;
try {
  x.boot_keys();
  x.payload_reserve(0);
  x.init();
} catch (_) {
  trapped = true;
}
const fault = x.fault();
console.log(`fault ${FAULTS[fault] ?? fault}`);
if (trapped || fault !== 0) {
  const text = new TextDecoder().decode(new Uint8Array(x.memory.buffer, x.err_ptr(), x.err_len()));
  console.log(text);
  process.exit(1);
}
for (let op = 1; op < OPCODES.length; op += 1) {
  const n = x.metric(WORK_METRIC_BASE + op);
  if (n > 0n) console.log(`${OPCODES[op]} ${n}`);
}
