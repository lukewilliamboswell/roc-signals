app [main] { pf: platform "../../platform/main.roc" }

import pf.Elem exposing [Elem]
import pf.Html
import pf.Rows
import pf.Signal
import pf.Ui

# ---------------------------------------------------------------------------
# Domain
# ---------------------------------------------------------------------------

## The four board columns. They are a closed set with a fixed left-to-right
## order, so they are a tag union rather than a name string compared against a
## ladder of literals. `to_str` is the heading a reader sees and `slug` is the
## stable id fragment the specs assert on.
Column := [Backlog, InProgress, Review, Done].{
	is_eq : Column, Column -> Bool
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
	to_str : Column -> Str
	to_str = |column|
		match column {
			Backlog => "Backlog"
			InProgress => "In Progress"
			Review => "Review"
			Done => "Done"
		}

	## Stable, spec-facing id fragment for a column. Ids are derived from this
	## so an assertion never has to spell out a rendered value.
	slug : Column -> Str
	slug = |column|
		match column {
			Backlog => "backlog"
			InProgress => "progress"
			Review => "review"
			Done => "done"
		}

	## The neighbouring column, or `Err(AtEdge)` at the ends of the board. The
	## board's edges live here, so no caller has to know an index bound.
	left : Column -> Try(Column, [AtEdge])
	left = |column|
		match column {
			Backlog => Err(AtEdge)
			InProgress => Ok(Backlog)
			Review => Ok(InProgress)
			Done => Ok(Review)
		}

	right : Column -> Try(Column, [AtEdge])
	right = |column|
		match column {
			Backlog => Ok(InProgress)
			InProgress => Ok(Review)
			Review => Ok(Done)
			Done => Err(AtEdge)
		}
}

## Board order, left to right. Every regroup walks this list, so adding a
## column is a one-line change here plus a new tag.
all_columns : List(Column)
all_columns = [Backlog, InProgress, Review, Done]

## The two-word column reads as a phrase with a space, not as its slug.
expect Column.to_str(InProgress) == "In Progress"
## A column's spec-facing id fragment is a short single word, independent of its heading.
expect Column.slug(InProgress) == "progress"
## Rightward from the leftmost column lands on the next column in board order.
expect Column.right(Backlog) == Ok(InProgress)
## The rightmost column has no column to its right, so the board edge is reported.
expect Column.right(Done) == Err(AtEdge)
## The leftmost column has no column to its left, so the board edge is reported.
expect Column.left(Backlog) == Err(AtEdge)
## The board lists its four columns once, in left-to-right order.
expect all_columns.map(Column.slug) == ["backlog", "progress", "review", "done"]

## A board card. The title is the durable identity used as the keyed-list key,
## so a card keeps its row scope through reorder and filter operations.
Card : { title : Str, column : Column, flags : U64 }

## Board editing state: the cards plus the new-card draft that the add reducer
## has to read. Everything the board displays about the cards is derived.
Board : { cards : List(Card), draft : Str }

## Presentation record for one card inside one column. Position and boundary
## facts are derived here so a row never has to know about its siblings.
CardView : {
	title : Str,
	column : Column,
	flags : U64,
	position : U64,
	total : U64,
	is_first : Bool,
	is_last : Bool,
	can_left : Bool,
	can_right : Bool,
}

initial_board : Board
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

cards_in : List(Card), Column -> List(Card)
cards_in = |cards, column| cards.keep_if(|card| card.column == column)

## Regroup the flat card list by column while preserving the relative order of
## each column's cards. Every mutation ends with this so list order and board
## order are the same thing.
canonical : List(Card) -> List(Card)
canonical = |cards| all_columns.fold([], |acc, column| acc.concat(cards_in(cards, column)))

find_card : List(Card), Str -> Try(Card, [NotFound])
find_card = |cards, title| cards.find_first(|card| card.title == title)

index_of : List(Card), Str -> U64
index_of = |cards, title|
	match cards.map_with_index(|card, index| { index, card }).find_first(|entry| entry.card.title == title) {
		Ok(entry) => entry.index
		Err(_) => 0
	}

insert_at : List(Card), U64, Card -> List(Card)
insert_at = |cards, position, card| {
	entries = cards.map_with_index(|item, index| { index, card: item })
	front = entries.keep_if(|entry| entry.index < position).map(|entry| entry.card)
	back = entries.keep_if(|entry| entry.index >= position).map(|entry| entry.card)
	front.append(card).concat(back)
}

