app [main] { pf: platform "https://github.com/lukewilliamboswell/roc-signals/releases/download/0.1/3eLQGNMDG9RuL9sn1A7ep1Rtq7QGmemE89y141WSv1XG.tar.zst" }

import pf.Elem exposing [Elem]
import pf.Html
import pf.Signal
import pf.Ui

Column : {
	id : Str,
	title : Str,
	limit : U64,
}

Card : {
	id : Str,
	title : Str,
	owner : Str,
	priority : Str,
	tags : List(Str),
	estimate : U64,
	status : Str,
	notes : U64,
	note_markdown : Str,
}

DragState := [Idle, Dragging(Str)].{
	is_eq : DragState, DragState -> Bool
	is_eq = |left, right|
		match left {
			Idle => match right {
				Idle => True
				Dragging(_) => False
			}
			Dragging(left_id) => match right {
				Idle => False
				Dragging(right_id) => left_id == right_id
			}
		}
}

HoverBeforeTarget : {
	column_id : Str,
	before_id : Str,
}

HoverState := [NoHover, HoverEnd(Str), HoverBefore(HoverBeforeTarget)].{
	is_eq : HoverState, HoverState -> Bool
	is_eq = |left, right|
		match left {
			NoHover => match right {
				NoHover => True
				_ => False
			}
			HoverEnd(left_column) => match right {
				HoverEnd(right_column) => left_column == right_column
				_ => False
			}
			HoverBefore(left_target) => match right {
				HoverBefore(right_target) => left_target == right_target
				_ => False
			}
		}
}

Board : {
	cards : List(Card),
	dragging : DragState,
	hover : HoverState,
	reviewer : Str,
	focus_high_priority : Bool,
	editing_card : Str,
}

MarkdownListItem : {
	key : Str,
	text : Str,
}

MarkdownBlock : {
	key : Str,
	kind : Str,
	text : Str,
	items : List(MarkdownListItem),
}

InlineSegment : {
	key : Str,
	kind : Str,
	text : Str,
	href : Str,
}

InlineState : {
	segments : List(InlineSegment),
	index : U64,
}

MarkdownState : {
	blocks : List(MarkdownBlock),
	index : U64,
}

backlog_id = "backlog"

ready_id = "ready"

progress_id = "progress"

review_id = "review"

done_id = "done"

design_note = "## Signal graph note\nBuild **signal graph** evidence before the public guide update.\n- Mount scopes\n- Dirty queue\n[Design docs](/docs/guide/)\n[Blocked script](javascript:alert)"

platform_note = "## Platform glue note\nKeep `roc_ui_mount` and `roc_ui_update` contracts aligned.\n- Native ABI\n- Wasm ABI\n[Runtime checklist](/docs/guide/)"

diff_note = "## Diff budget note\nMeasure **row reuse** before adding drag sugar.\n- Move existing rows\n- Avoid rebuilds"

browser_note = "## Browser runtime note\nExercise `prevent_default` and controlled text before release."

event_note = "## Event payload note\nDocument [event payloads](/docs/guide/) and block [unsafe links](javascript:alert)."

structural_note = "## Structural budget note\nKeep the spec metrics readable for reviewers."

docs_note = "## Host contract note\nPublish the command and signal lifecycle summary."

columns : List(Column)
columns = [
	{ id: backlog_id, title: "Backlog", limit: 6 },
	{ id: progress_id, title: "In Progress", limit: 3 },
	{ id: done_id, title: "Done", limit: 99 },
]

