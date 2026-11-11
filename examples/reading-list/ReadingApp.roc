import pf.Engine exposing [Elem, In, Root, Row, RowRef, State, Val]
import pf.Html
import ReadingList
import Store

## Reading List: the books you want to read, are reading and have finished,
## kept in the browser's IndexedDB through ports, so they are still there
## after a reload and in every tab.
##
## The view is one state, `ReadingList.S`. Four effect sites connect it to
## the store: one loads the books at start, one listens for the store's copy
## after any tab writes, one asks the store to add each book the user
## posts, and one sends each change's posted writes as commands. Everything
## else is ordinary view code.
ReadingApp := [].{
	Ctx : In(Root, ReadingList.S)

	view : State(Ctx, ReadingList.S) -> Elem(Ctx)
	view = |st| {
		v = st.val()
		Html.div(
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
				Html.form(
					"Add a book",
					[Engine.class("panel grid gap-3 p-4"), Html.on_submit(st.update(ReadingList.submit))],
					[
						Html.h2("Add a book", "panel-title"),
						Html.div(
							"grid gap-3 sm:grid-cols-2",
							[
								ReadingApp.field("Title", v.map(|s| s.title), "Piranesi", st.set_value(|s, text| { ..s, title: text })),
								ReadingApp.field("Author", v.map(|s| s.author), "Susanna Clarke", st.set_value(|s, text| { ..s, author: text })),
							],
						),
						Engine.element(
							"button",
							[Engine.attr("type", "submit"), Engine.class("button-primary justify-self-start"), Html.disabled(v.map(|s| !ReadingList.can_add(s)))],
							[Engine.text("Add book")],
						),
					],
				),
				Html.section(
					"Shelves",
					"panel grid gap-3 p-4",
					[
						Html.div(
							"toolbar",
							[
								ReadingApp.shelf_button(st, "All", Everything),
								ReadingApp.shelf_button(st, "Want to read", Only(WantToRead)),
								ReadingApp.shelf_button(st, "Reading", Only(Reading)),
								ReadingApp.shelf_button(st, "Finished", Only(Finished)),
							],
						),
						Html.p_v(v.map(ReadingList.status), [Engine.class("muted"), Engine.test_id("status")]),
						Engine.element("ul", [Engine.class("grid gap-2"), Html.aria_label("Books")], [Engine.each(v.map(ReadingList.shown), |b| b.id, |row| ReadingApp.book(st, row))]),
						Html.action_button(
							Engine.const("Remove finished books"),
							v.map(|s| ReadingList.count(s, Only(Finished)) == 0),
							[Engine.class("button-ghost button-sm justify-self-start")],
							st.update(ReadingList.clear_finished),
						),
						Html.p_v(v.map(|s| s.note), [Engine.class("hint"), Engine.test_id("note")]),
					],
				),
				# The store's books, once, at start.
				Engine.watch(
					Engine.const({}),
					|_| [Store.load.request({})],
					st.on_result(|s, _, res| ReadingList.loaded(s, Store.load.result(res))),
				),
				# The store's books again after any tab writes, for as long as
				# the app runs.
				Engine.watch(
					Engine.const({}),
					|_| [Store.stored.subscribe({})],
					st.on_result(|s, _, res| ReadingList.restocked(s, Store.stored.message(res))),
				),
				# A new book, which the store numbers. `on_post` never stops
				# an earlier add for a later one: each answer arrives.
				Engine.on_post(v.map(|s| s.adding), |book| [Store.add.request(book)], st.on_result(|s, book, res| ReadingList.added(s, book, Store.add.result(res)))),
				# Every change's writes, sent as commands in the turn of the
				# click that made them.
				Engine.on_post(v.map(|s| s.writes), ReadingList.requests, Engine.ignore({})),
			],
		)
	}

	## A labelled text box of the form.
	field : Str, Val(Ctx, Str), Str, Engine.Handler(Ctx) -> Elem(Ctx)
	field = |label, value, placeholder, handler|
		Html.div(
			"field",
			[
				Html.p(label, "field-label"),
				Html.text_input(Engine.const(label), "text", value, [Engine.class("input"), Engine.attr("placeholder", placeholder)], handler),
			],
		)

	## A button that shows one shelf, with its count; pressed while shown.
	shelf_button : State(Ctx, ReadingList.S), Str, ReadingList.Showing -> Elem(Ctx)
	shelf_button = |st, label, showing| {
		v = st.val()
		Html.action_button(
			v.map(|s| "${label} (${ReadingList.count(s, showing).to_str()})"),
			Engine.const(False),
			[Engine.class("button button-sm"), Html.aria_label(label), Html.flag("aria-pressed", v.map(|s| s.showing == showing))],
			st.update(|s| { ..s, showing }),
		)
	}

	## One book: its title and author, its shelf, and what can be done
	## with it.
	book : State(Ctx, ReadingList.S), RowRef(Ctx, Store.Book) -> Elem(Row(Ctx, Store.Book))
	book = |st0, row| {
		st = st0.lift_row()
		id = row.key()
		title = row.field(|b| b.title)
		action = row.field(ReadingList.next_action)
		Engine.element(
			"li",
			[Engine.class("card flex flex-wrap items-center justify-between gap-3 p-3"), Engine.attr_v("aria-label", title)],
			[
				Html.div(
					"grid",
					[
						Engine.element("strong", [], [Engine.text_v(title)]),
						Html.span_v(row.field(|b| if (b.author.is_empty()) "Unknown author" else b.author), [Engine.class("muted")]),
					],
				),
				Html.div(
					"toolbar",
					[
						Html.span_v(row.field(|b| ReadingList.shelf_name(b.shelf)), [Engine.class("badge badge-neutral")]),
						Engine.element(
							"button",
							[Engine.attr("type", "button"), Engine.class("button button-sm"), Engine.attr_v("aria-label", action.map(|a| a.name)), Engine.on_click(st.update_by(id, ReadingList.advance))],
							[Engine.text_v(action.map(|a| a.label))],
						),
						Engine.element(
							"button",
							[Engine.attr("type", "button"), Engine.class("button-ghost button-sm"), Engine.attr_v("aria-label", title.map(|t| "Remove ${t}")), Engine.on_click(st.update_by(id, ReadingList.delete))],
							[Engine.text("Remove")],
						),
					],
				),
			],
		)
	}

	## The program `main.roc` binds for the browser module and the native
	## spec runner, and `main-fuzz.roc` drives as a roc-fuzz target. The
	## page passes `ports.mjs`'s handlers when it mounts it.
	program : Engine.Program
	program =
		Engine.program(|| Engine.state(ReadingList.initial, ReadingApp.view))
			.with_ports(Store.registrations)
}
