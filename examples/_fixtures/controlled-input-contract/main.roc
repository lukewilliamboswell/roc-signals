app [main] { pf: platform "../../../platform/main.roc" }

import pf.Elem exposing [Elem]
import pf.Html
import pf.Signal
import pf.Ui

State : {
	normalized : Str,
	echo : Str,
	focus_count : I64,
	blur_count : I64,
	composition_start_count : I64,
	composition_end_count : I64,
}

initial_state : State
initial_state = {
	normalized: "",
	echo: "",
	focus_count: 0,
	blur_count: 0,
	composition_start_count: 0,
	composition_end_count: 0,
}

canonical : Str -> Str
canonical = |value| "canonical:${value}"

record_normalized : State, Str -> State
record_normalized = |state, value| { ..state, normalized: canonical(value) }

record_echo : State, Str -> State
record_echo = |state, value| { ..state, echo: value }

record_focus : State -> State
record_focus = |state| { ..state, focus_count: state.focus_count + 1 }

record_blur : State -> State
record_blur = |state| { ..state, blur_count: state.blur_count + 1 }

record_composition_start : State -> State
record_composition_start = |state| { ..state, composition_start_count: state.composition_start_count + 1 }

record_composition_end : State -> State
record_composition_end = |state| { ..state, composition_end_count: state.composition_end_count + 1 }

canonical_label : Str -> Str
canonical_label = |value| "Canonical normalized: ${value}"

counter_label : Str, I64 -> Str
counter_label = |name, value| "${name}: ${value.to_str()}"

main : () -> Elem
main = || {
	Ui.state(
		initial_state,
		|model| {
			state_signal = model.signal()
			normalized_signal = state_signal.map(|state| state.normalized)
			echo_signal = state_signal.map(|state| state.echo)
			canonical_text = normalized_signal.map(canonical_label)
			focus_text = state_signal.map(|state| counter_label("Focus events", state.focus_count))
			blur_text = state_signal.map(|state| counter_label("Blur events", state.blur_count))
			composition_start_text = state_signal.map(|state| counter_label("Composition start events", state.composition_start_count))
			composition_end_text = state_signal.map(|state| counter_label("Composition end events", state.composition_end_count))

			Html.section(
				"Controlled Input Contract",
				[Html.attr("data-fixture", "controlled-input-contract")],
				[
					Html.heading("Controlled Input Contract"),
					Html.text_input_attrs(
						"Normalized draft",
						normalized_signal,
						[
							Html.on_focus(model.on_unit(record_focus)),
							Html.on_blur(model.on_unit(record_blur)),
							Html.on_composition_start(model.on_unit(record_composition_start)),
							Html.on_composition_end(model.on_unit(record_composition_end)),
						],
						model.on_str(record_normalized),
					),
					Html.text_input_attrs(
						"Echo draft",
						echo_signal,
						[
							Html.on_focus(model.on_unit(record_focus)),
							Html.on_blur(model.on_unit(record_blur)),
						],
						model.on_str(record_echo),
					),
					Html.paragraph_s(canonical_text),
					Html.paragraph_s(focus_text),
					Html.paragraph_s(blur_text),
					Html.paragraph_s(composition_start_text),
					Html.paragraph_s(composition_end_text),
				],
			)
		},
	)
}
