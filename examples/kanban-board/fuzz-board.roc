app [target] {
	fz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.6.0/6uc3YKGydgEnS2nrCimSYWDNfT6drYcgU52VAwqrb6DS.tar.zst",
}

import fz.Fuzz
import Kanban

## The board's moves, against a model that keeps each column as its own
## list. The board keeps every card in one flat list and regroups it by
## column after each change, so the bugs to fear are a card lost, doubled
## or reordered by a regrouping, and a move past the edge of a column or
## of the board.
##
## Each input decodes into a sequence of what the user can do: type a
## draft and add it, move a card left, right, up or down, flag it, delete
## it. After every step:
##
## - the board's cards, in order, are the model's columns read left to
##   right, each top to bottom, with the same flags;
## - no two cards share a title;
## - the add form accepts exactly a trimmed, non-empty draft that no card
##   has as its title.
Input : List(U8)

## The model: each column's cards, top to bottom, as (title, flags).
Model : List(List((Str, U64)))

## The pieces a draft is typed from; an input byte picks one.
pieces : List(Str)
pieces = ["Ship", " ", "Ship ", "search", "", "é", "Rotate API keys", "  x  "]

## The model of `Kanban.initial_board`.
initial : Model
initial = Kanban.all_columns.map(|column| Kanban.cards_in(Kanban.initial_board.cards, column).map(|card| (card.title, card.flags)))

## The model's cards as the board lists them.
listed : Model -> List(Kanban.Card)
listed = |model| List.map2(Kanban.all_columns, model, |column, cards| cards.map(|(title, flags)| { title, column, flags })).join()

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
model_step : Model, Str, U8, Str -> Model
model_step = |model, title, op, draft|
	match (op % 6, place(model, title)) {
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
			if (op / 6) % 2 == 0 {
				model.update(at.column, |cards| cards.update(at.row, |(t, flags)| (t, flags + 1)) ?? cards) ?? model
			} else {
				take_out(model, at)
			}
		_ => model
	}

## The same step on the board.
board_step : Kanban.Board, Str, U8, Str -> Kanban.Board
board_step = |board, title, op, draft|
	match op % 6 {
		0 => Kanban.add_card({ ..board, draft })
		1 => Kanban.move_across(board, title, Leftward)
		2 => Kanban.move_across(board, title, Rightward)
		3 => Kanban.move_within(board, title, Upward)
		4 => Kanban.move_within(board, title, Downward)
		_ => if ((op / 6) % 2 == 0) Kanban.flag_card(board, title) else Kanban.delete_card(board, title)
	}

## Every property after every step, or the first that fails.
check : Input -> Try({}, Str)
check = |bytes| {
	var $board = Kanban.initial_board
	var $model = initial
	var $i = 0
	while $i + 2 < bytes.len() {
		op = bytes.get($i) ?? 0
		a = bytes.get($i + 1) ?? 0
		b = bytes.get($i + 2) ?? 0
		cards = $board.cards
		title = (cards.get(a.to_u64() % (cards.len() + 1)) ?? { title: "no such card", column: Backlog, flags: 0 }).title
		draft = "${pieces.get(a.to_u64() % pieces.len()) ?? ""}${pieces.get(b.to_u64() % pieces.len()) ?? ""}"
		accepts = Kanban.can_add({ ..$board, draft })
		trimmed = draft.trim()
		if accepts != (!trimmed.is_empty() and !cards.any(|c| c.title == trimmed)) {
			return Err("the add form ${if (accepts) "accepts" else "refuses"} ${Str.inspect(draft)} on ${Str.inspect(cards.map(|c| c.title))}")
		}
		$board = board_step($board, title, op, draft)
		$model = model_step($model, title, op, draft)
		if $board.cards != listed($model) {
			return Err("after step ${($i // 3).to_str()} (op ${(op % 6).to_str()} on ${Str.inspect(title)}) the board holds ${Str.inspect($board.cards)}, the model ${Str.inspect(listed($model))}")
		}
		titles = $board.cards.map(|c| c.title)
		if Set.from_list(titles).len() != titles.len() {
			return Err("two cards share a title: ${Str.inspect(titles)}")
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
ex = |name, input| Fuzz.example({ name, revision: "1", make: || input })

target = Fuzz.target_with!({
	name: "kanban-board",
	examples: [
		# Add "Ship search", move it right twice, up, flag it, then left.
		ex("add-and-move", [0, 0, 3, 2, 5, 0, 2, 5, 0, 3, 5, 0, 5, 5, 0, 1, 5, 0]),
		# Past every edge: left from Backlog, right from Done, up from the top,
		# down from the bottom.
		ex("edges", [1, 0, 0, 2, 4, 0, 3, 0, 0, 4, 1, 0]),
		# A duplicate and a blank draft, then a delete.
		ex("duplicate-blank-delete", [0, 6, 4, 0, 4, 1, 11, 0, 0]),
		ex("empty", []),
	],
	generator: Fuzz.list(Fuzz.u8, 300),
	test!,
	show: Str.inspect,
})