initial_cards : List(Card)
initial_cards = [
	{
		id: "CARD-101",
		title: "Design signal graph",
		owner: "Mara",
		priority: "High",
		tags: ["signals", "engine"],
		estimate: 5,
		status: backlog_id,
		notes: 0,
		note_markdown: design_note,
	},
	{
		id: "CARD-102",
		title: "Write platform glue",
		owner: "Noah",
		priority: "Medium",
		tags: ["wasm", "abi"],
		estimate: 3,
		status: backlog_id,
		notes: 0,
		note_markdown: platform_note,
	},
	{
		id: "CARD-103",
		title: "Tune keyed diff",
		owner: "Ada",
		priority: "High",
		tags: ["ui.each", "metrics"],
		estimate: 2,
		status: backlog_id,
		notes: 0,
		note_markdown: diff_note,
	},
	{
		id: "CARD-201",
		title: "QA browser runtime",
		owner: "Ilya",
		priority: "Low",
		tags: ["browser", "events"],
		estimate: 2,
		status: progress_id,
		notes: 0,
		note_markdown: browser_note,
	},
	{
		id: "CARD-301",
		title: "Model drag payloads",
		owner: "Sam",
		priority: "High",
		tags: ["events", "state"],
		estimate: 4,
		status: progress_id,
		notes: 0,
		note_markdown: event_note,
	},
	{
		id: "CARD-401",
		title: "Review structural budgets",
		owner: "Rin",
		priority: "Medium",
		tags: ["spec", "metrics"],
		estimate: 1,
		status: progress_id,
		notes: 0,
		note_markdown: structural_note,
	},
	{
		id: "CARD-501",
		title: "Document host contract",
		owner: "Lee",
		priority: "Low",
		tags: ["docs"],
		estimate: 1,
		status: done_id,
		notes: 0,
		note_markdown: docs_note,
	},
]

initial_board : Board
initial_board = {
	cards: initial_cards,
	dragging: Idle,
	hover: NoHover,
	reviewer: "",
	focus_high_priority: False,
	editing_card: "CARD-101",
}

page_class = "grid min-h-screen gap-5 bg-zinc-100 text-zinc-950"

toolbar_class = "panel grid gap-4 p-5"

toolbar_top_class = "grid gap-3 lg:grid-cols-3"

toolbar_title_class = "grid gap-1 lg:col-span-2"

eyebrow_class = "text-xs font-semibold uppercase text-emerald-700"

toolbar_copy_class = "text-sm text-zinc-600"

metric_grid_class = "grid gap-2 sm:grid-cols-3"

metric_card_class = "panel grid gap-1 bg-zinc-50 p-3"

metric_label_class = "text-xs font-semibold uppercase text-zinc-500"

metric_value_class = "text-lg font-semibold text-zinc-950"

controls_class = "grid gap-3 sm:flex sm:flex-wrap sm:items-end"

board_class = "grid gap-4 xl:grid-cols-3"

column_class = "panel grid min-h-32 content-start gap-3 bg-zinc-50 p-3"

column_heading_class = "text-sm font-semibold text-zinc-950"

column_summary_class = "text-xs font-medium uppercase text-zinc-500"

card_base_class = "panel grid cursor-grab select-none touch-none gap-3 p-4 text-left transition hover:border-zinc-400"

card_drag_class = "panel grid cursor-grabbing select-none touch-none gap-3 border-emerald-500 bg-emerald-50 p-4 text-left"

card_hover_class = "panel grid cursor-grab select-none touch-none gap-3 border-sky-500 bg-sky-50 p-4 text-left"

drop_zone_class = "select-none touch-none border border-dashed border-zinc-300 bg-white p-4 text-center text-sm font-medium text-zinc-500"

drop_zone_active_class = "select-none touch-none border border-dashed border-emerald-500 bg-emerald-50 p-4 text-center text-sm font-semibold text-emerald-800"

card_header_class = "grid gap-1"

card_title_class = "text-sm font-semibold leading-5 text-zinc-950"

card_id_class = "text-xs font-semibold uppercase text-zinc-500"

card_meta_grid_class = "grid gap-2 sm:grid-cols-2"

card_meta_class = "text-xs text-zinc-600"

card_tag_class = "text-xs font-medium text-emerald-700"

card_footer_class = "grid gap-2 border-t border-zinc-100 pt-3 sm:flex sm:flex-wrap sm:items-center sm:justify-between"

