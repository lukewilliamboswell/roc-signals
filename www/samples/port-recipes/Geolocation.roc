import pf.Engine
import pf.Html
import pf.Port
import CallView

Geolocation := [].{
	# region declaration
	Position : { latitude : F64, longitude : F64, accuracy : F64 }

	## The module's named ports, declared once and registered together.
	Ports : {
		## One location, cancelled through the handler's AbortSignal on timeout.
		locate : Port.Call({}, Position),

		## Current position is a value: only the newest waiting fix matters.
		positions : Port.Subscription({}, Position),
	}

	## The same values serve requests and the derived program catalogue.
	ports : Ports
	ports = {
		locate: Port.call({ name: "example.org/recipes/location", timeout: Ms(15000) }),
		positions: Port.subscription({ name: "example.org/recipes/positions", delivery: Latest }),
	}
	# endregion declaration

	view : {} -> Engine.Elem(ctx)
	view = |_| Html.div(
		"recipe",
		[
			CallView.view({ label: "Find location", test_id: "location-result", port: Geolocation.ports.locate, argument: Engine.const({}), show: show }),
			Engine.state(
				{ following: False, text: "Location watch stopped" },
				|state| Html.div(
					"location-watch",
					[
						Html.button("Toggle location watch", [], state.update(|s| { ..s, following: !s.following })),
						Engine.when(
							state.signal().map(|s| s.following),
							|| Engine.watch(
								Engine.const({}),
								|_| [Geolocation.ports.positions.ask({})],
								state.on_result(
									|s, _, result| match result {
										Ok(position) => { ..s, text: show(position) }
										Err(Threw(message)) => { ..s, following: False, text: "Location stopped: ${message}" }
										Err(Closed) => { ..s, following: False, text: "Location watch ended" }
										Err(error) => { ..s, text: "Location unavailable: ${Str.inspect(error)}" }
									},
								),
							),
							|| Engine.text(""),
						),
						Html.p_s(state.signal().map(|s| s.text), [Engine.test_id("position-result")]),
					],
				),
			),
		],
	)
}

show : Geolocation.Position -> Str
show = |position| "${position.latitude.to_str()}, ${position.longitude.to_str()} (±${position.accuracy.to_str()} m)"