drop_card : List(Card), Str -> List(Card)
drop_card = |cards, title| cards.keep_if(|card| card.title != title)

## The starting board is already grouped by column, so regrouping leaves it untouched.
expect canonical(initial_board.cards).map(|card| card.title) == initial_board.cards.map(|card| card.title)
## Regrouping sorts cards into board order regardless of their position in the flat list.
expect canonical([{ title: "b", column: Done, flags: 0 }, { title: "a", column: Backlog, flags: 0 }]).map(|card| card.title) == ["a", "b"]

## Move a card to the neighbouring column, landing at the end of that column.
## A move at the edge of the board is a no-op, which is what `Column.left` and
## `Column.right` report by returning `Err(AtEdge)`.
move_across : Board, Str, [Leftward, Rightward] -> Board
move_across = |board, title, direction|
	match find_card(board.cards, title) {
		Ok(card) => {
			target = match direction {
				Leftward => Column.left(card.column)
				Rightward => Column.right(card.column)
			}
			match target {
				Ok(column) => {
					moved = { ..card, column }
					{ ..board, cards: canonical(drop_card(board.cards, title).append(moved)) }
				}
				Err(AtEdge) => board
			}
		}
		Err(_) => board
	}

## Move a card one slot up or down inside its own column.
move_within : Board, Str, [Upward, Downward] -> Board
move_within = |board, title, direction|
	match find_card(board.cards, title) {
		Ok(card) => {
			group = cards_in(board.cards, card.column)
			position = index_of(group, title)
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
				regrouped = insert_at(drop_card(group, title), target, card)
				others = board.cards.keep_if(|item| item.column != card.column)
				{ ..board, cards: canonical(others.concat(regrouped)) }
			}
		}
		Err(_) => board
	}

## Moving a card rightward lands it at the end of the neighbouring column.
expect move_across(initial_board, "Draft onboarding copy", Rightward).cards.map(|card| card.column) == [Backlog, InProgress, InProgress, Review, Done]
## A card in the leftmost column cannot move further left, so the board is unchanged.
expect move_across(initial_board, "Draft onboarding copy", Leftward) == initial_board
## A card in the rightmost column cannot move further right, so the board is unchanged.
expect move_across(initial_board, "Rotate API keys", Rightward) == initial_board
## Moving a card up swaps it past the card above it inside its own column.
expect move_within(initial_board, "Design login screen", Upward).cards.map(|card| card.title).first() == Ok("Design login screen")
## The first card in a column cannot rise any further, so the board is unchanged.
expect move_within(initial_board, "Draft onboarding copy", Upward) == initial_board

flag_card : Board, Str -> Board
flag_card = |board, title| {
	..board,
	cards: board.cards.map(|card| if card.title == title { { ..card, flags: card.flags + 1 } } else { card }),
}

delete_card : Board, Str -> Board
delete_card = |board, title| { ..board, cards: drop_card(board.cards, title) }

## What the add form has to say about the current draft. The rendered sentence
## and the tone it is drawn in both come off this one tag, so the line can
## never be red while the button is enabled.
AddStatus := [NeedsTitle, Duplicate, Ready].{
	is_eq : AddStatus, AddStatus -> Bool
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

	to_str : AddStatus -> Str
	to_str = |status|
		match status {
			NeedsTitle => "Enter a title"
			Duplicate => "Duplicate title"
			Ready => "Ready"
		}

	## The status line is a neutral requirement until there is a draft worth
	## commenting on; only a duplicate turns it red.
	class : AddStatus -> Str
	class = |status|
		match status {
			NeedsTitle => "hint"
			Duplicate => "text-xs font-medium text-red-600"
			Ready => "text-xs font-medium text-emerald-700"
		}

	accepts : AddStatus -> Bool
	accepts = |status|
		match status {
			Ready => True
			_ => False
		}
}

add_status : Board -> AddStatus
add_status = |board| {
	title = board.draft.trim()
	if title.is_empty() {
		NeedsTitle
	} else if !board.cards.keep_if(|card| card.title == title).is_empty() {
		Duplicate
	} else {
		Ready
	}
}

can_add : Board -> Bool
can_add = |board| AddStatus.accepts(add_status(board))

