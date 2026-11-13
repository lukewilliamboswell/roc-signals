app [main] { pf: platform "../../../platform/main.roc" }

import pf.Engine
import pf.Html

## Empty text is a value; absence is an explicit choice. The empty option
## means all works, while the note's attribute can be absent or present-empty.
main : Engine.Program
main = Engine.program(
	|| Engine.state(
		{ selected: "", shown: False },
		|state| Html.div(
			"stack",
			[
				Html.select(
					Engine.const("Works"),
					state.signal().map(|s| s.selected),
					[],
					[Html.option("", "All works"), Html.option("a", "Work A")],
					state.set_value(|s, value| { ..s, selected: value }),
				),
				Html.p_s(state.signal().map(|s| if (s.selected == "") "All works" else "Work A"), [Engine.test_id("selection")]),
				Engine.element("img", [Engine.attr("alt", ""), Engine.test_id("decoration")], []),
				Html.button("Toggle note", [], state.update(|s| { ..s, shown: !s.shown })),
				# region presence
				Engine.element(
					"div",
					[
						Engine.test_id("note"),
						Engine.attr_presence("data-note", state.signal().map(|s| if (s.shown) Present("") else Absent)),
					],
					[Engine.text("The note's attribute is present only while enabled.")],
				),
				# endregion presence
			],
		),
	),
)

## The instance holds this store beside its site tree.
Store : {}
