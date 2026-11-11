import pf.Engine exposing [Elem, File, In, Root, Row, RowRef, State, Val]
import pf.Files
import pf.Html
import pf.Worker
import Log
import Sample

## Log Explorer: open a log file of any size, or generate a sample, and
## explore it in three tabs: an overview, a search and a viewer.
##
## The file never comes into the page. A worker prepares it once: it reads
## the file a megabyte at a time and keeps an index (where each line starts,
## what it is, the counts) and the file's handle, but not its text. Each tab
## asks its own task of that prepared state, from a site inside the tab: the
## overview is answered from the index alone, a search reads the file again
## in chunks (or, with no text, only the lines of its page), and the viewer
## reads only the lines it shows. Switching tabs, paging and searching again
## cost the task, not the preparation; a new file is prepared afresh.
ExplorerApp := [].{

	# -- In the worker ------------------------------------------------------

	## Why a log has no index: the browser could not read the file, it is
	## empty, or no line of it starts with a timestamp and a level.
	Problem : [Unreadable, Empty, NotALog]

	## The prepared state: the log's handle, kept to read lines from later,
	## and its index.
	Prepared : { file : File, index : Log.Index }

	## How much of the file one read brings into the worker's memory.
	chunk_bytes : U64
	chunk_bytes = 1048576

	## Index the log a chunk at a time, so the worker holds one chunk and the
	## index, never the whole text.
	index! : File => Try(Prepared, Problem)
	index! = |file| {
		if file.size() == 0 {
			return Err(Empty)
		}
		var $indexer = Log.indexer
		for span in file.spans(ExplorerApp.chunk_bytes) {
			$indexer = Log.feed($indexer, file.read!(span)?)
		}
		index = Log.finish($indexer)
		if index.entries == 0 {
			return Err(NotALog)
		}
		Ok({ file, index })
	}

	## The preparation every tab's task reads.
	log : Worker.Preparation(File, Prepared, Problem)
	log = Worker.prepared({ name: "roc-signals.example/log-explorer/log", prepare!: ExplorerApp.index! })

	## A task of the log's preparation, asked a `query`, answering `output`.
	LogTask(query, output) : Worker.PreparedTask(File, Prepared, query, output, Problem)

	## The overview, from the index alone.
	overview : LogTask({}, Log.Overview)
	overview = ExplorerApp.log.task({ name: "roc-signals.example/log-explorer/overview", run!: |prepared, {}| Ok(Log.overview(prepared.index)) })

	## A page of the lines that match a search. A search the user has typed
	## past is let finish rather than stopped, so its worker keeps the index.
	search : LogTask(Log.Search, Log.Found)
	search = ExplorerApp.log.task({ name: "roc-signals.example/log-explorer/search", run!: ExplorerApp.search!, on_cancel: Finish })

	## With no text, the index says which lines match, and only the page's
	## lines are read. With text, the whole file is read again a chunk of
	## whole lines at a time, and the matches are counted over time too.
	search! : Prepared, Log.Search => Try(Log.Found, Problem)
	search! = |{ file, index }, query| {
		if query.text.is_empty() {
			{ matches, page } = Log.listed(index, query)
			var $lines = []
			for n in page {
				bytes = file.read!(Log.span(index, { first: n, count: 1 }))?
				$lines = $lines.concat(Log.lines_in(index, { first: n, count: 1, bytes }))
			}
			Ok({ matches, lines: $lines, over_time: NotCounted })
		} else {
			var $scanned = Log.unscanned(index)
			for { first, count } in Log.chunks(index, ExplorerApp.chunk_bytes) {
				bytes = file.read!(Log.span(index, { first, count }))?
				$scanned = Log.scan($scanned, { index, search: query, first, count, bytes })
			}
			Ok({ matches: $scanned.matches, lines: $scanned.lines, over_time: Counted($scanned.per_bucket) })
		}
	}

	## The viewer's page from a line (from 0): one read of just its lines.
	window : LogTask(U64, Log.Window)
	window = ExplorerApp.log.task({ name: "roc-signals.example/log-explorer/window", run!: ExplorerApp.window! })

	window! : Prepared, U64 => Try(Log.Window, Problem)
	window! = |{ file, index }, wanted| {
		total = index.starts.len()
		first = Log.window_first({ lines: total, wanted })
		count = (total - first).min(Log.window_lines)
		bytes = file.read!(Log.span(index, { first, count }))?
		Ok({ first, total, lines: Log.lines_in(index, { first, count, bytes }) })
	}

	## A sample log of some number of entries, written to a new file.
	generate : Worker.Task(U64, File, Engine.FileError)
	generate = Worker.task({ name: "roc-signals.example/log-explorer/generate", run!: ExplorerApp.generate! })

	generate! : U64 => Try(File, Engine.FileError)
	generate! = |entries| {
		out = Files.build!({ name: "sample-${entries.to_str()}.log", mime: Mime("text/plain") })
		var $progress = Sample.start
		var $left = entries
		while $left > 0 {
			batch = $left.min(2000)
			{ text, progress } = Sample.entries($progress, batch)
			out.append!(text.to_utf8())?
			$progress = progress
			$left = $left - batch
		}
		Ok(out.finish!())
	}

	## Every task the page asks for, for `Program.with_workers`.
	registrations : List(Engine.Registration)
	registrations = [
		ExplorerApp.log.registration([ExplorerApp.overview.registration(), ExplorerApp.search.registration(), ExplorerApp.window.registration()]),
		ExplorerApp.generate.registration(),
	]

	# -- On the page --------------------------------------------------------

	Tab : [Overview, Search, Viewer]

	## The page's state: the log, the tab, the search and the viewer's
	## place, and the sample's size as typed.
	S : {
		log : [NoLog, Chosen(File)],
		tab : Tab,
		text : Str,
		filter : Log.Filter,
		page : U64,
		first : U64,
		entries : Str,
		generating : [Idle, Generating(U64)],
		note : Str,
	}

	Ctx : In(Root, S)

	initial : S
	initial = { log: NoLog, tab: Overview, text: "", filter: Everything, page: 0, first: 0, entries: "20000", generating: Idle, note: "" }

	## The most entries the sample generator writes.
	most_entries : U64
	most_entries = 2000000

	## A new log: the search and the viewer start from its beginning.
	opened : S, File -> S
	opened = |s, file| { ..s, log: Chosen(file), page: 0, first: 0, note: "" }

	## A tab's question for the open log, or none before one is open.
	asked : S, q -> [Run(Worker.Question(File, q)), Skip]
	asked = |s, query| match s.log {
		Chosen(file) => Run({ input: file, query })
		NoLog => Skip
	}

	## Ask for a sample of the entries typed, or say why not.
	generated : S -> S
	generated = |s| match U64.from_str(s.entries.trim()) {
		Ok(entries) if entries >= 1 and entries <= ExplorerApp.most_entries => { ..s, generating: Generating(entries), note: "" }
		_ => { ..s, note: "Enter a number of entries from 1 to ${ExplorerApp.grouped(ExplorerApp.most_entries)}." }
	}

	## What a log that could not be explored says.
	explain : Problem -> Str
	explain = |problem| match problem {
		Unreadable => "The browser can no longer read this file. Choose it again."
		Empty => "The file is empty."
		NotALog => "This does not look like a log: no line starts with a timestamp and a level."
	}

	## A task's state as one line of text: working, why it failed, or what
	## `describe` says of its answer.
	status : Engine.Remote(a, Worker.Error(Problem)), Str, (a -> Str) -> Str
	status = |remote, working, describe| match Worker.status(remote) {
		Working => working
		Answered(value) => describe(value)
		Failed(problem) => ExplorerApp.explain(problem)
		Lost(fault) => "The worker stopped (${Str.inspect(fault)}). Open the log again to retry."
		Timeout => "This took too long."
		Refused => "Too many requests at once."
		Unasked => "Open a log file, or generate a sample."
	}

	## A count with thousands separated: `1,234,567`.
	grouped : U64 -> Str
	grouped = |n| {
		digits = n.to_str().to_utf8()
		var $out = []
		var $i = 0
		for d in digits {
			if $i > 0 and (digits.len() - $i) % 3 == 0 {
				$out = $out.append(',')
			}
			$out = $out.append(d)
			$i = $i + 1
		}
		Str.from_utf8_lossy($out)
	}

	size_text : U64 -> Str
	size_text = |n|
		if n < 1024 {
			"${n.to_str()} bytes"
		} else if n < 1048576 {
			"${(n / 1024).to_str()} KiB"
		} else {
			"${(n / 1048576).to_str()} MiB"
		}

	## A count and its noun: `1 line`, `2,000 lines`.
	counted : U64, { one : Str, many : Str } -> Str
	counted = |n, { one, many }| "${ExplorerApp.grouped(n)} ${if (n == 1) one else many}"

	## The overview's first line: the counts and the time the entries span.
	summary : Log.Overview -> Str
	summary = |o| {
		lines = "${ExplorerApp.counted(o.lines, { one: "line", many: "lines" })}, ${ExplorerApp.counted(o.entries, { one: "entry", many: "entries" })}"
		match o.span {
			Between({ earliest, latest }) => "${lines}, from ${earliest} to ${latest}"
			Untimed => lines
		}
	}

	level_tile : Val(ctx, Engine.Remote(Log.Overview, Worker.Error(Problem))), Log.Level -> Elem(ctx)
	level_tile = |r, level| {
		name = Log.level_name(level)
		Html.div(
			"stat",
			[
				Html.p(name, "stat-label"),
				Html.p_v(
					r.map(|remote| remote.answered().map_ok(|o| ExplorerApp.grouped(Log.tally_of(o.tally, level))) ?? "–"),
					[Engine.class("stat-value numeric"), Engine.test_id("level-${Str.from_utf8_lossy(name.to_utf8().map(|b| b + 32))}")],
				),
			],
		)
	}

	overview_panel : State(Ctx, S) -> Elem(Ctx)
	overview_panel = |st| {
		v = st.val()
		Worker.derive_when(
			ExplorerApp.overview,
			v.map(|s| ExplorerApp.asked(s, {})),
			|r| Html.section(
				"Overview",
				"grid gap-3",
				[
					Html.p_v(r.map(|remote| ExplorerApp.status(remote, "Indexing the log…", ExplorerApp.summary)), [Engine.test_id("overview")]),
					Html.div("stat-grid", Log.levels.map(|level| ExplorerApp.level_tile(r, level))),
					Html.p_v(
						r.map(
							|remote| match remote.answered() {
								Ok(o) => "Busiest sources: ${Str.join_with(o.sources.map(|s| "${s.source} ${ExplorerApp.grouped(s.entries)}"), ", ")} (of ${o.distinct_sources.to_str()})"
								Err(NoAnswer) => ""
							},
						),
						[Engine.class("hint"), Engine.test_id("sources")],
					),
				],
			),
		)
	}

	## One line of the log: its number, its level and its text. A search
	## result also has a button that shows it in the viewer.
	line_row : State(ctx, S), RowRef(ctx, Log.Line), [Jump, Stay] -> Elem(Row(ctx, Log.Line))
	line_row = |st0, row, jump| {
		st = st0.lift_row()
		number = row.field(|line| line.number)
		Engine.element(
			"li",
			[Engine.class("flex items-baseline gap-2 font-mono text-xs")],
			[
				match jump {
					Jump =>
						Engine.element(
							"button",
							[Engine.attr("type", "button"), Engine.class("button-ghost button-sm numeric"), Engine.attr_v("aria-label", number.map(|n| "Show line ${n.to_str()}")), Engine.on_click(st.update_by(number, |s, n| { ..s, tab: Viewer, first: n - 1 }))],
							[Engine.text_v(number.map(|n| n.to_str()))],
						)
					Stay => Html.span_v(number.map(|n| n.to_str()), [Engine.class("muted numeric")])
				},
				Html.span_v(row.field(|line| ExplorerApp.mark_name(line.mark)), [Engine.class_v(row.field(|line| ExplorerApp.mark_class(line.mark)))]),
				Html.span_v(row.field(|line| line.text), [Engine.class("whitespace-pre-wrap break-all"), Engine.test_id_v(number.map(|n| "line-${n.to_str()}"))]),
			],
		)
	}

	mark_name : Log.Mark -> Str
	mark_name = |mark| match mark {
		Entry(level) => Log.level_name(level)
		Continued(_) => "…"
		Unheaded => ""
	}

	mark_class : Log.Mark -> Str
	mark_class = |mark| match mark {
		Entry(Error) | Entry(Fatal) => "badge badge-danger"
		Entry(Warn) => "badge badge-warn"
		Entry(Info) => "badge badge-info"
		Entry(_) => "badge badge-neutral"
		Continued(_) | Unheaded => "muted"
	}

	search_panel : State(Ctx, S) -> Elem(Ctx)
	search_panel = |st| {
		v = st.val()
		Html.section(
			"Search",
			"grid gap-3",
			[
				Html.div(
					"toolbar",
					[
						Html.text_input(Engine.const("Text to find"), "search", v.map(|s| s.text), [Engine.class("input"), Engine.attr("placeholder", "Text to find, any case")], st.set_value(|s, text| { ..s, text, page: 0 })),
						Html.select(
							Engine.const("Level"),
							v.map(
								|s| match s.filter {
									Everything => "any"
									Only(level) => Log.level_name(level)
								},
							),
							[Engine.class("input")],
							[Html.option("any", "Any level")].concat(Log.levels.map(|level| Html.option(Log.level_name(level), Log.level_name(level)))),
							st.set_value(
								|s, value| {
									..s,
									filter: match Log.levels.find_first(|level| Log.level_name(level) == value) {
										Ok(level) => Only(level)
										Err(_) => Everything
									},
									page: 0,
								},
							),
						),
					],
				),
				Worker.derive_when(
					ExplorerApp.search,
					v.map(|s| ExplorerApp.asked(s, { text: s.text, filter: s.filter, page: s.page })),
					|r| Html.div(
						"grid gap-2",
						[
							Html.p_v(
								v.lift().map2(r, |s, remote| ExplorerApp.status(remote, "Searching…", |found| ExplorerApp.found_text(found, s.page))),
								[Engine.test_id("search-status")],
							),
							Engine.element("ol", [Engine.class("grid gap-1"), Html.aria_label("Search results")], [Engine.each(r.map(|remote| remote.answered().map_ok(|found| found.lines) ?? []), |line| line.number.to_str(), |row| ExplorerApp.line_row(st.lift(), row, Jump))]),
							Html.div(
								"toolbar",
								[
									Html.button("Previous page", [Engine.class("button button-sm")], st.lift().update(|s| { ..s, page: if (s.page > 0) s.page - 1 else 0 })),
									Html.button(
										"Next page",
										[Engine.class("button button-sm")],
										st.lift().update_by(
											r,
											|s, remote| match remote.answered() {
												Ok(found) if (s.page + 1) * Log.page_lines < found.matches => { ..s, page: s.page + 1 }
												_ => s
											},
										),
									),
								],
							),
						],
					),
				),
			],
		)
	}

	## How many lines matched, and which page is shown.
	found_text : Log.Found, U64 -> Str
	found_text = |found, page| {
		pages = (found.matches + Log.page_lines - 1) / Log.page_lines
		match found.matches {
			0 => "No matching lines."
			1 => "1 matching line."
			n => "${ExplorerApp.grouped(n)} matching lines, page ${(page + 1).to_str()} of ${ExplorerApp.grouped(pages)}."
		}
	}

	viewer_panel : State(Ctx, S) -> Elem(Ctx)
	viewer_panel = |st| {
		v = st.val()
		Worker.derive_when(
			ExplorerApp.window,
			v.map(|s| ExplorerApp.asked(s, s.first)),
			|r| {
				moved = |s, remote, step| match remote.answered() {
					Ok(w) => { ..s, first: step(w) }
					Err(NoAnswer) => s
				}
				Html.section(
					"Viewer",
					"grid gap-3",
					[
						Html.div(
							"toolbar",
							[
								Html.button("First", [Engine.class("button button-sm")], st.lift().update(|s| { ..s, first: 0 })),
								Html.button("Previous", [Engine.class("button button-sm")], st.lift().update_by(r, |s, remote| moved(s, remote, |w| if (w.first > Log.window_lines) w.first - Log.window_lines else 0))),
								Html.button("Next", [Engine.class("button button-sm")], st.lift().update_by(r, |s, remote| moved(s, remote, |w| Log.window_first({ lines: w.total, wanted: w.first + Log.window_lines })))),
								Html.button("Last", [Engine.class("button button-sm")], st.lift().update_by(r, |s, remote| moved(s, remote, |w| Log.window_first({ lines: w.total, wanted: w.total })))),
								Html.number_input(
									Engine.const("Go to line"),
									v.lift().map(|s| (s.first + 1).to_str()),
									[Engine.class("input w-32")],
									st.lift().set_value(
										|s, text| match U64.from_str(text.trim()) {
											Ok(line) if line >= 1 => { ..s, first: line - 1 }
											_ => s
										},
									),
								),
							],
						),
						Html.p_v(
							r.map(
								|remote| ExplorerApp.status(
									remote,
									"Reading…",
									|w| if (w.lines.is_empty()) "The log has no lines." else "Lines ${ExplorerApp.grouped(w.first + 1)}–${ExplorerApp.grouped(w.first + w.lines.len())} of ${ExplorerApp.grouped(w.total)}.",
								),
							),
							[Engine.test_id("viewer-status")],
						),
						Engine.element("ol", [Engine.class("grid gap-1"), Html.aria_label("Lines")], [Engine.each(r.map(|remote| remote.answered().map_ok(|w| w.lines) ?? []), |line| line.number.to_str(), |row| ExplorerApp.line_row(st.lift(), row, Stay))]),
					],
				)
			},
		)
	}

	tab_button : State(Ctx, S), Str, Tab -> Elem(Ctx)
	tab_button = |st, label, tab| {
		v = st.val()
		Html.action_button(Engine.const(label), Engine.const(Bool.False), [Engine.class("button button-sm"), Html.flag("aria-pressed", v.map(|s| s.tab == tab))], st.update(|s| { ..s, tab }))
	}

	view : State(Ctx, S) -> Elem(Ctx)
	view = |st| {
		v = st.val()
		Html.div(
			"app-shell",
			[
				Html.section(
					"Log Explorer",
					"app-header",
					[
						Html.h1("Log Explorer", "app-title"),
						Html.p("Open a log of any size: a worker indexes it once, and the overview, the search and the viewer ask that index their own questions, reading only the lines they need. The file never comes into the page.", "app-subtitle"),
					],
				),
				Engine.element(
					"section",
					[Engine.class("panel grid gap-3 p-4"), Html.aria_label("Open a log"), Html.on_drop_files(st.on_files(|s, { files, refused: _ }| ExplorerApp.dropped(s, files)))],
					[
						Html.div(
							"toolbar",
							[
								Html.file_input(Engine.const("Log file"), { accept: Types(".log,.txt,text/plain") }, st.on_files(|s, { files, refused: _ }| ExplorerApp.dropped(s, files))),
								Html.number_input(Engine.const("Entries"), v.map(|s| s.entries), [Engine.class("input w-32")], st.set_value(|s, entries| { ..s, entries })),
								Html.button("Generate a sample log", [Engine.class("button")], st.update(ExplorerApp.generated)),
								Html.button("Close the log", [Engine.class("button-ghost")], st.update(|s| { ..s, log: NoLog })),
							],
						),
						Html.p_v(
							v.map(
								|s| match (s.generating, s.log) {
									(Generating(entries), _) => "Generating a sample log of ${ExplorerApp.grouped(entries)} entries…"
									(Idle, Chosen(file)) => "${file.name()}, ${ExplorerApp.size_text(file.size())}"
									(Idle, NoLog) => "No log open. Drop a log file here, choose one, or generate a sample."
								},
							),
							[Engine.test_id("log")],
						),
						Html.p_v(v.map(|s| s.note), [Engine.class("hint"), Engine.test_id("note")]),
					],
				),
				Html.div(
					"toolbar",
					[
						ExplorerApp.tab_button(st, "Overview", Overview),
						ExplorerApp.tab_button(st, "Search", Search),
						ExplorerApp.tab_button(st, "Viewer", Viewer),
					],
				),
				# Each tab's task site lives in its branch: leaving a tab stops
				# its job and coming back asks again, which the prepared index
				# makes cheap.
				Html.div(
					"panel p-4",
					[
						Engine.switch(
							v.map(|s| s.tab),
							[Overview, Search, Viewer],
							|tab| match tab {
								Overview => ExplorerApp.overview_panel(st)
								Search => ExplorerApp.search_panel(st)
								Viewer => ExplorerApp.viewer_panel(st)
							},
						),
					],
				),
				# The sample, written to a file by a task of its own.
				Engine.latest(
					v.map(|s| s.generating),
					|generating| match generating {
						Generating(entries) => [ExplorerApp.generate.request(entries)]
						Idle => []
					},
					st.on_result(
						|s, _, res| match ExplorerApp.generate.result(res) {
							Ok(file) => { ..ExplorerApp.opened(s, file), generating: Idle }
							Err(problem) => { ..s, generating: Idle, note: "The sample was not written: ${Str.inspect(problem)}." }
						},
					),
				),
			],
		)
	}

	## The first file of a drop or a choice opens.
	dropped : S, List(File) -> S
	dropped = |s, files| match files {
		[file, ..] => ExplorerApp.opened(s, file)
		[] => s
	}

	program : Engine.Program
	program = Engine.program(|| Engine.state(ExplorerApp.initial, ExplorerApp.view)).with_workers(ExplorerApp.registrations)
}
