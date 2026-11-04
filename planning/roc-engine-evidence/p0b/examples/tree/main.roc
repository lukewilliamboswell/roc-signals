app [main] { roc: "nightly-2026-11-01-48d3369", pf: platform "../../main.roc" }

import pf.Elem
import pf.Html
import pf.Rows
import pf.Ui

## A recursive tree (comment thread, file explorer) with `Ui.tree`: every
## depth shares one context type, so `node_view` is ordinary recursion-free code.
Node := { id : Str, label : Str, children : Rows(Node) }.{
	is_eq : Node, Node -> Bool
	is_eq = |a, b| a.id == b.id and a.label == b.label and a.children == b.children
}

NodeCtx : Ui.Site(Ui.Up(Ui.Root, Node), Node)

rename : Rows(Node), Str -> Rows(Node)
rename = |rows, _key| rows

node_view : Ui.State(Rows(Node)), Ui.RowRef(Ui.Up(Ui.Root, Node), Node) -> Elem(NodeCtx)
node_view = |model, node|
	Html.element(
		"li",
		[],
		[
			Html.text_s(node.field(|value| value.label)),
			Html.button("Rename", model.update_by(node.key(), rename)),
			Html.element("ul", [], [Ui.children(node, |value| value.children)]),
		],
	)

main : () -> Elem(Ui.Root)
main = || {
	empty : Rows(Node)
	empty = Rows.empty(|value| value.id)
	Ui.state(empty, |model| Html.element("ul", [], [Ui.tree(model.signal(), |node| node_view(model, node))]))
}

## The root description builds; the tree template is described once.
expect {
	actual = Elem.platform_describe(main())
	actual == "<ul:0>{tree <li:0>{val}<button:1>Rename</button><ul:0>{children}</ul></li>}</ul>"
}
