app [main] { pf: platform "../../../platform/main.roc" }

import pf.Elem exposing [Elem]
import pf.Html
import pf.Signal
import pf.Ui

value_text : I64 -> Str
value_text = |value| value.to_str()

main : () -> Elem
main = || {
	Ui.state(
		1,
		|left| {
			Ui.state(
				10,
				|right| {
					left_value = left.signal().map(value_text)
					right_value = right.signal().map(value_text)
					shared_value = left.signal().map(value_text)
					first_constant = Signal.const("constant-a")
					second_constant = Signal.const("constant-b")

					Html.div(
						[],
						[
							Html.heading("Callable Signal Identity"),
							Html.section("Left map", [Html.test_id("left-map"), Html.attr_s("data-value", left_value)], []),
							Html.section("Right map", [Html.test_id("right-map"), Html.attr_s("data-value", right_value)], []),
							Html.section("Clone A", [Html.test_id("clone-a"), Html.attr_s("data-value", shared_value)], []),
							Html.section("Clone B", [Html.test_id("clone-b"), Html.attr_s("data-value", shared_value)], []),
							Html.section("Constant A", [Html.test_id("constant-a"), Html.attr_s("data-value", first_constant)], []),
							Html.section("Constant B", [Html.test_id("constant-b"), Html.attr_s("data-value", second_constant)], []),
							Html.button("Increment left", left.on_unit(|value| value + 1)),
							Html.button("Increment right", right.on_unit(|value| value + 1)),
						],
					)
				},
			)
		},
	)
}
