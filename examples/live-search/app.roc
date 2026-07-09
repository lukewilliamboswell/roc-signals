app [main] { pf: platform "https://github.com/lukewilliamboswell/roc-signals/releases/download/0.1/3eLQGNMDG9RuL9sn1A7ep1Rtq7QGmemE89y141WSv1XG.tar.zst" }

import pf.Elem exposing [Elem]
import pf.Browser
import pf.Html
import pf.Signal
import pf.Ui

page_class = "grid gap-5"

hero_class = "panel grid gap-2 p-5"

panel_class = "panel grid gap-4 p-4"

input_class = "w-full max-w-md rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm"

TaskView := [Loading, Done(Str), Failed(Str)]

status_text : TaskView -> Str
status_text = |status|
	match status {
		Loading => "Search status: loading"
		Done(_) => "Search status: results ready"
		Failed(_) => "Search status: failed"
	}

is_done : TaskView -> Bool
is_done = |status|
	match status {
		Done(_) => True
		_ => False
	}

is_failed : TaskView -> Bool
is_failed = |status|
	match status {
		Failed(_) => True
		_ => False
	}

done_text : TaskView -> Str
done_text = |status|
	match status {
		Done(value) => "Results: ${value}"
		_ => "Waiting for search results"
	}

failed_text : TaskView -> Str
failed_text = |status|
	match status {
		Failed(err) => "Search error: ${err}"
		_ => "No search error"
	}

online_text : Bool -> Str
online_text = |online|
	if online {
		"Network: online"
	} else {
		"Network: offline - search paused"
	}

toggle_label : Bool -> Str
toggle_label = |shown|
	if shown {
		"Close results"
	} else {
		"Open results"
	}

panel : Ui.State(Str), _ -> Elem
panel = |query, task| {
	ticks = Signal.interval(1000)
	online = Browser.online
	tick_text = ticks.map(|n| "Freshness check: ${n.to_str()}")
	network_text = online.map(online_text)
	search_request = { query: query.signal(), online: online }.Signal
	status =
		Signal.fold_task(
			task,
			Loading,
			|value| Done(value),
			|err| Failed(err),
		)

	Html.section_c(
		"Search results",
		panel_class,
		[
			Html.text_input_c("Search", query.signal(), input_class, query.on_str(|_, value| value)),
			Html.paragraph_s_c(network_text, "text-sm font-medium text-zinc-900"),
			Html.paragraph_s_c(status.map(status_text), "text-sm font-medium text-zinc-900"),
			Html.paragraph_s_c(status.map(done_text), "text-sm text-zinc-700"),
			Html.paragraph_s_c(status.map(failed_text), "text-sm text-red-950"),
			Html.paragraph_s_c(tick_text, "text-sm text-zinc-600"),
			Ui.on_change(
				search_request,
				|request|
					if request.online {
						Signal.start_str(task, request.query)
					} else {
						Signal.noop
					},
			),
			Ui.on_cleanup(Signal.cleanup("live search panel cleanup")),
		],
	)
}

main : () -> Elem
main = || {
	Ui.state(
		True,
		|show_panel| {
			Ui.state(
				"",
				|query| {
					task = Signal.fake_task("lookup", |value| value, |err| err)
					toggle_text = show_panel.signal().map(toggle_label)

					Html.div_c(
						page_class,
						[
							Html.section_c(
								"Live Search",
								hero_class,
								[
									Html.heading_c("Live Search", "text-3xl font-semibold text-zinc-950"),
									Html.paragraph_c("Search as you type, show loading and error states, refresh freshness ticks, and cancel in-flight work when the panel closes.", "max-w-3xl text-sm text-zinc-700"),
								],
							),
							Html.button_s_c(toggle_text, "button-primary justify-self-start", show_panel.on_unit(|value| !value)),
							Ui.when(
								show_panel.signal(),
								|| panel(query, task),
								|| Html.section_c("Search panel closed", panel_class, [Html.paragraph("Closed")]),
							),
						],
					)
				},
			)
		},
	)
}
