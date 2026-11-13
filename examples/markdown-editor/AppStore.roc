import pf.Engine
import pf.Clipboard
import Edit

## The editor's document and decisions. Revision numbers describe writes, so
## dirty state is constant work and never compares or retains an earlier text.
## Draft, save and copy intents are small outbox posts; the page's sites read
## the current source only when issuing requests in that same turn. The derived panels still read only source.
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

	SavedRevision : [NotSaved, Saved(U64)]
	Elsewhere : [Same, Changed(Str)]
	DraftStatus : [Ready, TooLarge, Unavailable]
	CopyStatus : [Ready, Working, Copied, Blocked, Unavailable, Refused]
	CopyFormat : [Markdown, Html]

	initial_saved : SavedRevision
	initial_saved = Saved(0)

	initial_elsewhere : Elsewhere
	initial_elsewhere = Same

	initial_draft_status : DraftStatus
	initial_draft_status = Ready

	initial_copy_status : CopyStatus
	initial_copy_status = Ready

	## Each field owns one independently changing concern. A pending draft is
	## ordinary intent, not an earlier source retained to discover a change.
	store = Engine.store(
		AppStore.Editor,
		{
			source: Engine.cell(AppStore.sample_document),
			revision: Engine.cell(0.U64),
			saved_revision: Engine.cell(AppStore.initial_saved),
			elsewhere: Engine.cell(AppStore.initial_elsewhere),
			drafts: Engine.cell(Engine.outbox({})),
			saves: Engine.cell(Engine.outbox({})),
			copies: Engine.cell(Engine.outbox({})),
			apply_source: Engine.cell(Engine.outbox({})),
			draft_status: Engine.cell(AppStore.initial_draft_status),
			copy_status: Engine.cell(AppStore.initial_copy_status),
			save_status: Engine.cell(AppStore.initial_draft_status),
			paste_too_large: Engine.cell(False),
		}.Engine.Cells,
	)

	## The store's cells, handed to the decisions and the page's panels.
	cells = AppStore.store.cells()

	## A restored session draft wins over the saved document. It starts dirty:
	## the app does not compare two possibly large texts to guess whether they
	## agree. Without a draft the saved document, or the sample, is clean.
	start : Engine.Boot -> _
	start = |boot| {
		saved = Engine.boot_storage(boot, "md.document") ?? AppStore.sample_document
		source = Engine.boot_session(boot, "md.draft") ?? saved
		restored = Engine.boot_session(boot, "md.draft").is_ok()
		AppStore.store
			.with_initial(AppStore.cells.source, source)
			.with_initial(AppStore.cells.revision, if (restored) 1 else 0)
			.with_initial(AppStore.cells.draft_status, if (boot.session_available) Ready else Unavailable)
	}

	## What is drawn has not been saved when its revision differs, or when a
	## failed local write invalidated the optimistic save's revision.
	is_dirty : { revision : U64, saved_revision : SavedRevision } -> Bool
	is_dirty = |reading| match reading.saved_revision {
		Saved(revision) => reading.revision != revision
		NotSaved => True
	}

	## One input replacement and its draft marker are one decision. The draft
	## site reads the source only when sending; no outbox retains a large text.
	replaced : Str -> List(Engine.Write(_))
	replaced = |text| [
		AppStore.cells.source.set(text),
		AppStore.cells.revision.update(next_revision),
		AppStore.cells.drafts.update(|box| box.post({})),
		AppStore.cells.paste_too_large.set(False),
		AppStore.cells.draft_status.set(Ready),
		AppStore.cells.save_status.set(Ready),
	]

	## A toolbar transform receives the source through its cell's modifier,
	## uniquely owned. The small revision and draft marker travel beside it.
	edited : (Str -> Str) -> List(Engine.Write(_))
	edited = |command| [
		AppStore.cells.source.update(command),
		AppStore.cells.revision.update(next_revision),
		AppStore.cells.drafts.update(|box| box.post({})),
		AppStore.cells.paste_too_large.set(False),
		AppStore.cells.draft_status.set(Ready),
		AppStore.cells.save_status.set(Ready),
	]

	## Request a durable save and optimistically end the leave warning. The
	## session draft stays as a safety net because writes have no success answer;
	## a later local StorageFailed marks the document unsaved again.
	saved : U64 -> List(Engine.Write(_))
	saved = |revision| [
		AppStore.cells.saved_revision.set(Saved(revision)),
		AppStore.cells.saves.update(|box| box.post({})),
		AppStore.cells.elsewhere.set(Same),
		AppStore.cells.save_status.set(Ready),
	]

	## A clean document follows the other tab. A dirty one preserves its text
	## and presents the reported value as an explicit choice. Missing means the
	## other tab removed the saved document, so its candidate is an empty text.
	heard_elsewhere : { revision : U64, saved_revision : SavedRevision }, Engine.Result -> List(Engine.Write(_))
	heard_elsewhere = |reading, result| {
		text = match result {
			Value(value) => value
			Missing => ""
			Refused => return []
			_ => crash "Markdown Editor.heard_elsewhere: a storage subscription answered another result"
		}
		if AppStore.is_dirty(reading) {
			[AppStore.cells.elsewhere.set(Changed(text))]
		} else {
			accept_theirs({ revision: reading.revision, text })
		}
	}

	## Load the offered version only when the reader chose to. This accepts it
	## as the saved revision and keeps the session draft and controlled editor
	## consistent, even when the editor still has keyboard focus.
	took_theirs : { revision : U64, elsewhere : Elsewhere } -> List(Engine.Write(_))
	took_theirs = |reading| match reading.elsewhere {
		Same => []
		Changed(text) => accept_theirs({ revision: reading.revision, text })
	}

	## Keeping this tab's draft dismisses only the offer. Its dirty revision and
	## its text are untouched; Save is still an explicit action.
	kept_mine : {} -> List(Engine.Write(_))
	kept_mine = |_| [AppStore.cells.elsewhere.set(Same)]

	## A copy posts its format. The site samples this turn's source while
	## issuing the request, so later edits cannot change the clipboard write and
	## the outbox never keeps a document snapshot after the request is sent.
	copied_as : CopyFormat -> List(Engine.Write(_))
	copied_as = |format| [
		AppStore.cells.copies.update(|box| box.post(format)),
		AppStore.cells.copy_status.set(Working),
	]

	## Copy outcomes are values the page shows; none changes its document.
	copy_answered : Engine.Result -> List(Engine.Write(_))
	copy_answered = |result| [
		AppStore.cells.copy_status.set(
			match Clipboard.written(result) {
				Ok({}) => Copied
				Err(NotAllowed) => Blocked
				Err(Unavailable) => Unavailable
				Err(Refused) => Refused
			},
		),
	]

	## An import is a document replacement. Oversized external text leaves the
	## source, revisions and draft untouched and gives the reader a message.
	pasted : Engine.Paste -> List(Engine.Write(_))
	pasted = |paste| match paste {
		Text(text) => AppStore.replaced(text).append(AppStore.cells.apply_source.update(|box| box.post({})))
		TooLarge => [AppStore.cells.paste_too_large.set(True)]
	}

	## Write failures cannot be treated as saved. Session quota and unavailable
	## storage have distinct messages; a failed local Save restores the warning.
	storage_failed : Engine.Result -> List(Engine.Write(_))
	storage_failed = |result| match result {
		StorageFailed({ store: Session, key: "md.draft", reason }) => [
			AppStore.cells.draft_status.set(
				match reason {
					Quota => TooLarge
					Unavailable => Unavailable
				},
			),
		]
		StorageFailed({ store: Local, key: "md.document", reason }) => [
			AppStore.cells.saved_revision.set(NotSaved),
			AppStore.cells.save_status.set(
				match reason {
					Quota => TooLarge
					Unavailable => Unavailable
				},
			),
		]
		StorageFailed(_) => []
		Refused => []
		_ => crash "Markdown Editor.storage_failed: a failure subscription answered another result"
	}
}

