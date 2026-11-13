import pf.Engine exposing [File]
import pf.Worker
import Log
import TimelineChart

## The Log Explorer's store: the open log and where the reader is in it,
## held at the root and read by every tab with no `lift`, and every
## transition over it as a pure function that returns its writes.
##
## - `log`: the log that is open, if any. Closing it, or opening another,
##   lets its file go.
## - `tab`: the tab that is showing.
## - `query`: the search as typed: its text and the level it keeps.
## - `place`: where the reader is in the open log, the search's page and
##   the viewer's first line. A group, because a new log starts both from
##   its beginning: `opened` applies the reset the description generated.
## - `viewport`: the capacity of the observed viewer, kept across tabs.
##   It waits for the first report before asking for a window.
## - `theme`: the declared color-scheme query, starting from boot.
## - `generating`: the sample being written, if one is.
## - `note`: why the last request for a sample gave no log.
##
## The number of entries typed for a sample is not here: only the box it
## is typed in reads it, so it is a state of that box.
LogStore := [Explorer].{

	## The tabs.
	Tab : [Overview, Search, Viewer]

	## The search as typed.
	Query : { text : Str, filter : Log.Filter }

	## Why the last request for a sample gave no log: the entries typed are
	## not a number the generator writes, or its task did not finish.
	Note : [NoNote, NotACount, NotWritten(Worker.Error(Engine.FileError))]

	## Geometry belongs to the chosen immutable file. Before its first window
	## answers, a requested line remains intent and has no proportional offset.
	Geometry : [Awaiting, Ready(Log.ScrollMap)]

	## Close the initial union before it is stored (roc-lang/roc#13011).
	awaiting_geometry : Geometry
	awaiting_geometry = Awaiting

	## The most entries the sample generator writes.
	most_entries : U64
	most_entries = 2000000

	store = Engine.store(
		LogStore.Explorer,
		{
			log: Engine.cell(NoLog),
			tab: Engine.cell(Overview),
			query: Engine.cell({ text: "", filter: Everything }),
			place: {
				page: Engine.cell(0.U64),
				first: Engine.cell(0.U64),
				asked: Engine.cell(0.U32),
				geometry: Engine.cell(LogStore.awaiting_geometry),
			}.Engine.Cells.with_reset(|cells, reset| { page: cells.page, first: cells.first, asked: cells.asked, geometry: cells.geometry, reset }),
			viewport: Engine.cell(Log.Viewport.waiting),
			scrolling: Engine.cell(Engine.outbox({})),
			# Construct the full union: an open Light initializer crashes monotype
			# across store tests (https://github.com/roc-lang/roc/issues/13011).
			theme: Engine.cell(TimelineChart.preferred_theme(Bool.False)),
			generating: Engine.cell(Idle),
			note: Engine.cell(NoNote),
		}.Engine.Cells,
	)

	## The store's cells.
	cells = LogStore.store.cells()

	## The query the timeline follows, declared before boot reads it.
	dark_query : Str
	dark_query = "(prefers-color-scheme: dark)"

	## The first figure already uses the declared boot preference.
	start : Engine.Boot -> Engine.Store(_, _)
	start = |boot| match Engine.boot_media(boot, LogStore.dark_query) {
		Ok(matches) => LogStore.store.with_initial(LogStore.cells.theme, TimelineChart.preferred_theme(matches))
		Err(Undeclared) => crash "LogStore.start: color-scheme query was not declared"
	}

	## A size report supplies both capacity and the scroll map's height. The
	## viewer reconciles its offset when the resulting geometry settles.
	viewer_sized : U32 -> List(Engine.Write(_))
	viewer_sized = |height| [LogStore.cells.viewport.set(Log.Viewport.for_height(height))]

	## The subscription changes chart presentation without touching the log.
	media_changed : Engine.Result -> List(Engine.Write(_))
	media_changed = |result| match result {
		Matches(matches) => [LogStore.cells.theme.set(TimelineChart.preferred_theme(matches))]
		_ => []
	}

	## The reader chose or dropped files: the first is the log to open, in
	## the event that carried it. The others are not kept, and an event
	## that carried no file changes nothing.
	arrived : Engine.Received -> List(Engine.Write(_))
	arrived = |{ files, refused: _ }| match files {
		[file, ..] => LogStore.opened(file)
		[] => []
	}

	## A new log is open.
	opened : File -> List(Engine.Write(_))
	opened = |file| [LogStore.cells.log.set(Chosen(file))].concat(LogStore.fresh)

	## What every new log starts from: the search and the viewer at its
	## beginning, and nothing to say.
	fresh : List(Engine.Write(_))
	fresh = [
		LogStore.cells.place.reset,
		LogStore.cells.note.set(NoNote),
	]

	## The log is closed, and its file let go.
	closed : List(Engine.Write(_))
	closed = [LogStore.cells.log.set(NoLog), LogStore.cells.place.reset]

	## Ask for a sample of the entries typed, or say why not.
	sample_asked : Str -> List(Engine.Write(_))
	sample_asked = |typed| match U64.from_str(typed.trim()) {
		Ok(entries) if entries >= 1 and entries <= LogStore.most_entries => [LogStore.cells.generating.set(Generating(entries)), LogStore.cells.note.set(NoNote)]
		_ => [LogStore.cells.note.set(NotACount)]
	}

	## The sample's task answered: its file opens, or the note says why
	## there is none.
	sample_written : Try(File, Worker.Error(Engine.FileError)) -> List(Engine.Write(_))
	sample_written = |answer| {
		ended = LogStore.cells.generating.set(Idle)
		match answer {
			Ok(file) => [ended].concat(LogStore.opened(file))
			Err(problem) => [ended, LogStore.cells.note.set(NotWritten(problem))]
		}
	}

	## Another tab is showing.
	turned_to : Tab -> List(Engine.Write(_))
	turned_to = |tab| [LogStore.cells.tab.set(tab)]

	## The viewer, opened at a line (from 0). A known geometry places its
	## scrollbar immediately; an unmeasured log keeps the line until it can.
	shown_at : Geometry, U64 -> List(Engine.Write(_))
	shown_at = |geometry, line| [LogStore.cells.tab.set(Viewer)].concat(LogStore.moved_to(geometry, Ok(line)))

	## The chart's point names the first line of that minute or the next
	## bucket with entries. An unanswered timeline or an invalid time is inert.
	timeline_clicked : { answered : Try(Log.Overview, [NoAnswer]), geometry : Geometry, clicked : Str } -> List(Engine.Write(_))
	timeline_clicked = |{ answered, geometry, clicked }| match (answered, Log.minute_of(clicked.to_utf8())) {
		(Ok(overview), Ok(minute)) => match Log.first_line_from(overview.timeline, minute) {
			Ok(line) => LogStore.shown_at(geometry, line)
			Err(NoLaterEntry) => []
		}
		_ => []
	}

	## A newly known line count, a remount or a changed height reconciles the
	## current line intent. Only small geometry is retained, never log contents.
	geometry_ready : { total : U64, height : U32, first : U64, previous : Geometry, asked : U32 } -> List(Engine.Write(_))
	geometry_ready = |{ total, height, first, previous, asked }| {
		map = { total, viewport_height: height, line_height: Log.line_height }
		offset = if (previous == Ready(map)) asked else Log.offset_of(map, first)
		[LogStore.cells.place.geometry.set(Ready(map)), LogStore.cells.place.asked.set(offset), LogStore.cells.scrolling.update(|box| box.post(offset))]
	}

	## A scroll echo can be rounded one pixel from the requested offset. It
	## writes nothing; a hand scroll keeps its actual offset beside its line.
	scrolled : { geometry : Geometry, asked : U32 }, U32 -> List(Engine.Write(_))
	scrolled = |{ geometry, asked }, top| {
		distance = if (top >= asked) top - asked else asked - top
		if distance <= 1 {
			return []
		}
		match geometry {
			Ready(map) => [LogStore.cells.place.first.set(Log.first_at(map, top)), LogStore.cells.place.asked.set(top)]
			Awaiting => []
		}
	}

	## The search's text as typed: a new search starts from its first page.
	searched : Str -> List(Engine.Write(_))
	searched = |text| [LogStore.cells.query.update(|query| { ..query, text }), LogStore.cells.place.page.set(0)]

	## The level the search keeps, by the name the menu sends; any other
	## name keeps every level. A new search starts from its first page.
	filtered : Str -> List(Engine.Write(_))
	filtered = |name| {
		filter = match Log.levels.find_first(|level| Log.level_name(level) == name) {
			Ok(level) => Only(level)
			Err(_) => Everything
		}
		[LogStore.cells.query.update(|query| { ..query, filter }), LogStore.cells.place.page.set(0)]
	}

	## The search's page before this one, or the first.
	paged_back : List(Engine.Write(_))
	paged_back = [LogStore.cells.place.page.update(|page| if (page > 0) page - 1 else 0)]

	## The search's next page, when what it found has one.
	paged_on : Try(Log.Found, [NoAnswer]) -> List(Engine.Write(_))
	paged_on = |answered| match answered {
		Ok(found) => [LogStore.cells.place.page.update(|page| if ((page + 1) * Log.page_lines < found.matches) page + 1 else page)]
		Err(NoAnswer) => []
	}

	## A jump is one decision over line intent and physical offset. When the
	## count is not known, no guessed offset is sent to the browser.
	moved_to : Geometry, Try(U64, [NoAnswer]) -> List(Engine.Write(_))
	moved_to = |geometry, line| match line {
		Ok(first) => {
			asked = match geometry {
				Ready(map) => Log.offset_of(map, first)
				Awaiting => 0
			}
			[LogStore.cells.place.first.set(first), LogStore.cells.place.asked.set(asked)].concat(
				match geometry {
					Ready(_) => [LogStore.cells.scrolling.update(|box| box.post(asked))]
					Awaiting => []
				},
			)
		}
		Err(NoAnswer) => []
	}

	## The viewer sent to a one-based line typed by its reader.
	went_to : Geometry, Str -> List(Engine.Write(_))
	went_to = |geometry, typed| match U64.from_str(typed.trim()) {
		Ok(line) if line >= 1 => LogStore.moved_to(geometry, Ok(line - 1))
		_ => []
	}

}

