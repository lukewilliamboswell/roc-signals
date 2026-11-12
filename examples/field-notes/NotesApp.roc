import pf.Engine exposing [Elem, Handler, Row, RowRef, Signal]
import pf.Html
import AppStore
import Notes

## Field Notes: an offline-first note capture tool.
##
## Notes are captured while the browser is offline, queued in an outbox, and
## synced one at a time when the connection returns. Local storage is the
## base of truth: the board starts from the notes the boot storage holds and
## writes them back whenever they change.
##
## The page's state is the cells of the app's store (`AppStore`): the board,
## the draft and the "hide synced" filter. Every handler and reaction here
## runs one of the store's decisions, and every panel reads the cells it
## needs where it is drawn.
##
## The rows are one memoised `derive` of the board, so a change that leaves
## them equal does no row work, and typing a draft does not reach them at
## all. They are drawn with `each`: there are at most four, one for each
## sync lane, and what a row shows (its status above all) is derived from
## the whole board, not held in the note.
##
## Each of the four sync lanes is an effect site watching its lane's request
## and generation: a new generation is a new send, and a result settles the
## lane only while its generation is still the latest.
NotesApp := [].{

	## The page over the session's boot data.
	view : Engine.Boot -> Elem(Engine.StoreRoot(_))
	view = |boot| Engine.derive(
		AppStore.cells.board.signal().map(Notes.board_rows),
		|rows| Html.div(
			page_class,
			[
				Html.section(
					"Field Notes",
					"app-header",
					[
						Engine.element("h1", [Engine.class("app-title")], [Engine.text("Field Notes")]),
						Html.p("Capture notes while offline, queue them in an outbox, and sync them one at a time when the connection returns.", "app-subtitle"),
					],
				),
				sync_status(boot.storage_available, rows),
				capture(rows),
				outbox(rows),
				captured(rows),
				sync_lane(0),
				sync_lane(1),
				sync_lane(2),
				sync_lane(3),
				# The browser's connectivity, for as long as the app runs.
				Engine.watch(
					Engine.const({}),
					|_| [OnlineChanges],
					Engine.react(
						|_, res| match res {
							Online(on) => AppStore.connected(on)
							_ => []
						},
					),
				),
				# The notes, written back to local storage whenever they change.
				Engine.watch_changes(AppStore.cells.board.signal().map(|b| Notes.encode_notes(b.notes)), |text| [StorageSet(Notes.notes_key, text)], Engine.ignore({})),
			],
		),
	)

	## The program `main.roc` binds for the browser module and the native spec
	## runner.
	program : Engine.Program
	program = Engine.program_store({ storage_keys: [Notes.notes_key], max_inflight: 32 }, AppStore.start, NotesApp.view)
}

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
stat : { label : Str, value : Signal(ctx, Str), id : Str } -> Elem(ctx)
stat = |{ label, value, id }| Html.div("stat", [Html.p(label, "stat-label"), Html.p_s(value, [Engine.class("stat-value"), Engine.test_id(id)])])

## A checkbox draws no caption of its own, so the visible label is next to
## it.
check_row : Str, Signal(ctx, Bool), Handler(ctx) -> Elem(ctx)
check_row = |label, checked, changed| Html.div("check-row", [Html.checkbox(Engine.const(label), checked, [Engine.class("checkbox")], changed), Engine.text(label)])

## One note, a row of the list. Its handlers name the note by the row's
## key, read when the event fires, and write the board through the store's
## decisions: a row needs nothing handed to it.
note_card : RowRef(ctx, Notes.Row) -> Elem(Row(ctx, Notes.Row))
	where [ctx.store : () -> Engine.Reach(ctx, _)]
note_card = |row| {
	key = row.key()
	named = |prefix| key.map(|k| "${prefix} ${k}")
	status = row.field(|r| r.status)
	act = |decide| Engine.handle_by(key, |id, _| decide(id))
	Engine.element(
		"section",
		[Engine.attr_s("aria-label", named("Note")), Engine.class(note_class), Engine.attr_s("data-status", status.map(Notes.status_code))],
		[
			Html.div(
				"flex flex-wrap items-center justify-between gap-2",
				[
					Html.h2_s(named("Note"), [Engine.class("card-title")]),
					Html.p_s(status.map(Notes.status_title), [Engine.class_s(status.map(status_class)), Engine.test_id_s(key.map(|k| "status-${k}"))]),
				],
			),
			Html.div(
				"field",
				[
					Html.p_s(named("Body"), [Engine.class("field-label")]),
					Html.text_input(
						named("Body"),
						"text",
						row.field(|r| r.body),
						[Engine.class("input"), Engine.attr("placeholder", "Generator hours 128")],
						Engine.handle_by(key, |id, text| AppStore.edited({ id, text })),
					),
				],
			),
			Html.p_s(row.field(|r| r.detail), [Engine.class("hint numeric")]),
			Html.div(
				toolbar_class,
				[
					Html.action_button(named("Queue note"), row.field(|r| r.queue_disabled), [Engine.class("button button-sm")], act(AppStore.queued)),
					Html.action_button(named("Retry note"), row.field(|r| r.retry_disabled), [Engine.class_s(status.map(retry_class))], act(AppStore.retried)),
					Html.button_s(named("Promote note"), [Engine.class("button-ghost button-sm")], act(AppStore.promoted)),
					Html.button_s(named("Delete note"), [Engine.class("button-ghost button-sm")], act(AppStore.deleted)),
				],
			),
		],
	)
}

