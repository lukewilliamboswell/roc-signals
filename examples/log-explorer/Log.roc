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
Log := [].{

	## How severe an entry is, from its level word.
	Level : [Trace, Debug, Info, Warn, Error, Fatal]

	## What a line is: the first line of an entry, a line continuing the
	## entry before it, or a line before the first entry.
	Mark : [Entry(Level), Continued(Level), Unheaded]

	## Entries counted by level.
	Tally : { trace : U64, debug : U64, info : U64, warn : U64, error : U64, fatal : U64 }

	## What indexing a log keeps: the file's size, where each line starts and
	## what it is, and the counts the overview shows. Line `n` (from 0) is
	## the bytes from `starts[n]` to the next line's start, or to the end.
	Index : {
		size : U64,
		starts : List(U64),
		marks : List(Mark),
		entries : U64,
		tally : Tally,
		earliest : Str,
		latest : Str,
		sources : Dict(Str, U64),
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

	## A search's answer: how many lines match, the page asked for (from 0)
	## and its lines.
	Found : { matches : U64, page : U64, lines : List(Line) }

	## A search with text, over the lines scanned so far: how many matched,
	## and those of them on the page asked for.
	Scan : { matches : U64, lines : List(Line) }

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

	## A search with text, continued over the next range of lines and the
	## bytes of their span.
	scan : Scan, { index : Index, search : Search, first : U64, count : U64, bytes : List(U8) } -> Scan
	scan = |scanned, { index, search, first, count, bytes }| {
		needle = search.text.to_utf8().map(folded)
		from = search.page * Log.page_lines
		base = index.starts.get(first) ?? index.size
		var $matches = scanned.matches
		var $lines = scanned.lines
		var $n = first
		while $n < first + count {
			mark = mark_of(index, $n)
			if Log.is_shown(mark, search.filter) {
				{ start, len } = Log.span(index, { first: $n, count: 1 })
				line = bytes.sublist({ start: start - base, len })
				if has_folded(line, needle) {
					if $matches >= from and $matches < from + Log.page_lines {
						$lines = $lines.append({ number: $n + 1, mark, text: text_of(line) })
					}
					$matches = $matches + 1
				}
			}
			$n = $n + 1
		}
		{ matches: $matches, lines: $lines }
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
	{ size, starts, marks, entries, tally, earliest, latest, sources } = index
	match Log.header(head) {
		Headed({ time, level, source }) => {
			seen = sources.get(source) ?? 0
			first = entries == 0
			{
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
			{ size, starts: starts.append(start), marks: marks.append(mark), entries, tally, earliest, latest, sources }
		}
	}
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
	len = if (end - start < room) end - start else room
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
	actual =
		\\starts: ${Str.inspect(index.starts)}
		\\marks: ${Str.inspect(index.marks)}
		\\overview: ${Str.inspect(view)}
	expected =
		\\starts: [0, 66, 126, 160, 216]
		\\marks: [Entry(Info), Entry(Error), Continued(Error), Entry(Warn), Continued(Warn)]
		\\overview: { distinct_sources: 3, entries: 3, lines: 5, size: 229, sources: [{ entries: 1, source: "api" }, { entries: 1, source: "cache" }, { entries: 1, source: "db" }], span: Between({ earliest: "2026-11-11T07:59:59.000Z", latest: "2026-11-11T08:00:01.004Z" }), tally: { debug: 0, error: 1, fatal: 0, info: 1, trace: 0, warn: 1 } }
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
## with their entry's level; a search with no text lists from the index.
expect {
	index = indexed(sample, 1000)
	search = |text, filter| {
		found = Log.scan({ matches: 0, lines: [] }, { index, search: { text, filter, page: 0 }, first: 0, count: 5, bytes: sample.to_utf8() })
		"${found.matches.to_str()} ${Str.inspect(found.lines.map(|l| l.number))}"
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
		\\pool: 1 [3]
		\\pool in errors: 1 [3]
		\\pool in warnings: 0 []
		\\every 2026: 3 [1, 2, 4]
		\\errors: { matches: 2, page: [1, 2] }
		\\all: { matches: 5, page: [0, 1, 2, 3, 4] }
	actual == expected
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