## Where a store's reader is: the tab, the search's page and the viewer's
## first line.
place_in : Engine.Store(_, _) -> Str
place_in = |store| "${Str.inspect(store.read(LogStore.cells.tab))} page ${store.read(LogStore.cells.place.page).to_str()} line ${store.read(LogStore.cells.place.first).to_str()}"

## A new log starts the search and the viewer from its beginning and says
## nothing, whatever the last one left. An `expect` cannot make a file, so
## this reaches `opened` through the writes every new log starts from.
expect {
	left = LogStore.store
		.after(LogStore.sample_asked("none"))
		.after(LogStore.searched("reset"))
		.after(LogStore.paged_on(Ok({ matches: 200, lines: [], over_time: NotCounted })))
		.after(LogStore.shown_at(LogStore.awaiting_geometry, 41))
	begun = left.after(LogStore.fresh)
	actual =
		\\left: ${place_in(left)}, ${Str.inspect(left.read(LogStore.cells.note))}
		\\begun: ${place_in(begun)}, ${Str.inspect(begun.read(LogStore.cells.note))}, "${begun.read(LogStore.cells.query).text}"
	expected =
		\\left: Viewer page 1 line 41, NotACount
		\\begun: Viewer page 0 line 0, NoNote, "reset"
	actual == expected
}

