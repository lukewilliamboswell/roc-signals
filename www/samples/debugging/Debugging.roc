import pf.Engine exposing [Elem, Root]
import pf.Html

## Name the observation because the compiler supplies no source location.
Debugging := [].{
	# region add-one
	## A dbg observes this evaluation; it never changes the answer.
	add_one : I64 -> I64
	add_one = |count| {
		dbg { at: "add_one", count }
		count + 1
	}
	# endregion add-one

	## Ordinary local state and a handler; no logging API or effect is needed.
	view : {} -> Elem(Root)
	view = |_unit| Engine.state(
		0.I64,
		|count| Html.div(
			"counter",
			[
				Html.p_s(count.signal().map(I64.to_str), [Engine.test_id("count")]),
				Html.button("Add one", [], count.update(Debugging.add_one)),
			],
		),
	)
}
