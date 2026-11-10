import Log

## The sample log the explorer makes for itself, so the site can show it
## without a file from the user: a day of a small web shop's services,
## generated from a fixed seed, so the same number of entries is always the
## same text.
Sample := [].{

	## Where generation has got to: the random state and the time of the
	## last entry, in milliseconds after the log's start.
	Progress : { seed : U64, ms : U64 }

	## Where every sample log starts.
	start : Progress
	start = { seed: 2026, ms: 0 }

	## The next `count` entries of the log, a line each and a few more for
	## an error's stack trace, and where generation got to.
	entries : Progress, U64 -> { text : Str, progress : Progress }
	entries = |progress, count| {
		var $text = ""
		var $seed = progress.seed
		var $ms = progress.ms
		var $n = 0
		while $n < count {
			$seed = next($seed)
			$ms = $ms + 1 + ($seed.shr_zf_wrap(33) % 100)
			$seed = next($seed)
			kind = pick($seed.shr_zf_wrap(33) % total_weight)
			$seed = next($seed)
			number = $seed.shr_zf_wrap(33) % 10000
			level = Log.level_name(kind.level)
			padded = if (level.count_utf8_bytes() < 5) "${level} " else level
			$text = Str.concat($text, "${timestamp($ms)} ${padded} ${kind.source}: ${(kind.message)(number)}\n")
			for line in kind.trace {
				$text = Str.concat($text, "    at ${line}\n")
			}
			$n = $n + 1
		}
		{ text: $text, progress: { seed: $seed, ms: $ms } }
	}
}

## What an entry of the sample can be, and how often, out of
## `total_weight`.
Kind : { weight : U64, source : Str, level : Log.Level, message : U64 -> Str, trace : List(Str) }

kinds : List(Kind)
kinds = [
	{ weight: 300, source: "api", level: Info, message: |n| "GET /orders/${n.to_str()} answered 200 in ${(n % 90 + 4).to_str()} ms", trace: [] },
	{ weight: 40, source: "api", level: Warn, message: |n| "GET /search answered 429 for client ${n.to_str()}: rate limited", trace: [] },
	{ weight: 15, source: "api", level: Error, message: |n| "POST /checkout answered 500 for order ${n.to_str()}", trace: ["Checkout.submit (checkout.roc:141)", "Router.dispatch (router.roc:57)"] },
	{ weight: 120, source: "db", level: Debug, message: |n| "query orders by customer ${n.to_str()} took ${(n % 40 + 1).to_str()} ms", trace: [] },
	{ weight: 25, source: "db", level: Warn, message: |n| "slow query: ${(n % 900 + 500).to_str()} ms for report ${(n % 12).to_str()}", trace: [] },
	{ weight: 10, source: "db", level: Error, message: |_n| "connection reset by peer", trace: ["Pool.acquire (pool.roc:88)", "Orders.load (orders.roc:212)", "Checkout.submit (checkout.roc:139)"] },
	{ weight: 90, source: "auth", level: Info, message: |n| "user ${n.to_str()} signed in", trace: [] },
	{ weight: 20, source: "auth", level: Warn, message: |n| "failed sign-in for user ${n.to_str()}", trace: [] },
	{ weight: 110, source: "cache", level: Debug, message: |n| "miss for user:${n.to_str()}", trace: [] },
	{ weight: 60, source: "cache", level: Trace, message: |n| "hit for user:${n.to_str()}", trace: [] },
	{ weight: 50, source: "billing", level: Info, message: |n| "invoice ${n.to_str()} paid", trace: [] },
	{ weight: 8, source: "billing", level: Error, message: |n| "card declined for invoice ${n.to_str()}", trace: [] },
	{ weight: 70, source: "mailer", level: Info, message: |n| "sent receipt to customer ${n.to_str()}", trace: [] },
	{ weight: 40, source: "scheduler", level: Info, message: |n| "job ${(n % 7).to_str()} of the nightly report finished", trace: [] },
	{ weight: 41, source: "search", level: Info, message: |n| "indexed ${n.to_str()} documents", trace: [] },
	{ weight: 1, source: "kernel", level: Fatal, message: |_n| "out of memory, restarting the shop", trace: [] },
]

total_weight : U64
total_weight = kinds.fold(0, |sum, kind| sum + kind.weight)

## The kind a number below `total_weight` falls on.
pick : U64 -> Kind
pick = |at| {
	var $left = at
	for kind in kinds {
		if $left < kind.weight {
			return kind
		}
		$left = $left - kind.weight
	}
	crash "Sample.pick: ${at.to_str()} is not below the kinds' total weight"
}

next : U64 -> U64
next = |seed| seed.times_wrap(6364136223846793005).plus_wrap(1442695040888963407)

## The time `ms` milliseconds after 2026-11-11T08:00:00.000Z, for the first
## nineteen days.
timestamp : U64 -> Str
timestamp = |ms| {
	at = ms + 8 * 3600000
	day = 11 + at / 86400000
	of_day = at % 86400000
	"2026-11-${pad(day, 2)}T${pad(of_day / 3600000, 2)}:${pad(of_day / 60000 % 60, 2)}:${pad(of_day / 1000 % 60, 2)}.${pad(of_day % 1000, 3)}Z"
}

## A number written with at least `width` digits.
pad : U64, U64 -> Str
pad = |number, width| {
	digits = number.to_str()
	short = width - (if (digits.count_utf8_bytes() < width) digits.count_utf8_bytes() else width)
	"${Str.repeat("0", short)}${digits}"
}

## Times are written in full, and roll over to the next day.
expect {
	actual =
		\\start: ${timestamp(0)}
		\\later: ${timestamp(3723004)}
		\\next day: ${timestamp(16 * 3600000 + 5)}
	expected =
		\\start: 2026-11-11T08:00:00.000Z
		\\later: 2026-11-11T09:02:03.004Z
		\\next day: 2026-11-12T00:00:00.005Z
	actual == expected
}

## The sample is the same text every time, every line of it is indexed as
## the entry or the trace it is, and generating it in parts gives the same
## text as generating it at once.
expect {
	whole = Sample.entries(Sample.start, 400)
	first = Sample.entries(Sample.start, 150)
	rest = Sample.entries(first.progress, 250)
	index = Log.finish(Log.feed(Log.indexer, whole.text.to_utf8()))
	traced = index.marks.count_if(
		|mark| match mark {
			Continued(_) => Bool.True
			_ => Bool.False
		},
	)
	actual =
		\\parts: ${Str.inspect(Str.concat(first.text, rest.text) == whole.text)}
		\\entries: ${index.entries.to_str()}
		\\lines: ${(index.starts.len() - traced).to_str()}
	expected =
		\\parts: True
		\\entries: 400
		\\lines: 400
	actual == expected
}
