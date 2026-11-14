import pf.Engine
import pf.Html

## Raw type spellings stay observable while browser control defaults govern
## editing, commit-on-blur and the form's implicit/default submission actions.
EffectiveTypesApp := [].{
	field : Str, [Missing, Raw(Str)] -> Engine.Elem(ctx)
	field = |label, kind| Engine.state(
		{ value: "", committed: "", changes: 0.U64 },
		|state| Engine.element(
			"div",
			[],
			[
				Engine.element(
					"input",
					[
						Html.aria_label(label),
						Engine.prop_s(Engine.Prop.value, state.signal().map(|s| s.value)),
						Html.on_input(state.set_value(|s, value| { ..s, value })),
						Html.on_change(state.set_value(|s, value| { ..s, committed: value, changes: s.changes + 1 })),
					].concat(
						match kind {
							Missing => []
							Raw(value) => [Engine.attr("type", value)]
						},
					),
					[],
				),
				Html.p_s(state.signal().map(|s| "${s.committed}:${s.changes.to_str()}"), [Engine.test_id("commit-${label}")]),
			],
		),
	)

	FormProps := { name : Str, two_inputs : Bool ?? False, button : Bool ?? False }

	form : FormProps -> Engine.Elem(ctx)
	form = |props| Engine.state(
		0.U64,
		|submitted| Engine.element(
			"form",
			[Html.aria_label(props.name), Html.on_submit(submitted.update(|count| count + 1))],
			[
				Engine.element("input", [Html.aria_label("${props.name} input"), Engine.attr("type", "txet")], []),
				Html.p_s(submitted.signal().map(|count| count.to_str()), [Engine.test_id("submitted-${props.name}")]),
			].concat(
				if props.two_inputs {
					[Engine.element("input", [Html.aria_label("${props.name} second"), Engine.attr("type", "text")], [])]
				} else [],
			).concat(
				if props.button {
					[Engine.element("button", [Engine.attr("type", "sumbit")], [Engine.text("Invalid submit button")])]
				} else [],
			),
		),
	)

	view : {} -> Engine.Elem(ctx)
	view = |_| Engine.element(
		"section",
		[],
		[
			EffectiveTypesApp.field("Absent", Missing),
			EffectiveTypesApp.field("Empty", Raw("")),
			EffectiveTypesApp.field("Mixed", Raw("Text")),
			EffectiveTypesApp.field("Invalid", Raw("txet")),
			EffectiveTypesApp.field("Padded", Raw(" text ")),
			EffectiveTypesApp.field("NonASCII", Raw("TÉXT")),
			EffectiveTypesApp.form({ name: "one" }),
			EffectiveTypesApp.form({ name: "two", two_inputs: True }),
			EffectiveTypesApp.form({ name: "button", button: True }),
		],
	)
}
