app [main] { pf: platform "../../platform/main.roc" }

import pf.Engine
import pf.Html

# region transition
## A transition watches the value that changes the drawing. It starts
## after mount; each later change marks the complete batch for this call.
main : Engine.Program
main = Engine.program(
	|| Engine.state(
		False,
		|show_details| Html.div(
			"",
			[
				Html.button("Details", [], show_details.update(|visible| !visible)),
				Engine.when(show_details.signal(), || Html.p("More about this book", ""), || Html.p("Book summary", "")),
				Engine.watch_changes(show_details.signal(), |_| [ViewTransition(["shelf"])], Engine.ignore({})),
				long_exit({}),
			],
		),
	),
)

# endregion transition

# region leaving
## The row stays in the app's list while leaving. Its own scope owns the
## timer, so disposing the row cancels it. CSS can animate `.leaving` for
## 1500 ms; the timer's result then removes the row from the list. At the
## in-flight bound, refusal removes it immediately rather than leaving it stuck.
long_exit : {} -> Engine.Elem(ctx)
long_exit = |_| Engine.state(
	[{ id: "slow", title: "A slowly leaving book", leaving: False }],
	|books| Engine.each(
		books.signal(),
		|book| book.id,
		|row| Engine.element(
			"article",
			[Engine.class_s(row.item().map(|book| if (book.leaving) "leaving" else ""))],
			[
				Engine.text_s(row.item().map(|book| book.title)),
				Html.button("Remove slowly", [], books.lift_row().update_by(row.key(), |current, id| current.map(|book| if (book.id == id) { ..book, leaving: True } else book))),
				Engine.watch_changes(
					row.item(),
					|book| if (book.leaving) [Timer(1500)] else [],
					books.lift_row().on_result(
						|current, issued, result| match result {
							Fired(_) | Refused => current.keep_if(|book| book.id != issued.id)
							_ => current
						},
					),
				),
			],
		),
	),
)
# endregion leaving
