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

	## What a parsed block *is*. The heading level rides in the tag, so there is
	## no "level is 0 for everything that is not a heading" sentinel to forget.
	## `to_str` reproduces the wire form used inside the reconciler key.
	Kind := [Heading(U64), Paragraph, Quote, CodeBlock, ListBlock].{
		is_eq : Markdown.Kind, Markdown.Kind -> Bool
		is_eq = |left, right|
			match left {
				Heading(left_level) => match right {
					Heading(right_level) => left_level == right_level
					_ => False
				}
				Paragraph => match right {
					Paragraph => True
					_ => False
				}
				Quote => match right {
					Quote => True
					_ => False
				}
				CodeBlock => match right {
					CodeBlock => True
					_ => False
				}
				ListBlock => match right {
					ListBlock => True
					_ => False
				}
			}

		to_str : Markdown.Kind -> Str
		to_str = |kind|
			match kind {
				Heading(level) => "heading${level.to_str()}"
				Paragraph => "paragraph"
				Quote => "quote"
				CodeBlock => "codeblock"
				ListBlock => "list"
			}
	}

	Block : { key : Str, kind : Markdown.Kind, text : Str, items : List(Markdown.ListItem) }

	## Inline markup carried by one run of text.
	Style := [Plain, Strong, Code, Image, Link].{
		is_eq : Markdown.Style, Markdown.Style -> Bool
		is_eq = |left, right|
			match left {
				Plain => match right {
					Plain => True
					_ => False
				}
				Strong => match right {
					Strong => True
					_ => False
				}
				Code => match right {
					Code => True
					_ => False
				}
				Image => match right {
					Image => True
					_ => False
				}
				Link => match right {
					Link => True
					_ => False
				}
			}

		to_str : Markdown.Style -> Str
		to_str = |style|
			match style {
				Plain => "text"
				Strong => "strong"
				Code => "code"
				Image => "image"
				Link => "link"
			}
	}

	Segment : { key : Str, kind : Markdown.Style, text : Str, href : Str }

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

	## Row identity is independent of block shape; `Ui.switch` remounts the
	## structural branch when the kind changes.
	block_key : U64, Markdown.Kind -> Str
	block_key = |index, _| "b:${index.to_str()}"

	append_block : Markdown.ParseState, Markdown.Kind, Str, List(Markdown.ListItem) -> Markdown.ParseState
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
			appended = append_block(flushed, Markdown.Kind.ListBlock, "", flushed.pending_items)
			{ ..appended, pending_items: [], item_index: 0 }
		}
	}

	flush_fence : Markdown.ParseState -> Markdown.ParseState
	flush_fence = |state| {
		appended = append_block(state, Markdown.Kind.CodeBlock, Str.join_with(state.fence_lines, "\n"), [])
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
			append_block(flush_list(state), Markdown.Kind.Quote, trimmed.drop_prefix("> "), [])
		} else {
			heading : Markdown.Heading
			heading = heading_prefix(trimmed)
			if heading.level == 0 {
				append_block(flush_list(state), Markdown.Kind.Paragraph, trimmed, [])
			} else {
				append_block(flush_list(state), Markdown.Kind.Heading(heading.level), heading.text, [])
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

	segment_key : U64, Markdown.Style -> Str
	segment_key = |index, _| "s:${index.to_str()}"

	append_segment : Markdown.InlineState, Markdown.Style, Str, Str -> Markdown.InlineState
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

	plain : Markdown.InlineState, Str -> Markdown.InlineState
	plain = |state, text| append_segment(state, Markdown.Style.Plain, text, "")

	inline_segments : Str -> List(Markdown.Segment)
	inline_segments = |text| parse_inline({ segments: [], index: 0 }, text).segments

	## Inline markup stripped back to readable text. The outline needs heading
	## copy without the surrounding markers.
	plain_text : Str -> Str
	plain_text = |text| Str.join_with(inline_segments(text).map(|segment| segment.text), "")

	## The inline parsers form a fallback chain: strong, then code, then image,
	## then link, then plain text. Each one splits on its delimiters with `?`, so
	## the happy path reads as a straight line and the tagged error says *why* it
	## did not apply: `NoOpen` falls through to the next parser, `Unclosed` means
	## the delimiter was never balanced and the run stays literal.
	parse_inline : Markdown.InlineState, Str -> Markdown.InlineState
	parse_inline = |state, text|
		if text.is_empty() {
			state
		} else {
			parse_strong(state, text)
		}

	parse_paired : Markdown.InlineState, Str, Str, Markdown.Style -> Try(Markdown.InlineState, [NoOpen, Unclosed])
	parse_paired = |state, text, delimiter, style| {
		open = text.split_first(delimiter) ? |_| NoOpen
		close = open.after.split_first(delimiter) ? |_| Unclosed
		before = parse_inline(state, open.before)
		marked = append_segment(before, style, close.before, "")
		Ok(parse_inline(marked, close.after))
	}

	parse_strong : Markdown.InlineState, Str -> Markdown.InlineState
	parse_strong = |state, text|
		match parse_paired(state, text, "**", Markdown.Style.Strong) {
			Ok(next) => next
			Err(Unclosed) => plain(state, text)
			Err(NoOpen) => parse_code(state, text)
		}

	parse_code : Markdown.InlineState, Str -> Markdown.InlineState
	parse_code = |state, text|
		match parse_paired(state, text, "`", Markdown.Style.Code) {
			Ok(next) => next
			Err(Unclosed) => plain(state, text)
			Err(NoOpen) => parse_image(state, text)
		}

	## `![alt](src)` and `[label](href)` share a shape, so they share a parser.
	## An unsafe scheme keeps the label as plain text rather than emitting the
	## element at all.
	parse_bracketed : Markdown.InlineState, Str, Str, Markdown.Style -> Try(Markdown.InlineState, [NotBracketed])
	parse_bracketed = |state, text, opener, style| {
		open = text.split_first(opener) ? |_| NotBracketed
		label_split = open.after.split_first("](") ? |_| NotBracketed
		target_split = label_split.after.split_first(")") ? |_| NotBracketed
		before = parse_inline(state, open.before)
		marked = if safe_href(target_split.before) {
			append_segment(before, style, label_split.before, target_split.before)
		} else {
			plain(before, label_split.before)
		}
		Ok(parse_inline(marked, target_split.after))
	}

	parse_image : Markdown.InlineState, Str -> Markdown.InlineState
	parse_image = |state, text|
		match parse_bracketed(state, text, "![", Markdown.Style.Image) {
			Ok(next) => next
			Err(_) => parse_link(state, text)
		}

	parse_link : Markdown.InlineState, Str -> Markdown.InlineState
	parse_link = |state, text|
		match parse_bracketed(state, text, "[", Markdown.Style.Link) {
			Ok(next) => next
			Err(_) => plain(state, text)
		}

	inline_view : Signal.Signal(Str) -> Elem
	inline_view = |source| {
		segments = source.map(inline_segments)
		Elem.Element({ tag: "span", attrs: [], children: [Ui.each(segments, |segment| segment.key, |each_row| render_segment(each_row.key(), each_row.signal()))] })
	}

	render_segment : Str, Signal.Signal(Markdown.Segment) -> Elem
	render_segment = |_, segment| {
		text = segment.map(|value| value.text)
		href = segment.map(|value| value.href)
		Ui.switch(
			segment.map(|value| value.kind),
			|kind| match kind {
				Strong => Elem.Element({ tag: "strong", attrs: [], children: [Html.text_s(text)] })
				Code => Elem.Element({ tag: "code", attrs: [], children: [Html.text_s(text)] })
				Image => Elem.Element({ tag: "img", attrs: [Html.attr_s("src", href), Html.attr_s("alt", text), Html.class_attr("max-w-full rounded-md")], children: [] })
				Link => Elem.Element({ tag: "a", attrs: [Html.attr_s("href", href), Html.class_attr("font-medium text-emerald-700 underline underline-offset-2")], children: [Html.text_s(text)] })
				Plain => Html.text_s(text)
			},
		)
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

		Elem.Element({
			tag: "li",
			attrs: [],
			children: [
				inline_view(text),
				Ui.when(
					empty_children,
					|| Html.text(""),
					|| Elem.Element({ tag: "ul", attrs: [], children: [Ui.each(children_signal, |child| child.key, |each_row| render_child(each_row.key(), each_row.signal()))] }),
				),
			],
		})
	}

	heading_tag : U64 -> Str
	heading_tag = |level|
		match level {
			1 => "h1"
			2 => "h2"
			3 => "h3"
			4 => "h4"
			5 => "h5"
			_ => "h6"
		}

	## `prose-signals` styles h1-h3; levels four to six are rarer and get an
	## explicit, progressively quieter treatment so the hierarchy stays visible.
	heading_class : U64 -> Str
	heading_class = |level|
		if level <= 3 {
			""
		} else {
			"mt-6 text-base font-semibold text-zinc-950"
		}

	render_block : Str, Signal.Signal(Markdown.Block) -> Elem
	render_block = |_, block| {
		text : Signal.Signal(Str)
		text = block.map(|value| value.text)

		Ui.switch(
			block.map(|value| value.kind),
			|kind| match kind {
				Heading(level) =>
					Elem.Element({ tag: heading_tag(level), attrs: [Html.class_attr(heading_class(level))], children: [inline_view(text)] })
				Quote => Elem.Element({ tag: "blockquote", attrs: [], children: [inline_view(text)] })
				CodeBlock =>
					Elem.Element({
						tag: "pre",
						attrs: [],
						children: [Elem.Element({ tag: "code", attrs: [], children: [Html.text_s(text)] })],
					})
				ListBlock => {
					items : Signal.Signal(List(Markdown.ListItem))
					items = block.map(|value| value.items)

					Elem.Element({ tag: "ul", attrs: [], children: [Ui.each(items, |item| item.key, |each_row| render_item(each_row.key(), each_row.signal()))] })
				}
				Paragraph => Elem.Element({ tag: "p", attrs: [], children: [inline_view(text)] })
			},
		)
	}

	## Render already-parsed blocks. Taking `Signal(List(Block))` instead of
	## `Signal(Str)` lets the app parse once and fan the parsed value out to
	## the preview and the outline independently.
	view_blocks : Signal.Signal(List(Markdown.Block)) -> Elem
	view_blocks = |blocks|
		Html.div(
			[Html.attr("data-panel", "preview-body"), Html.class_attr("prose-signals")],
			[Ui.each(blocks, |block| block.key, |each_row| render_block(each_row.key(), each_row.signal()))],
		)
}

## An ATX heading needs a space after its hashes to count as a heading.
expect Markdown.heading_level("### Editor Notes") == 3

## Hashes with no following space are ordinary paragraph text, not a heading.
expect Markdown.heading_level("###Not a heading") == 0

## Structural kinds no longer affect row identity.
expect Markdown.block_key(4, Markdown.Kind.Heading(2)) == "b:4"
expect Markdown.block_key(4, Markdown.Kind.CodeBlock) == "b:4"
expect Markdown.segment_key(2, Markdown.Style.Link) == "s:2"
expect Markdown.segment_key(2, Markdown.Style.Plain) == "s:2"

## Strong and code markers are stripped, leaving the words the outline shows.
expect Markdown.plain_text("Use **map2** for fan-in and `combine`") == "Use map2 for fan-in and combine"

## Text that only looks like markup survives byte for byte: a lone `*` is not
## emphasis and an unclosed `[` never opens a link.
expect Markdown.plain_text("2 * 3 = 6 and [not a link( either") == "2 * 3 = 6 and [not a link( either"

## A real link keeps its label and drops the target from the plain rendering.
expect Markdown.plain_text("see [the guide](https://example.test/guide)") == "see the guide"

## Pins surprising existing behaviour. `javascript:` fails the scheme
## allowlist, so no link element is emitted -- but the label is re-parsed as
## plain text and the plain rendering keeps only "click". The unsafe target is
## dropped entirely rather than surfacing anywhere in the output.
expect Markdown.plain_text("[click](javascript:bad)") == "click"
