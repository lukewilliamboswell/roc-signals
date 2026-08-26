app [main] { pf: platform "../../../platform/main.roc" }

import pf.Elem exposing [Elem]
import pf.Html
import pf.Signal
import pf.Ui

main : () -> Elem
main = || {
	ticks = Signal.interval(1000)
	task = Signal.fake_task("state-command-task", |value| value, |err| err)

	Ui.state(
		0,
		|count|
			Ui.state(
				"waiting",
				|result|
					Html.div_c(
						"",
						[
							Html.heading("State commands"),
							Html.paragraph_s_attrs(count.signal().map(|value| "Count: ${value.to_str()}"), [Html.test_id("count")]),
							Html.paragraph_s_attrs(result.signal(), [Html.test_id("result")]),
							Ui.on_change(ticks, |value| count.set_cmd(value)),
							Ui.on_change(
								Signal.from_task(task),
								|status|
									match status {
										Loading => result.set_cmd("loading"),
										Done(value) => result.set_cmd("done:${value}"),
										Failed(err) => result.set_cmd("failed:${err}"),
									},
							),
							Ui.on_mount(|| Signal.start_str(task, "request")),
						],
					)
			),
	)
}
