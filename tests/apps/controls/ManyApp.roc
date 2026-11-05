import pf.Engine exposing [Elem, In, Root, State]
import pf.Html

## Many each sites: every row of the outer each holds a nested each (one
## each site per row), so 5,000 rows mount 5,001 each sites. Shrink removes
## rows (their sites are freed and their ids recycled), Grow adds rows back;
## clicking a nested item logs its row and item keys.
ManyApp := [].{
	S : { n : U64, gen : U64, log : List(Str) }

	keys_of : U64, U64 -> List(Str)
	keys_of = |n, gen| {
		var $l = []
		var $i = 0.U64
		while $i < n {
			$l = $l.append("g${gen.to_str()}r${$i.to_str()}")
			$i = $i + 1
		}
		$l
	}

	view : State(In(Root, S), S) -> Elem(In(Root, S))
	view = |st| Engine.element(
		"div",
		[],
		[
			Html.button("Shrink", [], st.update(|s| { ..s, n: s.n // 4 })),
			Html.button("Grow", [], st.update(|s| { ..s, n: 5000, gen: s.gen + 1 })),
			Engine.element("pre", [Engine.test_id("log")], [Engine.text_v(st.val().map(|s| Str.join_with(s.log, "|")))]),
			Engine.element(
				"ul",
				[],
				[
					Engine.each(
						st.val().map(|s| ManyApp.keys_of(s.n, s.gen)),
						|k| k,
						|row| Engine.element(
							"li",
							[],
							[
								Engine.text_v(row.key()),
								Engine.element(
									"ol",
									[],
									[
										Engine.each(
											row.key().map(|k| ["${k}-a", "${k}-b"]),
											|k| k,
											|item| Engine.element("li", [Engine.attr_v("aria-label", item.key()), Engine.on_click(st.lift_row().lift_row().update_by(item.key(), |s, k| { ..s, log: s.log.append(k) }))], [Engine.text_v(item.key())]),
										),
									],
								),
							],
						),
					),
				],
			),
		],
	)

	main : U64 -> Elem(Root)
	main = |n| Engine.state({ n, gen: 0, log: [] }, |st| ManyApp.view(st))
}
