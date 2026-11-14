import assert from "node:assert/strict";
import { readProtocolFacts } from "../../platform/runtime.mjs";

// These fixture bytes are written independently of the Roc facts encoder.
const word = n => [n & 255, (n >>> 8) & 255, (n >>> 16) & 255, n >>> 24];
const text = value => { const bytes = [...new TextEncoder().encode(value)]; return [...word(bytes.length), ...bytes]; };
const list = values => [...word(values.length), ...values.flat()];
const names = values => list(values.map(text));
const codes = rows => list(rows.map(([code, name]) => [code, ...text(name)]));
const field = (tag, body) => [tag, ...word(body.length), ...body];
const bodies = [
  codes([[1, "INST"]]),
  list([[1, ...text("TEXT"), ...names([])]]),
  list([[...word(1), ...text("PREVENT")]]),
  list([[1, ...text("value"), ...names(["input"])]]),
  codes([[1, "default"]]), codes([[1, "same-origin"]]),
  codes([[0, "HTML"]]), names(["button"]), names(["none", "contract"]), codes([[1, "ELEMENT"]]), codes([[0, "CHILDREN"]]),
];
const encode = parts => Uint8Array.from(parts.flatMap((body, index) => field(index + 1, body)));
const valid = encode(bodies);
assert.deepEqual(readProtocolFacts(valid), {
  ops: [{ code: 1, name: "INST" }], kinds: [{ code: 1, name: "TEXT", events: [] }],
  policies: [{ bit: 1, name: "PREVENT" }], properties: [{ index: 1, name: "value", elements: ["input"] }],
  http_cache: [{ code: 1, name: "default" }], http_credentials: [{ code: 1, name: "same-origin" }],
  namespaces: [{ code: 0, name: "HTML" }], text_entry_excluded: ["button"], fault_classes: ["none", "contract"], template_nodes: [{ code: 1, name: "ELEMENT" }], child_containers: [{ code: 0, name: "CHILDREN" }],
});
let refused = 0;
const reject = (bytes, reason) => { assert.throws(() => readProtocolFacts(Uint8Array.from(bytes)), reason); refused += 1; };
reject([], /short/);
reject(valid.slice(0, -1), /short/);
reject([...valid, 0], /trailing/);
reject([10, ...valid.slice(1)], /expected protocol fact field 1/);
reject([...field(1, bodies[0]), ...valid], /expected protocol fact field 2/);
reject(encode(bodies.slice(0, -1)), /short/);
reject(new Uint8Array(65537), /exceed/);
const change = (at, value) => encode(bodies.map((body, index) => index === at ? value : body));
reject(change(0, [...word(0xffffffff)]), /row count/);
reject(change(0, codes([[2, "INST"]])), /non-dense/);
reject(change(0, codes([[1, "INST"], [2, "INST"]])), /duplicate/);
reject(change(0, codes([[1, "INST"], [1, "TEXT"]])), /duplicate/);
reject(change(0, [...word(1), 1, ...word(1), 255]), /encoded data/);
reject(change(0, codes([[1, ""]])), /name length/);
reject(change(0, codes([[1, "A\0B"]])), /NUL/);
reject(change(0, [...bodies[0], 0]), /trailing/);
reject(change(1, list([[1, ...text("TEXT"), ...names(["input", "input"])]])), /duplicate/);
reject(change(1, list([[1, ...text("TEXT"), ...names(Array.from({ length: 33 }, (_, i) => `event${i}`))]])), /row count/);
reject(change(2, list([[...word(3), ...text("PREVENT")]])), /policy bit/);
reject(change(2, list([[...word(0), ...text("PREVENT")]])), /policy bit/);
reject(change(6, codes([[0, "HTML"], [1, "HTML"]])), /duplicate/);
reject(change(6, codes([[1, "HTML"]])), /non-dense/);
reject(change(9, codes([[0, "ELEMENT"]])), /non-dense/);
reject(change(10, codes([[1, "CHILDREN"]])), /non-dense/);
reject(change(8, names([])), /empty protocol fault/);
for (let end = 0; end < valid.length; end += 1) reject(valid.slice(0, end), /short|expected/);
console.log(`protocol-facts: independent round trip and ${refused} malformed/truncated refusals passed`);
