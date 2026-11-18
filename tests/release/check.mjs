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
let startup = null;
let facts = null;
try {
  const declarations = readDeclarations(x);
  mediaCount = declarations.media.length;
  startup = declarations.startup;
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
// Check the empty-byte shorthand against every explicit default section.
// This stays silent on success because spec.json records this helper's output.
const u32 = value => { const out = new Uint8Array(4); new DataView(out.buffer).setUint32(0, value, true); return out; };
const str = value => { const bytes = new TextEncoder().encode(value); return Buffer.concat([u32(bytes.length), bytes]); };
const section = (tag, body) => Buffer.concat([new Uint8Array([tag]), u32(body.length), body]);
const root = startup.profile === 1 ? startup.root : { namespace: "http://www.w3.org/1999/xhtml", prefix: "", local: "div" };
const known = ["http://www.w3.org/1999/xhtml", "http://www.w3.org/2000/svg", "http://www.w3.org/1998/Math/MathML", ""];
const code = known.indexOf(root.namespace);
const rootBytes = Buffer.concat([new Uint8Array([code < 0 ? 4 : code]), ...(code < 0 ? [str(root.namespace)] : []), str(root.prefix), str(root.local)]);
const defaults = Buffer.concat([new Uint8Array([
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
]), section(13, rootBytes), section(14, startup.profile === 1 ? Buffer.concat([new Uint8Array([1, 0]), u32(0)]) : new Uint8Array([0]))]);
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
// Deterministic programs publish a cold frame before initial follow-ups. This
// headless compatibility probe records its barrier and acknowledges it; full
// native/browser suites execute and check the effects themselves.
if (startup.profile === 1) {
  const begin = facts.ops.find(row => row.name === "STARTUP").code;
  const barrier = facts.ops.find(row => row.name === "STARTUP_ACK").code;
  for (const e of [x, other]) {
    const cold = commands(e);
    if (cold[0] !== 0 || cold[1] !== begin || cold[cold.length - 1] !== barrier) throw new Error("missing cold startup barrier");
    const p = e.payload_reserve(1);
    new Uint8Array(e.memory.buffer, p, 1)[0] = 254;
    e.event(0xffffffff, 0);
    if (e.fault()) throw new Error("startup acknowledgement fault");
  }
  if (!commands(x).equals(commands(other)) || !work(x).equals(work(other))) throw new Error("default startup acknowledgements differ");
}
// Work counters 1–18 are the opcode prefix; later counter positions have
// other meanings and must never be labelled as additional command opcodes.
for (const { code, name } of facts.ops.filter(row => row.code <= 18)) {
  const n = x.metric(WORK_METRIC_BASE + code);
  if (n > 0n) console.log(`${name} ${n}`);
}

other.drop();
x.drop();
