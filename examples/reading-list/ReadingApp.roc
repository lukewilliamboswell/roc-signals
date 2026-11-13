import pf.Engine exposing [Elem, Handler, Row, Signal, State]
import pf.Html
import ReadingList
import Store

## Reading List: the books you want to read, are reading and have finished,
## kept in the browser's IndexedDB through ports, so they are still there
## after a reload and in every tab.
##
## The page's state is the cells of the app's store (`ReadingList`), and
## every handler and reaction here runs one of its decisions. The books are
## a table, and the list is a view of it: the books the chosen shelf
## keeps, newest first, each row woken by a write of its own book alone.
##
## Four effect sites connect the store to the database: one loads the
## books at start, one listens for the database's copy after any tab
## writes, one asks the database to add each book the reader posts, and one
## sends each change's posted commands. Two change-only sites mark shelf
## and book-count changes for browser view transitions; the app owns their CSS.
## An additional site samples the clock before Roc mints a new book.
ReadingApp := [].{

	## The page, and the four effect sites that connect the store to the
	## database.
	view : {} -> Elem(Engine.StoreRoot(_))
	view = |{}| Html.div(
		"app-shell app-shell-narrow",
		[
			Engine.element("style", [], [Engine.text(motion_css)]),
			Html.section(
				"Reading List",
				"app-header",
				[
					Html.h1("Reading List", "app-title"),
					Html.p("Your books stay in this browser: reload the page, or open it in a second tab, and they are still here. A change in one tab shows in the others.", "app-subtitle"),
				],
			),
			add_form({}),
			shelves({}),
			# The database's books, once, at start. The answer counts only
			# while the copy is still loading, which the reaction reads when
			# it arrives.
			Engine.watch(
				Engine.const({}),
				|_| [Store.load.request({})],
				Engine.react_by(ReadingList.cells.copy.signal(), |copy, _, res| ReadingList.loaded(copy, Store.load.result(res))),
			),
			# The database's books again after any tab writes, for as long
			# as the app runs.
			Engine.watch(
				Engine.const({}),
				|_| [Store.stored.subscribe({})],
				Engine.react(|_, res| ReadingList.restocked(Store.stored.message(res))),
			),
			# Read the time a task after submission. Refusal uses the last
			# sampled clock; each answer mints its own complete book in Roc.
			Engine.on_post(
				ReadingList.cells.stamping.signal(),
				|_| [Timer(0)],
				Engine.react_by(
					{ state: ReadingList.cells.id_state.signal(), clock: ReadingList.cells.clock.signal() }.Signal,
					|at, form, result| ReadingList.stamped({ at, form, result }),
				),
			),
			# A new book, ready to store. `on_post` never stops
			# an earlier add for a later one: each answer arrives.
			Engine.on_post(ReadingList.cells.adding.signal(), |asked| [Store.add.request(asked)], Engine.react(|asked, res| ReadingList.added(asked, Store.add.result(res)))),
			# Every change's commands, sent in the turn of the click that
			# made them.
			Engine.on_post(ReadingList.cells.writes.signal(), ReadingList.requests, Engine.ignore({})),
		],
	)

	## The program `main.roc` binds for the browser module and the native
	## spec runner. The page passes `ports.mjs`'s handlers when it mounts
	## it.
	program : Engine.Program
	program =
		Engine.program_store({ storage_keys: [], max_inflight: 32 }, ReadingList.start, |_| ReadingApp.view({}))
			.with_ports(Store.registrations)
}

## A labelled text box of the form.
field : { label : Str, value : Signal(ctx, Str), placeholder : Str, typed : Handler(ctx) } -> Elem(ctx)
field = |{ label, value, placeholder, typed }|
	Html.div(
		"field",
		[
			Html.p(label, "field-label"),
			Html.text_input(Engine.const(label), "text", value, [Engine.class("input"), Engine.attr("placeholder", placeholder)], typed),
		],
	)

## The form that adds a book. Submitting it is one decision over what the
## form and the copy hold at that moment.
add_form : {} -> Elem(ctx)
	where [ctx.store : () -> Engine.Reach(ctx, _)]
