app [main] { pf: platform "../../../platform/main.roc" }

import pf.Elem exposing [Elem]
import pf.Html
import pf.Signal
import pf.Ui

## Keyboard event coverage: Html.on_key_down delivers a KeyPayload carrying the
## key name and the shift modifier.
Keys : { last : Str, shift : Bool, count : U64 }

set_key : Keys, Ui.KeyPayload -> Keys
set_key = |state, payload| { last: payload.key, shift: payload.shift_key, count: state.count + 1 }

key_text : Keys -> Str
key_text = |state| {
	suffix = if state.shift { " with Shift" } else { "" }
	if state.last.is_empty() {
		"No key yet"
	} else {
		"Key: ${state.last}${suffix}"
	}
}

count_text : Keys -> Str
count_text = |state| "Keys seen: ${state.count.to_str()}"

main : () -> Elem
main = || {
	Ui.state(
		{ last: "", shift: False, count: 0 },
		|keys| {
			Html.section(
				"Keyboard",
				[Html.attr("data-fixture", "keyboard-events")],
				[
					Html.heading("Keyboard"),
					Html.text_input_attrs(
						"Key capture",
						Signal.const(""),
						[Html.on_key_down(keys.on_key(set_key))],
						keys.on_str(|state, _value| state),
					),
					Html.paragraph_s_attrs(Signal.map(keys.signal(), key_text), [Html.test_id("last-key")]),
					Html.paragraph_s_attrs(Signal.map(keys.signal(), count_text), [Html.test_id("key-count")]),
				],
			)
		},
	)
}
