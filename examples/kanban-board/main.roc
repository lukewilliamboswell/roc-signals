app [main] { pf: platform "https://github.com/lukewilliamboswell/roc-signals/releases/download/0.1/3eLQGNMDG9RuL9sn1A7ep1Rtq7QGmemE89y141WSv1XG.tar.zst" }

import pf.Elem exposing [Elem]
import pf.Html
import pf.Signal
import pf.Ui

# ---------------------------------------------------------------------------
# Domain
# ---------------------------------------------------------------------------

## A board card. The title is the durable identity used as the keyed-list key,
## so a card keeps its row scope through reorder and filter operations.
Card : { title : Str, column : Str, flags : U64 }

## Board editing state: the cards plus the new-card draft that the add reducer
## has to read. Everything the board displays about the cards is derived.
Board : { cards : List(Card), draft : Str }

## Presentation record for one card inside one column. Position and boundary
## facts are derived here so a row never has to know about its siblings.
CardView : {
	title : Str,
	column : Str,
	flags : U64,
	position : U64,
	total : U64,
	is_first : Bool,
	is_last : Bool,
	can_left : Bool,
	can_right : Bool,
}

backlog = "Backlog"

progress = "In Progress"

review = "Review"

done = "Done"

last_column_index : U64
last_column_index = 3

column_index : Str -> U64
column_index = |name|
	if name == backlog {
		0
	} else if name == progress {
		1
	} else if name == review {
		2
	} else {
		3
	}

column_at : U64 -> Str
column_at = |index|
	if index == 0 {
		backlog
	} else if index == 1 {
		progress
	} else if index == 2 {
		review
	} else {
		done
	}

## Stable, spec-facing id fragment for a column. Ids are derived from this so
## an assertion never has to spell out a rendered value.
column_slug : Str -> Str
column_slug = |name|
	if name == backlog {
		"backlog"
	} else if name == progress {
		"progress"
	} else if name == review {
		"review"
	} else {
		"done"
	}

initial_board : Board
initial_board = {
	cards: [
		{ title: "Draft onboarding copy", column: backlog, flags: 0 },
		{ title: "Design login screen", column: backlog, flags: 0 },
		{ title: "Ship search filters", column: progress, flags: 0 },
		{ title: "Audit billing events", column: review, flags: 0 },
		{ title: "Rotate API keys", column: done, flags: 0 },
	],
	draft: "",
}

cards_in : List(Card), Str -> List(Card)
cards_in = |cards, column| cards.keep_if(|card| card.column == column)

## Regroup the flat card list by column while preserving the relative order of
## each column's cards. Every mutation ends with this so list order and board
## order are the same thing.
canonical : List(Card) -> List(Card)
canonical = |cards|
	cards_in(cards, backlog)
		.concat(cards_in(cards, progress))
		.concat(cards_in(cards, review))
		.concat(cards_in(cards, done))

find_card : List(Card), Str -> [Found(Card), Missing]
find_card = |cards, title|
	match cards.keep_if(|card| card.title == title).first() {
		Ok(card) => Found(card)
		Err(_) => Missing
	}

