app [main] { pf: platform "https://github.com/lukewilliamboswell/roc-signals/releases/download/0.1/3eLQGNMDG9RuL9sn1A7ep1Rtq7QGmemE89y141WSv1XG.tar.zst" }

import pf.Elem exposing [Elem]
import pf.Html
import pf.Signal
import pf.Ui

State : {
	draft : Str,
	committed : U64,
	commits : I64,
	errors : I64,
}

initial_state : State
initial_state = {
	draft: "3",
	committed: 3,
	commits: 0,
	errors: 0,
}

concat3 : Str, Str, Str -> Str
concat3 = |a, b, c| Str.concat(Str.concat(a, b), c)

set_draft : State, Str -> State
set_draft = |state, value| { ..state, draft: value }

commit_draft : State -> State
commit_draft = |state| {
	match U64.from_str(state.draft) {
		Ok(value) => { ..state, committed: value, draft: value.to_str(), commits: state.commits + 1 }
		Err(_) => { ..state, errors: state.errors + 1 }
	}
}

draft_label : Str -> Str
draft_label = |value| Str.concat("Draft seats: ", value)

committed_label : U64 -> Str
committed_label = |value| Str.concat("Committed seats: ", value.to_str())

counter_label : Str, I64 -> Str
counter_label = |name, value| concat3(name, ": ", value.to_str())

main : {} -> Elem
main = |_| {
	Ui.state(
		initial_state,
		|model| {
			state_signal = model.signal()
			draft_signal = Signal.map(state_signal, |state| state.draft)
			draft_text = Signal.map(draft_signal, draft_label)
			committed_text = Signal.map(state_signal, |state| committed_label(state.committed))
			commits_text = Signal.map(state_signal, |state| counter_label("Commits", state.commits))
			errors_text = Signal.map(state_signal, |state| counter_label("Commit errors", state.errors))

			Html.section(
				"Number Input Control",
				[Html.attr("data-fixture", "number-input-control")],
				[
					Html.heading("Number Input Control"),
					Html.number_input_attrs(
						"Seats",
						draft_signal,
						[
							Html.attr("id", "seat-count"),
							Html.attr("min", "0"),
							Html.attr("step", "1"),
							Html.on_focus(model.on_unit(|state| state)),
							Html.on_blur(model.on_unit(commit_draft)),
						],
						model.on_str(set_draft),
					),
					Html.paragraph_s(draft_text),
					Html.paragraph_s(committed_text),
					Html.paragraph_s(commits_text),
					Html.paragraph_s(errors_text),
				],
			)
		},
	)
}