note_text_class = "text-xs font-medium text-zinc-500"

note_button_class = "button"

note_editor_class = "panel grid gap-3 bg-white p-4"

markdown_view_class = "grid gap-2 text-sm text-zinc-700"

markdown_quote_class = "border-l-2 border-emerald-500 pl-3 text-zinc-700"

markdown_code_class = "rounded bg-zinc-100 px-1 py-0.5 font-mono text-xs text-zinc-950"

markdown_link_class = "font-medium text-emerald-700 underline"

textarea_class = "min-w-0 min-h-32 w-full rounded-md border border-zinc-300 bg-white px-3 py-2 font-mono text-sm"

button_class = "button"

primary_button_class = "button-primary"

input_class = "min-w-0 w-full max-w-md rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm"

column_title : Str -> Str
column_title = |column_id| match columns.find_first(|column| column.id == column_id) {
	Ok(column) => column.title
	Err(_) => column_id
}

card_title : List(Card), Str -> Str
card_title = |cards, card_id| match cards.find_first(|card| card.id == card_id) {
	Ok(card) => card.title
	Err(_) => card_id
}

join_tags : List(Str) -> Str
join_tags = |tags| Str.join_with(tags, ", ")

block_key : U64, Str -> Str
block_key = |index, kind| "b:${index.to_str()}:${kind}"

item_key : U64 -> Str
item_key = |index| "i:${index.to_str()}"

segment_key : U64, Str -> Str
segment_key = |index, kind| "s:${index.to_str()}:${kind}"

empty_inline_state : InlineState
empty_inline_state = { segments: [], index: 0 }

append_segment : InlineState, Str, Str, Str -> InlineState
append_segment = |state, kind, text, href| {
	if text.is_empty() {
		state
	} else {
		{
			segments: state.segments.append({ key: segment_key(state.index, kind), kind, text, href }),
			index: state.index + 1,
		}
	}
}

safe_href : Str -> Bool
safe_href = |href| {
	href.starts_with("https://")
		or href.starts_with("http://")
			or href.starts_with("/")
				or href.starts_with("#")
					or href.starts_with("mailto:")
}

parse_link_inline : InlineState, Str -> InlineState
parse_link_inline = |state, text| {
	match text.find_first("[") {
		Ok(open) =>
			match open.after.find_first("](") {
				Ok(label_split) =>
					match label_split.after.find_first(")") {
						Ok(href_split) => {
							before_state = parse_inline_into(state, open.before)
							link_state =
								if safe_href(href_split.before) {
									append_segment(before_state, "link", label_split.before, href_split.before)
								} else {
									append_segment(before_state, "text", label_split.before, "")
								}
							parse_inline_into(link_state, href_split.after)
						}
						Err(_) => append_segment(state, "text", text, "")
					}
				Err(_) => append_segment(state, "text", text, "")
			}
		Err(_) => append_segment(state, "text", text, "")
	}
}

parse_code_inline : InlineState, Str -> InlineState
parse_code_inline = |state, text| {
	match text.find_first("`") {
		Ok(open) =>
			match open.after.find_first("`") {
				Ok(close) => {
					before_state = parse_inline_into(state, open.before)
					code_state = append_segment(before_state, "code", close.before, "")
					parse_inline_into(code_state, close.after)
				}
				Err(_) => append_segment(state, "text", text, "")
			}
		Err(_) => parse_link_inline(state, text)
	}
}

parse_strong_inline : InlineState, Str -> InlineState
parse_strong_inline = |state, text| {
	match text.find_first("**") {
		Ok(open) =>
			match open.after.find_first("**") {
				Ok(close) => {
					before_state = parse_inline_into(state, open.before)
					strong_state = append_segment(before_state, "strong", close.before, "")
					parse_inline_into(strong_state, close.after)
				}
				Err(_) => append_segment(state, "text", text, "")
			}
		Err(_) => parse_code_inline(state, text)
	}
}

