app [target] {
	fz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.6.0/6uc3YKGydgEnS2nrCimSYWDNfT6drYcgU52VAwqrb6DS.tar.zst",
}

import fz.Fuzz
import Log

## The Log Explorer's index, against a model that reads the whole text at
## once. The worker indexes a log a chunk at a time and later reads back
## only the bytes of the lines a question needs, so the bugs to fear are at
## chunk boundaries (a line, a header or a `\r\n` split between two
## chunks) and in the arithmetic that turns line numbers into byte ranges.
##
## Each input decodes into a log made of header-like pieces (timestamps,
## level words with and without brackets, sources, breaks, `\r`, multibyte
## text), a chunk size, and a question. Its properties:
##
## - indexing in chunks of any size gives the index of indexing at once;
## - the index partitions the text: its lines, cut at their starts, are the
##   text's lines in order, each ending in its break except perhaps the
##   last, and the size is the text's;
## - each line's mark is what its own header says, continuations taking
##   the level of the entry before them, and the counts, sources and time
##   span are those of the entries;
## - a page of lines read from the bytes of its span equals the same lines
##   of the text;
## - `chunks` covers every line once, in order, each range within the bound
##   unless it is one line;
## - a search scanned chunk by chunk, and a listing from the index alone,
##   find exactly the lines the model finds, and the page asked for;
## - the timeline is the model's: the narrowest width that keeps the
##   entries' minutes within `most_buckets` buckets, each bucket counting
##   its entries by level and keeping its first line, and the entries
##   with no real time counted apart; a search counts each match in its
##   entry's bucket. Timestamps days and years apart make the timeline
##   widen while it is built, an entry at a time.
Input : { pieces : List(U8), chunk : U8, question : U8, page : U8 }

## The pieces a log is made of; an input byte picks one.
pieces : List(Str)
pieces = [
	"2026-11-11T08:00:00Z",
	"2026-11-11T08:00:00.120Z",
	"2026-11-10T23:59:59.999+10:00",
	"2026-1x-11T08:00:00Z",
	" ",
	"  ",
	"\t",
	"INFO",
	"warn",
	"[Warning]",
	"ERROR",
	"fatal",
	"DEBUG",
	"trace",
	"INFOS",
	"api:",
	"[cache]",
	"db",
	"reset by peer",
	"Reset",
	"é",
	"x",
	"\n",
	"\n",
	"\n",
	"\r\n",
	"\r",
	":",
	"2026-11-11T09:31:00Z",
	"2026-11-14T00:00:59Z",
	"2027-03-01T12:00:00Z",
	"2031-02-28T23:59:00Z",
	"2400-02-29T00:00:00Z",
	"2026-02-29T08:00:00Z",
	"2026-11-11T08:60:00Z",
	"\n2026-11-11T08:00:00Z ERROR db: reset\n",
]

## What a question searches for; an input byte picks one.
texts : List(Str)
texts = ["", "reset", "RESET BY", "api", "é", "2026", " ", "\r", "info", "zz"]

## The text an input's pieces make.
text_of_input : List(U8) -> List(U8)
text_of_input = |picks| Str.join_with(picks.map(|b| pieces.get(b.to_u64() % pieces.len()) ?? ""), "").to_utf8()

## The text's lines, each with its break.
model_lines : List(U8) -> List(List(U8))
model_lines = |text| {
	var $lines = []
	var $from = 0
	var $i = 0
	for b in text {
		if b == '\n' {
			$lines = $lines.append(text.sublist({ start: $from, len: $i + 1 - $from }))
			$from = $i + 1
		}
		$i = $i + 1
	}
	if ($from < text.len()) $lines.append(text.drop_first($from)) else $lines
}

## A line without its break.
unbroken : List(U8) -> List(U8)
unbroken = |line| if (line.last() == Ok('\n')) line.drop_last(1) else line

## A line as a question shows it: without its break or a `\r` before it,
## cut at `line_bytes`.
shown : List(U8) -> Str
shown = |line| {
	text = unbroken(line)
	bare = if (text.last() == Ok('\r')) text.drop_last(1) else text
	if bare.len() > Log.line_bytes {
		"${Str.from_utf8_lossy(bare.take_first(Log.line_bytes))}…"
	} else {
		Str.from_utf8_lossy(bare)
	}
}

