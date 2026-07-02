import pf.Json

Dashboard := {
	schema : U64,
	version : U64,
	updated : Dashboard.Clock,
	phase : Dashboard.Phase,
	traffic : Dashboard.Traffic,
	budget : Dashboard.Budget,
	queue : Dashboard.Queue,
	services : List(Dashboard.Service),
	jobs : List(Dashboard.Job),
	alerts : List(Dashboard.Alert),
}.{
	ParseErr : [BadJson, MissingData(Str), BadCode(Str), UnsupportedSchema(U64)]

	State := [Loading, Ready(Dashboard), RequestFailed(Str), DecodeFailed(ParseErr)]

	Clock : { hour : U64, minute : U64, second : U64 }

	Phase : [PhaseSteady, PhaseWatch, PhaseActiveIncident, PhaseRecovering]

	Health : [HealthOk, HealthWatch, HealthDegraded]

	QueueTrend : [TrendDraining, TrendSteady, TrendRising]

	JobState : [JobRunning, JobQueued, JobRetrying, JobBlocked]

	AlertKind : [AlertCriticalCheckout, AlertWorkerQueue, AlertEdgeCanary, AlertPaymentRecovering, AlertEdgeSteady]

	Traffic : {
		requests_per_minute : U64,
		delta_percent : U64,
		latency_ms : U64,
		latency_target_ms : U64,
		webhook_rpm : U64,
		db_write_rpm : U64,
		ingress_bar_code : U64,
		latency_bar_code : U64,
		error_bar_code : U64,
		webhook_bar_code : U64,
		db_write_bar_code : U64,
	}

	Budget : {
		remaining_permille : U64,
		burn_rate_x10 : U64,
		error_permille : U64,
		bar_code : U64,
	}

	Queue : {
		depth : U64,
		trend : QueueTrend,
		capacity : U64,
		running_jobs : U64,
		blocked_jobs : U64,
		oldest_job_min : U64,
	}

	Service : {
		id : Str,
		label : Str,
		health : Health,
		latency_ms : U64,
		detail : Str,
	}

	Job : {
		id : Str,
		label : Str,
		owner : Str,
		run_id : U64,
		state : JobState,
		progress : U64,
		age_min : U64,
	}

	Alert : {
		id : Str,
		kind : AlertKind,
		age_min : U64,
	}

	decode : Str -> State
	decode = |body|
		match parse_dashboard(body) {
			Ok(dashboard) => Ready(dashboard)
			Err(err) => DecodeFailed(err)
		}

	request_failed : Str -> State
	request_failed = |err| RequestFailed(err)

	loading : State
	loading = Loading
}

# Keep the raw JSON records split. With roc release-fast-7da362c8,
# derived parsing for one 52+ field record segfaults; the 10 small parses are
# an intentional compiler-workaround until that upstream issue is fixed.
RawMeta : {
	schema : U64,
	updated_version : U64,
	updated_hour : U64,
	updated_minute : U64,
	updated_second : U64,
	phase_code : U64,
}

RawTrafficCore : {
	requests_per_minute : U64,
	traffic_delta_percent : U64,
	latency_ms : U64,
	latency_target_ms : U64,
	webhook_rpm : U64,
	db_write_rpm : U64,
}

RawTrafficBars : {
	webhook_bar_code : U64,
	db_write_bar_code : U64,
	ingress_bar_code : U64,
	latency_bar_code : U64,
	error_bar_code : U64,
}

RawBudget : {
	error_permille : U64,
	burn_rate_x10 : U64,
	budget_remaining_permille : U64,
	budget_bar_code : U64,
}

RawQueue : {
	queue_depth : U64,
	queue_trend_code : U64,
	queue_capacity : U64,
	running_jobs : U64,
	blocked_jobs : U64,
	oldest_job_min : U64,
}

