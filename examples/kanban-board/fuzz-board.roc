app [target] {
	fz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.6.1/GDoZFRDnzMRiVk9nE8wdWn52btGsM1GhcY9VDKqy9f1Y.tar.zst",
}

import fz.Fuzz
import Kanban

## The board's moves, against a model that keeps each column as its own
## list. The board holds its cards by title, each with its column and its
## place in it, and a move is a few keyed edits of them, so the bugs to
## fear are a card lost or doubled, a column whose places have a gap or a
## tie after a card left or arrived, and a move past the edge of a column
## or of the board.
##
## Each input decodes into a sequence of what the user can do: type a
## draft and add it, move a card left, right, up or down, flag it, delete
## it, or drop it before or after a card, at a column end, or outside.
## After every step:
##
## - the board's cards, each column in the order its view draws, are the
##   model's columns read left to right, each top to bottom, with the same
##   flags, and every card's place is its position in its column;
## - no two cards share a title, and dropping on the current gap writes
##   no card;
## - the add form accepts exactly a trimmed, non-empty draft that no card
##   has as its title.
Input : List(U8)

## The model: each column's cards, top to bottom, as (title, flags).
Model : List(List((Str, U64)))

## The pieces a draft is typed from; an input byte picks one.
pieces : List(Str)
pieces = ["Ship", " ", "Ship ", "search", "", "é", "Rotate API keys", "  x  "]

## The model of `Kanban.initial_cards`.
initial : Model
initial = Kanban.all_columns.map(
	|column| Kanban.lane(Kanban.initial_cards, column).map(
		|title| match Kanban.card_titled(Kanban.initial_cards, title) {
			Ok(card) => (title, card.flags)
			Err(NoSuchCard) => crash "fuzz-board: a column lists a card the board does not hold"
		},
	),
)

## The model's cards as the board should hold them, in board order.
listed : Model -> Kanban.Listing
listed = |model|
	List.map2(
		Kanban.all_columns,
		model,
		|column, cards| cards.map_with_index(|(title, flags), place| { key: title, row: { column, place, flags } }),
	).join()

## The board's cards in board order: each column as its view orders it.
in_order : Kanban.Listing -> Kanban.Listing
in_order = |board|
	Kanban.all_columns
		.map(
			|column| {
				{ keep, sort, compare } = Kanban.plan({ column, filter: "" })
				board.keep_if(|held| keep(held.key, held.row)).sort_with(|a, b| compare(sort(a.key, a.row), sort(b.key, b.row)))
			},
		)
		.join()

## Where the card titled `title` is: its column and its place in it.
place : Model, Str -> Try({ column : U64, row : U64 }, [NotFound])
place = |model, title| {
	var $c = 0
	for cards in model {
		match cards.find_first_index(|(t, _)| t == title) {
			Ok(row) => return Ok({ column: $c, row })
			Err(_) => {}
		}
		$c = $c + 1
	}
	Err(NotFound)
}

## The model with the card at `at` taken out of its column.
take_out : Model, { column : U64, row : U64 } -> Model
take_out = |model, at| model.update(at.column, |cards| cards.drop_at(at.row)) ?? model

## One step of the model.
model_step : Model, { title : Str, op : U8, draft : Str, over : Kanban.Spot } -> Model
model_step = |model, { title, op, draft, over }|
	match (op % 8, place(model, title)) {
		(0, _) => {
			t = draft.trim()
			if t.is_empty() or place(model, t).is_ok() {
				model
			} else {
				model.update(0, |cards| cards.append((t, 0))) ?? model
			}
		}
		(1, Ok(at)) if at.column > 0 => {
			card = (model.get(at.column) ?? []).get(at.row) ?? crash "the model lost a card"
			take_out(model, at).update(at.column - 1, |cards| cards.append(card)) ?? model
		}
		(2, Ok(at)) if at.column + 1 < model.len() => {
			card = (model.get(at.column) ?? []).get(at.row) ?? crash "the model lost a card"
			take_out(model, at).update(at.column + 1, |cards| cards.append(card)) ?? model
		}
		(3, Ok(at)) if at.row > 0 => model.update(at.column, |cards| cards.swap(at.row - 1, at.row) ?? cards) ?? model
		(4, Ok(at)) => {
			last = (model.get(at.column) ?? []).len()
			if at.row + 1 < last {
				model.update(at.column, |cards| cards.swap(at.row, at.row + 1) ?? cards) ?? model
			} else {
				model
			}
		}
		(5, Ok(at)) =>
			if (op / 8) % 2 == 0 {
				model.update(at.column, |cards| cards.update(at.row, |(t, flags)| (t, flags + 1)) ?? cards) ?? model
			} else {
				take_out(model, at)
			}
		(6, _) | (7, _) => model_drop(model, { title, over })
		_ => model
	}

## The drop oracle removes a card from the model's column lists and inserts
## it at the chosen gap. It never uses the board's places or landing function.
model_drop : Model, { title : Str, over : Kanban.Spot } -> Model
model_drop = |model, { title, over }| {
	from = place(model, title) ?? return model
	card = (model.get(from.column) ?? []).get(from.row) ?? crash "fuzz-board: model lost the dragged card"
	target = match over {
		Nowhere => return model
		Before(other) => place(model, other) ?? return model
		After(other) => {
			at = place(model, other) ?? return model
			{ ..at, row: at.row + 1 }
		}
		EndOf(column) => {
			index = Kanban.all_columns.find_first_index(|known| known == column) ?? crash "fuzz-board: column outside board"
			{ column: index, row: (model.get(index) ?? []).len() }
		}
	}
	row = if (target.column == from.column and target.row > from.row) target.row - 1 else target.row
	take_out(model, from).update(target.column, |cards| cards.take_first(row).append(card).concat(cards.drop_first(row))) ?? model
}

