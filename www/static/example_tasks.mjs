import {
  HttpTask,
  decodeHttpRequestPayload,
  encodeHttpErrorPayload,
  encodeHttpResponsePayload,
} from "./signals.mjs";

const textEncoder = new TextEncoder();

const opsApiPaths = Object.freeze([
  "/api/ops/dashboard",
  "/api/ops/summary",
  "/api/ops/traffic",
  "/api/ops/jobs",
  "/api/ops/alerts",
  "/api/ops/health",
]);

export function createPublicExampleTaskHandler() {
  const opsBackend = createOpsBackend();
  return function publicExampleTaskHandler(args) {
    const lookup = lookupTaskHandler(args);
    if (lookup !== null && lookup !== undefined) {
      return lookup;
    }

    const apiConsole = apiRequestConsoleTaskHandler(args);
    if (apiConsole !== null && apiConsole !== undefined) {
      return apiConsole;
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

export function opsApiTaskHandler({ name, request }, backend = defaultOpsBackend) {
  if (!name.startsWith(HttpTask.namePrefix)) {
    return null;
  }

  const decoded = decodeHttpRequestPayload(request);
  if (!opsApiPaths.includes(decoded.uri)) {
    return null;
  }
  if (decoded.method !== "GET") {
    throw new Error(encodeHttpErrorPayload("unsupported", `unsupported ops API method: ${decoded.method}`));
  }

  const snapshot = backend.nextSnapshot();
  switch (decoded.uri) {
    case "/api/ops/dashboard":
      return resolvedResponse(dashboardJson(snapshot), "application/json; charset=utf-8");
    case "/api/ops/summary":
      return resolvedResponse(summaryText(snapshot), "text/plain; charset=utf-8");
    case "/api/ops/traffic":
      return resolvedResponse(trafficText(snapshot), "text/plain; charset=utf-8");
    case "/api/ops/jobs":
      return resolvedResponse(jobsText(snapshot), "text/plain; charset=utf-8");
    case "/api/ops/alerts":
      return resolvedResponse(alertsText(snapshot), "text/plain; charset=utf-8");
    case "/api/ops/health":
      return resolvedResponse(healthText(snapshot), "text/plain; charset=utf-8");
    default:
      return null;
  }
}

export function apiRequestConsoleTaskHandler({ name, request }) {
  if (!name.startsWith(HttpTask.namePrefix)) {
    return null;
  }
  const decoded = decodeHttpRequestPayload(request);
  if (decoded.uri !== "/api/api-request-console") {
    return null;
  }
  if (decoded.method !== "POST") {
    throw new Error(encodeHttpErrorPayload("unsupported", `unsupported API console method: ${decoded.method}`));
  }

  const scenario = httpHeaderValue(decoded.headers, "x-scenario") || "success";
  if (scenario === "failure") {
    throw new Error(encodeHttpErrorPayload("network", "offline"));
  }

  const missing = scenario === "missing";
  return resolvedResponse(
    missing
      ? '{"status":"missing","message":"customer record was not found"}'
      : '{"status":"created","message":"customer-42 is ready"}',
    "application/json; charset=utf-8",
    {
      status: missing ? 404 : 201,
      headers: [["x-result", missing ? "missing" : "ok"]],
    },
  );
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

function dashboardJson(snapshot) {
  return JSON.stringify(snapshot.fields);
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

function resolvedResponse(body, contentType, { status = 200, headers = [] } = {}) {
  return Promise.resolve(
    encodeHttpResponsePayload({
      status,
      headers: [["content-type", contentType], ...headers],
      body: textEncoder.encode(body),
    }),
  );
}

function httpHeaderValue(headers, targetName) {
  const target = targetName.toLowerCase();
  for (const [name, value] of headers) {
    if (String(name).toLowerCase() === target) {
      return String(value);
    }
  }
  return "";
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
