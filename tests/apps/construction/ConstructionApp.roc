import pf.Engine exposing [Elem, Root]

## Ordinary constructors whose first page is legal and whose event exposes a
## later construction error. The paired contract must observe the same rule
## and site through the native driver and actual browser dispatch.
ConstructionApp := [].{

	## Each mode exercises one deferred mount or text replacement boundary.
	view : Str -> Elem(Root)
	view = |mode| Engine.state(
		Bool.False,
		|changed| Engine.element(
			"main",
			[],
			[
				Engine.element("button", [Engine.on_click(changed.update(|_| Bool.True))], [Engine.text("Trigger construction")]),
				match mode {
					"/branch" => Engine.element("p", [], [Engine.when(changed.signal(), || Engine.element("div", [], []), || Engine.text(""))])
					"/row" => Engine.element("p", [], [Engine.each(changed.signal().map(|value| if (value) [1.U64] else []), |value| value.to_str(), |_row| Engine.element("span", [], [Engine.when(Engine.const(Bool.True), || Engine.element("div", [], []), || Engine.text(""))]))])
					"/state" => Engine.element("p", [], [Engine.when(changed.signal(), || Engine.state(0.U64, |_local| Engine.element("div", [], [])), || Engine.text(""))])
					"/text" => Engine.element("table", [], [Engine.text_s(changed.signal().map(|value| if (value) "bad text" else ""))])
					"/row-text" => Engine.each(changed.signal().map(|value| [if (value) "bad text" else " "]), |_| "one", |row| Engine.element("table", [], [Engine.text_s(row.item())]))
					_ => Engine.text("Choose a construction contract")
				},
			],
		),
	)
}
