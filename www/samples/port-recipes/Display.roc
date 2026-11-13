import pf.Engine
import pf.Html
import pf.Port
import CommandView

Display := [].{
	# region declaration
	## Browser state, not command acknowledgement. Both commands run in their
	## buttons' turns; a failed command reaches onPortFault, not the app.
	fullscreen : Port.Command({})
	fullscreen = Port.command({ name: "example.org/recipes/fullscreen" })

	fullscreen_state : Port.Subscription({}, Bool)
	fullscreen_state = Port.subscription({ name: "example.org/recipes/fullscreen-state", delivery: Latest })

	wake : Port.Command(Bool)
	wake = Port.command({ name: "example.org/recipes/wake" })

	wake_state : Port.Subscription({}, Bool)
	wake_state = Port.subscription({ name: "example.org/recipes/wake-state", delivery: Latest })
	# endregion declaration

	view : {} -> Engine.Elem(ctx)
	view = |_| Engine.state(
		{ fullscreen: False, awake: False, wake: Engine.outbox({}) },
		|state| Html.div(
			"recipe",
			[
				CommandView.view({ label: "Enter fullscreen", port: Display.fullscreen, argument: Engine.const({}) }),
				Html.button("Toggle wake lock", [], state.update(|s| { ..s, wake: s.wake.post(!s.awake) })),
				Engine.on_post(state.signal().map(|s| s.wake), |wanted| [Engine.command(Display.wake.send(wanted))], Engine.ignore({})),
				Engine.watch(
					Engine.const({}),
					|_| [Display.fullscreen_state.ask({})],
					state.on_result(
						|s, _, result| match result {
							Ok(active) => { ..s, fullscreen: active }
							Err(_) => s
						},
					),
				),
				Engine.watch(
					Engine.const({}),
					|_| [Display.wake_state.ask({})],
					state.on_result(
						|s, _, result| match result {
							Ok(active) => { ..s, awake: active }
							Err(_) => s
						},
					),
				),
				Html.p_s(state.signal().map(|s| if (s.fullscreen) "Fullscreen" else "Windowed"), [Engine.test_id("fullscreen-result")]),
				Html.p_s(state.signal().map(|s| if (s.awake) "Wake lock held" else "Wake lock released"), [Engine.test_id("wake-result")]),
			],
		),
	)
}