## The edits of the same step on the board.
board_edits : Kanban.Listing, { title : Str, op : U8, draft : Str, over : Kanban.Spot } -> List(Kanban.Edit)
board_edits = |board, { title, op, draft, over }|
	match op % 8 {
		0 => Kanban.add_card(board, draft)
		1 => Kanban.move_across(board, { title, toward: Leftward })
		2 => Kanban.move_across(board, { title, toward: Rightward })
		3 => Kanban.move_within(board, { title, toward: Upward })
		4 => Kanban.move_within(board, { title, toward: Downward })
		5 =>
			if (op / 8) % 2 == 0 {
				match Kanban.card_titled(board, title) {
					Ok(card) => [Put(title, Kanban.flag_card(card))]
					Err(NoSuchCard) => []
				}
			} else {
				Kanban.delete_card(board, title)
			}
		_ => {
			zone = match over {
				Before(other) | After(other) => "${if ((op / 16) % 2 == 0) "card" else "grip"}:${other}"
				EndOf(column) => "lane:${Kanban.Column.slug(column)}"
				Nowhere => ""
			}
			y = match over {
				Before(_) => 2500
				_ => 7500
			}
			Kanban.move_to(board, { title, over: Kanban.Spot.from_zone(zone, y) })
		}
	}

## Every property after every step, or the first that fails.
check : Input -> Try({}, Str)
check = |bytes| {
	var $board = Kanban.initial_cards
	var $model = initial
	var $i = 0
	while $i + 2 < bytes.len() {
		op = bytes.get($i) ?? 0
		a = bytes.get($i + 1) ?? 0
		b = bytes.get($i + 2) ?? 0
		titles = listed($model).map(|held| held.key)
		title = titles.get(a.to_u64() % (titles.len() + 1)) ?? "no such card"
		other = titles.get(b.to_u64() % (titles.len() + 1)) ?? "no such card"
		over = if op % 8 == 6 {
			if ((op / 8) % 2 == 0) Before(other) else After(other)
		} else if (op / 8) % 2 == 0 {
			EndOf(Kanban.all_columns.get(b.to_u64() % 4) ?? crash "fuzz-board: a board column")
		} else {
			Nowhere
		}
		draft = "${pieces.get(a.to_u64() % pieces.len()) ?? ""}${pieces.get(b.to_u64() % pieces.len()) ?? ""}"
		board = $board
		accepts = Kanban.AddStatus.is_ready(Kanban.add_status(draft, |taken| board.any(|held| held.key == taken)))
		trimmed = draft.trim()
		if accepts != (!trimmed.is_empty() and !titles.contains(trimmed)) {
			return Err("the add form ${if (accepts) "accepts" else "refuses"} ${Str.inspect(draft)} on ${Str.inspect(titles)}")
		}
		if !Kanban.move_to(board, { title, over: Before(title) }).is_empty() or !Kanban.move_to(board, { title, over: After(title) }).is_empty() {
			return Err("dropping onto either side of the dragged card edited its existing gap")
		}
		$board = Kanban.edited(board, board_edits(board, { title, op, draft, over }))
		$model = model_step($model, { title, op, draft, over })
		if in_order($board) != listed($model) {
			return Err("after step ${($i // 3).to_str()} (op ${(op % 8).to_str()} on ${Str.inspect(title)}) the board holds ${Str.inspect(in_order($board))}, the model ${Str.inspect(listed($model))}")
		}
		held_titles = $board.map(|held| held.key)
		if Set.from_list(held_titles).len() != held_titles.len() {
			return Err("two cards share a title: ${Str.inspect(held_titles)}")
		}
		$i = $i + 3
	}
	Ok({})
}

test! : Input => Fuzz.Outcome
test! = |input| match check(input) {
	Ok({}) => Fuzz.keep
	Err(problem) => crash problem
}

ex : Str, Input -> Fuzz.Example(Input)
ex = |name, input| Fuzz.example({ name, revision: "2", make: || input })

target = Fuzz.target_with!({
	name: "kanban-board",
	examples: [
		# Add "Shipsearch"; then the board's last card: right twice at the
		# board's edge, up at the top of its column, a flag, and left.
		ex("add-and-move", [0, 0, 3, 2, 5, 0, 2, 5, 0, 3, 5, 0, 5, 5, 0, 1, 5, 0]),
		# Past every edge: left from Backlog, right from Done, up from the top,
		# down from the bottom.
		ex("edges", [1, 0, 0, 2, 4, 0, 3, 0, 0, 4, 1, 0]),
		# A duplicate and a blank draft, then a delete.
		ex("duplicate-blank-delete", [0, 6, 4, 0, 4, 1, 13, 0, 0]),
		ex("drop-across-reorder-and-own-gap", [6, 0, 2, 14, 2, 1, 7, 1, 3, 6, 0, 0, 15, 0, 0]),
		ex("empty", []),
	],
	generator: Fuzz.list(Fuzz.u8, 300),
	test!,
	show: Str.inspect,
})
