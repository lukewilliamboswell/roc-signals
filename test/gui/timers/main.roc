app [main] { pf: platform "../../../platform-gui/main.roc" }

import pf.Action exposing [Action]
import pf.Elem exposing [Elem]
import pf.Signal
import pf.Ui

main : () -> Elem
main = || Ui.state(
	0.U64,
	|count| {
		Elem.col(
			Elem.ColProps.{},
			[
				Elem.heading("Scoped timer lifetime"),
				Elem.text_s(count.read(|value| "Ticks: ${value.to_str()}")),
				Ui.when(
					count.read(|value| value < 2),
					|| {
						Action.on_change(Signal.interval(100), |value| Action.update([count.write(|_| value)]))
					},
					|| Elem.text("Paused after 2 ticks"),
				),
				Elem.button("Restart", count.update(|_| 0)),
			],
		)
	},
)