index_of : List(Card), Str -> U64
index_of = |cards, title|
	match cards.map_with_index(|card, index| { index, card }).keep_if(|entry| entry.card.title == title).first() {
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

## Move a card to the neighbouring column, landing at the end of that column.
move_across : Board, Str, Bool -> Board
move_across = |board, title, rightward|
	match find_card(board.cards, title) {
		Found(card) => {
			index = column_index(card.column)
			if rightward and index >= last_column_index {
				board
			} else if (!rightward) and index == 0 {
				board
			} else {
				target = if rightward { index + 1 } else { index - 1 }
				moved = { ..card, column: column_at(target) }
				{ ..board, cards: canonical(drop_card(board.cards, title).append(moved)) }
			}
		}
		Missing => board
	}

## Move a card one slot up or down inside its own column.
move_within : Board, Str, Bool -> Board
move_within = |board, title, upward|
	match find_card(board.cards, title) {
		Found(card) => {
			group = cards_in(board.cards, card.column)
			position = index_of(group, title)
			total = group.len()
			if upward and position == 0 {
				board
			} else if (!upward) and position + 1 >= total {
				board
			} else {
				target = if upward { position - 1 } else { position + 1 }
				regrouped = insert_at(drop_card(group, title), target, card)
				others = board.cards.keep_if(|item| item.column != card.column)
				{ ..board, cards: canonical(others.concat(regrouped)) }
			}
		}
		Missing => board
	}

flag_card : Board, Str -> Board
flag_card = |board, title| {
	..board,
	cards: board.cards.map(|card| if card.title == title { { ..card, flags: card.flags + 1 } } else { card }),
}

delete_card : Board, Str -> Board
delete_card = |board, title| { ..board, cards: drop_card(board.cards, title) }

add_status : Board -> Str
add_status = |board| {
	title = board.draft.trim()
	if title.is_empty() {
		"Enter a title"
	} else if !board.cards.keep_if(|card| card.title == title).is_empty() {
		"Duplicate title"
	} else {
		"Ready"
	}
}

can_add : Board -> Bool
can_add = |board| add_status(board) == "Ready"

add_card : Board -> Board
add_card = |board|
	if can_add(board) {
		{
			cards: canonical(board.cards.append({ title: board.draft.trim(), column: backlog, flags: 0 })),
			draft: "",
		}
	} else {
		board
	}

## Build the per-column presentation records, including boundary facts.
column_views : List(Card), Str -> List(CardView)
column_views = |group, column| {
	total = group.len()
	index = column_index(column)
	group.map_with_index(
		|card, position| {
			title: card.title,
			column,
			flags: card.flags,
			position: position + 1,
			total,
			is_first: position == 0,
			is_last: position + 1 == total,
			can_left: index > 0,
			can_right: index < last_column_index,
		},
	)
}

## The WIP limit comes from a text draft. Empty or non-numeric input means
## "unlimited", modelled as 0.
parse_limit : Str -> U64
parse_limit = |raw| {
	text = raw.trim()
	if text.is_empty() {
		0
	} else {
		digits = text.to_utf8()
		if !digits.keep_if(|byte| byte < 48 or byte > 57).is_empty() {
			0
		} else {
			digits.fold(0, |acc, byte| acc * 10 + U8.to_u64(byte - 48))
		}
	}
}

limit_text : U64, U64 -> Str
limit_text = |count, limit|
	if limit == 0 {
		"WIP: ${count.to_str()} - unlimited"
	} else if count > limit {
		"WIP: ${count.to_str()} of ${limit.to_str()} - over limit"
	} else {
		"WIP: ${count.to_str()} of ${limit.to_str()} - within limit"
	}

limit_state : U64, U64 -> Str
limit_state = |count, limit|
	if limit == 0 {
		"unlimited"
	} else if count > limit {
		"over"
	} else {
		"ok"
	}

matches_filter : CardView, Str -> Bool
matches_filter = |view, query| if query.is_empty() { True } else { view.title.contains(query) }

# ---------------------------------------------------------------------------
# Styling
# ---------------------------------------------------------------------------

page_class = "grid gap-5"

hero_class = "panel grid gap-2 p-5"

panel_class = "panel grid gap-4 p-4"

board_class = "grid gap-4 md:grid-cols-4"

column_class = "panel grid gap-3 p-4"

card_class = "panel grid gap-2 p-3"

toolbar_class = "flex flex-wrap items-center gap-3"

input_class = "w-full max-w-xs rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm"

# ---------------------------------------------------------------------------
# Card row
# ---------------------------------------------------------------------------

## One card. Everything the row shows comes from the row's own
## `Signal(CardView)`; the row itself stores nothing.
render_card : Ui.State(Board), Str, Signal.Signal(CardView) -> Elem
render_card = |board, key, view| {
	position_text = Signal.map(view, |item| "Position ${item.position.to_str()} of ${item.total.to_str()} in ${item.column}")
	flags_text = Signal.map(view, |item| "Flags: ${item.flags.to_str()}")
	left_disabled = Signal.map(view, |item| !item.can_left)
	right_disabled = Signal.map(view, |item| !item.can_right)
	up_disabled = Signal.map(view, |item| item.is_first)
	down_disabled = Signal.map(view, |item| item.is_last)

	Html.section(
		key,
		[Html.class_attr(card_class), Html.attr("data-card", key)],
		[
			Html.heading_c(key, "text-base font-semibold text-zinc-950"),
			Html.paragraph_s_attrs(position_text, [Html.class_attr("text-sm text-zinc-700"), Html.test_id("card-position-${key}")]),
			Html.paragraph_s_attrs(flags_text, [Html.class_attr("text-sm text-zinc-700"), Html.test_id("card-flags-${key}")]),
			Html.div_c(
				toolbar_class,
				[
					Html.action_button_c(Signal.const("Move left: ${key}"), left_disabled, "button", board.on_unit(|state| move_across(state, key, False))),
					Html.action_button_c(Signal.const("Move right: ${key}"), right_disabled, "button", board.on_unit(|state| move_across(state, key, True))),
					Html.action_button_c(Signal.const("Move up: ${key}"), up_disabled, "button", board.on_unit(|state| move_within(state, key, True))),
					Html.action_button_c(Signal.const("Move down: ${key}"), down_disabled, "button", board.on_unit(|state| move_within(state, key, False))),
					Html.button_c("Flag: ${key}", "button", board.on_unit(|state| flag_card(state, key))),
					Html.button_c("Delete: ${key}", "button", board.on_unit(|state| delete_card(state, key))),
				],
			),
		],
	)
}

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
}

