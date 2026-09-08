app [main] { pf: platform "../../../platform/main.roc" }

import pf.Elem exposing [Elem]
import pf.Html
import pf.Rows
import pf.Signal
import pf.Ui

MarkdownListItem : {
	key : Str,
	text : Str,
	children : List(Str),
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
	item_index : U64,
	pending_items : List(MarkdownListItem),
	item_active : Bool,
	item_text : Str,
	item_children : List(Str),
	in_fence : Bool,
	fence_lines : List(Str),
}

State : {
	markdown : Str,
}

initial_markdown = "# Release note\nShip **bold outcome** safely.\nUse `Signal.map` for preview.\n- First item\n- Second item\n  - Nested detail\n> Quote text\n```\nroc check main.roc\n```\n![Build badge](https://example.test/badge.png)\n![Bad badge](javascript:alert)\n[Allowed link](https://example.test/release)\n[Blocked script](javascript:alert)"

initial_live_markdown = "```\nlive fence body\n```\n- Alpha item\n  - Beta nested\n![Live badge](https://example.test/live-badge.png)\n![Nope image](javascript:evil)"

initial_state : State
initial_state = { markdown: initial_live_markdown }

block_key : U64, Str -> Str
block_key = |index, kind| "b:${index.to_str()}:${kind}"

item_key : U64 -> Str
item_key = |index| "i:${index.to_str()}"