## Each line's mark, from its own header.
model_marks : List(List(U8)) -> List(Log.Mark)
model_marks = |lines| {
	var $marks = []
	var $level = NoEntry
	for line in lines {
		match Log.header(unbroken(line).take_first(Log.header_bytes)) {
			Headed({ level, .. }) => {
				$marks = $marks.append(Entry(level))
				$level = Seen(level)
			}
			Plain => {
				$marks = $marks.append(
					match $level {
						Seen(level) => Continued(level)
						NoEntry => Unheaded
					},
				)
			}
		}
	}
	$marks
}

## Whether `hay` holds `needle`, ignoring ASCII case, by the builtins.
model_has : List(U8), Str -> Bool
model_has = |hay, needle| {
	lower = |bytes| Str.from_utf8_lossy(bytes.map(|b| if (b >= 'A' and b <= 'Z') b + 32 else b))
	lower(hay).contains(lower(needle.to_utf8()))
}

model_shows : Log.Mark, Log.Filter -> Bool
model_shows = |mark, filter| match filter {
	Everything => Bool.True
	Only(wanted) =>
		match mark {
			Entry(level) | Continued(level) => level == wanted
			Unheaded => Bool.False
		}
}

## Each line's entry minute: for an entry, its own timestamp's; for a line
## continuing one, its entry's; `NoMinute` before the first entry or for
## an entry whose time is not a real one.
model_minutes : List(List(U8)) -> List([NoMinute, Minute({ minute : U64, level : Log.Level, entry : Bool })])
model_minutes = |lines| {
	var $out = []
	var $last = NoMinute
	for line in lines {
		match Log.header(unbroken(line).take_first(Log.header_bytes)) {
			Headed({ time, level, .. }) => {
				$last = match Log.minute_of(time) {
					Ok(minute) => Minute({ minute, level, entry: Bool.True })
					Err(NotATime) => NoMinute
				}
				$out = $out.append($last)
			}
			Plain => {
				$out = $out.append(
					match $last {
						Minute(m) => Minute({ ..m, entry: Bool.False })
						NoMinute => NoMinute
					},
				)
			}
		}
	}
	$out
}

## The timeline of every dated entry at once: the narrowest width whose
## buckets from the earliest minute to the latest are at most
## `most_buckets`, trying `widths` in order and then doubling.
model_timeline : List([NoMinute, Minute({ minute : U64, level : Log.Level, entry : Bool })]) -> Log.Timeline
model_timeline = |minutes| {
	dated = minutes.map_with_index(|m, line| (m, line)).keep_oks(
		|(m, line)| match m {
			Minute({ minute, level, entry }) if entry => Ok({ minute, level, line })
			_ => Err(Skip)
		},
	)
	match (dated.map(|d| d.minute).min(), dated.map(|d| d.minute).max()) {
		(Ok(low), Ok(high)) => {
			var $width = 1
			while high // $width - low // $width + 1 > Log.most_buckets {
				$width = Log.widths.find_first(|w| w > $width) ?? $width * 2
			}
			width = $width
			start = low // width
			var $buckets = List.repeat({ tally: { trace: 0, debug: 0, info: 0, warn: 0, error: 0, fatal: 0 }, first: NoEntry }, high // width - start + 1)
			for { minute, level, line } in dated {
				$buckets = $buckets.update(
					minute // width - start,
					|b| {
						tally: { ..b.tally, trace: b.tally.trace + (if (level == Trace) 1 else 0), debug: b.tally.debug + (if (level == Debug) 1 else 0), info: b.tally.info + (if (level == Info) 1 else 0), warn: b.tally.warn + (if (level == Warn) 1 else 0), error: b.tally.error + (if (level == Error) 1 else 0), fatal: b.tally.fatal + (if (level == Fatal) 1 else 0) },
						first: match b.first {
							Line(first) => Line(first)
							NoEntry => Line(line.to_u64())
						},
					},
				) ?? crash "model_timeline: a minute outside its own span"
			}
			{ width, start, buckets: $buckets }
		}
		_ => Log.no_timeline
	}
}

## The text indexed in chunks of `size` bytes.
indexed : List(U8), U64 -> Log.Index
indexed = |text, size| {
	var $ix = Log.indexer
	var $at = 0
	while $at < text.len() {
		$ix = Log.feed($ix, text.sublist({ start: $at, len: size }))
		$at = $at + size
	}
	Log.finish($ix)
}

