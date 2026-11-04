app [main] { pf: platform "platform/scale.roc" }
import pf.Elem exposing [Elem]
import pf.Html
import pf.Ui
import TaskPanel

main : () -> Elem
main = || Ui.state(True, |visible| Html.div([], [
	Html.button("Clear", visible.update(|_| False)),
	Ui.when(visible.signal(), || {
		var $children = List.with_capacity(1000)
		var $i = 0.U64
		while $i < 1000 {
			$children = $children.append(TaskPanel.view("Row ${$i.to_str()}"))
			$i = $i + 1
		}
		Html.div([], $children)
	}, || Html.text("empty")),
]))
