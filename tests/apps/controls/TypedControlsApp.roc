import pf.Engine
import pf.Html

## A typed select resolves the current value by its key, even after a choice
## changes without changing identity. Foreign and removed keys are app input.
TypedControlsApp := [].{
	Choice : { key : Str, title : Str, revision : U64 }

	choices : U64 -> List(Choice)
	choices = |revision| [{ key: "amber", title: "Amber", revision }, { key: "teal", title: "Teal", revision }, { key: "plum", title: "Plum", revision }]

	view : {} -> Engine.Elem(ctx)
	view = |_| Engine.state(
		{ offered: TypedControlsApp.choices(0), selected: { key: "amber", title: "Amber", revision: 0.U64 }, status: "initial", ticked: False, checks: 0.U64, revision: 0.U64 },
		|state| {
			value = state.signal()
			Engine.element(
				"section",
				[],
				[
					Html.checkbox(Engine.const("Typed checkbox"), value.map(|s| s.ticked), [], state.set_value(|s, ticked| { ..s, ticked, checks: s.checks + 1 })),
					Html.p_s(value.map(|s| "${if (s.ticked) "checked" else "unchecked"}:${s.checks.to_str()}"), [Engine.test_id("typed-checked")]),
					Html.select(
						Engine.const("Typed choice"),
						value.map(|s| s.selected),
						value.map(|s| s.offered),
						{ key: |choice| choice.key, label: |choice| choice.title },
						[],
						state.set_value(
							|s, picked| match picked {
								Chose(selected) => { ..s, selected, status: "chose:${selected.key}:${selected.revision.to_str()}" }
								NotOffered => { ..s, status: "not-offered" }
							},
						),
					),
					Html.p_s(value.map(|s| s.status), [Engine.test_id("typed-choice-status")]),
					Html.p_s(value.map(|s| "${s.selected.key}:${s.selected.revision.to_str()}"), [Engine.test_id("typed-selected")]),
					Html.button("Remove teal choice", [], state.update(|s| { ..s, offered: s.offered.keep_if(|choice| choice.key != "teal") })),
					Html.button("Refresh choices", [], state.update(|s| { ..s, offered: TypedControlsApp.choices(s.revision + 1), revision: s.revision + 1 })),
					Html.button("Reverse choices", [], state.update(|s| { ..s, offered: s.offered.fold([], |reversed, choice| [choice].concat(reversed)) })),
					Engine.element("input", [Engine.attr("type", "text"), Engine.attr("aria-label", "Wrong checked target"), Engine.on_checked(state.set_value(|s, _| { ..s, status: "wrong-target-fired" }))], []),
					Engine.element("input", [Engine.attr("type", "RaDiO"), Engine.attr("aria-label", "Typed radio"), Engine.on_checked(state.set_value(|s, ticked| { ..s, ticked, checks: s.checks + 1 }))], []),
					Engine.element(
						"svg",
						[],
						[
							Engine.element("input", [Engine.attr("type", "RaDiO"), Engine.attr("aria-label", "SVG checked target"), Engine.on_checked(state.set_value(|s, _| { ..s, status: "svg-fired" }))], []),
							Engine.each(Engine.const(["one"]), |key| key, |_| Engine.element("input", [Engine.attr("type", "RaDiO"), Engine.attr("aria-label", "SVG row checked target"), Engine.on_checked(state.lift_row().set_value(|s, _| { ..s, status: "svg-row-fired" }))], [])),
							Engine.element(
								"foreignObject",
								[],
								[
									Engine.element("INPUT", [Engine.attr("type", "RaDiO"), Engine.attr("aria-label", "Foreign object checked target"), Engine.on_checked(state.set_value(|s, _| { ..s, status: "foreign-object-fired" }))], []),
									Engine.element("svg", [], [Engine.element("input", [Engine.attr("type", "RaDiO"), Engine.attr("aria-label", "Nested SVG checked target"), Engine.on_checked(state.set_value(|s, _| { ..s, status: "nested-svg-fired" }))], [])]),
								],
							),
						],
					),
				],
			)
		},
	)
}
