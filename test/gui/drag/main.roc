app [main] { pf: platform "../../../platform-gui/main.roc" }

import pf.Elem exposing [Elem]
import pf.Ui

main : () -> Elem
main = || Ui.state(
	"none",
	|last| {
		Elem.col(
			Elem.ColProps.{},
			[
				Elem.heading("Internal drag and drop"),
				Elem.panel({ test_id: "drag-source", drag_source: "task-λ" }, ["Drag this task"]),
				Elem.panel({ test_id: "drop-target", on_drop: last.update_detail(|_, key| key) }, ["Drop here"]),
				Elem.text_s(last.read(|key| "Dropped: ${key}")),
			],
		)
	},
)
