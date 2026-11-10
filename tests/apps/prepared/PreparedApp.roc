import pf.Engine exposing [Elem, File, In, Root, State]
import pf.Html
import pf.Worker

## Prepared programs test app, in the shape of a document explorer: one
## preparation and three typed queries over it.
## - "Document" is a file input; the file and the "Ignore case" checkbox are
##   the preparation's input. The preparation reads the file in a worker and
##   indexes its words: each word's line numbers, built at run time from
##   the file's bytes.
## - Three tabs, each with its query site inside its branch, so leaving a
##   tab disposes its site and coming back asks again: "Stats" (lines, words
##   and distinct words, `test-id "stats"`), "Lookup" (the count and first
##   lines of the word typed in "Word", `test-id "lookup"`, with a deadline)
##   and "Top" (the three most frequent words, `test-id "top"`, which
##   finishes a cancelled run instead of stopping it).
## - "Forget" drops the file, so its handle is released and no worker keeps
##   a state prepared from it.
## - "Summary" shows the stats again below the tabs (`test-id "summary"`),
##   a second site asking the same preparation at the same time as a tab.
## - Looking up the word "!crash" (which no word in a file can be) crashes
##   the query in its worker, for the contract tests of a lost holder.
PreparedApp := [].{
	S : { doc : [None, Loaded(File)], fold : Bool, tab : Tab, word : Str, summary : Bool }

	Tab : [Stats, Lookup, Top]

	## The preparation's input.
	Source : { doc : File, fold : Bool }

	## The prepared state: each word's line numbers, and the line count.
	Index : { lines : U64, words : U64, at : Dict(Str, List(U64)) }

	## Index the file's words, one line at a time. A word is a run of ASCII
	## letters and digits; with `fold` it is lower-cased first. Every line
	## ends with a newline (a last line without one is not counted).
	index : Source -> Index
	index = |{ doc, fold }| {
		var $at = Dict.empty()
		var $line = 1.U64
		var $words = 0.U64
		var $word = []
		for b in doc.contents() {
			c = if (fold and b >= 65 and b <= 90) b + 32 else b
			alnum = (c >= 48 and c <= 57) or (c >= 65 and c <= 90) or (c >= 97 and c <= 122)
			if alnum {
				$word = $word.append(c)
			} else {
				if !$word.is_empty() {
					w = Str.from_utf8($word) ?? ""
					# Taken out before it grows, so the list is appended in place.
					lines = $at.get(w) ?? []
					$at = $at.remove(w).insert(w, lines.append($line))
					$words = $words + 1
					$word = []
				}
				if c == 10 {
					$line = $line + 1
				}
			}
		}
		{ lines: $line - 1, words: $words, at: $at }
	}

	document : Worker.Prepared(Source, Index)
	document = Worker.prepared({
		name: "test.roc-signals/prepared/document",
		prepare: PreparedApp.index,
	})

	stats : Worker.Query(Source, Index, {}, { lines : U64, words : U64, distinct : U64 })
	stats = PreparedApp.document.query({
		name: "test.roc-signals/prepared/stats",
		run: |ix, {}| { lines: ix.lines, words: ix.words, distinct: ix.at.len() },
	})

	lookup : Worker.Query(Source, Index, Str, { count : U64, first : List(U64) })
	lookup = PreparedApp.document.query({
		name: "test.roc-signals/prepared/lookup",
		run: |ix, word| {
			if word == "!crash" {
				crash "the prepared test app's lookup was asked to crash"
			}
			lines = ix.at.get(word) ?? []
			{ count: lines.len(), first: lines.take_first(3) }
		},
		deadline: Ms(30000),
	})

	top : Worker.Query(Source, Index, U64, List({ word : Str, count : U64 }))
	top = PreparedApp.document.query({
		name: "test.roc-signals/prepared/top",
		run: |ix, n| {
			counted = ix.at.to_list().map(|(word, lines)| { word, count: lines.len() })
			counted.sort_with(|a, b| if (a.count > b.count) Before else if (a.count < b.count) After else PreparedApp.order(a.word.to_utf8(), b.word.to_utf8())).take_first(n)
		},
		on_cancel: Finish,
	})

	## Byte order of two words.
	order : List(U8), List(U8) -> [Before, After, Same]
	order = |a, b| {
		var $i = 0
		while $i < a.len() and $i < b.len() {
			x = a.get($i) ?? 0
			y = b.get($i) ?? 0
			if x != y {
				return if (x < y) Before else After
			}
			$i = $i + 1
		}
		if (a.len() < b.len()) Before else if (a.len() > b.len()) After else Same
	}

	registration : Engine.Registration
	registration = PreparedApp.document.registration([PreparedApp.stats.registration(), PreparedApp.lookup.registration(), PreparedApp.top.registration()])

	Ctx : In(Root, S)

	show : Engine.Remote(a, Worker.Error), (a -> Str) -> Str
	show = |{ request, answer }, f| match answer {
		Unanswered => if (request == Pending) "working" else "nothing"
		Answered(value) => if (request == Pending) "working" else f(value)
		Failed(Lost(fault)) => "lost ${Str.inspect(fault)}"
		Failed(Timeout) => "timed out"
		Failed(Refused) => "refused"
		Failed(FileFailed(reason)) => "file failed ${Str.inspect(reason)}"
	}

	asked : S, q -> [Run(Worker.Question(Source, q)), Skip]
	asked = |s, query| match s.doc {
		Loaded(doc) => Run({ input: { doc, fold: s.fold }, query })
		None => Skip
	}

	tab_button : State(Ctx, S), Str, Tab -> Elem(Ctx)
	tab_button = |st, label, tab| Html.button(label, [], st.update(|s| { ..s, tab }))

	panel : State(Ctx, S), Tab -> Elem(Ctx)
	panel = |st, tab| {
		v = st.val()
		match tab {
			Stats => Worker.derive_when(PreparedApp.stats, v.map(|s| PreparedApp.asked(s, {})), |r| Html.p_v(r.map(|x| PreparedApp.show(x, |a| "${a.lines.to_str()} lines, ${a.words.to_str()} words, ${a.distinct.to_str()} distinct")), [Engine.test_id("stats")]))
			Lookup =>
				Html.div(
					"lookup",
					[
						Html.text_input(Engine.const("Word"), "text", v.map(|s| s.word), [], st.set_value(|s, word| { ..s, word })),
						Worker.derive_when(PreparedApp.lookup, v.map(|s| PreparedApp.asked(s, s.word)), |r| Html.p_v(r.map(|x| PreparedApp.show(x, |a| "${a.count.to_str()} at ${Str.join_with(a.first.map(|l| l.to_str()), ",")}")), [Engine.test_id("lookup")])),
					],
				)
			Top => Worker.derive_when(PreparedApp.top, v.map(|s| PreparedApp.asked(s, 3)), |r| Html.p_v(r.map(|x| PreparedApp.show(x, |a| Str.join_with(a.map(|w| "${w.word}:${w.count.to_str()}"), " "))), [Engine.test_id("top")]))
		}
	}

	view : State(Ctx, S) -> Elem(Ctx)
	view = |st| {
		v = st.val()
		Html.div(
			"prepared",
			[
				Html.file_input(
					Engine.const("Document"),
					{},
					st.on_files(
						|s, { files, refused: _ }| match files {
							[first, ..] => { ..s, doc: Loaded(first) }
							[] => s
						},
					),
				),
				Html.checkbox(Engine.const("Ignore case"), v.map(|s| s.fold), [], st.set_value(|s, x| { ..s, fold: x == "true" })),
				Html.button("Forget", [], st.update(|s| { ..s, doc: None })),
				PreparedApp.tab_button(st, "Stats", Stats),
				PreparedApp.tab_button(st, "Lookup", Lookup),
				PreparedApp.tab_button(st, "Top", Top),
				Engine.switch(v.map(|s| s.tab), [Stats, Lookup, Top], |tab| PreparedApp.panel(st, tab)),
				Html.checkbox(Engine.const("Summary"), v.map(|s| s.summary), [], st.set_value(|s, x| { ..s, summary: x == "true" })),
				Worker.derive_when(PreparedApp.stats, v.map(|s| if (s.summary) PreparedApp.asked(s, {}) else Skip), |r| Html.p_v(r.map(|x| PreparedApp.show(x, |a| "${a.lines.to_str()} lines")), [Engine.test_id("summary")])),
			],
		)
	}

	program : Engine.Program
	program = Engine.program(|| Engine.state({ doc: None, fold: Bool.False, tab: Stats, word: "", summary: Bool.False }, PreparedApp.view)).with_workers([PreparedApp.registration])
}
