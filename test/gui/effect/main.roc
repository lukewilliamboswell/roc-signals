app [main] { pf: platform "../../../platform-gui/main.roc" }

import pf.Effect
import pf.Elem exposing [Elem]
import pf.Signal
import pf.Ui

## Exercises `Effect.run`: a button starts an effect task whose closure is
## effectful Roc code, and the outcome arrives through the task's status.
main : () -> Elem
main = || {
	greet = Effect.task("fixture-effect", |text| text, |text| text)
	status = Signal.fold_task(greet, "Idle", |text| "Done: ${text}", |err| "Failed: ${err}")
	Elem.col(
		{ test_id: "effect-fixture" },
		[
			Elem.heading("Effect fixture"),
			Elem.text_s(status),
			Elem.button("Succeed", Ui.action(Signal.const("hello"), |word| Effect.run(greet, || Ok("${word} from an effect")))),
			Elem.button("Fail", Ui.action(Signal.const({}), |_| Effect.run(greet, || Err("boom")))),
		],
	)
}
