app [main] { pf: platform "https://github.com/lukewilliamboswell/roc-signals/releases/download/0.1/3eLQGNMDG9RuL9sn1A7ep1Rtq7QGmemE89y141WSv1XG.tar.zst" }

import pf.Elem exposing [Elem]
import pf.Html
import pf.Signal
import pf.Ui

## A five-deep derived chain off one source, plus one node that always
## recomputes to the same value so the equality cutoff can be observed.
step : U64 -> U64
step = |n| n + 1

show : U64 -> Str
show = |n| "Chain: ${n.to_str()}"

constant : U64 -> Str
constant = |_| "Constant: unchanged"

main : () -> Elem
main = || {
	Ui.state(
		0,
		|count| {
			source : Signal.Signal(U64)
			source = count.signal()
			a : Signal.Signal(U64)
			a = source.map(step)
			b : Signal.Signal(U64)
			b = a.map(step)
			c : Signal.Signal(U64)
			c = b.map(step)
			d : Signal.Signal(U64)
			d = c.map(step)

			Html.section(
				"Metrics",
				[],
				[
					Html.heading("Metrics"),
					Html.paragraph_s_attrs(d.map(show), [Html.test_id("chain")]),
					Html.paragraph_s_attrs(source.map(constant), [Html.test_id("constant")]),
					Html.button("Bump", count.on_unit(|n| n + 1)),
				],
			)
		},
	)
}