## Every property, or the first that fails.
check : Input -> Try({}, Str)
check = |{ pieces: picks, chunk, question, page }| {
	text = text_of_input(picks)
	size = chunk.to_u64() + 1
	index = indexed(text, size)
	if index != indexed(text, text.len() + 1) {
		return Err("indexing in chunks of ${size.to_str()} bytes differs from indexing at once")
	}
	lines = model_lines(text)
	cut = List.map2(index.starts, index.starts.drop_first(1).append(text.len()), |start, end| text.sublist({ start, len: end - start }))
	if cut != lines or index.size != text.len() {
		return Err("the index does not partition the text: starts ${Str.inspect(index.starts)}")
	}
	marks = model_marks(lines)
	if index.marks != marks {
		return Err("marks ${Str.inspect(index.marks)}, the model's ${Str.inspect(marks)}")
	}
	headers = lines.keep_oks(
		|line| match Log.header(unbroken(line).take_first(Log.header_bytes)) {
			Headed(h) => Ok(h)
			Plain => Err(Plain)
		},
	)
	overview = Log.overview(index)
	tallied = Log.levels.map(|level| Log.tally_of(overview.tally, level))
	model_tallied = Log.levels.map(|level| headers.count_if(|h| h.level == level))
	sources = headers.map(|h| h.source)
	times = headers.map(|h| Str.from_utf8_lossy(h.time)).sort_with(|a, b| byte_order(a.to_utf8(), b.to_utf8()))
	span = match (times.first(), times.last()) {
		(Ok(earliest), Ok(latest)) => Between({ earliest, latest })
		_ => Untimed
	}
	if overview.entries != headers.len() or tallied != model_tallied or overview.span != span or overview.distinct_sources != Set.from_list(sources).len() or overview.sources.any(|s| sources.count_if(|x| x == s.source) != s.entries) {
		return Err("overview ${Str.inspect(overview)}, the model's entries ${headers.len().to_str()}, tally ${Str.inspect(model_tallied)}, span ${Str.inspect(span)}")
	}
	# The timeline, built an entry at a time, against one built at once.
	minutes = model_minutes(lines)
	timeline = model_timeline(minutes)
	undated = headers.count_if(|h| Log.minute_of(h.time).is_err())
	if overview.timeline != timeline or overview.undated != undated or timeline.buckets.len() > Log.most_buckets {
		return Err("timeline ${Str.inspect({ width: overview.timeline.width, start: overview.timeline.start, buckets: overview.timeline.buckets.len(), undated: overview.undated })}, the model's ${Str.inspect({ width: timeline.width, start: timeline.start, buckets: timeline.buckets.len(), undated })}")
	}
	# A page of lines from the bytes of its span.
	count = lines.len()
	first = if (count == 0) 0 else page.to_u64() % count
	taken = if (count - first < 7) count - first else 7
	{ start, len } = Log.span(index, { first, count: taken })
	read = Log.lines_in(index, { first, count: taken, bytes: text.sublist({ start, len }) })
	want = List.map2(lines.drop_first(first).take_first(taken), marks.drop_first(first).take_first(taken), |line, mark| (line, mark)).map_with_index(|(line, mark), i| { number: first + i + 1, mark, text: shown(line) })
	if read != want {
		return Err("lines ${first.to_str()} to ${(first + taken).to_str()} read ${Str.inspect(read)}, the text's are ${Str.inspect(want)}")
	}
	# Chunks of whole lines.
	bound = size * 3
	ranges = Log.chunks(index, bound)
	covered = ranges.fold(
		Ok(0),
		|at, r| match at {
			Ok(next) if r.first == next and r.count >= 1 => Ok(next + r.count)
			_ => Err(Gap(r))
		},
	)
	if covered != Ok(count) or ranges.any(|r| r.count > 1 and Log.span(index, r).len > bound) {
		return Err("chunks of ${bound.to_str()} bytes ${Str.inspect(ranges)} do not cover ${count.to_str()} lines in order within the bound")
	}
	# A search, scanned chunk by chunk, and a listing.
	needle = texts.get(question.to_u64() % texts.len()) ?? ""
	filter = match question.to_u64() / texts.len() % 8 {
		0 => Everything
		1 => Only(Trace)
		2 => Only(Debug)
		3 => Only(Info)
		4 => Only(Warn)
		5 => Only(Error)
		6 => Only(Fatal)
		_ => Everything
	}
	search = { text: needle, filter, page: page.to_u64() % 3 }
	matching = List.map2(lines, marks, |line, mark| (line, mark))
		.map_with_index(|(line, mark), i| { number: i + 1, mark, text: shown(line), line })
		.keep_if(|l| model_shows(l.mark, filter) and model_has(unbroken(l.line), needle))
	on_page = matching.drop_first(search.page * Log.page_lines).take_first(Log.page_lines).map(|l| { number: l.number, mark: l.mark, text: l.text })
	scanned = ranges.fold(
		Log.unscanned(index),
		|so_far, r| {
			range = Log.span(index, r)
			Log.scan(so_far, { index, search, first: r.first, count: r.count, bytes: text.sublist(range) })
		},
	)
	if scanned.matches != matching.len() or scanned.lines != on_page {
		return Err("search ${Str.inspect(search)} found ${scanned.matches.to_str()}: ${Str.inspect(scanned.lines.map(|l| l.number))}, the model ${matching.len().to_str()}: ${Str.inspect(on_page.map(|l| l.number))}")
	}
	var $per_bucket = List.repeat(0, timeline.buckets.len())
	for l in matching {
		match minutes.get(l.number - 1) {
			Ok(Minute({ minute, .. })) => {
				$per_bucket = $per_bucket.update(minute // timeline.width - timeline.start, |n| n + 1) ?? crash "the model's match is outside its timeline"
			}
			_ => {}
		}
	}
	if scanned.per_bucket != $per_bucket {
		return Err("search ${Str.inspect(search)} counted ${Str.inspect(scanned.per_bucket)} a bucket, the model ${Str.inspect($per_bucket)}")
	}
	listing = Log.listed(index, { ..search, text: "" })
	listed_model = List.map2(lines, marks, |_line, mark| mark).map_with_index(|mark, i| (i, mark)).keep_if(|(_i, mark)| model_shows(mark, filter)).map(|(i, _mark)| i)
	if listing != { matches: listed_model.len(), page: listed_model.drop_first(search.page * Log.page_lines).take_first(Log.page_lines) } {
		return Err("listing ${Str.inspect(listing)} for ${Str.inspect(filter)}, the model's ${Str.inspect(listed_model)}")
	}
	Ok({})
}

byte_order : List(U8), List(U8) -> [Before, Same, After]
byte_order = |a, b| {
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

test! : Input => Fuzz.Outcome
test! = |input| match check(input) {
	Ok({}) => Fuzz.keep
	Err(problem) => crash problem
}

## A log of every kind of line, picked by index into `pieces`.
log_example : List(U8)
log_example = [1, 4, 7, 5, 15, 21, 18, 22, 6, 20, 25, 0, 4, 9, 4, 16, 4, 19, 22, 26, 2, 4, 10, 4, 17, 23, 3, 4, 7, 22, 21]

ex : Str, Input -> Fuzz.Example(Input)
ex = |name, input| Fuzz.example({ name, revision: "1", make: || input })

target = Fuzz.target_with!({
	name: "log-explorer",
	examples: [
		ex("every-line", { pieces: log_example, chunk: 0, question: 1, page: 0 }),
		ex("chunk-7", { pieces: log_example, chunk: 6, question: 52, page: 2 }),
		ex("crlf-split", { pieces: [0, 4, 7, 25, 0, 4, 11, 4, 17, 25], chunk: 21, question: 0, page: 1 }),
		ex("no-break", { pieces: [1, 4, 10, 4, 15, 21, 21], chunk: 3, question: 3, page: 0 }),
		ex("empty", { pieces: [], chunk: 9, question: 4, page: 0 }),
		ex("long-page", { pieces: List.repeat(0, 1).concat(List.repeat(22, 90)), chunk: 200, question: 10, page: 1 }),
		ex("timeline-widens", { pieces: [0, 4, 7, 22, 28, 4, 10, 22, 29, 4, 8, 22, 30, 4, 11, 22, 31, 4, 12, 22, 32, 4, 7, 22, 33, 4, 7, 22, 34, 4, 7, 22, 35, 26, 21], chunk: 5, question: 1, page: 0 }),
	],
	generator: { pieces: Fuzz.list(Fuzz.u8, 300), chunk: Fuzz.u8, question: Fuzz.u8, page: Fuzz.u8 }.Fuzz,
	test!,
	show: Str.inspect,
})
