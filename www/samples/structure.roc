app [Instance, main] { pf: platform "../../platform/main.roc" }

import pf.Engine exposing [Comp, Elem, In, Root, Row, RowRef, State, Val]
import pf.Html

Instance : Engine.App

main : Engine.Program(Instance)
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
empty_note : Val(Ctx, List(Message)) -> Elem(Ctx)
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
		model.val().map(|m| m.tab),
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
	messages = model.val().map(|m| m.messages)
	selected = Engine.keyed(model.val().map(|m| m.selected), "selected", "")
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
message_row : State(Ctx, Model), RowRef(Ctx, Message), Val(Line, Str) -> Elem(Line)
message_row = |model0, row, is_selected| {
	model = model0.lift_row()
	id = row.key()
	Html.li(
		[Engine.class_v(is_selected)],
		[
			Html.button_v(row.field(|m| m.subject), [], model.update_by(id, |m, k| { ..m, selected: k })),
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
					Html.button_v(open.val().map(|o| if (o) "Hide" else "Show"), [], open.update(|o| !o)),
					Engine.when(open.val(), || Html.p_v(subject, []), || Engine.text("")),
				],
			)
		},
	)

# endregion row-state

# region component
## A component sees only its prop and its own outward actions. It is
## specialised once per prop and action type, however many places use it.
Rating : [Rate(U8)]

stars : Val(Comp(U8, Rating), U8), State(Comp(U8, Rating), List(Rating)) -> Elem(Comp(U8, Rating))
stars = |current, out|
	Html.div(
		"stars",
		[
			Html.button_v(current.map(|n| "${n.to_str()} of 5"), [], out.push(Rate(5))),
			Html.button("Clear", [], out.push(Rate(0))),
		],
	)

## The caller turns the component's actions into writes of its own state.
rating_field : State(In(Ctx, U8), U8) -> Elem(In(Ctx, U8))
rating_field = |rating|
	Engine.component(
		rating.val(),
		Engine.sink(rating, |_, Rate(n)| n),
		stars,
	)

# endregion component

page : State(Ctx, Model) -> Elem(Ctx)
page = |model|
	Html.div(
		"mail",
		[
			tabs(model),
			inbox(model),
			empty_note(model.val().map(|m| m.messages)),
			Engine.state(3, rating_field),
		],
	)
