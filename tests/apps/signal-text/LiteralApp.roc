import pf.Engine exposing [Elem, In, Root, Signal, State]
import pf.Html

## Text literals and constants retain ordinary control initialization, while
## an interpolation over a row selection updates only the old and new rows.
LiteralApp := [].{
	S : { selected : Str, focus : Engine.Outbox(Str) }
	Ctx : In(Root, S)

	controls : Signal(ctx, Str), State(ctx, S) -> Elem(ctx)
	controls = |name, state| Html.div(
		"",
		[
			Html.select("${name} select", "two", Engine.const(["one", "two"]), { key: |choice| choice, label: |choice| if (choice == "one") "One" else "Two" }, [Engine.test_id_s("${name}-select")], state.update(|held| held)),
			Html.checkbox("${name} checked", Engine.const(True), [Engine.test_id_s("${name}-checked")], state.update(|held| held)),
			Html.text_input("${name} input", "text", "draft", [Engine.ref_s("${name}-input")], state.update(|held| held)),
			Html.p_s("fixed text", [Engine.attr_s("title", "fixed title"), Engine.class_s("fixed-class"), Engine.test_id_s("${name}-constant"), Engine.attr_presence("data-empty", Engine.const(Present("")))]),
		],
	)

	view : State(Ctx, S) -> Elem(Ctx)
	view = |state| {
		selection = Engine.keyed(state.signal().map(|s| s.selected), "yes", "no")
		Html.div(
			"",
			[
				LiteralApp.controls("block", state),
				Engine.element("select", [Engine.attr("aria-label", "static property"), Engine.prop(Engine.Prop.value, "two")], [Engine.element("option", [Engine.prop(Engine.Prop.value, "one")], [Engine.text("One")]), Engine.element("option", [Engine.prop(Engine.Prop.value, "two")], [Engine.text("Two")])]),
				Engine.each(Engine.const(["left", "right"]), |key| key, |row| LiteralApp.controls(row.key(), state.lift_row())),
				Html.button("Focus left", [], state.update(|s| { ..s, focus: s.focus.post("left-input") })),
				Engine.on_post(state.signal().map(|s| s.focus), |name| [Engine.command(Focus(name))], Engine.ignore({})),
				Html.button("Choose row-0", [], state.update(|s| { ..s, selected: "row-0" })),
				Html.button("Choose row-1", [], state.update(|s| { ..s, selected: "row-1" })),
				Html.button("Choose row-2", [], state.update(|s| { ..s, selected: "row-2" })),
				Engine.each(
					Engine.const(["row-0", "row-1", "row-2", "row-3", "row-4", "row-5", "row-6", "row-7"]),
					|key| key,
					|row| {
						key = row.key()
						selected = row.select(selection)
						Html.p_s("${key}", [Engine.test_id_s("choice-${key}"), Engine.attr_s("data-choice", "${selected} ${key}")])
					},
				),
			],
		)
	}

	program : Engine.Program
	program = Engine.program(|| Engine.state({ selected: "row-0", focus: Engine.outbox({}) }, LiteralApp.view))
}
