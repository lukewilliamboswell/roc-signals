app [main] { roc: "nightly-2026-11-01-48d3369", pf: platform "../../main.roc" }

import pf.Elem
import pf.Html
import pf.Rows
import pf.Ui

## A recursive tree (comment thread, file explorer). Each level of nesting is a
## new context, so the view must be polymorphically recursive in `ctx`.
Node := { id : Str, label : Str, children : Rows(Node) }.{
	is_eq : Node, Node -> Bool
	is_eq = |a, b| a.id == b.id and a.label == b.label and a.children == b.children
}

node_view : Ui.RowRef(ctx, Node) -> Elem(Ui.Site(ctx, Node))
node_view = |node|
	Html.element(
		"li",
		[],
		[
			Html.text_s(node.field(|value| value.label)),
			Html.element("ul", [], [Ui.each(node.field(|value| value.children), |child| node_view(child))]),
		],
	)

main : () -> Elem(Ui.Root)
main = || {
	empty : Rows(Node)
	empty = Rows.empty(|value| value.id)
	Ui.state(empty, |model| Html.element("ul", [], [Ui.each(model.signal(), node_view)]))
}
