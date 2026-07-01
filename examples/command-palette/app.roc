app [main] { pf: platform "https://github.com/lukewilliamboswell/roc-signals/releases/download/0.1/3eLQGNMDG9RuL9sn1A7ep1Rtq7QGmemE89y141WSv1XG.tar.zst" }

import pf.Elem exposing [Elem]
import pf.Html
import pf.Signal
import pf.Ui

PaletteState : {
	query : Str,
	last_key : Str,
	shift_key : Bool,
	submits : I64,
}

initial_state : PaletteState
initial_state = {
	query: "",
	last_key: "none",
	shift_key: False,
	submits: 0,
}

concat3 : Str, Str, Str -> Str
concat3 = |a, b, c| Str.concat(Str.concat(a, b), c)

concat4 : Str, Str, Str, Str -> Str
concat4 = |a, b, c, d| Str.concat(concat3(a, b, c), d)

set_query : PaletteState, Str -> PaletteState
set_query = |state, value| { ..state, query: value }

set_key : PaletteState, Ui.KeyPayload -> PaletteState
set_key = |state, payload| {
	{ ..state, last_key: payload.key, shift_key: payload.shift_key }
}

record_submit : PaletteState -> PaletteState
record_submit = |state| { ..state, submits: state.submits + 1 }

shortcut_label : PaletteState -> Str
shortcut_label = |state| {
	shift_label =
		if state.shift_key {
			" with Shift"
		} else {
			""
		}

	concat4("Shortcut captured: ", state.last_key, shift_label, "")
}

submit_label : PaletteState -> Str
submit_label = |state| {
	if state.submits == 0 {
		"No command has run yet"
	} else {
		Str.concat("Commands run: ", state.submits.to_str())
	}
}

query_label : PaletteState -> Str
query_label = |state| {
	if Str.is_empty(state.query) {
		"Start typing to filter actions"
	} else {
		Str.concat("Filtering actions for: ", state.query)
	}
}

page_class : Str
page_class = "grid gap-5"

hero_class : Str
hero_class = "panel grid gap-2 p-5"

panel_class : Str
panel_class = "panel grid gap-4 p-4"

toolbar_class : Str
toolbar_class = "flex flex-wrap items-center gap-3"

input_class : Str
input_class = "w-full max-w-md rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm"

main : {} -> Elem
main = |_| {
	Ui.state(
		initial_state,
		|model| {
			state_signal = model.signal()
			query_signal = Signal.map(state_signal, |state| state.query)
			key_signal = Signal.map(state_signal, shortcut_label)
			submit_signal = Signal.map(state_signal, submit_label)
			query_text = Signal.map(state_signal, query_label)

			Html.div_c(
				page_class,
				[
					Html.section(
						"Command Palette",
						[Html.class_attr(hero_class), Html.attr("data-app", "command-palette")],
						[
							Html.heading_c("Command Palette", "text-3xl font-semibold text-zinc-950"),
							Html.paragraph_c("Search workspace actions, capture shortcuts, and run a command without leaving the keyboard.", "max-w-3xl text-sm text-zinc-700"),
							Html.div_c(
								toolbar_class,
								[
									Html.link(
										"Command docs",
										[
											Html.attr("href", "/docs/guide/"),
											Html.attr("aria-label", "Command docs"),
											Html.attr("data-link", "guide"),
										],
									),
								],
							),
						],
					),
					Html.form_label(
						"Command form",
						[
							Html.class_attr(panel_class),
							Html.attr("id", "command-form"),
							Html.attr("data-form", "command-palette"),
							Html.on_submit_prevent_default(model.on_unit(record_submit)),
						],
						[
							Html.text_input_attrs(
								"Command search",
								query_signal,
								[
									Html.class_attr(input_class),
									Html.attr("id", "command-search"),
									Html.attr("placeholder", "Search actions or jump to a page"),
									Html.attr("data-static", "ready"),
									Html.attr_s("data-query", query_signal),
									Html.on_key_down(model.on_key(set_key)),
								],
								model.on_str(set_query),
							),
							Html.paragraph_s_c(query_text, "text-sm text-zinc-700"),
							Html.paragraph_s_c(key_signal, "text-sm font-medium text-zinc-900"),
							Html.paragraph_s_c(submit_signal, "text-sm text-zinc-600"),
							Html.button_c("Run command", "button-primary", model.on_unit(record_submit)),
						],
					),
				],
			)
		},
	)
}
