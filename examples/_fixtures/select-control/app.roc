app [main] { pf: platform "https://github.com/lukewilliamboswell/roc-signals/releases/download/0.1/3eLQGNMDG9RuL9sn1A7ep1Rtq7QGmemE89y141WSv1XG.tar.zst" }

import pf.Elem exposing [Elem]
import pf.Html
import pf.Signal
import pf.Ui

State : {
	plan : Str,
	focus_count : I64,
	blur_count : I64,
	change_count : I64,
}

initial_state : State
initial_state = {
	plan: "starter",
	focus_count: 0,
	blur_count: 0,
	change_count: 0,
}

set_plan : State, Str -> State
set_plan = |state, value| { ..state, plan: value, change_count: state.change_count + 1 }

record_focus : State -> State
record_focus = |state| { ..state, focus_count: state.focus_count + 1 }

record_blur : State -> State
record_blur = |state| { ..state, blur_count: state.blur_count + 1 }

label_i64 : Str, I64 -> Str
label_i64 = |name, value| "${name}: ${value.to_str()}"

selected_label : Str -> Str
selected_label = |plan| "Selected plan: ${plan}"

main : {} -> Elem
main = |_| {
	Ui.state(
		initial_state,
		|model| {
			state_signal = model.signal()
			plan_signal = state_signal.map(|state| state.plan)
			selected_text = plan_signal.map(selected_label)
			focus_text = state_signal.map(|state| label_i64("Focus events", state.focus_count))
			blur_text = state_signal.map(|state| label_i64("Blur events", state.blur_count))
			change_text = state_signal.map(|state| label_i64("Change events", state.change_count))

			Html.section(
				"Select Control",
				[Html.attr("data-fixture", "select-control")],
				[
					Html.heading("Select Control"),
					Html.select_attrs(
						"Plan",
						plan_signal,
						[
							Html.attr("id", "plan-select"),
							Html.on_focus(model.on_unit(record_focus)),
							Html.on_blur(model.on_unit(record_blur)),
						],
						[
							Html.option("starter", "Starter"),
							Html.option("growth", "Growth"),
							Html.option("enterprise", "Enterprise"),
						],
						model.on_str(set_plan),
					),
					Html.paragraph_s(selected_text),
					Html.paragraph_s(focus_text),
					Html.paragraph_s(blur_text),
					Html.paragraph_s(change_text),
				],
			)
		},
	)
}
