// Boundary and probe contracts for the browser facts carried at mount. The
// TZ children exercise the actual host service, without changing globals.
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { performance } from "node:perf_hooks";
import { I64_MIN, I64_MAX, checkedI64, i64Bytes, i32Bytes, checkedLanguages, browserLanguages, checkedSeed, browserSeed, checkedZone, probeTimeZone } from "../../platform/environment.mjs";
const DAY = 86400000n;
const at = BigInt(Date.parse("2026-11-13T00:40:00Z"));
const offsetOf = (zone, time) => {
  assert(time >= zone.from_ms && time <= zone.until_ms);
  let minutes = zone.offsets[0].minutes;
  for (const offset of zone.offsets) if (offset.from_ms <= time) minutes = offset.minutes;
  return minutes;
};
const check = (name, test) => { test(); console.log(`ok   ${name}`); };

if (process.argv.includes("--zone-child")) {
  const expected = process.env.TZ;
  check(`the Date service uses ${expected}`, () => {
    assert.equal(Intl.DateTimeFormat().resolvedOptions().timeZone, expected);
  });
  for (const days of [366, 7305]) {
    let reads = 0;
    const begin = performance.now();
    const zone = probeTimeZone(days, at, { offsetAt(time) { reads++; return -new Date(Number(time)).getTimezoneOffset(); } });
    const elapsed = performance.now() - begin;
    check(`${expected} probe covers its declared ${days}-day span exactly`, () => {
      assert.equal(zone.from_ms, at - BigInt(days) * DAY);
      assert.equal(zone.until_ms, at + BigInt(days) * DAY);
      assert(zone.offsets.length <= 128);
      checkedZone(zone);
      for (const time of [zone.from_ms, at, zone.until_ms]) assert.equal(offsetOf(zone, time), 0 - new Date(Number(time)).getTimezoneOffset() || 0);
      for (const offset of zone.offsets.slice(1)) {
        assert.equal(offsetOf(zone, offset.from_ms), 0 - new Date(Number(offset.from_ms)).getTimezoneOffset() || 0);
        assert.equal(offsetOf(zone, offset.from_ms - 1n), 0 - new Date(Number(offset.from_ms - 1n)).getTimezoneOffset() || 0);
        assert.notEqual(offsetOf(zone, offset.from_ms - 1n), offset.minutes);
      }
      assert(reads >= days * 2 + 1 && reads <= days * 2 + 1 + (zone.offsets.length - 1) * 27);
      if (expected === "UTC") assert.deepEqual(zone.offsets, [{ from_ms: zone.from_ms, minutes: 0 }]);
      else {
        assert(zone.offsets.some(offset => offset.minutes === 600));
        assert(zone.offsets.some(offset => offset.minutes === 660));
      }
    });
    console.log(JSON.stringify({ zone: expected, days, reads, offsets: zone.offsets.length, elapsedMs: elapsed }));
  }
  process.exit(0);
}

