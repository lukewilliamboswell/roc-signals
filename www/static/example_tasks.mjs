import { createConduitFetch } from "./conduit_backend.mjs";

// --- deterministic HTTP services for the gallery examples -------------------
//
// Native specs supply service responses explicitly. In the browser these
// fetch implementations provide the corresponding scripted examples.
//
// House rules: no `Math.random()`, no wall-clock input. Each backend owns a
// small counter that advances once per request, and the counter indexes a
// scripted progression so that successive polls tell a story — healthy,
// degraded, an incident with updates, a failure, recovery — and then settle on
// a steady final state.
//
// Payload wire formats are copied from the literal payloads in each example's
// `specs/*.scm`, which are the ground truth the Roc parse functions were
// written against.

// Responses settle after a short delay so loading state is visible. Each
// occurrence completes independently unless the mount's abort signal fires.
function settle(value, { signal, delayMs = 140 } = {}) {
  return new Promise((resolve, reject) => {
    if (signal?.aborted) {
      reject(new Error("canceled"));
      return;
    }
    const timer = setTimeout(() => resolve(value), delayMs);
    signal?.addEventListener?.(
      "abort",
      () => {
        clearTimeout(timer);
        reject(new Error("canceled"));
      },
      { once: true },
    );
  });
}

function failWith(message, options) {
  return settle(null, options).then(() => {
    throw new Error(message);
  });
}

// Index into a scripted list, holding the last entry once the story has settled.
function stage(script, index) {
  return script[Math.min(index, script.length - 1)];
}

// --- status-page -------------------------------------------------------------
//
// GET /api/status/{api,web,database,notifications,incidents}. A per-service
// counter advances each script independently; each fetch is a new occurrence.
//
// Wire formats (see parse_check and parse_feed in examples/status-page/Status.roc):
//   check      "operational|99.98"          health | uptime percent
//   incidents  "id~severity~title~hh:mm@body^hh:mm@body#…"   "#" separates incidents
//
// Rounds (one round every 5s while the tab is visible):
//   1  all four services operational, no incidents
//   2  api degrades, inc-42 opens with its first update
//   3  database degrades too, web wobbles, inc-42 gains an update
//   4  the api check itself fails (CheckFailed, distinct from an observed
//      outage), inc-42 gains the rollback update
//   5  api and database recovering, notifications degrade, inc-51 opens
//   6  everything operational again, both incidents resolved
//   7+ settled on the healthy board with the resolved incident history
const statusIncident42 = "inc-42~major~Elevated API error rate~";
const statusIncident51 = "inc-51~minor~Delayed notification delivery~";

const statusChecks = {
  "check:api": [
    "operational|99.98",
    "degraded|97.40",
    "degraded|96.80",
    { fail: "check timed out after 5s" },
    "degraded|98.60",
    "operational|99.21",
    "operational|99.40",
  ],
  "check:web": [
    "operational|99.99",
    "operational|99.99",
    "degraded|98.10",
    "operational|99.95",
    "operational|99.99",
    "operational|99.99",
  ],
  "check:database": [
    "operational|99.90",
    "operational|99.90",
    "degraded|96.00",
    "degraded|97.10",
    "operational|99.72",
    "operational|99.90",
  ],
  "check:notifications": [
    "operational|99.95",
    "operational|99.95",
    "operational|99.95",
    "operational|99.95",
    "degraded|99.20",
    "operational|99.95",
  ],
};

const statusFeed = [
  "",
  `${statusIncident42}10:02@Investigating elevated 5xx responses`,
  `${statusIncident42}10:02@Investigating elevated 5xx responses^10:20@Identified a bad deploy`,
  `${statusIncident42}10:02@Investigating elevated 5xx responses^10:20@Identified a bad deploy^10:45@Rolled back the deploy`,
  `${statusIncident42}10:02@Investigating elevated 5xx responses^10:20@Identified a bad deploy^10:45@Rolled back the deploy^11:05@Monitoring after rollback#${statusIncident51}11:10@Investigating a notification backlog`,
  `${statusIncident42}10:02@Investigating elevated 5xx responses^10:20@Identified a bad deploy^10:45@Rolled back the deploy^11:05@Monitoring after rollback^11:30@Resolved, error rates back to baseline#${statusIncident51}11:10@Investigating a notification backlog^11:34@Resolved, backlog drained`,
];

function createStatusPageFetch() {
  const rounds = new Map();
  return function statusPageFetch(uri, { method = "GET", signal } = {}) {
    if (method !== "GET") return new Response("method not allowed", { status: 405 });
    const name = String(uri).slice("/api/status/".length);
    const script = name === "incidents" ? statusFeed : statusChecks[`check:${name}`];
    if (!script) {
      return new Response("unknown status service", { status: 404 });
    }
    const round = rounds.get(name) ?? 0;
    rounds.set(name, Math.min(round + 1, script.length - 1));
    const entry = stage(script, round);
    if (entry && typeof entry === "object" && entry.fail) {
      return failWith(entry.fail, { signal });
    }
    return settle(new Response(entry), { signal });
  };
}

// --- field-notes -------------------------------------------------------------
//
// POST /api/notes/sync carries the settlement token, "<id>#<rev>", as text.
// Success echoes it. The calling effect retains its own token on failure.
//
// Every third sync request fails, so the outbox demonstrates a failed row and
// the Retry button; retrying mints a new revision, which produces a new token
// and (usually) a clean settlement on the next attempt.
function createFieldNotesFetch() {
  let attempts = 0;
  return async function fieldNotesFetch(uri, options = {}) {
    if ((options.method ?? "GET") !== "POST") return new Response("method not allowed", { status: 405 });
    const token = await new Response(options.body).text();
    const { signal } = options;
    attempts = (attempts + 1) % 3;
    if (attempts === 0) return settle(new Response("sync temporarily unavailable", { status: 503 }), { signal });
    return settle(new Response(token), { signal });
  };
}

// Route each request to the scripted backend for its example. Anything else
// goes to the real network.
export function createPublicExampleFetch(fetchImpl = globalThis.fetch) {
  const conduitFetch = createConduitFetch();
  const statusPageFetch = createStatusPageFetch();
  const fieldNotesFetch = createFieldNotesFetch();
  return async function publicExampleFetch(uri, options = {}) {
    const conduit = conduitFetch(uri, options);
    if (conduit !== null) return conduit;
    if (String(uri).startsWith("/api/status/")) return statusPageFetch(uri, options);
    if (String(uri) === "/api/notes/sync") return fieldNotesFetch(uri, options);
    return fetchImpl(uri, options);
  };
}