RawServiceStates : {
	edge_state_code : U64,
	api_state_code : U64,
	worker_state_code : U64,
	database_state_code : U64,
	billing_state_code : U64,
	search_state_code : U64,
	identity_state_code : U64,
}

RawServiceMetrics : {
	edge_latency_ms : U64,
	api_latency_ms : U64,
	worker_oldest_job_min : U64,
	database_lag_sec : U64,
	billing_latency_ms : U64,
	search_refresh_sec : U64,
	identity_latency_ms : U64,
}

RawJobsA : {
	job_a_id : U64,
	job_a_progress : U64,
	job_a_age_min : U64,
	job_a_state_code : U64,
	job_b_id : U64,
	job_b_progress : U64,
	job_b_age_min : U64,
	job_b_state_code : U64,
}

RawJobsB : {
	job_c_id : U64,
	job_c_progress : U64,
	job_c_age_min : U64,
	job_c_state_code : U64,
	job_d_id : U64,
	job_d_progress : U64,
	job_d_age_min : U64,
	job_d_state_code : U64,
}

RawAlerts : {
	alert_a_code : U64,
	alert_a_age_min : U64,
	alert_b_code : U64,
	alert_b_age_min : U64,
	alert_c_code : U64,
	alert_c_age_min : U64,
}

