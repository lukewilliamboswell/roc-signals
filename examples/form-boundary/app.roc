app [main] { pf: platform "https://github.com/lukewilliamboswell/roc-signals/releases/download/0.1/3eLQGNMDG9RuL9sn1A7ep1Rtq7QGmemE89y141WSv1XG.tar.zst" }

import pf.Elem exposing [Elem]
import pf.Html
import pf.Signal
import pf.Ui

FormState : {
	email : Str,
	accepted : Bool,
	focus_count : I64,
	blur_count : I64,
	change_count : I64,
	submit_count : I64,
	composition_start_count : I64,
	composition_end_count : I64,
}

initial_state : FormState
initial_state = {
	email: "",
	accepted: False,
	focus_count: 0,
	blur_count: 0,
	change_count: 0,
	submit_count: 0,
	composition_start_count: 0,
	composition_end_count: 0,
}

concat3 : Str, Str, Str -> Str
concat3 = |a, b, c| Str.concat(Str.concat(a, b), c)

label_i64 : Str, I64 -> Str
label_i64 = |name, value| concat3(name, ": ", value.to_str())

update_email : FormState, Str -> FormState
update_email = |state, value| { ..state, email: value }

record_change : FormState, Str -> FormState
record_change = |state, value| { ..state, email: value, change_count: state.change_count + 1 }

record_terms : FormState, Bool -> FormState
record_terms = |state, accepted| { ..state, accepted }

record_submit : FormState -> FormState
record_submit = |state| {
	if (!Str.is_empty(state.email)) and state.accepted {
		{ ..state, submit_count: state.submit_count + 1 }
	} else {
		state
	}
}

record_focus : FormState -> FormState
record_focus = |state| { ..state, focus_count: state.focus_count + 1 }

record_blur : FormState -> FormState
record_blur = |state| { ..state, blur_count: state.blur_count + 1 }

record_composition_start : FormState -> FormState
record_composition_start = |state| { ..state, composition_start_count: state.composition_start_count + 1 }

record_composition_end : FormState -> FormState
record_composition_end = |state| { ..state, composition_end_count: state.composition_end_count + 1 }

invalid_label : Str -> Str
invalid_label = |value| {
	if Str.is_empty(value) {
		"Invalid: yes"
	} else {
		"Invalid: no"
	}
}

terms_label : Bool -> Str
terms_label = |accepted| {
	if accepted {
		"Terms accepted"
	} else {
		"Terms pending"
	}
}

main : {} -> Elem
main = |_| {
	Ui.state(
		initial_state,
		|model| {
			state_signal = model.signal()
			email_signal = Signal.map(state_signal, |state| state.email)
			accepted_signal = Signal.map(state_signal, |state| state.accepted)
			invalid_signal = Signal.map(email_signal, |value| Str.is_empty(value))
			invalid_text = Signal.map(email_signal, invalid_label)
			terms_text = Signal.map(accepted_signal, terms_label)
			focus_text = Signal.map(state_signal, |state| label_i64("Focus events", state.focus_count))
			blur_text = Signal.map(state_signal, |state| label_i64("Blur events", state.blur_count))
			change_text = Signal.map(state_signal, |state| label_i64("Change events", state.change_count))
			submit_text = Signal.map(state_signal, |state| label_i64("Submits", state.submit_count))
			composition_start_text = Signal.map(state_signal, |state| label_i64("Composition start events", state.composition_start_count))
			composition_end_text = Signal.map(state_signal, |state| label_i64("Composition end events", state.composition_end_count))

			Html.section(
				"Form boundary",
				[Html.attr("data-boundary", "forms")],
				[
					Html.heading_c("Form boundary", "text-2xl font-semibold text-zinc-950"),
					Html.paragraph_c("Boolean attributes and named form events stay reactive across native and JS hosts.", "max-w-3xl text-sm text-zinc-700"),
					Html.form_label(
						"Signup form",
						[
							Html.attr("id", "signup-form"),
							Html.attr("data-form", "form-boundary"),
							Html.on_submit_prevent_default(model.on_unit(record_submit)),
						],
						[
							Html.text_input_attrs(
								"Email",
								email_signal,
								[
									Html.class_attr("w-full max-w-md"),
									Html.attr("id", "form-boundary-email"),
									Html.attr("type", "email"),
									Html.attr("name", "email"),
									Html.attr("placeholder", "team@example.com"),
									Html.attr("autocomplete", "email"),
									Html.required,
									Html.aria_describedby("email-help"),
									Html.aria_invalid_s(invalid_signal),
									Html.on_focus(model.on_unit(record_focus)),
									Html.on_blur(model.on_unit(record_blur)),
									Html.on_change(model.on_str(record_change)),
									Html.on_composition_start(model.on_unit(record_composition_start)),
									Html.on_composition_end(model.on_unit(record_composition_end)),
								],
								model.on_str(update_email),
							),
							Html.paragraph_attrs(
								"Email is required.",
								[
									Html.attr("id", "email-help"),
									Html.class_attr("text-sm text-zinc-600"),
								],
							),
							Html.text_input_attrs(
								"Reference",
								Signal.const("READ-ONLY"),
								[
									Html.class_attr("w-full max-w-md"),
									Html.attr("id", "form-boundary-reference"),
									Html.readonly,
								],
								model.on_str(|state, _value| state),
							),
							Html.checkbox("Accept terms", accepted_signal, model.on_bool(record_terms)),
							Html.paragraph_s(terms_text),
							Html.button("Submit form", model.on_unit(|state| state)),
						],
					),
					Html.paragraph_s(invalid_text),
					Html.paragraph_s(submit_text),
					Html.paragraph_s(focus_text),
					Html.paragraph_s(blur_text),
					Html.paragraph_s(change_text),
					Html.paragraph_s(composition_start_text),
					Html.paragraph_s(composition_end_text),
				],
			)
		},
	)
}
