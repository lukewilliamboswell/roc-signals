// The runtime helper of the release examples archive (`runtime/check.mjs`).
// The shared nightly-compatibility runner builds each archived app for
// wasm32 with the latest Roc nightly and runs `node check.mjs app.wasm`; the
// output must match the case recorded in `spec.json` exactly.
//
// It mounts the app the way platform/runtime.mjs does, without a DOM: it
// checks the protocol version, mounts with empty boot bytes (URL "/", no storage,
// online, visible, storage available), and prints the fault state and the mount's commands by
// kind from the engine's work record (design.md, Appendix B). Those counts
// are decided by the engine and the app, not by the compiler, so a nightly
// that changes them has changed behaviour.
import { readFile } from "node:fs/promises";

const PROTOCOL_VERSION = 13;
const WORK_METRIC_BASE = 16;
const OPCODES = ["", "INST", "TEXT", "HATTR", "MOVE", "REMOVE", "CLEAR", "TEMPLATE", "ELEM", "ATTR", "TEXTNODE", "LISTEN", "SETTEXT", "FX", "CANCEL", "NAV", "STORAGE", "TITLE", "REF"];
const FAULTS = ["none", "contract", "resource_limit", "out_of_memory", "app_crash", "expect_failed"];

const path = process.argv[2];
if (!path) {
  console.error("usage: node check.mjs app.wasm");
  process.exit(2);
}
// A module whose tasks call hosted effects imports them (`env.js_*`); the
// page's instance gets stubs that throw, as runtime.mjs's `pageImports`
// gives it, and mounting never reaches one.
const module = await WebAssembly.compile(await readFile(path));
const env = {};
for (const imp of WebAssembly.Module.imports(module)) {
  if (imp.module === "env" && imp.kind === "function")
    env[imp.name] = () => {
      throw new Error(`contract: ${imp.name} is a task effect`);
    };
}
const instance = await WebAssembly.instantiate(module, { env });
const x = instance.exports;

const version = x.protocol_version();
console.log(`protocol ${version}`);
if (version !== PROTOCOL_VERSION) process.exit(1);

let trapped = false;
let mediaCount = null;
try {
  x.boot_keys();
  // Boot carries flags in declaration order, so explicit defaults need one
  // False byte for every declared query, including apps with preferences.
  const declarations = new DataView(x.memory.buffer, x.cmd_ptr(), x.cmd_len());
  for (let at = 0; at < declarations.byteLength;) {
    const tag = declarations.getUint8(at);
    const length = declarations.getUint32(at + 1, true);
    const body = at + 5;
    if (body + length > declarations.byteLength) throw new Error("truncated declaration section");
    if (tag === 6) {
      if (mediaCount !== null || length < 4) throw new Error("invalid media declaration section");
      mediaCount = declarations.getUint32(body, true);
      if (mediaCount > 32) throw new Error("media declaration exceeds the protocol bound");
    }
    at = body + length;
  }
  if (mediaCount === null) throw new Error("missing media declaration section");
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

// Check the empty-byte shorthand against every explicit default section.
// This stays silent on success because spec.json records this helper's output.
const defaults = new Uint8Array([
  1, 5, 0, 0, 0, 1, 0, 0, 0, 47,
  2, 5, 0, 0, 0, 1, 0, 0, 0, 0,
  3, 1, 0, 0, 0, 1,
  4, 1, 0, 0, 0, 1,
  6, mediaCount, 0, 0, 0, ...new Array(mediaCount).fill(0),
]);
const other = (await WebAssembly.instantiate(module, { env })).exports;
other.boot_keys();
const p = other.payload_reserve(defaults.length);
new Uint8Array(other.memory.buffer, p, defaults.length).set(defaults);
other.init();
const commands = (e) => Buffer.from(new Uint8Array(e.memory.buffer, e.cmd_ptr(), e.cmd_len()));
const work = (e) => Buffer.from(new Uint8Array(e.memory.buffer, e.work_ptr(), e.work_len()));
if (!commands(x).equals(commands(other)) || !work(x).equals(work(other))) {
  console.error('empty boot bytes differ from the default sections (URL "/")');
  process.exit(1);
}
other.drop();