add_form = |{}| {
	form = ReadingList.cells.form.signal()
	Html.form(
		"Add a book",
		[Engine.class("panel grid gap-3 p-4"), Html.on_submit(Engine.handle_by(ReadingList.asking({}), |at, _| ReadingList.submitted(at)))],
		[
			Html.h2("Add a book", "panel-title"),
			Html.div(
				"grid gap-3 sm:grid-cols-2",
				[
					field({ label: "Title", value: form.map(|f| f.title), placeholder: "Piranesi", typed: Engine.handle(ReadingList.title_typed) }),
					field({ label: "Author", value: form.map(|f| f.author), placeholder: "Susanna Clarke", typed: Engine.handle(ReadingList.author_typed) }),
				],
			),
			Engine.element(
				"button",
				[Engine.attr("type", "submit"), Engine.class("button-primary justify-self-start"), Html.disabled(ReadingList.asking({}).map(|at| !ReadingList.can_add(at)))],
				[Engine.text("Add book")],
			),
		],
	)
}

## A button that shows one shelf, with its count; pressed while shown.
shelf_button : Signal(ctx, ReadingList.Tally), { label : Str, showing : ReadingList.Showing } -> Elem(ctx)
	where [ctx.store : () -> Engine.Reach(ctx, _)]
shelf_button = |counted, { label, showing }|
	Html.action_button(
		counted.map(|c| "${label} (${ReadingList.count(c, showing).to_str()})"),
		Engine.const(False),
		[Engine.class("button button-sm"), Html.aria_label(label), Html.flag("aria-pressed", ReadingList.cells.showing.signal().map(|now| now == showing))],
		Engine.does(ReadingList.shown(showing)),
	)

## One book, a row of the list: its title and author, its shelf, and what
## can be done with it. The row reads its own book, so a move to another
## shelf re-evaluates this row and no other.
book : Signal(Row(ctx, Str), Str), State(Row(ctx, Str), Store.Book) -> Elem(Row(ctx, Str))
	where [ctx.store : () -> Engine.Reach(ctx, _)]
book = |id, row| {
	held = row.signal()
	title = held.map(|b| b.title)
	action = held.map(ReadingList.next_action)
	Engine.element(
		"li",
		[
			Engine.class("book card flex flex-wrap items-center justify-between gap-3 p-3"),
			Engine.attr_s("aria-label", title),
			# App keys name snapshots; the prefix also supports older UUID keys.
			Engine.attr_s("style", id.map(|key| "view-transition-name: book-${key}")),
		],
		[
			Html.div(
				"grid",
				[
					Engine.element("strong", [], [Engine.text_s(title)]),
					Html.span_s(held.map(|b| if (b.author.is_empty()) "Unknown author" else b.author), [Engine.class("muted")]),
				],
			),
			Html.div(
				"toolbar",
				[
					Html.span_s(held.map(|b| ReadingList.shelf_name(b.shelf)), [Engine.class("badge badge-neutral")]),
					Engine.element(
						"button",
						[Engine.attr("type", "button"), Engine.class("button button-sm"), Engine.attr_s("aria-label", action.map(|a| a.name)), Engine.on_click(Engine.handle_by(held, |b, _| ReadingList.advanced(b)))],
						[Engine.text_s(action.map(|a| a.label))],
					),
					Engine.element(
						"button",
						[Engine.attr("type", "button"), Engine.class("button-ghost button-sm"), Engine.attr_s("aria-label", title.map(|t| "Remove ${t}")), Engine.on_click(Engine.handle_by(id, |key, _| ReadingList.removed(key)))],
						[Engine.text("Remove")],
					),
				],
			),
		],
	)
}

## The shelves: the buttons that choose one, the status line, the list and
## what clears it. The count of each shelf is one `derive` of the table,
## read by every button and by the status line.
shelves : {} -> Elem(ctx)
	where [ctx.store : () -> Engine.Reach(ctx, _)]
