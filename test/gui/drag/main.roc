app [main] { pf: platform "../../../platform-gui/main.roc" }

import pf.Elem exposing [Elem]
import pf.Gui
import pf.Ui

main : () -> Elem
main = || Ui.state(
	"none",
	|last| {
		Gui.column(
			[],
			[
				Gui.heading("Internal drag and drop"),
				Gui.panel([Gui.test_id("drag-source"), Gui.drag_source("task-λ")], [Gui.text("Drag this task")]),
				Gui.panel([Gui.test_id("drop-target"), Gui.drop_target(last.on_detail(|_, key| key))], [Gui.text("Drop here")]),
				Gui.text_s(last.signal().map(|key| "Dropped: ${key}")),
			],
		)
	},
)