parse_dashboard : Str -> Try(Dashboard, Dashboard.ParseErr)
parse_dashboard = |body| {
	meta_result : Try(RawMeta, Json)
	meta_result = Json.parse(body)
	meta = map_json_result("meta", meta_result)?
	if meta.schema != 1 {
		return Err(UnsupportedSchema(meta.schema))
	}

	traffic_result : Try(RawTrafficCore, Json)
	traffic_result = Json.parse(body)
	traffic = map_json_result("traffic", traffic_result)?
	traffic_bars_result : Try(RawTrafficBars, Json)
	traffic_bars_result = Json.parse(body)
	traffic_bars = map_json_result("traffic bars", traffic_bars_result)?
	budget_result : Try(RawBudget, Json)
	budget_result = Json.parse(body)
	budget = map_json_result("budget", budget_result)?
	queue_result : Try(RawQueue, Json)
	queue_result = Json.parse(body)
	queue = map_json_result("queue", queue_result)?
	service_states_result : Try(RawServiceStates, Json)
	service_states_result = Json.parse(body)
	service_states = map_json_result("service states", service_states_result)?
	service_metrics_result : Try(RawServiceMetrics, Json)
	service_metrics_result = Json.parse(body)
	service_metrics = map_json_result("service metrics", service_metrics_result)?
	jobs_a_result : Try(RawJobsA, Json)
	jobs_a_result = Json.parse(body)
	jobs_a = map_json_result("jobs a", jobs_a_result)?
	jobs_b_result : Try(RawJobsB, Json)
	jobs_b_result = Json.parse(body)
	jobs_b = map_json_result("jobs b", jobs_b_result)?
	alerts_result : Try(RawAlerts, Json)
	alerts_result = Json.parse(body)
	alerts = map_json_result("alerts", alerts_result)?

	phase = decode_phase(meta.phase_code)?
	queue_trend = decode_queue_trend(queue.queue_trend_code)?

	edge_health = decode_health("edge_state_code", service_states.edge_state_code)?
	api_health = decode_health("api_state_code", service_states.api_state_code)?
	worker_health = decode_health("worker_state_code", service_states.worker_state_code)?
	database_health = decode_health("database_state_code", service_states.database_state_code)?
	billing_health = decode_health("billing_state_code", service_states.billing_state_code)?
	search_health = decode_health("search_state_code", service_states.search_state_code)?
	identity_health = decode_health("identity_state_code", service_states.identity_state_code)?

	job_a_state = decode_job_state("job_a_state_code", jobs_a.job_a_state_code)?
	job_b_state = decode_job_state("job_b_state_code", jobs_a.job_b_state_code)?
	job_c_state = decode_job_state("job_c_state_code", jobs_b.job_c_state_code)?
	job_d_state = decode_job_state("job_d_state_code", jobs_b.job_d_state_code)?

	alert_a_kind = decode_alert_kind("alert_a_code", alerts.alert_a_code)?
	alert_b_kind = decode_alert_kind("alert_b_code", alerts.alert_b_code)?
	alert_c_kind = decode_alert_kind("alert_c_code", alerts.alert_c_code)?

	Ok(
		{
			schema: meta.schema,
			version: meta.updated_version,
			updated: { hour: meta.updated_hour, minute: meta.updated_minute, second: meta.updated_second },
			phase,
			traffic: {
				requests_per_minute: traffic.requests_per_minute,
				delta_percent: traffic.traffic_delta_percent,
				latency_ms: traffic.latency_ms,
				latency_target_ms: traffic.latency_target_ms,
				webhook_rpm: traffic.webhook_rpm,
				db_write_rpm: traffic.db_write_rpm,
				ingress_bar_code: get_bar_code("ingress_bar_code", traffic_bars.ingress_bar_code)?,
				latency_bar_code: get_bar_code("latency_bar_code", traffic_bars.latency_bar_code)?,
				error_bar_code: get_bar_code("error_bar_code", traffic_bars.error_bar_code)?,
				webhook_bar_code: get_bar_code("webhook_bar_code", traffic_bars.webhook_bar_code)?,
				db_write_bar_code: get_bar_code("db_write_bar_code", traffic_bars.db_write_bar_code)?,
			},
			budget: {
				remaining_permille: budget.budget_remaining_permille,
				burn_rate_x10: budget.burn_rate_x10,
				error_permille: budget.error_permille,
				bar_code: get_bar_code("budget_bar_code", budget.budget_bar_code)?,
			},
			queue: {
				depth: queue.queue_depth,
				trend: queue_trend,
				capacity: queue.queue_capacity,
				running_jobs: queue.running_jobs,
				blocked_jobs: queue.blocked_jobs,
				oldest_job_min: queue.oldest_job_min,
			},
			services: [
				{
					id: "edge",
					label: "edge",
					health: edge_health,
					latency_ms: service_metrics.edge_latency_ms,
					detail: "8 pods",
				},
				{
					id: "api",
					label: "api",
					health: api_health,
					latency_ms: service_metrics.api_latency_ms,
					detail: "12 pods",
				},
				{
					id: "workers",
					label: "workers",
					health: worker_health,
					latency_ms: 0,
					detail: "oldest ${service_metrics.worker_oldest_job_min.to_str()}m | ${queue.queue_depth.to_str()} queued",
				},
				{
					id: "database",
					label: "database",
					health: database_health,
					latency_ms: 0,
					detail: "lag ${service_metrics.database_lag_sec.to_str()}s | 2 writers",
				},
				{
					id: "billing",
					label: "billing",
					health: billing_health,
					latency_ms: service_metrics.billing_latency_ms,
					detail: "webhooks",
				},
				{
					id: "search",
					label: "search",
					health: search_health,
					latency_ms: 0,
					detail: "refresh ${service_metrics.search_refresh_sec.to_str()}s | 5 shards",
				},
				{
					id: "identity",
					label: "identity",
					health: identity_health,
					latency_ms: service_metrics.identity_latency_ms,
					detail: "session cache",
				},
			],
			jobs: [
				{
					id: "search-index",
					label: "Rebuild search index",
					owner: "workers/search",
					run_id: jobs_a.job_a_id,
					state: job_a_state,
					progress: jobs_a.job_a_progress,
					age_min: jobs_a.job_a_age_min,
				},
				{
					id: "billing-backfill",
					label: "Backfill billing events",
					owner: "billing",
					run_id: jobs_a.job_b_id,
					state: job_b_state,
					progress: jobs_a.job_b_progress,
					age_min: jobs_a.job_b_age_min,
				},
				{
					id: "audit-export",
					label: "Export audit archive",
					owner: "compliance",
					run_id: jobs_b.job_c_id,
					state: job_c_state,
					progress: jobs_b.job_c_progress,
					age_min: jobs_b.job_c_age_min,
				},
				{
					id: "session-prune",
					label: "Prune stale sessions",
					owner: "identity",
					run_id: jobs_b.job_d_id,
					state: job_d_state,
					progress: jobs_b.job_d_progress,
					age_min: jobs_b.job_d_age_min,
				},
			],
			alerts: [
				{ id: alert_id(alert_a_kind), kind: alert_a_kind, age_min: alerts.alert_a_age_min },
				{ id: alert_id(alert_b_kind), kind: alert_b_kind, age_min: alerts.alert_b_age_min },
				{ id: alert_id(alert_c_kind), kind: alert_c_kind, age_min: alerts.alert_c_age_min },
			],
		},
	)
}

