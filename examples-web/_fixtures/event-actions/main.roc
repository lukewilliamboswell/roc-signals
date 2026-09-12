app [main] { pf: platform "../../../platform-web/main.roc", roc: "nightly-2026-09-11-793f9d8" }

import pf.Action
import pf.Http
import pf.Elem exposing [Elem]
import pf.Html
import pf.Signal
import pf.Ui

main : () -> Elem
main = || Ui.state(
	"idle",
	|ping_result| Ui.state(
		"idle",
		|disposal_result| {
			Ui.state(
				"alpha",
				|source|
					Ui.state(
						"waiting",
						|result|
							Ui.state(
								True,
								|visible| {
									status = ping_result.signal()
									dispose_status = disposal_result.signal()
									action_reads = { source: source.signal(), result: result.signal() }.Signal
									Html.div_c(
										"",
										[
											Html.heading("Event actions"),
											Html.text_input("Source", source.signal(), source.update_str(|_, text| text)),
											Html.paragraph_s_attrs(result.signal(), [Html.test_id("result")]),
											Html.text_input_attrs(
												"Action text",
												Signal.const(""),
												[Html.test_id("action-text")],
												Ui.action_str(action_reads, |reads, text| result.set_cmd("${reads.result}|text:${reads.source}:${text}")),
											),
											Html.checkbox_attrs(
												"Action check",
												Signal.const(False),
												[Html.test_id("action-check")],
												Ui.action_bool(action_reads, |reads, checked| result.set_cmd("${reads.result}|checked:${Str.inspect(checked)}")),
											),
											Html.text_input_attrs(
												"Action key",
												Signal.const(""),
												[Html.test_id("action-key"), Html.on_key_down(Ui.action_key(action_reads, |reads, key| result.set_cmd("${reads.result}|key:${key.key}:${Str.inspect(key.shift_key)}")))],
												source.update_str(|current, _text| current),
											),
											Html.div(
												[
													Html.test_id("action-detail"),
													Html.on_custom("demo-detail", Ui.action_detail(action_reads, |reads, detail| result.set_cmd("${reads.result}|detail:${detail}"))),
												],
												[Html.text("Custom action target")],
											),
											Html.paragraph_s_attrs(status, [Html.test_id("status")]),
											Html.paragraph_s_attrs(dispose_status, [Html.test_id("dispose-status")]),
											Html.button("Prime disposal", Action.run(source.signal(), |_value| Action.then([disposal_result.set("idle")], |read| send!(disposal_result, "/api/action-dispose", read)))),
											Ui.when(
												Signal.map(dispose_status, |value| value == "ready"),
												|| Html.button("Dispose on loading", Action.run(source.signal(), |_value| Action.then([disposal_result.set("idle")], |read| send!(disposal_result, "/api/action-dispose", read)))),
												|| Html.text("Disposal action hidden"),
											),
											Html.button("Toggle actions", visible.update(|value| !value)),
											Ui.when(
												visible.signal(),
												|| Html.div_c(
													"",
													[
														Html.button(
															"Append snapshot",
															Ui.action(
																{ source: source.signal(), result: result.signal() }.Signal,
																|reads| result.set_cmd("${reads.result}|${reads.source}"),
															),
														),
														Html.button("Ping", Action.run(source.signal(), |_value| Action.then([], |read| send!(ping_result, "/api/action-ping", read)))),
													],
												),
												|| Html.text("Actions hidden"),
											),
										],
									)
								},
							),
					),
			)
		},
	),
)

send! : Ui.State(Str), Str, Str => Action(Str)
send! = |state, uri, body| {
	request = Http.request_from_method(Http.method_post).with_uri(uri).with_body(body.to_utf8())
	result = match Http.send!(request) {
		Err(error) => Str.inspect(error)
		Ok(response) => if Http.response_status(response) == 200 {
			Str.from_utf8(Http.response_body(response)) ?? "Invalid UTF-8 response"
		} else {
			"HTTP ${Http.response_status(response).to_str()}"
		}
	}
	Action.update([state.set(result)])
}
