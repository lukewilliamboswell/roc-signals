app [main] { pf: platform "https://github.com/lukewilliamboswell/roc-signals/releases/download/0.1/3eLQGNMDG9RuL9sn1A7ep1Rtq7QGmemE89y141WSv1XG.tar.zst" }

import pf.Elem exposing [Elem]
import pf.Html
import pf.Http
import pf.Signal
import pf.Ui

page_class : Str
page_class = "grid gap-5"

panel_class : Str
panel_class = "grid gap-3 rounded-lg border border-sky-200 bg-sky-50 p-5"

button_class : Str
button_class = "border-sky-600 bg-sky-600 text-white hover:border-sky-700 hover:bg-sky-700"

header_value = |headers, target|
	match List.find_first(headers, |(name, _)| name == target) {
		Ok((_, value)) => value
		Err(_) => "missing"
	}

body_text = |response|
	match Str.from_utf8(Http.response_body(response)) {
		Ok(text) => text
		Err(_) => Str.from_utf8_lossy(Http.response_body(response))
	}

status_text = |response| Str.concat("Status: ", Http.response_status(response).to_str())

result_header_text = |response| Str.concat("Result header: ", header_value(Http.response_headers(response), "x-result"))

response_body_text = |response| Str.concat("Body: ", body_text(response))

failure_text = |err| Str.concat("Failed: ", Http.error_text(err))

request = {
	base0 = Http.request_from_method(Http.method_post)
	base1 = Http.with_uri(base0, "/api/http-boundary")
	base2 = Http.add_header(base1, "content-type", "text/plain")
	base3 = Http.add_header(base2, "x-scenario", "native")
	base4 = Http.with_body(base3, Str.to_utf8("ping"))
	Http.with_timeout_ms(base4, 1500)
}

main : {} -> Elem
main = |_| {
	Ui.state(
		0,
		|retry| {
			task = Http.request_task("boundary")
			status = Signal.fold_task(task, "Status: loading", status_text, failure_text)
			header = Signal.fold_task(task, "Result header: waiting", result_header_text, |_| "Result header: failed")
			body = Signal.fold_task(task, "Body: waiting", response_body_text, |_| "Body: failed")

			Html.div_c(
				page_class,
				[
					Html.section_c(
						"HTTP boundary",
						panel_class,
						[
							Html.heading_c("HTTP boundary", "text-3xl font-semibold text-zinc-950"),
							Html.text_s(status),
							Html.text_s(header),
							Html.text_s(body),
							Html.button_c("Retry HTTP request", button_class, retry.on_unit(|count| count + 1)),
							Ui.on_mount(|_| Http.start(task, request)),
							Ui.on_change(retry.signal(), |_| Http.start(task, request)),
						],
					),
				],
			)
		},
	)
}
