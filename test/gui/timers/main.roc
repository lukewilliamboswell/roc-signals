app [main] { pf: platform "../../../platform-gui/main.roc" }

import pf.Elem exposing [Elem]
import pf.Gui
import pf.Signal
import pf.Ui

main : () -> Elem
main = || Ui.state(
	0.U64,
	|count| {
		Gui.column(
			[],
			[
				Gui.heading("Scoped timer lifetime"),
				Gui.text_s(count.signal().map(|value| "Ticks: ${value.to_str()}")),
				Ui.when(
					count.signal().map(|value| value < 2),
					|| {
						Ui.on_change(Signal.interval(100), |value| count.update_cmd(|_| value))
					},
					|| Gui.text("Paused after 2 ticks"),
				),
				Gui.button("Restart", count.on_unit(|_| 0)),
			],
		)
	},
)
