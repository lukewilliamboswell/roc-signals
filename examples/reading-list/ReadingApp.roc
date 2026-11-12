import pf.Engine exposing [Elem, Handler, Row, State, Val]
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
## sends each change's posted commands. Everything else is ordinary view
## code.
ReadingApp := [].{

	## The page, and the four effect sites that connect the store to the
	## database.
	view : {} -> Elem(Engine.StoreRoot(_))
	view = |{}| Html.div(
		"app-shell app-shell-narrow",
		[
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
				Engine.react_by(ReadingList.h.copy.val(), |copy, _, res| ReadingList.loaded(copy, Store.load.result(res))),
			),
			# The database's books again after any tab writes, for as long
			# as the app runs.
			Engine.watch(
				Engine.const({}),
				|_| [Store.stored.subscribe({})],
				Engine.react(|_, res| ReadingList.restocked(Store.stored.message(res))),
			),
			# A new book, which the database numbers. `on_post` never stops
			# an earlier add for a later one: each answer arrives.
			Engine.on_post(ReadingList.h.adding.val(), |asked| [Store.add.request(asked)], Engine.react(|asked, res| ReadingList.added(asked, Store.add.result(res)))),
			# Every change's commands, sent in the turn of the click that
			# made them.
			Engine.on_post(ReadingList.h.writes.val(), ReadingList.requests, Engine.ignore({})),
		],
	)

	## The program `main.roc` binds for the browser module and the native
	## spec runner. The page passes `ports.mjs`'s handlers when it mounts
	## it.
	program : Engine.Program
	program =
		Engine.program_store({ storage_keys: [], max_inflight: 32 }, |_| ReadingList.store, |_| ReadingApp.view({}))
			.with_ports(Store.registrations)
}

## A labelled text box of the form.
field : { label : Str, value : Val(ctx, Str), placeholder : Str, typed : Handler(ctx) } -> Elem(ctx)
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
	form = ReadingList.h.form.val()
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
shelf_button : Val(ctx, ReadingList.Tally), { label : Str, showing : ReadingList.Showing } -> Elem(ctx)
	where [ctx.store : () -> Engine.Reach(ctx, _)]
shelf_button = |counted, { label, showing }|
	Html.action_button(
		counted.map(|c| "${label} (${ReadingList.count(c, showing).to_str()})"),
		Engine.const(False),
		[Engine.class("button button-sm"), Html.aria_label(label), Html.flag("aria-pressed", ReadingList.h.showing.val().map(|now| now == showing))],
		Engine.does(ReadingList.shown(showing)),
	)

## One book, a row of the list: its title and author, its shelf, and what
## can be done with it. The row reads its own book, so a move to another
## shelf re-evaluates this row and no other.
book : Val(Row(ctx, Str), Str), State(Row(ctx, Str), Store.Book) -> Elem(Row(ctx, Str))
	where [ctx.store : () -> Engine.Reach(ctx, _)]
book = |id, row| {
	held = row.val()
	title = held.map(|b| b.title)
	action = held.map(ReadingList.next_action)
	Engine.element(
		"li",
		[Engine.class("card flex flex-wrap items-center justify-between gap-3 p-3"), Engine.attr_v("aria-label", title)],
		[
			Html.div(
				"grid",
				[
					Engine.element("strong", [], [Engine.text_v(title)]),
					Html.span_v(held.map(|b| if (b.author.is_empty()) "Unknown author" else b.author), [Engine.class("muted")]),
				],
			),
			Html.div(
				"toolbar",
				[
					Html.span_v(held.map(|b| ReadingList.shelf_name(b.shelf)), [Engine.class("badge badge-neutral")]),
					Engine.element(
						"button",
						[Engine.attr("type", "button"), Engine.class("button button-sm"), Engine.attr_v("aria-label", action.map(|a| a.name)), Engine.on_click(Engine.handle_by(held, |b, _| ReadingList.advanced(b)))],
						[Engine.text_v(action.map(|a| a.label))],
					),
					Engine.element(
						"button",
						[Engine.attr("type", "button"), Engine.class("button-ghost button-sm"), Engine.attr_v("aria-label", title.map(|t| "Remove ${t}")), Engine.on_click(Engine.handle_by(id, |key, _| ReadingList.removed(key)))],
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
	books = ReadingList.h.books
	showing = ReadingList.h.showing.val()
	Engine.derive(
		books.val().map(ReadingList.tally),
		|counted| {
			Html.section(
				"Shelves",
				"panel grid gap-3 p-4",
				[
					Html.div(
						"toolbar",
						[
							shelf_button(counted, { label: "All", showing: Everything }),
							shelf_button(counted, { label: "Want to read", showing: Only(WantToRead) }),
							shelf_button(counted, { label: "Reading", showing: Only(Reading) }),
							shelf_button(counted, { label: "Finished", showing: Only(Finished) }),
						],
					),
					Html.p_v(
						{ copy: ReadingList.h.copy.val(), tally: counted, showing }.Val.map(ReadingList.status),
						[Engine.class("muted"), Engine.test_id("status")],
					),
					Engine.element(
						"ul",
						[Engine.class("grid gap-2"), Html.aria_label("Books")],
						[
							# A reading list is short: every book the shelf
							# keeps is drawn.
							Engine.each_view(
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
						Engine.handle_by(books.val().map(ReadingList.finished_ids), |ids, _| ReadingList.finished_removed(ids)),
					),
					Html.p_v(ReadingList.h.note.val(), [Engine.class("hint"), Engine.test_id("note")]),
				],
			)
		},
	)
}
