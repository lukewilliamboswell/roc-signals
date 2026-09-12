app [main] { pf: platform "../../../platform-web/main.roc", roc: "nightly-2026-09-11-793f9d8" }

import pf.Elem exposing [Elem]
import pf.Action exposing [Action]
import pf.Html
import pf.Http
import pf.Signal
import pf.Ui

TaskState := [Loading, Ready(Str), Measured(U64), Failed(U64)].{
	is_eq : _
}

decode : Str -> TaskState
decode = |body| Ready(body)

failed : Str -> TaskState
failed = |err| Failed(err.to_utf8().len())

state_text : TaskState -> Str
state_text = |state|
	match state {
		Loading => "loading"
		Ready(body) => "ready bytes ${body.to_utf8().len().to_str()}"
		Measured(n) => "retained bytes ${n.to_str()}"
		Failed(n) => "failed bytes ${n.to_str()}"
	}

main : () -> Elem
main = || Ui.state(
	Loading,
	|state| {
		text = state.signal().map(state_text)
		Html.div_c(
			"",
			[
				Html.heading("Effect UTF-8 lifetime"),
				Html.text_s(text),
				Html.button(
					"Measure retained body",
					state.update(
						|current| match current {
							Ready(body) => Measured(body.to_utf8().len())
							_ => current
						},
					),
				),
				Action.on_change_initial(Signal.const({}), |_| Action.then([], |_| load!(state))),
			],
		)
	},
)

load! : Ui.State(TaskState) => Action({})
load! = |state| {
	result = match Http.get_text!("/api/ops/dashboard") {
		Ok(body) => decode(body)
		Err(err) => failed(Str.inspect(err))
	}
	Action.update([state.write(|_current| result)])
}
