import pf.Engine exposing [Elem, File, Row, RowRef, Signal]
import pf.Files
import pf.Html
import pf.Worker
import Log
import LogStore
import Sample
import TimelineChart

## Log Explorer: open a log file of any size, or generate a sample, and
## explore it in three tabs: an overview, a search and a viewer.
##
## The file never comes into the page. A worker prepares it once: it reads
## the file a megabyte at a time and keeps an index (where each line starts,
## what it is, the counts, and a timeline of entries by level over time)
## and the file's handle, but not its text. The overview task is answered
## from the index alone, once for each log, and every tab reads its answer:
## the overview shows the counts and the timeline as a chart. The search
## and the viewer each ask their own task of the prepared state, from a
## site inside their tab: a search reads the file again in chunks (or,
## with no text, only the lines of its page) and adds its matches to the
## chart, and the viewer reads only the lines it shows. Switching tabs,
## paging and searching again cost the task, not the preparation; a new
## file is prepared afresh. A click on the chart opens the viewer at that
## time, from the timeline the page already has.
##
## The open log, the tab and the reader's place in the log are the page's
## store (`LogStore`). A tab reads the cells it draws where it draws them,
## however deep its sites nest, and what a click means for the store is
## one of the store's transitions.
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
	log = Worker.preparation({ name: "roc-signals.example/log-explorer/log", prepare!: ExplorerApp.index! })

	## A task of the log's preparation, given `input`, answering `output`.
	LogTask(input, output) : Worker.PreparedTask(File, Prepared, input, output, Problem)

	## The overview, from the index alone: the counts, the busiest sources
	## and the timeline.
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
	window : LogTask({ first : U64, count : U64 }, Log.Window)
	window = ExplorerApp.log.task({ name: "roc-signals.example/log-explorer/window", run!: ExplorerApp.window!, on_cancel: Finish })

	window! : Prepared, { first : U64, count : U64 } => Try(Log.Window, Problem)
	window! = |{ file, index }, wanted| {
		total = index.starts.len()
		first = Log.window_first({ lines: total, wanted: wanted.first, count: wanted.count })
		count = (total - first).min(wanted.count)
		bytes = file.read!(Log.span(index, { first, count }))?
		Ok({ first, total, count: wanted.count, lines: Log.lines_in(index, { first, count, bytes }) })
	}

	## A sample log of some number of entries, written to a new file.
	generate : Worker.Task(U64, File, Engine.FileError)
	generate = Worker.task({ name: "roc-signals.example/log-explorer/generate", run!: ExplorerApp.generate! })

	generate! : U64 => Try(File, Engine.FileError)
	generate! = |entries| {
		out = Files.build!({ name: "sample-${entries.to_str()}.log", mime: Mime("text/plain") })
		var $progress = Sample.start({ total: entries })
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

	## A tab's question for the open log, or none before one is open.
	asked : [NoLog, Chosen(File)], q -> [Run(Worker.Question(File, q)), Skip]
	asked = |open, input| match open {
		Chosen(file) => Run({ init: file, input })
		NoLog => Skip
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

	## Why the last request for a sample gave no log, in words.
	note_text : LogStore.Note -> Str
	note_text = |note| match note {
		NoNote => ""
		NotACount => "Enter a number of entries from 1 to ${ExplorerApp.grouped(LogStore.most_entries)}."
		NotWritten(problem) => "The sample was not written: ${Str.inspect(problem)}."
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

	## The overview task's answer, which every tab reads.
	OverviewAnswer : Engine.Remote(Log.Overview, Worker.Error(Problem))

	level_tile : Signal(ctx, OverviewAnswer), Log.Level -> Elem(ctx)
	level_tile = |r, level| {
		name = Log.level_name(level)
		Html.div(
			"stat",
			[
				Html.p(name, "stat-label"),
				Html.p_s(
					r.map(|remote| remote.answered().map_ok(|o| ExplorerApp.grouped(Log.tally_of(o.tally, level))) ?? "–"),
					[Engine.class("stat-value numeric"), Engine.test_id("level-${Str.from_utf8_lossy(name.to_utf8().map(|b| b + 32))}")],
				),
			],
		)
	}

	overview_panel : Signal(ctx, OverviewAnswer) -> Elem(ctx)
		where [ctx.store : () -> Engine.Reach(ctx, _)]
	overview_panel = |r|
		Html.section(
			"Overview",
			"grid gap-3",
			[
				Html.p_s(r.map(|remote| ExplorerApp.status(remote, "Indexing the log…", ExplorerApp.summary)), [Engine.test_id("overview")]),
				Html.div("stat-grid", Log.levels.map(|level| ExplorerApp.level_tile(r, level))),
				Html.p_s(
					r.map(
						|remote| match remote.answered() {
							Ok(o) => "Busiest sources: ${Str.join_with(o.sources.map(|s| "${s.source} ${ExplorerApp.grouped(s.entries)}"), ", ")} (of ${o.distinct_sources.to_str()})"
							Err(NoAnswer) => ""
						},
					),
					[Engine.class("hint"), Engine.test_id("sources")],
				),
				ExplorerApp.timeline_view(r, Engine.const(NotCounted)),
			],
		)

	## The timeline chart, with a line under it naming its peak: the
	## busiest bucket for errors, or for a search's matches. A click on a
	## point opens the viewer at that time.
	timeline_view : Signal(ctx, OverviewAnswer), Signal(ctx, [NotCounted, Counted(List(U64))]) -> Elem(ctx)
		where [ctx.store : () -> Engine.Reach(ctx, _)]
	timeline_view = |r, matches| {
		answered : Signal(ctx, Try({ o : Log.Overview, over_time : [NotCounted, Counted(List(U64))], theme : TimelineChart.Theme }, [NoAnswer]))
		answered = { remote: r, over_time: matches, theme: LogStore.cells.theme.signal() }.Signal.map(|{ remote, over_time, theme }| remote.answered().map_ok(|o| { o, over_time, theme }))
		Html.div(
			"grid gap-1",
			[
				Engine.element(
					"plume-chart",
					[
						Engine.class("block"),
						Engine.attr("role", "img"),
						Engine.test_id("timeline"),
						# The element reports a click on a point as the point's
						# time, in its value and a change event.
						Engine.attr("data-click", "x"),
						Engine.attr_s("data-background", LogStore.cells.theme.signal().map(TimelineChart.background)),
						Engine.attr_s("aria-label", answered.map(|a| a.map_ok(|{ o, over_time, .. }| ExplorerApp.timeline_label(o, over_time)) ?? "Timeline")),
						Engine.attr_presence(
							"data-figure",
							answered.map(
								|a| match a {
									Ok({ o, over_time, theme }) => TimelineChart.figure({ timeline: o.timeline, matches: over_time, revision: "${o.size.to_str()}/${o.lines.to_str()}", theme })
									Err(NoAnswer) => Absent
								},
							),
						),
						Html.on_change(Engine.handle_by({ remote: r, geometry: LogStore.cells.place.geometry.signal() }.Signal, |at, clicked| LogStore.timeline_clicked({ answered: at.remote.answered(), geometry: at.geometry, clicked }))),
					],
					[],
				),
				Html.p_s(answered.map(|a| a.map_ok(|{ o, over_time, .. }| ExplorerApp.peak_text(o, over_time)) ?? ""), [Engine.class("hint"), Engine.test_id("timeline-peak")]),
			],
		)
	}

	## What the chart shows, for a reader who cannot see it.
	timeline_label : Log.Overview, [NotCounted, Counted(List(U64))] -> Str
	timeline_label = |o, over_time| {
		per = TimelineChart.width_name(o.timeline.width)
		match over_time {
			NotCounted => "Entries per ${per} by level"
			Counted(_) => "Entries per ${per} by level, and the search's matches"
		}
	}

	## Where the timeline peaks: the bucket with the most errors (and fatal
	## entries), or with a search, the most matches. Entries whose time is
	## not a real one are not on the timeline, and the line says how many.
	peak_text : Log.Overview, [NotCounted, Counted(List(U64))] -> Str
	peak_text = |o, over_time| {
		per = TimelineChart.width_name(o.timeline.width)
		{ counts, what } = match over_time {
			NotCounted => { counts: o.timeline.buckets.map(|b| b.tally.error + b.tally.fatal), what: { one: "error", many: "errors" } }
			Counted(matches) => { counts: matches, what: { one: "match", many: "matches" } }
		}
		peak = match TimelineChart.peak(counts, { timeline: o.timeline }) {
			Peak({ time, count }) => "Most ${what.many} in a ${per}: ${ExplorerApp.counted(count, what)} at ${time}."
			NoPeak => "No ${what.many} on the timeline."
		}
		if (o.undated == 0) peak else "${peak} Not on the timeline: ${ExplorerApp.counted(o.undated, { one: "entry", many: "entries" })} whose time is not a real one."
	}

	## One line of the log: its number, its level and its text. A search
	## result also has a button that shows it in the viewer.
	line_row : RowRef(ctx, Log.Line), [Jump, Stay] -> Elem(Row(ctx, Log.Line))
		where [ctx.store : () -> Engine.Reach(ctx, _)]
	line_row = |row, jump| {
		number = row.field(|line| line.number)
		Engine.element(
			"li",
			[Engine.class("flex items-baseline gap-2 font-mono text-xs")].concat(
				match jump {
					Stay => [Engine.attr("style", "height:${Log.line_height.to_str()}px;line-height:${Log.line_height.to_str()}px;white-space:pre")]
					Jump => []
				},
			),
			[
				match jump {
					Jump =>
						Engine.element(
							"button",
							[Engine.attr("type", "button"), Engine.class("button-ghost button-sm numeric"), Engine.attr_s("aria-label", number.map(|n| "Show line ${n.to_str()}")), Engine.on_click(Engine.handle_by({ number: number, geometry: LogStore.cells.place.geometry.signal() }.Signal, |at, _| LogStore.shown_at(at.geometry, at.number - 1)))],
							[Engine.text_s(number.map(|n| n.to_str()))],
						)
					Stay => Html.span_s(number.map(|n| n.to_str()), [Engine.class("muted numeric")])
				},
				Html.span_s(
					row.field(|line| ExplorerApp.mark_name(line.mark)),
					[Engine.class_s(row.field(|line| ExplorerApp.mark_class(line.mark)))].concat(
						match jump {
							Stay => [Engine.attr("style", "padding-block:0;line-height:16px")]
							Jump => []
						},
					),
				),
				Html.span_s(
					row.field(|line| line.text),
					[
						Engine.class(
							match jump {
								Jump => "whitespace-pre-wrap break-all"
								Stay => "whitespace-pre"
							},
						),
						Engine.test_id_s(number.map(|n| "line-${n.to_str()}")),
					],
				),
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

	## The search: its text and level, a page of what it found, and the
	## overview's timeline with its matches.
	search_panel : Signal(ctx, OverviewAnswer) -> Elem(ctx)
		where [ctx.store : () -> Engine.Reach(ctx, _)]
	search_panel = |answer| {
		cells = LogStore.cells
		query = cells.query.signal()
		Html.section(
			"Search",
			"grid gap-3",
			[
				Html.div(
					"toolbar",
					[
						Html.text_input(Engine.const("Text to find"), "search", query.map(|typed| typed.text), [Engine.class("input"), Engine.attr("placeholder", "Text to find, any case")], Engine.handle(LogStore.searched)),
						Html.select(
							Engine.const("Level"),
							query.map(|typed| typed.filter),
							Engine.const([Everything].concat(Log.levels.map(|level| Only(level)))),
							{
								key: |filter| match filter {
									Everything => "any"
									Only(level) => Log.level_name(level)
								},
								label: |filter| match filter {
									Everything => "Any level"
									Only(level) => Log.level_name(level)
								},
							},
							[Engine.class("input")],
							Engine.handle(LogStore.filtered),
						),
					],
				),
				Worker.resource_when(
					ExplorerApp.search,
					{ open: cells.log.signal(), typed: query, page: cells.place.page.signal() }.Signal.map(|at| ExplorerApp.asked(at.open, { text: at.typed.text, filter: at.typed.filter, page: at.page })),
					|r| Html.div(
						"grid gap-2",
						[
							Html.p_s(
								cells.place.page.signal().map2(r, |page, remote| ExplorerApp.status(remote, "Searching…", |found| ExplorerApp.found_text(found, page))),
								[Engine.test_id("search-status")],
							),
							Engine.element("ol", [Engine.class("grid gap-1"), Html.aria_label("Search results")], [Engine.each(r.map(|remote| remote.answered().map_ok(|found| found.lines) ?? []), |line| line.number.to_str(), |row| ExplorerApp.line_row(row, Jump))]),
							Html.div(
								"toolbar",
								[
									Html.button("Previous page", [Engine.class("button button-sm")], Engine.does(LogStore.paged_back)),
									Html.button("Next page", [Engine.class("button button-sm")], Engine.handle_by(r, |remote, _| LogStore.paged_on(remote.answered()))),
								],
							),
							# The overview's timeline, with this search's matches
							# added once it has counted them.
							ExplorerApp.timeline_view(answer.lift(), r.map(|remote| remote.answered().map_ok(|found| found.over_time) ?? NotCounted)),
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

	## The viewer: a page of the log's lines from the reader's place, and
	## the ways to move it.
	viewer_panel : {} -> Elem(ctx)
		where [ctx.store : () -> Engine.Reach(ctx, _)]
	viewer_panel = |{}| Engine.remount_on(LogStore.cells.log.signal(), || ExplorerApp.viewer_for_log({}))

	## Each chosen file owns its resource; an old file can never lend its total
	## to a newly opened log while that log's first window is pending.
	viewer_for_log : {} -> Elem(ctx)
		where [ctx.store : () -> Engine.Reach(ctx, _)]
	viewer_for_log = |{}| {
		cells = LogStore.cells
		Worker.resource_when(
			ExplorerApp.window,
			{ open: cells.log.signal(), first: cells.place.first.signal(), viewport: cells.viewport.signal() }.Signal.map(
				|at| match at.viewport.capacity() {
					Ok(count) => ExplorerApp.asked(at.open, { first: at.first, count })
					Err(Unmeasured) => Skip
				},
			),
			|r| {
				geometry = { answer: r, prior: cells.place.geometry.signal(), viewport: cells.viewport.signal() }.Signal.map(
					|at| {
						total = match at.answer.answered() {
							Ok(answered) => Ok(answered.total)
							Err(NoAnswer) => match at.prior {
								Ready(map) => Ok(map.total)
								Awaiting => Err(NoAnswer)
							}
						}
						match (total, at.viewport.height()) {
							(Ok(lines), Ok(height)) => Ready({ total: lines, line_height: Log.line_height, viewport_height: height })
							_ => Awaiting
						}
					},
				)
				Html.section(
					"Viewer",
					"grid gap-3",
					[
						Html.div(
							"toolbar",
							[
								Html.button("First", [Engine.class("button button-sm")], Engine.handle_by(cells.place.geometry.signal(), |known, _| LogStore.moved_to(known, Ok(0)))),
								Html.button("Previous", [Engine.class("button button-sm")], ExplorerApp.stepped(r, |w| if (w.first > w.count) w.first - w.count else 0)),
								Html.button("Next", [Engine.class("button button-sm")], ExplorerApp.stepped(r, |w| Log.window_first({ lines: w.total, wanted: w.first + w.count, count: w.count }))),
								Html.button("Last", [Engine.class("button button-sm")], ExplorerApp.stepped(r, |w| Log.window_first({ lines: w.total, wanted: w.total, count: w.count }))),
								Html.number_input(
									Engine.const("Go to line"),
									cells.place.first.signal().map(|first| (first + 1).to_str()),
									[Engine.class("input w-32")],
									Engine.handle_by(cells.place.geometry.signal(), LogStore.went_to),
								),
							],
						),
						Html.p_s(
							r.map(
								|remote| ExplorerApp.status(
									remote,
									"Reading…",
									|w| if (w.lines.is_empty()) "The log has no lines." else "Lines ${ExplorerApp.grouped(w.first + 1)}–${ExplorerApp.grouped(w.first + w.lines.len())} of ${ExplorerApp.grouped(w.total)}.",
								),
							),
							[Engine.test_id("viewer-status")],
						),
						Engine.element(
							"div",
							[
								Engine.test_id("viewer-viewport"),
								Engine.ref("log-viewer"),
								Engine.attr("tabindex", "0"),
								Html.aria_label("Log lines"),
								Engine.attr("style", "height:min(60vh,1000px);min-width:0;overflow:auto;overflow-anchor:none"),
								Html.on_size(Engine.handle(|size| LogStore.viewer_sized(size.height))),
								Html.on_scroll(Engine.handle_by({ geometry: cells.place.geometry.signal(), asked: cells.place.asked.signal() }.Signal, |at, scroll| LogStore.scrolled(at, scroll.top))),
							],
							[
								Engine.element(
									"div",
									[
										Engine.test_id("viewer-spacer"),
										Engine.attr_s(
											"style",
											geometry.map(
												|map| {
													height = match map {
														Ready(known) => Log.spacer_height({ total: known.total, line_height: known.line_height })
														Awaiting => 0
													}
													"height:${height.to_str()}px;position:relative"
												},
											),
										),
									],
									[Engine.element("ol", [Engine.class("m-0 p-0"), Engine.attr("style", "position:sticky;top:0;width:max-content;min-width:100%;margin:0;padding:0"), Html.aria_label("Lines")], [Engine.each(r.map(|remote| remote.answered().map_ok(|w| w.lines) ?? []), |line| line.number.to_str(), |row| ExplorerApp.line_row(row, Stay))])],
								),
							],
						),
						Engine.on_post(cells.scrolling.signal(), |top| [Engine.command(ScrollTo("log-viewer", { top: Px(top), left: Keep, behavior: Instant }))], Engine.ignore({})),
						# Mount and geometry changes restore the current intent. Self is an
						# ordinary follow-up, settled before this call publishes its batch.
						Engine.watch(
							geometry,
							|map| match map {
								Ready(_) => [Engine.again({})]
								Awaiting => []
							},
							Engine.react_by(
								{ first: cells.place.first.signal(), previous: cells.place.geometry.signal(), asked: cells.place.asked.signal() }.Signal,
								|at, map, result| match (map, result) {
									(Ready(known), Ok({})) => LogStore.geometry_ready({ total: known.total, height: known.viewport_height, first: at.first, previous: at.previous, asked: at.asked })
									_ => crash "ExplorerApp.viewer_for_log: geometry follow-up was not successful"
								},
							),
						),
					],
				)
			},
		)
	}

	## A handler that moves the viewer to the line `step` works out from
	## the page it shows. It is a function of the module rather than a
	## local of `viewer_panel`: as a local helper it makes `roc check` of
	## this module take minutes with the pinned compiler
	## (roc-lang/roc#12869, fixed in later ones).
	stepped : Signal(ctx, Engine.Remote(Log.Window, Worker.Error(Problem))), (Log.Window -> U64) -> Engine.Handler(ctx)
		where [ctx.store : () -> Engine.Reach(ctx, _)]
	stepped = |r, step| Engine.handle_by({ remote: r, geometry: LogStore.cells.place.geometry.signal() }.Signal, |at, _| LogStore.moved_to(at.geometry, at.remote.answered().map_ok(step)))

	tab_button : Str, LogStore.Tab -> Elem(ctx)
		where [ctx.store : () -> Engine.Reach(ctx, _)]
	tab_button = |label, tab| Html.action_button(
		Engine.const(label),
		Engine.const(Bool.False),
		[Engine.class("button button-sm"), Html.flag("aria-pressed", LogStore.cells.tab.signal().map(|showing| showing == tab))],
		Engine.does(LogStore.turned_to(tab)),
	)

	## Where a log is opened: a file chosen or dropped, or a sample of the
	## entries typed. A choice or a drop opens its file as one decision, in
	## the event that carried it. The number typed is this panel's own
	## state; asking for a sample hands it to the store's decision.
	opener : {} -> Elem(ctx)
		where [ctx.store : () -> Engine.Reach(ctx, _)]
	opener = |{}| Engine.state(
		"20000",
		|entries| {
			cells = LogStore.cells
			arrival = Engine.handle(LogStore.arrived)
			Engine.element(
				"section",
				[Engine.class("panel grid gap-3 p-4"), Html.aria_label("Open a log"), Html.on_drop_files(arrival)],
				[
					Html.div(
						"toolbar",
						[
							Html.file_input(Engine.const("Log file"), { accept: Types(".log,.txt,text/plain") }, arrival),
							Html.number_input(Engine.const("Entries"), entries.signal(), [Engine.class("input w-32")], entries.set_value(|_, typed| typed)),
							Html.button("Generate a sample log", [Engine.class("button")], Engine.handle_by(entries.signal(), |typed, _| LogStore.sample_asked(typed))),
							Html.button("Close the log", [Engine.class("button-ghost")], Engine.does(LogStore.closed)),
						],
					),
					Html.p_s(
						cells.generating.signal().map2(
							cells.log.signal(),
							|generating, open| match (generating, open) {
								(Generating(count), _) => "Generating a sample log of ${ExplorerApp.grouped(count)} entries…"
								(Idle, Chosen(file)) => "${file.name()}, ${ExplorerApp.size_text(file.size())}"
								(Idle, NoLog) => "No log open. Drop a log file here, choose one, or generate a sample."
							},
						),
						[Engine.test_id("log")],
					),
					Html.p_s(cells.note.signal().map(ExplorerApp.note_text), [Engine.class("hint"), Engine.test_id("note")]),
				],
			)
		},
	)

	view : {} -> Elem(Engine.StoreRoot(_))
	view = |{}| {
		cells = LogStore.cells
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
				Engine.watch(Engine.const({}), |_| [Engine.media_changes(LogStore.dark_query)], Engine.react(|_, result| LogStore.media_changed(result))),
				ExplorerApp.opener({}),
				Html.div(
					"toolbar",
					[
						ExplorerApp.tab_button("Overview", Overview),
						ExplorerApp.tab_button("Search", Search),
						ExplorerApp.tab_button("Viewer", Viewer),
					],
				),
				# The overview's site sits above the tabs: it is asked once for
				# each log, and every tab reads its answer. The search's and
				# the viewer's sites live in their branches: leaving a tab
				# stops its job and coming back asks again, which the prepared
				# index makes cheap.
				Worker.resource_when(
					ExplorerApp.overview,
					cells.log.signal().map(|open| ExplorerApp.asked(open, {})),
					|answer| Html.div(
						"panel p-4",
						[
							Engine.switch(
								cells.tab.signal(),
								[Overview, Search, Viewer],
								|tab| match tab {
									Overview => ExplorerApp.overview_panel(answer)
									Search => ExplorerApp.search_panel(answer)
									Viewer => ExplorerApp.viewer_panel({})
								},
							),
						],
					),
				),
				# What the preparation and each later question took, from the
				# runtime's monitor: the example's own element, which draws in
				# its own shadow root and only reads.
				Engine.element("log-timings", [Engine.class("block")], []),
				# The sample, written to a file by a task of its own.
				Engine.watch_latest(
					cells.generating.signal(),
					|generating| match generating {
						Generating(entries) => [ExplorerApp.generate.ask(entries)]
						Idle => []
					},
					Engine.react(|_, res| LogStore.sample_written(res)),
				),
			],
		)
	}

	program : Engine.Program
	program = Engine.program_store({ media: [LogStore.dark_query] }, LogStore.start, |_boot| ExplorerApp.view({})).with_workers(ExplorerApp.registrations)
}
