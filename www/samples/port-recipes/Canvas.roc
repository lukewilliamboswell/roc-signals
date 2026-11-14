import pf.Engine
import pf.Html

Canvas := [].{
	# region element
	## The element owns its canvas and drawing frame. Roc supplies a bounded
	## value through an ordinary attribute, and decides the reduced-motion rule.
	view : { reduced : Bool } -> Engine.Elem(ctx)
	view = |props| Engine.state(
		0.U32,
		|state| Html.div(
			"recipe",
			[
				Html.button("Increase gauge", [], state.update(|n| (n + 1) % 101)),
				Engine.element("recipe-gauge", [Engine.test_id("gauge"), Engine.attr_s("data-value", state.signal().map(|n| n.to_str())), Engine.attr("data-animate", if (props.reduced) "false" else "true")], []),
			],
		),
	)
	# endregion element
}
