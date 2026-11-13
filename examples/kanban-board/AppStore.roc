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
## - `drag`: the board's active gesture, including its owning pointer and
##   the gap currently under it.
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
			drag: Engine.cell(Board.idle_drag),
		}.Engine.Cells,
	)

	## The store's cells: what a board is drawn over
	## (`Board.Props`).
	cells = AppStore.store.cells()
}

## Every column of the store's board after `writes`, in board order, each
## top to bottom.
lanes_after : List(Engine.Write(_)) -> List(List(Str))
lanes_after = |writes| {
	held = AppStore.store.after(writes).read(AppStore.cells.cards).to_list()
	Kanban.all_columns.map(|column| Kanban.lane(held, column))
}

## Adding a card writes it at the end of Backlog, under its title without the spaces around it.
expect lanes_after(Board.added(AppStore.cells.cards, " Write release notes ")) == [["Draft onboarding copy", "Design login screen", "Write release notes"], ["Ship search filters"], ["Audit billing events"], ["Rotate API keys"]]

## A draft that is a card's title already, or blank, adds nothing.
expect lanes_after(Board.added(AppStore.cells.cards, "Rotate API keys").concat(Board.added(AppStore.cells.cards, "  "))) == lanes_after([])

## A move to the next column lands at its end, and a move past the board's edge writes no card.
expect {
	cards = AppStore.cells.cards
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

## Releasing a drag moves its card and clears its owner in one pure
## transition, without an engine or browser deciding either write.
expect {
	cells = AppStore.cells
	dragging : Board.Drag
	dragging = Dragging({ title: "Draft onboarding copy", pointer: 7, over: Before("Ship search filters") })
	before = AppStore.store.with_initial(cells.drag, dragging)
	pointer : Engine.Pointer
	pointer = { id: 7, kind: Mouse, button: Main, buttons: 0, modifiers: { shift: Bool.False, ctrl: Bool.False, alt: Bool.False, meta: Bool.False }, primary: Bool.True, at: In({ zone: "card:Ship search filters", x: 5000, y: 2500 }) }
	after = before.after(Board.finished_drag({ cards: cells.cards, drag: cells.drag }, { before: dragging, listing: Kanban.initial_cards, pointer }))
	{
		drag: after.read(cells.drag),
		lanes: Kanban.all_columns.map(|column| Kanban.lane(after.read(cells.cards).to_list(), column)),
		written_cards: after.read(cells.cards).inverse()?.len(),
	} == {
		drag: Board.idle_drag,
		lanes: [["Design login screen"], ["Draft onboarding copy", "Ship search filters"], ["Audit billing events"], ["Rotate API keys"]],
		written_cards: 3,
	}
}

## An unchanged gap and another pointer both leave the active drag alone.
## Its own cancellation clears it without editing the cards.
expect {
	cells = AppStore.cells
	dragging : Board.Drag
	dragging = Dragging({ title: "Draft onboarding copy", pointer: 7, over: Before("Ship search filters") })
	pointer : Engine.Pointer
	pointer = { id: 7, kind: Mouse, button: None, buttons: 1, modifiers: { shift: Bool.False, ctrl: Bool.False, alt: Bool.False, meta: Bool.False }, primary: Bool.True, at: In({ zone: "card:Ship search filters", x: 5000, y: 1000 }) }
	before = AppStore.store.with_initial(cells.drag, dragging)
	cancelled = before.after(Board.cancelled_drag(cells.drag, { before: dragging, pointer }))
	{
		unchanged: Board.moved_drag(cells.drag, { before: dragging, pointer }).is_empty(),
		other: Board.moved_drag(cells.drag, { before: dragging, pointer: { ..pointer, id: 8, at: Outside } }).is_empty(),
		second_press: Board.started_drag(cells.drag, { before: dragging, title: "Ship search filters", pointer: { ..pointer, id: 8, button: Main } }).is_empty(),
		drag: cancelled.read(cells.drag),
		cards: cancelled.read(cells.cards).to_list().len(),
	} == {
		unchanged: Bool.True,
		other: Bool.True,
		second_press: Bool.True,
		drag: Board.idle_drag,
		cards: Kanban.initial_cards.len(),
	}
}

## A move inside a column exchanges two cards, and the two moves of one event apply in order.
expect {
	cards = AppStore.cells.cards
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
	cards = AppStore.cells.cards
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

## A move inside a column writes two keyed cards, a move past its top
## writes none, and a later turn records only its own cards after an earlier move.
expect {
	cards = AppStore.cells.cards
	up = AppStore.store.after(Board.moved_within(cards, { title: "Design login screen", toward: Upward }))
	top = AppStore.store.after(Board.moved_within(cards, { title: "Draft onboarding copy", toward: Upward }))
	across = AppStore.store.after(Board.moved_across(cards, { title: "Draft onboarding copy", toward: Rightward }))
	within = across.after(Board.moved_within(cards, { title: "Ship search filters", toward: Downward }))
	{
		up: up.read(cards).inverse()?.len(),
		top: top.read(cards).inverse()?.len(),
		chained: within.read(cards).inverse()?.len(),
	} == { up: 2, top: 0, chained: 2 }
}
