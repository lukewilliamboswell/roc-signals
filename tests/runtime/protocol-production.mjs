// The protocol fixture (tests/browser/protocol-fixture.mjs) is test-owned
// and independent of the Roc encoder, so the runtime's contract tests stay
// honest about what they feed it. This check closes the loop the other way:
// a module the platform actually built must declare exactly the fixture's
// facts, or the contract tests are exercising a protocol no module speaks.
// It reuses a module the runtime units already built.
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { readDeclarations } from "../../platform/runtime.mjs";
import { protocolFixtureFacts } from "../browser/protocol-fixture.mjs";

const file = process.argv[2];
assert.ok(file, "usage: node tests/runtime/protocol-production.mjs BUILT.wasm");
const module = await WebAssembly.compile(await readFile(file));
const imports = {};
for (const entry of WebAssembly.Module.imports(module)) {
  (imports[entry.module] ??= {})[entry.name] = () => { throw new Error(`unexpected hosted effect ${entry.name}`); };
}
const exports = (await WebAssembly.instantiate(module, imports)).exports;
const { facts } = readDeclarations(exports).bindings;
// Compare plain copies: the bindings freeze their rows.
assert.deepStrictEqual(structuredClone(facts), structuredClone(protocolFixtureFacts));
console.log("ok   a built module's protocol facts are the fixture's");
