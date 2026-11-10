+++
title = "Monitoring Workers"
description = "Where a worker job's time goes, how busy the pool is, and what workers cost, from the runtime's monitor."
weight = 12
template = "page.html"
+++

# Monitoring Workers

A `Work` request runs a registered pure program in a Web Worker (see
[Effects and the Browser](@/docs/effects-and-browser.md)). The runtime's
**monitor** shows what that costs: where each job's time went, how busy the
pool is, what cancellations, deadlines and crashes cost, and how much memory
the worker instances hold. It only observes. Turning it on or subscribing to
it never changes which job runs when, what it returns or what the app sees.

Everything here is JavaScript run by the page that mounts the app (its
`index.html`, a test harness or a benchmark). The app itself needs nothing.

## Turning it on

Every runtime has a monitor, `runtime.monitor`, and it is always counting.
The `monitor` mount option only sets what it keeps and how loudly it reports:

```js
const runtime = await mountRocEngineApp({
  wasmUrl: "app.wasm",
  root: document.getElementById("app"),
  monitor: {
    history: 128,      // job records kept for snapshot().recent (0 to 1024)
    userTiming: false, // add performance.measure entries for DevTools
    payloads: false,   // copy input and output bytes into events
  },
});
```

The monitor has three surfaces:

- `runtime.monitor.snapshot()` returns plain data you can log, `console.table`
  or `JSON.stringify`.
- `runtime.monitor.subscribe(listener, { turns })` reports lifecycle events
  as they happen and returns the function that unsubscribes.
- `runtime.monitor.reset()` starts a new measurement window.

## The timeline of a job

The monitor stamps each job at every step from the request to its applied
result, and turns those stamps into spans. The spans add up to the job's
`total`:

| Span | From → to | What it is |
|---|---|---|
| `held` | issued → handed to the pool | Manual mode or `manualWork` only: waiting for `runEffect` |
| `queue` | handed to the pool → posted | Waiting for a free worker |
| `cold` | posted → instance ready | Starting a worker: its script and its instance. 0 for a warm worker |
| `toWorker` | posted → received | The message reaching a warm worker (`null` when cold) |
| `stage` | ready → staged | Copying the input into the worker's instance, and reading the [files](@/docs/files.md) it names |
| `compute` | staged → returned | The program itself (`work()`) |
| `copyOut` | returned → posted back | Copying the output out of the instance |
| `fromWorker` | posted back → received by the page | The message coming back |
| `resultWait` | received → result turn starts | The page was busy with another turn |
| `resultTurn` | result turn | The app's reaction and the DOM it changed |

A job's deadline runs from the moment the request is performed, so it covers
queueing and cold start as well as compute. A held job (manual mode, or the
`manualWork` mount option) has no deadline timer: a spec's time is manual,
and `expireEffect(id)` expires it instead.

For a job whose input holds files, the record's `readMs` is the part of
`stage` spent reading them into the instance, and its `fileBytes` how many
bytes that was; `inputBytes` counts the payload alone, which refers to the files
but does not carry them.

`firstJobOnInstance` marks a worker's first job. That job's `compute` also
pays for the browser compiling the program's code the first time it runs, so
compare later jobs when you judge a program's speed.

### Clocks

Every time the monitor reports is the page's `performance.now()` in
milliseconds. That is the clock User Timing, `PerformanceObserver` and the
DevTools Performance panel use. A worker has its own clock. When its instance
is ready it reports its `performance.timeOrigin`, and the monitor converts its
stamps by adding the difference between the two origins.

Browsers coarsen timers: in Chrome to 0.1 ms when the page is not
cross-origin isolated. So a span between two threads (`toWorker`,
`fromWorker`) is good to about ±0.2 ms. Spans are reported raw, never clamped,
and one shorter than the resolution may read 0 or even slightly negative.

## The snapshot

```js
const s = runtime.monitor.snapshot();
console.table(s.recent.map((j) => ({ id: j.id, program: j.program, outcome: j.outcome, ...j.ms })));
```