shelves = |{}| {
	books = ReadingList.cells.books
	Engine.derive(
		books.signal().map(ReadingList.tally),
		|counted| {
			showing = ReadingList.cells.showing.signal()
			Html.section(
				"Shelves",
				"panel grid gap-3 p-4",
				[
					# These values choose the animation, including changes from a port result.
					# Neither marks mount; typing touches neither value.
					Engine.watch_changes(showing, |_| [ViewTransition(["shelf"])], Engine.ignore({})),
					Engine.watch_changes(counted, |_| [ViewTransition(["books"])], Engine.ignore({})),
					Html.div(
						"toolbar",
						[
							shelf_button(counted, { label: "All", showing: Everything }),
							shelf_button(counted, { label: "Want to read", showing: Only(WantToRead) }),
							shelf_button(counted, { label: "Reading", showing: Only(Reading) }),
							shelf_button(counted, { label: "Finished", showing: Only(Finished) }),
						],
					),
					Html.p_s(
						{ copy: ReadingList.cells.copy.signal(), tally: counted, showing }.Signal.map(ReadingList.status),
						[Engine.class("muted"), Engine.test_id("status")],
					),
					Engine.element(
						"ul",
						[Engine.class("grid gap-2"), Html.aria_label("Books")],
						[
							# A reading list is short: every book the shelf
							# keeps is drawn.
							Engine.table_view(
								books,
								{ query: showing, plan: ReadingList.plan, window: Engine.const(Engine.every_row) },
								book,
							),
						],
					),
					Html.action_button(
						Engine.const("Remove finished books"),
						counted.map(|c| ReadingList.count(c, Only(Finished)) == 0),
						[Engine.class("button-ghost button-sm justify-self-start")],
						Engine.handle_by(books.signal().map(ReadingList.finished_ids), |ids, _| ReadingList.finished_removed(ids)),
					),
					Html.p_s(ReadingList.cells.note.signal(), [Engine.class("hint"), Engine.test_id("note")]),
				],
			)
		},
	)
}

## The app carries one stylesheet in its DOM, so a standalone mount and the
## documentation site use the same motion without app-specific runtime code.
## Disposed books survive only as browser snapshots, never as retained nodes.
## Only books are captured: the form and shelf controls stay interactive.
## Controls inside a captured book wait until its animation finishes.
motion_css : Str
motion_css =
	\\ :root { view-transition-name: none; }
	\\ .book { view-transition-class: book; }
	\\ ::view-transition { pointer-events: none; }
	\\ ::view-transition-group(.book) {
	\\   animation-duration: 220ms;
	\\   animation-timing-function: cubic-bezier(0.2, 0.8, 0.2, 1);
	\\ }
	\\ ::view-transition-old(.book):only-child {
	\\   animation: reading-book-leave 160ms ease-in both;
	\\ }
	\\ ::view-transition-new(.book):only-child {
	\\   animation: reading-book-arrive 220ms ease-out both;
	\\ }
	\\ :root:active-view-transition-type(shelf)::view-transition-group(.book) {
	\\   animation: none;
	\\ }
	\\ :root:active-view-transition-type(shelf)::view-transition-old(.book) {
	\\   animation: reading-fade-out 120ms ease-out both;
	\\ }
	\\ :root:active-view-transition-type(shelf)::view-transition-new(.book) {
	\\   animation: reading-fade-in 160ms ease-out both;
	\\ }
	\\ @keyframes reading-book-arrive {
	\\   from { opacity: 0; translate: 0 0.5rem; }
	\\   to { opacity: 1; translate: 0 0; }
	\\ }
	\\ @keyframes reading-book-leave {
	\\   from { opacity: 1; translate: 0 0; }
	\\   to { opacity: 0; translate: 0 -0.35rem; }
	\\ }
	\\ @keyframes reading-fade-in { from { opacity: 0; } to { opacity: 1; } }
	\\ @keyframes reading-fade-out { from { opacity: 1; } to { opacity: 0; } }
	\\ @supports not (view-transition-name: none) {
	\\   .book { transition: opacity 180ms ease-out, translate 180ms ease-out; }
	\\   @starting-style { .book { opacity: 0; translate: 0 0.5rem; } }
	\\ }
	\\ @media (prefers-reduced-motion: reduce) {
	\\   ::view-transition-group(*), ::view-transition-old(*), ::view-transition-new(*) {
	\\     animation: none !important;
	\\   }
	\\   .book { transition: none; }
	\\   @starting-style { .book { opacity: 1; translate: none; } }
	\\ }
