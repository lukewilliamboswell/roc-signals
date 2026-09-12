app [main] { pf: platform "../../../platform-web/main.roc", roc: "nightly-2026-09-11-793f9d8" }

import pf.Action
import pf.Elem exposing [Elem]
import pf.Html
import pf.Http
import pf.Signal
import pf.Ui

Status := [Loading, Done(Str), Failed(Str), Ignored].{
	is_eq : _
}

Model : { request : U64, generation : U64, status : Status }

status_text : Status -> Str
status_text = |status| match status {
	Loading => "Loading"
	Done(value) => "Done: ${value}"
	Failed(error) => "Failed: ${error}"
	Ignored => "Result ignored"
}

ignore_result : Model -> Model
ignore_result = |current| match current.status {
	Ignored => current
	_ => { ..current, generation: current.generation + 1, status: Ignored }
}

fetch! : Ui.State(Model), U64, U64 => Action(Model)
fetch! = |state, request, generation| {
	status = match Http.get_text!("/api/latest/${request.to_str()}") {
		Ok(value) => Done(value)
		Err(error) => Failed(Str.inspect(error))
	}
	Action.update([
		state.write(
			|current| if current.generation == generation {
				{ ..current, status }
			} else {
				current
			},
		),
	])
}

main : () -> Elem
main = || Ui.state(
	{ request: 0.U64, generation: 0.U64, status: Loading },
	|state| {
		reads = state.signal()
		Html.div_c(
			"",
			[
				Html.heading("Effect latest wins"),
				Html.button("Refresh", state.update(|current| { ..current, request: current.request + 1 })),
				Html.button("Ignore result", state.update(ignore_result)),
				Html.paragraph_s_attrs(reads.map(|current| status_text(current.status)), [Html.test_id("status")]),
				Action.on_change_initial(
					Action.sampled(reads.map(|current| current.request), reads),
					|read| {
						generation = read.generation + 1
						Action.then([state.write(|current| { ..current, generation, status: Loading })], |_| fetch!(state, read.request, generation))
					},
				),
			],
		)
	},
)
