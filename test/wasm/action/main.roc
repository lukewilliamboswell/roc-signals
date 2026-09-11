app [main] { pf: platform "../../../platform-web/main.roc", roc: "nightly-2026-09-04-c125b82" }

import pf.Action exposing [Action]
import pf.Elem exposing [Elem]
import pf.Html
import pf.Ui

main : () -> Elem
main = || Ui.state(
	0.I64,
	|count| {
		Html.div(
			[],
			[
				Html.text_s(count.signal().map(|n| "Count: ${n.to_str()}")),
				Html.button(
					"Run",
					Action.run(
						Action.sampled(count.signal().map(|n| n.to_str()), count.signal()),
						|_| {
							Action.then([count.write(|n| n + 1)], |snapshot| first!(count, snapshot))
						},
					),
				),
			],
		)
	},
)

first! : Ui.State(I64), I64 => Action(I64)
first! = |count, snapshot| Action.then([count.write(|n| n + snapshot)], |fresh| second!(count, fresh))

second! : Ui.State(I64), I64 => Action(I64)
second! = |count, fresh| Action.update([count.write(|n| n + fresh)])
