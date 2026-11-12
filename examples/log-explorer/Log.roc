## The pure half of the Log Explorer: reading the header of a log line,
## indexing a log a chunk at a time, and answering questions from the index
## and the bytes of the lines a question needs.
##
## A log here is UTF-8 text, one entry per line, each entry starting with an
## ISO 8601 timestamp, a level and a source:
##
##     2026-11-11T08:00:00.120Z INFO  api: GET /orders/1042 answered 200
##
## A line that does not start that way continues the entry before it (a
## stack trace, say). The index keeps where each line starts and what it is,
## never the text, so a question that shows lines reads just their bytes.
## It also keeps a timeline: entries counted by level for each minute of the
## time the log spans, or for each longer stretch when the log spans more
## than `most_buckets` minutes, so its size has a bound however long the
## log runs.
Log := [].{

	## How severe an entry is, from its level word.
	Level : [Trace, Debug, Info, Warn, Error, Fatal]

	## What a line is: the first line of an entry, a line continuing the
	## entry before it, or a line before the first entry.
	Mark : [Entry(Level), Continued(Level), Unheaded]

	## Entries counted by level.
	Tally : { trace : U64, debug : U64, info : U64, warn : U64, error : U64, fatal : U64 }

	## One stretch of the timeline: its entries counted by level, and the
	## first line (from 0) of an entry in it.
	Bucket : { tally : Tally, first : [NoEntry, Line(U64)] }

	## Entries over time, a bucket for each `width` minutes. Bucket `n`
	## counts the entries whose minute `m` (counted as `minute_of` counts)
	## has `m // width == start + n`. `width` is the narrowest of the
	## `widths` that keeps the buckets from the earliest entry's to the
	## latest's within `most_buckets`: one minute for a log of a day, half
	## an hour for a month, six hours for a year.
	Timeline : { width : U64, start : U64, buckets : List(Bucket) }

	## What indexing a log keeps: the file's size, where each line starts and
	## what it is, and the counts the overview shows. Line `n` (from 0) is
	## the bytes from `starts[n]` to the next line's start, or to the end.
	## `undated` counts the entries whose timestamp is not a real UTC time
	## (a 31 June, a 25th hour), which the timeline leaves out.
	Index : {
		size : U64,
		starts : List(U64),
		marks : List(Mark),
		entries : U64,
		tally : Tally,
		earliest : Str,
		latest : Str,
		sources : Dict(Str, U64),
		timeline : Timeline,
		undated : U64,
	}

	## An index being built a chunk at a time: the index of the lines seen
	## whole, the offset of the next byte, and the line the last chunk ended
	## in, with its first bytes (at most `header_bytes` of them, so a line
	## with no break in it costs no memory).
	Indexer : { index : Index, at : U64, line : [Between, Open({ start : U64, head : List(U8) })] }

	## One line, as a question answers it: its number (from 1), what it is
	## and its text (at most `line_bytes` of it).
	Line : { number : U64, mark : Mark, text : Str }

	## Which lines a search looks at.
	Filter : [Everything, Only(Level)]

	## A search: lines whose text holds `text` (ignoring ASCII case; every
	## line when it is empty) among those `filter` lets through, and which
	## page of them to show.
	Search : { text : Str, filter : Filter, page : U64 }

	## A search's answer: how many lines match, the lines of the page asked
	## for, and, for a search with text, how many matched in each bucket of
	## the log's timeline. A listing with no text counts nothing over time:
	## the timeline's own lines show it.
	Found : { matches : U64, lines : List(Line), over_time : [NotCounted, Counted(List(U64))] }

	## A search with text, over the lines scanned so far: how many matched,
	## those of them on the page asked for, how many in each bucket of the
	## timeline, and the bucket of the last entry scanned, which the lines
	## continuing it share.
	Scan : { matches : U64, lines : List(Line), per_bucket : List(U64), entry : [Undated, Bucket(U64)] }

	## A page of the viewer: its first line (from 0), the log's line count
	## and the lines.
	Window : { first : U64, total : U64, lines : List(Line) }

	## What the overview shows.
	Overview : {
		size : U64,
		lines : U64,
		entries : U64,
		tally : Tally,
		span : [Untimed, Between({ earliest : Str, latest : Str })],
		sources : List({ source : Str, entries : U64 }),
		distinct_sources : U64,
		timeline : Timeline,
		undated : U64,
	}

	## How many lines a page of search results holds.
	page_lines : U64
	page_lines = 25

	## How many lines a page of the viewer holds.
	window_lines : U64
	window_lines = 50

	## How much of a line's start the header is looked for in.
	header_bytes : U64
	header_bytes = 128

	## How much of a line a question shows.
	line_bytes : U64
	line_bytes = 1000

	## The most buckets a timeline has: a day at one a minute (1,440, and
	## one more for a log that ends where it began), a month at one each
	## half hour (at most 1,488) and a year at one each six hours (at most
	## 1,464). Each costs the index about 64 bytes, so a timeline costs at
	## most about 96 KB however long the log runs, where counting every
	## minute would cost 2.8 MB for a month and 34 MB for a year, and draw
	## more points than a chart should.
	most_buckets : U64
	most_buckets = 1500

	## The widths a timeline's buckets may have, in minutes, narrowest
	## first: each divides the next, so widening a timeline merges whole
	## buckets. Past the last, a width doubles.
	widths : List(U64)
	widths = [1, 5, 15, 30, 60, 180, 360, 720, 1440, 10080]

	## A timeline with no entries, a minute a bucket.
	no_timeline : Timeline
	no_timeline = { width: 1, start: 0, buckets: [] }

	## The minute a timestamp names, counted from a fixed day long before
	## year 1: `YYYY-MM-DD`, then `T` or a space and `hh:mm`, then anything
	## (seconds, a fraction, a zone, none of which is read: a minute is the
	## one the log writes). A date alone is its midnight. Only a real
	## Gregorian date and time of day, in years 1 to 9999, has a minute.
	minute_of : List(U8) -> Try(U64, [NotATime])
	minute_of = |bytes| {
		# Read in place, with no list made: every search reads the minute
		# of every entry it passes.
		number = |{ start, len }| {
			var $n = 0
			var $i = start
			while $i < start + len {
				match bytes.get($i) {
					Ok(b) if b >= '0' and b <= '9' => {
						$n = $n * 10 + (b - '0').to_u64()
					}
					_ => return Err(NotATime)
				}
				$i = $i + 1
			}
			Ok($n)
		}
		if bytes.get(4) != Ok('-') or bytes.get(7) != Ok('-') {
			return Err(NotATime)
		}
		date = { year: number({ start: 0, len: 4 })?, month: number({ start: 5, len: 2 })?, day: number({ start: 8, len: 2 })? }
		if bytes.len() == 10 {
			return Log.minute_at({ year: date.year, month: date.month, day: date.day, hour: 0, minute: 0 })
		}
		separated = match bytes.get(10) {
			Ok(b) => (b == 'T' or b == ' ') and bytes.get(13) == Ok(':')
			Err(OutOfBounds) => Bool.False
		}
		if !separated {
			return Err(NotATime)
		}
		Log.minute_at({ year: date.year, month: date.month, day: date.day, hour: number({ start: 11, len: 2 })?, minute: number({ start: 14, len: 2 })? })
	}

	## The minute of a date and time of day, counted as `minute_of` counts,
	## when the date is a real one in years 1 to 9999 and the time a real
	## time of day.
	minute_at : { year : U64, month : U64, day : U64, hour : U64, minute : U64 } -> Try(U64, [NotATime])
	minute_at = |{ year, month, day, hour, minute }|
		if year < 1 or month < 1 or month > 12 or day < 1 or day > days_in_month({ year, month }) or hour > 23 or minute > 59 {
			Err(NotATime)
		} else {
			Ok(days_from_civil({ year, month, day }) * 1440 + hour * 60 + minute)
		}

	## The minute of 1970-01-01T00:00, from which Unix and JavaScript count.
	epoch_minute : U64
	epoch_minute = days_from_civil({ year: 1970, month: 1, day: 1 }) * 1440

	## The timeline with one more entry, of `level`, at `minute`, on line
	## `line` (from 0). A minute beyond the buckets' bound widens them first.
	placed : Timeline, { minute : U64, level : Level, line : U64 } -> Timeline
	placed = |timeline, { minute, level, line }| {
		{ width, start, buckets } = timeline
		at = minute // width
		if buckets.is_empty() {
			return { width, start: at, buckets: [{ tally: counted(no_tally, level), first: Line(line) }] }
		}
		low = start.min(at)
		high = (start + buckets.len() - 1).max(at)
		if high - low + 1 > Log.most_buckets {
			return Log.placed(widened(timeline), { minute, level, line })
		}
		grown =
			if at < start {
				List.repeat(empty_bucket, start - at).concat(buckets)
			} else if at >= start + buckets.len() {
				buckets.concat(List.repeat(empty_bucket, at + 1 - start - buckets.len()))
			} else {
				buckets
			}
		counted_in = grown.update(at - low, |bucket| { tally: counted(bucket.tally, level), first: earlier(bucket.first, Line(line)) }) ?? crash "Log.placed: bucket ${(at - low).to_str()} is past the grown timeline"
		{ width, start: low, buckets: counted_in }
	}

	## The bucket (from 0) of a timeline that a minute falls in, when it
	## falls in one.
	bucket_of : Timeline, U64 -> Try(U64, [OutsideTheTimeline])
	bucket_of = |{ width, start, buckets }, minute| {
		at = minute // width
		if (at >= start and at - start < buckets.len()) Ok(at - start) else Err(OutsideTheTimeline)
	}

	## The first line (from 0) of an entry in the bucket a minute falls in,
	## or in the nearest later bucket that has one: where the viewer shows
	## that time from.
	first_line_from : Timeline, U64 -> Try(U64, [NoLaterEntry])
	first_line_from = |timeline, minute| {
		from = if (minute // timeline.width < timeline.start) 0 else Log.bucket_of(timeline, minute) ?? timeline.buckets.len()
		for bucket in timeline.buckets.drop_first(from) {
			match bucket.first {
				Line(line) => return Ok(line)
				NoEntry => {}
			}
		}
		Err(NoLaterEntry)
	}

	## An indexer that has seen nothing.
	indexer : Indexer
	indexer = {
		index: {
			size: 0,
			starts: [],
			marks: [],
			entries: 0,
			tally: { trace: 0, debug: 0, info: 0, warn: 0, error: 0, fatal: 0 },
			earliest: "",
			latest: "",
			sources: Dict.empty(),
			timeline: Log.no_timeline,
			undated: 0,
		},
		at: 0,
		line: Between,
	}

	## Index the next chunk of the log. A line split between two chunks is
	## recorded once its break arrives.
	feed : Indexer, List(U8) -> Indexer
	feed = |{ index, at, line }, chunk| {
		var $index = index
		var $line = line
		var $from = 0
		var $i = 0
		for b in chunk {
			if b == '\n' {
				$index = match $line {
					Open({ start, head }) => recorded($index, start, grown(head, chunk, { start: $from, end: $i }))
					Between => recorded($index, at + $from, grown([], chunk, { start: $from, end: $i }))
				}
				$line = Between
				$from = $i + 1
			}
			$i = $i + 1
		}
		if $from < chunk.len() {
			$line = match $line {
				Open({ start, head }) => Open({ start, head: grown(head, chunk, { start: $from, end: chunk.len() }) })
				Between => Open({ start: at + $from, head: grown([], chunk, { start: $from, end: chunk.len() }) })
			}
		}
		{ index: $index, at: at + chunk.len(), line: $line }
	}

	## The index of everything fed, the last line included when no break
	## ends it.
	finish : Indexer -> Index
	finish = |{ index, at, line }| {
		whole = match line {
			Open({ start, head }) => recorded(index, start, head)
			Between => index
		}
		{ ..whole, size: at }
	}

	## The timestamp, level and source a line starts with, when it starts
	## with a timestamp and a level word (`TRACE`, `DEBUG`, `INFO`, `WARN`,
	## `WARNING`, `ERROR` or `FATAL`, in any case, bracketed or not). The
	## source is the next word, without a trailing colon or brackets, or
	## `-` when there is none.
	header : List(U8) -> [Headed({ time : List(U8), level : Level, source : Str }), Plain]
	header = |bytes| {
		time_end = word_end(bytes, 0)
		time = bytes.sublist({ start: 0, len: time_end })
		if !is_timestamp(time) {
			return Plain
		}
		level_start = spaces_end(bytes, time_end)
		level_end = word_end(bytes, level_start)
		match level_of(bytes.sublist({ start: level_start, len: level_end - level_start })) {
			Ok(level) => {
				source_start = spaces_end(bytes, level_end)
				source = bracketless(bytes.sublist({ start: source_start, len: word_end(bytes, source_start) - source_start }))
				Headed({ time, level, source: if (source.is_empty()) "-" else Str.from_utf8_lossy(source) })
			}
			Err(NotALevel) => Plain
		}
	}

	## The overview of an index: its counts, the time its entries span
	## and its five busiest sources.
	overview : Index -> Overview
	overview = |index| {
		busiest = index.sources
			.to_list()
			.map(|(source, entries)| { source, entries })
			.sort_with(|a, b| if (a.entries > b.entries) Before else if (a.entries < b.entries) After else order(a.source.to_utf8(), b.source.to_utf8()))
		{
			size: index.size,
			lines: index.starts.len(),
			entries: index.entries,
			tally: index.tally,
			span: if (index.entries == 0) Untimed else Between({ earliest: index.earliest, latest: index.latest }),
			sources: busiest.take_first(5),
			distinct_sources: index.sources.len(),
			timeline: index.timeline,
			undated: index.undated,
		}
	}

	## The bytes lines `first` to `first + count - 1` (from 0) cover.
	span : Index, { first : U64, count : U64 } -> { start : U64, len : U64 }
	span = |index, { first, count }| {
		start = index.starts.get(first) ?? index.size
		end = index.starts.get(first + count) ?? index.size
		{ start, len: end - start }
	}

	## Lines `first` to `first + count - 1` (from 0), from `bytes`, which
	## are the bytes of their `span`.
	lines_in : Index, { first : U64, count : U64, bytes : List(U8) } -> List(Line)
	lines_in = |index, { first, count, bytes }| {
		base = index.starts.get(first) ?? index.size
		var $lines = List.with_capacity(count)
		var $n = first
		while $n < first + count {
			{ start, len } = Log.span(index, { first: $n, count: 1 })
			$lines = $lines.append({ number: $n + 1, mark: mark_of(index, $n), text: text_of(bytes.sublist({ start: start - base, len })) })
			$n = $n + 1
		}
		$lines
	}

	## Ranges of whole lines that cover every line in order, each at most
	## `bytes` long unless one line alone is longer.
	chunks : Index, U64 -> List({ first : U64, count : U64 })
	chunks = |index, bytes| {
		lines = index.starts.len()
		var $out = []
		var $first = 0
		var $n = 0
		while $n < lines {
			{ len, .. } = Log.span(index, { first: $first, count: $n - $first + 1 })
			if len > bytes and $n > $first {
				$out = $out.append({ first: $first, count: $n - $first })
				$first = $n
			} else {
				$n = $n + 1
			}
		}
		if $first < lines {
			$out = $out.append({ first: $first, count: lines - $first })
		}
		$out
	}

	## Whether a line with this mark is one a filter lets through. Lines
	## before the first entry have no level, so only `Everything` shows them.
	is_shown : Mark, Filter -> Bool
	is_shown = |mark, filter| match (mark, filter) {
		(_, Everything) => Bool.True
		(Entry(level), Only(wanted)) => level == wanted
		(Continued(level), Only(wanted)) => level == wanted
		(Unheaded, Only(_)) => Bool.False
	}

	## A search with no text, answered from the index alone: how many lines
	## the filter lets through, and the numbers (from 0) of those on the
	## page asked for.
	listed : Index, Search -> { matches : U64, page : List(U64) }
	listed = |index, search| {
		from = search.page * Log.page_lines
		var $matches = 0
		var $page = []
		var $n = 0
		for mark in index.marks {
			if Log.is_shown(mark, search.filter) {
				if $matches >= from and $matches < from + Log.page_lines {
					$page = $page.append($n)
				}
				$matches = $matches + 1
			}
			$n = $n + 1
		}
		{ matches: $matches, page: $page }
	}

	## A search with text that has scanned nothing of an index yet.
	unscanned : Index -> Scan
	unscanned = |index| { matches: 0, lines: [], per_bucket: List.repeat(0, index.timeline.buckets.len()), entry: Undated }

	## A search with text, continued over the next range of lines and the
	## bytes of their span. A match is counted in its entry's bucket, which
	## the entry's own line gives: the index keeps no time for a line.
	scan : Scan, { index : Index, search : Search, first : U64, count : U64, bytes : List(U8) } -> Scan
	scan = |scanned, { index, search, first, count, bytes }| {
		needle = search.text.to_utf8().map(folded)
		from = search.page * Log.page_lines
		base = index.starts.get(first) ?? index.size
		var $matches = scanned.matches
		var $lines = scanned.lines
		var $per_bucket = scanned.per_bucket
		var $entry = scanned.entry
		var $n = first
		while $n < first + count {
			mark = mark_of(index, $n)
			if Log.is_shown(mark, search.filter) {
				{ start, len } = Log.span(index, { first: $n, count: 1 })
				line = bytes.sublist({ start: start - base, len })
				$entry = match mark {
					Entry(_) =>
						match Log.minute_of(line.take_first(16)) {
							Ok(minute) => Log.bucket_of(index.timeline, minute).map_ok(|at| Bucket(at)) ?? Undated
							Err(NotATime) => Undated
						}
					_ => $entry
				}
				if has_folded(line, needle) {
					if $matches >= from and $matches < from + Log.page_lines {
						$lines = $lines.append({ number: $n + 1, mark, text: text_of(line) })
					}
					$matches = $matches + 1
					$per_bucket = match $entry {
						Bucket(at) => $per_bucket.update(at, |n| n + 1) ?? crash "Log.scan: bucket ${at.to_str()} is past the timeline"
						Undated => $per_bucket
					}
				}
			}
			$n = $n + 1
		}
		{ matches: $matches, lines: $lines, per_bucket: $per_bucket, entry: $entry }
	}

	## The first line (from 0) of the viewer's page that is `wanted` in a
	## log of `lines` lines: no further than the last full page's.
	window_first : { lines : U64, wanted : U64 } -> U64
	window_first = |{ lines, wanted }| {
		last = if (lines > Log.window_lines) lines - Log.window_lines else 0
		if (wanted > last) last else wanted
	}

	## A level's word, as the log writes it.
	level_name : Level -> Str
	level_name = |level| match level {
		Trace => "TRACE"
		Debug => "DEBUG"
		Info => "INFO"
		Warn => "WARN"
		Error => "ERROR"
		Fatal => "FATAL"
	}

	## Every level, least severe first.
	levels : List(Level)
	levels = [Trace, Debug, Info, Warn, Error, Fatal]

	## How many entries of a level a tally counts.
	tally_of : Tally, Level -> U64
	tally_of = |tally, level| match level {
		Trace => tally.trace
		Debug => tally.debug
		Info => tally.info
		Warn => tally.warn
		Error => tally.error
		Fatal => tally.fatal
	}
}

## The index with one more line, starting at `start`, whose first bytes are
## `head`. Its fields are taken apart first so each list is appended in
## place.
recorded : Log.Index, U64, List(U8) -> Log.Index
recorded = |index, start, head| {
	{ size, starts, marks, entries, tally, earliest, latest, sources, timeline, undated } = index
	match Log.header(head) {
		Headed({ time, level, source }) => {
			seen = sources.get(source) ?? 0
			first = entries == 0
			dated = match Log.minute_of(time) {
				Ok(minute) => Placed(Log.placed(timeline, { minute, level, line: starts.len() }))
				Err(NotATime) => Undated
			}
			{
				timeline: match dated {
					Placed(placed) => placed
					Undated => timeline
				},
				undated: match dated {
					Placed(_) => undated
					Undated => undated + 1
				},
				size,
				starts: starts.append(start),
				marks: marks.append(Entry(level)),
				entries: entries + 1,
				tally: counted(tally, level),
				earliest: if (first or order(time, earliest.to_utf8()) == Before) Str.from_utf8_lossy(time) else earliest,
				latest: if (first or order(time, latest.to_utf8()) == After) Str.from_utf8_lossy(time) else latest,
				sources: sources.insert(source, seen + 1),
			}
		}
		Plain => {
			mark = match marks.last() {
				Ok(Entry(level)) => Continued(level)
				Ok(Continued(level)) => Continued(level)
				Ok(Unheaded) => Unheaded
				Err(ListWasEmpty) => Unheaded
			}
			{ size, starts: starts.append(start), marks: marks.append(mark), entries, tally, earliest, latest, sources, timeline, undated }
		}
	}
}

no_tally : Log.Tally
no_tally = { trace: 0, debug: 0, info: 0, warn: 0, error: 0, fatal: 0 }

empty_bucket : Log.Bucket
empty_bucket = { tally: no_tally, first: NoEntry }

## A timeline with buckets of the next width (the next of `widths`, or
## twice the last past them): each new bucket merges the old ones it
## covers, adding their counts and keeping their first line.
widened : Log.Timeline -> Log.Timeline
widened = |{ width, start, buckets }| {
	next = Log.widths.find_first(|w| w > width) ?? width * 2
	factor = next // width
	low = start // factor
	var $merged = []
	var $at = start
	for bucket in buckets {
		slot = $at // factor - low
		$merged = if slot < $merged.len() {
			$merged.update(slot, |into| { tally: added(into.tally, bucket.tally), first: earlier(into.first, bucket.first) }) ?? crash "Log.widened: slot ${slot.to_str()} is past the merged buckets"
		} else {
			$merged.append(bucket)
		}
		$at = $at + 1
	}
	{ width: next, start: low, buckets: $merged }
}

## Two tallies added.
added : Log.Tally, Log.Tally -> Log.Tally
added = |a, b| { trace: a.trace + b.trace, debug: a.debug + b.debug, info: a.info + b.info, warn: a.warn + b.warn, error: a.error + b.error, fatal: a.fatal + b.fatal }

## The earlier of two first lines.
earlier : [NoEntry, Line(U64)], [NoEntry, Line(U64)] -> [NoEntry, Line(U64)]
earlier = |a, b| match (a, b) {
	(Line(x), Line(y)) => Line(x.min(y))
	(Line(x), NoEntry) => Line(x)
	(NoEntry, other) => other
}

## Days in a month of a year, by the Gregorian calendar.
days_in_month : { year : U64, month : U64 } -> U64
days_in_month = |{ year, month }| match month {
	2 => if (year % 4 == 0 and (year % 100 != 0 or year % 400 == 0)) 29 else 28
	4 | 6 | 9 | 11 => 30
	_ => 31
}

## Days from a fixed day before year 1 to a date: Howard Hinnant's
## `days_from_civil`, with years shifted by 400 so nothing is negative.
days_from_civil : { year : U64, month : U64, day : U64 } -> U64
days_from_civil = |{ year, month, day }| {
	shifted = if (month <= 2) year + 399 else year + 400
	era = shifted // 400
	year_of_era = shifted - era * 400
	day_of_year = (153 * (if (month > 2) month - 3 else month + 9) + 2) // 5 + day - 1
	era * 146097 + year_of_era * 365 + year_of_era // 4 - year_of_era // 100 + day_of_year
}

## A tally with one more entry of `level`.
counted : Log.Tally, Log.Level -> Log.Tally
counted = |tally, level| match level {
	Trace => { ..tally, trace: tally.trace + 1 }
	Debug => { ..tally, debug: tally.debug + 1 }
	Info => { ..tally, info: tally.info + 1 }
	Warn => { ..tally, warn: tally.warn + 1 }
	Error => { ..tally, error: tally.error + 1 }
	Fatal => { ..tally, fatal: tally.fatal + 1 }
}

## `head` followed by the bytes of `chunk` from `start` to `end`, as far as
## a header can reach.
grown : List(U8), List(U8), { start : U64, end : U64 } -> List(U8)
grown = |head, chunk, { start, end }| {
	room = if (head.len() >= Log.header_bytes) 0 else Log.header_bytes - head.len()
	len = (end - start).min(room)
	if (len == 0) head else head.concat(chunk.sublist({ start, len }))
}

## A line's mark, which the index has for every line it counts.
mark_of : Log.Index, U64 -> Log.Mark
mark_of = |index, n| match index.marks.get(n) {
	Ok(mark) => mark
	Err(OutOfBounds) => crash "Log.mark_of: line ${n.to_str()} is past the index's ${index.marks.len().to_str()} lines"
}

## A line's text: without its break, at most `line_bytes` of it.
text_of : List(U8) -> Str
text_of = |bytes| {
	unbroken = if (bytes.last() == Ok('\n')) bytes.drop_last(1) else bytes
	line = if (unbroken.last() == Ok('\r')) unbroken.drop_last(1) else unbroken
	if line.len() > Log.line_bytes {
		"${Str.from_utf8_lossy(line.take_first(Log.line_bytes))}…"
	} else {
		Str.from_utf8_lossy(line)
	}
}

## Where the word starting at `from` ends: the next space, tab or carriage
## return, or the end.
word_end : List(U8), U64 -> U64
word_end = |bytes, from| {
	var $i = from
	while $i < bytes.len() and !is_space(bytes.get($i) ?? ' ') {
		$i = $i + 1
	}
	$i
}

## Where the spaces starting at `from` end.
spaces_end : List(U8), U64 -> U64
spaces_end = |bytes, from| {
	var $i = from
	while $i < bytes.len() and is_space(bytes.get($i) ?? 'x') {
		$i = $i + 1
	}
	$i
}

is_space : U8 -> Bool
is_space = |b| b == ' ' or b == '\t' or b == '\r'

## Whether a word is an ISO 8601 timestamp: `YYYY-MM-DDTHH:MM:SS`, then
## anything (a fraction, a zone).
is_timestamp : List(U8) -> Bool
is_timestamp = |word| {
	shape = "dddd-dd-ddTdd:dd:dd".to_utf8()
	if word.len() < shape.len() {
		Bool.False
	} else {
		List.map2(shape, word.take_first(shape.len()), |want, b| if (want == 'd') b >= '0' and b <= '9' else b == want).all(|ok| ok)
	}
}

## The level a word names.
level_of : List(U8) -> Try(Log.Level, [NotALevel])
level_of = |word| match Str.from_utf8_lossy(bracketless(word).map(upper)) {
	"TRACE" => Ok(Trace)
	"DEBUG" => Ok(Debug)
	"INFO" => Ok(Info)
	"WARN" => Ok(Warn)
	"WARNING" => Ok(Warn)
	"ERROR" => Ok(Error)
	"FATAL" => Ok(Fatal)
	_ => Err(NotALevel)
}

## A word without a trailing colon, and without surrounding brackets.
bracketless : List(U8) -> List(U8)
bracketless = |word| {
	uncoloned = if (word.last() == Ok(':')) word.drop_last(1) else word
	unclosed = if (uncoloned.last() == Ok(']')) uncoloned.drop_last(1) else uncoloned
	if (unclosed.first() == Ok('[')) unclosed.drop_first(1) else unclosed
}

upper : U8 -> U8
upper = |b| if (b >= 'a' and b <= 'z') b - 32 else b

folded : U8 -> U8
folded = |b| if (b >= 'A' and b <= 'Z') b + 32 else b

## Whether `hay` holds `needle` (already lower-cased), ignoring ASCII case.
has_folded : List(U8), List(U8) -> Bool
has_folded = |hay, needle| {
	if needle.len() > hay.len() {
		return Bool.False
	}
	last = hay.len() - needle.len()
	var $at = 0
	while $at <= last {
		var $k = 0
		while $k < needle.len() and folded(hay.get($at + $k) ?? 0) == (needle.get($k) ?? 0) {
			$k = $k + 1
		}
		if $k == needle.len() {
			return Bool.True
		}
		$at = $at + 1
	}
	Bool.False
}

## Byte order of two words.
order : List(U8), List(U8) -> [Before, Same, After]
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

## A log's text, indexed in chunks of `size` bytes.
indexed : Str, U64 -> Log.Index
indexed = |text, size| {
	bytes = text.to_utf8()
	var $ix = Log.indexer
	var $at = 0
	while $at < bytes.len() {
		$ix = Log.feed($ix, bytes.sublist({ start: $at, len: size }))
		$at = $at + size
	}
	Log.finish($ix)
}

sample : Str
sample =
	\\2026-11-11T08:00:00.120Z INFO  api: GET /orders/1042 answered 200
	\\2026-11-11T08:00:01.004Z ERROR db: connection reset by peer
	\\    at Pool.acquire (pool.roc:88)
	\\2026-11-11T07:59:59.000Z [warn] [cache] miss for user:7
	\\not a header
	\\

## A header gives the time, the level and the source; other lines are
## plain.
expect {
	shown = |line| match Log.header(line.to_utf8()) {
		Headed({ time, level, source }) => "${Str.from_utf8_lossy(time)} ${Log.level_name(level)} ${source}"
		Plain => "plain"
	}
	actual =
		\\info: ${shown("2026-11-11T08:00:00.120Z INFO  api: GET /")}
		\\bracketed: ${shown("2026-11-11T08:00:00Z [Warning] [cache] miss")}
		\\no source: ${shown("2026-11-11T08:00:00Z debug")}
		\\no level: ${shown("2026-11-11T08:00:00Z hello there")}
		\\no time: ${shown("INFO api: hello")}
		\\short time: ${shown("2026-11-11T08:00 INFO api")}
		\\empty: ${shown("")}
	expected =
		\\info: 2026-11-11T08:00:00.120Z INFO api
		\\bracketed: 2026-11-11T08:00:00Z WARN cache
		\\no source: 2026-11-11T08:00:00Z DEBUG -
		\\no level: plain
		\\no time: plain
		\\short time: plain
		\\empty: plain
	actual == expected
}

## Indexing finds every line, marks continuations with their entry's level,
## and keeps the counts, the earliest and latest times and the sources.
expect {
	index = indexed(sample, 1000)
	view = Log.overview(index)
	{ width, start, buckets } = view.timeline
	actual =
		\\starts: ${Str.inspect(index.starts)}
		\\marks: ${Str.inspect(index.marks)}
		\\overview: ${Str.inspect({ ..view, timeline: Log.no_timeline })}
		\\timeline: ${Str.inspect({ width, starts_at_07_59: Ok(start) == Log.minute_of("2026-11-11T07:59".to_utf8()), buckets })}
	expected =
		\\starts: [0, 66, 126, 160, 216]
		\\marks: [Entry(Info), Entry(Error), Continued(Error), Entry(Warn), Continued(Warn)]
		\\overview: { distinct_sources: 3, entries: 3, lines: 5, size: 229, sources: [{ entries: 1, source: "api" }, { entries: 1, source: "cache" }, { entries: 1, source: "db" }], span: Between({ earliest: "2026-11-11T07:59:59.000Z", latest: "2026-11-11T08:00:01.004Z" }), tally: { debug: 0, error: 1, fatal: 0, info: 1, trace: 0, warn: 1 }, timeline: { buckets: [], start: 0, width: 1 }, undated: 0 }
		\\timeline: { buckets: [{ first: Line(3), tally: { debug: 0, error: 0, fatal: 0, info: 0, trace: 0, warn: 1 } }, { first: Line(0), tally: { debug: 0, error: 1, fatal: 0, info: 1, trace: 0, warn: 0 } }], starts_at_07_59: True, width: 1 }
	actual == expected
}

## Any chunk size gives the same index, a line split between chunks
## included.
expect [1, 2, 3, 7, 64, 228, 229, 4096].all(|size| indexed(sample, size) == indexed(sample, 1000))

## A last line without a break is a line; an empty log has none.
expect {
	actual =
		\\unbroken: ${Str.inspect(indexed("a\nb", 1).starts)}
		\\empty: ${Str.inspect(indexed("", 1).starts)}
		\\blank lines: ${Str.inspect(indexed("\n\n", 1).starts)}
	expected =
		\\unbroken: [0, 2]
		\\empty: []
		\\blank lines: [0, 1]
	actual == expected
}

## A line longer than a chunk is one line, and only its start is kept to
## read its header.
expect {
	long = "2026-11-11T08:00:00Z FATAL kernel: ${Str.repeat("x", 500)}\nnext\n"
	index = indexed(long, 16)
	actual = "${Str.inspect(index.starts)} ${Str.inspect(index.marks)}"
	actual == "[0, 536] [Entry(Fatal), Continued(Fatal)]"
}

## The lines of a range come from the bytes of its span, without their
## breaks.
expect {
	index = indexed(sample, 1000)
	{ start, len } = Log.span(index, { first: 1, count: 2 })
	bytes = sample.to_utf8().sublist({ start, len })
	lines = Log.lines_in(index, { first: 1, count: 2, bytes })
	lines == [{ number: 2, mark: Entry(Error), text: "2026-11-11T08:00:01.004Z ERROR db: connection reset by peer" }, { number: 3, mark: Continued(Error), text: "    at Pool.acquire (pool.roc:88)" }]
}

## Chunks cover every line once, in order, within the bound unless a line
## is longer.
expect {
	index = indexed(sample, 1000)
	actual =
		\\60: ${Str.inspect(Log.chunks(index, 60))}
		\\100: ${Str.inspect(Log.chunks(index, 100))}
		\\all: ${Str.inspect(Log.chunks(index, 1000))}
	expected =
		\\60: [{ count: 1, first: 0 }, { count: 1, first: 1 }, { count: 1, first: 2 }, { count: 1, first: 3 }, { count: 1, first: 4 }]
		\\100: [{ count: 1, first: 0 }, { count: 2, first: 1 }, { count: 2, first: 3 }]
		\\all: [{ count: 5, first: 0 }]
	actual == expected
}

## A search ignores ASCII case and honours the filter; continuations go
## with their entry's level, and are counted in its minute; a search with
## no text lists from the index.
expect {
	index = indexed(sample, 1000)
	search = |text, filter| {
		found = Log.scan(Log.unscanned(index), { index, search: { text, filter, page: 0 }, first: 0, count: 5, bytes: sample.to_utf8() })
		"${found.matches.to_str()} ${Str.inspect(found.lines.map(|l| l.number))} by minute ${Str.inspect(found.per_bucket)}"
	}
	listed = |filter| Str.inspect(Log.listed(index, { text: "", filter, page: 0 }))
	actual =
		\\pool: ${search("POOL", Everything)}
		\\pool in errors: ${search("pool", Only(Error))}
		\\pool in warnings: ${search("pool", Only(Warn))}
		\\every 2026: ${search("2026", Everything)}
		\\errors: ${listed(Only(Error))}
		\\all: ${listed(Everything)}
	expected =
		\\pool: 1 [3] by minute [0, 1]
		\\pool in errors: 1 [3] by minute [0, 1]
		\\pool in warnings: 0 [] by minute [0, 0]
		\\every 2026: 3 [1, 2, 4] by minute [1, 2]
		\\errors: { matches: 2, page: [1, 2] }
		\\all: { matches: 5, page: [0, 1, 2, 3, 4] }
	actual == expected
}

## A minute is read from a timestamp's date, hour and minute, and only a
## real date and time of day has one; a date alone is its midnight.
expect {
	minute = |text| match Log.minute_of(text.to_utf8()) {
		Ok(m) => (m - Log.epoch_minute).to_str()
		Err(NotATime) => "not a time"
	}
	actual =
		\\epoch: ${minute("1970-01-01T00:00:00Z")}
		\\a day on: ${minute("1970-01-02 00:01")}
		\\leap day: ${minute("2024-02-29T12:00")}
		\\a date: ${minute("2026-11-11")}
		\\as written: ${minute("2026-11-11T08:00:59.999+10:00")}
		\\no leap day: ${minute("2025-02-29T12:00")}
		\\31 June: ${minute("2026-06-31T00:00")}
		\\hour 24: ${minute("2026-11-11T24:00")}
		\\year 0: ${minute("0000-01-01T00:00")}
		\\cut short: ${minute("2026-11-11T08")}
	expected =
		\\epoch: 0
		\\a day on: 1441
		\\leap day: 28486800
		\\a date: 29905920
		\\as written: 29906400
		\\no leap day: not a time
		\\31 June: not a time
		\\hour 24: not a time
		\\year 0: not a time
		\\cut short: not a time
	actual == expected
}

## A log that spans more minutes than a timeline holds widens its buckets,
## merging their counts and keeping each one's first line; a time the log
## shows from is the first line of its bucket or the next one with entries.
expect {
	at = |text| Log.minute_of(text.to_utf8()) ?? 0
	log =
		\\2026-11-11T08:00:00Z INFO api: a
		\\2026-11-11T08:03:00Z WARN api: b
		\\2026-11-13T08:00:00Z ERROR db: c
		\\2026-11-11T08:04:00Z INFO api: d
		\\2026-11-11T25:00:00Z INFO api: undated
		\\
	index = indexed(log, 7)
	{ width, start, buckets } = index.timeline
	actual =
		\\width: ${width.to_str()}, buckets: ${buckets.len().to_str()}, from: ${Str.inspect(start * width == at("2026-11-11T08:00"))}, undated: ${index.undated.to_str()}
		\\first: ${Str.inspect(buckets.first())}
		\\last: ${Str.inspect(buckets.last())}
		\\from 08:02: ${Str.inspect(Log.first_line_from(index.timeline, at("2026-11-11T08:02")))}
		\\from 08:07: ${Str.inspect(Log.first_line_from(index.timeline, at("2026-11-11T08:07")))}
		\\from before: ${Str.inspect(Log.first_line_from(index.timeline, at("2026-11-10T00:00")))}
		\\from after: ${Str.inspect(Log.first_line_from(index.timeline, at("2026-11-14T00:00")))}
	expected =
		\\width: 5, buckets: 577, from: True, undated: 1
		\\first: Ok({ first: Line(0), tally: { debug: 0, error: 0, fatal: 0, info: 2, trace: 0, warn: 1 } })
		\\last: Ok({ first: Line(2), tally: { debug: 0, error: 1, fatal: 0, info: 0, trace: 0, warn: 0 } })
		\\from 08:02: Ok(0)
		\\from 08:07: Ok(2)
		\\from before: Ok(0)
		\\from after: Err(NoLaterEntry)
	actual == expected
}

## However far apart its entries, a timeline stays within its bound and
## counts every dated entry once: the first and last years a timestamp
## can name are about 5.3 billion minutes apart.
expect {
	far =
		\\5000-06-15T12:00:00Z ERROR x: y
		\\0001-01-01T00:00:00Z ERROR x: y
		\\9999-12-31T23:59:00Z ERROR x: y
		\\
	timeline = indexed(far, 3).timeline
	actual = {
		within_bound: timeline.buckets.len() <= Log.most_buckets,
		errors: timeline.buckets.fold(0, |sum, b| sum + b.tally.error),
		first_lines: timeline.buckets.keep_oks(
			|b| match b.first {
				Line(line) => Ok(line)
				NoEntry => Err(NoEntry)
			},
		),
	}
	actual == { within_bound: Bool.True, errors: 3, first_lines: [1, 0, 2] }
}

## A long line is cut for showing; a CRLF break is not part of the text.
expect {
	actual =
		\\crlf: ${Str.inspect(text_of("a\r\n".to_utf8()))}
		\\long: ${Str.inspect(text_of(Str.repeat("y", 1001).to_utf8()).count_utf8_bytes())}
	expected =
		\\crlf: "a"
		\\long: 1003
	actual == expected
}

## The viewer's first line stops at the last page.
expect [0, 60, 100].map(|wanted| Log.window_first({ lines: 120, wanted })) == [0, 60, 70]

## A log shorter than a page always starts at its first line.
expect Log.window_first({ lines: 10, wanted: 7 }) == 0
