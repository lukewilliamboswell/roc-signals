import pf.Engine
import pf.Html
import pf.Port

## A call posted in the button's turn, with a small marker and a send-time
## reading. Each instance owns its pending state and decodes its own port.
CallView := [].{
	Props(ctx, input, output) : { label : Str, test_id : Str, port : Port.Call(input, output), argument : Engine.Signal(ctx, input), show : (output -> Str) }

	view : Props(ctx, input, output) -> Engine.Elem(ctx)
	view = |props| Engine.state(
		{ sent: Engine.outbox({}), pending: False, text: "Not requested" },
		|state| Html.div(
			"recipe-call",
			[
				Html.button(props.label, [Html.disabled(state.signal().map(|s| s.pending))], state.update(|s| { ..s, sent: s.sent.post({}), pending: True, text: "Waiting…" })),
				Engine.on_post_by(
					state.signal().map(|s| s.sent),
					props.argument.lift(),
					|argument, _| [props.port.request(argument)],
					state.on_result(
						|s, _, result| {
							text = match props.port.result(result) {
								Ok(value) => (props.show)(value)
								Err(error) => "Unavailable: ${Str.inspect(error)}"
							}
							{ ..s, pending: False, text }
						},
					),
				),
				Html.p_s(state.signal().map(|s| s.text), [Engine.test_id(props.test_id)]),
			],
		),
	)
}