child_key : U64 -> Str
child_key = |index| "c:${index.to_str()}"

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
	match text.split_first("[") {
		Ok(open) =>
			match open.after.split_first("](") {
				Ok(label_split) =>
					match label_split.after.split_first(")") {
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

parse_image_inline : InlineState, Str -> InlineState
parse_image_inline = |state, text| {
	match text.split_first("![") {
		Ok(open) =>
			match open.after.split_first("](") {
				Ok(alt_split) =>
					match alt_split.after.split_first(")") {
						Ok(src_split) => {
							before_state = parse_inline_into(state, open.before)
							image_state =
								if safe_href(src_split.before) {
									append_segment(before_state, "image", alt_split.before, src_split.before)
								} else {
									append_segment(before_state, "text", alt_split.before, "")
								}
							parse_inline_into(image_state, src_split.after)
						}
						Err(_) => parse_link_inline(state, text)
					}
				Err(_) => parse_link_inline(state, text)
			}
		Err(_) => parse_link_inline(state, text)
	}
}

parse_code_inline : InlineState, Str -> InlineState
parse_code_inline = |state, text| {
	match text.split_first("`") {
		Ok(open) =>
			match open.after.split_first("`") {
				Ok(close) => {
					before_state = parse_inline_into(state, open.before)
					code_state = append_segment(before_state, "code", close.before, "")
					parse_inline_into(code_state, close.after)
				}
				Err(_) => append_segment(state, "text", text, "")
			}
		Err(_) => parse_image_inline(state, text)
	}
}

parse_strong_inline : InlineState, Str -> InlineState
parse_strong_inline = |state, text| {
	match text.split_first("**") {
		Ok(open) =>
			match open.after.split_first("**") {
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

empty_markdown_state : MarkdownState
empty_markdown_state = {
	blocks: [],
	index: 0,
	item_index: 0,
	pending_items: [],
	item_active: False,
	item_text: "",
	item_children: [],
	in_fence: False,
	fence_lines: [],
}

append_block : MarkdownState, Str, Str, List(MarkdownListItem) -> MarkdownState
append_block = |state, kind, text, items| {
	{
		..state,
		blocks: state.blocks.append({ key: block_key(state.index, kind), kind, text, items }),
		index: state.index + 1,
	}
}

flush_item : MarkdownState -> MarkdownState
flush_item = |state|
	if state.item_active {
		{
			..state,
			pending_items: state.pending_items.append({
				key: item_key(state.item_index),
				text: state.item_text,
				children: state.item_children,
			}),
			item_index: state.item_index + 1,
			item_active: False,
			item_text: "",
			item_children: [],
		}
	} else {
		state
	}

flush_list : MarkdownState -> MarkdownState
flush_list = |state| {
	flushed = flush_item(state)
	if flushed.pending_items.is_empty() {
		flushed
	} else {
		appended = append_block(flushed, "list", "", flushed.pending_items)
		{ ..appended, pending_items: [], item_index: 0 }
	}
}

flush_fence : MarkdownState -> MarkdownState
flush_fence = |state| {
	appended = append_block(state, "codeblock", Str.join_with(state.fence_lines, "\n"), [])
	{ ..appended, in_fence: False, fence_lines: [] }
}

start_item : MarkdownState, Str -> MarkdownState
start_item = |state, text| {
	flushed = flush_item(state)
	{ ..flushed, item_active: True, item_text: text, item_children: [] }
}

add_nested_item : MarkdownState, Str -> MarkdownState
add_nested_item = |state, text|
	if state.item_active {
		{ ..state, item_children: state.item_children.append(text) }
	} else {
		start_item(state, text)
	}

append_other : MarkdownState, Str, Str -> MarkdownState
append_other = |state, kind, text| append_block(flush_list(state), kind, text, [])

parse_markdown_line : MarkdownState, Str -> MarkdownState
parse_markdown_line = |state, line| {
	trimmed = line.trim()
	if state.in_fence {
		if trimmed.starts_with("```") {
			flush_fence(state)
		} else {
			{ ..state, fence_lines: state.fence_lines.append(line) }
		}
	} else if trimmed.starts_with("```") {
		flushed = flush_list(state)
		{ ..flushed, in_fence: True, fence_lines: [] }
	} else if trimmed.is_empty() {
		flush_list(state)
	} else if line.starts_with("  - ") {
		add_nested_item(state, line.drop_prefix("  - ").trim())
	} else if trimmed.starts_with("- ") {
		start_item(state, trimmed.drop_prefix("- "))
	} else if trimmed.starts_with("## ") {
		append_other(state, "heading", trimmed.drop_prefix("## "))
	} else if trimmed.starts_with("# ") {
		append_other(state, "heading", trimmed.drop_prefix("# "))
	} else if trimmed.starts_with("> ") {
		append_other(state, "quote", trimmed.drop_prefix("> "))
	} else {
		append_other(state, "paragraph", trimmed)
	}
}

parse_markdown : Str -> List(MarkdownBlock)
parse_markdown = |source| {
	folded = source.split_on("\n").fold(empty_markdown_state, parse_markdown_line)
	ended = if folded.in_fence {
		flush_fence(folded)
	} else {
		folded
	}
	flush_list(ended).blocks
}

inline_plain_text : Str -> Str
inline_plain_text = |source| Str.join_with(inline_segments(source).map(|segment| segment.text), "")

keyed_children : List(Str) -> List({ key : Str, text : Str })
keyed_children = |texts|
	texts.fold(
		{ items: [], index: 0 },
		|acc, text| {
			items: acc.items.append({ key: child_key(acc.index), text }),
			index: acc.index + 1,
		},
	).items

inline_view : Signal.Signal(Str) -> Elem
inline_view = |source| {
	segments = source.map(inline_segments)
	Elem.Element({ namespace: Html, tag: "span", attrs: [], children: [Ui.each(Signal.map(segments, |rows_items| Rows.from_list(rows_items, |segment| segment.key) ?? crash "duplicate row key"), |each_row| render_inline_segment(each_row.key(), each_row.signal()))] })
}

render_inline_segment : Str, Signal.Signal(InlineSegment) -> Elem
render_inline_segment = |key, segment| {
	text = segment.map(|value| value.text)
	href = segment.map(|value| value.href)
	if key.ends_with(":strong") {
		Elem.Element({ namespace: Html, tag: "strong", attrs: [], children: [Html.text_s(text)] })
	} else if key.ends_with(":code") {
		Elem.Element({ namespace: Html, tag: "code", attrs: [Html.class_attr("rounded bg-zinc-100 px-1 font-mono")], children: [Html.text_s(text)] })
	} else if key.ends_with(":image") {
		Elem.Element({
			namespace: Html,
			tag: "img",
			attrs: [
				Html.attr_s("src", href),
				Html.attr_s("alt", text),
				Html.test_id(key),
			],
			children: [],
		})
	} else if key.ends_with(":link") {
		Elem.Element({
			namespace: Html,
			tag: "a",
			attrs: [
				Html.attr_s("href", href),
				Html.test_id(key),
			],
			children: [Html.text_s(text)],
		})
	} else {
		Html.text_s(text)
	}
}

render_child_item : Str, Signal.Signal({ key : Str, text : Str }) -> Elem
render_child_item = |_, child| {
	text = child.map(|value| value.text)
	Elem.Element({ namespace: Html, tag: "li", attrs: [], children: [inline_view(text)] })
}

render_list_item : Str, Signal.Signal(MarkdownListItem) -> Elem
render_list_item = |_, item| {
	text : Signal.Signal(Str)
	text = item.map(|value| value.text)

	children_signal : Signal.Signal(List({ key : Str, text : Str }))
	children_signal = item.map(|value| keyed_children(value.children))

	empty_children : Signal.Signal(Bool)
	empty_children = item.map(|value| value.children.is_empty())

	Elem.Element({
		namespace: Html,
		tag: "li",
		attrs: [],
		children: [
			inline_view(text),
			Ui.when(
				empty_children,
				|| Html.text(""),
				|| Elem.Element({ namespace: Html, tag: "ul", attrs: [], children: [Ui.each(Signal.map(children_signal, |rows_items| Rows.from_list(rows_items, |child| child.key) ?? crash "duplicate row key"), |each_row| render_child_item(each_row.key(), each_row.signal()))] }),
			),
		],
	})
}

render_markdown_block : Str, Signal.Signal(MarkdownBlock) -> Elem
render_markdown_block = |key, block| {
	text : Signal.Signal(Str)
	text = block.map(|value| value.text)

	if key.ends_with(":heading") {
		Elem.Element({ namespace: Html, tag: "h3", attrs: [], children: [Html.text_s(text)] })
	} else if key.ends_with(":quote") {
		Elem.Element({ namespace: Html, tag: "blockquote", attrs: [], children: [inline_view(text)] })
	} else if key.ends_with(":codeblock") {
		Elem.Element({
			namespace: Html,
			tag: "pre",
			attrs: [Html.class_attr("rounded bg-zinc-100 p-2 font-mono"), Html.test_id(key)],
			children: [Elem.Element({ namespace: Html, tag: "code", attrs: [], children: [Html.text_s(text)] })],
		})
	} else if key.ends_with(":list") {
		items : Signal.Signal(List(MarkdownListItem))
		items = block.map(|value| value.items)

		Elem.Element({ namespace: Html, tag: "ul", attrs: [], children: [Ui.each(Signal.map(items, |rows_items| Rows.from_list(rows_items, |item| item.key) ?? crash "duplicate row key"), |each_row| render_list_item(each_row.key(), each_row.signal()))] })
	} else {
		Elem.Element({ namespace: Html, tag: "p", attrs: [], children: [inline_view(text)] })
	}
}

markdown_view : Signal.Signal(Str) -> Elem
markdown_view = |source| {
	blocks = source.map(parse_markdown)
	Html.div([Html.attr("data-fixture", "markdown-preview")], [Ui.each(Signal.map(blocks, |rows_items| Rows.from_list(rows_items, |block| block.key) ?? crash "duplicate row key"), |each_row| render_markdown_block(each_row.key(), each_row.signal()))])
}

render_static_segment : InlineSegment -> Elem
render_static_segment = |segment| {
	if segment.kind == "strong" {
		Elem.Element({ namespace: Html, tag: "strong", attrs: [], children: [Html.text(segment.text)] })
	} else if segment.kind == "code" {
		Elem.Element({ namespace: Html, tag: "code", attrs: [Html.class_attr("rounded bg-zinc-100 px-1 font-mono")], children: [Html.text(segment.text)] })
	} else if segment.kind == "image" {
		Elem.Element({ namespace: Html, tag: "img", attrs: [Html.attr("src", segment.href), Html.attr("alt", segment.text), Html.test_id("static-image")], children: [] })
	} else if segment.kind == "link" {
		Html.link(segment.text, [Html.attr("href", segment.href), Html.test_id("allowed-link")])
	} else {
		Html.text(segment.text)
	}
}

static_inline_view : Str -> List(Elem)
static_inline_view = |source| inline_segments(source).map(render_static_segment)

render_static_child : Str -> Elem
render_static_child = |text| Elem.Element({ namespace: Html, tag: "li", attrs: [], children: static_inline_view(text) })

render_static_item : MarkdownListItem -> Elem
render_static_item = |item| {
	base = static_inline_view(item.text)
	children_elems =
		if item.children.is_empty() {
			base
		} else {
			base.append(Elem.Element({ namespace: Html, tag: "ul", attrs: [], children: item.children.map(render_static_child) }))
		}
	Elem.Element({ namespace: Html, tag: "li", attrs: [], children: children_elems })
}

render_static_block : MarkdownBlock -> Elem
render_static_block = |block| {
	if block.kind == "heading" {
		Html.heading(block.text)
	} else if block.kind == "quote" {
		Elem.Element({ namespace: Html, tag: "blockquote", attrs: [], children: static_inline_view(block.text) })
	} else if block.kind == "codeblock" {
		Elem.Element({
			namespace: Html,
			tag: "pre",
			attrs: [Html.class_attr("rounded bg-zinc-100 p-2 font-mono"), Html.test_id("static-code")],
			children: [Elem.Element({ namespace: Html, tag: "code", attrs: [], children: [Html.text(block.text)] })],
		})
	} else if block.kind == "list" {
		Elem.Element({ namespace: Html, tag: "ul", attrs: [], children: block.items.map(render_static_item) })
	} else {
		Elem.Element({ namespace: Html, tag: "p", attrs: [], children: static_inline_view(block.text) })
	}
}

static_markdown_view : Str -> Elem
static_markdown_view = |source| {
	Html.div([Html.attr("data-fixture", "static-markdown")], parse_markdown(source).map(render_static_block))
}

update_markdown : State, Str -> State
update_markdown = |state, value| { ..state, markdown: value }

main : () -> Elem
main = || {
	Ui.state(
		initial_state,
		|model| {
			state = model.signal()
			markdown = state.map(|value| value.markdown)

			Html.section(
				"Markdown Elem Fixture",
				[Html.attr("data-fixture", "markdown-elem")],
				[
					Html.heading("Markdown Elem Fixture"),
					static_markdown_view(initial_markdown),
					Html.textarea_c("Markdown input", markdown, "min-h-32 w-full font-mono", model.on_str(update_markdown)),
					markdown_view(markdown),
				],
			)
		},
	)
}
