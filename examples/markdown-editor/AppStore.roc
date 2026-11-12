import pf.Engine
import Edit

## The Markdown Editor's store: the document's source text, the one piece
## of state the whole page shares. The editor panel writes it; the
## statistics, the preview and the table of contents each derive what they
## show from it, at whatever depth they sit, with no `lift`.
##
## What a single panel alone cares about is not here. The reading speed is
## the statistics panel's own state and the numbering toggle the table of
## contents' (`Stats`, `Outline`): each lives and dies with its panel.
##
## The store stands apart from the page (`MdApp`) so that what the app
## shares and how it changes are read, and tested, without the markup.
##
## The module's one tag, `Editor`, is the store's name. Nothing spells the
## store's storage type: an annotation that mentions it says `_`.
AppStore := [Editor].{

	## The document the editor opens with: every kind of block the preview
	## draws, headings at four levels, and text that looks like markup but
	## is not.
	sample_document : Str
	sample_document = "# Roc Signals Field Guide\n\nSignals keep the graph alive instead of rebuilding a whole view after every event.\n\n## Getting Started\n\nRun `roc check main.roc` before you build anything larger, then read the guide.\n\n- Read the guide end to end\n- Skim the gallery examples\n  - Live search covers async and cleanup\n- Write the spec first\n\n### Editor Notes\n\nSpecial characters such as * and _ and # stay literal when they are not real markup.\n\nA line that says 2 * 3 = 6 is arithmetic, not emphasis, and [not a link( either.\n\n##### Deep Dive\n\nThis heading skips from level three to level five on purpose.\n\n## Performance\n\n> Keep derived values derived.\n\n```\n# this hash lives inside a fence and is not a heading\n```\n\nUse **map2** for fan-in and `combine` for wide fan-in, and see [the guide](https://example.test/guide) for more."

	## A document with nothing for the table of contents to show.
	no_heading_document : Str
	no_heading_document = "Just a paragraph with no headings at all.\n\nAnd a second paragraph so the preview has something to show."

	## Four headings and nothing else, for moving, removing and demoting
	## sections.
	heading_drill_document : Str
	heading_drill_document = "# Alpha\n\n## Beta\n\n## Gamma\n\n## Delta"

	## The store: its name, and its one cell with the document it starts at.
	##
	## A record builder needs two fields, so the description of one cell
	## names its handle with `map`; a store of two or more cells is
	## described `{ a: Engine.cell(..), b: Engine.cell(..) }.Engine.Cells`.
	store = Engine.store(AppStore.Editor, Engine.cell(AppStore.sample_document).map(|source| { source: source }))

	## The handles on the store's cells.
	h = AppStore.store.handles()

	## What the reader typed, or a prepared document they loaded: the
	## document becomes `text`.
	replaced : Str -> List(Engine.Write(_))
	replaced = |text| [AppStore.h.source.put(text)]

	## A toolbar command: the document becomes `command` of itself. The
	## commands are the pure functions of `Edit`.
	edited : (Str -> Str) -> List(Engine.Write(_))
	edited = |command| [AppStore.h.source.change(command)]
}

## The store starts at the sample document, and a replacement puts another in its place.
expect {
	replaced = AppStore.store.after(AppStore.replaced(AppStore.heading_drill_document))
	(AppStore.store.read(AppStore.h.source), replaced.read(AppStore.h.source)) == (AppStore.sample_document, AppStore.heading_drill_document)
}

## A command changes the document that is there, and two in one list compose in order.
expect {
	drill = AppStore.store.after(AppStore.replaced(AppStore.heading_drill_document))
	once = drill.after(AppStore.edited(Edit.remove_last_section))
	twice = drill.after(AppStore.edited(Edit.append_word).concat(AppStore.edited(Edit.append_word)))
	(once.read(AppStore.h.source), twice.read(AppStore.h.source)) == ("# Alpha\n\n## Beta\n\n## Gamma\n", "# Alpha\n\n## Beta\n\n## Gamma\n\n## Delta extra extra")
}
