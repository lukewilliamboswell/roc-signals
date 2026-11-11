// An independent implementation of the Worker Lab's jobs
// (examples/worker-lab/Lab.roc): the tasks a run's parameters give, each
// task's answer, the digest the page shows per job and the run's checksum.
// workers-scaling.mjs compares what the page shows against it. It shares no
// code with the app: the tile kernel's 16.16 fixed-point arithmetic stays
// below 2^53, so plain JavaScript numbers reproduce it exactly.

export const NUMBERS_PER_WEIGHT = 2000;
export const FIRST_NUMBER = 1000000;
export const PIXELS_PER_WEIGHT = 4;
export const TILE_ITERS = 96;
const ONE = 65536;

function ceilSqrt(n) {
  let c = 1;
  while (c * c < n) c += 1;
  return c;
}

// Job `index`'s task for `{ workload, jobs, weight }`.
export function taskOf({ workload, jobs, weight }, index) {
  const width = weight * NUMBERS_PER_WEIGHT;
  const lo = FIRST_NUMBER + index * width;
  if (workload === "primes" || (workload === "faulty" && index % 4 !== 3)) return { kind: "count", lo, hi: lo + width };
  if (workload === "faulty") return { kind: "crash", lo, hi: lo + width };
  const cols = ceilSqrt(jobs);
  const side = weight * PIXELS_PER_WEIGHT;
  const step = Math.trunc((3 * ONE) / (cols * side));
  const span = side * step;
  return { kind: "tile", x0: -2 * ONE + (index % cols) * span, y0: Math.trunc((-3 * ONE) / 2) + Math.floor(index / cols) * span, step, side, iters: TILE_ITERS };
}

function isPrime(n) {
  if (n < 2) return false;
  if (n % 2 === 0) return n === 2;
  for (let d = 3; d * d <= n; d += 2) if (n % d === 0) return false;
  return true;
}

export function countPrimes(lo, hi) {
  let c = 0;
  for (let n = lo; n < hi; n += 1) if (isPrime(n)) c += 1;
  return c;
}

const shr16 = (x) => Math.floor(x / ONE);

export function tile({ x0, y0, step, side, iters }) {
  const out = new Uint8Array(side * side);
  for (let py = 0; py < side; py += 1) {
    const ci = y0 + py * step;
    for (let px = 0; px < side; px += 1) {
      const cr = x0 + px * step;
      let zr = 0;
      let zi = 0;
      let n = 0;
      while (n < iters) {
        const zr2 = shr16(zr * zr);
        const zi2 = shr16(zi * zi);
        if (zr2 + zi2 > 4 * ONE) break;
        zi = shr16(2 * zr * zi) + ci;
        zr = zr2 - zi2 + cr;
        n += 1;
      }
      out[py * side + px] = n;
    }
  }
  return out;
}

const FNV_OFFSET = 2166136261;
const fnvByte = (h, b) => Math.imul((h ^ b) >>> 0, 16777619) >>> 0;

export function fnv(bytes) {
  let h = FNV_OFFSET;
  for (const b of bytes) h = fnvByte(h, b);
  return h;
}

export const hex = (n) => (n >>> 0).toString(16).padStart(8, "0");

// What the page shows for a job that finished with an answer, and the
// answer's digest; `null` for a crash task (it has no answer).
export function answerOf(task) {
  if (task.kind === "count") {
    const n = countPrimes(task.lo, task.hi);
    return { text: `done: ${n} primes`, digest: n >>> 0, primes: n, bytes: 0 };
  }
  if (task.kind === "tile") {
    const bytes = tile(task);
    const h = fnv(bytes);
    return { text: `done: ${bytes.length} bytes, hash ${hex(h)}`, digest: h, primes: 0, bytes: bytes.length };
  }
  return null;
}

// The whole run: each job's answer, the totals and the checksum the page
// shows when every job is done (FNV-1a over the digests' little-endian
// bytes, in job order).
export function expectedRun(params) {
  const answers = [];
  let h = FNV_OFFSET;
  let primes = 0;
  let bytes = 0;
  for (let i = 0; i < params.jobs; i += 1) {
    const a = answerOf(taskOf(params, i));
    answers.push(a);
    if (a === null) continue;
    for (const shift of [0, 8, 16, 24]) h = fnvByte(h, (a.digest >>> shift) & 255);
    primes += a.primes;
    bytes += a.bytes;
  }
  return { answers, checksum: hex(h), primes, bytes };
}

// The Draw workload: a picture `weight * 128` pixels wide spanning x from
// -2.25 to 0.75, about two thirds as many rows centred on the real axis,
// cut into `jobs` strips of equal height. Each strip is an 8-bit palette
// BMP stored top row first; the picture is one header followed by every
// strip's pixels.
export const PIXELS_PER_DRAW_WEIGHT = 128;
export const DRAW_ITERS = 255;
const HEADER_BYTES = 1078;

