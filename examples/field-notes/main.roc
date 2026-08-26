app [main] { pf: platform "https://github.com/lukewilliamboswell/roc-signals/releases/download/0.1/3eLQGNMDG9RuL9sn1A7ep1Rtq7QGmemE89y141WSv1XG.tar.zst" }

import Notes
import pf.Browser
import pf.Elem exposing [Elem]
import pf.Html
import pf.Signal
import pf.Ui

## Field Notes: an offline-first note capture tool.
##
## Notes are captured while the browser is offline, queued in an outbox, and
## synced one at a time when the connection returns. Local storage is the base
## of truth: the notes signal is the restored value replayed through the
## session's operation log, so no reducer ever has to read a signal.

## --- view -------------------------------------------------------------------

page_class = "app-shell"

panel_class = "panel grid gap-4 p-4"

note_class = "card gap-3 p-4"

toolbar_class = "flex flex-wrap items-center gap-2"

## Online/offline is this app's central condition, so it is a banner rather than
## a line of status text. Both the tone and the sentence come off the same
## `board.online` field.
network_class : Bool -> Str
network_class = |online| if online { "notice notice-ok" } else { "notice notice-warn" }

auto_class : Bool -> Str
auto_class = |auto| if auto { "badge badge-ok" } else { "badge badge-warn" }

## Badge tone per note, derived from the same `Notes.Status` tag that produces
## the badge's caption, so the colour can never disagree with the word.
status_class : Notes.Status -> Str
status_class = |status|
	match status {
		Draft => "badge badge-neutral"
		Queued => "badge badge-warn"
		Syncing => "badge badge-warn"
		Synced => "badge badge-ok"
		Failed => "badge badge-danger"
	}

## A failed note has to offer its retry where the failure is shown, so the retry
## control is loud exactly while it is the thing to do.
retry_class : Notes.Status -> Str
retry_class = |status|
	match status {
		Failed => "button-danger button-sm"
		_ => "button button-sm"
	}

## One metric tile. A count is a label and a number, not a sentence.
stat : Str, Signal.Signal(Str), Str -> Elem
stat = |label, value, test_id|
	Html.div_c(
		"stat",
		[
			Html.paragraph_c(label, "stat-label"),
			Html.paragraph_s_attrs(value, [Html.class_attr("stat-value"), Html.test_id(test_id)]),
		],
	)

## A checkbox draws no caption of its own, so the visible label is next to it.
check_row : Str, Signal.Signal(Bool), _ -> Elem
check_row = |label, checked, msg|
	Html.div_c(
		"check-row",
		[Html.checkbox_c(label, checked, "checkbox", msg), Html.text(label)],
	)

render_note : Ui.State(Notes.Capture), Str, Signal.Signal(Notes.Row) -> Elem
render_note = |capture, key, row|
	Html.section(
		"Note ${key}",
		[Html.class_attr(note_class), Html.attr_s("data-status", row.map(|value| Notes.status_code(value.status)))],
		[
			Html.div_c(
				"flex flex-wrap items-center justify-between gap-2",
				[
					Html.heading_c("Note ${key}", "card-title"),
					Html.paragraph_s_attrs(
						row.map(|value| Notes.status_title(value.status)),
						[Html.class_attr_s(row.map(|value| status_class(value.status))), Html.test_id("status-${key}")],
					),
				],
			),
			Html.div_c(
				"field",
				[
					Html.paragraph_c("Body ${key}", "field-label"),
					Html.text_input_attrs(
						"Body ${key}",
						row.map(|value| value.body),
						[Html.class_attr("input"), Html.attr("placeholder", "Generator hours 128")],
						capture.on_str(|current, text| Notes.edit_note(current, key, Notes.sanitize(text))),
					),
				],
			),
			Html.paragraph_s_c(row.map(|value| value.detail), "hint numeric"),
			Html.div_c(
				toolbar_class,
				[
					Html.action_button_c(
						Signal.const("Queue note ${key}"),
						row.map(|value| value.queue_disabled),
						"button button-sm",
						capture.on_unit(|current| Notes.push_op(current, OpQueue(key))),
					),
					Html.action_button_attrs(
						Signal.const("Retry note ${key}"),
						row.map(|value| value.retry_disabled),
						[Html.class_attr_s(row.map(|value| retry_class(value.status)))],
						capture.on_unit(|current| Notes.retry_note(current, key)),
					),
					Html.button_c("Promote note ${key}", "button-ghost button-sm", capture.on_unit(|current| Notes.push_op(current, OpPromote(key)))),
					Html.button_c("Delete note ${key}", "button-ghost button-sm", capture.on_unit(|current| Notes.push_op(current, OpDelete(key)))),
				],
			),
		],
	)

## The one place a lane request becomes wire text.
sync_lane = |board, task, slot|
	Ui.on_change_initial(
		board.map(|value| Notes.request_at(value, slot)),
		|request|
			match request {
				Idle => Signal.noop
				Send(request_token) => Signal.start_str(task, request_token)
			},
	)

