app [main] { pf: platform "https://github.com/lukewilliamboswell/roc-signals/releases/download/0.1/3eLQGNMDG9RuL9sn1A7ep1Rtq7QGmemE89y141WSv1XG.tar.zst" }

import pf.Elem exposing [Elem]
import pf.Html
import pf.Signal
import pf.Ui

show : U64 -> Str
show = |n| n.to_str()

prefix_left : Str -> Str
prefix_left = |value| "Left: ${value}"

joined_text : List(Str) -> Str
joined_text = |parts| "Joined: ${Str.join_with(parts, "+")}"

main : () -> Elem
main = || {
	Ui.state(
		1,
		|left| {
			Ui.state(
				10,
				|right| {
					# top-level transforms only, no inline lambdas
					left_text : Signal.Signal(Str)
					left_text = left.signal().map(show)
					right_text : Signal.Signal(Str)
					right_text = right.signal().map(show)
					combined : Signal.Signal(Str)
					combined = Signal.combine([left_text, right_text]).map(joined_text)

					Html.section(
						"Combine",
						[],
						[
							Html.heading("Combine"),
							# A: direct map over a Ui.state signal
							Html.paragraph_s_attrs(left_text.map(prefix_left), [Html.test_id("left")]),
							# B: the combine result
							Html.paragraph_s_attrs(combined, [Html.test_id("joined")]),
							Html.button("Bump left", left.on_unit(|n| n + 1)),
						],
					)
				},
			)
		},
	)
}
