import pf.Engine exposing [Elem, File, In, Root, State]
import pf.Html
import pf.Worker

## A notes explorer: the user chooses a text file, a worker splits it into
## lines once, and three tabs ask different questions of the result.
Notes := [].{
	S : { doc : [None, Loaded(File)], tab : Tab, word : Str }

	Tab : [Summary, Search, Longest]

	# region prepare
	## The expensive step: read the file and split it into lines, once per
	## file in a worker that keeps the result.
	document : Worker.Prepared(File, List(Str))
	document = Worker.prepared({
		name: "example.org/notes/document",
		prepare: |file| Str.from_utf8_lossy(file.contents()).split_on("\n"),
	})
	# endregion prepare

	# region queries
	## Three typed questions over the same lines, each with its own input and
	## output type.
	summary : Worker.Query(File, List(Str), {}, { lines : U64, chars : U64 })
	summary = Notes.document.query({
		name: "example.org/notes/summary",
		run: |lines, {}| { lines: lines.len(), chars: lines.fold(0, |n, l| n + l.count_utf8_bytes()) },
	})

	search : Worker.Query(File, List(Str), Str, List(U64))
	search = Notes.document.query({
		name: "example.org/notes/search",
		run: |lines, word| {
			var $found = []
			var $at = 1.U64
			for line in lines {
				if word != "" and line.contains(word) {
					$found = $found.append($at)
				}
				$at = $at + 1
			}
			$found
		},
	})

	longest : Worker.Query(File, List(Str), {}, Str)
	longest = Notes.document.query({
		name: "example.org/notes/longest",
		run: |lines, {}| lines.fold("", |best, l| if (l.count_utf8_bytes() > best.count_utf8_bytes()) l else best),
		on_cancel: Finish,
	})
	# endregion queries

	# region register
	program : Engine.Program
	program =
		Engine.program(|| Engine.state({ doc: None, tab: Summary, word: "" }, Notes.view))
			.with_workers([Notes.document.registration([Notes.summary.registration(), Notes.search.registration(), Notes.longest.registration()])])
	# endregion register

	Ctx : In(Root, S)

	# region asked
	## The question for the current file, or none before a file is chosen.
	asked : S, q -> [Run(Worker.Question(File, q)), Skip]
	asked = |s, query| match s.doc {
		Loaded(doc) => Run({ input: doc, query })
		None => Skip
	}
	# endregion asked

	show : Engine.Remote(a, Worker.Error), (a -> Str) -> Str
	show = |{ request, answer }, f| match answer {
		Answered(value) => if (request == Pending) "working" else f(value)
		Failed(_) => "failed"
		Unanswered => if (request == Pending) "working" else "choose a file"
	}

	# region tabs
	## Each tab's site lives in its branch: a revisit asks again, and the
	## worker that kept the lines answers with a query, not a new split.
	panel : State(Ctx, S), Tab -> Elem(Ctx)
	panel = |st, tab| {
		v = st.val()
		match tab {
			Summary => Worker.derive_when(Notes.summary, v.map(|s| Notes.asked(s, {})), |r| Html.p_v(r.map(|x| Notes.show(x, |a| "${a.lines.to_str()} lines, ${a.chars.to_str()} characters")), [Engine.test_id("summary")]))
			Search =>
				Html.div(
					"search",
					[
						Html.text_input(Engine.const("Word"), "search", v.map(|s| s.word), [], st.set_value(|s, word| { ..s, word })),
						Worker.derive_when(Notes.search, v.map(|s| Notes.asked(s, s.word)), |r| Html.p_v(r.map(|x| Notes.show(x, |found| "lines ${Str.join_with(found.map(|n| n.to_str()), ", ")}")), [Engine.test_id("found")])),
					],
				)
			Longest => Worker.derive_when(Notes.longest, v.map(|s| Notes.asked(s, {})), |r| Html.p_v(r.map(|x| Notes.show(x, |line| line)), [Engine.test_id("longest")]))
		}
	}
	# endregion tabs

	view : State(Ctx, S) -> Elem(Ctx)
	view = |st| {
		v = st.val()
		Html.div(
			"notes",
			[
				Html.file_input(
					Engine.const("Notes file"),
					{ accept: Types(".txt,text/plain") },
					st.on_files(
						|s, { files, refused: _ }| match files {
							[first, ..] => { ..s, doc: Loaded(first) }
							[] => s
						},
					),
				),
				Html.button("Summary", [], st.update(|s| { ..s, tab: Summary })),
				Html.button("Search", [], st.update(|s| { ..s, tab: Search })),
				Html.button("Longest", [], st.update(|s| { ..s, tab: Longest })),
				Engine.switch(v.map(|s| s.tab), [Summary, Search, Longest], |tab| Notes.panel(st, tab)),
			],
		)
	}
}
