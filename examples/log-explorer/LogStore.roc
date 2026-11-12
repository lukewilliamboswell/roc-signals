import pf.Engine exposing [File]
import pf.Worker
import Log

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
			}.Engine.Cells.with_reset(|cells, reset| { page: cells.page, first: cells.first, reset }),
			generating: Engine.cell(Idle),
			note: Engine.cell(NoNote),
		}.Engine.Cells,
	)

	## The handles on the store's cells.
	h = LogStore.store.handles()

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
	opened = |file| [LogStore.h.log.put(Chosen(file))].concat(LogStore.fresh)

	## What every new log starts from: the search and the viewer at its
	## beginning, and nothing to say.
	fresh : List(Engine.Write(_))
	fresh = [
		LogStore.h.place.reset,
		LogStore.h.note.put(NoNote),
	]

	## The log is closed, and its file let go.
	closed : List(Engine.Write(_))
	closed = [LogStore.h.log.put(NoLog)]

	## Ask for a sample of the entries typed, or say why not.
	sample_asked : Str -> List(Engine.Write(_))
	sample_asked = |typed| match U64.from_str(typed.trim()) {
		Ok(entries) if entries >= 1 and entries <= LogStore.most_entries => [LogStore.h.generating.put(Generating(entries)), LogStore.h.note.put(NoNote)]
		_ => [LogStore.h.note.put(NotACount)]
	}

	## The sample's task answered: its file opens, or the note says why
	## there is none.
	sample_written : Try(File, Worker.Error(Engine.FileError)) -> List(Engine.Write(_))
	sample_written = |answer| {
		ended = LogStore.h.generating.put(Idle)
		match answer {
			Ok(file) => [ended].concat(LogStore.opened(file))
			Err(problem) => [ended, LogStore.h.note.put(NotWritten(problem))]
		}
	}

	## Another tab is showing.
	turned_to : Tab -> List(Engine.Write(_))
	turned_to = |tab| [LogStore.h.tab.put(tab)]

	## The viewer, opened at a line (from 0).
	shown_at : U64 -> List(Engine.Write(_))
	shown_at = |line| [LogStore.h.tab.put(Viewer), LogStore.h.place.first.put(line)]

	## The viewer, opened at the time a click on the timeline reports: at
	## the first line of that bucket, or of the next one with entries. A
	## time the timeline cannot place, or a timeline not yet answered,
	## changes nothing.
	timeline_clicked : Try(Log.Overview, [NoAnswer]), Str -> List(Engine.Write(_))
	timeline_clicked = |answered, clicked|
		match (answered, Log.minute_of(clicked.to_utf8())) {
			(Ok(overview), Ok(minute)) =>
				match Log.first_line_from(overview.timeline, minute) {
					Ok(line) => LogStore.shown_at(line)
					Err(NoLaterEntry) => []
				}
			_ => []
		}

	## The search's text as typed: a new search starts from its first page.
	searched : Str -> List(Engine.Write(_))
	searched = |text| [LogStore.h.query.change(|query| { ..query, text }), LogStore.h.place.page.put(0)]

	## The level the search keeps, by the name the menu sends; any other
	## name keeps every level. A new search starts from its first page.
	filtered : Str -> List(Engine.Write(_))
	filtered = |name| {
		filter = match Log.levels.find_first(|level| Log.level_name(level) == name) {
			Ok(level) => Only(level)
			Err(_) => Everything
		}
		[LogStore.h.query.change(|query| { ..query, filter }), LogStore.h.place.page.put(0)]
	}

	## The search's page before this one, or the first.
	paged_back : List(Engine.Write(_))
	paged_back = [LogStore.h.place.page.change(|page| if (page > 0) page - 1 else 0)]

	## The search's next page, when what it found has one.
	paged_on : Try(Log.Found, [NoAnswer]) -> List(Engine.Write(_))
	paged_on = |answered| match answered {
		Ok(found) => [LogStore.h.place.page.change(|page| if ((page + 1) * Log.page_lines < found.matches) page + 1 else page)]
		Err(NoAnswer) => []
	}

	## The viewer moved to a line (from 0), when there is one to move to.
	moved_to : Try(U64, [NoAnswer]) -> List(Engine.Write(_))
	moved_to = |line| match line {
		Ok(first) => [LogStore.h.place.first.put(first)]
		Err(NoAnswer) => []
	}

	## The viewer sent to the line typed (from 1); anything else is ignored.
	went_to : Str -> List(Engine.Write(_))
	went_to = |typed| match U64.from_str(typed.trim()) {
		Ok(line) if line >= 1 => [LogStore.h.place.first.put(line - 1)]
		_ => []
	}
}

