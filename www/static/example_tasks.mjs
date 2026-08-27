import {
  createHttpTaskRouter,
  httpHeaderValue,
  httpJsonResponse,
  httpTaskError,
  httpTextResponse,
} from "./signals.mjs";
import { createConduitTaskHandler } from "./conduit_backend.mjs";

export function createPublicExampleTaskHandler() {
  const opsBackend = createOpsBackend();
  const conduitTaskHandler = createConduitTaskHandler();
  // One backend instance per handler, so each mounted app gets its own scripted
  // sequence starting at the beginning of the story.
  // They are built on first use because the scripted payload tables below are
  // module-level `const`s, and this factory also runs at module evaluation time.
  let namedTaskHandlers = null;
  const namedHandlers = () => {
    if (namedTaskHandlers === null) {
      namedTaskHandlers = [
        createStatusPageBackend(),
        createSupportInboxBackend(),
        createFieldNotesBackend(),
        createOnboardingBackend(),
        createPackageExplorerBackend(),
        createFlightSearchBackend(),
      ];
    }
    return namedTaskHandlers;
  };
  return function publicExampleTaskHandler(args) {
    const lookup = lookupTaskHandler(args);
    if (lookup !== null && lookup !== undefined) {
      return lookup;
    }

    for (const handler of namedHandlers()) {
      const handled = handler(args);
      if (handled !== null && handled !== undefined) {
        return handled;
      }
    }

    const apiConsole = apiRequestConsoleTaskHandler(args);
    if (apiConsole !== null && apiConsole !== undefined) {
      return apiConsole;
    }

    const conduit = conduitTaskHandler(args);
    if (conduit !== null && conduit !== undefined) {
      return conduit;
    }

    return opsApiTaskHandler(args, opsBackend);
  };
}

export const publicExampleTaskHandler = createPublicExampleTaskHandler();

export function createOpsBackend() {
  let sequence = 0;
  return {
    nextSnapshot() {
      sequence += 1;
      return opsSnapshot(sequence);
    },
  };
}

const defaultOpsBackend = createOpsBackend();
const opsRouters = new WeakMap();

export function opsApiTaskHandler({ name, request }, backend = defaultOpsBackend) {
  return opsRouterFor(backend)({ name, request });
}

function opsRouterFor(backend) {
  let router = opsRouters.get(backend);
  if (router) {
    return router;
  }

  router = createHttpTaskRouter({
    "GET /api/ops/dashboard": () => {
      const snapshot = backend.nextSnapshot();
      return httpJsonResponse(snapshot.fields);
    },
    "GET /api/ops/summary": () => {
      const snapshot = backend.nextSnapshot();
      return httpTextResponse(summaryText(snapshot));
    },
    "GET /api/ops/traffic": () => {
      const snapshot = backend.nextSnapshot();
      return httpTextResponse(trafficText(snapshot));
    },
    "GET /api/ops/jobs": () => {
      const snapshot = backend.nextSnapshot();
      return httpTextResponse(jobsText(snapshot));
    },
    "GET /api/ops/alerts": () => {
      const snapshot = backend.nextSnapshot();
      return httpTextResponse(alertsText(snapshot));
    },
    "GET /api/ops/health": () => {
      const snapshot = backend.nextSnapshot();
      return httpTextResponse(healthText(snapshot));
    },
  });
  opsRouters.set(backend, router);
  return router;
}

const apiConsoleRouter = createHttpTaskRouter({
  "POST /api/api-request-console": (req) => {
    const scenario = httpHeaderValue(req.headers, "x-scenario") || "success";
    if (scenario === "failure") {
      throw httpTaskError("network", "offline");
    }

    const missing = scenario === "missing";
    return httpJsonResponse(
      missing
        ? { status: "missing", message: "customer record was not found" }
        : { status: "created", message: "customer-42 is ready" },
      {
        status: missing ? 404 : 201,
        headers: [["x-result", missing ? "missing" : "ok"]],
      },
    );
  },
});

export function apiRequestConsoleTaskHandler(args) {
  return apiConsoleRouter(args);
}

