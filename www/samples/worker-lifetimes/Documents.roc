import pf.Engine exposing [Elem, In, Root, Row, RowRef, State]
import pf.Html
import pf.Worker

## A list of documents, each counting its words in a worker, with a
## statistics panel and an export that outlives the panel.
Documents := [].{

	Doc : { id : Str, text : Str }

	## What the "Export" button last asked for: nothing yet, or a report on a
	## snapshot of the documents. `press` numbers the presses.
	Ask : [Idle, Export({ press : U64, docs : List(Doc) })]

	S : { docs : List(Doc), next : U64, panel : Bool, presses : U64, ask : Ask, report : Str }

	Ctx : In(Root, S)

	Line : Row(Ctx, Doc)

	count : Worker.Program(Str, U64)
	count = Worker.program({
		name: "example.org/documents/count",
		run: |text| Documents.word_count(text),
	})

	tally : Worker.Program(List(Str), { words : U64, documents : U64 })
	tally = Worker.program({
		name: "example.org/documents/tally",
		run: |texts| { words: texts.map(Documents.word_count).sum(), documents: texts.len() },
	})

	report : Worker.Program(List(Doc), Str)
	report = Worker.program({
		name: "example.org/documents/report",
		run: |docs| Str.join_with(docs.map(|d| "${d.id}: ${Documents.word_count(d.text).to_str()} words"), "; "),
	})

	# region bound
	## At most three runs are in flight at once, kept low here so the specs
	## can reach the bound; the default is 32.
	program : Engine.Program
	program =
		Engine.program_boot({ storage_keys: [], max_inflight: 3 }, |_| Engine.state(Documents.initial, Documents.view))
			.with_workers([Documents.count.registration(), Documents.tally.registration(), Documents.report.registration()])
	# endregion bound

	initial : S
	initial = {
		docs: [{ id: "doc-1", text: "a short note" }, { id: "doc-2", text: "the minutes of the meeting" }],
		next: 3,
		panel: Bool.False,
		presses: 0,
		ask: Idle,
		report: "",
	}

	word_count : Str -> U64
	word_count = |text| text.split_on(" ").keep_if(|w| !w.is_empty()).len()

	view : State(Ctx, S) -> Elem(Ctx)
	view = |st| {
		v = st.val()
		Html.div(
			"documents",
			[
				Documents.rows(st),
				Html.button("Add document", [], st.update(Documents.add)),
				Html.button("Statistics", [], st.update(|s| { ..s, panel: !s.panel })),
				Documents.panel(st),
				Documents.export(st),
				Html.p_v(v.map(|s| s.report), [Engine.test_id("report")]),
			],
		)
	}

	add : S -> S
	add = |s| {
		id = "doc-${s.next.to_str()}"
		{ ..s, docs: s.docs.append({ id, text: "new words for ${id}" }), next: s.next + 1 }
	}

	# region rows
	## Each row runs its own count. Removing a row stops its run.
	rows : State(Ctx, S) -> Elem(Ctx)
	rows = |st|
		Html.ul(
			[],
			[Engine.each(st.val().map(|s| s.docs), |d| d.id, |row| Documents.row(st, row))],
		)

	row : State(Ctx, S), RowRef(Ctx, Doc) -> Elem(Line)
	row = |st0, row_ref| {
		st = st0.lift_row()
		id = row_ref.key()
		Html.li(
			[],
			[
				Html.span_v(row_ref.field(|d| d.text), []),
				Worker.derive(
					Documents.count,
					row_ref.field(|d| d.text),
					|remote| Html.p_v(remote.map(Documents.show_count), [Engine.test_id_v(id.map(|k| "words-${k}").lift())]),
				),
				Html.button_v(id.map(|k| "Remove ${k}"), [], st.update_by(id, |s, k| { ..s, docs: s.docs.keep_if(|d| d.id != k) })),
			],
		)
	}
	# endregion rows

	show_count : Engine.Remote(U64, Worker.Error) -> Str
	show_count = |{ answer, .. }|
		match answer {
			Unanswered => "Counting…"
			Answered(n) => "${n.to_str()} words"
			Failed(error) => Documents.problem(error)
		}

	problem : Worker.Error -> Str
	problem = |error|
		match error {
			Timeout => "This took too long."
			Refused => "Too much is running."
			Lost(_) => "Counting failed."
			FileFailed(_) => "The file could not be read."
		}

	# region panel
	## The panel's totals belong to the panel: closing it stops their run.
	## Its "Export" button only asks; the export site is outside the panel.
	panel : State(Ctx, S) -> Elem(Ctx)
	panel = |st| {
		v = st.val()
		Engine.when(
			v.map(|s| s.panel),
			||
				Html.section(
					"Statistics",
					"panel",
					[
						Worker.derive(
							Documents.tally,
							v.map(|s| s.docs.map(|d| d.text)),
							|remote| Html.p_v(remote.map(Documents.show_totals), [Engine.test_id("totals")]),
						),
						Html.button(
							"Export",
							[],
							st.update(
								|s| {
									..s,
									presses: s.presses + 1,
									ask: Export({ press: s.presses + 1, docs: s.docs }),
									report: "Exporting…",
								},
							),
						),
					],
				),
			|| Engine.text(""),
		)
	}

	## The export site lives as long as the page, so an export started in the
	## panel finishes after the panel is closed.
	export : State(Ctx, S) -> Elem(Ctx)
	export = |st|
		Engine.latest(
			st.val().map(|s| s.ask),
			|ask|
				match ask {
					Idle => []
					Export({ docs, .. }) => [Documents.report.request(docs)]
				},
			st.on_result(
				|s, _, res|
					match Documents.report.result(res) {
						Ok(text) => { ..s, report: text }
						Err(error) => { ..s, report: Documents.problem(error) }
					},
			),
		)
	# endregion panel

	show_totals : Engine.Remote({ words : U64, documents : U64 }, Worker.Error) -> Str
	show_totals = |{ answer, .. }|
		match answer {
			Unanswered => "Counting…"
			Answered(
				{
					words,
					documents,
				},
			) => "${words.to_str()} words in ${documents.to_str()} documents"
			Failed(error) => Documents.problem(error)
		}
}
