app [Instance, main] { pf: platform "../../platform/main.roc" }

import pf.Engine exposing [Comp, Elem, Root, Row, RowRef, State, Val]

Instance : Engine.App

Item : { title : Str }

P : { views : List(Item), name : Str }

CC : Comp(P, Str)

card_row : State(CC, List(Str)), RowRef(CC, Item) -> Elem(Row(CC, Item))
card_row = |_out, row| Engine.element("li", [], [Engine.text_v(row.key())])

col : Val(CC, P), State(CC, List(Str)) -> Elem(CC)
col = |cp, out| {
	_slug = |prefix| cp.map(|p| "${prefix}-${p.name}")
	Engine.element("section", [], [Engine.each(cp.map(|p| p.views), |v| v.title, |row| Engine.element("li", [], [Engine.text_v(row.key())]))])
}

view : Elem(Root)
view = Engine.state([], |s| Engine.component(s.val().map(|l| { views: l, name: "x" }), Engine.sink(s, |l, a| l.append(a)), col))

main : Engine.Program(Instance)
main = Engine.program(|| view)