map_json_result : Str, Try(a, Json) -> Try(a, Dashboard.ParseErr)
map_json_result = |label, result|
	match result {
		Ok(value) => Ok(value)
		Err(MissingRequired) => Err(MissingData(label))
		Err(InvalidJson) => Err(BadJson)
	}

get_bar_code : Str, U64 -> Try(U64, Dashboard.ParseErr)
get_bar_code = |name, value| {
	if value <= 8 {
		Ok(value)
	} else {
		Err(BadCode(name))
	}
}

decode_phase : U64 -> Try(Dashboard.Phase, Dashboard.ParseErr)
decode_phase = |code|
	if code == 0 {
		Ok(PhaseSteady)
	} else if code == 1 {
		Ok(PhaseWatch)
	} else if code == 2 {
		Ok(PhaseActiveIncident)
	} else if code == 3 {
		Ok(PhaseRecovering)
	} else {
		Err(BadCode("phase_code"))
	}

decode_health : Str, U64 -> Try(Dashboard.Health, Dashboard.ParseErr)
decode_health = |name, code|
	if code == 0 {
		Ok(HealthOk)
	} else if code == 1 {
		Ok(HealthWatch)
	} else if code == 2 {
		Ok(HealthDegraded)
	} else {
		Err(BadCode(name))
	}

decode_queue_trend : U64 -> Try(Dashboard.QueueTrend, Dashboard.ParseErr)
decode_queue_trend = |code|
	if code == 0 {
		Ok(TrendDraining)
	} else if code == 1 {
		Ok(TrendSteady)
	} else if code == 2 {
		Ok(TrendRising)
	} else {
		Err(BadCode("queue_trend_code"))
	}

decode_job_state : Str, U64 -> Try(Dashboard.JobState, Dashboard.ParseErr)
decode_job_state = |name, code|
	if code == 0 {
		Ok(JobRunning)
	} else if code == 1 {
		Ok(JobQueued)
	} else if code == 2 {
		Ok(JobRetrying)
	} else if code == 3 {
		Ok(JobBlocked)
	} else {
		Err(BadCode(name))
	}

decode_alert_kind : Str, U64 -> Try(Dashboard.AlertKind, Dashboard.ParseErr)
decode_alert_kind = |name, code|
	if code == 1 {
		Ok(AlertCriticalCheckout)
	} else if code == 2 {
		Ok(AlertWorkerQueue)
	} else if code == 3 {
		Ok(AlertEdgeCanary)
	} else if code == 4 {
		Ok(AlertPaymentRecovering)
	} else if code == 5 {
		Ok(AlertEdgeSteady)
	} else {
		Err(BadCode(name))
	}

alert_id : Dashboard.AlertKind -> Str
alert_id = |kind|
	match kind {
		AlertCriticalCheckout => "checkout-latency"
		AlertWorkerQueue => "worker-queue"
		AlertEdgeCanary => "edge-canary"
		AlertPaymentRecovering => "payment-recovery"
		AlertEdgeSteady => "edge-steady"
	}
