import pf.Engine
import pf.Html

## Build contracts exercise the ordinary app entry and effect channel.
StartupBuild := [].{

	## Every entry has a different fixed route, with the same declaration order.
	program : Engine.Program
	program = Engine.program_startup(
		{ max_inflight: 0 },
		Engine.entries({}, [{ path: "/", route: 0.U8 }, { path: "/tasks/", route: 1 }]),
		|route| Engine.state(
			{ ready: False, refused: False, count: 0.I64 },
			|state| {
				label = if (route == 0) "home" else "tasks"
				Html.div(
					"startup-build",
					[
						Engine.element("span", [Engine.test_id("retained"), Engine.attr("title", "app.wasm")], [Engine.text("retained ${label}")]),
						Engine.watch(
							Engine.const({}),
							|_| [Engine.again({}).map_ok(|_| True), Engine.http({ url: "/must-not-start" }).map_ok(|_| False)],
							state.on_result(
								|current, _, result| match result {
									Ok(True) => { ..current, ready: True }
									Err(Refused) => { ..current, refused: True }
									_ => current
								},
							),
						),
						Engine.when(state.signal().map(|current| current.ready), || Engine.element("p", [Engine.test_id("phase")], [Engine.text("active ${label}")]), || Engine.element("p", [Engine.test_id("phase")], [Engine.text("cold ${label}")])),
						Html.p_s(state.signal().map(|current| if (current.refused) "refused" else "waiting"), [Engine.test_id("refusal")]),
						Html.span_s("${state.signal().map(|current| current.count)}", [Engine.test_id("count")]),
						Html.button("+", [Html.aria_label("Increment")], state.update(|current| { ..current, count: current.count + 1 })),
					],
				)
			},
		),
	)
}
