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
	## (`saved_ms` as a signed decimal string, since it is an `I64`).
	Note : { id : Str, title : Str, saved_ms : I64 }

	## Every note whose title starts with `prefix`, at `revision`.
	list : Port.Call({ prefix : Str, revision : U64 }, List(Note))
	list = Port.call({ name: "example.org/notes/list", timeout: Ms(5000) })

	## Store a note; JavaScript answers nothing (`undefined`).
	put : Port.Call(Note, {})
	put = Port.call({ name: "example.org/notes/put" })

	## The store's revision, whenever it changes. Only the newest matters.
	changed : Port.Subscription({}, U64)
	changed = Port.subscription({ name: "example.org/notes/changed", delivery: Latest })
	# endregion ports

	S : { prefix : Str, draft : Str, revision : U64, saves : U64, clock : I64, stamping : Engine.Outbox(Note), save : Note, error : Str }

	## A new document starts with its supplied clock and no pending save.
	initial : I64 -> S
	initial = |clock| { prefix: "", draft: "", revision: 0, saves: 0, clock, stamping: Engine.outbox({}), save: { id: "", title: "", saved_ms: 0 }, error: "" }

	## The draft as the next note to save.
	saved : S -> S
	saved = |s| {
		saves = s.saves + 1
		{ ..s, saves, stamping: s.stamping.post({ id: "n${saves.to_str()}", title: s.draft, saved_ms: s.clock }), draft: "" }
	}

	## The timer supplies the action's time. Refusal uses the last sample,
	## and the IndexedDB port receives the complete record without minting time.
	stamped : S, { note : Note, result : Engine.Result } -> S
	stamped = |s, { note, result }| {
		clock = match result {
			Fired(at_ms) => at_ms
			Refused => s.clock
			_ => crash "Notes.stamped: Timer(0) returned another result"
		}
		{ ..s, clock, save: { ..note, saved_ms: clock } }
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
		v = st.signal()
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
				Engine.on_post(v.map(|s| s.stamping), |_| [Timer(0)], st.on_result(|s, note, result| Notes.stamped(s, { note, result }))),
				# A save is kept even if the user leaves the view mid-way.
				Engine.watch_changes(
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
				Port.resource(Notes.list, v.map(|s| { prefix: s.prefix, revision: s.revision }), |r| Html.p_s(r.map(Notes.shown), [Engine.test_id("notes")])),
				Html.p_s(v.map(|s| s.error), [Engine.test_id("error")]),
			],
		)
	}
	# endregion view

	# region program
	program : Engine.Program
	program =
		Engine.program_boot({}, |boot| Engine.state(Notes.initial(boot.now_ms), Notes.view))
			.with_ports([Notes.list.registration(), Notes.put.registration(), Notes.changed.registration()])
	# endregion program
}

## A timer answer supplies signed time; refusal keeps the last sample and
## never asks the storage port to replace it with a real-page clock read.
expect {
	start = Notes.initial(10)
	note = { id: "n1", title: "Draft", saved_ms: 10 }
	fired = Notes.stamped(start, { note, result: Fired(-1) })
	refused = Notes.stamped(fired, { note: { ..note, id: "n2" }, result: Refused })
	{ fired: fired.save, refused: refused.save } == {
		fired: { ..note, saved_ms: -1 },
		refused: { ..note, id: "n2", saved_ms: -1 },
	}
}
