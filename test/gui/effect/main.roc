app [main] { pf: platform "../../../platform-gui/main.roc" }

import pf.Effect
import pf.Elem exposing [Elem]
import pf.Env
import pf.Signal
import pf.Ui

## Exercises `Effect.run`: a button starts an effect task whose closure calls
## the hosted `Env.var!`, and the outcome arrives through the task's status.
main : () -> Elem
main = || {
	greet = Effect.task("fixture-effect", |text| text, |text| text)
	status = Signal.fold_task(greet, "Idle", |text| "Done: ${text}", |err| "Failed: ${err}")
	Elem.col(
		{ test_id: "effect-fixture" },
		[
			Elem.heading("Effect fixture"),
			Elem.text_s(status),
			Elem.button(
				"Succeed",
				Ui.action(
					Signal.const("HOME"),
					|name| Effect.run(
						greet,
						|| match Env.var!(name) {
							Ok(value) => if value.is_empty() { Err("${name} is empty") } else { Ok("${name} is set") }
							Err(Missing) => Err("${name} is missing")
						},
					),
				),
			),
			Elem.button("Fail", Ui.action(Signal.const({}), |_| Effect.run(greet, || Err("boom")))),
		],
	)
}
