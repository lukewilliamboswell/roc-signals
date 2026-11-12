import pf.Engine exposing [Elem, Row, RowRef, Val]
import Markdown

## Markdown, drawn: an article's body, generic in the context. It needs no
## state, so any view imports it rather than being handed it.
MarkdownView := [].{

	inline_view : Val(ctx, Str) -> Elem(ctx)
	inline_view = |src| Engine.element("span", [], [Engine.each(src.map(Markdown.inline_segments), |s| s.key, |seg| MarkdownView.md_segment(seg))])

	md_segment : RowRef(ctx, Markdown.Segment) -> Elem(Row(ctx, Markdown.Segment))
	md_segment = |seg| {
		text = seg.field(|s| s.text)
		href = seg.field(|s| s.href)
		Engine.element(
			"span",
			[],
			[
				Engine.switch(
					seg.field(|s| s.kind),
					[Strong, Code, Image, Link, Text],
					|k| match k {
						Strong => Engine.element("strong", [], [Engine.text_v(text)])
						Code => Engine.element("code", [Engine.class("bg-zinc-100 px-1 font-mono")], [Engine.text_v(text)])
						Image => Engine.element("img", [Engine.attr_v("src", href), Engine.attr_v("alt", text)], [])
						Link => Engine.element("a", [Engine.attr_v("href", href)], [Engine.text_v(text)])
						Text => Engine.text_v(text)
					},
				),
			],
		)
	}

	keyed_children : List(Str) -> List({ key : Str, text : Str })
	keyed_children = |texts| {
		var $out = []
		var $i = 0.U64
		for t in texts {
			$out = $out.append({ key: "c:${$i.to_str()}", text: t })
			$i = $i + 1
		}
		$out
	}

	md_item : RowRef(ctx, Markdown.ListItem) -> Elem(Row(ctx, Markdown.ListItem))
	md_item = |item| Engine.element(
		"li",
		[],
		[
			MarkdownView.inline_view(item.field(|i| i.text)),
			Engine.when(
				item.field(|i| !i.children.is_empty()),
				|| Engine.element("ul", [], [Engine.each(item.field(|i| MarkdownView.keyed_children(i.children)), |c| c.key, |child| Engine.element("li", [], [MarkdownView.inline_view(child.field(|c| c.text))]))]),
				|| Engine.text(""),
			),
		],
	)

	md_block : RowRef(ctx, Markdown.Block) -> Elem(Row(ctx, Markdown.Block))
	md_block = |row| {
		text = row.field(|b| b.text)
		Engine.element(
			"div",
			[],
			[
				Engine.switch(
					row.field(|b| b.kind),
					[Heading, Quote, CodeBlock, ListBlock, Paragraph],
					|k| match k {
						Heading => Engine.element("h3", [], [Engine.text_v(text)])
						Quote => Engine.element("blockquote", [], [MarkdownView.inline_view(text)])
						CodeBlock => Engine.element("pre", [Engine.class("overflow-x-auto bg-zinc-900 p-4 font-mono text-sm text-zinc-100")], [Engine.element("code", [], [Engine.text_v(text)])])
						ListBlock => Engine.element("ul", [], [Engine.each(row.field(|b| b.items), |i| i.key, |item| MarkdownView.md_item(item))])
						Paragraph => Engine.element("p", [], [MarkdownView.inline_view(text)])
					},
				),
			],
		)
	}

	markdown : Val(ctx, Str) -> Elem(ctx)
	markdown = |src| Engine.element("div", [Engine.attr("data-conduit", "markdown"), Engine.class("conduit-prose my-10")], [Engine.each(src.map(Markdown.parse), |b| b.key, |row| MarkdownView.md_block(row))])
}
