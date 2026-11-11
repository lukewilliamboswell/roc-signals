// The Status Page's port handlers: a simulated live metrics stream, the
// example's own JavaScript. The platform's runtime knows nothing of it; the
// page that mounts the app passes this module's default export as the
// `ports` option of mountRocEngineApp, and the runtime checks it against
// the ports Latency.roc registers before the app starts.
//
// `latency` is a subscription (delivery `Every(16)`): a reading of each
// service's p95 latency every TICK_MS, one message per reading, in the
// order measured. `disconnect` is a command: the stream loses its
// connection for a while and then replays what it buffered.
//
// What a reading says is a pure function of the seed and its sequence
// number, so a seed always tells the same story; only which sequence
// numbers a page sees depends on the clock (a page hidden or paused for ten
// seconds misses ten seconds of the stream, as it would a real one). The
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

// The live streams of this page, so `disconnect` reaches each of them.
const streams = new Set();

// Each seed's stream began once, when the page first subscribed to it, and
// runs on its own clock from then: a new subscription (after a pause, a
// hidden page or a reconnect) joins it at the current reading, so sequence
// numbers only ever go up and the time away is a gap, as with a real feed.
const clocks = new Map();

function startStream(seed, emit) {
  if (!clocks.has(seed)) clocks.set(seed, { origin: performance.now(), epoch: Date.now() });
  const { origin, epoch } = clocks.get(seed);
  let next = Math.floor((performance.now() - origin) / TICK_MS); // the next sequence number to measure
  const buffer = [];
  let dropped = 0;
  let offline = 0; // until this time (performance.now), the connection is down
  let frame = 0;

  const measure = () => {
    const due = Math.floor((performance.now() - origin) / TICK_MS);
    for (; next <= due; next += 1) {
      buffer.push({ seq: next, at_ms: String(epoch + next * TICK_MS), p95_ms: p95(seed, next) });
      if (buffer.length > BUFFER) {
        buffer.shift();
        dropped += 1;
      }
    }
  };

  // Offer the buffer in order until the page refuses or it is empty.
  const offer = () => {
    frame = 0;
    if (performance.now() < offline) return;
    while (buffer.length > 0) {
      if (!emit({ ...buffer[0], dropped })) {
        frame = requestAnimationFrame(offer);
        return;
      }
      buffer.shift();
    }
  };

  const tick = () => {
    measure();
    if (frame === 0) offer();
  };
  const timer = setInterval(tick, TICK_MS);
  tick();

  const stream = {
    disconnect(seconds) {
      offline = performance.now() + seconds * 1000;
    },
    stop() {
      clearInterval(timer);
      if (frame !== 0) cancelAnimationFrame(frame);
      streams.delete(stream);
    },
  };
  streams.add(stream);
  return stream;
}

export default {
  [`${NS}/latency`]: {
    subscribe: ({ seed }, { emit }) => startStream(seed, emit).stop,
  },
  [`${NS}/disconnect`]: {
    command: ({ seconds }) => {
      for (const stream of streams) stream.disconnect(seconds);
    },
  },
};
