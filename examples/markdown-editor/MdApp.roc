import pf.Engine exposing [Elem]
import pf.Html
import AppStore
import Edit
import Markdown
import Outline
import Preview
import Stats

## Markdown Editor: one source text and four views of it.
##
## The document is the one cell of the app's store (`AppStore`). This
## module composes the page: it parses the document once and derives the
## heading spine from the parse, both memoised, and hands each panel what
## it draws.
##
## - The editor panel, here, writes the document: typing replaces it and
##   the toolbar runs the pure commands of `Edit` on it.
## - `Stats` is handed the document's cell and counts it itself.
## - `Preview` is handed the parsed blocks.
## - `Outline` is handed the heading spine.
##
## An edit that leaves the heading spine equal stops there: the parse
## changes, so the preview's changed rows update, and the table of contents
## does no work. The reading speed and the numbering toggle are local to
## their panels, so neither reaches anything outside its panel.
MdApp := [].{

	## The page. The parse and the heading spine are each one `derive`, so
	## each is computed once per change of the document however many panels
	## read it, and a spine equal to the last one wakes none of its readers.
	view : {} -> Elem(Engine.StoreRoot(_))
	view = |{}| Engine.derive(
		AppStore.cells.source.signal().map(Markdown.parse),
		|blocks| Engine.derive(
			blocks.map(Outline.headings),
			|spine| Html.div(
				"app-shell app-shell-wide",
				[
					Html.section("Markdown Editor", "app-header", [Html.h1("Markdown Editor", "app-title"), Html.p("One source string, four independently derived views.", "app-subtitle")]),
					Stats.view({ source: AppStore.cells.source }, spine.map(|found| found.len())),
					Html.div("grid gap-6 lg:grid-cols-2", [editor({}), Preview.view(blocks.lift())]),
					Outline.view(spine),
				],
			),
		),
	)

	## The program `main.roc` binds for the browser module and the native spec
	## runner.
	program : Engine.Program
	program = Engine.program_store({ storage_keys: [], max_inflight: 32 }, |_| AppStore.store, |_| MdApp.view({}))
}

## A captioned row of buttons.
button_group : Str, List(Elem(ctx)) -> Elem(ctx)
button_group = |caption, buttons| Html.div("grid gap-2", [Html.p(caption, "hint"), Html.div("toolbar", buttons)])

## A button that replaces the document with a prepared one.
load_button : { label : Str, class : Str, document : Str } -> Elem(ctx)
	where [ctx.store : () -> Engine.Reach(ctx, _)]
load_button = |{ label, class, document }| Html.button(label, [Engine.class(class)], Engine.does(AppStore.replaced(document)))

## A button that runs one of `Edit`'s commands on the document.
edit_button : Str, (Str -> Str) -> Elem(ctx)
	where [ctx.store : () -> Engine.Reach(ctx, _)]
edit_button = |label, command| Html.button(label, [Engine.class("button button-sm")], Engine.does(AppStore.edited(command)))

## The editor panel: the source text and the buttons that change it. It
## reads and writes the document's cell and nothing else, so it needs
## nothing from the scope it is drawn in.
editor : {} -> Elem(ctx)
	where [ctx.store : () -> Engine.Reach(ctx, _)]
editor = |{}| Engine.element(
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
						Engine.element("textarea", [Engine.attr("aria-label", "Markdown source"), Engine.attr_s("value", AppStore.cells.source.signal()), Engine.class("input textarea font-mono min-h-96 text-sm"), Engine.on("input", Engine.handle(AppStore.replaced))], []),
						Html.p("Headings, lists, fenced code, quotes, and links all render live in the preview.", "hint"),
					],
				),
				button_group(
					"Documents",
					[
						load_button({ label: "Load sample document", class: "button button-primary button-sm", document: AppStore.sample_document }),
						load_button({ label: "Load document without headings", class: "button button-sm", document: AppStore.no_heading_document }),
						load_button({ label: "Load heading drill", class: "button button-sm", document: AppStore.heading_drill_document }),
					],
				),
				button_group(
					"Edit the document",
					[
						edit_button("Append a word", Edit.append_word),
						edit_button("Append a section", Edit.append_section),
						edit_button("Move the last section up", Edit.move_last_section_up),
						edit_button("Demote the last heading", Edit.demote_last_heading),
						edit_button("Remove the last section", Edit.remove_last_section),
						load_button({ label: "Clear document", class: "button-danger button-sm", document: "" }),
					],
				),
			],
		),
	],
)
