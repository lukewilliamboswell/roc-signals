app [main] { pf: platform "../../platform-web/main.roc", roc: "nightly-2026-09-09-7dadc35" }

import pf.Elem exposing [Elem]
import pf.Html
import pf.Rows
import pf.Signal
import pf.Ui

QNode := [Group(List(QNode)), Leaf].{
	is_eq : QNode, QNode -> Bool
	is_eq = |left, right|
		match (left, right) {
			(Group(xs), Group(ys)) => xs.is_eq(ys)
			(Leaf, Leaf) => True
			_ => False
		}
}

children : QNode -> List(QNode)
children = |node|
	match node {
		Group(items) => items
		Leaf => []
	}

key : QNode -> Str
key = |node|
	match node {
		Group(_) => "group"
		Leaf => "leaf"
	}

render_group : Ui.State(QNode), Signal.Signal(QNode) -> Elem
render_group = |tree, node| {
	rows = node.map(|value| Rows.from_list(children(value), key) ?? crash "duplicate key")
	Html.div_c("group", [Ui.each(rows, |row| render_node(tree, row.signal()))])
}

render_node : Ui.State(QNode), Signal.Signal(QNode) -> Elem
render_node = |tree, node| {
	is_group = node.map(|value| match value {
		Group(_) => True
		Leaf => False
	})
	Ui.when(is_group, || render_group(tree, node), || Html.text("leaf"))
}

main : () -> Elem
main = || Ui.state(QNode.Group([QNode.Leaf]), |tree| render_group(tree, tree.signal()))
