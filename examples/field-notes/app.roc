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

page_class = "grid gap-5"

hero_class = "panel grid gap-2 p-5"

panel_class = "panel grid gap-4 p-4"

note_class = "panel grid gap-3 p-4"

toolbar_class = "flex flex-wrap items-center gap-3"

input_class = "w-full max-w-md rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm"

render_note : Ui.State(Notes.Capture), Str, Signal.Signal(Notes.Row) -> Elem
render_note = |capture, key, row|
	Html.section(
		"Note ${key}",
		[Html.class_attr(note_class), Html.attr_s("data-status", row.map(|value| value.status))],
		[
			Html.heading_c("Note ${key}", "text-lg font-semibold text-zinc-950"),
			Html.text_input_c(
				"Body ${key}",
				row.map(|value| value.body),
				input_class,
				capture.on_str(|current, text| Notes.edit_note(current, key, Notes.sanitize(text))),
			),
			Html.paragraph_s_attrs(row.map(|value| value.status_label), [Html.class_attr("text-sm font-medium text-zinc-900"), Html.test_id("status-${key}")]),
			Html.div_c(
				toolbar_class,
				[
					Html.action_button_c(
						Signal.const("Queue note ${key}"),
						row.map(|value| value.queue_disabled),
						"button",
						capture.on_unit(|current| Notes.push_op(current, OpQueue(key))),
					),
					Html.action_button_c(
						Signal.const("Retry note ${key}"),
						row.map(|value| value.retry_disabled),
						"button",
						capture.on_unit(|current| Notes.retry_note(current, key)),
					),
					Html.button_c("Promote note ${key}", "button", capture.on_unit(|current| Notes.push_op(current, OpPromote(key)))),
					Html.button_c("Delete note ${key}", "button", capture.on_unit(|current| Notes.push_op(current, OpDelete(key)))),
				],
			),
		],
	)

sync_lane = |board, task, slot|
	Ui.on_change_initial(
		board.map(|value| Notes.request_at(value, slot)),
		|request|
			if request == "" {
				Signal.noop
			} else {
				Signal.start_str(task, request)
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
											all_rows.fold([], |acc, row| if row.status == "synced" { acc } else { acc.append(row) })
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

							Html.div_c(
								page_class,
								[
									Html.section_c(
										"Field Notes",
										hero_class,
										[
											Html.heading_c("Field Notes", "text-3xl font-semibold text-zinc-950"),
											Html.paragraph_c("Capture notes while offline, queue them in an outbox, and sync them one at a time when the connection returns.", "max-w-3xl text-sm text-zinc-700"),
											Html.paragraph_s_attrs(stored.map(Notes.storage_notice), [Html.class_attr("text-sm text-zinc-600"), Html.test_id("storage-notice")]),
										],
									),
									Html.section_c(
										"Capture",
										panel_class,
										[
											Html.heading_c("New note", "text-xl font-semibold text-zinc-950"),
											Html.textarea_c("Note body", draft_signal, input_class, capture.on_str(|current, text| { ..current, draft: text })),
											Html.action_button_c(Signal.const("Save note"), save_disabled, "button-primary justify-self-start", capture.on_unit(Notes.save_note)),
										],
									),
									Html.section(
										"Sync status",
										[Html.class_attr(panel_class), Html.attr_s("data-network", board.map(|value| if value.online { "online" } else { "offline" }))],
										[
											Html.heading_c("Sync status", "text-xl font-semibold text-zinc-950"),
											Html.paragraph_s_attrs(board.map(|value| Notes.network_text(value.online)), [Html.class_attr("text-sm font-medium text-zinc-900"), Html.test_id("network")]),
											Html.paragraph_s_attrs(board.map(|value| Notes.auto_text(value.auto)), [Html.class_attr("text-sm text-zinc-700"), Html.test_id("auto-sync")]),
											Html.paragraph_s_attrs(rows.map(|value| "Outbox: ${Notes.outbox_count(value).to_str()}"), [Html.class_attr("text-sm text-zinc-700"), Html.test_id("outbox-count")]),
											Html.paragraph_s_attrs(rows.map(Notes.syncing_text), [Html.class_attr("text-sm text-zinc-700"), Html.test_id("syncing")]),
											Html.paragraph_s_attrs(rows.map(|value| "Failed: ${Notes.count_status(value, "failed").to_str()}"), [Html.class_attr("text-sm text-zinc-700"), Html.test_id("failed-count")]),
											Html.paragraph_s_attrs(rows.map(|value| "Synced: ${Notes.count_status(value, "synced").to_str()}"), [Html.class_attr("text-sm text-zinc-700"), Html.test_id("synced-count")]),
											Html.paragraph_s_attrs(rows.map(Notes.capacity_text), [Html.class_attr("text-sm text-zinc-700"), Html.test_id("capacity")]),
											Html.checkbox_c("Sync automatically", auto_sync.signal(), "rounded border-zinc-300", auto_sync.on_bool(|_current, checked| checked)),
											Html.checkbox_c("Hide synced notes", hide_synced.signal(), "rounded border-zinc-300", hide_synced.on_bool(|_current, checked| checked)),
										],
									),
									Html.section_c(
										"Outbox",
										panel_class,
										[
											Html.heading_c("Outbox", "text-xl font-semibold text-zinc-950"),
											Ui.when(
												outbox_empty,
												|| Html.paragraph_c("Outbox is empty", "text-sm text-zinc-600"),
												|| Html.paragraph_s_attrs(rows.map(|value| "Outbox holds ${Notes.outbox_count(value).to_str()} notes"), [Html.class_attr("text-sm text-zinc-900"), Html.test_id("outbox-detail")]),
											),
										],
									),
									Html.section_c(
										"Notes",
										panel_class,
										[
											Html.heading_c("Captured notes", "text-xl font-semibold text-zinc-950"),
											Ui.when(
												notes_empty,
												|| Html.paragraph_c("No notes captured yet", "text-sm text-zinc-600"),
												|| Ui.each_str(visible_rows, |row| row.id, |key, row| render_note(capture, key, row)),
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
