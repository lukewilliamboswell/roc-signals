import pf.Engine
import pf.Html
import pf.Port

## A command deliberately has no answer. The browser's state subscription,
## when there is one, says what actually happened; failures go to onPortFault.
CommandView := [].{
	view : { label : Str, port : Port.Command(input), argument : Engine.Signal(ctx, input) } -> Engine.Elem(ctx)
	view = |props| Engine.state(
		Engine.outbox({}),
		|state| Html.div(
			"recipe-command",
			[
				Html.button(props.label, [], state.update(|box| box.post({}))),
				Engine.on_post_by(state.signal(), props.argument.lift(), |argument, _| [props.port.send(argument)], Engine.ignore({})),
			],
		),
	)
}