export function lookupTaskHandler({ name, request, signal }) {
  if (name !== "lookup") {
    return null;
  }

  const query = String(request).trim();
  return new Promise((resolve, reject) => {
    if (signal?.aborted) {
      reject(new Error("canceled"));
      return;
    }

    const timer = setTimeout(() => {
      if (query.toLowerCase().includes("fail") || query.toLowerCase().includes("offline")) {
        reject(new Error("offline search index"));
      } else if (query === "") {
        resolve("Type a search term to see matching actions");
      } else {
        resolve(`Top results for "${query}": docs, examples, and release notes`);
      }
    }, 80);

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

function opsSnapshot(sequence) {
  const activeIncident = sequence % 11 >= 6 && sequence % 11 <= 8;
  const recovering = sequence % 11 === 9 || sequence % 11 === 10;
  const phaseCode = activeIncident ? 2 : recovering ? 3 : sequence % 5 === 0 ? 1 : 0;
  const requestsPerMinute = round(1480 + wave(sequence, 0.64, 130) + (activeIncident ? 240 : 0));
  const latencyMs = round(82 + wave(sequence, 0.72, 18) + (activeIncident ? 62 : recovering ? 26 : 0));
  const errorPermille = clamp(round(5 + wave(sequence, 0.57, 3) + (activeIncident ? 17 : recovering ? 7 : 0)), 2, 42);
  const queueDepth = clamp(round(38 + wave(sequence, 0.48, 16) + (activeIncident ? 31 : recovering ? 14 : 0)), 12, 96);
  const databaseLagSec = clamp(round(1 + wave(sequence, 0.8, 1) + (activeIncident ? 5 : 0)), 0, 12);
  const budgetRemainingPermille = clamp(989 - sequence - activeIncident * 8 - errorPermille, 910, 990);
  const burnRateX10 = clamp(round(7 + errorPermille / 2 + (activeIncident ? 10 : 0)), 5, 35);
  const webhookRpm = round(requestsPerMinute * 0.61 + wave(sequence, 0.43, 50));
  const dbWriteRpm = round(requestsPerMinute * 0.45 + wave(sequence, 0.36, 34));
  const runningJobs = activeIncident ? 14 : recovering ? 12 : 10;
  const blockedJobs = activeIncident ? 2 : queueDepth > 62 ? 1 : 0;
  const oldestJobMin = clamp(round(6 + queueDepth / 12 + (activeIncident ? 7 : 0)), 4, 24);
  const workerStateCode = blockedJobs > 0 ? 2 : queueDepth > 58 ? 1 : 0;
  const apiStateCode = activeIncident ? 2 : recovering ? 1 : 0;
  const billingStateCode = activeIncident ? 1 : 0;
  const databaseStateCode = databaseLagSec > 5 ? 1 : 0;
  const searchStateCode = sequence % 7 === 0 ? 1 : 0;

  const fields = {
    schema: 1,
    updated_version: sequence,
    updated_hour: 12,
    updated_minute: Math.floor((sequence * 2) / 60) % 60,
    updated_second: (sequence * 2) % 60,
    phase_code: phaseCode,
    requests_per_minute: requestsPerMinute,
    traffic_delta_percent: clamp(round(7 + wave(sequence, 0.55, 5) + (activeIncident ? 11 : 0)), 0, 28),
    error_permille: errorPermille,
    burn_rate_x10: burnRateX10,
    budget_remaining_permille: budgetRemainingPermille,
    latency_ms: latencyMs,
    latency_target_ms: 120,
    webhook_rpm: webhookRpm,
    webhook_bar_code: barCode(webhookRpm, 1250),
    db_write_rpm: dbWriteRpm,
    db_write_bar_code: barCode(dbWriteRpm, 980),
    ingress_bar_code: barCode(requestsPerMinute, 2200),
    latency_bar_code: barCode(latencyMs, 190),
    error_bar_code: barCode(errorPermille, 36),
    budget_bar_code: clamp(8 - barCode(budgetRemainingPermille, 1000), 0, 8),
    queue_depth: queueDepth,
    queue_trend_code: activeIncident ? 2 : recovering ? 0 : sequence % 4 === 0 ? 2 : 1,
    queue_capacity: 120,
    running_jobs: runningJobs,
    blocked_jobs: blockedJobs,
    oldest_job_min: oldestJobMin,
    job_a_id: 101 + sequence,
    job_a_progress: progress(72, sequence, 3),
    job_a_age_min: 3 + (sequence % 5),
    job_a_state_code: 0,
    job_b_id: 118 + sequence,
    job_b_progress: progress(43, sequence, 2),
    job_b_age_min: 7 + (sequence % 6),
    job_b_state_code: activeIncident ? 2 : 0,
    job_c_id: 132 + sequence,
    job_c_progress: progress(58, sequence, 4),
    job_c_age_min: 2 + (sequence % 5),
    job_c_state_code: blockedJobs > 0 ? 3 : 0,
    job_d_id: 172 + sequence,
    job_d_progress: progress(64, sequence, 3),
    job_d_age_min: 4 + (sequence % 4),
    job_d_state_code: sequence % 6 === 0 ? 1 : 0,
    alert_a_code: activeIncident ? 1 : workerStateCode === 2 ? 2 : 3,
    alert_a_age_min: activeIncident ? 2 + (sequence % 5) : 5 + (sequence % 8),
    alert_b_code: activeIncident ? 2 : 4,
    alert_b_age_min: 3 + (sequence % 9),
    alert_c_code: activeIncident ? 3 : 5,
    alert_c_age_min: 8 + (sequence % 11),
    edge_state_code: sequence % 9 === 0 ? 1 : 0,
    edge_latency_ms: clamp(round(47 + wave(sequence, 0.5, 10) + (activeIncident ? 18 : 0)), 35, 95),
    api_state_code: apiStateCode,
    api_latency_ms: latencyMs,
    worker_state_code: workerStateCode,
    worker_oldest_job_min: oldestJobMin,
    database_state_code: databaseStateCode,
    database_lag_sec: databaseLagSec,
    billing_state_code: billingStateCode,
    billing_latency_ms: clamp(round(94 + wave(sequence, 0.62, 18) + (activeIncident ? 31 : 0)), 70, 160),
    search_state_code: searchStateCode,
    search_refresh_sec: clamp(round(14 + wave(sequence, 0.75, 6) + (searchStateCode ? 9 : 0)), 8, 30),
    identity_state_code: 0,
    identity_latency_ms: clamp(round(42 + wave(sequence, 0.38, 8)), 30, 70),
  };
  fields.service_details = serviceDetails(fields);

  return {
    sequence,
    fields,
    activeIncident,
    recovering,
    requestsPerMinute,
    latencyMs,
    errorPermille,
    queueDepth,
    oldestJobMin,
    burnRateX10,
    budgetRemainingPermille,
    runningJobs,
    blockedJobs,
    databaseLagSec,
  };
}

function serviceDetails(fields) {
  return [
    serviceDetail("edge", "edge", "traffic", fields.edge_state_code, "Global edge routers and canary traffic shaping", "runbooks/edge-traffic", [
      dependency("api", "api", fields.api_state_code),
      dependency("identity", "identity", fields.identity_state_code),
    ]),
    serviceDetail("api", "api", "platform", fields.api_state_code, "Primary JSON API gateway for customer and ops workflows", "runbooks/api-gateway", [
      dependency("database", "database", fields.database_state_code),
      dependency("billing", "billing", fields.billing_state_code),
      dependency("identity", "identity", fields.identity_state_code),
    ]),
    serviceDetail("workers", "workers", "delivery", fields.worker_state_code, "Background queue consumers for search, billing, exports, and session cleanup", "runbooks/workers-queue", [
      dependency("database", "database", fields.database_state_code),
      dependency("search", "search", fields.search_state_code),
    ]),
    serviceDetail("database", "database", "data", fields.database_state_code, "Primary transactional store and replica health for the public API", "runbooks/database-lag", [
      dependency("api", "api", fields.api_state_code),
      dependency("workers", "workers", fields.worker_state_code),
    ]),
    serviceDetail("billing", "billing", "revenue", fields.billing_state_code, "Billing API and webhook delivery coordination", "runbooks/billing-webhooks", [
      dependency("api", "api", fields.api_state_code),
      dependency("workers", "workers", fields.worker_state_code),
    ]),
    serviceDetail("search", "search", "discovery", fields.search_state_code, "Search indexing and query freshness for public workspaces", "runbooks/search-freshness", [
      dependency("workers", "workers", fields.worker_state_code),
      dependency("database", "database", fields.database_state_code),
    ]),
    serviceDetail("identity", "identity", "security", fields.identity_state_code, "Session cache, token validation, and operator access checks", "runbooks/identity-cache", [
      dependency("api", "api", fields.api_state_code),
      dependency("database", "database", fields.database_state_code),
    ]),
  ];
}

function serviceDetail(id, label, owner, stateCode, summary, runbook, dependencies) {
  return {
    id,
    label,
    owner,
    status: healthTextForCode(stateCode),
    summary,
    runbook,
    dependencies,
    contacts: [
      { team: `${owner}-primary`, channel: `#ops-${id}` },
      { team: "incident-command", channel: "#incident-room" },
    ],
  };
}

function dependency(id, label, stateCode) {
  return {
    id,
    label,
    state: healthTextForCode(stateCode),
  };
}

function healthTextForCode(code) {
  if (code === 2) {
    return "degraded";
  }
  if (code === 1) {
    return "watch";
  }
  return "ok";
}

function summaryText(snapshot) {
  return [
    `Updated: 12:${twoDigits(Math.floor((snapshot.sequence * 2) / 60) % 60)}:${twoDigits((snapshot.sequence * 2) % 60)} UTC  version ${snapshot.sequence}`,
    `Overall: ${snapshot.activeIncident ? "Degraded" : snapshot.recovering ? "Recovering" : "Nominal"}  phase simulated  incidents ${snapshot.activeIncident ? 1 : 0}`,
    `Traffic: ${snapshot.requestsPerMinute.toLocaleString("en-US")} rpm  live feed`,
    `Errors: ${(snapshot.errorPermille / 10).toFixed(1)}%  budget burn ${(snapshot.burnRateX10 / 10).toFixed(1)}x`,
    `Queue: ${snapshot.queueDepth} jobs  running ${snapshot.runningJobs}  blocked ${snapshot.blockedJobs}`,
    "Services: browser-backed simulation  primary region usw2",
  ].join("\n");
}

function trafficText(snapshot) {
  return [
    `Ingress        ${snapshot.requestsPerMinute.toLocaleString("en-US")} rpm`,
    `API p95        ${snapshot.latencyMs} ms`,
    `Error rate     ${(snapshot.errorPermille / 10).toFixed(1)}%`,
    `Queue depth    ${snapshot.queueDepth} jobs`,
  ].join("\n");
}

function jobsText(snapshot) {
  return [
    `job-${101 + snapshot.sequence}  running   ${progress(72, snapshot.sequence, 3)}%  workers/search`,
    `job-${118 + snapshot.sequence}  ${snapshot.activeIncident ? "retrying" : "running"}   ${progress(43, snapshot.sequence, 2)}%  billing`,
    `job-${132 + snapshot.sequence}  ${snapshot.blockedJobs > 0 ? "blocked" : "running"}   ${progress(58, snapshot.sequence, 4)}%  compliance`,
    `job-${172 + snapshot.sequence}  queued    ${progress(64, snapshot.sequence, 3)}%  identity`,
  ].join("\n");
}

function alertsText(snapshot) {
  if (snapshot.activeIncident) {
    return [
      "CRITICAL payments-api active     Checkout latency above SLO",
      "WARNING  workers      monitoring Queue age approaching cap",
      "INFO     edge         monitoring Canary pool shifted 10 percent",
    ].join("\n");
  }
  return [
    "WARNING workers      monitoring Retry queue elevated",
    "INFO    payments-api recovering Error budget burn below 1x",
    "INFO    edge         steady     Canary pool normal",
  ].join("\n");
}

function healthText(snapshot) {
  return [
    `edge      ok       live`,
    `api       ${snapshot.activeIncident ? "degraded" : "ok"} p95 ${snapshot.latencyMs} ms`,
    `workers   ${snapshot.blockedJobs > 0 ? "degraded" : "ok"} oldest ${snapshot.oldestJobMin}m`,
    `database  ${snapshot.databaseLagSec > 5 ? "watch" : "ok"} lag ${snapshot.databaseLagSec}s`,
    "billing   watch    webhooks draining",
    "search    ok       index green",
    "identity  ok       session cache hot",
  ].join("\n");
}

function wave(seed, speed, amplitude) {
  return Math.sin(seed * speed) * amplitude;
}

function round(value) {
  return Math.round(value);
}

function clamp(value, min, max) {
  return Math.max(min, Math.min(max, value));
}

function barCode(value, max) {
  return clamp(Math.round((value / max) * 8), 0, 8);
}

function progress(base, sequence, speed) {
  return clamp((base + sequence * speed) % 100, 5, 98);
}

function twoDigits(value) {
  return String(value).padStart(2, "0");
}

// --- named task sources for the gallery examples ----------------------------
//
// Several examples drive their async work through `Signal.task_source(name, …)`
// rather than `Http`, so their requests arrive here under a bare name instead of
// the `http:send:` prefix the routers above match. Under the native spec host a
// spec script supplies each result; in the browser these handlers stand in for
// that script.
//
// House rules, same as `createOpsBackend`: no `Math.random()`, no wall-clock
// input. Each backend owns a small counter that advances once per request, and
// the counter indexes a scripted progression so that successive polls tell a
// story — healthy, degraded, an incident with updates, a failure, recovery —
// and then settle on a steady final state.
//
// Payload wire formats are copied from the literal payloads in each example's
// `specs/*.scm`, which are the ground truth the Roc parse functions were
// written against.

// Tasks resolve after a short delay so the Loading branch of every
// `Signal.fold_task` is actually visible, and so a superseded request can be
// cancelled while still in flight (latest-wins in package-explorer).
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
// Names: "check:api", "check:web", "check:database", "check:notifications",
// "incidents". Every request payload is the literal string "refresh"; the round
// number comes from a per-name counter, so each service tells its own part of
// the same story even though the five tasks are independent.
//
// Wire formats (see parse_check / parse_feed in examples/status-page/main.roc):
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

export function createStatusPageBackend() {
  const rounds = new Map();
  return function statusPageTaskHandler({ name, signal }) {
    const script = name === "incidents" ? statusFeed : statusChecks[name];
    if (!script) {
      return null;
    }
    const round = rounds.get(name) ?? 0;
    rounds.set(name, round + 1);
    const entry = stage(script, round);
    if (entry && typeof entry === "object" && entry.fail) {
      return failWith(entry.fail, { signal });
    }
    return settle(entry, { signal });
  };
}

// --- support-inbox -----------------------------------------------------------
//
// Names: "inbox" (request "poll" or "read:<conv>") and "send"
// (request "<cid>|<conv>|<body>", resolving with the cid so the optimistic row
// can be reconciled).
//
// Wire format (Inbox.parse_snapshot):
//   "<conversations># <messages>" with ";" between records
//   conversation  id|subject|customer|owner
//   message       id|conv|author|body|read-flag|client-id   (flag "new" = unread)
//
// The backend keeps real server state so the example can demonstrate what it
// claims. Successive polls (every 4s) deliver new customer messages, which
// raises unread counts without touching the open thread; opening a conversation
// issues "read:<id>", which clears that conversation's unread flags server-side.
//
//   poll 1  the three seeded conversations, one unread in c2
//   poll 2  a new unread message lands in c1
//   poll 3  the poll itself fails (sync status shows the error, the list stays)
//   poll 4  a new unread message lands in c3
//   poll 5  another unread lands in c2
//   poll 6+ settled
//
// Sends: the first succeeds, the second fails so the optimistic row rolls back,
// later ones succeed. A body containing "fail" always fails, so the rollback is
// reproducible on demand.
const inboxConversations = [
  "c1|Card declined|Ada Lovelace|me",
  "c2|Cannot log in|Grace Hopper|sam",
  "c3|Refund status|Alan Turing|me",
];

const inboxSeedMessages = [
  { id: "m1", conv: "c1", author: "customer", body: "My card was declined", unread: false, cid: "-" },
  { id: "m2", conv: "c1", author: "agent", body: "Looking into it now", unread: false, cid: "-" },
  { id: "m3", conv: "c2", author: "customer", body: "Login loop on mobile", unread: true, cid: "-" },
];

const inboxArrivals = [
  null,
  { id: "m4", conv: "c1", author: "customer", body: "Any update on this?", unread: true, cid: "-" },
  null,
  { id: "m5", conv: "c3", author: "customer", body: "Still waiting on my refund", unread: true, cid: "-" },
  { id: "m6", conv: "c2", author: "customer", body: "Still broken after a reinstall", unread: true, cid: "-" },
];

export function createSupportInboxBackend() {
  const messages = inboxSeedMessages.map((message) => ({ ...message }));
  let polls = 0;
  let sends = 0;
  let nextServerId = 100;

  const encode = () => {
    const rows = messages.map(
      (m) => `${m.id}|${m.conv}|${m.author}|${m.body}|${m.unread ? "new" : "read"}|${m.cid}`,
    );
    return `${inboxConversations.join(";")}#${rows.join(";")}`;
  };

  return function supportInboxTaskHandler({ name, request, signal }) {
    if (name === "inbox") {
      const text = String(request);
      if (text.startsWith("read:")) {
        const conv = text.slice("read:".length);
        for (const message of messages) {
          if (message.conv === conv) {
            message.unread = false;
          }
        }
        return settle(encode(), { signal });
      }

      polls += 1;
      // The third poll fails on purpose: `reset_on_start = False` means the
      // board keeps showing the last good snapshot while the status line
      // reports the failure, and the next poll recovers.
      if (polls === 3) {
        return failWith("sync gateway timed out", { signal });
      }
      const arrival = polls <= inboxArrivals.length ? inboxArrivals[polls - 1] : null;
      if (arrival && !messages.some((m) => m.id === arrival.id)) {
        messages.push({ ...arrival });
      }
      return settle(encode(), { signal });
    }

    if (name !== "send") {
      return null;
    }

    const [cid, conv, ...bodyParts] = String(request).split("|");
    const body = bodyParts.join("|");
    sends += 1;
    if (sends === 2 || body.toLowerCase().includes("fail")) {
      return failWith("delivery service rejected the message", { signal });
    }
    nextServerId += 1;
    messages.push({
      id: `s${nextServerId}`,
      conv,
      author: "agent",
      body,
      unread: false,
      // Echoing the client id is what lets the optimistic merge drop the local
      // copy instead of showing the message twice.
      cid,
    });
    return settle(cid, { signal });
  };
}

// --- field-notes -------------------------------------------------------------
//
// Name: "note-sync". The request is the note's settlement token, "<id>#<rev>",
// and both the success and the failure payload must echo that same token back:
// the app compares the settled token against the note's current token to decide
// whether a row is synced, failed, or still outstanding.
//
// Every third sync request fails, so the outbox demonstrates a failed row and
// the Retry button; retrying mints a new revision, which produces a new token
// and (usually) a clean settlement on the next attempt.
export function createFieldNotesBackend() {
  let attempts = 0;
  return function fieldNotesTaskHandler({ name, request, signal }) {
    if (name !== "note-sync") {
      return null;
    }
    attempts += 1;
    const token = String(request);
    if (attempts % 3 === 0) {
      return failWith(token, { signal });
    }
    return settle(token, { signal });
  };
}

// --- onboarding-wizard -------------------------------------------------------
//
// Name: "onboarding-submit", request "submit-<attempt>". The first attempt
// fails so the failure branch of the submit status is reachable without any
// special input; every later attempt creates the workspace.
export function createOnboardingBackend() {
  return function onboardingTaskHandler({ name, request, signal }) {
    if (name !== "onboarding-submit") {
      return null;
    }
    const attempt = Number.parseInt(String(request).replace("submit-", ""), 10) || 1;
    if (attempt === 1) {
      return failWith("workspace name already taken", { signal });
    }
    return settle(`acme-${40 + attempt}`, { signal });
  };
}

// --- package-explorer --------------------------------------------------------
//
// Names: "search" (request is the query text) and "detail" / "versions" /
// "deps" (request is the package id). Wire formats, from Catalog.roc:
//   search    "id|summary;id|summary"
//   detail    "id|summary|license|downloads"
//   versions  "version|released;version|released"
//   deps      "id|requirement;id|requirement"
// An empty payload is a legitimate answer everywhere.
//
// The registry is a fixed catalogue filtered by substring, so search is
// deterministic and latest-wins cancellation is observable (a superseded
// request rejects with "canceled" while in flight). A query containing
// "offline" fails the search, and an unknown package id fails the detail panel
// while versions and deps still answer — the point the example makes about
// panels settling independently.
const packageCatalog = [
  {
    id: "roc-json",
    summary: "JSON codec for Roc",
    license: "Apache-2.0",
    downloads: "18422",
    versions: "1.2.0|2026-05-02;1.1.0|2026-03-14;1.0.0|2026-01-09",
    deps: "roc-parser|0.4.0;roc-bytes|1.1.0",
  },
  {
    id: "roc-http",
    summary: "HTTP client for Roc",
    license: "MIT",
    downloads: "9310",
    versions: "0.9.1|2026-04-22;0.9.0|2026-02-01",
    deps: "roc-bytes|1.1.0",
  },
  {
    id: "roc-parser",
    summary: "Parser combinators for Roc",
    license: "Apache-2.0",
    downloads: "12045",
    versions: "0.4.0|2026-03-30;0.3.2|2025-12-11",
    deps: "",
  },
  {
    id: "roc-bytes",
    summary: "Byte helpers for Roc",
    license: "MIT",
    downloads: "6188",
    versions: "1.1.0|2026-02-18;1.0.0|2025-11-05",
    deps: "",
  },
  {
    id: "roc-random",
    summary: "Seeded random number generators for Roc",
    license: "MIT",
    downloads: "3401",
    versions: "0.2.0|2026-01-27",
    deps: "roc-bytes|1.1.0",
  },
];

export function createPackageExplorerBackend() {
  return function packageExplorerTaskHandler({ name, request, signal }) {
    const text = String(request).trim();
    if (name === "search") {
      if (text.toLowerCase().includes("offline")) {
        return failWith("registry unreachable", { signal });
      }
      const needle = text.toLowerCase();
      const rows = packageCatalog.filter(
        (pkg) =>
          needle === "" ||
          pkg.id.toLowerCase().includes(needle) ||
          pkg.summary.toLowerCase().includes(needle),
      );
      return settle(rows.map((pkg) => `${pkg.id}|${pkg.summary}`).join(";"), { signal });
    }

    if (name !== "detail" && name !== "versions" && name !== "deps") {
      return null;
    }

    const pkg = packageCatalog.find((candidate) => candidate.id === text);
    if (!pkg) {
      if (name === "detail") {
        return failWith("overview service unavailable", { signal });
      }
      return settle("", { signal });
    }
    if (name === "detail") {
      return settle(`${pkg.id}|${pkg.summary}|${pkg.license}|${pkg.downloads}`, { signal });
    }
    if (name === "versions") {
      return settle(pkg.versions, { signal });
    }
    return settle(pkg.deps, { signal });
  };
}

// --- flight-search -----------------------------------------------------------
//
// Name: "flight-search". The request is the fan-in of the six filter states:
// "<origin>-<destination>|<date>|<max stops>|<max price>|<airline>". Only the
// route and date reach the server; stops, price and airline are applied locally
// to the results already held, which is the point of the example.
//
// Wire format: "code,airline,depart,duration,stops,price" records separated by
// ";" (see parse_flights).
//
// Choosing the same city for both ends (MEL to MEL) is a reachable failure, and
// changing either end back recovers. The board itself is a fixed timetable
// shifted deterministically by the route and departure date, so no wall clock
// or randomness is involved.
const flightTimetable = [
  { code: "QF421", airline: "Qantas", depart: "06:00", minutes: 305, stops: 0, price: 145 },
  { code: "VA518", airline: "Virgin Australia", depart: "09:30", minutes: 210, stops: 1, price: 215 },
  { code: "JQ722", airline: "Jetstar", depart: "07:15", minutes: 480, stops: 0, price: 130 },
  { code: "QF876", airline: "Qantas", depart: "14:05", minutes: 265, stops: 2, price: 300 },
  { code: "VA209", airline: "Virgin Australia", depart: "17:40", minutes: 190, stops: 0, price: 265 },
];

// A tiny stable hash over the route and date, so the same criteria always
// produce the same board and different criteria visibly differ.
function criteriaSeed(text) {
  let seed = 0;
  for (let index = 0; index < text.length; index += 1) {
    seed = (seed * 31 + text.charCodeAt(index)) % 997;
  }
  return seed;
}

export function createFlightSearchBackend() {
  return function flightSearchTaskHandler({ name, request, signal }) {
    if (name !== "flight-search") {
      return null;
    }
    const [route = "", date = ""] = String(request).split("|");
    const [origin = "", destination = ""] = route.split("-");
    if (origin !== "" && origin === destination) {
      return failWith(`no route ${origin}-${destination}`, { signal });
    }

    const seed = criteriaSeed(`${route}|${date}`);
    const rows = flightTimetable.map((flight, index) => {
      const priceShift = ((seed + index * 17) % 9) * 5;
      const durationShift = ((seed + index * 23) % 5) * 6;
      return [
        flight.code,
        flight.airline,
        flight.depart,
        flight.minutes + durationShift,
        flight.stops,
        flight.price + priceShift,
      ].join(",");
    });
    return settle(rows.join(";"), { signal });
  };
}
