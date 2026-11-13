import pf.Engine exposing [Elem, File, In, Root, State]
import pf.Files
import pf.Html
import pf.Worker

## Prepared state test app, in the shape of a document explorer: one
## preparation and three tasks over it.
## - "Document" is a file input; the file and the "Ignore case" checkbox are
##   the preparation's input. The preparation reads the file as text in a
##   worker (`contents_utf8!`) and indexes its words: each word's line
##   numbers, built at run time from the file's bytes. A file that cannot be
##   read, or is not UTF-8, fails the preparation with `Unread(error)`, and
##   an empty file with `Empty`; every task over it then answers
##   `Failed(...)` with that error.
## - Three tabs, each with its task's site inside its branch, so leaving a
##   tab disposes its site and coming back asks again: "Stats" (lines, words
##   and distinct words, `test-id "stats"`), "Lookup" (the count and first
##   lines of the word typed in "Word", `test-id "lookup"`, with a timeout)
##   and "Top" (the three most frequent words, `test-id "top"`, which
##   finishes a cancelled job instead of stopping it).
## - "Forget" drops the file, so its handle is released and no worker keeps
##   a state prepared from it.
## - "Summary" shows the stats again below the tabs (`test-id "summary"`),
##   a second site asking the same preparation at the same time as a tab.
## - Looking up the word "!crash" (which no word in a file can be) crashes
##   the task in its worker, for the contract tests of a lost holder.
## - A second preparation, "scratch", over the same file opens a builder and
##   finishes a copy of the file, and keeps both in its state. "Write
##   scratch" runs a task that appends to the kept builder, which outlived
##   the preparation's call: a contract error, so the job is lost
##   (`test-id "write"`). "Keep copy" runs a task that answers with the kept
##   finished file, which is fine (`test-id "copy"`).
PreparedApp := [].{
	S : { doc : [None, Loaded(File)], fold : Bool, tab : Tab, word : Str, summary : Bool, scratch : [Idle, Write, Keep] }

	Tab : [Stats, Lookup, Top]

	## The preparation's input.
	Source : { doc : File, fold : Bool }

	## The prepared state: each word's line numbers, and the line count.
	Index : { lines : U64, words : U64, at : Dict(Str, List(U64)) }

	## Why the document has no index: its file could not be read, or it is
	## empty.
	Problem : [Unread(Engine.FileError), Empty]

	## Index the file's words, one line at a time. A word is a run of ASCII
	## letters and digits; with `fold` it is lower-cased first. Every line
	## ends with a newline (a last line without one is not counted).
	index! : Source => Try(Index, Problem)
	index! = |{ doc, fold }| {
		bytes = doc.contents_utf8!().map_err(|e| Unread(e))?.to_utf8()
		if bytes.is_empty() {
			return Err(Empty)
		}
		var $at = Dict.empty()
		var $line = 1.U64
		var $words = 0.U64
		var $word = []
		for b in bytes {
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
		Ok({ lines: $line - 1, words: $words, at: $at })
	}

	document : Worker.Preparation(Source, Index, Problem)
	document = Worker.preparation({
		name: "test.roc-signals/prepared/document",
		prepare!: PreparedApp.index!,
	})

	stats : Worker.PreparedTask(Source, Index, {}, { lines : U64, words : U64, distinct : U64 }, Problem)
	stats = PreparedApp.document.task({
		name: "test.roc-signals/prepared/stats",
		run!: |ix, {}| Ok({ lines: ix.lines, words: ix.words, distinct: ix.at.len() }),
	})

	lookup : Worker.PreparedTask(Source, Index, Str, { count : U64, first : List(U64) }, Problem)
	lookup = PreparedApp.document.task({
		name: "test.roc-signals/prepared/lookup",
		run!: |ix, word| {
			if word == "!crash" {
				crash "the prepared test app's lookup was asked to crash"
			}
			lines = ix.at.get(word) ?? []
			Ok({ count: lines.len(), first: lines.take_first(3) })
		},
		timeout: Ms(30000),
	})

	top : Worker.PreparedTask(Source, Index, U64, List({ word : Str, count : U64 }), Problem)
	top = PreparedApp.document.task({
		name: "test.roc-signals/prepared/top",
		run!: |ix, n| {
			counted = ix.at.to_list().map(|(word, lines)| { word, count: lines.len() })
			Ok(counted.sort_with(|a, b| if (a.count > b.count) Before else if (a.count < b.count) After else PreparedApp.order(a.word.to_utf8(), b.word.to_utf8())).take_first(n))
		},
		on_cancel: Finish,
	})

	## What the scratch preparation keeps: a builder it opened (which a later
	## task may not use) and a file it finished (which a later task may).
	Scratch : { open : Engine.Builder, copy : File }

	## Open a builder and finish a copy of `doc`, both kept in the state.
	scratch! : File => Try(Scratch, Engine.FileError)
	scratch! = |doc| {
		open = Files.build!({ name: "scratch.txt" })
		copier = Files.build!({ name: "copy.txt", start_from: From(doc) })
		Ok({ open, copy: copier.finish!() })
	}

	scratch : Worker.Preparation(File, Scratch, Engine.FileError)
	scratch = Worker.preparation({ name: "test.roc-signals/prepared/scratch", prepare!: PreparedApp.scratch! })

	## Append to the builder the preparation kept: a contract error.
	write : Worker.PreparedTask(File, Scratch, {}, {}, Engine.FileError)
	write = PreparedApp.scratch.task({ name: "test.roc-signals/prepared/scratch/write", run!: PreparedApp.write! })

	write! : Scratch, {} => Try({}, Engine.FileError)
	write! = |kept, {}| {
		kept.open.append!("late".to_utf8())?
		Ok({})
	}

	## Answer with the file the preparation finished and kept.
	keep : Worker.PreparedTask(File, Scratch, {}, File, Engine.FileError)
	keep = PreparedApp.scratch.task({ name: "test.roc-signals/prepared/scratch/keep", run!: |kept, {}| Ok(kept.copy) })

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

	registrations : List(Engine.Registration)
	registrations = [
		PreparedApp.document.registration([PreparedApp.stats.registration(), PreparedApp.lookup.registration(), PreparedApp.top.registration()]),
		PreparedApp.scratch.registration([PreparedApp.write.registration(), PreparedApp.keep.registration()]),
	]

	Ctx : In(Root, S)

	show : Engine.Remote(a, Worker.Error(e)), (a -> Str) -> Str
	show = |remote, f| match Worker.status(remote) {
		Unasked => "nothing"
		Working => "working"
		Answered(value) => f(value)
		Lost(fault) => "lost ${Str.inspect(fault)}"
		Timeout => "timed out"
		Refused => "refused"
		Failed(problem) => "failed ${Str.inspect(problem)}"
	}

	## The scratch task `want` asks for, over the loaded document.
	scratched : S, [Idle, Write, Keep] -> [Run(Worker.Question(File, {})), Skip]
	scratched = |s, want| match s.doc {
		Loaded(doc) if s.scratch == want => Run({ init: doc, input: {} })
		_ => Skip
	}

	asked : S, q -> [Run(Worker.Question(Source, q)), Skip]
	asked = |s, input| match s.doc {
		Loaded(doc) => Run({ init: { doc, fold: s.fold }, input })
		None => Skip
	}

	tab_button : State(Ctx, S), Str, Tab -> Elem(Ctx)
	tab_button = |st, label, tab| Html.button(label, [], st.update(|s| { ..s, tab }))

	panel : State(Ctx, S), Tab -> Elem(Ctx)
	panel = |st, tab| {
		v = st.signal()
		match tab {
			Stats => Worker.resource_when(PreparedApp.stats, v.map(|s| PreparedApp.asked(s, {})), |r| Html.p_s(r.map(|x| PreparedApp.show(x, |a| "${a.lines.to_str()} lines, ${a.words.to_str()} words, ${a.distinct.to_str()} distinct")), [Engine.test_id("stats")]))
			Lookup =>
				Html.div(
					"lookup",
					[
						Html.text_input(Engine.const("Word"), "text", v.map(|s| s.word), [], st.set_value(|s, word| { ..s, word })),
						Worker.resource_when(PreparedApp.lookup, v.map(|s| PreparedApp.asked(s, s.word)), |r| Html.p_s(r.map(|x| PreparedApp.show(x, |a| "${a.count.to_str()} at ${Str.join_with(a.first.map(|l| l.to_str()), ",")}")), [Engine.test_id("lookup")])),
					],
				)
			Top => Worker.resource_when(PreparedApp.top, v.map(|s| PreparedApp.asked(s, 3)), |r| Html.p_s(r.map(|x| PreparedApp.show(x, |a| Str.join_with(a.map(|w| "${w.word}:${w.count.to_str()}"), " "))), [Engine.test_id("top")]))
		}
	}

	view : State(Ctx, S) -> Elem(Ctx)
	view = |st| {
		v = st.signal()
		Html.div(
			"prepared",
			[
				Html.file_input(
					Engine.const("Document"),
					{},
					st.set_value(
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
				Worker.resource_when(PreparedApp.stats, v.map(|s| if (s.summary) PreparedApp.asked(s, {}) else Skip), |r| Html.p_s(r.map(|x| PreparedApp.show(x, |a| "${a.lines.to_str()} lines")), [Engine.test_id("summary")])),
				Html.button("Write scratch", [], st.update(|s| { ..s, scratch: Write })),
				Html.button("Keep copy", [], st.update(|s| { ..s, scratch: Keep })),
				Worker.resource_when(PreparedApp.write, v.map(|s| PreparedApp.scratched(s, Write)), |r| Html.p_s(r.map(|x| PreparedApp.show(x, |{}| "written")), [Engine.test_id("write")])),
				Worker.resource_when(PreparedApp.keep, v.map(|s| PreparedApp.scratched(s, Keep)), |r| Html.p_s(r.map(|x| PreparedApp.show(x, |f| "kept ${f.name()}:${f.size().to_str()}")), [Engine.test_id("copy")])),
			],
		)
	}

	program : Engine.Program
	program = Engine.program(|| Engine.state({ doc: None, fold: Bool.False, tab: Stats, word: "", summary: Bool.False, scratch: Idle }, PreparedApp.view)).with_workers(PreparedApp.registrations)
}
