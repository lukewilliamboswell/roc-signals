import pf.Engine exposing [Elem, RowRef, Val]
import pf.Html
import Markdown

## The table of contents: the heading spine of a document, its display rows,
## and the panel that draws them.
##
## `headings` reduces parsed markdown blocks to the heading spine and `rows`
## turns that spine into display rows. Splitting the two is what lets the
## outline stay quiet while the preview and the statistics keep updating: a
## paragraph edit changes the blocks but produces an identical heading list,
## so whoever derives the spine stops there and `rows` never runs.
##
## The panel is handed the spine as a value. Whether its rows are numbered
## is its own state: nothing else on the page reads it, so it lives in the
## panel and needs no cell in the app's store.
Outline := {}.{
	Heading : { level : U64, text : Str, slug : Str }

	Row : {
		key : Str,
		slug : Str,
		href : Str,
		level : U64,
		level_text : Str,
		label : Str,
		indent : Str,
	}

	SlugState : { out : List(U8), pending_dash : Bool }

	CollectState : { headings : List(Outline.Heading), used : List(Str) }

	RowState : { out : List(Outline.Row), ordinal : U64 }

	## Heading spine of a parsed document, in document order, with a unique
	## anchor slug per heading. Duplicate titles get a "-2", "-3", ... suffix so
	## keyed rows keep a stable identity.
	headings : List(Markdown.Block) -> List(Outline.Heading)
	headings = |blocks|
		blocks.fold({ headings: [], used: [] }, collect_heading).headings

	collect_heading : Outline.CollectState, Markdown.Block -> Outline.CollectState
	collect_heading = |state, block|
		match block.kind {
			Heading(level) => {
				text = Markdown.plain_text(block.text)
				base = slugify(text)
				seen = state.used.keep_if(|value| value == base).len()
				slug = if seen == 0 {
					base
				} else {
					"${base}-${(seen + 1).to_str()}"
				}
				{
					headings: state.headings.append({ level, text, slug }),
					used: state.used.append(base),
				}
			}
			_ => state
		}

	## Lowercase ASCII slug: letters and digits survive, every other run of
	## bytes collapses to a single "-", and leading/trailing dashes never
	## appear. A heading made only of punctuation slugs to "section".
	slugify : Str -> Str
	slugify = |text| {
		folded = text.to_utf8().fold({ out: [], pending_dash: False }, slug_step)
		if folded.out.is_empty() {
			"section"
		} else {
			Str.from_utf8_lossy(folded.out)
		}
	}

	slug_step : Outline.SlugState, U8 -> Outline.SlugState
	slug_step = |acc, byte|
		if (byte >= 97 and byte <= 122) or (byte >= 48 and byte <= 57) {
			{ out: push_byte(acc, byte), pending_dash: False }
		} else if byte >= 65 and byte <= 90 {
			{ out: push_byte(acc, byte + 32), pending_dash: False }
		} else {
			{ ..acc, pending_dash: True }
		}

	push_byte : Outline.SlugState, U8 -> List(U8)
	push_byte = |acc, byte|
		if acc.pending_dash and !acc.out.is_empty() {
			acc.out.append(45).append(byte)
		} else {
			acc.out.append(byte)
		}

	## Display rows for the outline. `numbered` prefixes each row with its
	## document-order ordinal; indentation always reflects the heading level,
	## including levels that skip (a level 3 followed by a level 5).
	rows : List(Outline.Heading), Bool -> List(Outline.Row)
	rows = |items, numbered| {
		start : Outline.RowState
		start = { out: [], ordinal: 0 }
		items.fold(
			start,
			|acc, heading| {
				ordinal = acc.ordinal + 1
				label = if numbered {
					"${ordinal.to_str()}. ${heading.text}"
				} else {
					heading.text
				}
				{
					out: acc.out.append({
						key: "toc:${heading.slug}",
						slug: heading.slug,
						href: "#${heading.slug}",
						level: heading.level,
						level_text: heading.level.to_str(),
						label,
						indent: indent_class(heading.level),
					}),
					ordinal,
				}
			},
		).out
	}

	indent_class : U64 -> Str
	indent_class = |level|
		match level {
			1 => "pl-0"
			2 => "pl-3"
			3 => "pl-6"
			4 => "pl-9"
			5 => "pl-12"
			_ => "pl-16"
		}

	## The panel over a document's heading spine. A row is keyed by its
	## heading's slug, so numbering relabels rows in place and a heading
	## that moves or changes level keeps its row.
	view : Val(ctx, List(Outline.Heading)) -> Elem(ctx)
	view = |spine| Engine.state(
		True,
		|numbered| {
			found = spine.lift()
			Engine.element(
				"section",
				[Engine.attr("aria-label", "Table of contents"), Engine.attr("data-panel", "outline"), Engine.class("panel")],
				[
					Html.div(
						"panel-head",
						[
							Html.h2("Table of contents", "panel-title"),
							Html.div("check-row", [Html.checkbox(Engine.const("Number the outline"), numbered.val(), [Engine.class("checkbox")], numbered.set_value(|_, checked| checked == "true")), Html.p("Number the outline", "")]),
						],
					),
					Html.div(
						"panel-body",
						[
							Engine.when(
								found.map(|l| l.is_empty()),
								|| Html.p("No headings yet: add a line that starts with a hash.", "empty-state"),
								|| Engine.element("ul", [Engine.attr("data-panel", "outline-body"), Engine.class("grid gap-0.5")], [Engine.each(found.map2(numbered.val(), Outline.rows), |r| r.key, row_view)]),
							),
						],
					),
				],
			)
		},
	)
}

## One row of the panel: a link to its heading, indented by level.
row_view : RowRef(ctx, Outline.Row) -> Elem(Engine.Row(ctx, Outline.Row))
row_view = |row| Engine.element(
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

## Slugs are lowercased and spaces become single dashes.
expect Outline.slugify("Roc Signals Field Guide") == "roc-signals-field-guide"

## Punctuation is dropped, and a trailing dash never survives.
expect Outline.slugify("Deep Dive!") == "deep-dive"

## A title with no slug-able bytes still gets a usable key.
expect Outline.slugify("***") == "section"

## The outline reads the heading spine out of the parsed document, keeping
## each heading's level and its stripped text.
expect Outline.headings(Markdown.parse("# Alpha\n\ntext\n\n## Beta")) == [
	{ level: 1, text: "Alpha", slug: "alpha" },
	{ level: 2, text: "Beta", slug: "beta" },
]

## Duplicate titles are disambiguated with a counter so row keys stay distinct
## and stable across redraws.
expect Outline.headings(Markdown.parse("# Alpha\n\n# Alpha")).map(|heading| heading.slug) == ["alpha", "alpha-2"]

## Numbering on prefixes each row label with its position.
expect Outline.rows([{ level: 3, text: "Beta", slug: "beta" }], True).map(|row| row.label) == ["1. Beta"]

## Numbering off leaves the heading text as the whole label.
expect Outline.rows([{ level: 3, text: "Beta", slug: "beta" }], False).map(|row| row.label) == ["Beta"]

## Indentation comes from the heading level, not from the numbering toggle.
expect Outline.rows([{ level: 3, text: "Beta", slug: "beta" }], False).map(|row| row.indent) == ["pl-6"]