## An event that carried no file opens nothing.
expect LogStore.arrived({ files: [], refused: 2 }).len() == 0

## A sample is asked for only with a number of entries the generator
## writes, and a task that did not finish says why.
expect {
	generating_in = |store| Str.inspect(store.read(LogStore.cells.generating))
	none = LogStore.store.after(LogStore.sample_asked("0"))
	many = LogStore.store.after(LogStore.sample_asked(" 3000 "))
	lost = many.after(LogStore.sample_written(Err(Timeout)))
	actual =
		\\none: ${generating_in(none)} ${Str.inspect(none.read(LogStore.cells.note))}
		\\many: ${generating_in(many)} ${Str.inspect(many.read(LogStore.cells.note))}
		\\too many: ${generating_in(LogStore.store.after(LogStore.sample_asked("2000001")))}
		\\lost: ${generating_in(lost)} ${Str.inspect(lost.read(LogStore.cells.note))}
	expected =
		\\none: Idle NotACount
		\\many: Generating(3000) NoNote
		\\too many: Idle
		\\lost: Idle NotWritten(Timeout)
	actual == expected
}

## A search pages on only while what it found has another page, back no
## further than the first, and a new text or level starts from the first.
expect {
	found = Ok({ matches: 2 * Log.page_lines, lines: [], over_time: NotCounted })
	page_in = |store| store.read(LogStore.cells.place.page).to_str()
	second = LogStore.store.after(LogStore.paged_on(found))
	third = second.after(LogStore.paged_on(found))
	back = third.after(LogStore.paged_back).after(LogStore.paged_back)
	levelled = second.after(LogStore.filtered("ERROR"))
	actual =
		\\pages: ${page_in(second)} ${page_in(third)} ${page_in(back)} ${page_in(LogStore.store.after(LogStore.paged_on(Err(NoAnswer))))}
		\\typed: ${page_in(second.after(LogStore.searched("pool")))}
		\\levelled: ${page_in(levelled)} ${Str.inspect(levelled.read(LogStore.cells.query).filter)} ${Str.inspect(levelled.after(LogStore.filtered("any")).read(LogStore.cells.query).filter)}
	expected =
		\\pages: 1 1 0 0
		\\typed: 0
		\\levelled: 0 Only(Error) Everything
	actual == expected
}

