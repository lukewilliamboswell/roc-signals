import pf.Engine
import Board
import Kanban

## The Kanban board's store: the state the whole page shares, held at the
## root and reached from any depth with no `lift` and no prop.
##
## - `cards`: the board's cards, a table by title. Each column draws a view
##   of it, and every move is a keyed write of it (`Board`).
## - `filter`: the text of the filter box, which every column's view and
##   the summary read.
## - `limit`: the text of the WIP limit box, read by each column's badge
##   and the summary.
##
## The module's one tag is the store's name: it is part of the type of every
## handle, so a cell of another store is a type error here.
AppStore := [KanbanBoard].{

	## The store: its name, and its cells with their starting values.
	store = Engine.store(
		AppStore.KanbanBoard,
		{
			cards: Engine.table(Kanban.initial_cards),
			filter: Engine.cell(""),
			limit: Engine.cell("1"),
		}.Engine.Cells,
	)

	## The handles on the store's cells: what a board is drawn over
	## (`Board.Props`).
	h = AppStore.store.handles()
}

## Every column of the store's board after `writes`, in board order, each
## top to bottom.
lanes_after : List(Engine.Write(_)) -> List(List(Str))
lanes_after = |writes| {
	held = AppStore.store.after(writes).read(AppStore.h.cards).to_list()
	Kanban.all_columns.map(|column| Kanban.lane(held, column))
}

## Adding a card writes it at the end of Backlog, under its title without the spaces around it.
expect lanes_after(Board.added(AppStore.h.cards, " Write release notes ")) == [["Draft onboarding copy", "Design login screen", "Write release notes"], ["Ship search filters"], ["Audit billing events"], ["Rotate API keys"]]

## A draft that is a card's title already, or blank, adds nothing.
expect lanes_after(Board.added(AppStore.h.cards, "Rotate API keys").concat(Board.added(AppStore.h.cards, "  "))) == lanes_after([])

## A move to the next column lands at its end, and a move past the board's edge writes no card.
expect {
	cards = AppStore.h.cards
	right = lanes_after(Board.moved_across(cards, { title: "Draft onboarding copy", toward: Rightward }))
	edge = lanes_after(Board.moved_across(cards, { title: "Rotate API keys", toward: Rightward }))
	actual =
		\\right: ${Str.inspect(right)}
		\\edge: ${Str.inspect(edge == lanes_after([]))}
	expected =
		\\right: [["Design login screen"], ["Ship search filters", "Draft onboarding copy"], ["Audit billing events"], ["Rotate API keys"]]
		\\edge: True
	actual == expected
}

## A move inside a column exchanges two cards, and the two moves of one event apply in order.
expect {
	cards = AppStore.h.cards
	up = Board.moved_within(cards, { title: "Design login screen", toward: Upward })
	back = Board.moved_within(cards, { title: "Design login screen", toward: Downward })
	actual =
		\\up: ${Str.inspect(lanes_after(up))}
		\\up and back: ${Str.inspect(lanes_after(up.concat(back)) == lanes_after([]))}
	expected =
		\\up: [["Design login screen", "Draft onboarding copy"], ["Ship search filters"], ["Audit billing events"], ["Rotate API keys"]]
		\\up and back: True
	actual == expected
}

## Deleting a card moves the card below it up, and the table records the two cards written, not a rewrite of the board.
expect {
	cards = AppStore.h.cards
	after = AppStore.store.after(Board.deleted(cards, "Draft onboarding copy")).read(cards)
	written = match after.inverse() {
		Ok(undoing) => "${undoing.len().to_str()} cards"
		Err(Rewritten) => "the whole board"
	}
	actual =
		\\backlog: ${Str.inspect(Kanban.lane(after.to_list(), Backlog))}
		\\now first: ${Str.inspect(after.get("Design login screen"))}
		\\written: ${written}
	expected =
		\\backlog: ["Design login screen"]
		\\now first: Ok({ column: Backlog, flags: 0, place: 0 })
		\\written: 2 cards
	actual == expected
}