add_card : Board -> Board
add_card = |board|
	if can_add(board) {
		{
			cards: canonical(board.cards.append({ title: board.draft.trim(), column: Backlog, flags: 0 })),
			draft: "",
		}
	} else {
		board
	}

## An empty draft asks for a title rather than reporting a problem.
expect AddStatus.to_str(add_status(initial_board)) == "Enter a title"
## A draft matching an existing card title is reported as a duplicate.
expect AddStatus.to_str(add_status({ ..initial_board, draft: "Rotate API keys" })) == "Duplicate title"
## Surrounding whitespace is trimmed before the draft is judged, so a padded title is addable.
expect can_add({ ..initial_board, draft: "  Write release notes  " })
## Adding an accepted draft grows the board by exactly one card.
expect add_card({ ..initial_board, draft: " Write release notes " }).cards.len() == 6

## Build the per-column presentation records, including boundary facts.
column_views : List(Card), Column -> List(CardView)
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
			can_left: Try.is_ok(Column.left(column)),
			can_right: Try.is_ok(Column.right(column)),
		},
	)
}

## A WIP cap, or no cap at all. The absence of a limit is a tag rather than a
## magic zero, so no reader has to remember what `0` meant.
Limit := [NoLimit, AtMost(U64)].{
	is_eq : Limit, Limit -> Bool
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
	from_str : Str -> Limit
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
	is_eq : WipState, WipState -> Bool
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

	of : U64, Limit -> WipState
	of = |count, limit|
		match limit {
			NoLimit => Unlimited
			AtMost(cap) => if count > cap { Over(count, cap) } else { Within(count, cap) }
		}

	## The badge caption, short enough to sit on the header line beside the
	## column title.
	to_str : WipState -> Str
	to_str = |state|
		match state {
			Unlimited => "No WIP limit"
			Within(count, cap) => "WIP ${count.to_str()}/${cap.to_str()}"
			Over(count, cap) => "Over ${count.to_str()}/${cap.to_str()}"
		}

	## The `data-wip` attribute the specs read.
	attr : WipState -> Str
	attr = |state|
		match state {
			Unlimited => "unlimited"
			Within(_, _) => "ok"
			Over(_, _) => "over"
		}

	class : WipState -> Str
	class = |state|
		match state {
			Unlimited => "badge badge-neutral shrink-0"
			Within(_, _) => "badge badge-ok shrink-0"
			Over(_, _) => "badge badge-danger shrink-0"
		}

	is_over : WipState -> Bool
	is_over = |state|
		match state {
			Over(_, _) => True
			_ => False
		}
}

## An empty limit box means the column is uncapped rather than capped at nothing.
expect Limit.from_str("") == NoLimit
## Non-numeric text in the limit box is leniently read as no cap at all.
expect Limit.from_str("abc") == NoLimit
## A partly numeric entry is rejected whole, not truncated to its leading digits.
expect Limit.from_str("12x3") == NoLimit
## A cap of zero is spelled as the absence of a limit, never as `AtMost(0)`.
expect Limit.from_str("0") == NoLimit
## A padded number still parses to a cap at that many cards.
expect Limit.from_str(" 3 ") == AtMost(3)

## An uncapped column says so instead of printing a count against a cap.
expect WipState.to_str(WipState.of(2, NoLimit)) == "No WIP limit"
## A column exactly at its cap is still within the limit, not over it.
expect WipState.to_str(WipState.of(2, AtMost(2))) == "WIP 2/2"
## A column past its cap changes the caption wording, not just the number.
expect WipState.to_str(WipState.of(2, AtMost(1))) == "Over 2/1"
## An over-limit column exposes the "over" marker the specs read.
expect WipState.attr(WipState.of(2, AtMost(1))) == "over"
## A column at exactly its cap still exposes the calm marker.
expect WipState.attr(WipState.of(2, AtMost(2))) == "ok"
## An uncapped column is marked as unlimited rather than as merely acceptable.
expect WipState.attr(WipState.of(2, NoLimit)) == "unlimited"
## No card count can put an uncapped column over its limit.
expect !WipState.is_over(WipState.of(9, NoLimit))

matches_filter : CardView, Str -> Bool
matches_filter = |view, query| if query.is_empty() { True } else { view.title.contains(query) }

# ---------------------------------------------------------------------------
# Styling
# ---------------------------------------------------------------------------

