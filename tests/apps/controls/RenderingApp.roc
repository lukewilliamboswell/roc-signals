import pf.Engine exposing [Elem, Signal]
import pf.Html

## Static nodes, row templates and a freshly mounted animated template use
## the same SVG names. Boolean text remains observable in each render path.
RenderingApp := [].{
	scene : Signal(ctx, List(Str)), Signal(ctx, Str), Str -> Elem(ctx)
	scene = |rows, length, prefix| Engine.element(
		"svg",
		[Engine.test_id(prefix), Engine.attr("viewBox", "0 0 20 20")],
		[
			Engine.element("linearGradient", [Engine.test_id("${prefix}-static-gradient"), Engine.attr("gradientUnits", "userSpaceOnUse")], []),
			Engine.element("path", [Engine.test_id("${prefix}-static-path"), Engine.attr("pathLength", "10"), Engine.attr("d", "M0 0L10 10")], []),
			Engine.each(
				rows,
				|key| key,
				|row| Engine.element(
					"g",
					[Engine.test_id_s(row.key().map(|key| "${prefix}-row-${key}"))],
					[
						Engine.element("linearGradient", [Engine.attr("gradientUnits", "userSpaceOnUse")], []),
						Engine.element("path", [Engine.test_id_s(row.key().map(|key| "${prefix}-fixed-${key}")), Engine.attr("pathLength", "10"), Engine.attr("d", "M0 0L10 10")], []),
						Engine.element("path", [Engine.test_id_s(row.key().map(|key| "${prefix}-length-${key}")), Engine.attr_s("pathLength", length.lift_row()), Engine.attr("d", "M0 0L10 10")], []),
						Engine.element(
							"foreignObject",
							[Engine.attr("width", "10"), Engine.attr("height", "10")],
							[
								Engine.element("div", [Engine.class("html-child")], [Engine.text_s(row.key())]),
							],
						),
					],
				),
			),
		],
	)

	view : {} -> Elem(ctx)
	view = |_| Engine.state(
		{ rows: ["a", "b"], length: "10", animated: False, hidden: UntilFound },
		|state| Engine.element(
			"section",
			[],
			[
				Html.button("Reverse SVG rows", [], state.update(|s| { ..s, rows: s.rows.fold([], |reversed, key| [key].concat(reversed)) })),
				Html.button("Remove SVG row", [], state.update(|s| { ..s, rows: s.rows.keep_if(|key| key != "a") })),
				Html.button("Restore SVG rows", [], state.update(|s| { ..s, rows: ["a", "b"] })),
				Html.button("Change SVG length", [], state.update(|s| { ..s, length: "20" })),
				Html.button("Animate SVG mount", [], state.update(|s| { ..s, animated: True })),
				Engine.watch_changes(state.signal().map(|s| s.animated), |_| [Engine.command(ViewTransition(["rendering"]))], Engine.ignore({})),
				RenderingApp.scene(state.signal().map(|s| s.rows), state.signal().map(|s| s.length), "plain-svg"),
				Engine.when(
					state.signal().map(|s| s.animated),
					|| RenderingApp.scene(state.signal().map(|s| s.rows), state.signal().map(|s| s.length), "animated-svg"),
					|| Engine.text(""),
				),
				Html.button("Show findable", [], state.update(|s| { ..s, hidden: Shown })),
				Html.button("Hide findable", [], state.update(|s| { ..s, hidden: Hidden })),
				Html.button("Findable until found", [], state.update(|s| { ..s, hidden: UntilFound })),
				Engine.element(
					"details",
					[Engine.test_id("findable"), Engine.attr("open", "true"), Html.hidden_s(state.signal().map(|s| s.hidden))],
					[
						Engine.element("summary", [], [Engine.text("Findable details")]),
						Engine.element("p", [], [Engine.text("until-found needle225")]),
					],
				),
				Engine.element("div", [Engine.test_id("boolean-static"), Engine.attr("readonly", "named"), Engine.attr("required", "named"), Engine.attr("multiple", "named"), Engine.attr("selected", "named"), Engine.attr("open", "named")], []),
				Engine.each(Engine.const(["only"]), |key| key, |_row| Engine.element("div", [Engine.test_id("boolean-row"), Engine.attr("readonly", "named"), Engine.attr("required", "named"), Engine.attr("multiple", "named"), Engine.attr("selected", "named"), Engine.attr("open", "named")], [])),
			],
		),
	)
}
