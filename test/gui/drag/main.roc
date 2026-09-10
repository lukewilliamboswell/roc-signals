app [main] { pf: platform "../../../platform-gui/main.roc" }

import pf.Elem exposing [Elem]
import pf.Gui
import pf.Ui

main : () -> Elem
main = || Ui.state(
	"none",
	|last| {
		Gui.column(
			Gui.ColumnProps.{},
			[
				Gui.heading("Internal drag and drop"),
				Gui.panel({ test_id: "drag-source", drag_source: "task-λ" }, ["Drag this task"]),
				Gui.panel({ test_id: "drop-target", on_drop: last.on_detail(|_, key| key) }, ["Drop here"]),
				Gui.text_s(last.signal().map(|key| "Dropped: ${key}")),
			],
		)
	},
)
