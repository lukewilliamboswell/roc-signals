app [main] { pf: platform "https://github.com/lukewilliamboswell/roc-signals/releases/download/0.1/3eLQGNMDG9RuL9sn1A7ep1Rtq7QGmemE89y141WSv1XG.tar.zst" }

import pf.Elem exposing [Elem]
import pf.Html
import pf.Signal
import pf.Ui

FormState : {
	email : Str,
	accepted : Bool,
	attempted : Bool,
	submit_count : I64,
	submit_request : Str,
}

initial_state : FormState
initial_state = {
	email: "",
	accepted: False,
	attempted: False,
	submit_count: 0,
	submit_request: "",
}

can_submit_state : FormState -> Bool
can_submit_state = |state| (!state.email.is_empty()) and state.accepted

email_invalid_state : FormState -> Bool
email_invalid_state = |state| state.attempted and state.email.is_empty()

terms_invalid_state : FormState -> Bool
terms_invalid_state = |state| state.attempted and !state.accepted

set_email : FormState, Str -> FormState
set_email = |state, value| { ..state, email: value }

set_accepted : FormState, Bool -> FormState
set_accepted = |state, accepted| { ..state, accepted }

submit_if_valid : FormState -> FormState
submit_if_valid = |state| {
	if can_submit_state(state) {
		next_count = state.submit_count + 1
		request = "${state.email}#${next_count.to_str()}"
		{ ..state, attempted: True, submit_count: next_count, submit_request: request }
	} else {
		{ ..state, attempted: True }
	}
}

email_message : FormState -> Str
email_message = |state|
	if email_invalid_state(state) {
		"Email validation: enter an email address."
	} else {
		"Email validation: ready."
	}

terms_message : FormState -> Str
terms_message = |state|
	if terms_invalid_state(state) {
		"Terms validation: accept terms to continue."
	} else {
		"Terms validation: ready."
	}

status_message : FormState, Str -> Str
status_message = |state, task_text|
	if state.submit_count == 0 {
		"Submit status: idle"
	} else {
		task_text
	}

disabled_state : FormState, Bool -> Bool
disabled_state = |state, task_loading| (!can_submit_state(state)) or ((state.submit_count > 0) and task_loading)

page_class = "grid gap-5"

panel_class = "panel grid gap-4 p-4"

input_class = "w-full max-w-md rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm"

main : {} -> Elem
main = |_| {
	Ui.state(
		initial_state,
		|model| {
			state_signal : Signal.Signal(FormState)
			state_signal = model.signal()
			email_signal : Signal.Signal(Str)
			email_signal = state_signal.map(|state| state.email)
			accepted_signal : Signal.Signal(Bool)
			accepted_signal = state_signal.map(|state| state.accepted)
			request_signal : Signal.Signal(Str)
			request_signal = state_signal.map(|state| state.submit_request)
			email_invalid : Signal.Signal(Bool)
			email_invalid = state_signal.map(email_invalid_state)
			terms_invalid : Signal.Signal(Bool)
			terms_invalid = state_signal.map(terms_invalid_state)
			email_text : Signal.Signal(Str)
			email_text = state_signal.map(email_message)
			terms_text : Signal.Signal(Str)
			terms_text = state_signal.map(terms_message)
			task = Signal.fake_task("form-submit", |value| value, |err| err)
			task_text : Signal.Signal(Str)
			task_text =
				Signal.fold_task(
					task,
					"Submit status: sending",
					|value| "Submit result: ${value}",
					|err| "Submit error: ${err}",
				)
			task_loading : Signal.Signal(Bool)
			task_loading = Signal.fold_task(task, True, |_| False, |_| False)
			status_inputs : Signal.Signal({ state : FormState, task_text : Str })
			status_inputs = { state: state_signal, task_text: task_text }.Signal
			status_text : Signal.Signal(Str)
			status_text = status_inputs.map(|inputs| status_message(inputs.state, inputs.task_text))
			disabled_inputs : Signal.Signal({ state : FormState, task_loading : Bool })
			disabled_inputs = { state: state_signal, task_loading: task_loading }.Signal
			submit_disabled : Signal.Signal(Bool)
			submit_disabled = disabled_inputs.map(|inputs| disabled_state(inputs.state, inputs.task_loading))

			Html.div_c(
				page_class,
				[
					Html.section(
						"Form Validation Pattern",
						[Html.attr("data-fixture", "form-validation-pattern")],
						[
							Html.heading("Form Validation Pattern"),
						],
					),
					Html.form_label(
						"Validation form",
						[
							Html.class_attr(panel_class),
							Html.attr("id", "validation-form"),
							Html.on_submit_prevent_default(model.on_unit(submit_if_valid)),
						],
						[
							Html.text_input_attrs(
								"Invite email",
								email_signal,
								[
									Html.class_attr(input_class),
									Html.attr("id", "invite-email"),
									Html.attr("type", "email"),
									Html.aria_describedby("invite-email-message"),
									Html.aria_invalid_s(email_invalid),
								],
								model.on_str(set_email),
							),
							Html.div(
								[
									Html.attr("id", "invite-email-message"),
									Html.class_attr("text-sm text-zinc-700"),
								],
								[Html.text_s(email_text)],
							),
							Html.checkbox_attrs(
								"Accept terms",
								accepted_signal,
								[
									Html.aria_describedby("terms-message"),
									Html.aria_invalid_s(terms_invalid),
								],
								model.on_bool(set_accepted),
							),
							Html.div(
								[
									Html.attr("id", "terms-message"),
									Html.class_attr("text-sm text-zinc-700"),
								],
								[Html.text_s(terms_text)],
							),
							Html.paragraph_s_c(status_text, "text-sm font-medium text-zinc-900"),
							Html.action_button_attrs(
								Signal.const("Send invite"),
								submit_disabled,
								[Html.class_attr("button-primary"), Html.attr("type", "button")],
								model.on_unit(submit_if_valid),
							),
							Ui.on_change(request_signal, |request| Signal.start_str(task, request)),
						],
					),
				],
			)
		},
	)
}
