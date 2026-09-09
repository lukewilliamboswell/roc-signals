app [main] { pf: platform "../../../platform-gui/main.roc" }

import pf.Elem exposing [Elem]
import pf.Gui
import pf.Signal
import pf.Ui

main : () -> Elem
main = || Ui.state(
	KeepOpen,
	|decision| Gui.window_lifecycle(
		{ on_close_requested: decision.on_unit(|_| AwaitDecision), decision: decision.signal() },
		[
			Gui.column(
				[],
				[
					Gui.heading("Window close contract"),
					Gui.text_s(
						decision.signal().map(
							|value| match value {
								KeepOpen => "Open"
								AwaitDecision => "Deciding"
								Close => "Approved"
							},
						),
					),
					Gui.button("Keep open", decision.on_unit(|_| KeepOpen)),
					Gui.button("Approve close", decision.on_unit(|_| Close)),
				],
			),
		],
	),
)