## Derive one column's signals from the shared card list, the filter text, and
## the parsed WIP limit. Nothing here is stored.
column_signals : Signal.Signal(List(Card)), Signal.Signal(Str), Signal.Signal(U64), Str -> ColumnSignals
column_signals = |cards, query, limit, column| {
	group = Signal.map(cards, |list| cards_in(list, column))
	all_views = Signal.map(group, |list| column_views(list, column))

	# Fan-in: column membership x filter text.
	views = Signal.map2(all_views, query, |list, text| list.keep_if(|item| matches_filter(item, text)))

	count = Signal.map(group, |list| list.len())
	matching = Signal.map(views, |list| list.len())

	# Fan-in: derived column count x parsed WIP limit.
	over = Signal.map2(count, limit, |value, cap| cap > 0 and value > cap)
	limit_line = Signal.map2(count, limit, limit_text)
	state_attr = Signal.map2(count, limit, limit_state)

	{ views, count, matching, over, limit_line, state_attr }
}

render_column : Ui.State(Board), Str, ColumnSignals -> Elem
render_column = |board, column, signals| {
	slug = column_slug(column)
	count_text = Signal.map(signals.count, |value| "Count: ${value.to_str()}")
	matching_text = Signal.map(signals.matching, |value| "Matching: ${value.to_str()}")
	empty_text = Signal.map(signals.matching, |value| if value == 0 { "No cards shown" } else { "Showing cards" })

	Html.section(
		column,
		[Html.class_attr(column_class), Html.attr_s("data-wip", signals.state_attr)],
		[
			Html.heading_c(column, "text-lg font-semibold text-zinc-950"),
			Html.paragraph_s_attrs(count_text, [Html.class_attr("text-sm font-medium text-zinc-900"), Html.test_id("count-${slug}")]),
			Html.paragraph_s_attrs(matching_text, [Html.class_attr("text-sm text-zinc-700"), Html.test_id("matching-${slug}")]),
			Html.paragraph_s_attrs(signals.limit_line, [Html.class_attr("text-sm font-medium text-zinc-900"), Html.test_id("wip-${slug}")]),
			Html.paragraph_s_attrs(empty_text, [Html.class_attr("text-sm text-zinc-600"), Html.test_id("empty-${slug}")]),
			Ui.each_str(signals.views, |item| item.title, |key, item| render_card(board, key, item)),
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
							status_text = Signal.map(board_signal, add_status)
							add_disabled = Signal.map(board_signal, |state| !can_add(state))
							total_text = Signal.map(cards_signal, |list| "Board total: ${list.len().to_str()} cards")

							query = Signal.map(filter.signal(), |text| text.trim())
							limit = Signal.map(wip.signal(), parse_limit)

							backlog_signals = column_signals(cards_signal, query, limit, backlog)
							progress_signals = column_signals(cards_signal, query, limit, progress)
							review_signals = column_signals(cards_signal, query, limit, review)
							done_signals = column_signals(cards_signal, query, limit, done)

							# Fan-in across all four columns, two hops above the card list.
							matching_parts =
								{
									backlog: backlog_signals.matching,
									progress: progress_signals.matching,
									review: review_signals.matching,
									done: done_signals.matching,
								}.Signal
							matching_total =
								Signal.map(
									matching_parts,
									|parts| "Matching cards: ${(parts.backlog + parts.progress + parts.review + parts.done).to_str()}",
								)

							over_parts =
								{
									backlog: backlog_signals.over,
									progress: progress_signals.over,
									review: review_signals.over,
									done: done_signals.over,
								}.Signal
							over_count = Signal.map(over_parts, |parts| [parts.backlog, parts.progress, parts.review, parts.done].keep_if(|flag| flag).len())
							over_total = Signal.map(over_count, |count| "Columns over WIP: ${count.to_str()}")
							any_over = Signal.map(over_count, |count| count > 0)

							Html.div_c(
								page_class,
								[
									Html.section_c(
										"Kanban Board",
										hero_class,
										[
											Html.heading_c("Kanban Board", "text-3xl font-semibold text-zinc-950"),
											Html.paragraph_c("Move cards across columns, reorder within a column, filter by title, and watch derived per-column counts and WIP limits.", "max-w-3xl text-sm text-zinc-700"),
										],
									),
									Html.section_c(
										"Board controls",
										panel_class,
										[
											Html.div_c(
												toolbar_class,
												[
													Html.text_input_c("Filter cards", filter.signal(), input_class, filter.on_str(|_, value| value)),
													Html.number_input_c("WIP limit", wip.signal(), input_class, wip.on_str(|_, value| value)),
													Html.text_input_c("New card title", draft_signal, input_class, board.on_str(|state, value| { ..state, draft: value })),
													Html.action_button_c(Signal.const("Add card"), add_disabled, "button-primary", board.on_unit(|state| add_card(state))),
												],
											),
											Html.paragraph_s_attrs(status_text, [Html.class_attr("text-sm font-medium text-zinc-900"), Html.test_id("add-status")]),
										],
									),
									Html.section_c(
										"Board summary",
										panel_class,
										[
											Html.paragraph_s_attrs(total_text, [Html.class_attr("text-sm font-medium text-zinc-900"), Html.test_id("board-total")]),
											Html.paragraph_s_attrs(matching_total, [Html.class_attr("text-sm font-medium text-zinc-900"), Html.test_id("board-matching")]),
											Html.paragraph_s_attrs(over_total, [Html.class_attr("text-sm font-medium text-zinc-900"), Html.test_id("board-over")]),
											Ui.when(
												any_over,
												|| Html.paragraph_c("WIP warning: rebalance the board", "text-sm font-medium text-red-950"),
												|| Html.paragraph_c("WIP status: every column is within its limit", "text-sm text-emerald-700"),
											),
										],
									),
									Html.div_c(
										board_class,
										[
											render_column(board, backlog, backlog_signals),
											render_column(board, progress, progress_signals),
											render_column(board, review, review_signals),
											render_column(board, done, done_signals),
										],
									),
								],
							)
						},
					),
			),
	)
