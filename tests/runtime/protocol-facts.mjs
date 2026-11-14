import assert from "node:assert/strict";
import { readProtocolFacts } from "../../platform/runtime.mjs";
import { encodeProtocolFixture as encode, cborFixtureHead as head } from "../browser/protocol-fixture.mjs";

// Test-owned values/encoder, independent of Protocol.roc and its derived writer.
const facts = {
  ops: [{ code: 1, name: "INST" }], kinds: [{ code: 1, name: "TEXT", events: [] }],
  policies: [{ bit: 1, name: "PREVENT" }], properties: [{ index: 1, name: "value", elements: ["input"] }],
  http_cache: [{ code: 1, name: "default" }], http_credentials: [{ code: 1, name: "same-origin" }],
  namespaces: [{ code: 0, name: "HTML" }], text_entry_excluded: ["button"], fault_classes: ["none", "contract"],
  template_nodes: [{ code: 1, name: "ELEMENT" }], child_containers: [{ code: 0, name: "CHILDREN" }],
};
// RFC8949 preferred argument widths and deterministic encoded-key ordering.
assert.deepEqual(encode({ a: 1, b: [2, 3] }), [0xa2, 0x61, 0x61, 0x01, 0x61, 0x62, 0x82, 0x02, 0x03]);
assert.deepEqual(encode({ aa: 256, b: 24 }), [0xa2, 0x61, 0x62, 0x18, 0x18, 0x62, 0x61, 0x61, 0x19, 0x01, 0x00]);
const valid = Uint8Array.from(encode(facts));
assert.deepEqual(readProtocolFacts(valid), facts);
assert.deepEqual([...valid.slice(0, 5)], [0xab, 0x63, 0x6f, 0x70, 0x73]);
let refused = 0;
const reject = (bytes, reason) => { assert.throws(() => readProtocolFacts(Uint8Array.from(bytes)), reason); refused++; };
const change = (field, value) => encode({ ...facts, [field]: value });
const rawMap = pairs => [...head(5, pairs.length), ...pairs.flatMap(([key, value]) => [...encode(key), ...value])];
const sortedPairs = Object.entries(facts).map(([key, value]) => [key, encode(value)]).sort((a, b) => Buffer.compare(Buffer.from(encode(a[0])), Buffer.from(encode(b[0]))));
const rawField = (key, bytes) => rawMap(sortedPairs.map(pair => pair[0] === key ? [key, bytes] : pair));
// Saved independent nested-list witness. A byte string must never alias
// an empty events array in either consumer.
const nestedEmptyEvents = [...valid];
const emptyEventsPattern = [...encode("events"), 0x80];
const emptyEventsAt = nestedEmptyEvents.findIndex((_, i) => emptyEventsPattern.every((byte, j) => nestedEmptyEvents[i + j] === byte));
assert.ok(emptyEventsAt >= 0);
nestedEmptyEvents[emptyEventsAt + emptyEventsPattern.length - 1] = 0x40;
reject(nestedEmptyEvents, /unsupported protocol facts CBOR type/);
reject([], /short/);
reject([...valid, 0], /trailing/);
reject(new Uint8Array(65537), /exceed/);
reject([0xb8, 11, ...valid.slice(1)], /non-shortest/);
reject([0xbf, 0xff], /unsupported/);
reject([0xc0, ...valid], /unsupported|map/);
reject([0x40], /unsupported/);
reject([0xf6], /unsupported|map/);
reject(rawMap(sortedPairs.slice(1)), /field count/);
reject(rawMap([...sortedPairs, ["unknown", []]]), /field count/);
reject(rawMap([["bad", sortedPairs[0][1]], ...sortedPairs.slice(1)]), /unknown/);
reject(rawMap([sortedPairs[0], sortedPairs[0], ...sortedPairs.slice(2)]), /duplicate/);
reject(rawMap([sortedPairs[1], sortedPairs[0], ...sortedPairs.slice(2)]), /out-of-order/);
reject(rawField("ops", [0x9a, 0xff, 0xff, 0xff, 0xff]), /row count/);
reject(change("ops", [{ code: 2, name: "INST" }]), /non-dense/);
reject(change("ops", [{ code: 1, name: "INST" }, { code: 2, name: "INST" }]), /duplicate/);
reject(change("ops", [{ code: 1, name: "INST" }, { code: 1, name: "TEXT" }]), /duplicate/);
reject(change("ops", [{ code: 1, name: "" }]), /name length/);
reject(change("ops", [{ code: 1, name: "A\0B" }]), /NUL/);
reject(change("ops", [{ code: 1, name: "x".repeat(129) }]), /name length/);
reject(change("ops", [{ code: 256, name: "INST" }]), /unsigned|unsupported/);
reject(change("ops", [{ code: 1, name: "INST", extra: 0 }]), /field count/);
reject(rawField("ops", [0x81, 0xa2, ...encode("code"), 0x20, ...encode("name"), ...encode("INST")]), /unsigned|unsupported/);
reject(rawField("ops", [0x81, 0xa2, ...encode("code"), 0x18, 1, ...encode("name"), ...encode("INST")]), /non-shortest/);
reject(rawField("ops", [0x81, 0xa2, ...encode("code"), 1, ...encode("name"), 0x61, 255]), /encoded data/);
reject(rawField("ops", [0x81, 0xa2, ...encode("code"), 1, ...encode("name"), 0x41, 65]), /name length\/type|unsupported/);
reject(rawField("ops", [0x81, 0xa2, ...encode("code"), 1, ...encode("name"), 0x7f, 0xff]), /unsupported/);
reject(rawField("ops", [0x81, 0xa2, ...encode("code"), 0xfa, 0, 0, 0, 0, ...encode("name"), ...encode("INST")]), /unsigned|unsupported/);
reject(change("kinds", [{ code: 1, name: "TEXT", events: ["input", "input"] }]), /duplicate/);
reject(change("kinds", [{ code: 1, name: "TEXT", events: Array.from({ length: 33 }, (_, i) => `event${i}`) }]), /row count/);
reject(change("properties", [{ index: 1, name: "value", elements: Array.from({ length: 33 }, (_, i) => `tag${i}`) }]), /row count/);
reject(change("properties", [{ index: 1, name: "value", elements: ["input", "input"] }]), /duplicate/);
for (const bit of [0, 3, 0xffffffff]) reject(change("policies", [{ bit, name: "PREVENT" }]), /policy bit/);
reject(change("namespaces", [{ code: 0, name: "HTML" }, { code: 1, name: "HTML" }]), /duplicate/);
reject(change("namespaces", [{ code: 1, name: "HTML" }]), /non-dense/);
reject(change("template_nodes", [{ code: 0, name: "ELEMENT" }]), /non-dense/);
reject(change("child_containers", [{ code: 1, name: "CHILDREN" }]), /non-dense/);
reject(change("fault_classes", []), /empty protocol fault/);
reject(change("text_entry_excluded", ["button", "button"]), /duplicate/);
reject(change("fault_classes", ["none", "none"]), /duplicate/);
for (const field of Object.keys(facts)) reject(change(field, Array.from({ length: 65 }, (_, i) => field === "text_entry_excluded" || field === "fault_classes" ? `name${i}` : facts[field][0])), /row count/);
for (const field of ["ops", "kinds", "policies", "properties", "http_cache", "http_credentials", "namespaces", "template_nodes", "child_containers"]) reject(change(field, []), /empty protocol/);
for (let end = 0; end < valid.length; end++) reject(valid.slice(0, end), /short|row count/);
// Exact acceptance boundaries and long/short text keep BOM and non-ASCII bytes.
const boundary = { ...facts, ops: [{ code: 1, name: "é".repeat(64) }], policies: [{ bit: 0x80000000, name: "PREVENT" }], text_entry_excluded: Array.from({ length: 64 }, (_, i) => `x${i}`), kinds: [{ code: 1, name: "TEXT", events: Array.from({ length: 32 }, (_, i) => `e${i}`) }] };
assert.deepEqual(readProtocolFacts(Uint8Array.from(encode(boundary))), boundary);
for (const count of [1, 48]) {
  const name = "\uFEFF" + "x".repeat(count);
  assert.equal(readProtocolFacts(Uint8Array.from(change("ops", [{ code: 1, name }]))).ops[0].name, name);
}
console.log(`protocol-facts CBOR: independent canonical vectors/boundaries and ${refused} malformed/truncated refusals passed`);