check("signed time accepts safe numbers and every I64 bigint without rounding", () => {
  for (const value of [I64_MIN, -1n, 0n, I64_MAX]) assert.equal(new DataView(i64Bytes(checkedI64(value, "time")).buffer).getBigInt64(0, true), value);
  assert.equal(checkedI64(-12, "time"), -12n);
  for (const value of [I64_MIN - 1n, I64_MAX + 1n, 1.5, NaN, Infinity, Number.MAX_SAFE_INTEGER + 1, "0", null]) assert.throws(() => checkedI64(value, "time"));
  assert.equal(new DataView(i32Bytes(-2147483648).buffer).getInt32(0, true), -2147483648);
});
check("language bounds are bytes and count, without invented BCP47 validation", () => {
  assert.deepEqual(checkedLanguages(["", "en-AU", "é".repeat(32)]), ["", "en-AU", "é".repeat(32)]);
  assert.equal(checkedLanguages(Array(16).fill("en")).length, 16);
  for (const value of [[], Array(17).fill("en"), ["é".repeat(33)], ["\ud800"], [7], "en"]) assert.throws(() => checkedLanguages(value));
  assert.deepEqual(browserLanguages({ languages: ["x".repeat(65), "en-AU", "en"] }), ["en-AU", "en"]);
  assert.equal(browserLanguages({ languages: Array(20).fill("en") }).length, 16);
  assert.deepEqual(browserLanguages({ languages: [], language: "fr" }), ["fr"]);
  assert.deepEqual(browserLanguages({ languages: ["x".repeat(65)] }), ["en-US"]);
  assert.deepEqual(browserLanguages({}), ["en-US"]);
});
check("a seed is exactly sixteen owned bytes and never Math.random", () => {
  const input = new Uint8Array(16).fill(7), output = checkedSeed(input);
  input[0] = 2; assert.equal(output[0], 7);
  for (const value of [new Uint8Array(15), new Uint8Array(17), Array(16).fill(0)]) assert.throws(() => checkedSeed(value));
  const random = Math.random;
  try { Math.random = () => { throw new Error("Math.random must not mint a seed"); }; assert.equal(browserSeed().length, 16); }
  finally { Math.random = random; }
  const crypto = Object.getOwnPropertyDescriptor(globalThis, "crypto");
  try { Object.defineProperty(globalThis, "crypto", { value: undefined, configurable: true }); assert.throws(browserSeed, /entropy/); }
  finally { Object.defineProperty(globalThis, "crypto", crypto); }
});
const utc = { name: "UTC", from_ms: I64_MIN, until_ms: I64_MAX, offsets: [{ from_ms: I64_MIN, minutes: 0 }] };
check("zone validation includes both endpoints and rejects every structural fault", () => {
  assert.deepEqual(checkedZone(utc), utc);
  assert.deepEqual(checkedZone({ name: "", from_ms: 1n, until_ms: 1n, offsets: [{ from_ms: 1, minutes: -60 }] }), { name: "", from_ms: 1n, until_ms: 1n, offsets: [{ from_ms: 1n, minutes: -60 }] });
  for (const zone of [
    { ...utc, name: "x".repeat(65) }, { ...utc, from_ms: 1n, until_ms: 0n },
    { ...utc, offsets: [] }, { ...utc, offsets: Array(129).fill({ from_ms: I64_MIN, minutes: 0 }) },
    { ...utc, offsets: [{ from_ms: I64_MIN + 1n, minutes: 0 }] },
    { ...utc, offsets: [{ from_ms: I64_MIN, minutes: 0 }, { from_ms: I64_MIN, minutes: 1 }] },
    { ...utc, offsets: [{ from_ms: I64_MIN, minutes: 0 }, { from_ms: I64_MAX + 1n, minutes: 1 }] },
    { ...utc, offsets: [{ from_ms: I64_MIN, minutes: 0.5 }] },
  ]) assert.throws(() => checkedZone(zone));
});
check("dense changes shorten both ends, retain mount and stay within128 offsets", () => {
  let reads = 0;
  const fact = time => Math.abs(Math.floor(Number(time) / Number(DAY))) % 2 ? 60 : 0;
  const zone = probeTimeZone(366, at, { name: "dense", offsetAt(time) { reads++; return fact(time); } });
  checkedZone(zone);
  assert(zone.from_ms > at - 366n * DAY && zone.until_ms < at + 366n * DAY);
  assert(zone.from_ms <= at && zone.until_ms >= at && zone.offsets.length <= 128);
  for (const time of [zone.from_ms, at, zone.until_ms, ...zone.offsets.slice(1).flatMap(offset => [offset.from_ms - 1n, offset.from_ms])]) assert.equal(offsetOf(zone, time), fact(time));
  assert(reads < 366 * 2 + 129 * 27 + 2);
});
check("a zone with no browser name remains unknown without inventing offsets", () => {
  const zone = probeTimeZone(0, at, { name: "x".repeat(65), offsetAt: () => 345 });
  assert.deepEqual(zone, { name: "", from_ms: at, until_ms: at, offsets: [{ from_ms: at, minutes: 345 }] });
});
check("a malformed browser zone name refuses the probe instead of becoming unknown", () => {
  for (const name of ["\ud800", 42, null]) assert.throws(() => probeTimeZone(0, at, { name, offsetAt: () => 0 }), /time-zone name/);
});
check("an unrepresentable Date span is refused before any probe", () => {
  let reads = 0;
  for (const [days, time] of [[1, 8640000000000000n], [0, I64_MAX]]) assert.throws(() => probeTimeZone(days, time, { offsetAt() { reads++; return 0; } }), /Date range/);
  assert.equal(reads, 0);
  assert.throws(() => probeTimeZone(7306, at));
  assert.throws(() => probeTimeZone(1, at, { offsetAt: () => NaN }));
});
for (const TZ of ["UTC", "Australia/Sydney"]) {
  const child = spawnSync(process.execPath, [fileURLToPath(import.meta.url), "--zone-child"], { env: { ...process.env, TZ }, encoding: "utf8" });
  process.stdout.write(child.stdout); process.stderr.write(child.stderr);
  assert.equal(child.status, 0, `real zone child ${TZ}`);
}
console.log("environment unit: all pass");
