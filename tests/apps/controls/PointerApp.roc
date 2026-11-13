import pf.Engine exposing [Elem]
import pf.Html

## Pointer input fixtures use the public typed surface. The native specs and
## Chrome contracts observe the same zones, capture and row lifetimes.
PointerApp := [].{
	S : { log : List(Str), zone : Str, rows : List(Str), shown : Bool, mode : [Keep, Remove, Clear, Move, RemoveParent] }

	## Payload summaries omit browser-assigned pointer ids; equality of ids is
	## an application's rule, while their numeric spelling is not portable.
	summary : Str, Engine.Pointer -> Str
	summary = |event, pointer| {
		kind = match pointer.kind {
			Mouse => "mouse"
			Pen => "pen"
			Touch => "touch"
			Other => "other"
		}
		at = match pointer.at {
			Outside => "outside"
			In({ zone, x, y }) => "${zone}:${x.to_str()}:${y.to_str()}"
		}
		"${event}:${kind}:${pointer.buttons.to_str()}:${at}"
	}

	## A release can move or remove its pressed row or the row's ancestor.
	## The platform, rather than the application, decides the following click.
	released : S, Engine.Pointer -> S
	released = |s, pointer| {
		next = { ..s, log: s.log.append(PointerApp.summary("row-up", pointer)) }
		match s.mode {
			Keep => next
			Remove => { ..next, rows: s.rows.drop_first(1) }
			Clear => { ..next, rows: [] }
			Move => { ..next, rows: s.rows.drop_first(1).concat(s.rows.take_first(1)) }
			RemoveParent => { ..next, shown: False }
		}
	}

	view : {} -> Elem(ctx)
	view = |_props| Engine.state(
		{ log: [], zone: "capture", rows: ["a", "b", "c"], shown: True, mode: Keep },
		|state| Engine.element(
			"section",
			[],
			[
				Engine.element(
					"div",
					[
						Engine.test_id("pointer-capture"),
						Engine.prop_s(Engine.Prop.pointer_zone, state.signal().map(|s| s.zone)),
						Engine.attr("style", "width:240px;height:120px;touch-action:none;user-select:none;margin:10px"),
						Engine.on_pointer_capture(state.set_value(|s, p| { ..s, log: s.log.append(PointerApp.summary("down", p)) })),
						Engine.on_pointer_paced(state.set_value(|s, p| { ..s, log: s.log.append(PointerApp.summary("move", p)) })),
						Engine.on_pointer(Up, state.set_value(|s, p| { ..s, log: s.log.append(PointerApp.summary("up", p)) })),
						Engine.on_pointer(Cancel, state.set_value(|s, p| { ..s, log: s.log.append(PointerApp.summary("cancel", p)) })),
					],
					[
						Engine.element("span", [Engine.test_id("pointer-inside"), Engine.attr("style", "display:block;width:100px;height:30px")], [Engine.text("Inside capture")]),
						Engine.element("span", [Engine.test_id("pointer-empty-zone"), Engine.prop(Engine.Prop.pointer_zone, ""), Engine.attr("style", "display:block;width:100px;height:30px")], [Engine.text("Empty zone")]),
					],
				),
				Engine.element(
					"div",
					[
						Engine.test_id("pointer-plain"),
						Engine.prop(Engine.Prop.pointer_zone, "plain"),
						Engine.attr("style", "width:240px;height:120px;touch-action:none;user-select:none;margin:10px"),
						Engine.on_pointer(Down, state.set_value(|s, p| { ..s, log: s.log.append(PointerApp.summary("down", p)) })),
						Engine.on_pointer(Move, state.set_value(|s, p| { ..s, log: s.log.append(PointerApp.summary("move", p)) })),
						Engine.on_pointer(Up, state.set_value(|s, p| { ..s, log: s.log.append(PointerApp.summary("up", p)) })),
						Engine.on_pointer(Cancel, state.set_value(|s, p| { ..s, log: s.log.append(PointerApp.summary("cancel", p)) })),
					],
					[Engine.text("Plain pointer")],
				),
				Engine.element("div", [Engine.test_id("pointer-outside"), Engine.attr("style", "width:240px;height:80px;margin:10px")], [Engine.text("Outside")]),
				Html.button("Disable pointer zone", [], state.update(|s| { ..s, zone: "" })),
				Html.button("Enable pointer zone", [], state.update(|s| { ..s, zone: "capture" })),
				Html.button("Clear pointer log", [], state.update(|s| { ..s, log: [] })),
				Html.button("On up remove", [], state.update(|s| { ..s, mode: Remove })),
				Html.button("On up clear", [], state.update(|s| { ..s, mode: Clear })),
				Html.button("On up move", [], state.update(|s| { ..s, mode: Move })),
				Html.button("On up remove parent", [], state.update(|s| { ..s, mode: RemoveParent })),
				Html.button("Reset pointer rows", [], state.update(|s| { ..s, rows: ["a", "b", "c"], shown: True, mode: Keep, log: [] })),
				Engine.element(
					"div",
					[
						Engine.test_id("pointer-mutations"),
						Engine.on("mouseup", state.update(|s| { ..s, log: s.log.append("parent-mouseup") })),
						Engine.on_click(state.update(|s| { ..s, log: s.log.append("parent-click") })),
					],
					[
						Engine.when(
							state.signal().map(|s| s.shown),
							|| Engine.element(
								"div",
								[Engine.test_id("pointer-rows")],
								[
									Engine.each(
										state.signal().map(|s| s.rows),
										|key| key,
										|row| Engine.element(
											"div",
											[Engine.test_id_s(row.key().map(|key| "pointer-row-${key}"))],
											[
												Engine.element(
													"span",
													[
														Engine.test_id_s(row.key().map(|key| "pointer-grip-${key}")),
														Engine.prop_s(Engine.Prop.pointer_zone, row.key().map(|key| "grip:${key}")),
														Engine.attr("style", "display:block;width:240px;height:60px;touch-action:none;user-select:none"),
														Engine.on_pointer_capture(state.lift_row().set_value(|s, p| { ..s, log: s.log.append(PointerApp.summary("row-down", p)) })),
														Engine.on_pointer(Up, state.lift_row().set_value(PointerApp.released)),
													],
													[Engine.text_s(row.key())],
												),
											],
										),
									),
								],
							),
							|| Engine.text(""),
						),
					],
				),
				Html.p_s(state.signal().map(|s| Str.join_with(s.log, "|")), [Engine.test_id("pointer-log")]),
			],
		),
	)
}