| Field | Meaning |
|---|---|
| `mode` | `"workers"`, `"inline"` (the page's thread) or `"unavailable"` (no `Worker`) |
| `pool` | `instances`, `spawning`, `idle`, `busy` (holding a job, starting ones included) and `queued`, now; their `peak`; and the time integrals `busyMs`, `aliveMs`, `queuedMs` |
| `jobs` | Counts by outcome (`done`, `lost`, `timeout`, `cancelled`, `unavailable`); `inFlight`; `wastedMs` (time on instances by jobs that never delivered output); input and output bytes; `lateReplies` (always 0 in a healthy pool); for prepared programs, `prepared` (queries that prepared a state), `reused` (queries answered from a kept state) and `prepareMs` (total preparation time) |
| `instances` | `spawns`, `respawns` (spawns beyond the most instances ever live at once), `ended` by cause (`cancel`, `deadline`, `fault`, `executor`, `unmount`, `contained`, and `retired` for a worker over `maxWorkerBytes`), `evicted`: prepared states let go by cause (`replaced` by another preparation, `files` before a job that reads files, `released` with their file), and the `live` and `retired` instances: thread, state, spawn and ready times, instantiation time, jobs served, busy time, linear memory and its peak, the host's live allocations and bytes, and `held`, the name of the preparation whose state it keeps (or `null`) |
| `hist` | Histograms of `queue`, `cold`, `compute`, `total`, `resultTurn` and `prepare`, in fixed 1-2-5 millisecond buckets (`edges`, `counts`, `n`, `sum`, `min`, `max`) |
| `programs` | Per program: jobs, outcomes, bytes, and `queue`, `compute` and `total` histograms |
| `recent` | The last `history` job records, with every stamp (`t`) and span (`ms`). A prepared query's record says whether it `prepared` (`"prepare"`) or reused a kept state (`"reuse"`; `null` for other programs), and `prepareMs`, how long preparing took (also `ms.prepare`; `null` when it reused); `compute` is then the query alone. `finished` is true for a cancelled query whose `Finish` policy let it complete |
| `page` | The page instance's linear memory, live allocations and bytes, and turns |
| `engine` | The engine's effect counters, when the engine's work record carries them; otherwise `null` |
| `ports` | Per [port](@/docs/ports.md) the app used, by name: `sent` (commands), `calls`, `answered`, `threw`, `timedOut`, `cancelled` (stopped by the app or by teardown), `subscribed`, `messages` (delivered to the app), `coalesced` (replaced under `Latest` before delivery), `refusedEmits` (`emit` returned `false` under `Every(n)`), `tooLarge`, `closed` (ended by the JavaScript), and `faults` (failures of command handlers and unsubscribe functions, which the app never sees). Counted by the runtime since mount; at most one entry per declared port, so at most 64 |

Some useful figures:

- **Utilisation** is `pool.busyMs / pool.aliveMs`.
- **Mean queue length** is `pool.queuedMs / (s.at - s.since)`.
- **Overhead** is `1 - compute / total`. A job whose overhead dominates is
  too small to send to a worker.

Memory figures are each instance's linear memory, which only grows, and the
host's allocation counters. The browser's whole-process memory API needs
cross-origin isolation, which the platform does not require, so compiled
code and worker threads are not included.

A job refused at the engine's in-flight cap never reaches the pool, so the
pool cannot see it. When `engine` is present, `engine.refused` counts it.

## Events

```js
const stop = runtime.monitor.subscribe((e) => console.log(e.kind, e));
```

| Kind | Fields |
|---|---|
| `job-issue` | `id`, `program`, `inputBytes`, `deadlineMs`, `held`, `at` (and `input` with `payloads`) |
| `job-start` | `id`, `instance`, `cold`, `at` |
| `job-end` | `id`, `program`, `outcome`, `at`, `record` (the full job record; and `output` with `payloads`) |
| `instance-spawn` | `instance`, `thread` (`"worker"` or `"page"`), `at` |
| `instance-ready` | `instance`, `scriptAt`, `instantiateMs`, `memBytes`, `liveAllocs` (before any job), `at` |
| `instance-end` | `instance`, `cause`, `fault` (`{ class, message }` or `null`), `jobs`, `busyMs`, `memBytes`, `at` |
| `state-evict` | `instance`, `prep` (the preparation's name), `cause` (`replaced`, `files`, `released`), `at` |
| `turn` | `node`, `handler`, `fx` (the job id for a job's result turn), `eventMs`, `applyMs`, `bytes`, `at`. Only for subscribers that pass `{ turns: true }` |
| `runtime` | `state` (`mounted`, `poisoned`, `unmounted`), `generation`, `fault`, `at` |

What a listener can rely on:

- Events arrive synchronously as things happen, and `at` never goes backwards.
- Each issued job gets exactly one `job-end`. A `job-start`, if there is one,
  comes between the two.
- Each instance gets `instance-spawn`, then `instance-ready` if it ever
  becomes ready, then exactly one `instance-end`. No job starts on an
  instance before it was spawned.
- A job that delivers a result (`done`, `lost`, `timeout`, `unavailable`)
  ends after its result turn has been applied. A cancelled job ends when it
  is cancelled, with `record.phase` (`held`, `queued`, `starting`,
  `running`) and `record.cancelledBy` (`engine`, `unmount`, `contained`).
- A cancelled query whose policy is `Finish` ends at once as `cancelled`
  with `record.finished`, but its instance stays busy until the job
  completes.
- When stopping a job terminates its worker (cancel, deadline, fault), the
  `instance-end` comes before that job's `job-end`.
- When the page's runtime is poisoned or unmounted, every job and instance
  still live ends with that cause, then the `runtime` event follows. Nothing
  more is reported until `recover()` mounts a new generation.

A listener must only observe: it may call `snapshot()`, but not drive the
runtime. A listener that throws is reported on the console and unsubscribed.
At most 16 listeners can subscribe.

## DevTools and User Timing

With `userTiming: true` the monitor adds `performance.measure` entries, so
jobs show up in the DevTools Performance panel and in any
`PerformanceObserver`, with no custom tooling:

- `roc:work <program>`: a job from issue to its applied result. Its `detail`
  carries the id, instance, outcome and byte sizes.
- `roc:work.queue`, `roc:work.cold`, `roc:work.run` (posted until the reply
  arrives) and `roc:work.result`: the job's phases.
- `roc:work.prepare`: a prepared query's preparation, drawn with the length
  the worker measured, ending where the query's own call starts. When the
  query reads files of its own, the preparation really ran before that
  reading, so the entry is drawn that much late.
- `roc:worker <n> spawn`: a worker starting.
- `roc:work.compute <program>`: added by the worker itself, on its own
  thread.

Each entry's `detail.devtools` asks Chrome to draw it on a "roc workers"
track group.

```js
new PerformanceObserver((list) => {
  for (const m of list.getEntries()) if (m.name.startsWith("roc:work ")) console.log(m.name, m.duration.toFixed(1), m.detail.outcome);
}).observe({ type: "measure" });
```

Each thread keeps at most 1024 of the monitor's entries in its performance
timeline and clears them when it reaches that. Observers and recorded
traces have already received them by then.

## Bounds and cost

Everything the monitor keeps has a bound:

| Kept | Bound | At the bound |
|---|---|---|
| Job records | `history` (default 128, at most 1024) | Oldest overwritten, counted in `recentDropped` |
| Retired instances | 16 | Oldest overwritten, counted in `retiredDropped` |
| Programs | 64, the catalogue's bound | Further names counted under `"*"` |
| Live jobs and instances | The in-flight cap and `maxWorkers` | — |
| Subscribers | 16 | `subscribe` throws |
| Timeline entries | 1024 per thread | Cleared |

**When nobody is looking:**

- A job costs eight clock reads on the page and five in its worker, plus a
  few counter and histogram updates.
- A turn that delivers no job result reads no clock at all.

**When someone is looking:**

- Each event is one object and one call per subscriber.
- `{ turns: true }` adds three clock reads to every turn.
- User Timing adds roughly five measures per job.

## Diagnosing a slow job

A search box sends its filter to a worker. Results feel slow, so the page
logs the last few jobs:

```js
console.table(runtime.monitor.snapshot().recent.map((j) => ({ id: j.id, total: j.ms.total, queue: j.ms.queue, cold: j.ms.cold, compute: j.ms.compute, resultWait: j.ms.resultWait })));
```

The rows show a `total` of about 120 ms, of which `compute` is 8 ms and
`queue` 96 ms. `cold` is 0, and `resultWait` and `resultTurn` are a few
milliseconds. The jobs are not slow; they wait. The pool confirms it:

```js
const { pool, maxWorkers } = runtime.monitor.snapshot();
// maxWorkers 2, pool.peak.busy 2, pool.peak.queued 7, busyMs / aliveMs ≈ 0.97
```

Both workers are busy almost all the time, and up to seven jobs wait behind
them. Each keystroke issues several jobs at once. There are two fixes:

- Issue less: one job per query, or debounce the input.
- Allow more concurrency: raise `maxWorkers`.

After the change, `hist.queue` should collapse into its lowest buckets.

The same table can tell a different story. Suppose `cold` dominates instead,
`instances.respawns` keeps climbing and `instances.ended.cancel` grows with
it. Then jobs are being cancelled while they run: each cancel terminates a
worker, and the next job pays to start a new one. Work is scoped to the site
that issued it, so this means the issuing site is disposed and re-created,
for example inside a `when` that toggles. Issue the work from a site in a
longer-lived scope.
