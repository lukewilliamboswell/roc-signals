app [main] { pf: platform "../../../platform/main.roc" }

import pf.Elem exposing [Elem]
import pf.Html
import pf.Signal
import pf.Ui

main : () -> Elem
main = ||
	Ui.state(
		"alpha",
		|source|
			Ui.state(
				"waiting",
				|result|
					Ui.state(
						True,
						|visible| {
							task = Signal.fake_task("action-ping", |value| value, |err| err)
							status = Signal.fold_task(task, "idle", |value| value, |err| err)
							dispose_task = Signal.fake_task("action-dispose", |value| value, |err| err)
							dispose_status = Signal.fold_task(dispose_task, "idle", |value| value, |err| err)
							action_reads = { source: source.signal(), result: result.signal() }.Signal
							Html.div_c(
								"",
								[
									Html.heading("Event actions"),
									Html.text_input("Source", source.signal(), source.on_str(|_, text| text)),
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
										source.on_str(|current, _text| current),
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
									Html.button("Prime disposal", Ui.action(source.signal(), |value| Signal.start_str(dispose_task, value))),
									Ui.when(
										Signal.map(dispose_status, |value| value == "ready"),
										|| Html.button("Dispose on loading", Ui.action(source.signal(), |value| Signal.start_str(dispose_task, value))),
										|| Html.text("Disposal action hidden"),
									),
									Html.button("Toggle actions", visible.on_unit(|value| !value)),
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
												Html.button("Ping", Ui.action(source.signal(), |value| Signal.start_str(task, value))),
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