page_class = "app-shell app-shell-wide"

panel_class = "panel grid gap-4 p-5"

board_class = "grid gap-4 md:grid-cols-2 xl:grid-cols-4"

column_class = "panel min-w-0"

card_class = "card min-w-0"

input_class = "input"

## Card actions are single glyphs. The descriptive phrase lives in
## `Html.aria_label`, which is what screen readers and the specs read.
icon_class = "button button-sm w-8 justify-center px-0"

# The delete control sits apart from the four move controls, so a narrow
# column breaks the row there rather than orphaning it.
delete_icon_class = "button-danger button-sm w-8 justify-center px-0 ml-auto"

# ---------------------------------------------------------------------------
# Card row
# ---------------------------------------------------------------------------

## One card. Everything the row shows comes from the row's own
## `Signal(CardView)`; the row itself stores nothing.
render_card : Ui.State(Board), Str, Signal.Signal(CardView) -> Elem
render_card = |board, key, view| {
	position_text = Signal.map(view, |item| "${item.position.to_str()} of ${item.total.to_str()} in ${Column.to_str(item.column)}")
	flags_text = Signal.map(view, |item| if item.flags == 1 { "1 flag" } else { "${item.flags.to_str()} flags" })
	flagged = Signal.map(view, |item| item.flags > 0)
	left_disabled = Signal.map(view, |item| !item.can_left)
	right_disabled = Signal.map(view, |item| !item.can_right)
	up_disabled = Signal.map(view, |item| item.is_first)
	down_disabled = Signal.map(view, |item| item.is_last)

	Html.section(
		key,
		[Html.class_attr(card_class), Html.attr("data-card", key)],
		[
			Html.div_c(
				"flex items-start justify-between gap-2",
				[
					Html.heading_c(key, "card-title min-w-0"),
					# An unflagged card says nothing; the badge appears the moment
					# there is something to report.
					Ui.when(
						flagged,
						|| Html.paragraph_s_attrs(flags_text, [Html.class_attr("badge badge-warn shrink-0"), Html.test_id("card-flags-${key}")]),
						|| Html.text(""),
					),
				],
			),
			Html.paragraph_s_attrs(position_text, [Html.class_attr("hint numeric"), Html.test_id("card-position-${key}")]),
			Html.div_c(
				"flex items-center gap-1",
				[
					icon_button({ glyph: "←", label: "Move left: ${key}", classes: icon_class }, left_disabled, board.on_unit(|state| move_across(state, key, Leftward))),
					icon_button({ glyph: "→", label: "Move right: ${key}", classes: icon_class }, right_disabled, board.on_unit(|state| move_across(state, key, Rightward))),
					icon_button({ glyph: "↑", label: "Move up: ${key}", classes: icon_class }, up_disabled, board.on_unit(|state| move_within(state, key, Upward))),
					icon_button({ glyph: "↓", label: "Move down: ${key}", classes: icon_class }, down_disabled, board.on_unit(|state| move_within(state, key, Downward))),
					icon_button({ glyph: "⚑", label: "Flag: ${key}", classes: icon_class }, Signal.const(False), board.on_unit(|state| flag_card(state, key))),
					icon_button({ glyph: "✕", label: "Delete: ${key}", classes: delete_icon_class }, Signal.const(False), board.on_unit(|state| delete_card(state, key))),
				],
			),
		],
	)
}

## A square action: a glyph on screen, a descriptive accessible name for the
## specs and for screen readers. The three strings are named in a record so a
## call site cannot silently transpose the glyph, the label and the classes.
## The event-message type is platform-internal and has no public name, so the
## argument is spelled `_`.
icon_button : { glyph : Str, label : Str, classes : Str }, Signal.Signal(Bool), _ -> Elem
icon_button = |look, disabled, msg|
	Html.action_button_attrs(
		Signal.const(look.glyph),
		disabled,
		[Html.attr("type", "button"), Html.aria_label(look.label), Html.attr("title", look.label), Html.class_attr(look.classes)],
		msg,
	)

# ---------------------------------------------------------------------------
# Column
# ---------------------------------------------------------------------------

ColumnSignals : {
	views : Signal.Signal(List(CardView)),
	count : Signal.Signal(U64),
	matching : Signal.Signal(U64),
	over : Signal.Signal(Bool),
	limit_line : Signal.Signal(Str),
	state_attr : Signal.Signal(Str),
	badge_class : Signal.Signal(Str),
}