parse_inline_into : InlineState, Str -> InlineState
parse_inline_into = |state, text| {
	if text.is_empty() {
		state
	} else {
		parse_strong_inline(state, text)
	}
}

inline_segments : Str -> List(InlineSegment)
inline_segments = |text| parse_inline_into(empty_inline_state, text).segments

append_block : MarkdownState, Str, Str, List(MarkdownListItem) -> MarkdownState
append_block = |state, kind, text, items| {
	{
		blocks: state.blocks.append({ key: block_key(state.index, kind), kind, text, items }),
		index: state.index + 1,
	}
}

parse_markdown_line : MarkdownState, Str -> MarkdownState
parse_markdown_line = |state, line| {
	trimmed = line.trim()
	if trimmed.is_empty() {
		state
	} else if trimmed.starts_with("## ") {
		append_block(state, "heading", trimmed.drop_prefix("## "), [])
	} else if trimmed.starts_with("# ") {
		append_block(state, "heading", trimmed.drop_prefix("# "), [])
	} else if trimmed.starts_with("> ") {
		append_block(state, "quote", trimmed.drop_prefix("> "), [])
	} else if trimmed.starts_with("- ") {
		append_block(
			state,
			"list",
			trimmed.drop_prefix("- "),
			[],
		)
	} else {
		append_block(state, "paragraph", trimmed, [])
	}
}

parse_markdown : Str -> List(MarkdownBlock)
parse_markdown = |source| {
	source.split_on("\n").fold({ blocks: [], index: 0 }, parse_markdown_line).blocks
}

inline_plain_text : Str -> Str
inline_plain_text = |source| Str.join_with(inline_segments(source).map(|segment| segment.text), "")

inline_view : Signal.Signal(Str) -> Elem
inline_view = |source| {
	segments = source.map(inline_segments)
	Elem.Element({ tag: "span", attrs: [], children: [Ui.each_str(segments, |segment| segment.key, render_inline_segment)] })
}

render_inline_segment : Str, Signal.Signal(InlineSegment) -> Elem
render_inline_segment = |key, segment| {
	text = segment.map(|value| value.text)
	href = segment.map(|value| value.href)
	if key.ends_with(":strong") {
		Elem.Element({ tag: "strong", attrs: [], children: [Html.text_s(text)] })
	} else if key.ends_with(":code") {
		Elem.Element({ tag: "code", attrs: [Html.class_attr(markdown_code_class)], children: [Html.text_s(text)] })
	} else if key.ends_with(":link") {
		Elem.Element(
			{
				tag: "a",
				attrs: [
					Html.attr_s("href", href),
					Html.test_id(key),
					Html.class_attr(markdown_link_class),
				],
				children: [Html.text_s(text)],
			},
		)
	} else {
		Html.text_s(text)
	}
}

render_list_item : Str, Signal.Signal(MarkdownListItem) -> Elem
render_list_item = |_, item| {
	text = item.map(|value| value.text)
	Elem.Element({ tag: "li", attrs: [], children: [inline_view(text)] })
}

render_markdown_block : Str, Signal.Signal(MarkdownBlock) -> Elem
render_markdown_block = |key, block| {
	text = block.map(|value| value.text)
	if key.ends_with(":heading") {
		Elem.Element({ tag: "h3", attrs: [Html.class_attr(card_title_class)], children: [Html.text_s(text)] })
	} else if key.ends_with(":quote") {
		Elem.Element({ tag: "blockquote", attrs: [Html.class_attr(markdown_quote_class)], children: [inline_view(text)] })
	} else if key.ends_with(":list") {
		Elem.Element(
			{
				tag: "ul",
				attrs: [Html.class_attr("list-disc pl-5")],
				children: [
					Elem.Element({ tag: "li", attrs: [], children: [inline_view(text)] }),
				],
			},
		)
	} else {
		Elem.Element({ tag: "p", attrs: [], children: [inline_view(text)] })
	}
}