## Lane `slot`: send its request's token whenever the lane starts a new
## generation; the result settles the lane unless a newer send superseded
## it.
sync_lane : U64 -> Elem(ctx)
	where [ctx.store : () -> Engine.Reach(ctx, _)]
sync_lane = |slot| Engine.watch(
	AppStore.cells.board.signal().map(|b| Notes.issue_at(b, slot)),
	|issue| match issue.request {
		Send(token) => [Http({ method: "POST", url: "/api/notes/sync", headers: [], body: token, timeout_ms: 0 })]
		Idle => []
	},
	Engine.react(
		|issue, res| {
			accepted = match (issue.request, Engine.http_text(res)) {
				(Send(token), Ok(body)) => body == token
				_ => False
			}
			AppStore.answered({ slot, issue, accepted })
		},
	),
)

## The connection, auto-sync and the outbox at a glance, with the two
## switches. `storage_available` is fixed for the session: the browser
## reports it at boot.
sync_status : Bool, Signal(ctx, List(Notes.Row)) -> Elem(ctx)
	where [ctx.store : () -> Engine.Reach(ctx, _)]
sync_status = |storage_available, rows| {
	board = AppStore.cells.board.signal()
	online = board.map(|b| b.online)
	auto = board.map(|b| b.auto)
	Html.section_attrs(
		"Sync status",
		[Engine.class(panel_class), Engine.attr_s("data-network", online.map(|on| if (on) "online" else "offline"))],
		[
			Html.p_s(online.map(Notes.network_text), [Engine.class_s(online.map(network_class)), Engine.test_id("network")]),
			Html.div(
				"stat-grid",
				[
					stat({ label: "Outbox", value: rows.map(|r| Notes.outbox_count(r).to_str()), id: "outbox-count" }),
					stat({ label: "Syncing", value: rows.map(Notes.syncing_text), id: "syncing" }),
					stat({ label: "Failed", value: rows.map(|r| Notes.count_status(r, Failed).to_str()), id: "failed-count" }),
					stat({ label: "Synced", value: rows.map(|r| Notes.count_status(r, Synced).to_str()), id: "synced-count" }),
				],
			),
			Html.div(
				"toolbar justify-between border-t border-zinc-200 pt-3",
				[
					Html.div(
						toolbar_class,
						[
							check_row("Sync automatically", auto, Engine.handle(|checked| AppStore.auto_set(checked == "true"))),
							check_row("Hide synced notes", AppStore.cells.hide_synced.signal(), Engine.handle(|checked| AppStore.synced_hidden(checked == "true"))),
						],
					),
					Html.div(
						toolbar_class,
						[
							Html.p_s(auto.map(Notes.auto_text), [Engine.class_s(auto.map(auto_class)), Engine.test_id("auto-sync")]),
							Html.p_s(rows.map(Notes.capacity_text), [Engine.class("badge badge-neutral numeric"), Engine.test_id("capacity")]),
						],
					),
				],
			),
			Html.p_attrs(Notes.storage_notice(storage_available), [Engine.class("hint"), Engine.test_id("storage-notice")]),
		],
	)
}

## The box a new note is typed in. Saving is one decision over the draft
## as it stands when the button is clicked.
capture : Signal(ctx, List(Notes.Row)) -> Elem(ctx)
	where [ctx.store : () -> Engine.Reach(ctx, _)]
capture = |rows| {
	draft = AppStore.cells.draft.signal()
	Html.section(
		"Capture",
		panel_class,
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
						Engine.handle(AppStore.drafted),
					),
				],
			),
			Html.action_button(
				Engine.const("Save note"),
				draft.map2(rows, |typed, all| Notes.draft_body(typed) == "" or Notes.is_full(all)),
				[Engine.class("button-primary justify-self-start")],
				Engine.handle_by(draft, |typed, _| AppStore.saved(typed)),
			),
		],
	)
}

## How many notes wait in the outbox.
outbox : Signal(ctx, List(Notes.Row)) -> Elem(ctx)
outbox = |rows| Html.section(
	"Outbox",
	panel_class,
	[
		Html.h2("Outbox", "panel-title"),
		Engine.when(
			rows.map(|r| Notes.outbox_count(r) == 0),
			|| Html.p("Outbox is empty", "empty-state"),
			|| Html.p_s(rows.map(Notes.outbox_text), [Engine.class("notice notice-info"), Engine.test_id("outbox-detail")]),
		),
	],
)

## The captured notes, without the synced ones while they are hidden.
captured : Signal(ctx, List(Notes.Row)) -> Elem(ctx)
	where [ctx.store : () -> Engine.Reach(ctx, _)]
captured = |rows| {
	shown = rows.map2(AppStore.cells.hide_synced.signal(), |all, hide| if (hide) all.keep_if(|r| r.status != Synced) else all)
	Html.section(
		"Notes",
		panel_class,
		[
			Html.h2("Captured notes", "panel-title"),
			Engine.when(
				rows.map(|r| r.is_empty()),
				|| Html.p("No notes captured yet. Write one above — it will save even while you are offline.", "empty-state"),
				|| Html.div("grid gap-3", [Engine.each(shown, |r| r.id, note_card)]),
			),
		],
	)
}
