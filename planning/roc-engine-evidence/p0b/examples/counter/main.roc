app [main] { roc: "nightly-2026-11-01-48d3369", pf: platform "../../main.roc" }

import pf.Elem
import pf.Html
import pf.Ui

label_count : I64 -> Str
label_count = |value| "Count: ${value.to_str()}"

main : () -> Elem(Ui.Root)
main = || {
	Ui.state(
		0,
		|count| {
			label = count.signal().map(label_count)
			Html.div_c(
				"grid gap-6",
				[
					Html.heading("Signals counter"),
					Html.button("Decrement", count.update(|value| value - 1)),
					Html.text_s(label),
					Html.button("Increment", count.update(|value| value + 1)),
				],
			)
		},
	)
}

## The root description builds; each row template is described once, with holes.
expect {
	actual = Elem.platform_describe(main())
	actual == "<div:1><h1:0>Signals counter</h1><button:1>Decrement</button>{val}<button:1>Increment</button></div>"
}
