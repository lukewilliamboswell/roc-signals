# region imports
import pf.Engine exposing [Elem, In, Root, State]
import pf.Html
# endregion imports

## A counter: one piece of state and two buttons that change it.
Counter := [].{
	# region view
	## Inside the counter's state: one local state holding an `I64`.
	Ctx : In(Root, I64)

	## The program both platforms run.
	program : Engine.Program
	program = Engine.program(|| Engine.state(0, Counter.view))

	view : State(Ctx, I64) -> Elem(Ctx)
	view = |count|
		Html.div(
			"counter",
			[
				Html.button("-", [Html.aria_label("Decrement")], count.update(|n| n - 1)),
				Html.span_s(count.signal().map(|n| n.to_str()), [Engine.test_id("count")]),
				Html.button("+", [Html.aria_label("Increment")], count.update(|n| n + 1)),
			],
		)
	# endregion view
}
