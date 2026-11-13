import pf.Engine exposing [Elem]
import pf.Html

## Raw attributes exercise the browser's input classification independently
## of typed constructors. The specs preserve each original attribute spelling.
RawInputApp := [].{
	view : {} -> Elem(ctx)
	view = |_| Engine.state(
		{ checked: False, radio: "", text: "", files: "none" },
		|state| Engine.element(
			"section",
			[],
			[
				Engine.element(
					"input",
					[
						Html.aria_label("Mixed checkbox"),
						Engine.attr("type", "CHECKBOX"),
						Engine.prop_s(Engine.Prop.checked, state.signal().map(|s| s.checked)),
						Engine.on("change", state.set_value(|s, value| { ..s, checked: value == "true" })),
					],
					[],
				),
				Html.p_s(state.signal().map(|s| if (s.checked) "true" else "false"), [Engine.test_id("mixed-checked")]),
				Engine.element(
					"input",
					[
						Html.aria_label("Mixed first"),
						Engine.attr("type", "Radio"),
						Engine.attr("name", "mixed-group"),
						Engine.prop(Engine.Prop.value, "first"),
						Engine.on("change", state.set_value(|s, _| { ..s, radio: "first" })),
					],
					[],
				),
				Engine.element(
					"input",
					[
						Html.aria_label("Mixed second"),
						Engine.attr("type", "RADIO"),
						Engine.attr("name", "mixed-group"),
						Engine.prop(Engine.Prop.value, "second"),
						Engine.on("change", state.set_value(|s, _| { ..s, radio: "second" })),
					],
					[],
				),
				Html.p_s(state.signal().map(|s| s.radio), [Engine.test_id("mixed-radio")]),
				Engine.element(
					"input",
					[
						Html.aria_label("Mixed text"),
						Engine.attr("type", "Text"),
						Engine.prop_s(Engine.Prop.value, state.signal().map(|s| s.text)),
						Engine.on("input", state.set_value(|s, value| { ..s, text: value })),
					],
					[],
				),
				Html.p_s(state.signal().map(|s| s.text), [Engine.test_id("mixed-text")]),
				Engine.element(
					"input",
					[
						Html.aria_label("Mixed file"),
						Engine.attr("type", "FILE"),
						Engine.on_files(Change, state.set_value(|s, selected| { ..s, files: Str.join_with(selected.files.map(|file| file.name()), "|") })),
					],
					[],
				),
				Html.p_s(state.signal().map(|s| s.files), [Engine.test_id("mixed-files")]),
			],
		),
	)
}