## Derive one column's signals from the shared card list, the filter text, and
## the parsed WIP limit. Nothing here is stored.
column_signals : Signal.Signal(List(Card)), Signal.Signal(Str), Signal.Signal(Limit), Column -> ColumnSignals
column_signals = |cards, query, limit, column| {
	group = Signal.map(cards, |list| cards_in(list, column))
	all_views = Signal.map(group, |list| column_views(list, column))

	# Fan-in: column membership x filter text.
	views = Signal.map2(all_views, query, |list, text| list.keep_if(|item| matches_filter(item, text)))

	count = Signal.map(group, |list| list.len())
	matching = Signal.map(views, |list| list.len())

	# Fan-in: derived column count x parsed WIP limit. Everything the header
	# says about the limit hangs off this one derived tag, so the caption, the
	# attribute and the badge tone cannot disagree.
	wip = Signal.map2(count, limit, WipState.of)
	over = Signal.map(wip, WipState.is_over)
	limit_line = Signal.map(wip, WipState.to_str)
	state_attr = Signal.map(wip, WipState.attr)
	badge_class = Signal.map(wip, WipState.class)

	{ views, count, matching, over, limit_line, state_attr, badge_class }
}

render_column : Ui.State(Board), Column, ColumnSignals -> Elem
render_column = |board, column, signals| {
	slug = Column.slug(column)
	heading = Column.to_str(column)
	count_text = Signal.map(signals.count, |value| if value == 1 { "1 card" } else { "${value.to_str()} cards" })
	matching_text = Signal.map(signals.matching, |value| "${value.to_str()} shown")
	is_empty = Signal.map(signals.matching, |value| value == 0)

	Html.section(
		heading,
		[Html.class_attr(column_class), Html.attr_s("data-wip", signals.state_attr)],
		[
			Html.div_c(
				"panel-head",
				[
					Html.div_c(
						"flex min-w-0 items-baseline gap-2",
						[
							Html.heading_c(heading, "card-title"),
							Html.paragraph_s_attrs(count_text, [Html.class_attr("hint numeric"), Html.test_id("count-${slug}")]),
						],
					),
					Html.paragraph_s_attrs(signals.limit_line, [Html.class_attr_s(signals.badge_class), Html.test_id("wip-${slug}")]),
				],
			),
			Html.div_c(
				"panel-body",
				[
					Html.paragraph_s_attrs(matching_text, [Html.class_attr("hint numeric"), Html.test_id("matching-${slug}")]),
					Ui.each(Signal.map(signals.views, |rows_items| Rows.from_list(rows_items, |item| item.title) ?? crash "duplicate row key"), |each_row| render_card(board, each_row.key(), each_row.signal())),
					# The dashed box exists only while there is nothing to show, so
					# there is no hidden copy of it behind a populated column.
					Ui.when(
						is_empty,
						|| Html.paragraph_attrs("No cards", [Html.class_attr("empty-state"), Html.test_id("empty-${slug}")]),
						|| Html.text(""),
					),
				],
			),
		],
	)
}

# ---------------------------------------------------------------------------
# Page
# ---------------------------------------------------------------------------

