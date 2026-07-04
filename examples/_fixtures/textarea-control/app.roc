app [main] { pf: platform "https://github.com/lukewilliamboswell/roc-signals/releases/download/0.1/3eLQGNMDG9RuL9sn1A7ep1Rtq7QGmemE89y141WSv1XG.tar.zst" }

import pf.Elem exposing [Elem]
import pf.Html
import pf.Signal
import pf.Ui

State : {
	body : Str,
	focus_count : I64,
	blur_count : I64,
}

initial_state : State
initial_state = {
	body: "",
	focus_count: 0,
	blur_count: 0,
}

concat3 : Str, Str, Str -> Str
concat3 = |a, b, c| Str.concat(Str.concat(a, b), c)

canonical : Str -> Str
canonical = |value| Str.concat("saved:", value)

record_body : State, Str -> State
record_body = |state, value| { ..state, body: canonical(value) }

record_focus : State -> State
record_focus = |state| { ..state, focus_count: state.focus_count + 1 }

record_blur : State -> State
record_blur = |state| { ..state, blur_count: state.blur_count + 1 }

label_i64 : Str, I64 -> Str
label_i64 = |name, value| concat3(name, ": ", value.to_str())

body_label : Str -> Str
body_label = |value| Str.concat("Canonical body: ", value)

main : {} -> Elem
main = |_| {
	Ui.state(
		initial_state,
		|model| {
			state_signal = model.signal()
			body_signal = Signal.map(state_signal, |state| state.body)
			body_text = Signal.map(body_signal, body_label)
			focus_text = Signal.map(state_signal, |state| label_i64("Focus events", state.focus_count))
			blur_text = Signal.map(state_signal, |state| label_i64("Blur events", state.blur_count))

			Html.section(
				"Textarea Control",
				[Html.attr("data-fixture", "textarea-control")],
				[
					Html.heading("Textarea Control"),
					Html.textarea_attrs(
						"Message",
						body_signal,
						[
							Html.attr("id", "message-body"),
							Html.attr("placeholder", "Write a note"),
							Html.on_focus(model.on_unit(record_focus)),
							Html.on_blur(model.on_unit(record_blur)),
						],
						model.on_str(record_body),
					),
					Html.paragraph_s(body_text),
					Html.paragraph_s(focus_text),
					Html.paragraph_s(blur_text),
				],
			)
		},
	)
}
