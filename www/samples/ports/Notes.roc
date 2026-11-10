import pf.Engine exposing [Elem, In, Root, State]
import pf.Html
import pf.Port

## Notes kept in the browser's IndexedDB, which the platform does not model:
## three ports whose JavaScript (`notes-ports.mjs`, beside this file) the
## page passes at mount. A call lists the notes, a call saves one, and a
## subscription reports a new revision whenever any tab changes the store.
Notes := [].{

	# region ports
	## A note as it crosses: JavaScript sees an object with these fields
	## (`saved_ms` as a decimal string, since it is a `U64`).
	Note : { id : Str, title : Str, saved_ms : U64 }

	## Every note whose title starts with `prefix`, at `revision`.
	list : Port.Call({ prefix : Str, revision : U64 }, List(Note))
	list = Port.call("example.org/notes/list").with_timeout_ms(5000)

	## Store a note; JavaScript answers nothing (`undefined`).
	put : Port.Call(Note, {})
	put = Port.call("example.org/notes/put")

	## The store's revision, whenever it changes. Only the newest matters.
	changed : Port.Subscription({}, U64)
	changed = Port.subscription("example.org/notes/changed", Latest)
	# endregion ports

	S : { prefix : Str, draft : Str, revision : U64, saves : U64, save : Note, error : Str }

	## The draft as the next note to save.
	saved : S -> S
	saved = |s| {
		saves = s.saves + 1
		{ ..s, saves, save: { id: "n${saves.to_str()}", title: s.draft, saved_ms: 0 }, draft: "" }
	}

	shown : Engine.Remote(List(Note), Port.Error) -> Str
	shown = |{ request, answer }| match answer {
		Answered(notes) => if (notes.is_empty()) "No notes." else Str.join_with(notes.map(|n| n.title), ", ")
		Failed(Timeout) => "The store did not answer."
		Failed(_) => "The notes could not be read."
		Unanswered => if (request == Pending) "Loading…" else ""
	}

	# region view
	view : State(In(Root, S), S) -> Elem(In(Root, S))
	view = |st| {
		v = st.val()
		Html.div(
			"notes",
			[
				# Any tab's write moves the revision, which lists the notes again.
				Engine.watch(
					Engine.const({}),
					|_| [Notes.changed.subscribe({})],
					st.on_result(
						|s, _, res| match Notes.changed.message(res) {
							Ok(revision) => { ..s, revision }
							Err(e) => { ..s, error: Str.inspect(e) }
						},
					),
				),
				Html.text_input(Engine.const("Note"), "text", v.map(|s| s.draft), [], st.set_value(|s, t| { ..s, draft: t })),
				Html.button("Save", [], st.update(Notes.saved)),
				# A save is kept even if the user leaves the view mid-way.
				Engine.on_change(
					v.map(|s| s.save),
					|note| [Notes.put.request(note)],
					st.on_result(
						|s, _, res| match Notes.put.result(res) {
							Ok({}) => s
							Err(e) => { ..s, error: Str.inspect(e) }
						},
					),
				),
				Html.text_input(Engine.const("Filter"), "text", v.map(|s| s.prefix), [], st.set_value(|s, t| { ..s, prefix: t })),
				# A newer filter or revision stops the older listing.
				Port.derive(Notes.list, v.map(|s| { prefix: s.prefix, revision: s.revision }), |r| Html.p_v(r.map(Notes.shown), [Engine.test_id("notes")])),
				Html.p_v(v.map(|s| s.error), [Engine.test_id("error")]),
			],
		)
	}
	# endregion view

	# region program
	program : Engine.Program
	program =
		Engine.program(|| Engine.state({ prefix: "", draft: "", revision: 0, saves: 0, save: { id: "", title: "", saved_ms: 0 }, error: "" }, Notes.view))
			.with_ports([Notes.list.declaration(), Notes.put.declaration(), Notes.changed.declaration()])
	# endregion program
}
