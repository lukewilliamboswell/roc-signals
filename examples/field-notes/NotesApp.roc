import pf.Engine exposing [Elem, In, Root, Row, RowRef, State, Val]
import pf.Html
import Notes

## Field Notes on the Roc-owned engine, ported from the previous engine: an
## offline-first note capture tool.
##
## Notes are captured while the browser is offline, queued in an outbox, and
## synced one at a time when the connection returns. Local storage is the
## base of truth: the board starts from the notes the boot storage holds and
## writes them back whenever they change.
##
## The board is one state: saving a draft, a sync result and a connectivity
## change each rewrite the notes and the lanes' requests together. The rows
## are one memoised `derive` over it, so typing a draft does no row work. The
## "hide synced" toggle is its own state. Each of the four sync lanes is an
## effect site watching its lane's request and generation: a new generation
## is a new send, and a result settles the lane only while its generation is
## still the latest.
NotesApp := [].{
	C1 : In(Root, Notes.Board)
	C2 : In(C1, Bool)
	C3 : In(C2, List(Notes.Row))

	page_class = "app-shell"

	panel_class = "panel grid gap-4 p-4"

	note_class = "card gap-3 p-4"

	toolbar_class = "flex flex-wrap items-center gap-2"

	## Online/offline is this app's central condition, so it is a banner rather
	## than a line of status text. Both the tone and the sentence come off the
	## same `online` field.
	network_class : Bool -> Str
	network_class = |online| if (online) "notice notice-ok" else "notice notice-warn"

	auto_class : Bool -> Str
	auto_class = |auto| if (auto) "badge badge-ok" else "badge badge-warn"

	## Badge tone per note, derived from the same `Notes.Status` tag that
	## produces the badge's caption, so the colour can never disagree with the
	## word.
	status_class : Notes.Status -> Str
	status_class = |status|
		match status {
			Draft => "badge badge-neutral"
			Queued => "badge badge-warn"
			Syncing => "badge badge-warn"
			Synced => "badge badge-ok"
			Failed => "badge badge-danger"
		}

	## A failed note has to offer its retry where the failure is shown, so the
	## retry control is loud exactly while it is the thing to do.
	retry_class : Notes.Status -> Str
	retry_class = |status|
		match status {
			Failed => "button-danger button-sm"
			_ => "button button-sm"
		}

	## One metric tile. A count is a label and a number, not a sentence.
	stat : Str, Val(ctx, Str), Str -> Elem(ctx)
	stat = |label, value, id| Html.div("stat", [Html.p(label, "stat-label"), Html.p_v(value, [Engine.class("stat-value"), Engine.test_id(id)])])

	## A checkbox draws no caption of its own, so the visible label is next to
	## it.
	check_row : Str, Val(ctx, Bool), Engine.Handler(ctx) -> Elem(ctx)
	check_row = |label, checked, h| Html.div("check-row", [Html.checkbox(Engine.const(label), checked, [Engine.class("checkbox")], h), Engine.text(label)])

	render_note : State(C3, Notes.Board), RowRef(C3, Notes.Row) -> Elem(Row(C3, Notes.Row))
	render_note = |board0, row| {
		board = board0.lift_row()
		key = row.key()
		named = |prefix| key.map(|k| "${prefix} ${k}")
		status = row.field(|r| r.status)
		Engine.element(
			"section",
			[Engine.attr_v("aria-label", named("Note")), Engine.class(NotesApp.note_class), Engine.attr_v("data-status", status.map(Notes.status_code))],
			[
				Html.div(
					"flex flex-wrap items-center justify-between gap-2",
					[
						Html.h2_v(named("Note"), [Engine.class("card-title")]),
						Html.p_v(status.map(Notes.status_title), [Engine.class_v(status.map(NotesApp.status_class)), Engine.test_id_v(key.map(|k| "status-${k}"))]),
					],
				),
				Html.div(
					"field",
					[
						Html.p_v(named("Body"), [Engine.class("field-label")]),
						Html.text_input(
							named("Body"),
							"text",
							row.field(|r| r.body),
							[Engine.class("input"), Engine.attr("placeholder", "Generator hours 128")],
							board.set_value_by(key, |b, k, text| Notes.edit_note(b, k, Notes.sanitize(text))),
						),
					],
				),
				Html.p_v(row.field(|r| r.detail), [Engine.class("hint numeric")]),
				Html.div(
					NotesApp.toolbar_class,
					[
						Html.action_button(named("Queue note"), row.field(|r| r.queue_disabled), [Engine.class("button button-sm")], board.update_by(key, Notes.queue_note)),
						Html.action_button(named("Retry note"), row.field(|r| r.retry_disabled), [Engine.class_v(status.map(NotesApp.retry_class))], board.update_by(key, Notes.retry_note)),
						Html.button_v(named("Promote note"), [Engine.class("button-ghost button-sm")], board.update_by(key, Notes.promote_note)),
						Html.button_v(named("Delete note"), [Engine.class("button-ghost button-sm")], board.update_by(key, Notes.delete_note)),
					],
				),
			],
		)
	}

	## Lane `slot`: send its request's token whenever the lane starts a new
	## generation; the result settles the lane unless a newer send superseded
	## it.
	sync_lane : State(C3, Notes.Board), U64 -> Elem(C3)
	sync_lane = |board, slot| Engine.watch(
		board.val().map(|b| Notes.issue_at(b, slot)),
		|issue| match issue.request {
			Send(token) => [Http({ method: "POST", url: "/api/notes/sync", headers: [], body: token, timeout_ms: 0 })]
			Idle => []
		},
		board.on_result(
			|b, issue, res| {
				ok = match (issue.request, Engine.http_text(res)) {
					(Send(token), Ok(body)) => body == token
					_ => False
				}
				Notes.settle_send(b, slot, issue, ok)
			},
		),
	)

	page : Bool, State(C3, Notes.Board), State(C3, Bool), Val(C3, List(Notes.Row)) -> Elem(C3)
	page = |storage_available, board, hide_synced, rows| {
		bv = board.val()
		online = bv.map(|b| b.online)
		auto = bv.map(|b| b.auto)
		draft = bv.map(|b| b.draft)
		visible_rows = rows.map2(hide_synced.val(), |all, hide| if (hide) all.keep_if(|r| r.status != Synced) else all)
		save_disabled = draft.map2(rows, |d, all| Notes.sanitize(d).trim() == "" or Notes.is_full(all))
		Html.div(
			NotesApp.page_class,
			[
				Html.section(
					"Field Notes",
					"app-header",
					[
						Engine.element("h1", [Engine.class("app-title")], [Engine.text("Field Notes")]),
						Html.p("Capture notes while offline, queue them in an outbox, and sync them one at a time when the connection returns.", "app-subtitle"),
					],
				),
				Html.section_attrs(
					"Sync status",
					[Engine.class(NotesApp.panel_class), Engine.attr_v("data-network", online.map(|on| if (on) "online" else "offline"))],
					[
						Html.p_v(online.map(Notes.network_text), [Engine.class_v(online.map(NotesApp.network_class)), Engine.test_id("network")]),
						Html.div(
							"stat-grid",
							[
								NotesApp.stat("Outbox", rows.map(|r| Notes.outbox_count(r).to_str()), "outbox-count"),
								NotesApp.stat("Syncing", rows.map(Notes.syncing_text), "syncing"),
								NotesApp.stat("Failed", rows.map(|r| Notes.count_status(r, Failed).to_str()), "failed-count"),
								NotesApp.stat("Synced", rows.map(|r| Notes.count_status(r, Synced).to_str()), "synced-count"),
							],
						),
						Html.div(
							"toolbar justify-between border-t border-zinc-200 pt-3",
							[
								Html.div(
									NotesApp.toolbar_class,
									[
										NotesApp.check_row("Sync automatically", auto, board.set_value(|b, checked| Notes.set_auto(b, checked == "true"))),
										NotesApp.check_row("Hide synced notes", hide_synced.val(), hide_synced.set_value(|_, checked| checked == "true")),
									],
								),
								Html.div(
									NotesApp.toolbar_class,
									[
										Html.p_v(auto.map(Notes.auto_text), [Engine.class_v(auto.map(NotesApp.auto_class)), Engine.test_id("auto-sync")]),
										Html.p_v(rows.map(Notes.capacity_text), [Engine.class("badge badge-neutral numeric"), Engine.test_id("capacity")]),
									],
								),
							],
						),
						Html.p_attrs(Notes.storage_notice(storage_available), [Engine.class("hint"), Engine.test_id("storage-notice")]),
					],
				),
				Html.section(
					"Capture",
					NotesApp.panel_class,
					[
						Html.h2("New note", "panel-title"),
						Html.div(
							"field",
							[
								Html.p("Note body", "field-label"),
								Html.textarea(
									Engine.const("Note body"),
									draft,
									[Engine.class("input textarea"), Engine.attr("placeholder", "Pump pressure 4.2 bar at the west wellhead")],
									board.set_value(|b, text| { ..b, draft: text }),
								),
							],
						),
						Html.action_button(Engine.const("Save note"), save_disabled, [Engine.class("button-primary justify-self-start")], board.update(Notes.save_note)),
					],
				),
				Html.section(
					"Outbox",
					NotesApp.panel_class,
					[
						Html.h2("Outbox", "panel-title"),
						Engine.when(
							rows.map(|r| Notes.outbox_count(r) == 0),
							|| Html.p("Outbox is empty", "empty-state"),
							|| Html.p_v(rows.map(Notes.outbox_text), [Engine.class("notice notice-info"), Engine.test_id("outbox-detail")]),
						),
					],
				),
				Html.section(
					"Notes",
					NotesApp.panel_class,
					[
						Html.h2("Captured notes", "panel-title"),
						Engine.when(
							rows.map(|r| r.is_empty()),
							|| Html.p("No notes captured yet. Write one above — it will save even while you are offline.", "empty-state"),
							|| Html.div("grid gap-3", [Engine.each(visible_rows, |r| r.id, |row| NotesApp.render_note(board, row))]),
						),
					],
				),
				NotesApp.sync_lane(board, 0),
				NotesApp.sync_lane(board, 1),
				NotesApp.sync_lane(board, 2),
				NotesApp.sync_lane(board, 3),
				Engine.watch(
					Engine.const({}),
					|_| [OnlineChanges],
					board.on_result(
						|b, _, r| match r {
							Online(on) => Notes.set_online(b, on)
							_ => b
						},
					),
				),
				Engine.on_change(bv.map(|b| Notes.encode_notes(b.notes)), |text| [StorageSet(Notes.notes_key, text)], Engine.ignore({})),
			],
		)
	}

	## The program `main.roc` binds for the browser module and the native spec
	## runner, and `main-fuzz.roc` drives as a roc-fuzz target.
	program : Engine.Program
	program = Engine.program_boot({ storage_keys: [Notes.notes_key], max_inflight: 32 }, NotesApp.main)

	main : Engine.Boot -> Elem(Root)
	main = |boot| NotesApp.main_with(Notes.initial(Notes.stored_notes(boot.storage), boot.online), boot.storage_available)

	## The page over a board at mount, and whether local storage is available
	## (fixed for the session: the browser reports it at boot).
	main_with : Notes.Board, Bool -> Elem(Root)
	main_with = |board0, storage_available| Engine.state(
		board0,
		|board| Engine.state(
			False,
			|hide| {
				b = board.lift()
				Engine.derive(b.val().map(Notes.board_rows), |rows| NotesApp.page(storage_available, b.lift(), hide.lift(), rows))
			},
		),
	)
}
