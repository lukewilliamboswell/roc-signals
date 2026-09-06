app [main] { pf: platform "../../../platform/main.roc" }

import pf.Elem exposing [Elem]
import pf.Html
import pf.Signal
import pf.Svg
import pf.Ui

main : () -> Elem
main = || Ui.state(
	False,
	|changed|
		Html.div(
			[],
			[
				Html.button("Change graph", changed.on_unit(|value| !value)),
				Ui.when(changed.signal(), || Svg.element("a", [Html.test_id("namespace-switch")], [Html.text("Link")]), || Elem.Element({ namespace: Html, tag: "a", attrs: [Html.test_id("namespace-switch")], children: [Html.text("Link")] })),
				Svg.svg(
					[Html.attr("viewBox", "0 0 200 100"), Html.test_id("graph"), Html.class_attr("diagram")],
					[
						Svg.rect([Html.attr("width", "80"), Html.attr("height", "30")]),
						Svg.text_s(
							[Html.test_id("graph-label"), Html.attr("x", "5"), Html.attr("y", "20")],
							changed.signal().map(
								|value| if value {
									"Updated"
								} else {
									"Initial"
								},
							),
						),
						Ui.when(changed.signal(), || Svg.element("foreignObject", [Html.test_id("foreign")], [Html.div([Html.test_id("html-child")], [Html.text("HTML child")])]), || Svg.element("linearGradient", [Html.test_id("gradient")], [])),
					],
				),
			],
		),
)
