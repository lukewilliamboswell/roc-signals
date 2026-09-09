app [main] { roc: "nightly-2026-09-09-7dadc35", pf: platform "../../../platform-web/main.roc" }

import pf.Elem exposing [Elem]
import pf.Html
import pf.Signal
import pf.Ui

source_commands : () -> Elem
source_commands = || {
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

history_panel : () -> Elem
history_panel = || Ui.state("", |history| Ui.state(False, |running| {
	append = history.update_cmd(|current| "${current}event;")
	Html.div([], [
		Html.paragraph_s_attrs(history.signal(), [Html.test_id("history")]),
		Html.button("Append event", Ui.action(Signal.const({}), |_| append)),
		Html.button("Unchanged history", Ui.action(Signal.const({}), |_| history.update_cmd(|current| current))),
		Html.button("Toggle history clock", running.on_unit(|current| !current)),
		Ui.when(running.signal(), || {
			Ui.on_change(Signal.interval(250), |_| append)
		}, || Html.text("History clock stopped")),
	])
}))

main : () -> Elem
main = || Html.div([], [source_commands(), history_panel()])
