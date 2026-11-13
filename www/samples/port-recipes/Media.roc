import pf.Engine
import pf.Html
import pf.Port

Media := [].{
	# region declaration
	State : [Starting, Active, Ended]

	## Only device state crosses. The custom element owns its MediaStream and
	## video, and unsubscribe stops its tracks; no browser object reaches Roc.
	camera : Port.Subscription({}, State)
	camera = Port.subscription({ name: "example.org/recipes/camera", delivery: Latest })
	# endregion declaration

	view : {} -> Engine.Elem(ctx)
	view = |_| Engine.state(
		{ enabled: False, text: "Camera stopped" },
		|state| Html.div(
			"recipe",
			[
				Html.button("Toggle camera", [], state.update(|s| { ..s, enabled: !s.enabled })),
				Engine.when(
					state.signal().map(|s| s.enabled),
					|| Engine.watch(
						Engine.const({}),
						|_| [Media.camera.ask({})],
						state.on_result(
							|s, _, result| match result {
								Ok(value) => { ..s, text: Str.inspect(value) }
								Err(Threw(message)) => { ..s, enabled: False, text: "Camera stopped: ${message}" }
								Err(Closed) => { ..s, enabled: False, text: "Camera ended" }
								Err(error) => { ..s, text: "Camera unavailable: ${Str.inspect(error)}" }
							},
						),
					),
					|| Engine.text(""),
				),
				Html.p_s(state.signal().map(|s| s.text), [Engine.test_id("camera-result")]),
			],
		),
	)
}