## A click on the timeline opens the viewer at the first line of that
## minute, or of the next one with entries; a time after the last entry,
## text that is not a time and a timeline not yet answered change nothing.
expect {
	text = "2026-11-11T12:00:10Z INFO api: one\n2026-11-11T12:00:40Z INFO api: two\n2026-11-11T12:03:00Z ERROR api: three\n"
	overview = Log.overview(Log.finish(Log.feed(Log.indexer, text.to_utf8())))
	clicked = |time| place_in(LogStore.store.after(LogStore.timeline_clicked({ answered: Ok(overview), geometry: LogStore.awaiting_geometry, clicked: time })))
	actual =
		\\that minute: ${clicked("2026-11-11 12:00")}
		\\the next with entries: ${clicked("2026-11-11 12:01")}
		\\after the last: ${clicked("2026-11-11 13:00")}
		\\not a time: ${clicked("soon")}
		\\unanswered: ${place_in(LogStore.store.after(LogStore.timeline_clicked({ answered: Err(NoAnswer), geometry: LogStore.awaiting_geometry, clicked: "2026-11-11 12:03" })))}
		\\typed: ${place_in(LogStore.store.after(LogStore.went_to(LogStore.awaiting_geometry, "7")))}, ${place_in(LogStore.store.after(LogStore.went_to(LogStore.awaiting_geometry, "0")))}
	expected =
		\\that minute: Viewer page 0 line 0
		\\the next with entries: Viewer page 0 line 2
		\\after the last: Overview page 0 line 0
		\\not a time: Overview page 0 line 0
		\\unanswered: Overview page 0 line 0
		\\typed: Overview page 0 line 6, Overview page 0 line 0
	actual == expected
}

## The boot preference is available before any subscription result.
expect {
	boot = LogStore.start({ media: [(LogStore.dark_query, Bool.True)] })
	boot.read(LogStore.cells.theme) == Dark
}

## Resizing retains the reader's place and changing media retains capacity.
expect {
	before = LogStore.store.after(LogStore.shown_at(LogStore.awaiting_geometry, 99))
	fitted = before.after(LogStore.viewer_sized(400))
	dark = fitted.after(LogStore.media_changed(Matches(Bool.True)))
	actual = {
		count: dark.read(LogStore.cells.viewport).capacity()?,
		first: dark.read(LogStore.cells.place.first),
		theme: dark.read(LogStore.cells.theme),
		light: dark.after(LogStore.media_changed(Matches(Bool.False))).read(LogStore.cells.theme),
		refused: LogStore.media_changed(Refused).len(),
	}
	actual == { count: 20, first: 99, theme: Dark, light: Light, refused: 0 }
}

