// Browser facts for the boot protocol and timer results. These readers encode
// outside data; application policy, formatting and random generators stay in Roc.
export const I64_MIN = -(1n << 63n);
export const I64_MAX = (1n << 63n) - 1n;
const DATE_LIMIT = 8640000000000000n;
const DAY_MS = 86400000n;
const encoder = new TextEncoder();

export function checkedI64(value, label) {
  if (typeof value === "number") {
    if (!Number.isSafeInteger(value)) throw new Error(`${label} must answer a safe integer number or an I64 bigint`);
    value = BigInt(value);
  }
  if (typeof value !== "bigint" || value < I64_MIN || value > I64_MAX) throw new Error(`${label} must answer a safe integer number or an I64 bigint`);
  return value;
}

export function i64Bytes(value) {
  const bytes = new Uint8Array(8);
  new DataView(bytes.buffer).setBigInt64(0, value, true);
  return bytes;
}

export function i32Bytes(value) {
  const bytes = new Uint8Array(4);
  new DataView(bytes.buffer).setInt32(0, value, true);
  return bytes;
}

function checkedText(value, label) {
  if (typeof value !== "string" || !value.isWellFormed() || encoder.encode(value).length > 64) throw new Error(`${label} must be a well-formed string of at most 64 UTF-8 bytes`);
  return value;
}

export function checkedLanguages(value) {
  if (!Array.isArray(value) || value.length < 1 || value.length > 16) throw new Error("options.environment.languages must answer 1 to 16 language strings");
  return value.map(language => checkedText(language, "options.environment.languages tag"));
}

export function browserLanguages(navigator) {
  const preferred = navigator?.languages;
  let languages;
  if (Array.isArray(preferred) && preferred.length > 0) languages = preferred;
  else if (typeof navigator?.language === "string") languages = [navigator.language];
  else languages = ["en-US"];
  const fitting = [];
  for (const language of languages) {
    if (typeof language !== "string" || !language.isWellFormed()) throw new Error("browser language is not a well-formed string");
    if (encoder.encode(language).length <= 64) fitting.push(language);
    if (fitting.length === 16) break;
  }
  return fitting.length > 0 ? fitting : ["en-US"];
}

export function checkedSeed(value) {
  if (!(value instanceof Uint8Array) || value.length !== 16) throw new Error("options.environment.seed must answer a Uint8Array of exactly 16 bytes");
  return value.slice();
}

export function browserSeed() {
  if (typeof globalThis.crypto?.getRandomValues !== "function") throw new Error("the browser has no cryptographic entropy source");
  return globalThis.crypto.getRandomValues(new Uint8Array(16));
}

export function checkedZone(value) {
  if (typeof value !== "object" || value === null || Array.isArray(value)) throw new Error("options.environment.timeZone must answer a zone record");
  const name = checkedText(value.name, "options.environment.timeZone name");
  const from_ms = checkedI64(value.from_ms, "options.environment.timeZone from_ms");
  const until_ms = checkedI64(value.until_ms, "options.environment.timeZone until_ms");
  if (from_ms > until_ms) throw new Error("options.environment.timeZone span starts after its end");
  if (!Array.isArray(value.offsets) || value.offsets.length < 1 || value.offsets.length > 128) throw new Error("options.environment.timeZone must answer 1 to 128 offsets");
  let previous = null;
  const offsets = value.offsets.map((offset, index) => {
    if (typeof offset !== "object" || offset === null || Array.isArray(offset)) throw new Error("options.environment.timeZone offset must be a record");
    const start = checkedI64(offset.from_ms, "options.environment.timeZone offset from_ms");
    if (index === 0 ? start !== from_ms : start <= previous) throw new Error("options.environment.timeZone offsets must start at from_ms and ascend strictly");
    if (start < from_ms || start > until_ms) throw new Error("options.environment.timeZone offset is outside its span");
    const minutes = offset.minutes;
    if (!Number.isInteger(minutes) || minutes < -2147483648 || minutes > 2147483647) throw new Error("options.environment.timeZone minutes must be I32 integers");
    previous = start;
    return { from_ms: start, minutes: minutes === 0 ? 0 : minutes };
  });
  return { name, from_ms, until_ms, offsets };
}

// Sample daily outward from the mount instant, bisecting every observed
// change. The temporary transition list is bounded by 129 entries. If it
// would overflow the 128-offset table, trim both ends to the nearest span
// whose changes fit; that span always includes the mount instant.
export function probeTimeZone(days, at_ms, readers = {}) {
  if (!Number.isInteger(days) || days < 0 || days > 7305) throw new Error("time-zone days must be from 0 to 7305");
  const at = checkedI64(at_ms, "mount time");
  const reach = BigInt(days) * DAY_MS;
  if (at - reach < -DATE_LIMIT || at + reach > DATE_LIMIT) throw new Error("the requested time-zone span is outside the browser Date range");
  const offsetAt = readers.offsetAt ?? (time => -new Date(Number(time)).getTimezoneOffset());
  const offset = time => {
    const minutes = offsetAt(time);
    if (!Number.isInteger(minutes) || minutes < -2147483648 || minutes > 2147483647) throw new Error("the browser supplied an invalid time-zone offset");
    return minutes === 0 ? 0 : minutes;
  };
  let name;
  if (readers.name !== undefined) name = readers.name;
  else name = typeof globalThis.Intl?.DateTimeFormat === "function" ? Intl.DateTimeFormat().resolvedOptions().timeZone : "";
  if (typeof name !== "string" || !name.isWellFormed() || encoder.encode(name).length > 64) name = "";
  const middle = offset(at);
  let left = { time: at, minutes: middle }, right = left;
  let transitions = [];
  const change = (start, end) => {
    let low = start.time, high = end.time;
    while (high - low > 1n) {
      const half = low + (high - low) / 2n;
      if (offset(half) === start.minutes) low = half;
      else high = half;
    }
    return { from_ms: high, minutes: end.minutes };
  };
  for (let day = 1; day <= days; day++) {
    const distance = BigInt(day) * DAY_MS;
    const nextLeft = { time: at - distance, minutes: offset(at - distance) };
    const nextRight = { time: at + distance, minutes: offset(at + distance) };
    if (nextLeft.minutes !== left.minutes) transitions.push(change(nextLeft, left));
    if (right.minutes !== nextRight.minutes) transitions.push(change(right, nextRight));
    left = nextLeft; right = nextRight;
    if (transitions.length > 127) {
      let radius = distance;
      while (transitions.filter(item => item.from_ms > at - radius && item.from_ms <= at + radius).length > 127) {
        const furthest = transitions.reduce((largest, item) => {
          const distance = item.from_ms < at ? at - item.from_ms : item.from_ms - at;
          return distance > largest ? distance : largest;
        }, 0n);
        radius = furthest - 1n;
        transitions = transitions.filter(item => item.from_ms > at - radius && item.from_ms <= at + radius);
      }
      const from_ms = at - radius, until_ms = at + radius;
      return { name, from_ms, until_ms, offsets: [{ from_ms, minutes: offset(from_ms) }, ...transitions.sort((a, b) => a.from_ms < b.from_ms ? -1 : a.from_ms > b.from_ms ? 1 : 0)] };
    }
  }
  const from_ms = at - reach;
  return { name, from_ms, until_ms: at + reach, offsets: [{ from_ms, minutes: left.minutes }, ...transitions.filter(item => item.from_ms > from_ms).sort((a, b) => a.from_ms < b.from_ms ? -1 : a.from_ms > b.from_ms ? 1 : 0)] };
}
