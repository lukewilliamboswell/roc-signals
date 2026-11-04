Kanban := [].{
	## The four board columns. They are a closed set with a fixed left-to-right
	## order, so they are a tag union rather than a name string compared against a
	## ladder of literals. `to_str` is the heading a reader sees and `slug` is the
	## stable id fragment the specs assert on.
	Column := [Backlog, InProgress, Review, Done].{
		is_eq : Kanban.Column, Kanban.Column -> Bool
		is_eq = |left, right|
			match left {
				Backlog => match right {
					Backlog => True
					_ => False
				}
				InProgress => match right {
					InProgress => True
					_ => False
				}
				Review => match right {
					Review => True
					_ => False
				}
				Done => match right {
					Done => True
					_ => False
				}
			}

		## The visible column heading, and the phrase a card's position line ends
		## with ("1 of 2 in Backlog").
		to_str : Kanban.Column -> Str
		to_str = |column|
			match column {
				Backlog => "Backlog"
				InProgress => "In Progress"
				Review => "Review"
				Done => "Done"
			}

		## Stable, spec-facing id fragment for a column. Ids are derived from this
		## so an assertion never has to spell out a rendered value.
		slug : Kanban.Column -> Str
		slug = |column|
			match column {
				Backlog => "backlog"
				InProgress => "progress"
				Review => "review"
				Done => "done"
			}

		## The neighbouring column, or `Err(AtEdge)` at the ends of the board. The
		## board's edges live here, so no caller has to know an index bound.
		left : Kanban.Column -> Try(Kanban.Column, [AtEdge])
		left = |column|
			match column {
				Backlog => Err(AtEdge)
				InProgress => Ok(Backlog)
				Review => Ok(InProgress)
				Done => Ok(Review)
			}

		right : Kanban.Column -> Try(Kanban.Column, [AtEdge])
		right = |column|
			match column {
				Backlog => Ok(InProgress)
				InProgress => Ok(Review)
				Review => Ok(Done)
				Done => Err(AtEdge)
			}
	}

	## Kanban.Board order, left to right. Every regroup walks this list, so adding a
	## column is a one-line change here plus a new tag.
	all_columns : List(Kanban.Column)
	all_columns = [Backlog, InProgress, Review, Done]

	## The two-word column reads as a phrase with a space, not as its slug.
	## A column's spec-facing id fragment is a short single word, independent of its heading.
	## Rightward from the leftmost column lands on the next column in board order.
	## The rightmost column has no column to its right, so the board edge is reported.
	## The leftmost column has no column to its left, so the board edge is reported.
	## The board lists its four columns once, in left-to-right order.

	## A board card. The title is the durable identity used as the keyed-list key,
	## so a card keeps its row scope through reorder and filter operations.
	Card : { title : Str, column : Kanban.Column, flags : U64 }

	## Kanban.Board editing state: the cards plus the new-card draft that the add reducer
	## has to read. Everything the board displays about the cards is derived.
	Board : { cards : List(Kanban.Card), draft : Str }

	## Presentation record for one card inside one column. Position and boundary
	## facts are derived here so a row never has to know about its siblings.
	CardView : {
		title : Str,
		column : Kanban.Column,
		flags : U64,
		position : U64,
		total : U64,
		is_first : Bool,
		is_last : Bool,
		can_left : Bool,
		can_right : Bool,
	}

	initial_board : Kanban.Board
	initial_board = {
		cards: [
			{ title: "Draft onboarding copy", column: Backlog, flags: 0 },
			{ title: "Design login screen", column: Backlog, flags: 0 },
			{ title: "Ship search filters", column: InProgress, flags: 0 },
			{ title: "Audit billing events", column: Review, flags: 0 },
			{ title: "Rotate API keys", column: Done, flags: 0 },
		],
		draft: "",
	}

	cards_in : List(Kanban.Card), Kanban.Column -> List(Kanban.Card)
	cards_in = |cards, column| cards.keep_if(|card| card.column == column)

	## Regroup the flat card list by column while preserving the relative order of
	## each column's cards. Every mutation ends with this so list order and board
	## order are the same thing.
	canonical : List(Kanban.Card) -> List(Kanban.Card)
	canonical = |cards| Kanban.all_columns.fold([], |acc, column| acc.concat(Kanban.cards_in(cards, column)))

	find_card : List(Kanban.Card), Str -> Try(Kanban.Card, [NotFound])
	find_card = |cards, title| cards.find_first(|card| card.title == title)

	index_of : List(Kanban.Card), Str -> U64
	index_of = |cards, title|
		match cards.map_with_index(|card, index| { index, card }).find_first(|entry| entry.card.title == title) {
			Ok(entry) => entry.index
			Err(_) => 0
		}

	insert_at : List(Kanban.Card), U64, Kanban.Card -> List(Kanban.Card)
	insert_at = |cards, position, card| {
		entries = cards.map_with_index(|item, index| { index, card: item })
		front = entries.keep_if(|entry| entry.index < position).map(|entry| entry.card)
		back = entries.keep_if(|entry| entry.index >= position).map(|entry| entry.card)
		front.append(card).concat(back)
	}

	drop_card : List(Kanban.Card), Str -> List(Kanban.Card)
	drop_card = |cards, title| cards.keep_if(|card| card.title != title)

	## The starting board is already grouped by column, so regrouping leaves it untouched.
	## Regrouping sorts cards into board order regardless of their position in the flat list.

	## Move a card to the neighbouring column, landing at the end of that column.
	## A move at the edge of the board is a no-op, which is what `Kanban.Column.left` and
	## `Kanban.Column.right` report by returning `Err(AtEdge)`.
	move_across : Kanban.Board, Str, [Leftward, Rightward] -> Kanban.Board
	move_across = |board, title, direction|
		match Kanban.find_card(board.cards, title) {
			Ok(card) => {
				target = match direction {
					Leftward => Kanban.Column.left(card.column)
					Rightward => Kanban.Column.right(card.column)
				}
				match target {
					Ok(column) => {
						moved = { ..card, column }
						{ ..board, cards: Kanban.canonical(Kanban.drop_card(board.cards, title).append(moved)) }
					}
					Err(AtEdge) => board
				}
			}
			Err(_) => board
		}

	## Move a card one slot up or down inside its own column.
	move_within : Kanban.Board, Str, [Upward, Downward] -> Kanban.Board
	move_within = |board, title, direction|
		match Kanban.find_card(board.cards, title) {
			Ok(card) => {
				group = Kanban.cards_in(board.cards, card.column)
				position = Kanban.index_of(group, title)
				total = group.len()
				# Genuine boundary arithmetic: the first row cannot rise and the
				# last row cannot fall.
				at_edge = match direction {
					Upward => position == 0
					Downward => position + 1 >= total
				}
				if at_edge {
					board
				} else {
					target = match direction {
						Upward => position - 1
						Downward => position + 1
					}
					regrouped = Kanban.insert_at(Kanban.drop_card(group, title), target, card)
					others = board.cards.keep_if(|item| item.column != card.column)
					{ ..board, cards: Kanban.canonical(others.concat(regrouped)) }
				}
			}
			Err(_) => board
		}

	## Moving a card rightward lands it at the end of the neighbouring column.
	## A card in the leftmost column cannot move further left, so the board is unchanged.
	## A card in the rightmost column cannot move further right, so the board is unchanged.
	## Moving a card up swaps it past the card above it inside its own column.
	## The first card in a column cannot rise any further, so the board is unchanged.

	flag_card : Kanban.Board, Str -> Kanban.Board
	flag_card = |board, title| {
		..board,
		cards: board.cards.map(|card| if card.title == title { { ..card, flags: card.flags + 1 } } else { card }),
	}

	delete_card : Kanban.Board, Str -> Kanban.Board
	delete_card = |board, title| { ..board, cards: Kanban.drop_card(board.cards, title) }

	## What the add form has to say about the current draft. The rendered sentence
	## and the tone it is drawn in both come off this one tag, so the line can
	## never be red while the button is enabled.
	AddStatus := [NeedsTitle, Duplicate, Ready].{
		is_eq : Kanban.AddStatus, Kanban.AddStatus -> Bool
		is_eq = |left, right|
			match left {
				NeedsTitle => match right {
					NeedsTitle => True
					_ => False
				}
				Duplicate => match right {
					Duplicate => True
					_ => False
				}
				Ready => match right {
					Ready => True
					_ => False
				}
			}

		to_str : Kanban.AddStatus -> Str
		to_str = |status|
			match status {
				NeedsTitle => "Enter a title"
				Duplicate => "Duplicate title"
				Ready => "Ready"
			}

		## The status line is a neutral requirement until there is a draft worth
		## commenting on; only a duplicate turns it red.
		class : Kanban.AddStatus -> Str
		class = |status|
			match status {
				NeedsTitle => "hint"
				Duplicate => "text-xs font-medium text-red-600"
				Ready => "text-xs font-medium text-emerald-700"
			}

		accepts : Kanban.AddStatus -> Bool
		accepts = |status|
			match status {
				Ready => True
				_ => False
			}
	}

	add_status : Kanban.Board -> Kanban.AddStatus
	add_status = |board| {
		title = board.draft.trim()
		if title.is_empty() {
			NeedsTitle
		} else if board.cards.any(|card| card.title == title) {
			Duplicate
		} else {
			Ready
		}
	}

	can_add : Kanban.Board -> Bool
	can_add = |board| Kanban.AddStatus.accepts(Kanban.add_status(board))

	add_card : Kanban.Board -> Kanban.Board
	add_card = |board|
		if Kanban.can_add(board) {
			{
				cards: Kanban.canonical(board.cards.append({ title: board.draft.trim(), column: Backlog, flags: 0 })),
				draft: "",
			}
		} else {
			board
		}

	## An empty draft asks for a title rather than reporting a problem.
	## A draft matching an existing card title is reported as a duplicate.
	## Surrounding whitespace is trimmed before the draft is judged, so a padded title is addable.
	## Adding an accepted draft grows the board by exactly one card.

	## Build the per-column presentation records, including boundary facts.
	column_views : List(Kanban.Card), Kanban.Column -> List(Kanban.CardView)
	column_views = |group, column| {
		total = group.len()
		group.map_with_index(
			|card, position| {
				title: card.title,
				column,
				flags: card.flags,
				position: position + 1,
				total,
				is_first: position == 0,
				is_last: position + 1 == total,
				can_left: Try.is_ok(Kanban.Column.left(column)),
				can_right: Try.is_ok(Kanban.Column.right(column)),
			},
		)
	}

	## A WIP cap, or no cap at all. The absence of a limit is a tag rather than a
	## magic zero, so no reader has to remember what `0` meant.
	Limit := [NoLimit, AtMost(U64)].{
		is_eq : Kanban.Limit, Kanban.Limit -> Bool
		is_eq = |left, right|
			match left {
				NoLimit => match right {
					NoLimit => True
					_ => False
				}
				AtMost(left_cap) => match right {
					AtMost(right_cap) => left_cap == right_cap
					_ => False
				}
			}

		## Parse once, at the edge where the number input hands us its text. Empty,
		## non-numeric and zero input all mean "no limit"; anything else caps the
		## column at that many cards.
		from_str : Str -> Kanban.Limit
		from_str = |raw|
			match U64.from_str(raw.trim()) {
				Ok(0) => NoLimit
				Ok(cap) => AtMost(cap)
				Err(_) => NoLimit
			}
	}

	## Where a column sits against its limit. The caption, the `data-wip` attribute
	## and the badge tone are all derived from this one tag, so a column can never
	## show "Over" in the calm colour.
	WipState := [Unlimited, Within(U64, U64), Over(U64, U64)].{
		is_eq : Kanban.WipState, Kanban.WipState -> Bool
		is_eq = |left, right|
			match left {
				Unlimited => match right {
					Unlimited => True
					_ => False
				}
				Within(left_count, left_cap) => match right {
					Within(right_count, right_cap) => left_count == right_count and left_cap == right_cap
					_ => False
				}
				Over(left_count, left_cap) => match right {
					Over(right_count, right_cap) => left_count == right_count and left_cap == right_cap
					_ => False
				}
			}

		of : U64, Kanban.Limit -> Kanban.WipState
		of = |count, limit|
			match limit {
				NoLimit => Unlimited
				AtMost(cap) => if count > cap { Over(count, cap) } else { Within(count, cap) }
			}

		## The badge caption, short enough to sit on the header line beside the
		## column title.
		to_str : Kanban.WipState -> Str
		to_str = |state|
			match state {
				Unlimited => "No WIP limit"
				Within(count, cap) => "WIP ${count.to_str()}/${cap.to_str()}"
				Over(count, cap) => "Over ${count.to_str()}/${cap.to_str()}"
			}

		## The `data-wip` attribute the specs read.
		attr : Kanban.WipState -> Str
		attr = |state|
			match state {
				Unlimited => "unlimited"
				Within(_, _) => "ok"
				Over(_, _) => "over"
			}

		class : Kanban.WipState -> Str
		class = |state|
			match state {
				Unlimited => "badge badge-neutral shrink-0"
				Within(_, _) => "badge badge-ok shrink-0"
				Over(_, _) => "badge badge-danger shrink-0"
			}

		is_over : Kanban.WipState -> Bool
		is_over = |state|
			match state {
				Over(_, _) => True
				_ => False
			}
	}

	## An empty limit box means the column is uncapped rather than capped at nothing.
	## Non-numeric text in the limit box is leniently read as no cap at all.
	## A partly numeric entry is rejected whole, not truncated to its leading digits.
	## A cap of zero is spelled as the absence of a limit, never as `AtMost(0)`.
	## A padded number still parses to a cap at that many cards.

	## An uncapped column says so instead of printing a count against a cap.
	## A column exactly at its cap is still within the limit, not over it.
	## A column past its cap changes the caption wording, not just the number.
	## An over-limit column exposes the "over" marker the specs read.
	## A column at exactly its cap still exposes the calm marker.
	## An uncapped column is marked as unlimited rather than as merely acceptable.
	## No card count can put an uncapped column over its limit.

	matches_filter : Kanban.CardView, Str -> Bool
	matches_filter = |view, query| if query.is_empty() { True } else { view.title.contains(query) }


}
