app [main] { pf: platform "https://github.com/lukewilliamboswell/roc-signals/releases/download/0.1/3eLQGNMDG9RuL9sn1A7ep1Rtq7QGmemE89y141WSv1XG.tar.zst" }

import pf.Elem exposing [Elem]
import pf.Html
import pf.Http
import pf.Signal
import pf.Ui

page_class = "grid gap-5"

hero_class = "panel grid gap-2 p-5"

panel_class = "panel grid gap-4 p-4"

card_class = "panel grid gap-3 p-4"

toolbar_class = "flex flex-wrap items-center gap-3"

header_value : List(Http.Header), Str -> Str
header_value = |headers, target|
	match headers.find_first(|header| header.name == target) {
		Ok(header) => header.value
		Err(_) => "missing"
	}

body_text : _ -> Str
body_text = |response|
	match Str.from_utf8(Http.response_body(response)) {
		Ok(text) => text
		Err(_) => Str.from_utf8_lossy(Http.response_body(response))
	}

status_text : _ -> Str
status_text = |response| {
	status = Http.response_status(response)
	if status < 300 {
		"Response status: ${status.to_str()}"
	} else {
		"Response needs attention: ${status.to_str()}"
	}
}

result_header_text : _ -> Str
result_header_text = |response| "Result header: ${header_value(Http.response_headers(response), "x-result")}"

response_body_text : _ -> Str
response_body_text = |response| "Response body: ${body_text(response)}"

failure_text : _ -> Str
failure_text = |err| "Request failed: ${Http.error_text(err)}"

scenario_label : Str -> Str
scenario_label = |scenario| {
	if scenario == "missing" {
		"Scenario: missing record"
	} else if scenario == "failure" {
		"Scenario: network failure"
	} else {
		"Scenario: healthy request"
	}
}

request_body_text : Str -> Str
request_body_text = |scenario| {
	if scenario == "missing" {
		"Body: {\"lookup\":\"missing-customer\"}"
	} else if scenario == "failure" {
		"Body: {\"lookup\":\"offline-route\"}"
	} else {
		"Body: {\"lookup\":\"customer-42\"}"
	}
}

request_for : Str -> _
request_for = |scenario| {
	body =
		if scenario == "missing" {
			"{\"lookup\":\"missing-customer\"}"
		} else if scenario == "failure" {
			"{\"lookup\":\"offline-route\"}"
		} else {
			"{\"lookup\":\"customer-42\"}"
		}

	request =
		Http.with_headers(
			Http.request_from_method(Http.method_post)
				.with_uri("/api/api-request-console"),
			[
				{ name: "content-type", value: "application/json" },
				{ name: "x-scenario", value: scenario },
			],
		)
			.with_body(body.to_utf8())

	Http.with_timeout_ms(request, 1500)
}

main : () -> Elem
main = || {
	Ui.state(
		"success",
		|scenario| {
			task = Http.request_task("api-request-console")
			status = Signal.fold_task(task, "Waiting for response", status_text, failure_text)
			header = Signal.fold_task(task, "Result header: waiting", result_header_text, |_| "Result header: failed")
			body = Signal.fold_task(task, "Response body: waiting", response_body_text, |_| "Response body: failed")
			scenario_text = scenario.signal().map(scenario_label)
			request_text = scenario.signal().map(request_body_text)

			Html.div_c(
				page_class,
				[
					Html.section_c(
						"API Request Console",
						hero_class,
						[
							Html.heading_c("API Request Console", "text-3xl font-semibold text-zinc-950"),
							Html.paragraph_c("Send a deterministic POST request and inspect the method, body, response headers, and error states.", "max-w-3xl text-sm text-zinc-700"),
						],
					),
					Html.section_c(
						"Request controls",
						panel_class,
						[
							Html.div_c(
								toolbar_class,
								[
									Html.button_c(
										"Send request",
										"button-primary",
										scenario.on_unit(
											|value| if value == "success-retry" {
												"success"
											} else {
												"success-retry"
											},
										),
									),
									Html.button_c("Use healthy request", "button", scenario.on_unit(|_| "success")),
									Html.button_c("Load missing record", "button", scenario.on_unit(|_| "missing")),
									Html.button_c("Simulate network error", "button", scenario.on_unit(|_| "failure")),
								],
							),
						],
					),
					Html.section_c(
						"Request",
						card_class,
						[
							Html.paragraph("Method: POST"),
							Html.paragraph("URL: /api/api-request-console"),
							Html.paragraph_s(scenario_text),
							Html.paragraph_s(request_text),
						],
					),
					Html.section_c(
						"Response",
						card_class,
						[
							Html.paragraph_s(status),
							Html.paragraph_s(header),
							Html.paragraph_s(body),
						],
					),
					Ui.on_mount(|| Http.start(task, request_for("success"))),
					Ui.on_change(scenario.signal(), |value| Http.start(task, request_for(value))),
				],
			)
		},
	)
}