next_revision : U64 -> U64
next_revision = |revision| {
	if revision == 18446744073709551615 {
		crash "Markdown Editor: document revision exhausted"
	}
	revision + 1
}

accept_theirs : { revision : U64, text : Str } -> List(Engine.Write(_))
accept_theirs = |{ revision, text }| {
	next = next_revision(revision)
	[
		AppStore.cells.source.set(text),
		AppStore.cells.revision.set(next),
		AppStore.cells.saved_revision.set(Saved(next)),
		AppStore.cells.elsewhere.set(Same),
		AppStore.cells.drafts.update(|box| box.post({})),
		AppStore.cells.apply_source.update(|box| box.post({})),
		AppStore.cells.draft_status.set(Ready),
		AppStore.cells.save_status.set(Ready),
	]
}

## Replacing a document writes its source, revision and a small draft marker together.
expect {
	store = AppStore.store.after(AppStore.replaced("# Draft"))
	(store.read(AppStore.cells.source), store.read(AppStore.cells.revision), store.read(AppStore.cells.drafts).last()) == ("# Draft", 1, Posted({}))
}

## Toolbar commands update the current source, and each decision names one draft.
expect {
	draft = AppStore.store.after(AppStore.replaced("# One"))
	store = draft.after(AppStore.edited(Edit.append_word))
	(store.read(AppStore.cells.source), store.read(AppStore.cells.revision), store.read(AppStore.cells.drafts).last()) == ("# One extra", 2, Posted({}))
}