markdown_view : Signal.Signal(Str), Str -> Elem
markdown_view = |source, classes| {
	blocks = source.map(parse_markdown)
	Html.div([Html.class_attr(classes)], [Ui.each_str(blocks, |block| block.key, render_markdown_block)])
}

priority_visible : Bool, Card -> Bool
priority_visible = |focus_high_priority, card|
	if focus_high_priority {
		card.priority == "High"
	} else {
		True
	}

column_cards : Board, Str -> List(Card)
column_cards = |board, column_id| board.cards.keep_if(
	|card| (card.status == column_id) and priority_visible(board.focus_high_priority, card),
)

visible_cards : Board -> List(Card)
visible_cards = |board| board.cards.keep_if(|card| priority_visible(board.focus_high_priority, card))

visible_card_count : Board -> U64
visible_card_count = |board| visible_cards(board).len()

visible_estimate : Board -> U64
visible_estimate = |board| visible_cards(board).fold(0, |total, card| total + card.estimate)

column_summary : Board, Column -> Str
column_summary = |board, column| {
	count_str = column_cards(board, column.id).len().to_str()
	if column.id == done_id {
		"${count_str} completed"
	} else {
		"${count_str} / ${column.limit.to_str()} cards"
	}
}

drag_status_text : Board -> Str
drag_status_text = |board| {
	match board.dragging {
		Idle => "Board ready"
		Dragging(card_id) => {
			title = card_title(board.cards, card_id)
			match board.hover {
				NoHover => "Dragging ${title}"
				HoverEnd(column_id) => "Dragging ${title} over ${column_title(column_id)}"
				HoverBefore(target) => {
					before_title = card_title(board.cards, target.before_id)
					"Dragging ${title} before ${before_title} in ${column_title(target.column_id)}"
				}
			}
		}
	}
}

reviewer_text : Board -> Str
reviewer_text = |board| {
	if board.reviewer == "" {
		"No reviewer assigned"
	} else {
		"Reviewing with ${board.reviewer}"
	}
}

focus_text : Board -> Str
focus_text = |board| {
	if board.focus_high_priority {
		"High priority focus"
	} else {
		"All priorities"
	}
}

visible_cards_text : Board -> Str
visible_cards_text = |board| "${visible_card_count(board).to_str()} cards"

visible_points_text : Board -> Str
visible_points_text = |board| "${visible_estimate(board).to_str()} points"

done_cards_text : Board -> Str
done_cards_text = |board| "${column_cards(board, done_id).len().to_str()} done"

start_drag : Board, Str -> Board
start_drag = |board, card_id| { ..board, dragging: Dragging(card_id), hover: NoHover }

cancel_drag : Board -> Board
cancel_drag = |board| { ..board, dragging: Idle, hover: NoHover }

hover_end : Board, Str -> Board
hover_end = |board, column_id| match board.dragging {
	Idle => board
	Dragging(_) => { ..board, hover: HoverEnd(column_id) }
}

hover_before : Board, Str, Str -> Board
hover_before = |board, column_id, before_id| match board.dragging {
	Idle => board
	Dragging(card_id) => if card_id == before_id
		{ ..board, hover: NoHover }
	else
		{ ..board, hover: HoverBefore({ column_id, before_id }) }
}

clear_hover : Board -> Board
clear_hover = |board| { ..board, hover: NoHover }

increment_card_notes : Board, Str -> Board
increment_card_notes = |board, card_id| {
	..board,
	cards: board.cards.map(|card| if card.id == card_id { ..card, notes: card.notes + 1 } else card),
}

select_note_card : Board, Str -> Board
select_note_card = |board, card_id| { ..board, editing_card: card_id }

update_selected_note : Board, Str -> Board
update_selected_note = |board, value| {
	..board,
	cards: board.cards.map(
		|card|
			if card.id == board.editing_card {
				{ ..card, note_markdown: value }
			} else {
				card
			},
	),
}