main : () -> Elem
main = ||
	Ui.state(
		initial_board,
		|board|
			Ui.state(
				"",
				|filter|
					Ui.state(
						"1",
						|wip| {
							board_signal = board.signal()
							cards_signal = Signal.map(board_signal, |state| state.cards)
							draft_signal = Signal.map(board_signal, |state| state.draft)
							status = Signal.map(board_signal, add_status)
							status_text = Signal.map(status, AddStatus.to_str)
							status_class = Signal.map(status, AddStatus.class)
							add_disabled = Signal.map(board_signal, |state| !can_add(state))
							total_value = Signal.map(cards_signal, |list| list.len().to_str())

							query = Signal.map(filter.signal(), |text| text.trim())
							limit = Signal.map(wip.signal(), Limit.from_str)

							backlog_signals = column_signals(cards_signal, query, limit, Backlog)
							progress_signals = column_signals(cards_signal, query, limit, InProgress)
							review_signals = column_signals(cards_signal, query, limit, Review)
							done_signals = column_signals(cards_signal, query, limit, Done)

							# Fan-in across all four columns, two hops above the card list.
							matching_parts =
								{
									backlog: backlog_signals.matching,
									progress: progress_signals.matching,
									review: review_signals.matching,
									done: done_signals.matching,
								}.Signal
							matching_count = Signal.map(matching_parts, |parts| parts.backlog + parts.progress + parts.review + parts.done)
							matching_value = Signal.map(matching_count, |value| value.to_str())

							over_parts =
								{
									backlog: backlog_signals.over,
									progress: progress_signals.over,
									review: review_signals.over,
									done: done_signals.over,
								}.Signal
							over_count = Signal.map(over_parts, |parts| [parts.backlog, parts.progress, parts.review, parts.done].keep_if(|flag| flag).len())
							over_value = Signal.map(over_count, |count| count.to_str())
							any_over = Signal.map(over_count, |count| count > 0)

							Html.div_c(
								page_class,
								[
									Html.section_c(
										"Kanban Board",
										"app-header",
										[
											Html.heading_c("Kanban Board", "app-title"),
											Html.paragraph_c("Move cards across columns, reorder within a column, filter by title, and watch derived per-column counts and WIP limits.", "app-subtitle"),
										],
									),
									Html.section_c(
										"Board controls",
										panel_class,
										[
											Html.div_c(
												"toolbar",
												[
													labelled_field(
														"Filter cards",
														"min-w-0 flex-1 basis-56",
														Html.text_input_attrs(
															"Filter cards",
															filter.signal(),
															[Html.class_attr(input_class), Html.attr("placeholder", "Search titles, e.g. billing")],
															filter.on_str(|_, value| value),
														),
													),
													labelled_field(
														"WIP limit",
														"w-28 shrink-0",
														Html.number_input_attrs(
															"WIP limit",
															wip.signal(),
															[Html.class_attr(input_class), Html.attr("placeholder", "3"), Html.attr("min", "0")],
															wip.on_str(|_, value| value),
														),
													),
													labelled_field(
														"New card title",
														"min-w-0 flex-1 basis-56",
														Html.text_input_attrs(
															"New card title",
															draft_signal,
															[Html.class_attr(input_class), Html.attr("placeholder", "Write release notes")],
															board.on_str(|state, value| { ..state, draft: value }),
														),
													),
													Html.action_button_attrs(
														Signal.const("Add card"),
														add_disabled,
														[Html.attr("type", "button"), Html.class_attr("button-primary shrink-0")],
														board.on_unit(|state| add_card(state)),
													),
												],
											),
											Html.paragraph_s_attrs(status_text, [Html.class_attr_s(status_class), Html.test_id("add-status")]),
										],
									),
									Html.section_c(
										"Board summary",
										panel_class,
										[
											Html.div_c(
												"stat-grid",
												[
													stat_tile("Board total", total_value, "board-total"),
													stat_tile("Matching filter", matching_value, "board-matching"),
													stat_tile("Columns over WIP", over_value, "board-over"),
												],
											),
											# The warning is only drawn when a column is actually over its
											# limit; a board within its limits says nothing at all.
											Ui.when(
												any_over,
												|| Html.paragraph_c("Rebalance the board: at least one column is over its WIP limit.", "notice notice-warn"),
												|| Html.text(""),
											),
										],
									),
									Html.div_c(
										board_class,
										[
											render_column(board, Backlog, backlog_signals),
											render_column(board, InProgress, progress_signals),
											render_column(board, Review, review_signals),
											render_column(board, Done, done_signals),
										],
									),
								],
							)
						},
					),
			),
	)

# ---------------------------------------------------------------------------
# View helpers
# ---------------------------------------------------------------------------

## A labelled control. `Html.text_input_attrs`' first argument is only the
## accessible name, so the visible caption is drawn here.
labelled_field : Str, Str, Elem -> Elem
labelled_field = |label, classes, control|
	Html.div_c(
		"field ${classes}",
		[
			Html.paragraph_c(label, "field-label"),
			control,
		],
	)

## One metric tile: a caption and the figure it names. The test id sits on the
## figure, which is the element a reader actually sees.
stat_tile : Str, Signal.Signal(Str), Str -> Elem
stat_tile = |label, value, id|
	Html.div_c(
		"stat",
		[
			Html.paragraph_c(label, "stat-label"),
			Html.paragraph_s_attrs(value, [Html.class_attr("stat-value"), Html.test_id(id)]),
		],
	)
