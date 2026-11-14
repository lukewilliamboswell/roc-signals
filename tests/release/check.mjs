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
import { resolve } from "node:path";
import { pathToFileURL } from "node:url";

const path = process.argv[2];
if (!path) {
  console.error("usage: node check.mjs app.wasm [runtime.mjs]");
  process.exit(2);
}
// The archive carries the complete runtime beside this helper. Repository
// checks pass the source runtime explicitly so they exercise the same module.
const runtimeURL = process.argv[3]
  ? pathToFileURL(resolve(process.argv[3]))
  : new URL("./runtime.mjs", import.meta.url);
const { PROTOCOL_VERSION, WORK_METRIC_BASE, readDeclarations } = await import(runtimeURL.href);

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
let boundaryError = null;
let mediaCount = null;
let facts = null;
try {
  const declarations = readDeclarations(x);
  mediaCount = declarations.media.length;
  facts = declarations.protocol;
  x.payload_reserve(0);
  x.init();
} catch (error) {
  trapped = true;
  boundaryError = error;
}
const fault = x.fault();
console.log(`fault ${facts?.fault_classes[fault] ?? fault}`);
if (trapped || fault !== 0) {
  const text = new TextDecoder().decode(new Uint8Array(x.memory.buffer, x.err_ptr(), x.err_len()));
  console.log(text || String(boundaryError?.message ?? boundaryError ?? "unknown mount failure"));
  process.exit(1);
}
// Work counters 1–18 are the opcode prefix; later counter positions have
// other meanings and must never be labelled as additional command opcodes.
for (const { code, name } of facts.ops.filter(row => row.code <= 18)) {
  const n = x.metric(WORK_METRIC_BASE + code);
  if (n > 0n) console.log(`${name} ${n}`);
}

// Check the empty-byte shorthand against every explicit default section.
// This stays silent on success because spec.json records this helper's output.
const defaults = new Uint8Array([
  1, 5, 0, 0, 0, 1, 0, 0, 0, 47,
  2, 5, 0, 0, 0, 1, 0, 0, 0, 0,
  3, 1, 0, 0, 0, 1,
  4, 1, 0, 0, 0, 1,
  6, mediaCount, 0, 0, 0, ...new Array(mediaCount).fill(0),
  7, 8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
  8, 16, 0, 0, 0, ...new Array(16).fill(0),
  9, 13, 0, 0, 0, 1, 0, 0, 0, 5, 0, 0, 0, 101, 110, 45, 85, 83,
  10, 39, 0, 0, 0, 3, 0, 0, 0, 85, 84, 67,
  0, 0, 0, 0, 0, 0, 0, 128, 255, 255, 255, 255, 255, 255, 255, 127,
  1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 128, 0, 0, 0, 0,
  11, 5, 0, 0, 0, 1, 0, 0, 0, 0,
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
