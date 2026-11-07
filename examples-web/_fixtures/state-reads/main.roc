app [main] { roc: "nightly-2026-11-07-ad3a5d2", pf: platform "../../../platform-web/main.roc" }

import pf.Elem
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
							Html.text_input("Source", source.signal(), source.update_str(|_, text| text)),
							Html.button("Copy source", result.update_with(source, |_, value| value)),
							Html.paragraph_s_attrs(result.signal(), [Html.test_id("result")]),
						],
					)
			),
	)
