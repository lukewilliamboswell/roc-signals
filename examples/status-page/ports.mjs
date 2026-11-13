// The Status Page's port handlers: a simulated live metrics stream, the
// example's own JavaScript. The platform's runtime knows nothing of it; the
// page that mounts the app passes this module's default export as the
// `ports` option of mountRocEngineApp, and the runtime checks it against
// the ports Latency.roc registers before the app starts.
//
// `latency` is a subscription (delivery `Every(16)`): a reading of each
// service's p95 latency every TICK_MS, one message per reading, in the
// order measured. `drop` is a command: the stream ends, leaving retry to Roc.
//
// What a reading says is a pure function of the seed and its sequence
// number, so a seed always tells the same story; only which sequence
// numbers a page sees depends on the clock. A reconnect asks after the last
// sequence Roc kept: a short pause replays every reading, and a pause
// beyond the server's 64-reading history reports the missing gap. The
// story repeats every CYCLE readings: about fifteen seconds in, the API's
// p95 climbs far past its 300 ms objective, the database follows a little,
// and both recover ten seconds later.
//
// Pacing and backpressure. The stream measures on a fixed tick and puts
// each reading in its own buffer, then offers the buffer to the page in
// order. `emit` answers false when the page's subscription already holds
// 16 readings it has not delivered: the stream stops offering and tries
// again on the next animation frame, so a burst (a replay after a lost
// connection, or catching up after the page's thread was blocked) reaches
// the page at most 16 readings a frame, each its own turn, and nothing is
// lost while the page keeps up. The buffer holds at most BUFFER readings;
// beyond that the oldest is dropped and counted, and every reading carries
// the count (`dropped`). The runtime's monitor counts the refused emits.
//
// The stream stops when its subscription ends: the page hidden, the reader
// pausing, or the app gone all call the function `subscribe` returns.
const NS = "roc-signals.example/status-page";
const TICK_MS = 250;
const BUFFER = 64;
const CYCLE = 160;
const INCIDENT = { start: 60, rise: 8, hold: 24, fall: 8 };

// mulberry32 over (seed, seq, salt): one deterministic number in [0, 1).
function noise(seed, seq, salt) {
  let a = (seed ^ Math.imul(seq + 1, 0x9e3779b1) ^ Math.imul(salt + 1, 0x85ebca77)) >>> 0;
  a = (a + 0x6d2b79f5) >>> 0;
  let t = a;
  t = Math.imul(t ^ (t >>> 15), t | 1);
  t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
  return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
}

// How far into the incident a sequence number is, from 0 (calm) to 1 (worst).
function severity(seq) {
  const at = (seq % CYCLE) - INCIDENT.start;
  if (at < 0) return 0;
  if (at < INCIDENT.rise) return at / INCIDENT.rise;
  if (at < INCIDENT.rise + INCIDENT.hold) return 1;
  const falling = at - INCIDENT.rise - INCIDENT.hold;
  return falling < INCIDENT.fall ? 1 - falling / INCIDENT.fall : 0;
}

// Each service's p95 for one reading, in whole milliseconds. Every value
// stays between 100 and 999, so a figure's digits never change its width.
export function p95(seed, seq) {
  const s = severity(seq);
  const around = (base, spread, salt) => base + Math.round((noise(seed, seq, salt) - 0.5) * 2 * spread);
  return {
    api: around(140, 25, 1) + Math.round(s * 640),
    web: around(150, 20, 2),
    database: around(115, 10, 3) + Math.round(s * 90),
    notifications: around(190, 30, 4),
  };
}

// This EventSource-shaped simulation opens one connection. The port adapter
// below closes on error; it never reconnects. Roc owns retry and resume.
const streams = new Set();
const clocks = new Map();

class SimulatedEventSource {
  constructor({ seed, after }) {
    if (!clocks.has(seed)) clocks.set(seed, { origin: performance.now(), epoch: Date.now() });
    const { origin, epoch } = clocks.get(seed);
    this.closed = false;
    this.buffer = [];
    this.dropped = 0;
    this.frame = 0;
    // The server keeps the newest BUFFER readings. A short outage can be
    // replayed whole; an older cursor reports exactly the unavailable gap.
    const due = Math.floor((performance.now() - origin) / TICK_MS) + 1;
    let next = Math.max(after + 1, due - BUFFER + 1);
    this.dropped = Math.max(0, next - after - 1);
    this.flush = () => {
      this.frame = 0;
      if (this.closed) return;
      while (this.buffer.length) {
        if (!this.onmessage?.({ data: { ...this.buffer[0], dropped: this.dropped } })) {
          this.frame = requestAnimationFrame(this.flush);
          return;
        }
        this.buffer.shift();
      }
    };
    const tick = () => {
      const current = Math.floor((performance.now() - origin) / TICK_MS) + 1;
      for (; next <= current; next += 1) {
        this.buffer.push({ seq: next, at_ms: String(epoch + next * TICK_MS), p95_ms: p95(seed, next) });
        if (this.buffer.length > BUFFER) {
          this.buffer.shift();
          this.dropped += 1;
        }
      }
      if (!this.frame) this.flush();
    };
    this.timer = setInterval(tick, TICK_MS);
    // Handlers are installed before the first event, as with EventSource.
    queueMicrotask(() => {
      if (this.closed) return;
      this.onopen?.();
      tick();
    });
    streams.add(this);
  }

  close() {
    if (this.closed) return;
    this.closed = true;
    clearInterval(this.timer);
    if (this.frame) cancelAnimationFrame(this.frame);
    this.buffer.length = 0;
    streams.delete(this);
  }

  drop() {
    this.onerror?.(new Error("connection dropped"));
  }
}

export default {
  [`${NS}/latency`]: {
    subscribe: ({ seed, after }, { emit, close }) => {
      const source = new SimulatedEventSource({ seed, after });
      source.onopen = () => emit("Opened");
      source.onmessage = ({ data }) => emit({ Event: data });
      source.onerror = (error) => {
        // Real EventSource also reconnects automatically unless closed here.
        source.close();
        close(error);
      };
      return () => source.close();
    },
  },
  [`${NS}/drop`]: {
    command: () => {
      for (const source of streams) source.drop();
    },
  },
};