selected_card : Board -> Card
selected_card = |board| {
	match board.cards.find_first(|card| card.id == board.editing_card) {
		Ok(card) => card
		Err(_) => {
			match board.cards.first() {
				Ok(card) => card
				Err(_) => {
					id: "",
					title: "No card selected",
					owner: "",
					priority: "",
					tags: [],
					estimate: 0,
					status: backlog_id,
					notes: 0,
					note_markdown: "",
				}
			}
		}
	}
}

selected_note_markdown : Board -> Str
selected_note_markdown = |board| selected_card(board).note_markdown

selected_note_title : Board -> Str
selected_note_title = |board| "Editing notes for ${selected_card(board).title}"

insert_before : List(Card), Card, Str -> List(Card)
insert_before = |cards, moved, before_id| {
	state =
		cards.fold(
			{ output: [], inserted: False },
			|acc, card| {
				if (!acc.inserted) and card.id == before_id {
					{
						output: acc.output.append(moved).append(card),
						inserted: True,
					}
				} else {
					{
						output: acc.output.append(card),
						inserted: acc.inserted,
					}
				}
			},
		)

	if state.inserted {
		state.output
	} else {
		state.output.append(moved)
	}
}

move_dragging_card : Board, HoverState -> Board
move_dragging_card = |board, target| {
	match board.dragging {
		Idle => board
		Dragging(card_id) => {
			match board.cards.find_first(|card| card.id == card_id) {
				Ok(card) => {
					without_card = board.cards.keep_if(|candidate| candidate.id != card_id)
					next_cards =
						match target {
							NoHover => board.cards
							HoverEnd(column_id) => without_card.append({ ..card, status: column_id })
							HoverBefore(drop_target) => {
								if card_id == drop_target.before_id {
									board.cards
								} else {
									insert_before(without_card, { ..card, status: drop_target.column_id }, drop_target.before_id)
								}
							}
						}

					{ ..board, cards: next_cards, dragging: Idle, hover: NoHover }
				}
				Err(_) => cancel_drag(board)
			}
		}
	}
}

drop_on_end : Board, Str -> Board
drop_on_end = |board, column_id| move_dragging_card(board, HoverEnd(column_id))

drop_before : Board, Str, Str -> Board
drop_before = |board, column_id, before_id| move_dragging_card(board, HoverBefore({ column_id, before_id }))

card_class : Board, Card -> Str
card_class = |board, card| {
	match board.dragging {
		Dragging(card_id) => if card_id == card.id {
			card_drag_class
		} else {
			match board.hover {
				HoverBefore(target) => if target.before_id == card.id {
					card_hover_class
				} else {
					card_base_class
				}
				_ => card_base_class
			}
		}
		Idle => card_base_class
	}
}

drop_zone_class_for : Board, Str -> Str
drop_zone_class_for = |board, column_id| {
	match board.hover {
		HoverEnd(active_column) => if active_column == column_id {
			drop_zone_active_class
		} else {
			drop_zone_class
		}
		_ => drop_zone_class
	}
}

card_meta_text : Card -> Str
card_meta_text = |card| "${card.owner} owns ${card.id} - ${card.priority} priority - ${card.estimate.to_str()} points"

card_status_text : Card -> Str
card_status_text = |card| "Column: ${column_title(card.status)}"

card_priority_text : Card -> Str
card_priority_text = |card| "${card.priority} priority"

card_estimate_text : Card -> Str
card_estimate_text = |card| "${card.estimate.to_str()} pts"

card_tags_text : Card -> Str
card_tags_text = |card| "Tags: ${join_tags(card.tags)}"

note_label : Card -> Str
note_label = |card| "Notes on ${card.title}: ${card.notes.to_str()}"

