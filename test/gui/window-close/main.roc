app [main] { pf: platform "../../../platform-gui/main.roc" }

import pf.Elem exposing [Elem]
import pf.Signal
import pf.Ui

main : () -> Elem
main = || Ui.state(
	KeepOpen,
	|decision| Elem.window_lifecycle(
		{ on_close_requested: decision.update(|_| AwaitDecision), decision: decision.signal() },
		[
			Elem.col(
				Elem.ColProps.{},
				[
					Elem.heading("Window close contract"),
					Elem.text_s(
						decision.read(
							|value| match value {
								KeepOpen => "Open"
								AwaitDecision => "Deciding"
								Close => "Approved"
							},
						),
					),
					Elem.button("Keep open", decision.update(|_| KeepOpen)),
					Elem.button("Approve close", decision.update(|_| Close)),
				],
			),
		],
	),
)
