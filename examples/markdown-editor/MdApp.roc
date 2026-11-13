import pf.Engine exposing [Elem]
import pf.Html
import pf.Clipboard
import AppStore
import Edit
import Markdown
import Outline
import Preview
import Stats

## Markdown Editor: one source text and four views of it.
##
## The source is one cell of the app's store (`AppStore`). This
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
				].concat(persistence_sites({})),
			),
		),
	)

	## The program `main.roc` binds for the browser module and the native spec
	## runner.
	program : Engine.Program
	program = Engine.program_store({ storage_keys: ["md.document"], session_keys: ["md.draft"] }, AppStore.start, |_| MdApp.view({}))
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
## composes the document decisions with persistence and copy controls. Its
## cells can be reached at any depth, without a fixed scope.
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
						Engine.element("textarea", [Engine.attr("aria-label", "Markdown source"), Engine.ref("md.source"), Engine.prop_s(Engine.Prop.value, AppStore.cells.source.signal()), Engine.class("input textarea font-mono min-h-96 text-sm"), Engine.on("input", Engine.handle(AppStore.replaced))], []),
						Html.p("Headings, lists, fenced code, quotes, and links all render live in the preview.", "hint"),
					],
				),
				persistence_controls({}),
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

dirty : {} -> Engine.Signal(ctx, Bool)
	where [ctx.store : () -> Engine.Reach(ctx, _)]
dirty = |_| { revision: AppStore.cells.revision.signal(), saved_revision: AppStore.cells.saved_revision.signal() }.Engine.Signal.map(AppStore.is_dirty)

## Every storage, clipboard and leave policy uses ordinary sites. Source
## replacements and draft writes are explicit decisions, never a two-way binding.
persistence_sites : {} -> List(Elem(ctx))
	where [ctx.store : () -> Engine.Reach(ctx, _)]
persistence_sites = |_| [
	Engine.guard_leave(dirty({})),
	Engine.on_post_by(AppStore.cells.drafts.signal(), AppStore.cells.source.signal(), |text, _| [Engine.command(SessionStorageSet("md.draft", text))], Engine.ignore({})),
	Engine.on_post_by(AppStore.cells.saves.signal(), AppStore.cells.source.signal(), |text, _| [Engine.command(StorageSet("md.document", text))], Engine.ignore({})),
	Engine.on_post(AppStore.cells.apply_source.signal(), |_| [Engine.command(ApplyValue("md.source"))], Engine.ignore({})),
	Engine.on_post_by(
		AppStore.cells.copies.signal(),
		AppStore.cells.source.signal(),
		|text, format| [
			match format {
				Markdown => Clipboard.text(text)
				Html => Clipboard.html({ text, html: Markdown.to_html(text) })
			},
		],
		Engine.react(|_, result| AppStore.copy_answered(result)),
	),
	Engine.watch(
		Engine.const({}),
		|_| [Engine.storage_changes("md.document")],
		Engine.react_by(
			{ revision: AppStore.cells.revision.signal(), saved_revision: AppStore.cells.saved_revision.signal() }.Engine.Signal,
			|current, _, result| AppStore.heard_elsewhere(current, result),
		),
	),
	Engine.watch(Engine.const({}), |_| [Engine.storage_write_failures({})], Engine.react(|_, result| AppStore.storage_failed(result))),
]

readout : Str, Engine.Signal(ctx, Str) -> Elem(ctx)
readout = |name, value| Engine.element("p", [Engine.test_id(name), Engine.class("hint"), Engine.attr("aria-live", "polite")], [Engine.text_s(value)])

## Session storage is the safety net; the leave warning is a browser courtesy.
## A saved document stays available to other tabs, whose changes remain a choice
## whenever this tab has a dirty revision.
persistence_controls : {} -> Elem(ctx)
	where [ctx.store : () -> Engine.Reach(ctx, _)]
persistence_controls = |_| Html.div(
	"grid gap-3",
	[
		button_group(
			"Keep and copy",
			[
				Html.button("Save", [Engine.class("button button-primary button-sm")], Engine.handle_by(AppStore.cells.revision.signal(), |revision, _| AppStore.saved(revision))),
				Html.button("Copy as markdown", [Engine.class("button button-sm")], Engine.does(AppStore.copied_as(Markdown))),
				Html.button("Copy as HTML", [Engine.class("button button-sm")], Engine.does(AppStore.copied_as(Html))),
			],
		),
		readout("document-status", dirty({}).map(|unsaved| if (unsaved) "Unsaved changes" else "Saved")),
		readout(
			"draft-status",
			AppStore.cells.draft_status.signal().map(
				|status| match status {
					Ready => "Drafts stay in this tab across reloads."
					TooLarge => "This draft is too large to keep"
					Unavailable => "Session drafts are unavailable; keep a copy before leaving."
				},
			),
		),
		readout(
			"save-status",
			AppStore.cells.save_status.signal().map(
				|status| match status {
					Ready => ""
					TooLarge => "This document is too large to save"
					Unavailable => "This document could not be saved"
				},
			),
		),
		readout(
			"copy-status",
			AppStore.cells.copy_status.signal().map(
				|status| match status {
					Ready => ""
					Working => "Copying…"
					Copied => "Copied"
					Blocked => "Copy blocked by the browser"
					Unavailable => "Clipboard is unavailable"
					Refused => "Copy could not start"
				},
			),
		),
		Engine.when(
			AppStore.cells.elsewhere.signal().map(
				|offer| match offer {
					Same => False
					Changed(_) => True
				},
			),
			|| Html.div(
				"grid gap-2",
				[
					Html.p("Another tab saved this document. Your unsaved text is still here.", "hint"),
					Html.div(
						"toolbar",
						[
							Html.button(
								"Load the other tab's version",
								[Engine.class("button button-sm")],
								Engine.handle_by(
									{ revision: AppStore.cells.revision.signal(), elsewhere: AppStore.cells.elsewhere.signal() }.Engine.Signal,
									|current, _| AppStore.took_theirs(current),
								),
							),
							Html.button("Keep mine", [Engine.class("button button-sm")], Engine.does(AppStore.kept_mine({}))),
						],
					),
				],
			),
			|| Engine.text(""),
		),
		Engine.element(
			"div",
			[
				Engine.attr("aria-label", "Paste to import"),
				Engine.attr("tabindex", "0"),
				Engine.class("input p-3 text-sm"),
				Html.on_paste_text(Engine.handle(AppStore.pasted)),
			],
			[Engine.text("Paste text here to replace the document.")],
		),
		readout("paste-status", AppStore.cells.paste_too_large.signal().map(|too_large| if (too_large) "Pasted text is too large to import" else "")),
	],
)