main : () -> Elem
main = || {
	stored = Browser.local_storage_text(Notes.notes_key)

	Ui.state(
		Notes.initial_capture,
		|capture|
			Ui.state(
				True,
				|auto_sync|
					Ui.state(
						False,
						|hide_synced| {
							## A lane's value is a settlement record, not a live status, so lanes
							## are built with reset_on_start = False: starting a request must not
							## erase the Notes.token the lane last settled.
							task_0 = Signal.task_source("note-sync", |value| value, |err| err, False)
							task_1 = Signal.task_source("note-sync", |value| value, |err| err, False)
							task_2 = Signal.task_source("note-sync", |value| value, |err| err, False)
							task_3 = Signal.task_source("note-sync", |value| value, |err| err, False)

							## Wide fan-in: one lane status signal per outbox lane, each from its
							## own task source, combined into the lane status vector.
							views =
								Signal.combine(
									[
										Signal.fold_task(task_0, TaskIdle, |value| TaskDone(value), |err| TaskFailed(err)),
										Signal.fold_task(task_1, TaskIdle, |value| TaskDone(value), |err| TaskFailed(err)),
										Signal.fold_task(task_2, TaskIdle, |value| TaskDone(value), |err| TaskFailed(err)),
										Signal.fold_task(task_3, TaskIdle, |value| TaskDone(value), |err| TaskFailed(err)),
									],
								)

							base_notes = stored.map(Notes.stored_notes)
							notes = Signal.map2(base_notes, capture.signal(), |base, current| current.ops.fold(base, Notes.apply_op))

							board = {
								notes: notes,
								online: Browser.online(),
								auto: auto_sync.signal(),
								views: views,
							}.Signal

							rows = board.map(Notes.board_rows)
							visible_rows =
								Signal.map2(
									rows,
									hide_synced.signal(),
									|all_rows, hide|
										if hide {
											all_rows.keep_if(|row| row.status != Synced)
										} else {
											all_rows
										},
								)

							draft_signal = capture.signal().map(|value| value.draft)
							save_disabled =
								Signal.map2(
									draft_signal,
									rows,
									|draft, all_rows| Notes.sanitize(draft).trim() == "" or Notes.is_full(all_rows),
								)
							outbox_empty = rows.map(|value| Notes.outbox_count(value) == 0)
							notes_empty = rows.map(|value| value.is_empty())
							online_signal = board.map(|value| value.online)

							Html.div_c(
								page_class,
								[
									Html.section_c(
										"Field Notes",
										"app-header",
										[
											Html.heading_c("Field Notes", "app-title"),
											Html.paragraph_c("Capture notes while offline, queue them in an outbox, and sync them one at a time when the connection returns.", "app-subtitle"),
										],
									),
									Html.section(
										"Sync status",
										[Html.class_attr(panel_class), Html.attr_s("data-network", board.map(|value| if value.online { "online" } else { "offline" }))],
										[
											Html.paragraph_s_attrs(
												online_signal.map(Notes.network_text),
												[Html.class_attr_s(online_signal.map(network_class)), Html.test_id("network")],
											),
											Html.div_c(
												"stat-grid",
												[
													stat("Outbox", rows.map(|value| Notes.outbox_count(value).to_str()), "outbox-count"),
													stat("Syncing", rows.map(Notes.syncing_text), "syncing"),
													stat("Failed", rows.map(|value| Notes.count_status(value, Failed).to_str()), "failed-count"),
													stat("Synced", rows.map(|value| Notes.count_status(value, Synced).to_str()), "synced-count"),
												],
											),
											Html.div_c(
												"toolbar justify-between border-t border-zinc-200 pt-3",
												[
													Html.div_c(
														toolbar_class,
														[
															check_row("Sync automatically", auto_sync.signal(), auto_sync.on_bool(|_current, checked| checked)),
															check_row("Hide synced notes", hide_synced.signal(), hide_synced.on_bool(|_current, checked| checked)),
														],
													),
													Html.div_c(
														toolbar_class,
														[
															Html.paragraph_s_attrs(
																board.map(|value| Notes.auto_text(value.auto)),
																[Html.class_attr_s(board.map(|value| auto_class(value.auto))), Html.test_id("auto-sync")],
															),
															Html.paragraph_s_attrs(
																rows.map(Notes.capacity_text),
																[Html.class_attr("badge badge-neutral numeric"), Html.test_id("capacity")],
															),
														],
													),
												],
											),
											Html.paragraph_s_attrs(stored.map(Notes.storage_notice), [Html.class_attr("hint"), Html.test_id("storage-notice")]),
										],
									),
									Html.section_c(
										"Capture",
										panel_class,
										[
											Html.heading_c("New note", "panel-title"),
											Html.div_c(
												"field",
												[
													Html.paragraph_c("Note body", "field-label"),
													Html.textarea_attrs(
														"Note body",
														draft_signal,
														[Html.class_attr("input textarea"), Html.attr("placeholder", "Pump pressure 4.2 bar at the west wellhead")],
														capture.on_str(|current, text| { ..current, draft: text }),
													),
												],
											),
											Html.action_button_c(Signal.const("Save note"), save_disabled, "button-primary justify-self-start", capture.on_unit(Notes.save_note)),
										],
									),
									Html.section_c(
										"Outbox",
										panel_class,
										[
											Html.heading_c("Outbox", "panel-title"),
											Ui.when(
												outbox_empty,
												|| Html.paragraph_c("Outbox is empty", "empty-state"),
												|| Html.paragraph_s_attrs(rows.map(Notes.outbox_text), [Html.class_attr("notice notice-info"), Html.test_id("outbox-detail")]),
											),
										],
									),
									Html.section_c(
										"Notes",
										panel_class,
										[
											Html.heading_c("Captured notes", "panel-title"),
											Ui.when(
												notes_empty,
												|| Html.paragraph_c("No notes captured yet. Write one above — it will save even while you are offline.", "empty-state"),
												|| Html.div_c("grid gap-3", [Ui.each_str(visible_rows, |row| row.id, |key, row| render_note(capture, key, row))]),
											),
										],
									),
									sync_lane(board, task_0, 0),
									sync_lane(board, task_1, 1),
									sync_lane(board, task_2, 2),
									sync_lane(board, task_3, 3),
									Ui.on_change(notes, |value| Browser.set_local_storage_text(Notes.notes_key, Notes.encode_notes(value))),
								],
							)
						},
					),
			),
	)
}
