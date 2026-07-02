app [main] { pf: platform "../../../platform/main.roc" }

import pf.Elem exposing [Elem]
import pf.Html
import pf.Signal
import pf.Ui

request_text : U64 -> Str
request_text = |version| Str.concat("/api/latest/", version.to_str())

main : {} -> Elem
main = |_| {
	Ui.state(
		0,
		|version| {
			task = Signal.fake_task("lookup", |value| value, |err| err)
			label = 
				Signal.fold_task(
					task,
					"Task status: loading",
					|value| Str.concat("Task status: done ", value),
					|err| Str.concat("Task status: failed ", err),
				)
			request = Signal.map(version.signal(), request_text)

			Html.div_c(
				"",
				[
					Html.heading("Task latest wins"),
					Html.button("Refresh", version.on_unit(|value| value + 1)),
					Html.text_s(label),
					Ui.on_mount(|_| Signal.start_str(task, request_text(0))),
					Ui.on_change(request, |value| Signal.start_str(task, value)),
				],
			)
		},
	)
}
