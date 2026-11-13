app [main] { pf: platform "../../platform/main.roc" }

import pf.Engine exposing [Elem, In, Root, Row, RowRef, Signal, State]
import pf.Html

main : Engine.Program
main = Engine.program(|| Engine.state(initial, page))

# region model
Tab : [Inbox, Archive]

Message : { id : Str, subject : Str, starred : Bool }

Model : { tab : Tab, messages : List(Message), selected : Str }

Ctx : In(Root, Model)

initial : Model
initial = { tab: Inbox, messages: [{ id: "m1", subject: "Welcome", starred: False }, { id: "m2", subject: "Invoice", starred: True }], selected: "" }

# endregion model

# region when
## `when` builds only the selected branch, and rebuilds it when the
## condition flips. State inside the departing branch is disposed.
empty_note : Signal(Ctx, List(Message)) -> Elem(Ctx)
empty_note = |messages|
	Engine.when(
		messages.map(|l| l.is_empty()),
		|| Html.p("No messages.", "empty"),
		|| Engine.text(""),
	)

# endregion when

# region switch
## `switch` lists every case it can select, so it knows everything its
## branches read. A value outside the list is a contract error.
tabs : State(Ctx, Model) -> Elem(Ctx)
tabs = |model|
	Engine.switch(
		model.signal().map(|m| m.tab),
		[Inbox, Archive],
		|tab|
			match tab {
				Inbox => Html.h2("Inbox", "tab-title")
				Archive => Html.h2("Archive", "tab-title")
			},
	)

# endregion switch

# region each
## Rows are keyed by `id`. A surviving key keeps its DOM nodes and its row
## state when the list is reordered; a duplicate key is a contract error.
inbox : State(Ctx, Model) -> Elem(Ctx)
inbox = |model| {
	messages = model.signal().map(|m| m.messages)
	selected = Engine.keyed(model.signal().map(|m| m.selected), "selected", "")
	Html.ul(
		[],
		[
			Engine.each(
				messages,
				|m| m.id,
				|row| message_row(model, row, row.select(selected)),
			),
		],
	)
}

# endregion each

# region row
Line : Row(Ctx, Message)

## The template runs once for the whole list. `row.field` reads the current
## row's item; `row.select` is "selected" for exactly one row, so changing the
## selection re-evaluates two rows, not all of them.
message_row : State(Ctx, Model), RowRef(Ctx, Message), Signal(Line, Str) -> Elem(Line)
message_row = |model0, row, is_selected| {
	model = model0.lift_row()
	id = row.key()
	Html.li(
		[Engine.class_s(is_selected)],
		[
			Html.button_s(row.field(|m| m.subject), [], model.update_by(id, |m, k| { ..m, selected: k })),
			Html.checkbox(row.field(|m| "Star ${m.subject}"), row.field(|m| m.starred), [], model.set_value_by(id, star)),
		],
	)
}

star : Model, Str, Str -> Model
star = |m, id, flag| { ..m, messages: m.messages.map(|msg| if (msg.id == id) { ..msg, starred: flag == "true" } else msg) }

# endregion row

# region row-state
## State declared inside a row template is per row: each message has its own
## "expanded" flag, kept while its key survives and dropped with its row.
expandable : RowRef(Ctx, Message) -> Elem(Line)
expandable = |row|
	Engine.state(
		False,
		|open| {
			subject = row.field(|m| m.subject).lift()
			Html.div(
				"message",
				[
					Html.button_s(open.signal().map(|o| if (o) "Hide" else "Show"), [], open.update(|o| !o)),
					Engine.when(open.signal(), || Html.p_s(subject, []), || Engine.text("")),
				],
			)
		},
	)

# endregion row-state

# region over-a-state
## The smallest component is a function over what it is handed: here a
## `State` of the rating, which it reads and writes. It cannot tell whose
## state that is, so the same function draws a local state of its caller's,
## a row of a table or a cell of the app's store (`cell.state()`).
stars : State(ctx, U8) -> Elem(ctx)
stars = |rating|
	Html.div(
		"stars",
		[
			Html.button_s(rating.signal().map(|n| "${n.to_str()} of 5"), [], rating.update(|_| 5)),
			Html.button("Clear", [], rating.update(|_| 0)),
		],
	)

# endregion over-a-state

page : State(Ctx, Model) -> Elem(Ctx)
page = |model|
	Html.div(
		"mail",
		[
			tabs(model),
			inbox(model),
			empty_note(model.signal().map(|m| m.messages)),
			Engine.state(3, stars),
		],
	)

## The instance holds this store beside its site tree.
Store : {}

## Check that the default first page mounts while this app compiles.
mounted : U64
mounted = Engine.mounts(main)
