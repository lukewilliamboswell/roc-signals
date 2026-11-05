## Markdown parsing (the view lives in ConduitApp) for article bodies: headings, paragraphs,
## quotes, fenced code blocks, one-level nested lists, bold, inline code,
## links, and images. Links and image sources pass a scheme allowlist;
## anything else degrades to plain text. Adapted from the previous engine's
## markdown-elem test fixture (the proven app-land path; no roc-parser package
## exists yet).

Markdown := {}.{
	ListItem : { key : Str, text : Str, children : List(Str) }

	## Keys identify rows; block and segment shape is selected lazily from the
	## typed kind signal by `Ui.switch`.
	BlockKind : [Heading, Quote, CodeBlock, ListBlock, Paragraph]

	SegmentKind : [Strong, Code, Image, Link, Text]

	Block : { key : Str, kind : Markdown.BlockKind, text : Str, items : List(Markdown.ListItem) }

	Segment : { key : Str, kind : Markdown.SegmentKind, text : Str, href : Str }

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

	block_key : U64, Markdown.BlockKind -> Str
	block_key = |index, _| "b:${index.to_str()}"

	append_block : Markdown.ParseState, Markdown.BlockKind, Str, List(Markdown.ListItem) -> Markdown.ParseState
	append_block = |state, kind, text, items| {
		{
			..state,
			blocks: state.blocks.append({ key: block_key(state.index, kind), kind, text, items }),
			index: state.index + 1,
		}
	}

	flush_item : Markdown.ParseState -> Markdown.ParseState
	flush_item = |state|
		if state.item_active {
			{
				..state,
				pending_items: state.pending_items.append({
					key: "i:${state.item_index.to_str()}",
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

	flush_list : Markdown.ParseState -> Markdown.ParseState
	flush_list = |state| {
		flushed = flush_item(state)
		if flushed.pending_items.is_empty() {
			flushed
		} else {
			appended = append_block(flushed, ListBlock, "", flushed.pending_items)
			{ ..appended, pending_items: [], item_index: 0 }
		}
	}

	flush_fence : Markdown.ParseState -> Markdown.ParseState
	flush_fence = |state| {
		appended = append_block(state, CodeBlock, Str.join_with(state.fence_lines, "\n"), [])
		{ ..appended, in_fence: False, fence_lines: [] }
	}

	start_item : Markdown.ParseState, Str -> Markdown.ParseState
	start_item = |state, text| {
		flushed = flush_item(state)
		{ ..flushed, item_active: True, item_text: text, item_children: [] }
	}

	parse_line : Markdown.ParseState, Str -> Markdown.ParseState
	parse_line = |state, line| {
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
			nested = line.drop_prefix("  - ").trim()
			if state.item_active {
				{ ..state, item_children: state.item_children.append(nested) }
			} else {
				start_item(state, nested)
			}
		} else if trimmed.starts_with("- ") {
			start_item(state, trimmed.drop_prefix("- "))
		} else if trimmed.starts_with("## ") {
			append_block(flush_list(state), Heading, trimmed.drop_prefix("## "), [])
		} else if trimmed.starts_with("# ") {
			append_block(flush_list(state), Heading, trimmed.drop_prefix("# "), [])
		} else if trimmed.starts_with("> ") {
			append_block(flush_list(state), Quote, trimmed.drop_prefix("> "), [])
		} else {
			append_block(flush_list(state), Paragraph, trimmed, [])
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

	segment_key : U64, Markdown.SegmentKind -> Str
	segment_key = |index, _| "s:${index.to_str()}"

	append_segment : Markdown.InlineState, Markdown.SegmentKind, Str, Str -> Markdown.InlineState
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
						strong = append_segment(before, Strong, close.before, "")
						parse_inline(strong, close.after)
					}
					Err(_) => append_segment(state, Text, text, "")
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
						code = append_segment(before, Code, close.before, "")
						parse_inline(code, close.after)
					}
					Err(_) => append_segment(state, Text, text, "")
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
										append_segment(before, Image, alt_split.before, src_split.before)
									} else {
										append_segment(before, Text, alt_split.before, "")
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
										append_segment(before, Link, label_split.before, href_split.before)
									} else {
										append_segment(before, Text, label_split.before, "")
									}
								parse_inline(link, href_split.after)
							}
							Err(_) => append_segment(state, Text, text, "")
						}
					Err(_) => append_segment(state, Text, text, "")
				}
			Err(_) => append_segment(state, Text, text, "")
		}

}

## Structural kinds no longer affect keyed-row identity.
expect Markdown.block_key(7, CodeBlock) == "b:7"
expect Markdown.segment_key(2, Link) == "s:2"

## A blank line separates blocks, and a leading `#` marks the first as a heading.
expect Markdown.parse("# Title\n\nbody").map(|block| block.kind) == [Heading, Paragraph]