note_button : Ui.State(Board), Str, Str -> Elem
note_button = |board_state, card_id, label| {
	stop_drag = board_state.on_unit(|board| board)

	Html.button_attrs(
		label,
		[
			Html.class_attr(note_button_class),
			Html.on_event("pointerdown", Html.event_policy_stop_propagation, stop_drag),
			Html.on_event("pointerup", Html.event_policy_stop_propagation, stop_drag),
		],
		board_state.on_unit(|board| increment_card_notes(board, card_id)),
	)
}

edit_note_button : Ui.State(Board), Str, Str -> Elem
edit_note_button = |board_state, card_id, label| {
	stop_drag = board_state.on_unit(|board| board)

	Html.button_attrs(
		label,
		[
			Html.class_attr(note_button_class),
			Html.on_event("pointerdown", Html.event_policy_stop_propagation, stop_drag),
			Html.on_event("pointerup", Html.event_policy_stop_propagation, stop_drag),
		],
		board_state.on_unit(|board| select_note_card(board, card_id)),
	)
}

render_note_editor : Ui.State(Board), Signal.Signal(Board) -> Elem
render_note_editor = |board, board_signal| {
	title = board_signal.map(selected_note_title)
	note = board_signal.map(selected_note_markdown)
	Html.section_c(
		"Note editor",
		note_editor_class,
		[
			Html.paragraph_s_c(title, "text-sm font-semibold text-zinc-950"),
			Html.textarea_c("Note markdown", note, textarea_class, board.on_str(update_selected_note)),
			Html.section_c(
				"Rendered note preview",
				markdown_view_class,
				[
					markdown_view(note, markdown_view_class),
				],
			),
		],
	)
}

render_card : Ui.State(Board), Str, Str, Signal.Signal(Card) -> Elem
render_card = |board_state, column_id, card_id, card_signal| {
	board_signal = board_state.signal()
	class_inputs = { board: board_signal, card: card_signal }.Signal
	class_signal = class_inputs.map(|inputs| card_class(inputs.board, inputs.card))
	title_signal = card_signal.map(|card| card.title)
	meta_signal = card_signal.map(card_meta_text)
	status_signal = card_signal.map(card_status_text)
	priority_signal = card_signal.map(card_priority_text)
	estimate_signal = card_signal.map(card_estimate_text)
	tags_signal = card_signal.map(card_tags_text)
	note_signal = card_signal.map(note_label)

	Html.section(
		"Card: ${card_title(initial_cards, card_id)}",
		[
			Html.class_attr_s(class_signal),
			Html.on_pointer_down(board_state.on_unit(|board| start_drag(board, card_id))),
			Html.on_pointer_enter(board_state.on_unit(|board| hover_before(board, column_id, card_id))),
			Html.on_pointer_up(board_state.on_unit(|board| drop_before(board, column_id, card_id))),
			Html.on_pointer_leave(board_state.on_unit(clear_hover)),
		],
		[
			Html.div_c(
				card_header_class,
				[
					Html.paragraph_c(card_id, card_id_class),
					Html.paragraph_s_c(title_signal, card_title_class),
				],
			),
			Html.div_c(
				card_meta_grid_class,
				[
					Html.paragraph_s_c(priority_signal, card_meta_class),
					Html.paragraph_s_c(estimate_signal, card_meta_class),
				],
			),
			Html.paragraph_s_c(meta_signal, card_meta_class),
			Html.paragraph_s_c(status_signal, card_meta_class),
			Html.paragraph_s_c(tags_signal, card_tag_class),
			Html.div_c(
				card_footer_class,
				[
					Html.paragraph_s_c(note_signal, note_text_class),
					note_button(board_state, card_id, "Add note ${card_title(initial_cards, card_id)}"),
					edit_note_button(board_state, card_id, "Edit notes ${card_title(initial_cards, card_id)}"),
				],
			),
		],
	)
}