## A measured jump writes both facts; its echo is inert and a hand scroll
## writes the mapped line and the offset it actually reported.
expect {
	geometry = Ready({ total: 2000000, line_height: 20, viewport_height: 400 })
	jumped = LogStore.store.after(LogStore.moved_to(geometry, Ok(123456)))
	asked = jumped.read(LogStore.cells.place.asked)
	hand = jumped.after(LogStore.scrolled({ geometry, asked }, 4000000))
	{ first: jumped.read(LogStore.cells.place.first), asked, echo: LogStore.scrolled({ geometry, asked }, asked + 1).len(), hand_first: hand.read(LogStore.cells.place.first), hand_asked: hand.read(LogStore.cells.place.asked) } == {
		first: 123456,
		asked: Log.offset_of({ total: 2000000, line_height: 20, viewport_height: 400 }, 123456),
		echo: 0,
		hand_first: Log.first_at({ total: 2000000, line_height: 20, viewport_height: 400 }, 4000000),
		hand_asked: 4000000,
	}
}

## A line chosen before geometry exists is placed once that geometry arrives;
## a partial-height resize changes the offset without moving the line intent.
expect {
	intent = LogStore.store.after(LogStore.shown_at(LogStore.awaiting_geometry, 99))
	ready = intent.after(LogStore.geometry_ready({ total: 100, height: 39, first: intent.read(LogStore.cells.place.first), previous: intent.read(LogStore.cells.place.geometry), asked: intent.read(LogStore.cells.place.asked) }))
	resized = ready.after(LogStore.viewer_sized(19)).after(LogStore.geometry_ready({ total: 100, height: 19, first: ready.read(LogStore.cells.place.first), previous: ready.read(LogStore.cells.place.geometry), asked: ready.read(LogStore.cells.place.asked) }))
	{ before: intent.read(LogStore.cells.place.asked), ready: ready.read(LogStore.cells.place.asked), resized: resized.read(LogStore.cells.place.asked), first: resized.read(LogStore.cells.place.first) } == { before: 0, ready: 1961, resized: 1980, first: 99 }
}

## Entering the viewer before a capped log's first answer retains exact line
## intent, then places it using the real geometry. Opening a new log resets it.
expect {
	intent = LogStore.store.after(LogStore.shown_at(LogStore.awaiting_geometry, 123456))
	ready = intent.after(LogStore.geometry_ready({ total: 2000000, height: 400, first: intent.read(LogStore.cells.place.first), previous: intent.read(LogStore.cells.place.geometry), asked: intent.read(LogStore.cells.place.asked) }))
	fresh = ready.after(LogStore.fresh)
	{ intent: intent.read(LogStore.cells.place.first), before: intent.read(LogStore.cells.place.asked), placed: ready.read(LogStore.cells.place.asked), reset_first: fresh.read(LogStore.cells.place.first), reset_asked: fresh.read(LogStore.cells.place.asked), reset_geometry: fresh.read(LogStore.cells.place.geometry) } == {
		intent: 123456,
		before: 0,
		placed: Log.offset_of({ total: 2000000, line_height: 20, viewport_height: 400 }, 123456),
		reset_first: 0,
		reset_asked: 0,
		reset_geometry: Awaiting,
	}
}

## Returning to an unchanged geometry restores a hand scroll's actual pixel,
## which need not be the canonical pixel of its nearest line on a capped map.
expect {
	map = { total: 2000000, line_height: 20, viewport_height: 400 }
	asked = 4999824
	first = Log.first_at(map, asked)
	returned = LogStore.store.after(LogStore.geometry_ready({ total: map.total, height: map.viewport_height, first, previous: Ready(map), asked }))
	returned.read(LogStore.cells.place.asked) == asked
}