export function stripsOf({ jobs, weight }) {
  const width = weight * PIXELS_PER_DRAW_WEIGHT;
  const rows = Math.ceil(Math.floor((width * 2) / 3) / jobs);
  const step = Math.trunc((3 * ONE) / width);
  const top = -Math.trunc((rows * jobs * step) / 2);
  const strips = [];
  for (let index = 0; index < jobs; index += 1) strips.push({ x0: -2.25 * ONE, y0: top + index * rows * step, step, width, rows, iters: DRAW_ITERS });
  return { width, height: rows * jobs, rows, strips };
}

// A strip's pixels are its escape counts, row by row.
export function stripPixels({ x0, y0, step, width, rows, iters }) {
  const out = new Uint8Array(width * rows);
  for (let py = 0; py < rows; py += 1) {
    const ci = y0 + py * step;
    for (let px = 0; px < width; px += 1) out[py * width + px] = escape(x0 + px * step, ci, iters);
  }
  return out;
}

function escape(cr, ci, iters) {
  let zr = 0;
  let zi = 0;
  let n = 0;
  while (n < iters) {
    const zr2 = shr16(zr * zr);
    const zi2 = shr16(zi * zi);
    if (zr2 + zi2 > 4 * ONE) break;
    zi = shr16(2 * zr * zi) + ci;
    zr = zr2 - zi2 + cr;
    n += 1;
  }
  return n;
}

// The palette: a cycle of 64 counts through five colours, and black for a
// point that never escaped.
const STOPS = [
  [0, 0, 7, 100],
  [41, 32, 107, 203],
  [107, 237, 255, 255],
  [164, 255, 170, 0],
  [219, 0, 2, 0],
  [256, 0, 7, 100],
];

export function palette() {
  const out = new Uint8Array(1024);
  for (let n = 0; n < 256; n += 1) {
    let rgb = [0, 0, 0];
    if (n < DRAW_ITERS) {
      const at = (n * 4) % 256;
      const i = STOPS.findIndex((s, k) => k + 1 < STOPS.length && at >= s[0] && at < STOPS[k + 1][0]);
      const [a, b] = [STOPS[i], STOPS[i + 1]];
      const num = at - a[0];
      const den = b[0] - a[0];
      rgb = [1, 2, 3].map((c) => Math.floor((a[c] * (den - num) + b[c] * num) / den));
    }
    out.set([rgb[2], rgb[1], rgb[0], 0], n * 4);
  }
  return out;
}

export function bmpHeader(width, height) {
  const b = new Uint8Array(HEADER_BYTES);
  const d = new DataView(b.buffer);
  b.set([66, 77]);
  d.setUint32(2, HEADER_BYTES + width * height, true);
  d.setUint32(10, HEADER_BYTES, true);
  d.setUint32(14, 40, true);
  d.setInt32(18, width, true);
  d.setInt32(22, -height, true);
  d.setUint16(26, 1, true);
  d.setUint16(28, 8, true);
  d.setUint32(34, width * height, true);
  d.setUint32(38, 2835, true);
  d.setUint32(42, 2835, true);
  d.setUint32(46, 256, true);
  b.set(palette(), 54);
  return b;
}

// The whole drawing: each strip's file size and hash (what its job row
// shows), the picture's name and bytes.
export function expectedPicture(params) {
  const { width, height, strips } = stripsOf(params);
  const pixels = strips.map(stripPixels);
  const picture = new Uint8Array(HEADER_BYTES + width * height);
  picture.set(bmpHeader(width, height));
  pixels.forEach((p, i) => picture.set(p, HEADER_BYTES + i * p.length));
  return {
    strips: pixels.map((p) => ({ text: `done: ${HEADER_BYTES + p.length}-byte strip, hash ${hex(fnv(p))}`, hash: fnv(p) })),
    name: `mandelbrot-${width}x${height}.bmp`,
    picture,
  };
}

// `node worker-lab-reference.mjs WORKLOAD JOBS WEIGHT`: print a run's
// expected answers, for writing specs.
if (import.meta.url === `file://${process.argv[1]}`) {
  const [workload, jobs, weight] = process.argv.slice(2);
  if (workload === "draw") {
    const { createHash } = await import("node:crypto");
    const r = expectedPicture({ jobs: Number(jobs), weight: Number(weight) });
    r.strips.forEach((s, i) => console.log(`job ${i + 1}: ${s.text}`));
    let h = FNV_OFFSET;
    for (const s of r.strips) for (const shift of [0, 8, 16, 24]) h = fnvByte(h, (s.hash >>> shift) & 255);
    console.log(`${r.name}, ${r.picture.length} bytes, SHA-256 ${createHash("sha256").update(r.picture).digest("hex")}, checksum ${hex(h)}`);
  } else {
    const r = expectedRun({ workload, jobs: Number(jobs), weight: Number(weight) });
    r.answers.forEach((a, i) => console.log(`job ${i + 1}: ${a ? a.text : "crash"}`));
    console.log(`primes ${r.primes} bytes ${r.bytes} checksum ${r.checksum}`);
  }
}
