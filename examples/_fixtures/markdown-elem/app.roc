app [main] { pf: platform "https://github.com/lukewilliamboswell/roc-signals/releases/download/0.1/3eLQGNMDG9RuL9sn1A7ep1Rtq7QGmemE89y141WSv1XG.tar.zst" }

import pf.Elem exposing [Elem]
import pf.Html
import pf.Signal
import pf.Ui

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

State : {
	markdown : Str,
}

initial_markdown = "# Release note\nShip **bold outcome** safely.\nUse `Signal.map` for preview.\n- First item\n- Second item\n> Quote text\n[Allowed link](https://example.test/release)\n[Blocked script](javascript:alert)"

initial_state : State
initial_state = { markdown: "" }

concat3 : Str, Str, Str -> Str
concat3 = |a, b, c| Str.concat(Str.concat(a, b), c)

concat4 : Str, Str, Str, Str -> Str
concat4 = |a, b, c, d| Str.concat(concat3(a, b, c), d)

block_key : U64, Str -> Str
block_key = |index, kind| concat4("b:", index.to_str(), ":", kind)

item_key : U64 -> Str
item_key = |index| concat3("i:", index.to_str(), "")

segment_key : U64, Str -> Str
segment_key = |index, kind| concat4("s:", index.to_str(), ":", kind)

empty_inline_state : InlineState
empty_inline_state = { segments: [], index: 0 }

append_segment : InlineState, Str, Str, Str -> InlineState
append_segment = |state, kind, text, href| {
	if Str.is_empty(text) {
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
	Str.starts_with(href, "https://")
		or Str.starts_with(href, "http://")
		or Str.starts_with(href, "/")
		or Str.starts_with(href, "#")
		or Str.starts_with(href, "mailto:")
}

parse_link_inline : InlineState, Str -> InlineState
parse_link_inline = |state, text| {
	match Str.find_first(text, "[") {
		Ok(open) =>
			match Str.find_first(open.after, "](") {
				Ok(label_split) =>
					match Str.find_first(label_split.after, ")") {
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
	match Str.find_first(text, "`") {
		Ok(open) =>
			match Str.find_first(open.after, "`") {
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
	match Str.find_first(text, "**") {
		Ok(open) =>
			match Str.find_first(open.after, "**") {
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
	if Str.is_empty(text) {
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
	trimmed = Str.trim(line)
	if Str.is_empty(trimmed) {
		state
	} else if Str.starts_with(trimmed, "## ") {
		append_block(state, "heading", Str.drop_prefix(trimmed, "## "), [])
	} else if Str.starts_with(trimmed, "# ") {
		append_block(state, "heading", Str.drop_prefix(trimmed, "# "), [])
	} else if Str.starts_with(trimmed, "> ") {
		append_block(state, "quote", Str.drop_prefix(trimmed, "> "), [])
	} else if Str.starts_with(trimmed, "- ") {
		append_block(
			state,
			"list",
			Str.drop_prefix(trimmed, "- "),
			[],
		)
	} else {
		append_block(state, "paragraph", trimmed, [])
	}
}

parse_markdown : Str -> List(MarkdownBlock)
parse_markdown = |source| Str.split_on(source, "\n").fold({ blocks: [], index: 0 }, parse_markdown_line).blocks

inline_plain_text : Str -> Str
inline_plain_text = |source| inline_segments(source).fold("", |acc, segment| Str.concat(acc, segment.text))

inline_view : Signal.Signal(Str) -> Elem
inline_view = |source| {
	segments = Signal.map(source, inline_segments)
	Elem.Element({ tag: "span", attrs: [], children: [Ui.each_str(segments, |segment| segment.key, render_inline_segment)] })
}

render_inline_segment : Str, Signal.Signal(InlineSegment) -> Elem
render_inline_segment = |key, segment| {
	text = Signal.map(segment, |value| value.text)
	href = Signal.map(segment, |value| value.href)
	if Str.ends_with(key, ":strong") {
		Elem.Element({ tag: "strong", attrs: [], children: [Html.text_s(text)] })
	} else if Str.ends_with(key, ":code") {
		Elem.Element({ tag: "code", attrs: [Html.class_attr("rounded bg-zinc-100 px-1 font-mono")], children: [Html.text_s(text)] })
	} else if Str.ends_with(key, ":link") {
		Elem.Element(
			{
				tag: "a",
				attrs: [
					Html.attr_s("href", href),
					Html.test_id(key),
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
	text = Signal.map(item, |value| value.text)
	Elem.Element({ tag: "li", attrs: [], children: [inline_view(text)] })
}

render_markdown_block : Str, Signal.Signal(MarkdownBlock) -> Elem
render_markdown_block = |key, block| {
	text = Signal.map(block, |value| value.text)
	if Str.ends_with(key, ":heading") {
		Elem.Element({ tag: "h3", attrs: [], children: [Html.text_s(text)] })
	} else if Str.ends_with(key, ":quote") {
		Elem.Element({ tag: "blockquote", attrs: [], children: [inline_view(text)] })
	} else if Str.ends_with(key, ":list") {
		Elem.Element({ tag: "ul", attrs: [], children: [Elem.Element({ tag: "li", attrs: [], children: [inline_view(text)] })] })
	} else {
		Elem.Element({ tag: "p", attrs: [], children: [inline_view(text)] })
	}
}

markdown_view : Signal.Signal(Str) -> Elem
markdown_view = |source| {
	blocks = Signal.map(source, parse_markdown)
	Html.div([Html.attr("data-fixture", "markdown-preview")], [Ui.each_str(blocks, |block| block.key, render_markdown_block)])
}

render_static_segment : InlineSegment -> Elem
render_static_segment = |segment| {
	if segment.kind == "strong" {
		Elem.Element({ tag: "strong", attrs: [], children: [Html.text(segment.text)] })
	} else if segment.kind == "code" {
		Elem.Element({ tag: "code", attrs: [Html.class_attr("rounded bg-zinc-100 px-1 font-mono")], children: [Html.text(segment.text)] })
	} else if segment.kind == "link" {
		Html.link(segment.text, [Html.attr("href", segment.href), Html.test_id("allowed-link")])
	} else {
		Html.text(segment.text)
	}
}

static_inline_view : Str -> List(Elem)
static_inline_view = |source| inline_segments(source).map(render_static_segment)

render_static_block : MarkdownBlock -> Elem
render_static_block = |block| {
	if block.kind == "heading" {
		Html.heading(block.text)
	} else if block.kind == "quote" {
		Elem.Element({ tag: "blockquote", attrs: [], children: static_inline_view(block.text) })
	} else if block.kind == "list" {
		Elem.Element({ tag: "ul", attrs: [], children: [Elem.Element({ tag: "li", attrs: [], children: static_inline_view(block.text) })] })
	} else {
		Elem.Element({ tag: "p", attrs: [], children: static_inline_view(block.text) })
	}
}

static_markdown_view : Str -> Elem
static_markdown_view = |source| {
	Html.div([Html.attr("data-fixture", "static-markdown")], parse_markdown(source).map(render_static_block))
}

update_markdown : State, Str -> State
update_markdown = |state, value| { ..state, markdown: value }

main : {} -> Elem
main = |_| {
	Ui.state(
		initial_state,
		|model| {
			state = model.signal()
			markdown = Signal.map(state, |value| value.markdown)

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
