// monitor-unit.mjs -- the work monitor's aggregation in Node, driven by
// synthetic transitions on a fake clock: the job timeline and its spans,
// clock conversion, histograms, gauges, peaks and integrals, outcomes and
// teardown, the engine counters' decoding, and every bound (history ring,
// retired instances, tasks, subscribers, timeline entries).
// Usage: node tests/runtime/monitor-unit.mjs
import { WorkMonitor, MONITOR_EDGES, MONITOR_LIMITS } from "../../platform/runtime.mjs";

let failures = 0;
const check = (name, got, want) => {
  const ok = JSON.stringify(got) === JSON.stringify(want);
  if (!ok) failures += 1;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok ? "" : `: got ${JSON.stringify(got)}, want ${JSON.stringify(want)}`}`);
};

const FX_NODE = 0xffffffff;

function make(options = {}, env = {}) {
  const clock = { t: 0 };
  const measures = [];
  const cleared = [];
  const perf = {
    timeOrigin: 1000,
    now: () => clock.t,
    measure: (name, o) => measures.push({ name, ...o }),
    clearMeasures: (name) => cleared.push(name),
  };
  const m = new WorkMonitor(options, { performance: perf, maxWorkers: 2, ...env });
  const events = [];
  m.subscribe((e) => events.push(e));
  m.runtimeMounted();
  return { m, clock, events, measures, cleared };
}

// One job, warm and cold, through a worker whose clock origin is 5 ms after
// the page's: every span, and its conversion.
{
  const { m, clock, events } = make();
  clock.t = 10;
  m.jobIssued(1, "p/a", new Uint8Array(7), 0, false);
  m.jobSubmitted(1);
  clock.t = 11;
  const seq = m.instanceSpawned("worker");
  m.jobPosted(1, seq);
  check("a job on a starting instance is cold", [m.snapshot().pool.busy, m.snapshot().pool.spawning, m.snapshot().pool.queued], [1, 1, 0]);
  clock.t = 20;
  m.instanceReady(seq, { origin: 1005, instStart: 9, instEnd: 10, memBytes: 65536 });
  clock.t = 40;
  // Worker stamps (worker clock): recv 6, begin 16, call 17, ret 30, sent 31.
  m.jobReplied(1, seq, { t: [6, 16, 17, 30, 31], mem: [131072, 4, 100], outputBytes: 3 });
  m.jobAnswered(1, "done", null, new Uint8Array(3));
  clock.t = 42;
  check("an answered job's result turn is timed", m.timesTurn(FX_NODE, 1), true);
  check("a DOM turn is not timed without a turn subscriber", m.timesTurn(5, 1), false);
  m.turn(FX_NODE, 1, 41, 41.5, 42, 9);
  const r = m.snapshot().recent[0];
  check("timeline converted to the page clock", [r.t.recv, r.t.begin, r.t.call, r.t.ret, r.t.sent, r.t.reply, r.t.turnStart, r.t.turnEnd], [11, 21, 22, 35, 36, 40, 41, 42]);
  check("spans of a cold job", r.ms, { held: 0, queue: 1, toWorker: null, cold: 10, stage: 1, compute: 13, copyOut: 1, fromWorker: 4, resultWait: 1, resultTurn: 1, total: 32, prepare: null });
  check("record facts", [r.outcome, r.cold, r.firstJobOnInstance, r.inputBytes, r.outputBytes, r.thread, r.instance], ["done", true, true, 7, 3, "worker", seq]);
  check("no bytes in the record", Object.values(r).some((v) => v instanceof Uint8Array), false);
  check("event order", events.map((e) => e.kind), ["runtime", "job-issue", "instance-spawn", "job-start", "instance-ready", "job-end"]);
  const s = m.snapshot();
  check("instance facts", [s.instances.live[0].state, s.instances.live[0].jobs, s.instances.live[0].memBytes, s.instances.live[0].peakMemBytes, s.instances.live[0].liveAllocs, s.instances.live[0].instantiateMs, s.instances.live[0].scriptAt], ["idle", 1, 131072, 131072, 4, 1, 5]);
  check("busy and alive integrals", [s.pool.busyMs, s.pool.aliveMs], [29, 31]);
  check("histograms count the job", [s.hist.compute.n, s.hist.compute.sum, s.hist.cold.n, s.hist.total.counts[MONITOR_EDGES.indexOf(50)]], [1, 13, 1, 1]);
  check("per task", [s.tasks["p/a"].jobs, s.tasks["p/a"].done, s.tasks["p/a"].inputBytes, s.tasks["p/a"].outputBytes], [1, 1, 7, 3]);

  // A second job is warm and goes straight to running.
  clock.t = 50;
  m.jobIssued(2, "p/a", new Uint8Array(1), 0, false);
  m.jobSubmitted(2);
  m.jobPosted(2, seq);
  m.jobReplied(2, seq, { t: [46, 46, 46, 47, 47], mem: [131072, 4, 100], outputBytes: 1 });
  m.jobAnswered(2, "done", null, null);
  m.turn(FX_NODE, 2, 50, 50, 50, 0);
  const w = m.snapshot().recent[1];
  check("a warm job: cold 0, transit measured", [w.cold, w.firstJobOnInstance, w.ms.cold, w.ms.toWorker], [false, false, 0, 1]);

  // A warm job on a busy machine: the worker receives it (page time 61)
  // before the page's thread reports the post (63), and begins a moment
  // after receiving it (62). The post keeps the reading the pool took
  // before posting (60), so transit is not negative, and a warm job's stage
  // starts at receipt, so the spans still add up to the total.
  clock.t = 60;
  m.jobIssued(3, "p/a", new Uint8Array(1), 0, false);
  m.jobSubmitted(3);
  const postedAt = m.tick();
  clock.t = 63;
  m.jobPosted(3, seq, "work", null, postedAt);
  clock.t = 64;
  // Worker stamps (worker clock, 5 ms behind): recv 56, begin 57, call 57, ret 58, sent 58.
  m.jobReplied(3, seq, { t: [56, 57, 57, 58, 58], mem: [131072, 4, 100], outputBytes: 1 });
  m.jobAnswered(3, "done", null, null);
  m.turn(FX_NODE, 3, 65, 65, 66, 0);
  const b = m.snapshot().recent[2];
  check("a post reported late keeps the pool's reading", [b.t.post, b.t.recv, b.ms.toWorker], [60, 61, 1]);
  check("a warm job's stage starts when the worker receives it", [b.t.begin, b.ms.stage], [62, 1]);
  const parts = ["held", "queue", "toWorker", "cold", "stage", "compute", "copyOut", "fromWorker", "resultWait", "resultTurn"].reduce((a, k) => a + (b.ms[k] ?? 0), 0);
  check("the spans add up to the total", [parts, b.ms.total], [6, 6]);
}

// Bins: a value on an edge goes to the bucket above it.
{
  const { m, clock } = make();
  for (const [id, compute] of [[1, 0.05], [2, 0.1], [3, 9.99], [4, 20000]]) {
    m.jobIssued(id, "p", new Uint8Array(0), 0, false);
    m.jobSubmitted(id);
    const seq = id === 1 ? m.instanceSpawned("page") : 1;
    if (id === 1) m.instanceReady(seq, { origin: 1000, instStart: 0, instEnd: 0, memBytes: 0 });
    m.jobPosted(id, seq);
    m.jobReplied(id, seq, { t: [clock.t, clock.t, 0, compute, compute], mem: [0, 0, 0], outputBytes: 0 });
    m.jobAnswered(id, "done", null, null);
    m.turn(FX_NODE, id, 0, 0, 0, 0);
  }
  const h = m.snapshot().hist.compute;
  check("histogram buckets", [h.counts[0], h.counts[1], h.counts[MONITOR_EDGES.indexOf(10)], h.counts[MONITOR_EDGES.length], h.min, h.max], [1, 1, 1, 1, 0.05, 20000]);
}

// Queue and peaks: two instances, four jobs; cancel one queued, one running.
{
  const { m, clock, events } = make();
  const a = m.instanceSpawned("worker");
  const b = m.instanceSpawned("worker");
  for (const id of [1, 2, 3, 4]) {
    m.jobIssued(id, "p", new Uint8Array(0), 0, false);
    m.jobSubmitted(id);
  }
  m.jobPosted(1, a);
  m.jobPosted(2, b);
  clock.t = 10;
  let s = m.snapshot();
  check("two busy, two queued; peaks", [s.pool.busy, s.pool.queued, s.pool.peak.queued, s.pool.peak.instances], [2, 2, 4, 2]);
  check("queued integral", s.pool.queuedMs, 20);
  m.jobCancelled(4);
  m.instanceEnded(b, "cancel");
  m.jobCancelled(2);
  s = m.snapshot();
  const two = s.recent.find((r) => r.id === 2);
  const four = s.recent.find((r) => r.id === 4);
  check("cancelled while queued", [four.outcome, four.phase, four.cancelledBy], ["cancelled", "queued", "engine"]);
  check("cancelled while starting; its time wasted", [two.phase, s.jobs.wastedMs], ["starting", 10]);
  const ends = events.filter((e) => e.kind === "instance-end" || (e.kind === "job-end" && e.id === 2)).map((e) => e.kind);
  check("instance-end before the job's job-end", ends, ["instance-end", "job-end"]);
  check("terminations by cause", s.instances.ended.cancel, 1);
  const c = m.instanceSpawned("worker");
  check("a respawn beyond the peak", m.snapshot().instances.respawns, 1);
  m.jobPosted(3, c);
  // Deadline: the instance ends first, then the job is answered Timeout.
  clock.t = 15;
  m.instanceEnded(c, "deadline");
  m.jobAnswered(3, "timeout", null, null);
  m.turn(FX_NODE, 3, 15, 15, 15, 0);
  s = m.snapshot();
  check("deadline: outcome and cause", [s.jobs.timeout, s.instances.ended.deadline, s.recent.find((r) => r.id === 3).outcome], [1, 1, "timeout"]);
}

// Lost, unavailable, held.
{
  const { m } = make();
  m.jobIssued(1, "p", new Uint8Array(0), 0, false);
  m.jobSubmitted(1);
  m.jobAnswered(1, "unavailable", "unavailable", null);
  m.turn(FX_NODE, 1, 0, 0, 0, 0);
  m.jobIssued(2, "p", new Uint8Array(0), 0, true);
  m.jobCancelled(2);
  const s = m.snapshot();
  check("unavailable: answered from the queue", [s.jobs.unavailable, s.pool.queued, s.recent[0].fault], [1, 0, "unavailable"]);
  check("a held job cancelled", [s.recent[1].phase, s.recent[1].outcome], ["held", "cancelled"]);
}

// Teardown: every job and instance ends with the teardown's cause, then the
// runtime event; nothing after it until a new mount.
{
  const { m, events } = make();
  const a = m.instanceSpawned("worker");
  m.instanceReady(a, { origin: 1000, instStart: 0, instEnd: 0, memBytes: 0 });
  m.jobIssued(1, "p", new Uint8Array(0), 0, false);
  m.jobSubmitted(1);
  m.jobPosted(1, a);
  m.jobIssued(2, "p", new Uint8Array(0), 0, true);
  m.runtimeEnding("contained");
  m.jobCancelled(1);
  m.instanceEnded(a, "cancel");
  m.runtimeEnded("poisoned", { class: "app_crash", message: "x" });
  m.jobIssued(3, "p", new Uint8Array(0), 0, false);
  const tail = events.slice(-4).map((e) => [e.kind, e.cause ?? e.record?.cancelledBy ?? e.state]);
  check("poison: jobs and instances end contained, then runtime", tail, [["job-end", "contained"], ["instance-end", "contained"], ["job-end", "contained"], ["runtime", "poisoned"]]);
  check("nothing reported after poison", [m.snapshot().jobs.issued, m.snapshot().state], [2, "poisoned"]);
  m.runtimeMounted();
  check("a recovered runtime is a new generation", [m.snapshot().generation, m.snapshot().state], [2, "mounted"]);
}

// Engine counters: decoded from a record of at least 40 counters, else null.
{
  const counters = Array.from({ length: 40 }, (_, i) => BigInt(i));
  const { m } = make({}, { page: () => ({ memBytes: 1, liveAllocs: 2, liveBytes: 3, counters }) });
  check("engine counters 32-39", m.snapshot().engine, { issued: 32, delivered: 33, stale: 34, refused: 35, cancelled: 36, reparented: 37, skipped: 38, live: 39 });
  check("page figures", m.snapshot().page, { memBytes: 1, liveAllocs: 2, liveBytes: 3, turns: 30 });
  const short = make({}, { page: () => ({ memBytes: 1, liveAllocs: 2, liveBytes: 3, counters: counters.slice(0, 32) }) });
  check("a 32-counter record has no engine counters", short.m.snapshot().engine, null);
}

// Bounds.
{
  const { m } = make({ history: 4 });
  for (let id = 1; id <= 10; id += 1) {
    m.jobIssued(id, `p${id}`, new Uint8Array(0), 0, true);
    m.jobCancelled(id);
  }
  const s = m.snapshot();
  check("history ring: the newest 4, 6 dropped", [s.recent.map((r) => r.id), s.recentDropped], [[7, 8, 9, 10], 6]);
  for (let i = 0; i < 20; i += 1) m.instanceEnded(m.instanceSpawned("worker"), "fault", { class: "app_crash", message: "m" });
  const t = m.snapshot();
  check("retired ring", [t.instances.retired.length, t.instances.retiredDropped, t.instances.retired[0].seq], [MONITOR_LIMITS.retired, 4, 5]);
  for (let id = 100; id < 200; id += 1) {
    m.jobIssued(id, `q${id}`, new Uint8Array(0), 0, true);
    m.jobCancelled(id);
  }
  const names = Object.keys(m.snapshot().tasks);
  check("tasks bounded; the rest under *", [names.length, names.includes("*")], [MONITOR_LIMITS.tasks + 1, true]);
  let threw = false;
  try {
    for (let i = 0; i < MONITOR_LIMITS.subscribers; i += 1) m.subscribe(() => {});
  } catch (_) {
    threw = true;
  }
  check("a 17th subscriber throws", threw, true);
  let bad = false;
  try {
    new WorkMonitor({ history: 2000 });
  } catch (_) {
    bad = true;
  }
  check("a history beyond the limit throws", bad, true);
  m.reset();
  check("reset clears the window", [m.snapshot().recent.length, m.snapshot().jobs.issued], [0, 0]);
}

// User Timing: named spans with details, and the timeline bound.
{
  const { m, measures, cleared } = make({ userTiming: true });
  const a = m.instanceSpawned("worker");
  m.instanceReady(a, { origin: 1000, instStart: 0, instEnd: 1, memBytes: 0 });
  for (let id = 1; id <= 300; id += 1) {
    m.jobIssued(id, "p/u", new Uint8Array(0), 0, false);
    m.jobSubmitted(id);
    m.jobPosted(id, a);
    m.jobReplied(id, a, { t: [0, 0, 0, 0, 0], mem: [0, 0, 0], outputBytes: 0 });
    m.jobAnswered(id, "done", null, null);
    m.turn(FX_NODE, id, 0, 0, 0, 0);
  }
  check("span names", [...new Set(measures.map((x) => x.name))].sort(), ["roc:work p/u", "roc:work.queue", "roc:work.result", "roc:work.run", "roc:worker 1 spawn"]);
  check("details", measures.find((x) => x.name === "roc:work p/u").detail.outcome, "done");
  check("the timeline is cleared at its bound", [cleared.length > 0, measures.length > MONITOR_LIMITS.timeline], [true, true]);
}

// A throwing listener is unsubscribed; a turn subscriber gets turns.
{
  const { m } = make();
  const seen = [];
  const errors = console.error;
  console.error = () => {};
  m.subscribe(() => {
    throw new Error("x");
  });
  m.subscribe((e) => seen.push(e.kind), { turns: true });
  check("timed with a turn subscriber", m.timesTurn(3, 1), true);
  m.turn(3, 1, 0, 1, 3, 5);
  m.turn(3, 1, 0, 1, 3, 5);
  m.runtimeMounted();
  console.error = errors;
  check("turn events delivered; the throwing listener gone", [seen, m.subs.length], [["turn", "turn", "runtime"], 2]);
}

console.log(failures === 0 ? "== monitor unit: all pass" : `== monitor unit: ${failures} failures`);
process.exit(failures === 0 ? 0 : 1);
