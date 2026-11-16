## Markdown parsing for the editor: headings (levels 1-6), paragraphs,
## quotes, fenced code blocks, one-level nested lists, bold, inline code,
## links, and images. Links and image sources pass a scheme allowlist;
## anything else degrades to plain text, and nothing is ever injected as raw
## HTML. A heading's level is part of its block's kind, so the outline is
## derived from the parsed blocks rather than by scanning the source again.

Markdown := {}.{
	ListItem : { key : Str, text : Str, children : List(Str) }

	## What a parsed block *is*. The heading level rides in the tag, so there is
	## no "level is 0 for everything that is not a heading" sentinel to forget.
	Kind := [Heading(U64), Paragraph, Quote, CodeBlock, ListBlock].{
		is_eq : _
	}

	Block : { key : Str, kind : Markdown.Kind, text : Str, items : List(Markdown.ListItem) }

	## Inline markup carried by one run of text.
	Style := [Plain, Strong, Code, Image, Link].{
		is_eq : _
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

	## A block's key is its place in the document, whatever its kind: a block
	## whose kind changes keeps its row, and the `switch` in that row draws
	## the new kind's element.
	block_key : U64 -> Str
	block_key = |index| "b:${index.to_str()}"

	append_block : Markdown.ParseState, Markdown.Kind, Str, List(Markdown.ListItem) -> Markdown.ParseState
	append_block = |state, kind, text, items| {
		{
			..state,
			blocks: state.blocks.append({ key: block_key(state.index), kind, text, items }),
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

	## A segment's key is its place in its line of text, whatever its style.
	segment_key : U64 -> Str
	segment_key = |index| "s:${index.to_str()}"

	append_segment : Markdown.InlineState, Markdown.Style, Str, Str -> Markdown.InlineState
	append_segment = |state, kind, text, href| {
		if text.is_empty() {
			state
		} else {
			{
				segments: state.segments.append({ key: segment_key(state.index), kind, text, href }),
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

	## Serialize the supported Markdown as HTML for a clipboard item. Source text
	## and attribute values always pass through the escaping builder, including
	## fenced code; raw HTML in a document stays literal text, as in the preview.
	to_html : Str -> Str
	to_html = |source| Markup.join(parse(source).map(block_html), Lines).to_str()

}

# The HTML serializer has one constructor for outside text and closed element
# constructors. Only this builder can introduce markup into a serialized result.
Markup :: Str.{
	Tag : [H1, H2, H3, H4, H5, H6, P, Blockquote, Pre, Code, Ul, Li, Strong]

	text : Str -> Markup
	text = |source_text| Markup.(escape(source_text))

	element : Markup.Tag, Markup -> Markup
	element = |tag, Markup.(body)| {
		name = match tag {
			H1 => "h1"
			H2 => "h2"
			H3 => "h3"
			H4 => "h4"
			H5 => "h5"
			H6 => "h6"
			P => "p"
			Blockquote => "blockquote"
			Pre => "pre"
			Code => "code"
			Ul => "ul"
			Li => "li"
			Strong => "strong"
		}
		Markup.("<${name}>${body}</${name}>")
	}

	link : { href : Str, body : Markup } -> Markup
	link = |{ href, body: Markup.(body) }| Markup.("<a href=\"${escape(href)}\">${body}</a>")

	image : { href : Str, alt : Str } -> Markup
	image = |{ href, alt }| Markup.("<img src=\"${escape(href)}\" alt=\"${escape(alt)}\">")

	join : List(Markup), [Adjacent, Lines] -> Markup
	join = |parts, spacing| Markup.(
		Str.join_with(
			parts.map(|Markup.(part)| part),
			match spacing {
				Adjacent => ""
				Lines => "\n"
			},
		),
	)

	to_str : Markup -> Str
	to_str = |Markup.(rendered)| rendered
}

escape : Str -> Str
escape = |text| {
	ampersands = Str.join_with(text.split_on("&"), "&amp;")
	opening = Str.join_with(ampersands.split_on("<"), "&lt;")
	closing = Str.join_with(opening.split_on(">"), "&gt;")
	quotes = Str.join_with(closing.split_on("\""), "&quot;")
	Str.join_with(quotes.split_on("'"), "&#39;")
}

inline_html : Str -> Markup
inline_html = |source| Markup.join(
	Markdown.inline_segments(source).map(
		|segment| match segment.kind {
			Plain => Markup.text(segment.text)
			Strong => Markup.element(Strong, Markup.text(segment.text))
			Code => Markup.element(Code, Markup.text(segment.text))
			Link => Markup.link({ href: segment.href, body: Markup.text(segment.text) })
			Image => Markup.image({ href: segment.href, alt: segment.text })
		},
	),
	Adjacent,
)

block_html : Markdown.Block -> Markup
block_html = |block| match block.kind {
	Heading(level) => {
		tag = match level {
			1 => H1
			2 => H2
			3 => H3
			4 => H4
			5 => H5
			6 => H6
			_ => crash "Markdown.to_html: a parsed heading level is outside 1–6"
		}
		Markup.element(tag, inline_html(block.text))
	}
	Paragraph => Markup.element(P, inline_html(block.text))
	Quote => Markup.element(Blockquote, inline_html(block.text))
	CodeBlock => Markup.element(Pre, Markup.element(Code, Markup.text(block.text)))
	ListBlock => Markup.element(
		Ul,
		Markup.join(
			block.items.map(
				|item| {
					children = if (item.children.is_empty()) Markup.text("") else Markup.element(Ul, Markup.join(item.children.map(|child| Markup.element(Li, inline_html(child))), Adjacent))
					Markup.element(Li, Markup.join([inline_html(item.text), children], Adjacent))
				},
			),
			Adjacent,
		),
	)
}

## Copied HTML follows the preview's supported blocks and inline markup.
expect Markdown.to_html("# Title\n\nA **strong** word and `code`.\n\n> quote\n\n- parent\n  - child") == "<h1>Title</h1>\n<p>A <strong>strong</strong> word and <code>code</code>.</p>\n<blockquote>quote</blockquote>\n<ul><li>parent<ul><li>child</li></ul></li></ul>"

## Raw markup, quotes and ampersands remain text in copied HTML and attributes.
expect Markdown.to_html("<script>alert(\"x\")</script> & <img>\n\n[x\"<](https://example.test/?x=\"&y=<)\n\n![a\"&<](https://example.test/\"<)") == "<p>&lt;script&gt;alert(&quot;x&quot;)&lt;/script&gt; &amp; &lt;img&gt;</p>\n<p><a href=\"https://example.test/?x=&quot;&amp;y=&lt;\">x&quot;&lt;</a></p>\n<p><img src=\"https://example.test/&quot;&lt;\" alt=\"a&quot;&amp;&lt;\"></p>"

## Unsafe URL schemes stay plain text, and fenced markup never becomes an element.
expect Markdown.to_html("[run](javascript:alert)\n\n```\n<script>\n```\n\n###### Six") == "<p>run</p>\n<pre><code>&lt;script&gt;</code></pre>\n<h6>Six</h6>"
