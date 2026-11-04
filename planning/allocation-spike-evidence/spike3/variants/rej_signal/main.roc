app [main] { roc: "nightly-2026-11-01-48d3369", pf: platform "../../../../../../../../../home/lbw/Documents/Github/roc-signals/.claude/worktrees/agent-a9954894a6aa838c9/platform-web/main.roc" }

import pf.Elem
import pf.Html
import pf.Rows
import pf.Signal
import pf.Ui

main : () -> Elem
main = ||
	Ui.state(
		0.U64,
		|model| {
			rows = Signal.const(Rows.from_list([{ id: "a" }], |item| item.id) ?? crash "unique")
			Html.div([Html.test_id("root"), Html.on_event("x", Html.event_policy_none, model.update(|n| n))], [Ui.each_template(rows, |_row| Html.text_s(Signal.const("x")))])
		},
	)
