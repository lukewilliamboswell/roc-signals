// The Status Page's simulated service: four service checks and an incident
// feed whose answers walk through a scripted outage and recovery.
//
// This is the example's own JavaScript, not the platform's or the site's.
// Its default export follows the contract every example backend keeps
// (www/data/examples.toml, `backend`): `createBackend()` returns
// `handle({ method, uri, headers, body, signal })`, which answers
// `{ status, body, headers }` (or a promise of one) for a request it serves,
// rejects for a network failure, and returns null for any other URI so the
// caller sends that request on to the real network. The site's site.mjs
// turns it into the mount's `fetch`; the browser soak serves it over HTTP.
//
// House rules: no `Math.random()`, no wall-clock input. The backend owns a
// small counter that advances once per request, so successive requests tell
// the same story every time. Payload formats are copied from the literal
// payloads in the example's `specs/*.scm`, the ground truth the Roc parse
// functions were written against.

// Answers settle after a short delay so loading state is visible; an abort
// (the request cancelled) rejects at once.
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

const plain = (status, body) => ({ status, body, headers: { "content-type": "text/plain; charset=utf-8" } });

function failWith(message, options) {
  return settle(null, options).then(() => {
    throw new Error(message);
  });
}

// Index into a scripted list, holding the last entry once the story has settled.
function stage(script, index) {
  return script[Math.min(index, script.length - 1)];
}

// GET /api/status/{api,web,database,notifications,incidents}. A per-service
// counter advances each script independently; each request is a new round.
//
// Wire formats (see parse_check and parse_feed in Status.roc):
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

const PREFIX = "/api/status/";

export default function createBackend() {
  const rounds = new Map();
  return function statusPageHandler({ method = "GET", uri, signal }) {
    if (!String(uri).startsWith(PREFIX)) return null;
    if (method !== "GET") return plain(405, "method not allowed");
    const name = String(uri).slice(PREFIX.length);
    const script = name === "incidents" ? statusFeed : statusChecks[`check:${name}`];
    if (!script) return plain(404, "unknown status service");
    const round = rounds.get(name) ?? 0;
    rounds.set(name, Math.min(round + 1, script.length - 1));
    const entry = stage(script, round);
    if (entry && typeof entry === "object" && entry.fail) return failWith(entry.fail, { signal });
    return settle(plain(200, entry), { signal });
  };
}
