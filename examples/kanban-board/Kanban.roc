## The rules of the Kanban board, as plain data and pure functions: its
## columns, its cards, the moves a card can make, what the add form says of
## a draft, and the WIP limit.
##
## Nothing here knows how the board is held or drawn. A move is decided
## from a listing of the cards and answered as the keyed edits that make
## it: the app applies them to the table its store holds (`Board`), and
## `fuzz-board.roc` to a listing of its own.
Kanban := [].{

	## The four board columns. They are a closed set with a fixed left-to-right
	## order, so they are a tag union rather than a name string compared against a
	## ladder of literals. `to_str` is the heading a reader sees and `slug` is the
	## stable id fragment the specs assert on.
	Column := [Backlog, InProgress, Review, Done].{
		is_eq : _

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

	## Board order, left to right.
	all_columns : List(Kanban.Column)
	all_columns = [Backlog, InProgress, Review, Done]

	## A card as the board holds it under its title: its column, its place in
	## that column counted from the top, and how often it has been flagged.
	## The places of a column's cards are 0, 1, 2 and so on with no gap, so a
	## card's place is both the order its column is drawn in and the number
	## its position line shows ("2 of 3").
	Card : { column : Kanban.Column, place : U64, flags : U64 }

	## The board's cards by title, in no particular order: what a move is
	## decided from. A title is a card's identity, so no two cards share one.
	Listing : List({ key : Str, row : Kanban.Card })

	## One keyed write to the cards: the card to hold under a title, or a
	## title to drop. A move is a list of them, applied in order.
	Edit : [Put(Str, Kanban.Card), Remove(Str)]

	## A drop describes a gap beside a card or the end of a lane. These are
	## application targets, independent of browser geometry and engine ids.
	Spot := [Nowhere, Before(Str), After(Str), EndOf(Kanban.Column)].{
		is_eq : _

		## Decode only this board's zone vocabulary. Titles retain every byte
		## after the prefix, including colons; an unknown zone is no drop target.
		from_zone : Str, U16 -> Kanban.Spot
		from_zone = |zone, y| {
			if zone.starts_with("card:") or zone.starts_with("grip:") {
				title = if (zone.starts_with("card:")) zone.drop_prefix("card:") else zone.drop_prefix("grip:")
				if (title.is_empty()) Nowhere else if (y < 5000) Before(title) else After(title)
			} else if zone.starts_with("lane:") {
				slug = zone.drop_prefix("lane:")
				match Kanban.all_columns.find_first(|column| Kanban.Column.slug(column) == slug) {
					Ok(column) => EndOf(column)
					Err(_) => Nowhere
				}
			} else {
				Nowhere
			}
		}
	}

	## A gap's column and place, before the dragged card is taken out.
	Position : { column : Kanban.Column, place : U64 }

	## Taking a card out shifts a later gap in its own lane up one place.
	## This one adjustment is shared by the preview and the eventual move.
	landing : Kanban.Card, Kanban.Position -> Kanban.Position
	landing = |card, target| {
		column: target.column,
		place: if (target.column == card.column and target.place > card.place) target.place - 1 else target.place,
	}

	## Move a card into a gap. Only rows whose column or place changes are
	## written; dropping into its existing gap returns no edit at all.
	move_to : Kanban.Listing, { title : Str, over : Kanban.Spot } -> List(Kanban.Edit)
	move_to = |cards, { title, over }| {
		card = Kanban.card_titled(cards, title) ?? return []
		target = match over {
			Nowhere => return []
			Before(other) => {
				row = Kanban.card_titled(cards, other) ?? return []
				{ column: row.column, place: row.place }
			}
			After(other) => {
				row = Kanban.card_titled(cards, other) ?? return []
				{ column: row.column, place: row.place + 1 }
			}
			EndOf(column) => { column, place: size_of(cards, column) }
		}
		at = Kanban.landing(card, target)
		if at.column == card.column and at.place == card.place {
			return []
		}
		cards.keep_oks(
			|held| {
				next = if held.key == title {
					{ ..held.row, column: at.column, place: at.place }
				} else {
					closed = if (held.row.column == card.column and held.row.place > card.place) held.row.place - 1 else held.row.place
					{ ..held.row, place: if (held.row.column == at.column and closed >= at.place) closed + 1 else closed }
				}
				if (next == held.row) Err(Unchanged) else Ok(Put(held.key, next))
			},
		)
	}

	## The cards the example starts with.
	initial_cards : Kanban.Listing
	initial_cards = [
		{ key: "Draft onboarding copy", row: { column: Backlog, place: 0, flags: 0 } },
		{ key: "Design login screen", row: { column: Backlog, place: 1, flags: 0 } },
		{ key: "Ship search filters", row: { column: InProgress, place: 0, flags: 0 } },
		{ key: "Audit billing events", row: { column: Review, place: 0, flags: 0 } },
		{ key: "Rotate API keys", row: { column: Done, place: 0, flags: 0 } },
	]

	## The card the board holds under `title`.
	card_titled : Kanban.Listing, Str -> Try(Kanban.Card, [NoSuchCard])
	card_titled = |cards, title|
		match cards.find_first(|held| held.key == title) {
			Ok(held) => Ok(held.row)
			Err(_) => Err(NoSuchCard)
		}

	## The titles of a column's cards, top to bottom: what its view draws
	## when nothing is filtered out.
	lane : Kanban.Listing, Kanban.Column -> List(Str)
	lane = |cards, column| {
		{ keep, sort, compare } = Kanban.plan({ column, filter: "" })
		cards
			.keep_if(|held| keep(held.key, held.row))
			.sort_with(|a, b| compare(sort(a.key, a.row), sort(b.key, b.row)))
			.map(|held| held.key)
	}

	## The edits that move a card to the neighbouring column: it lands at
	## the end of that column, and the cards that were below it move up one
	## place. A move past the edge of the board, or of a card the board does
	## not hold, is no edit.
	move_across : Kanban.Listing, { title : Str, toward : [Leftward, Rightward] } -> List(Kanban.Edit)
	move_across = |cards, { title, toward }|
		match Kanban.card_titled(cards, title) {
			Ok(card) => {
				neighbour = match toward {
					Leftward => Kanban.Column.left(card.column)
					Rightward => Kanban.Column.right(card.column)
				}
				match neighbour {
					Ok(column) => closing_gap(cards, card).append(Put(title, { ..card, column, place: size_of(cards, column) }))
					Err(AtEdge) => []
				}
			}
			Err(NoSuchCard) => []
		}

	## The edits that move a card one place up or down its own column, by
	## exchanging places with the card there. The first card cannot rise and
	## the last cannot fall: each is no edit.
	move_within : Kanban.Listing, { title : Str, toward : [Upward, Downward] } -> List(Kanban.Edit)
	move_within = |cards, { title, toward }|
		match Kanban.card_titled(cards, title) {
			Ok(card) =>
				match toward {
					Upward => if (card.place == 0) [] else exchanging(cards, { title, card, place: card.place - 1 })
					Downward => exchanging(cards, { title, card, place: card.place + 1 })
				}
			Err(NoSuchCard) => []
		}

	## The edits that delete a card: the cards that were below it in its
	## column move up one place.
	delete_card : Kanban.Listing, Str -> List(Kanban.Edit)
	delete_card = |cards, title|
		match Kanban.card_titled(cards, title) {
			Ok(card) => closing_gap(cards, card).append(Remove(title))
			Err(NoSuchCard) => []
		}

	## The edits that add a card titled by `draft` at the end of Backlog, or
	## no edit for a draft the add form does not accept.
	add_card : Kanban.Listing, Str -> List(Kanban.Edit)
	add_card = |cards, draft|
		match Kanban.add_status(draft, |title| Try.is_ok(Kanban.card_titled(cards, title))) {
			Ready => [Put(draft.trim(), { column: Backlog, place: size_of(cards, Backlog), flags: 0 })]
			_ => []
		}

	## A card flagged once more.
	flag_card : Kanban.Card -> Kanban.Card
	flag_card = |card| { ..card, flags: card.flags + 1 }

	## A listing with `edits` applied in order, as the app's table applies
	## them: what a test or a model holds a move to.
	edited : Kanban.Listing, List(Kanban.Edit) -> Kanban.Listing
	edited = |cards, edits| edits.fold(
		cards,
		|held, edit| match edit {
			Put(title, card) => held.drop_if(|one| one.key == title).append({ key: title, row: card })
			Remove(title) => held.drop_if(|one| one.key == title)
		},
	)

	## What the add form has to say about the current draft. The rendered sentence
	## and the tone it is drawn in both come off this one tag, so the line can
	## never be red while the button is enabled.
	AddStatus := [NeedsTitle, Duplicate, Ready].{
		is_eq : _

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

		## Whether the add form accepts the draft.
		is_ready : Kanban.AddStatus -> Bool
		is_ready = |status|
			match status {
				Ready => True
				_ => False
			}
	}

	## What the add form says about `draft`, on a board where `is_taken`
	## answers whether a card already has a title. The draft is judged
	## without the spaces around it, which is also the title it would add.
	add_status : Str, (Str -> Bool) -> Kanban.AddStatus
	add_status = |draft, is_taken| {
		title = draft.trim()
		if title.is_empty() {
			NeedsTitle
		} else if is_taken(title) {
			Duplicate
		} else {
			Ready
		}
	}

	## What a column shows: its own cards whose title contains `filter`, the
	## filter box's text without the spaces around it. An empty filter shows
	## every card of the column.
	Showing : { column : Kanban.Column, filter : Str }

	## Where a card stands in its column's order: its place, then its
	## title. While the edits of a move are applied one by one, two cards can
	## stand at one place for a moment, and the title tells them apart.
	Rank := { place : U64, title : Str }.{
		is_eq : _

		## Titles break position ties using the board's existing byte order.
		order_relative_to : Rank, Rank -> [Before, Same, After]
		order_relative_to = |left, right| match left.place.order_relative_to(right.place) {
			Same => title_order(left.title, right.title)
			other => other
		}
	}

	## How a column's view selects and orders the board's cards.
	plan : Kanban.Showing -> { keep : Str, Kanban.Card -> Bool, sort : Str, Kanban.Card -> Kanban.Rank, compare : Kanban.Rank, Kanban.Rank -> [Before, Same, After] }
	plan = |{ column, filter }| {
		keep: |title, card| card.column == column and Kanban.is_match({ title, filter }),
		sort: |title, card| { place: card.place, title },
		compare: Kanban.Rank.order_relative_to,
	}

	## Whether a title passes a filter: an empty filter passes every title.
	is_match : { title : Str, filter : Str } -> Bool
	is_match = |{ title, filter }| filter.is_empty() or title.contains(filter)

	## How many cards a column holds, and how many of them the filter shows.
	## Counts and the WIP limit go by `cards`, so filtering never hides a
	## column that is over its limit.
	Size : { cards : U64, shown : U64 }

	## The size of each column.
	Tally : { backlog : Kanban.Size, progress : Kanban.Size, review : Kanban.Size, done : Kanban.Size }

	## The tally of a board with no cards.
	empty_tally : Kanban.Tally
	empty_tally = { backlog: nothing, progress: nothing, review: nothing, done: nothing }

	## A tally with one more card counted: the step of a fold over the
	## board's cards. `filter` is a column's `Showing.filter`.
	counted : Kanban.Tally, { title : Str, card : Kanban.Card, filter : Str } -> Kanban.Tally
	counted = |tally, { title, card, filter }| {
		more = |size| { cards: size.cards + 1, shown: if (Kanban.is_match({ title, filter })) size.shown + 1 else size.shown }
		match card.column {
			Backlog => { ..tally, backlog: more(tally.backlog) }
			InProgress => { ..tally, progress: more(tally.progress) }
			Review => { ..tally, review: more(tally.review) }
			Done => { ..tally, done: more(tally.done) }
		}
	}

	## The size of one column.
	size_in : Kanban.Tally, Kanban.Column -> Kanban.Size
	size_in = |tally, column|
		match column {
			Backlog => tally.backlog
			InProgress => tally.progress
			Review => tally.review
			Done => tally.done
		}

	## How many cards the board holds.
	cards_held : Kanban.Tally -> U64
	cards_held = |tally| sizes(tally).fold(0, |sum, size| sum + size.cards)

	## How many cards the filter shows, over every column.
	cards_shown : Kanban.Tally -> U64
	cards_shown = |tally| sizes(tally).fold(0, |sum, size| sum + size.shown)

	## How many columns hold more cards than the limit allows.
	columns_over : Kanban.Tally, Kanban.Limit -> U64
	columns_over = |tally, limit| sizes(tally).count_if(|size| Kanban.WipState.is_over(Kanban.WipState.of(size.cards, limit)))

	## A WIP cap, or no cap at all. The absence of a limit is a tag rather than a
	## magic zero, so no reader has to remember what `0` means.
	Limit := [NoLimit, AtMost(U64)].{
		is_eq : _

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
		is_eq : _

		of : U64, Kanban.Limit -> Kanban.WipState
		of = |count, limit|
			match limit {
				NoLimit => Unlimited
				AtMost(cap) => if count > cap {
					Over(count, cap)
				} else {
					Within(count, cap)
				}
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
}

## A column with no cards.
nothing : Kanban.Size
nothing = { cards: 0, shown: 0 }

## The sizes of the columns, in board order.
sizes : Kanban.Tally -> List(Kanban.Size)
sizes = |tally| Kanban.all_columns.map(|column| Kanban.size_in(tally, column))

## How many cards a column holds.
size_of : Kanban.Listing, Kanban.Column -> U64
size_of = |cards, column| cards.count_if(|held| held.row.column == column)

## The edits that move every card below `gone` in its column up one place:
## what taking a card out of a column leaves to do.
closing_gap : Kanban.Listing, Kanban.Card -> List(Kanban.Edit)
closing_gap = |cards, gone|
	cards
		.keep_if(|held| held.row.column == gone.column and held.row.place > gone.place)
		.map(|held| Put(held.key, { ..held.row, place: held.row.place - 1 }))

## The edits that exchange the places of `card` and the card at `place` in
## its column, or no edit when the column has no card there.
exchanging : Kanban.Listing, { title : Str, card : Kanban.Card, place : U64 } -> List(Kanban.Edit)
exchanging = |cards, { title, card, place }|
	match cards.find_first(|held| held.row.column == card.column and held.row.place == place) {
		Ok(other) => [Put(title, { ..card, place }), Put(other.key, { ..other.row, place: card.place })]
		Err(_) => []
	}

## The byte order of two titles.
title_order : Str, Str -> [Before, Same, After]
title_order = |first, second| {
	a = first.to_utf8()
	b = second.to_utf8()
	match List.map2(a, b, |x, y| { x, y }).find_first(|pair| pair.x != pair.y) {
		Ok({ x, y }) => if (x < y) Before else After
		Err(_) => if (a.len() < b.len()) Before else if (a.len() > b.len()) After else Same
	}
}

## Every column's titles, in board order, each top to bottom: what the
## tests below compare.
lanes : Kanban.Listing -> List(List(Str))
lanes = |cards| Kanban.all_columns.map(|column| Kanban.lane(cards, column))

## The two-word column reads as a phrase with a space, not as its slug.
expect Kanban.Column.to_str(InProgress) == "In Progress"

## A column's spec-facing id fragment is a short single word, independent of its heading.
expect Kanban.Column.slug(InProgress) == "progress"

## Rightward from the leftmost column lands on the next column in board order.
expect Kanban.Column.right(Backlog) == Ok(InProgress)

## The rightmost column has no column to its right, so the board edge is reported.
expect Kanban.Column.right(Done) == Err(AtEdge)

## The leftmost column has no column to its left, so the board edge is reported.
expect Kanban.Column.left(Backlog) == Err(AtEdge)

## The starting board's columns, each top to bottom.
expect lanes(Kanban.initial_cards) == [["Draft onboarding copy", "Design login screen"], ["Ship search filters"], ["Audit billing events"], ["Rotate API keys"]]

## Moving a card rightward lands it at the end of the neighbouring column, and the card below it moves up.
expect {
	moved = Kanban.edited(Kanban.initial_cards, Kanban.move_across(Kanban.initial_cards, { title: "Draft onboarding copy", toward: Rightward }))
	actual =
		\\lanes: ${Str.inspect(lanes(moved))}
		\\moved: ${Str.inspect(Kanban.card_titled(moved, "Draft onboarding copy"))}
		\\left behind: ${Str.inspect(Kanban.card_titled(moved, "Design login screen"))}
	expected =
		\\lanes: [["Design login screen"], ["Ship search filters", "Draft onboarding copy"], ["Audit billing events"], ["Rotate API keys"]]
		\\moved: Ok({ column: InProgress, flags: 0, place: 1 })
		\\left behind: Ok({ column: Backlog, flags: 0, place: 0 })
	actual == expected
}

## A card in the leftmost column cannot move further left, so nothing is edited.
expect Kanban.move_across(Kanban.initial_cards, { title: "Draft onboarding copy", toward: Leftward }) == []

## A card in the rightmost column cannot move further right, so nothing is edited.
expect Kanban.move_across(Kanban.initial_cards, { title: "Rotate API keys", toward: Rightward }) == []

## Moving a card up exchanges its place with the card above it, and writes no other card.
expect Kanban.move_within(Kanban.initial_cards, { title: "Design login screen", toward: Upward }) == [Put("Design login screen", { column: Backlog, place: 0, flags: 0 }), Put("Draft onboarding copy", { column: Backlog, place: 1, flags: 0 })]

## The first card in a column cannot rise any further, so nothing is edited.
expect Kanban.move_within(Kanban.initial_cards, { title: "Draft onboarding copy", toward: Upward }) == []

## The last card in a column cannot fall any further, so nothing is edited.
expect Kanban.move_within(Kanban.initial_cards, { title: "Design login screen", toward: Downward }) == []

## Deleting a card moves the cards below it up one place.
expect {
	left = Kanban.edited(Kanban.initial_cards, Kanban.delete_card(Kanban.initial_cards, "Draft onboarding copy"))
	(Kanban.lane(left, Backlog), Kanban.card_titled(left, "Design login screen")) == (["Design login screen"], Ok({ column: Backlog, place: 0, flags: 0 }))
}

## An empty draft asks for a title rather than reporting a problem.
expect Kanban.add_status("   ", |_title| False) == NeedsTitle

## A draft matching an existing card title is reported as a duplicate.
expect Kanban.add_status("Design login screen", |title| title == "Design login screen") == Duplicate

## Surrounding whitespace is trimmed before the draft is judged, so a padded title is addable.
expect Kanban.add_status("  Write release notes  ", |_title| False) == Ready

## Adding an accepted draft puts its trimmed title at the end of Backlog.
expect Kanban.add_card(Kanban.initial_cards, "  Write release notes ") == [Put("Write release notes", { column: Backlog, place: 2, flags: 0 })]

## A duplicate or a blank draft adds nothing.
expect Kanban.add_card(Kanban.initial_cards, " Rotate API keys ").concat(Kanban.add_card(Kanban.initial_cards, "  ")) == []

## A column's size counts every card it holds, and separately those the filter shows.
expect {
	tally = Kanban.initial_cards.fold(Kanban.empty_tally, |counts, held| Kanban.counted(counts, { title: held.key, card: held.row, filter: "Design" }))
	actual =
		\\sizes: ${Str.inspect(sizes(tally))}
		\\held: ${Kanban.cards_held(tally).to_str()}
		\\shown: ${Kanban.cards_shown(tally).to_str()}
		\\over a limit of 1: ${Kanban.columns_over(tally, AtMost(1)).to_str()}
		\\over no limit: ${Kanban.columns_over(tally, NoLimit).to_str()}
	expected =
		\\sizes: [{ cards: 2, shown: 1 }, { cards: 1, shown: 0 }, { cards: 1, shown: 0 }, { cards: 1, shown: 0 }]
		\\held: 5
		\\shown: 1
		\\over a limit of 1: 1
		\\over no limit: 0
	actual == expected
}

## Two cards at one place are ordered by title, and a card is `Same` only as itself.
expect {
	{ compare, .. } = Kanban.plan({ column: Backlog, filter: "" })
	orders = [
		compare({ place: 0, title: "b" }, { place: 1, title: "a" }),
		compare({ place: 1, title: "a" }, { place: 1, title: "ab" }),
		compare({ place: 1, title: "b" }, { place: 1, title: "ab" }),
		compare({ place: 1, title: "ab" }, { place: 1, title: "ab" }),
	]
	orders == [Before, Before, After, Same]
}

## An empty limit box means the column is uncapped rather than capped at nothing.
expect Kanban.Limit.from_str("") == NoLimit

## Non-numeric text in the limit box is leniently read as no cap at all.
expect Kanban.Limit.from_str("abc") == NoLimit

## A partly numeric entry is rejected whole, not truncated to its leading digits.
expect Kanban.Limit.from_str("3x") == NoLimit

## A cap of zero is spelled as the absence of a limit, never as `AtMost(0)`.
expect Kanban.Limit.from_str("0") == NoLimit

## A padded number still parses to a cap at that many cards.
expect Kanban.Limit.from_str(" 3 ") == AtMost(3)

## An uncapped column says so instead of printing a count against a cap.
expect Kanban.WipState.to_str(Kanban.WipState.of(4, NoLimit)) == "No WIP limit"

## A column exactly at its cap is still within the limit, not over it.
expect Kanban.WipState.of(2, AtMost(2)) == Within(2, 2)

## A column past its cap changes the caption wording, not just the number.
expect Kanban.WipState.to_str(Kanban.WipState.of(3, AtMost(2))) == "Over 3/2"

## An over-limit column exposes the "over" marker the specs read.
expect Kanban.WipState.attr(Kanban.WipState.of(3, AtMost(2))) == "over"

## A column at exactly its cap still exposes the calm marker.
expect Kanban.WipState.attr(Kanban.WipState.of(2, AtMost(2))) == "ok"

## An uncapped column is marked as unlimited rather than as merely acceptable.
expect Kanban.WipState.attr(Kanban.WipState.of(2, NoLimit)) == "unlimited"

## No card count can put an uncapped column over its limit.
expect !Kanban.WipState.is_over(Kanban.WipState.of(1_000_000, NoLimit))

## Zone parsing is exact application vocabulary: card titles may contain
## colons, grips use their card, and unknown or empty names are nowhere.
expect {
	actual = [Kanban.Spot.from_zone("card:A:B", 4999), Kanban.Spot.from_zone("grip:A:B", 5000), Kanban.Spot.from_zone("lane:progress", 0), Kanban.Spot.from_zone("lane:nope", 0), Kanban.Spot.from_zone("card:", 0), Kanban.Spot.from_zone("", 0)]
	actual == [Before("A:B"), After("A:B"), EndOf(InProgress), Nowhere, Nowhere, Nowhere]
}

## Crossing lanes closes the source gap and inserts before the target,
## preserving every other card and its flags.
expect {
	starting = Kanban.initial_cards
	changes = Kanban.move_to(starting, { title: "Draft onboarding copy", over: Before("Ship search filters") })
	lanes(Kanban.edited(starting, changes)) == [["Design login screen"], ["Draft onboarding copy", "Ship search filters"], ["Audit billing events"], ["Rotate API keys"]]
}

## A reorder writes only the two changed rows, and either side of the
## dragged card itself is its existing gap, so neither gives an edit.
expect {
	starting = Kanban.initial_cards
	changes = Kanban.move_to(starting, { title: "Draft onboarding copy", over: After("Design login screen") })
	{
		lanes: lanes(Kanban.edited(starting, changes)),
		written: changes.len(),
		own_before: Kanban.move_to(starting, { title: "Draft onboarding copy", over: Before("Draft onboarding copy") }),
		own_after: Kanban.move_to(starting, { title: "Draft onboarding copy", over: After("Draft onboarding copy") }),
		outside: Kanban.move_to(starting, { title: "Draft onboarding copy", over: Nowhere }),
	} == {
		lanes: [["Design login screen", "Draft onboarding copy"], ["Ship search filters"], ["Audit billing events"], ["Rotate API keys"]],
		written: 2,
		own_before: [],
		own_after: [],
		outside: [],
	}
}
