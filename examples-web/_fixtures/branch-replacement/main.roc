app [main] { roc: "nightly-2026-09-09-7dadc35", pf: platform "../../../platform-web/main.roc" }

import pf.Elem exposing [Elem]
import pf.Html
import pf.Signal
import pf.Ui

## Size fixture: one `Ui.switch` whose live case replaces a whole subtree.
## Each branch is a different shape so the host exercises branch disposal and
## replacement rather than text updates inside a stable structure.
Mode : [Summary, Details, Empty]

next_mode : Mode -> Mode
next_mode = |mode|
	match mode {
		Summary => Details
		Details => Empty
		Empty => Summary
	}

mode_name : Mode -> Str
mode_name = |mode|
	match mode {
		Summary => "summary"
		Details => "details"
		Empty => "empty"
	}

label_count : I64 -> Str
label_count = |value| "Count: ${value.to_str()}"

branch : Mode, Signal.Signal(Str) -> Elem
branch = |mode, label|
	match mode {
		Summary =>
			Html.paragraph_s_attrs(label, [Html.test_id("summary")])
		Details =>
			Html.div_c(
				"grid gap-2",
				[
					Html.heading("Details"),
					Html.paragraph_s_attrs(label, [Html.test_id("details-count")]),
					Html.paragraph("A second static paragraph only this branch owns."),
				],
			)
		Empty =>
			Html.paragraph_s_attrs(Signal.const("Nothing selected"), [Html.test_id("empty")])
	}

main : () -> Elem
main = || {
	Ui.state(
		Summary,
		|mode| {
			Ui.state(
				0,
				|count| {
					label = count.signal().map(label_count)
					current = mode.signal().map(mode_name)

					Html.div_c(
						"grid gap-6",
						[
							Html.heading("Branch replacement"),
							Html.paragraph_s_attrs(current, [Html.test_id("mode")]),
							Html.button("Next mode", mode.on_unit(next_mode)),
							Html.button("Increment", count.on_unit(|value| value + 1)),
							Ui.switch(mode.signal(), |selected| branch(selected, label)),
						],
					)
				},
			)
		},
	)
}
