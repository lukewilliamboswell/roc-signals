app [main] { pf: platform "../../platform/main.roc" }

import pf.Engine
import pf.Html
import pf.Web

# region example
## The application owns the contents and trust policy of imported HTML.
view : () -> Engine.Elem(Engine.Root)
view = || Engine.state(
	"/guide",
	|destination| Engine.element(
		"main",
		[],
		[
			Html.unsafe_html("section", [Html.aria_label("Imported article")], Engine.const("<h2>Imported article</h2><p>HTML supplied by the application.</p>")),
			Html.text_input("Destination", Text, destination.signal(), [], destination.set_value(|_, text| text)),
			Engine.element(
				"a",
				[
					Html.href_s(
						destination.signal().map(
							|authored| match Web.Link.from_str(authored) {
								Ok(checked) => Present(checked)
								Err(UnsupportedScheme(_)) => Absent
							},
						),
					),
				],
				[Engine.text("Open destination")],
			),
			Html.link("Guide", "/guide", []),
		],
	),
)

# endregion example

main : Engine.Program
main = Engine.program(view)

## This sample has no shared store.
Store : {}
