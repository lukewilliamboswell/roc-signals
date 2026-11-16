import pf.Engine exposing [Elem, Row, RowRef, Signal]
import pf.Html
import Markdown

## The preview panel: a parsed document, drawn. It is a view over a value
## and holds no state, so it is handed the parsed blocks and nothing else,
## and works in any scope.
##
## Blocks, list items, a list item's children and inline segments are each
## a keyed list, so an edit re-evaluates only the rows whose block or
## segment changed. What a block or a segment is decides its element, so
## each row holds a `switch` over its kind: a row must be one element, hence
## the `div` around a block and the `span` around a segment.
Preview := [].{

	## The panel over a document's parsed blocks.
	view : Signal(ctx, List(Markdown.Block)) -> Elem(ctx)
	view = |blocks| Engine.element(
		"section",
		[Engine.attr("aria-label", "Preview"), Engine.attr("data-panel", "preview"), Engine.class("panel flex flex-col")],
		[
			Html.div("panel-head", [Html.h2("Preview", "panel-title")]),
			Html.div(
				"panel-body content-start",
				[
					Engine.when(
						blocks.map(|l| l.is_empty()),
						|| Html.p("Preview is empty: type markdown to see it rendered.", "empty-state"),
						|| Engine.element(
							"div",
							[Engine.attr("data-panel", "preview-body"), Engine.class("prose-signals")],
							[Engine.each(blocks, |b| b.key, |row| Engine.element("div", [], [Engine.switch(row.field(|b| b.kind), kinds, |kind| block_view(row, kind))]))],
						),
					),
				],
			),
		],
	)
}

## A list item's child, keyed by its place among its siblings.
Child : { key : Str, text : Str }

keyed_children : List(Str) -> List(Child)
keyed_children = |texts| texts.map_with_index(|text, i| { key: "c:${i.to_str()}", text })

## Every inline style, for the `switch` in a segment's row.
styles : List(Markdown.Style)
styles = [Plain, Strong, Code, Image, Link]

## Every kind of block, for the `switch` in a block's row.
kinds : List(Markdown.Kind)
kinds = [Heading(1), Heading(2), Heading(3), Heading(4), Heading(5), Heading(6), Paragraph, Quote, CodeBlock, ListBlock]

## One inline segment, as the element its style calls for.
segment_view : RowRef(ctx, Markdown.Segment), Markdown.Style -> Elem(Row(ctx, Markdown.Segment))
segment_view = |row, style| {
	text = row.field(|s| s.text)
	href = row.field(|s| s.href)
	match style {
		Strong => Engine.element("strong", [], [Engine.text_s(text)])
		Code => Engine.element("code", [], [Engine.text_s(text)])
		Image => Engine.element("img", [Engine.attr_s("src", href), Engine.attr_s("alt", text), Engine.class("max-w-full")], [])
		Link => Engine.element("a", [Engine.attr_s("href", href), Engine.class("font-medium text-accent-700 underline underline-offset-2")], [Engine.text_s(text)])
		Plain => Engine.text_s(text)
	}
}

## A run of text with its inline markup.
inline_view : Signal(ctx, Str) -> Elem(ctx)
inline_view = |source| Engine.element(
	"span",
	[],
	[
		Engine.each(
			source.map(Markdown.inline_segments),
			|s| s.key,
			|row| Engine.element("span", [], [Engine.switch(row.field(|s| s.kind), styles, |style| segment_view(row, style))]),
		),
	],
)

## One list item, with its children nested one level.
item_view : RowRef(ctx, Markdown.ListItem) -> Elem(Row(ctx, Markdown.ListItem))
item_view = |row| Engine.element(
	"li",
	[],
	[
		inline_view(row.field(|i| i.text)),
		Engine.when(
			row.field(|i| i.children.is_empty()),
			|| Engine.text(""),
			|| Engine.element("ul", [], [Engine.each(row.field(|i| keyed_children(i.children)), |c| c.key, |child| Engine.element("li", [], [inline_view(child.field(|c| c.text))]))]),
		),
	],
)

heading_tag : U64 -> Engine.Tag
heading_tag = |level| match level {
	1 => "h1"
	2 => "h2"
	3 => "h3"
	4 => "h4"
	5 => "h5"
	_ => "h6"
}

## One block, as the element its kind calls for.
block_view : RowRef(ctx, Markdown.Block), Markdown.Kind -> Elem(Row(ctx, Markdown.Block))
block_view = |row, kind| {
	text = row.field(|b| b.text)
	match kind {
		Heading(level) => Engine.element(heading_tag(level), [Engine.class(if (level <= 3) "" else "mt-6 text-base font-semibold text-zinc-950")], [inline_view(text)])
		Quote => Engine.element("blockquote", [], [inline_view(text)])
		CodeBlock => Engine.element("pre", [], [Engine.element("code", [], [Engine.text_s(text)])])
		ListBlock => Engine.element("ul", [], [Engine.each(row.field(|b| b.items), |i| i.key, item_view)])
		Paragraph => Engine.element("p", [], [inline_view(text)])
	}
}

## A list item's children are keyed by position, so a child keeps its row
## while the text before it changes.
expect keyed_children(["a", "b"]) == [{ key: "c:0", text: "a" }, { key: "c:1", text: "b" }]

## Levels past six draw as the deepest heading the page has.
expect [1, 3, 6, 9].map(heading_tag) == ["h1", "h3", "h6", "h6"]