## Where a store's reader is: the tab, the search's page and the viewer's
## first line.
place_in : Engine.Store(_, _) -> Str
place_in = |store| "${Str.inspect(store.read(LogStore.h.tab))} page ${store.read(LogStore.h.place.page).to_str()} line ${store.read(LogStore.h.place.first).to_str()}"

## A new log starts the search and the viewer from its beginning and says
## nothing, whatever the last one left. An `expect` cannot make a file, so
## this reaches `opened` through the writes every new log starts from.
expect {
	left = LogStore.store
		.after(LogStore.sample_asked("none"))
		.after(LogStore.searched("reset"))
		.after(LogStore.paged_on(Ok({ matches: 200, lines: [], over_time: NotCounted })))
		.after(LogStore.shown_at(41))
	begun = left.after(LogStore.fresh)
	actual =
		\\left: ${place_in(left)}, ${Str.inspect(left.read(LogStore.h.note))}
		\\begun: ${place_in(begun)}, ${Str.inspect(begun.read(LogStore.h.note))}, "${begun.read(LogStore.h.query).text}"
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
	generating_in = |store| Str.inspect(store.read(LogStore.h.generating))
	none = LogStore.store.after(LogStore.sample_asked("0"))
	many = LogStore.store.after(LogStore.sample_asked(" 3000 "))
	lost = many.after(LogStore.sample_written(Err(Timeout)))
	actual =
		\\none: ${generating_in(none)} ${Str.inspect(none.read(LogStore.h.note))}
		\\many: ${generating_in(many)} ${Str.inspect(many.read(LogStore.h.note))}
		\\too many: ${generating_in(LogStore.store.after(LogStore.sample_asked("2000001")))}
		\\lost: ${generating_in(lost)} ${Str.inspect(lost.read(LogStore.h.note))}
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
	page_in = |store| store.read(LogStore.h.place.page).to_str()
	second = LogStore.store.after(LogStore.paged_on(found))
	third = second.after(LogStore.paged_on(found))
	back = third.after(LogStore.paged_back).after(LogStore.paged_back)
	levelled = second.after(LogStore.filtered("ERROR"))
	actual =
		\\pages: ${page_in(second)} ${page_in(third)} ${page_in(back)} ${page_in(LogStore.store.after(LogStore.paged_on(Err(NoAnswer))))}
		\\typed: ${page_in(second.after(LogStore.searched("pool")))}
		\\levelled: ${page_in(levelled)} ${Str.inspect(levelled.read(LogStore.h.query).filter)} ${Str.inspect(levelled.after(LogStore.filtered("any")).read(LogStore.h.query).filter)}
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
	clicked = |time| place_in(LogStore.store.after(LogStore.timeline_clicked(Ok(overview), time)))
	actual =
		\\that minute: ${clicked("2026-11-11 12:00")}
		\\the next with entries: ${clicked("2026-11-11 12:01")}
		\\after the last: ${clicked("2026-11-11 13:00")}
		\\not a time: ${clicked("soon")}
		\\unanswered: ${place_in(LogStore.store.after(LogStore.timeline_clicked(Err(NoAnswer), "2026-11-11 12:03")))}
		\\typed: ${place_in(LogStore.store.after(LogStore.went_to("7")))}, ${place_in(LogStore.store.after(LogStore.went_to("0")))}
	expected =
		\\that minute: Viewer page 0 line 0
		\\the next with entries: Viewer page 0 line 2
		\\after the last: Overview page 0 line 0
		\\not a time: Overview page 0 line 0
		\\unanswered: Overview page 0 line 0
		\\typed: Overview page 0 line 6, Overview page 0 line 0
	actual == expected
}
