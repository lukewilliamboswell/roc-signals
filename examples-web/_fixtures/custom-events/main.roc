app [main] { roc: "nightly-2026-09-04-c125b82", pf: platform "../../../platform-web/main.roc" }

import pf.Elem exposing [Elem]
import pf.Html
import pf.Signal
import pf.Ui

## Custom DOM event coverage: Html.on_custom binds a named event whose
## `event.detail` string reaches a reducer built with State.update_detail.
detail_text : Str -> Str
detail_text = |value|
	if value.is_empty() {
		"Hover: none"
	} else {
		"Hover: ${value}"
	}

selected_text : Str -> Str
selected_text = |value|
	if value.is_empty() {
		"Selected: none"
	} else {
		"Selected: ${value}"
	}

take : Str, Str -> Str
take = |_current, value| value

main : () -> Elem
main = || {
	Ui.state(
		"",
		|hovered| {
			Ui.state(
				"",
				|selected| {
					Html.section(
						"Custom Events",
						[Html.attr("data-fixture", "custom-events")],
						[
							Html.heading("Custom Events"),
							Html.div(
								[
									Html.test_id("chart"),
									Html.on_custom("chart-hover", hovered.update_detail(take)),
									Html.on_custom("chart-select", selected.update_detail(take)),
								],
								[Html.text("chart")],
							),
							Html.paragraph_s_attrs(Signal.map(hovered.signal(), detail_text), [Html.test_id("hover")]),
							Html.paragraph_s_attrs(Signal.map(selected.signal(), selected_text), [Html.test_id("selected")]),
						],
					)
				},
			)
		},
	)
}
