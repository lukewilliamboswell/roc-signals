## Markdown source to `Elem` structure: headings (levels 1-6), paragraphs,
## quotes, fenced code blocks, one-level nested lists, bold, inline code,
## links, and images. Links and image sources pass a scheme allowlist;
## anything else degrades to plain text, and nothing is ever injected as raw
## HTML. Adapted from `examples/conduit/Markdown.roc`, with heading levels
## carried in the block key so the outline can be derived from parsed blocks
## rather than re-scanning the raw source.
import pf.Elem exposing [Elem]
import pf.Html
import pf.Signal
import pf.Ui

Markdown := {}.{
	ListItem : { key : Str, text : Str, children : List(Str) }

	## `kind` is one of "heading", "paragraph", "quote", "codeblock", "list".
	## `level` is the heading level (1-6) and is 0 for every other kind.
	Block : { key : Str, kind : Str, level : U64, text : Str, items : List(Markdown.ListItem) }

	Segment : { key : Str, kind : Str, text : Str, href : Str }

	InlineState : { segments : List(Markdown.Segment), index : U64 }

	ParseState : {
		blocks : List(Markdown.Block),
		index : U64,
		item_index : U64,
		pending_items : List(Markdown.ListItem),
		item_active : Bool,
		item_text : Str,
		item_children : List(Str),
		in_fence : Bool,
		fence_lines : List(Str),
	}

	parse : Str -> List(Markdown.Block)
	parse = |source| {
		folded = source.split_on("\n").fold(empty_state, parse_line)
		ended = if folded.in_fence {
			flush_fence(folded)
		} else {
			folded
		}
		flush_list(ended).blocks
	}

	empty_state : Markdown.ParseState
	empty_state = {
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

	## Heading levels live in the key so a level change remounts the row with
	## the correct `h1`-`h6` tag instead of patching text into the wrong tag.
	block_key : U64, Str, U64 -> Str
	block_key = |index, kind, level|
		if kind == "heading" {
			"b:${index.to_str()}:heading${level.to_str()}"
		} else {
			"b:${index.to_str()}:${kind}"
		}

	append_block : Markdown.ParseState, Str, U64, Str, List(Markdown.ListItem) -> Markdown.ParseState
	append_block = |state, kind, level, text, items| {
		{
			..state,
			blocks: state.blocks.append({ key: block_key(state.index, kind, level), kind, level, text, items }),
			index: state.index + 1,
		}
	}

	flush_item : Markdown.ParseState -> Markdown.ParseState
	flush_item = |state|
		if state.item_active {
			{
				..state,
				pending_items: state.pending_items.append(
					{
						key: "i:${state.item_index.to_str()}",
						text: state.item_text,
						children: state.item_children,
					},
				),
				item_index: state.item_index + 1,
				item_active: False,
				item_text: "",
				item_children: [],
			}
		} else {
			state
		}

	flush_list : Markdown.ParseState -> Markdown.ParseState
	flush_list = |state| {
		flushed = flush_item(state)
		if flushed.pending_items.is_empty() {
			flushed
		} else {
			appended = append_block(flushed, "list", 0, "", flushed.pending_items)
			{ ..appended, pending_items: [], item_index: 0 }
		}
	}

	flush_fence : Markdown.ParseState -> Markdown.ParseState
	flush_fence = |state| {
		appended = append_block(state, "codeblock", 0, Str.join_with(state.fence_lines, "\n"), [])
		{ ..appended, in_fence: False, fence_lines: [] }
	}

	start_item : Markdown.ParseState, Str -> Markdown.ParseState
	start_item = |state, text| {
		flushed = flush_item(state)
		{ ..flushed, item_active: True, item_text: text, item_children: [] }
	}

	## Longest heading prefix wins, so "### x" is level three rather than a
	## level-one heading whose text begins with "##". A `level` of 0 means the
	## line is not a heading at all.
	Heading : { level : U64, text : Str }

	heading_prefix : Str -> Markdown.Heading
	heading_prefix = |trimmed|
		if trimmed.starts_with("###### ") {
			{ level: 6, text: trimmed.drop_prefix("###### ").trim() }
		} else if trimmed.starts_with("##### ") {
			{ level: 5, text: trimmed.drop_prefix("##### ").trim() }
		} else if trimmed.starts_with("#### ") {
			{ level: 4, text: trimmed.drop_prefix("#### ").trim() }
		} else if trimmed.starts_with("### ") {
			{ level: 3, text: trimmed.drop_prefix("### ").trim() }
		} else if trimmed.starts_with("## ") {
			{ level: 2, text: trimmed.drop_prefix("## ").trim() }
		} else if trimmed.starts_with("# ") {
			{ level: 1, text: trimmed.drop_prefix("# ").trim() }
		} else {
			{ level: 0, text: trimmed }
		}

	## Heading level of one raw source line, or 0 when the line is not a
	## heading. Editing commands use this to find section boundaries.
	heading_level : Str -> U64
	heading_level = |line| heading_prefix(line.trim()).level

	parse_line : Markdown.ParseState, Str -> Markdown.ParseState
	parse_line = |state, line| {
		trimmed = line.trim()
		if state.in_fence {
			# Inside a fence every line is literal text, including "# ..." lines
			# that would otherwise look like headings.
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
			nested = line.drop_prefix("  - ").trim()
			if state.item_active {
				{ ..state, item_children: state.item_children.append(nested) }
			} else {
				start_item(state, nested)
			}
		} else if trimmed.starts_with("- ") {
			start_item(state, trimmed.drop_prefix("- "))
		} else if trimmed.starts_with("> ") {
			append_block(flush_list(state), "quote", 0, trimmed.drop_prefix("> "), [])
		} else {
			heading : Markdown.Heading
			heading = heading_prefix(trimmed)
			if heading.level == 0 {
				append_block(flush_list(state), "paragraph", 0, trimmed, [])
			} else {
				append_block(flush_list(state), "heading", heading.level, heading.text, [])
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

	segment_key : U64, Str -> Str
	segment_key = |index, kind| "s:${index.to_str()}:${kind}"

	append_segment : Markdown.InlineState, Str, Str, Str -> Markdown.InlineState
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

	inline_segments : Str -> List(Markdown.Segment)
	inline_segments = |text| parse_inline({ segments: [], index: 0 }, text).segments

	## Inline markup stripped back to readable text. The outline needs heading
	## copy without the surrounding markers.
	plain_text : Str -> Str
	plain_text = |text| Str.join_with(inline_segments(text).map(|segment| segment.text), "")

	parse_inline : Markdown.InlineState, Str -> Markdown.InlineState
	parse_inline = |state, text|
		if text.is_empty() {
			state
		} else {
			parse_strong(state, text)
		}

	parse_strong : Markdown.InlineState, Str -> Markdown.InlineState
	parse_strong = |state, text|
		match text.split_first("**") {
			Ok(open) =>
				match open.after.split_first("**") {
					Ok(close) => {
						before = parse_inline(state, open.before)
						strong = append_segment(before, "strong", close.before, "")
						parse_inline(strong, close.after)
					}
					Err(_) => append_segment(state, "text", text, "")
				}
			Err(_) => parse_code(state, text)
		}

	parse_code : Markdown.InlineState, Str -> Markdown.InlineState
	parse_code = |state, text|
		match text.split_first("`") {
			Ok(open) =>
				match open.after.split_first("`") {
					Ok(close) => {
						before = parse_inline(state, open.before)
						code = append_segment(before, "code", close.before, "")
						parse_inline(code, close.after)
					}
					Err(_) => append_segment(state, "text", text, "")
				}
			Err(_) => parse_image(state, text)
		}

	parse_image : Markdown.InlineState, Str -> Markdown.InlineState
	parse_image = |state, text|
		match text.split_first("![") {
			Ok(open) =>
				match open.after.split_first("](") {
					Ok(alt_split) =>
						match alt_split.after.split_first(")") {
							Ok(src_split) => {
								before = parse_inline(state, open.before)
								image =
									if safe_href(src_split.before) {
										append_segment(before, "image", alt_split.before, src_split.before)
									} else {
										append_segment(before, "text", alt_split.before, "")
									}
								parse_inline(image, src_split.after)
							}
							Err(_) => parse_link(state, text)
						}
					Err(_) => parse_link(state, text)
				}
			Err(_) => parse_link(state, text)
		}

	parse_link : Markdown.InlineState, Str -> Markdown.InlineState
	parse_link = |state, text|
		match text.split_first("[") {
			Ok(open) =>
				match open.after.split_first("](") {
					Ok(label_split) =>
						match label_split.after.split_first(")") {
							Ok(href_split) => {
								before = parse_inline(state, open.before)
								link =
									if safe_href(href_split.before) {
										append_segment(before, "link", label_split.before, href_split.before)
									} else {
										append_segment(before, "text", label_split.before, "")
									}
								parse_inline(link, href_split.after)
							}
							Err(_) => append_segment(state, "text", text, "")
						}
					Err(_) => append_segment(state, "text", text, "")
				}
			Err(_) => append_segment(state, "text", text, "")
		}

	inline_view : Signal.Signal(Str) -> Elem
	inline_view = |source| {
		segments = source.map(inline_segments)
		Elem.Element({ tag: "span", attrs: [], children: [Ui.each_str(segments, |segment| segment.key, render_segment)] })
	}

	render_segment : Str, Signal.Signal(Markdown.Segment) -> Elem
	render_segment = |key, segment| {
		text = segment.map(|value| value.text)
		href = segment.map(|value| value.href)
		if key.ends_with(":strong") {
			Elem.Element({ tag: "strong", attrs: [], children: [Html.text_s(text)] })
		} else if key.ends_with(":code") {
			Elem.Element({ tag: "code", attrs: [Html.class_attr("rounded bg-zinc-100 px-1 font-mono")], children: [Html.text_s(text)] })
		} else if key.ends_with(":image") {
			Elem.Element({ tag: "img", attrs: [Html.attr_s("src", href), Html.attr_s("alt", text)], children: [] })
		} else if key.ends_with(":link") {
			Elem.Element({ tag: "a", attrs: [Html.attr_s("href", href)], children: [Html.text_s(text)] })
		} else {
			Html.text_s(text)
		}
	}

	keyed_children : List(Str) -> List({ key : Str, text : Str })
	keyed_children = |texts|
		texts.fold(
			{ items: [], index: 0 },
			|acc, text| {
				items: acc.items.append({ key: "c:${acc.index.to_str()}", text }),
				index: acc.index + 1,
			},
		).items

	render_child : Str, Signal.Signal({ key : Str, text : Str }) -> Elem
	render_child = |_, child| {
		text = child.map(|value| value.text)
		Elem.Element({ tag: "li", attrs: [], children: [inline_view(text)] })
	}

	render_item : Str, Signal.Signal(Markdown.ListItem) -> Elem
	render_item = |_, item| {
		text : Signal.Signal(Str)
		text = item.map(|value| value.text)

		children_signal : Signal.Signal(List({ key : Str, text : Str }))
		children_signal = item.map(|value| keyed_children(value.children))

		empty_children : Signal.Signal(Bool)
		empty_children = item.map(|value| value.children.is_empty())

		Elem.Element(
			{
				tag: "li",
				attrs: [],
				children: [
					inline_view(text),
					Ui.when(
						empty_children,
						|| Html.text(""),
						|| Elem.Element({ tag: "ul", attrs: [Html.class_attr("list-disc pl-5")], children: [Ui.each_str(children_signal, |child| child.key, render_child)] }),
					),
				],
			},
		)
	}

	heading_tag : Str -> Str
	heading_tag = |key|
		if key.ends_with(":heading1") {
			"h1"
		} else if key.ends_with(":heading2") {
			"h2"
		} else if key.ends_with(":heading3") {
			"h3"
		} else if key.ends_with(":heading4") {
			"h4"
		} else if key.ends_with(":heading5") {
			"h5"
		} else {
			"h6"
		}

	is_heading_key : Str -> Bool
	is_heading_key = |key|
		key.ends_with(":heading1")
			or key.ends_with(":heading2")
				or key.ends_with(":heading3")
					or key.ends_with(":heading4")
						or key.ends_with(":heading5")
							or key.ends_with(":heading6")

	render_block : Str, Signal.Signal(Markdown.Block) -> Elem
	render_block = |key, block| {
		text : Signal.Signal(Str)
		text = block.map(|value| value.text)

		if is_heading_key(key) {
			Elem.Element({ tag: heading_tag(key), attrs: [Html.class_attr("font-semibold")], children: [inline_view(text)] })
		} else if key.ends_with(":quote") {
			Elem.Element({ tag: "blockquote", attrs: [Html.class_attr("border-l-2 border-zinc-300 pl-3")], children: [inline_view(text)] })
		} else if key.ends_with(":codeblock") {
			Elem.Element(
				{
					tag: "pre",
					attrs: [Html.class_attr("overflow-x-auto rounded bg-zinc-900 p-3 font-mono text-sm text-zinc-100")],
					children: [Elem.Element({ tag: "code", attrs: [], children: [Html.text_s(text)] })],
				},
			)
		} else if key.ends_with(":list") {
			items : Signal.Signal(List(Markdown.ListItem))
			items = block.map(|value| value.items)

			Elem.Element({ tag: "ul", attrs: [Html.class_attr("list-disc pl-5")], children: [Ui.each_str(items, |item| item.key, render_item)] })
		} else {
			Elem.Element({ tag: "p", attrs: [], children: [inline_view(text)] })
		}
	}

	## Render already-parsed blocks. Taking `Signal(List(Block))` instead of
	## `Signal(Str)` lets the app parse once and fan the parsed value out to
	## the preview and the outline independently.
	view_blocks : Signal.Signal(List(Markdown.Block)) -> Elem
	view_blocks = |blocks|
		Html.div(
			[Html.attr("data-panel", "preview-body"), Html.class_attr("grid gap-3")],
			[Ui.each_str(blocks, |block| block.key, render_block)],
		)
}