render_column : Ui.State(Board), Str, Signal.Signal(Column) -> Elem
render_column = |board_state, column_id, column_signal| {
	board_signal = board_state.signal()
	cards_signal : Signal.Signal(List(Card))
	cards_signal = board_signal.map(|board| column_cards(board, column_id))

	summary_inputs = { board: board_signal, column: column_signal }.Signal
	summary_signal = summary_inputs.map(|inputs| column_summary(inputs.board, inputs.column))

	drop_class_signal : Signal.Signal(Str)
	drop_class_signal = board_signal.map(|board| drop_zone_class_for(board, column_id))

	end_label = "Drop: ${column_title(column_id)} end"

	Html.section(
		column_title(column_id),
		[Html.class_attr(column_class)],
		[
			Html.heading_c(column_title(column_id), column_heading_class),
			Html.paragraph_s_c(summary_signal, column_summary_class),
			Ui.each_str(cards_signal, |card| card.id, |card_id, card| render_card(board_state, column_id, card_id, card)),
			Html.section(
				end_label,
				[
					Html.class_attr_s(drop_class_signal),
					Html.on_pointer_enter(board_state.on_unit(|board| hover_end(board, column_id))),
					Html.on_pointer_up(board_state.on_unit(|board| drop_on_end(board, column_id))),
					Html.on_pointer_leave(board_state.on_unit(clear_hover)),
				],
				[
					Html.paragraph("Drop card here"),
				],
			),
		],
	)
}

main : () -> Elem
main = || {
	Ui.state(
		initial_board,
		|board| {
			board_signal = board.signal()
			drag_status = board_signal.map(drag_status_text)
			reviewer_label = board_signal.map(reviewer_text)
			filter_label = board_signal.map(focus_text)
			card_metric = board_signal.map(visible_cards_text)
			point_metric = board_signal.map(visible_points_text)
			done_metric = board_signal.map(done_cards_text)
			column_signal = Signal.const(columns)

			Html.div_c(
				page_class,
				[
					Html.section_c(
						"Board controls",
						toolbar_class,
						[
							Html.div_c(
								toolbar_top_class,
								[
									Html.div_c(
										toolbar_title_class,
										[
											Html.paragraph_c("Release planning", eyebrow_class),
											Html.heading_c("Release Planner", "text-2xl font-semibold text-zinc-950"),
											Html.paragraph_c("Plan the next Signals milestone across backlog, active work, and completed cards.", toolbar_copy_class),
											Html.paragraph_s_c(drag_status, "text-sm font-medium text-emerald-700"),
										],
									),
									Html.div_c(
										metric_grid_class,
										[
											Html.div_c(
												metric_card_class,
												[
													Html.paragraph_c("Visible", metric_label_class),
													Html.paragraph_s_c(card_metric, metric_value_class),
												],
											),
											Html.div_c(
												metric_card_class,
												[
													Html.paragraph_c("Scope", metric_label_class),
													Html.paragraph_s_c(point_metric, metric_value_class),
												],
											),
											Html.div_c(
												metric_card_class,
												[
													Html.paragraph_c("Shipped", metric_label_class),
													Html.paragraph_s_c(done_metric, metric_value_class),
												],
											),
										],
									),
								],
							),
							Html.div_c(
								controls_class,
								[
									Html.text_input_c("Reviewer", board_signal.map(|value| value.reviewer), input_class, board.on_str(|state, value| { ..state, reviewer: value })),
									Html.paragraph_s_c(reviewer_label, toolbar_copy_class),
									Html.paragraph_s_c(filter_label, toolbar_copy_class),
									Html.button_c("Focus high priority", button_class, board.on_unit(|state| { ..state, focus_high_priority: !state.focus_high_priority })),
									Html.button_c("Clear drag", button_class, board.on_unit(cancel_drag)),
									Html.button_c("Reset demo", primary_button_class, board.on_unit(|_| initial_board)),
								],
							),
							render_note_editor(board, board_signal),
						],
					),
					Html.div_c(
						board_class,
						[
							Ui.each_str(column_signal, |column| column.id, |column_id, column| render_column(board, column_id, column)),
						],
					),
				],
			)
		},
	)
}
