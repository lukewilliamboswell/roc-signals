app [main] { pf: platform "../../../platform/main.roc" }

import pf.Elem exposing [Elem]
import pf.Html
import pf.Signal
import pf.Ui

main : () -> Elem
main = ||
	Ui.state(
		"alpha",
		|source|
			Ui.state(
				"waiting",
				|result|
					Html.div_c(
						"",
						[
							Html.heading("State reads"),
							Html.text_input("Source", source.signal(), source.on_str(|_, text| text)),
							Html.button("Copy source", result.on_unit_with(source, |_, value| value)),
							Html.paragraph_s_attrs(result.signal(), [Html.test_id("result")]),
						],
					)
			),
	)
