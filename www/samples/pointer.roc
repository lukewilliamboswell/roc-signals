app [main] { pf: platform "../../platform/main.roc" }

import pf.Engine
import pf.Html

## A drag remembers the pointer that began it, so a second pointer cannot
## move or end that gesture accidentally.
Gesture := [Idle, Dragging(U32)].{
	is_eq : _
}

Model : { gesture : Gesture, place : Str }

# region handlers
## Capture is declared on the press; moves are reports and cancellation is
## an ordinary typed handler that ends the same pointer's gesture.
view : {} -> Engine.Elem(Engine.Root)
view = |{}| Engine.state(
	{ gesture: Idle, place: "Outside" },
	|state| Html.div_attrs(
		[Engine.attr("style", "display:flex;gap:24px;align-items:start")],
		[
			Engine.element(
				"div",
				[
					Html.zone("grip"),
					Html.aria_label("Drag handle"),
					Engine.attr("style", "width:120px;height:120px;border:1px solid;touch-action:none;user-select:none"),
					Html.on_pointer_down_capture(state.set_value(pressed)),
					Html.on_pointer_move_paced(state.set_value(moved)),
					Html.on_pointer_up(state.set_value(finished)),
					Html.on_pointer_cancel(state.set_value(cancelled)),
				],
				[Engine.text("Drag from here")],
			),
			Engine.element("div", [Html.zone("target"), Html.aria_label("Drop zone"), Engine.attr("style", "width:160px;height:160px;border:1px solid")], [Engine.text("Move over this zone")]),
			Html.p_s(state.signal().map(|model| model.place), [Engine.test_id("pointer-place")]),
		],
	),
)

# endregion handlers

pressed : Model, Engine.Pointer -> Model
pressed = |model, pointer| match (model.gesture, pointer.button) {
	(Idle, Main) => { gesture: Dragging(pointer.id), place: place(pointer) }
	_ => model
}

moved : Model, Engine.Pointer -> Model
moved = |model, pointer| match model.gesture {
	Dragging(id) if id == pointer.id => { ..model, place: place(pointer) }
	_ => model
}

finished : Model, Engine.Pointer -> Model
finished = |model, pointer| match model.gesture {
	Dragging(id) if id == pointer.id => { gesture: Idle, place: place(pointer) }
	_ => model
}

cancelled : Model, Engine.Pointer -> Model
cancelled = |model, pointer| match model.gesture {
	Dragging(id) if id == pointer.id => { gesture: Idle, place: "Cancelled" }
	_ => model
}

# region zones
## Zone keys stay application data. The platform reports them exactly; x and
## y are 0..10000 fractions of that zone, independently of capture routing.
place : Engine.Pointer -> Str
place = |pointer| match pointer.at {
	Outside => "Outside"
	In({ zone, x, y }) => "${zone}: ${x.to_str()}, ${y.to_str()}"
}

# endregion zones

main : Engine.Program
main = Engine.program(|| view({}))

## Only the pointer that began a gesture may move or finish it; cancellation
## clears that gesture without needing any browser or engine state.
expect {
	point : Engine.Pointer
	point = { id: 7, kind: Mouse, button: Main, buttons: 1, modifiers: { shift: Bool.False, ctrl: Bool.False, alt: Bool.False, meta: Bool.False }, primary: Bool.True, at: In({ zone: "grip", x: 5000, y: 5000 }) }
	initial : Model
	initial = { gesture: Idle, place: "Outside" }
	started = pressed(initial, point)
	travel = { ..point, at: In({ zone: "target", x: 7500, y: 2500 }) }
	{
		moved: moved(started, travel),
		other: moved(started, { ..travel, id: 8 }),
		second_press: pressed(started, { ..point, id: 8 }),
		finished: finished(started, travel),
		cancelled: cancelled(started, point),
	} == {
		moved: { gesture: Dragging(7), place: "target: 7500, 2500" },
		other: { gesture: Dragging(7), place: "grip: 5000, 5000" },
		second_press: { gesture: Dragging(7), place: "grip: 5000, 5000" },
		finished: { gesture: Idle, place: "target: 7500, 2500" },
		cancelled: { gesture: Idle, place: "Cancelled" },
	}
}

## The instance holds this store beside its site tree.
Store : {}

## Check that the default first page mounts while this app compiles.
mounted : U64
mounted = Engine.mounts(main)
