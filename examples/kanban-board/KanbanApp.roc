import pf.Engine exposing [Elem, Signal]
import pf.Html
import AppStore
import Board
import Kanban

## Kanban Board: four columns of cards that move across and inside them,
## a filter by title, and a WIP limit.
##
## The cards, the filter and the limit are cells of the app's store
## (`AppStore`). The cards are a table: each column is a view of it that
## shows its own cards in the order of their places, so a move writes the
## cards it touches and each column hears of its own (`Board`). The size of
## every column is counted once per write, in one `derive` layer that the
## summary and the columns read. Only the add form's draft is local: no one
## else reads it.
KanbanApp := [].{

	## The page, over the store.
	view : {} -> Elem(Engine.StoreRoot(_))
	view = |{}| Engine.derive(Board.tally(board), |sizes| page(sizes))

	## The program `main.roc` binds for the browser module and the native spec
	## runner.
	program : Engine.Program
	program = Engine.program_store({ storage_keys: [], max_inflight: 32 }, |_boot| AppStore.store, |_boot| KanbanApp.view({}))
}

## What the board is drawn over: the cells of this app's store that `Board`
## reads and writes.
board = { cards: AppStore.cells.cards, filter: AppStore.cells.filter, limit: AppStore.cells.limit }

## The page under the board's tally: the controls, the summary and the
## four columns.
page : Signal(ctx, Kanban.Tally) -> Elem(ctx)
	where [ctx.store : () -> Engine.Reach(ctx, _)]
page = |sizes| Html.div(
	"app-shell app-shell-wide",
	[
		Html.section(
			"Kanban Board",
			"app-header",
			[
				Html.h1("Kanban Board", "app-title"),
				Html.p("Move cards across columns, reorder within a column, filter by title, and watch derived per-column counts and WIP limits.", "app-subtitle"),
			],
		),
		controls({}),
		summary(sizes),
		Html.div("grid gap-4 md:grid-cols-2 xl:grid-cols-4", Kanban.all_columns.map(|column| Board.lane(board, column, sizes))),
	],
)

## The filter box, the WIP limit box and the add form. The draft of a new
## card's title is this form's own state: the box, the status line and the
## button read it, and nothing outside the form does. "Add card" is one
## event that writes the card to the store and empties the draft; the
## button is disabled unless the draft is ready, so a click always adds.
controls : {} -> Elem(ctx)
	where [ctx.store : () -> Engine.Reach(ctx, _)]
controls = |{}| Engine.state(
	"",
	|draft| {
		cards = AppStore.cells.cards
		status = draft.signal().map2(cards.signal(), |text, table| Kanban.add_status(text, |title| table.contains(title)))
		Html.section(
			"Board controls",
			"panel grid gap-4 p-5",
			[
				Html.div(
					"toolbar",
					[
						labelled_field(
							{ label: "Filter cards", look: "min-w-0 flex-1 basis-56" },
							Html.text_input(
								Engine.const("Filter cards"),
								"text",
								AppStore.cells.filter.signal(),
								[Engine.class("input"), Engine.attr("placeholder", "Search titles, e.g. billing")],
								Engine.handle(|text| [AppStore.cells.filter.set(text)]),
							),
						),
						labelled_field(
							{ label: "WIP limit", look: "w-28 shrink-0" },
							Html.number_input(
								Engine.const("WIP limit"),
								AppStore.cells.limit.signal(),
								[Engine.class("input"), Engine.attr("placeholder", "3"), Engine.attr("min", "0")],
								Engine.handle(|text| [AppStore.cells.limit.set(text)]),
							),
						),
						labelled_field(
							{ label: "New card title", look: "min-w-0 flex-1 basis-56" },
							Html.text_input(
								Engine.const("New card title"),
								"text",
								draft.signal(),
								[Engine.class("input"), Engine.attr("placeholder", "Write release notes")],
								draft.set_value(|_, text| text),
							),
						),
						Html.button(
							"Add card",
							[Engine.attr("type", "button"), Engine.class("button-primary shrink-0"), Html.disabled(status.map(|now| !Kanban.AddStatus.is_ready(now)))],
							Engine.handle_by(draft.signal(), |text, _| Board.added(cards, text)).also(draft.update(|_| "")),
						),
					],
				),
				Html.p_s(status.map(Kanban.AddStatus.to_str), [Engine.class_s(status.map(Kanban.AddStatus.class)), Engine.test_id("add-status")]),
			],
		)
	},
)

## The board's totals, and a notice while any column is over the limit.
summary : Signal(ctx, Kanban.Tally) -> Elem(ctx)
	where [ctx.store : () -> Engine.Reach(ctx, _)]
summary = |sizes| {
	over = sizes.map2(AppStore.cells.limit.signal(), |tally, text| Kanban.columns_over(tally, Kanban.Limit.from_str(text)))
	Html.section(
		"Board summary",
		"panel grid gap-4 p-5",
		[
			Html.div(
				"stat-grid",
				[
					stat_tile({ label: "Board total", id: "board-total" }, sizes.map(|tally| Kanban.cards_held(tally).to_str())),
					stat_tile({ label: "Matching filter", id: "board-matching" }, sizes.map(|tally| Kanban.cards_shown(tally).to_str())),
					stat_tile({ label: "Columns over WIP", id: "board-over" }, over.map(|count| count.to_str())),
				],
			),
			Engine.when(
				over.map(|count| count > 0),
				|| Html.p("Rebalance the board: at least one column is over its WIP limit.", "notice notice-warn"),
				|| Engine.text(""),
			),
		],
	)
}

## A control under its caption.
labelled_field : { label : Str, look : Str }, Elem(ctx) -> Elem(ctx)
labelled_field = |{ label, look }, control| Html.div("field ${look}", [Html.p(label, "field-label"), control])

## One figure of the summary, under its caption.
stat_tile : { label : Str, id : Str }, Signal(ctx, Str) -> Elem(ctx)
stat_tile = |{ label, id }, value| Html.div("stat", [Html.p(label, "stat-label"), Html.p_s(value, [Engine.class("stat-value"), Engine.test_id(id)])])
