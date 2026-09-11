app [main] { pf: platform "../../../platform-web/main.roc", roc: "nightly-2026-09-04-c125b82" }

import pf.Action
import pf.Http
import pf.Elem exposing [Elem]
import pf.Html
import pf.Signal
import pf.Ui

source_commands : () -> Elem
source_commands = || {
	ticks = Signal.interval(1000)

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
							Action.on_change_initial(Signal.const({}), |_| Action.then([], |_| load_result!(result))),
						],
					),
			),
	)
}

load_result! : Ui.State(Str) => Action({})
load_result! = |result| {
	text = match Http.get_text!("/api/state-command") {
		Ok(value) => "done:${value}"
		Err(error) => "failed:${Str.inspect(error)}"
	}
	Action.update([result.set(text)])
}

history_panel : () -> Elem
history_panel = || Ui.state(
	"",
	|history| Ui.state(
		False,
		|running| {
			append = history.update_cmd(|current| "${current}event;")
			Html.div(
				[],
				[
					Html.paragraph_s_attrs(history.signal(), [Html.test_id("history")]),
					Html.button("Append event", Ui.action(Signal.const({}), |_| append)),
					Html.button("Unchanged history", Ui.action(Signal.const({}), |_| history.update_cmd(|current| current))),
					Html.button("Toggle history clock", running.update(|current| !current)),
					Ui.when(
						running.signal(),
						|| {
							Ui.on_change(Signal.interval(250), |_| append)
						},
						|| Html.text("History clock stopped"),
					),
				],
			)
		},
	),
)

main : () -> Elem
main = || Html.div([], [source_commands(), history_panel()])
