app [main] { pf: platform "https://github.com/lukewilliamboswell/roc-signals/releases/download/0.1/3eLQGNMDG9RuL9sn1A7ep1Rtq7QGmemE89y141WSv1XG.tar.zst" }

import pf.Elem exposing [Elem]
import pf.Html
import pf.Signal
import pf.Ui

Profile : { first : Str, last : Str, active : Bool }

summary_text : Profile -> Str
summary_text = |profile| {
	status =
		if profile.active {
			"active"
		} else {
			"paused"
		}

	"Profile: ${profile.first} ${profile.last} is ${status}"
}

profile_ready : Profile -> Bool
profile_ready = |profile| (!profile.first.is_empty()) and (!profile.last.is_empty()) and profile.active

ready_text : Profile -> Str
ready_text = |profile|
	if profile_ready(profile) {
		"Ready: yes"
	} else {
		"Ready: no"
	}

ready_disabled : Profile -> Bool
ready_disabled = |profile| !profile_ready(profile)

page_class = "grid gap-5"

panel_class = "panel grid gap-4 p-4"

input_class = "w-full max-w-md rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm"

main : () -> Elem
main = || {
	Ui.state(
		"Ada",
		|first| {
			Ui.state(
				"Lovelace",
				|last| {
					Ui.state(
						True,
						|active| {
							profile : Signal.Signal(Profile)
							profile =
								{
									first: first.signal(),
									last: last.signal(),
									active: active.signal(),
								}.Signal
							summary : Signal.Signal(Str)
							summary = profile.map(summary_text)
							ready : Signal.Signal(Str)
							ready = profile.map(ready_text)
							disabled : Signal.Signal(Bool)
							disabled = profile.map(ready_disabled)

							Html.div_c(
								page_class,
								[
									Html.section(
										"Signal Record Builder",
										[Html.attr("data-fixture", "signal-record-builder")],
										[
											Html.heading("Signal Record Builder"),
										],
									),
									Html.form_label(
										"Profile form",
										[Html.class_attr(panel_class)],
										[
											Html.text_input_c("First name", first.signal(), input_class, first.on_str(|_, value| value)),
											Html.text_input_c("Last name", last.signal(), input_class, last.on_str(|_, value| value)),
											Html.checkbox("Active profile", active.signal(), active.on_bool(|_, checked| checked)),
											Html.paragraph_s_c(summary, "text-sm text-zinc-700"),
											Html.paragraph_s_c(ready, "text-sm font-medium text-zinc-900"),
											Html.action_button(Signal.const("Continue"), disabled, first.on_unit(|value| value)),
										],
									),
								],
							)
						},
					)
				},
			)
		},
	)
}
