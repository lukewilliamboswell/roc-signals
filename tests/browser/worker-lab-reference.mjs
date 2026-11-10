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

// `node worker-lab-reference.mjs WORKLOAD JOBS WEIGHT`: print a run's
// expected answers, for writing specs.
if (import.meta.url === `file://${process.argv[1]}`) {
  const [workload, jobs, weight] = process.argv.slice(2);
  const r = expectedRun({ workload, jobs: Number(jobs), weight: Number(weight) });
  r.answers.forEach((a, i) => console.log(`job ${i + 1}: ${a ? a.text : "crash"}`));
  console.log(`primes ${r.primes} bytes ${r.bytes} checksum ${r.checksum}`);
}
