import pf.Engine
import pf.Html
import pf.Port
import CommandView

Display := [].{
	# region declaration
	## The module's named ports, declared once and registered together.
	Ports : {
		## Browser state, not command acknowledgement. Both commands run in their
		## buttons' turns; a failed command reaches onPortFault, not the app.
		fullscreen : Port.Command({}),
		fullscreen_state : Port.Subscription({}, Bool),
		wake : Port.Command(Bool),
		wake_state : Port.Subscription({}, Bool),
	}

	## The same values serve requests and the derived program catalogue.
	ports : Ports
	ports = {
		fullscreen: Port.command({ name: "example.org/recipes/fullscreen" }),
		fullscreen_state: Port.subscription({ name: "example.org/recipes/fullscreen-state", delivery: Latest }),
		wake: Port.command({ name: "example.org/recipes/wake" }),
		wake_state: Port.subscription({ name: "example.org/recipes/wake-state", delivery: Latest }),
	}
	# endregion declaration

	view : {} -> Engine.Elem(ctx)
	view = |_| Engine.state(
		{ fullscreen: False, awake: False, wake: Engine.outbox({}) },
		|state| Html.div(
			"recipe",
			[
				CommandView.view({ label: "Enter fullscreen", port: Display.ports.fullscreen, argument: Engine.const({}) }),
				Html.button("Toggle wake lock", [], state.update(|s| { ..s, wake: s.wake.post(!s.awake) })),
				Engine.on_post(state.signal().map(|s| s.wake), |wanted| [Engine.command(Display.ports.wake.send(wanted))], Engine.ignore({})),
				Engine.watch(
					Engine.const({}),
					|_| [Display.ports.fullscreen_state.ask({})],
					state.on_result(
						|s, _, result| match result {
							Ok(active) => { ..s, fullscreen: active }
							Err(_) => s
						},
					),
				),
				Engine.watch(
					Engine.const({}),
					|_| [Display.ports.wake_state.ask({})],
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
