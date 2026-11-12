import pf.Engine exposing [Comp, Elem, In, Root, Row, RowRef, State, Val]
import pf.Html
import Markdown
import Outline
import Stats
import Edit

## Markdown Editor on the Roc-owned engine: ported from the previous engine.
##
## Three sources (source text, outline numbering, reading speed) and four
## memoised derivations (blocks, counts, headings, outline rows), so an edit
## that leaves the heading spine equal stops at `headings`. The preview and
## the outline are components: the preview's nested each/switch tree (blocks,
## list items, children, inline segments) is specialised once, over its prop.
##
## Port difference: an each row must be a single element, so rows whose
## original root was a bare switch (a block, an inline segment) get a wrapper
## element (div for blocks, span for segments). Text and roles are unchanged.
MdApp := [].{
	Hs(ctx) : { source : State(ctx, Str), numbered : State(ctx, Bool), speed : State(ctx, Str) }

	lift_hs : Hs(ctx) -> Hs(In(ctx, a))
	lift_hs = |{ source, numbered, speed }| { source: source.lift(), numbered: numbered.lift(), speed: speed.lift() }

	sample_document : Str
	sample_document = "# Roc Signals Field Guide\n\nSignals keep the graph alive instead of rebuilding a whole view after every event.\n\n## Getting Started\n\nRun `roc check main.roc` before you build anything larger, then read the guide.\n\n- Read the guide end to end\n- Skim the gallery examples\n  - Live search covers async and cleanup\n- Write the spec first\n\n### Editor Notes\n\nSpecial characters such as * and _ and # stay literal when they are not real markup.\n\nA line that says 2 * 3 = 6 is arithmetic, not emphasis, and [not a link( either.\n\n##### Deep Dive\n\nThis heading skips from level three to level five on purpose.\n\n## Performance\n\n> Keep derived values derived.\n\n```\n# this hash lives inside a fence and is not a heading\n```\n\nUse **map2** for fan-in and `combine` for wide fan-in, and see [the guide](https://example.test/guide) for more."

	no_heading_document : Str
	no_heading_document = "Just a paragraph with no headings at all.\n\nAnd a second paragraph so the preview has something to show."

	heading_drill_document : Str
	heading_drill_document = "# Alpha\n\n## Beta\n\n## Gamma\n\n## Delta"

	## ------------------------------------------------------------------
	## Preview component.

	PC : Comp(List(Markdown.Block), {})

	Child : { key : Str, text : Str }

	keyed_children : List(Str) -> List(Child)
	keyed_children = |texts| texts.map_with_index(|text, i| { key: "c:${i.to_str()}", text })

	styles : List(Markdown.Style)
	styles = [Plain, Strong, Code, Image, Link]

	kinds : List(Markdown.Kind)
	kinds = [Heading(1), Heading(2), Heading(3), Heading(4), Heading(5), Heading(6), Paragraph, Quote, CodeBlock, ListBlock]

	segment_view : RowRef(ctx, Markdown.Segment), Markdown.Style -> Elem(Row(ctx, Markdown.Segment))
	segment_view = |row, style| {
		text = row.field(|s| s.text)
		href = row.field(|s| s.href)
		match style {
			Strong => Engine.element("strong", [], [Engine.text_v(text)])
			Code => Engine.element("code", [], [Engine.text_v(text)])
			Image => Engine.element("img", [Engine.attr_v("src", href), Engine.attr_v("alt", text), Engine.class("max-w-full rounded-md")], [])
			Link => Engine.element("a", [Engine.attr_v("href", href), Engine.class("font-medium text-emerald-700 underline underline-offset-2")], [Engine.text_v(text)])
			Plain => Engine.text_v(text)
		}
	}

	inline_view : Val(ctx, Str) -> Elem(ctx)
	inline_view = |source| Engine.element(
		"span",
		[],
		[
			Engine.each(
				source.map(Markdown.inline_segments),
				|s| s.key,
				|row| Engine.element("span", [], [Engine.switch(row.field(|s| s.kind), MdApp.styles, |st| MdApp.segment_view(row, st))]),
			),
		],
	)

	item_view : RowRef(ctx, Markdown.ListItem) -> Elem(Row(ctx, Markdown.ListItem))
	item_view = |row| Engine.element(
		"li",
		[],
		[
			MdApp.inline_view(row.field(|i| i.text)),
			Engine.when(
				row.field(|i| i.children.is_empty()),
				|| Engine.text(""),
				|| Engine.element("ul", [], [Engine.each(row.field(|i| MdApp.keyed_children(i.children)), |c| c.key, |child| Engine.element("li", [], [MdApp.inline_view(child.field(|c| c.text))]))]),
			),
		],
	)

	heading_tag : U64 -> Str
	heading_tag = |level| match level {
		1 => "h1"
		2 => "h2"
		3 => "h3"
		4 => "h4"
		5 => "h5"
		_ => "h6"
	}

	block_view : RowRef(PC, Markdown.Block), Markdown.Kind -> Elem(Row(PC, Markdown.Block))
	block_view = |row, kind| {
		text = row.field(|b| b.text)
		match kind {
			Heading(level) => Engine.element(MdApp.heading_tag(level), [Engine.class(if (level <= 3) "" else "mt-6 text-base font-semibold text-zinc-950")], [MdApp.inline_view(text)])
			Quote => Engine.element("blockquote", [], [MdApp.inline_view(text)])
			CodeBlock => Engine.element("pre", [], [Engine.element("code", [], [Engine.text_v(text)])])
			ListBlock => Engine.element("ul", [], [Engine.each(row.field(|b| b.items), |i| i.key, MdApp.item_view)])
			Paragraph => Engine.element("p", [], [MdApp.inline_view(text)])
		}
	}

	preview : Val(PC, List(Markdown.Block)), State(PC, List({})) -> Elem(PC)
	preview = |blocks, _| Engine.element(
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
							[Engine.each(blocks, |b| b.key, |row| Engine.element("div", [], [Engine.switch(row.field(|b| b.kind), MdApp.kinds, |k| MdApp.block_view(row, k))]))],
						),
					),
				],
			),
		],
	)

	## ------------------------------------------------------------------
	## Outline component: its checkbox routes the numbering toggle outward.

	OutlineProp : { rows : List(Outline.Row), numbered : Bool }

	OC : Comp(OutlineProp, Bool)

	outline_row : RowRef(OC, Outline.Row) -> Elem(Row(OC, Outline.Row))
	outline_row = |row| Engine.element(
		"li",
		[Engine.class_v(row.field(|r| r.indent))],
		[
			Engine.element(
				"a",
				[Engine.test_id_v(row.key()), Engine.attr_v("href", row.field(|r| r.href)), Engine.attr_v("data-level", row.field(|r| r.level_text)), Engine.class("block rounded px-2 py-1 text-sm text-zinc-700 transition hover:bg-zinc-100 hover:text-emerald-700")],
				[Engine.text_v(row.field(|r| r.label))],
			),
		],
	)

	outline : Val(OC, OutlineProp), State(OC, List(Bool)) -> Elem(OC)
	outline = |op, out| {
		rows = op.map(|p| p.rows)
		Engine.element(
			"section",
			[Engine.attr("aria-label", "Table of contents"), Engine.attr("data-panel", "outline"), Engine.class("panel")],
			[
				Html.div(
					"panel-head",
					[
						Html.h2("Table of contents", "panel-title"),
						Html.div("check-row", [Html.checkbox(Engine.const("Number the outline"), op.map(|p| p.numbered), [Engine.class("checkbox")], out.push_value_by(Engine.const({}), |_, v| v == "true")), Html.p("Number the outline", "")]),
					],
				),
				Html.div(
					"panel-body",
					[
						Engine.when(
							rows.map(|l| l.is_empty()),
							|| Html.p("No headings yet: add a line that starts with a hash.", "empty-state"),
							|| Engine.element("ul", [Engine.attr("data-panel", "outline-body"), Engine.class("grid gap-0.5")], [Engine.each(rows, |r| r.key, MdApp.outline_row)]),
						),
					],
				),
			],
		)
	}

	## ------------------------------------------------------------------
	## Page.

	button_group : Str, List(Elem(ctx)) -> Elem(ctx)
	button_group = |caption, buttons| Html.div("grid gap-2", [Html.p(caption, "hint"), Html.div("toolbar", buttons)])

	stat_tile : Str, Str, Val(ctx, Str) -> Elem(ctx)
	stat_tile = |caption, id, value| Html.div("stat", [Html.p(caption, "stat-label"), Html.p_v(value, [Engine.test_id(id), Engine.class("stat-value numeric")])])

	edit_button : State(ctx, Str), Str, Str, (Str -> Str) -> Elem(ctx)
	edit_button = |source, label, cls, f| Html.button(label, [Engine.class(cls)], source.update(f))

	page : Hs(ctx), Val(ctx, List(Markdown.Block)), Val(ctx, Stats.Counts), Val(ctx, U64), Val(ctx, List(Outline.Row)) -> Elem(ctx)
	page = |hs, blocks, counts, heading_count, rows| {
		minutes = counts.map2(hs.speed.val(), |c, s| Stats.reading_minutes(c.words, Stats.parse_wpm(s)))
		summary = counts.map2(heading_count.map2(minutes, |h, m| (h, m)), |c, (h, m)| "${c.words.to_str()} words | ${c.characters.to_str()} characters | ${h.to_str()} headings | ${m.to_str()} min")
		src = hs.source
		Html.div(
			"app-shell app-shell-wide",
			[
				Html.section("Markdown Editor", "app-header", [Html.h1("Markdown Editor", "app-title"), Html.p("One source string, four independently derived views.", "app-subtitle")]),
				Engine.element(
					"section",
					[Engine.attr("aria-label", "Statistics"), Engine.attr("data-panel", "statistics"), Engine.class("panel")],
					[
						Html.div("panel-head", [Html.h2("Statistics", "panel-title"), Html.p_v(summary, [Engine.test_id("stat-summary"), Engine.class("hint numeric")])]),
						Html.div(
							"panel-body",
							[
								Html.div(
									"stat-grid",
									[
										MdApp.stat_tile("Words", "stat-words", counts.map(|c| c.words.to_str())),
										MdApp.stat_tile("Characters", "stat-characters", counts.map(|c| c.characters.to_str())),
										MdApp.stat_tile("Headings", "stat-headings", heading_count.map(|n| n.to_str())),
										MdApp.stat_tile("Reading time", "stat-reading", minutes.map(|m| "${m.to_str()} min")),
									],
								),
								Html.div(
									"field sm:max-w-xs",
									[
										Html.p("Reading speed", "field-label"),
										Html.select(Engine.const("Reading speed"), hs.speed.val(), [Engine.class("input")], [Html.option("100", "Careful (100 wpm)"), Html.option("200", "Average (200 wpm)"), Html.option("300", "Fast (300 wpm)")], hs.speed.set_value(|_, v| v)),
										Html.p("The estimate is a fan-in of the word count and this speed; it never touches the preview or the outline.", "hint"),
									],
								),
							],
						),
					],
				),
				Html.div(
					"grid gap-6 lg:grid-cols-2",
					[
						Engine.element(
							"section",
							[Engine.attr("aria-label", "Editor"), Engine.attr("data-panel", "editor"), Engine.class("panel flex flex-col")],
							[
								Html.div("panel-head", [Html.h2("Editor", "panel-title")]),
								Html.div(
									"panel-body content-start",
									[
										Html.div(
											"field",
											[
												Html.p("Markdown source", "field-label"),
												Engine.element("textarea", [Engine.attr("aria-label", "Markdown source"), Engine.attr_v("value", src.val()), Engine.class("input textarea font-mono min-h-96 text-sm"), Engine.on("input", src.set_value(|_, v| v))], []),
												Html.p("Headings, lists, fenced code, quotes, and links all render live in the preview.", "hint"),
											],
										),
										MdApp.button_group(
											"Documents",
											[
												MdApp.edit_button(src, "Load sample document", "button button-primary button-sm", |_| MdApp.sample_document),
												MdApp.edit_button(src, "Load document without headings", "button button-sm", |_| MdApp.no_heading_document),
												MdApp.edit_button(src, "Load heading drill", "button button-sm", |_| MdApp.heading_drill_document),
											],
										),
										MdApp.button_group(
											"Edit the document",
											[
												MdApp.edit_button(src, "Append a word", "button button-sm", Edit.append_word),
												MdApp.edit_button(src, "Append a section", "button button-sm", Edit.append_section),
												MdApp.edit_button(src, "Move the last section up", "button button-sm", Edit.move_last_section_up),
												MdApp.edit_button(src, "Demote the last heading", "button button-sm", Edit.demote_last_heading),
												MdApp.edit_button(src, "Remove the last section", "button button-sm", Edit.remove_last_section),
												MdApp.edit_button(src, "Clear document", "button-danger button-sm", |_| ""),
											],
										),
									],
								),
							],
						),
						Engine.component(blocks, Engine.discard({}), MdApp.preview),
					],
				),
				Engine.component(rows.map2(hs.numbered.val(), |r, n| { rows: r, numbered: n }), Engine.sink(hs.numbered, |_, v| v), MdApp.outline),
			],
		)
	}

	## The program `main.roc` binds for the browser module and the native spec
	## runner.
	program : Engine.Program
	program = Engine.program(|| MdApp.main({}))

	main : {} -> Elem(Root)
	main = |_| MdApp.main_with(MdApp.sample_document)

	main_with : Str -> Elem(Root)
	main_with = |doc| Engine.state(
		doc,
		|source| Engine.state(
			True,
			|numbered| Engine.state(
				"200",
				|speed| {
					hs3 = { source: source.lift().lift(), numbered: numbered.lift(), speed }
					Engine.derive(
						hs3.source.val().map(Markdown.parse),
						|blocks| {
							hs4 = MdApp.lift_hs(hs3)
							Engine.derive(
								hs4.source.val().map(Stats.counts),
								|counts| {
									hs5 = MdApp.lift_hs(hs4)
									b5 = blocks.lift()
									Engine.derive(
										b5.map(Outline.headings),
										|headings| {
											hs6 = MdApp.lift_hs(hs5)
											Engine.derive(
												headings.map2(hs6.numbered.val(), Outline.rows),
												|rows| MdApp.page(MdApp.lift_hs(hs6), b5.lift().lift(), counts.lift().lift(), headings.map(|l| l.len()).lift(), rows),
											)
										},
									)
								},
							)
						},
					)
				},
			),
		),
	)
}