## Saving records the revision and posts a small marker, without dropping its draft.
expect {
	draft = AppStore.store.after(AppStore.replaced("mine"))
	saved = draft.after(AppStore.saved(1))
	(saved.read(AppStore.cells.source), saved.read(AppStore.cells.saved_revision), saved.read(AppStore.cells.saves).last(), saved.read(AppStore.cells.drafts).last()) == ("mine", Saved(1), Posted({}), Posted({}))
}

## A clean document takes the reported version and advances its saved revision too.
expect {
	store = AppStore.store.after(AppStore.heard_elsewhere({ revision: 3, saved_revision: Saved(3) }, Value("theirs")))
	(store.read(AppStore.cells.source), store.read(AppStore.cells.revision), store.read(AppStore.cells.saved_revision), store.read(AppStore.cells.elsewhere)) == ("theirs", 4, Saved(4), Same)
}

## A dirty document keeps its draft until the reader accepts the offered version.
expect {
	mine = AppStore.store.after(AppStore.replaced("mine"))
	offered = mine.after(AppStore.heard_elsewhere({ revision: 1, saved_revision: Saved(0) }, Value("theirs")))
	kept = offered.after(AppStore.kept_mine({}))
	taken = offered.after(AppStore.took_theirs({ revision: 1, elsewhere: Changed("theirs") }))
	(kept.read(AppStore.cells.source), kept.read(AppStore.cells.elsewhere), taken.read(AppStore.cells.source), taken.read(AppStore.cells.saved_revision), taken.read(AppStore.cells.drafts).last()) == ("mine", Same, "theirs", Saved(2), Posted({}))
}

## Copy intents hold only their format, and leave the document and revision alone.
expect {
	store = AppStore.store.after(AppStore.copied_as(Html))
	(store.read(AppStore.cells.copies).last(), store.read(AppStore.cells.copy_status), store.read(AppStore.cells.source), store.read(AppStore.cells.revision)) == (Posted(Html), Working, AppStore.sample_document, 0)
}

## A failed local save preserves its draft and restores the leave warning.
expect {
	draft = AppStore.store.after(AppStore.replaced("mine"))
	store = draft.after(AppStore.saved(1)).after(AppStore.storage_failed(StorageFailed({ store: Local, key: "md.document", reason: Quota }))).after(AppStore.copy_answered(Refused))
	(store.read(AppStore.cells.source), store.read(AppStore.cells.drafts).last(), store.read(AppStore.cells.saved_revision), store.read(AppStore.cells.copy_status), AppStore.is_dirty({ revision: 1, saved_revision: store.read(AppStore.cells.saved_revision) })) == ("mine", Posted({}), NotSaved, Refused, True)
}

## An oversized paste does not change the document or post a new draft.
expect {
	store = AppStore.store.after(AppStore.pasted(TooLarge))
	(store.read(AppStore.cells.source), store.read(AppStore.cells.drafts).last(), store.read(AppStore.cells.paste_too_large)) == (AppStore.sample_document, Unposted, True)
}

## A session draft starts dirty, while a saved document alone starts clean.
expect {
	draft = AppStore.start({ session: [("md.draft", "draft")], storage: [("md.document", "saved")] })
	saved = AppStore.start({ storage: [("md.document", "saved")] })
	(draft.read(AppStore.cells.source), draft.read(AppStore.cells.revision), saved.read(AppStore.cells.source), saved.read(AppStore.cells.revision)) == ("draft", 1, "saved", 0)
}

## Composed toolbar transforms edit in order while posting one draft for the turn.
expect {
	draft = AppStore.store.after(AppStore.replaced("# One"))
	store = draft.after(AppStore.edited(|source| Edit.append_word(Edit.append_word(source))))
	(store.read(AppStore.cells.source), store.read(AppStore.cells.revision)) == ("# One extra extra", 2)
}

## A removed saved document is an empty candidate, and a refused subscription writes nothing.
expect {
	removed = AppStore.store.after(AppStore.heard_elsewhere({ revision: 0, saved_revision: Saved(0) }, Missing))
	refused = AppStore.store.after(AppStore.heard_elsewhere({ revision: 0, saved_revision: Saved(0) }, Refused))
	(removed.read(AppStore.cells.source), removed.read(AppStore.cells.saved_revision), refused.read(AppStore.cells.source)) == ("", Saved(1), AppStore.sample_document)
}
