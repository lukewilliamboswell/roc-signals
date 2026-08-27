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

## The WIP caption is what the column badge says, so it is short enough to sit
## on the header line beside the column title.
limit_text : U64, U64 -> Str
limit_text = |count, limit|
	if limit == 0 {
		"No WIP limit"
	} else if count > limit {
		"Over ${count.to_str()}/${limit.to_str()}"
	} else {
		"WIP ${count.to_str()}/${limit.to_str()}"
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

## Badge tone follows the same two inputs as the caption, so a column can never
## show "Over" in the calm colour.
wip_badge_class : U64, U64 -> Str
wip_badge_class = |count, limit|
	if limit == 0 {
		"badge badge-neutral shrink-0"
	} else if count > limit {
		"badge badge-danger shrink-0"
	} else {
		"badge badge-ok shrink-0"
	}

## The add-status line is a neutral requirement until there is a draft that
## cannot be accepted; only then does it turn red.
add_status_class : Board -> Str
add_status_class = |board| {
	status = add_status(board)
	if status == "Ready" {
		"text-xs font-medium text-emerald-700"
	} else if status == "Duplicate title" {
		"text-xs font-medium text-red-600"
	} else {
		"hint"
	}
}

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
	position_text = Signal.map(view, |item| "${item.position.to_str()} of ${item.total.to_str()} in ${item.column}")
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
					icon_button("←", "Move left: ${key}", icon_class, left_disabled, board.on_unit(|state| move_across(state, key, False))),
					icon_button("→", "Move right: ${key}", icon_class, right_disabled, board.on_unit(|state| move_across(state, key, True))),
					icon_button("↑", "Move up: ${key}", icon_class, up_disabled, board.on_unit(|state| move_within(state, key, True))),
					icon_button("↓", "Move down: ${key}", icon_class, down_disabled, board.on_unit(|state| move_within(state, key, False))),
					icon_button("⚑", "Flag: ${key}", icon_class, Signal.const(False), board.on_unit(|state| flag_card(state, key))),
					icon_button("✕", "Delete: ${key}", delete_icon_class, Signal.const(False), board.on_unit(|state| delete_card(state, key))),
				],
			),
		],
	)
}

## A square action: a glyph on screen, a descriptive accessible name for the
## specs and for screen readers. The event-message type is platform-internal and
## has no public name, so the argument is spelled `_`.
icon_button : Str, Str, Str, Signal.Signal(Bool), _ -> Elem
icon_button = |glyph, label, classes, disabled, msg|
	Html.action_button_attrs(
		Signal.const(glyph),
		disabled,
		[Html.attr("type", "button"), Html.aria_label(label), Html.attr("title", label), Html.class_attr(classes)],
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

	# The badge tone comes off the same fan-in as its caption, so a column can
	# never show "Over" in the calm colour.
	badge_class = Signal.map2(count, limit, wip_badge_class)

	{ views, count, matching, over, limit_line, state_attr, badge_class }
}

render_column : Ui.State(Board), Str, ColumnSignals -> Elem
render_column = |board, column, signals| {
	slug = column_slug(column)
	count_text = Signal.map(signals.count, |value| if value == 1 { "1 card" } else { "${value.to_str()} cards" })
	matching_text = Signal.map(signals.matching, |value| "${value.to_str()} shown")
	is_empty = Signal.map(signals.matching, |value| value == 0)

	Html.section(
		column,
		[Html.class_attr(column_class), Html.attr_s("data-wip", signals.state_attr)],
		[
			Html.div_c(
				"panel-head",
				[
					Html.div_c(
						"flex min-w-0 items-baseline gap-2",
						[
							Html.heading_c(column, "card-title"),
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
					Ui.each_str(signals.views, |item| item.title, |key, item| render_card(board, key, item)),
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
							status_text = Signal.map(board_signal, add_status)
							status_class = Signal.map(board_signal, add_status_class)
							add_disabled = Signal.map(board_signal, |state| !can_add(state))
							total_value = Signal.map(cards_signal, |list| list.len().to_str())

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
