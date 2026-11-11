import pf.Engine
import pf.Port
import pf.Worker
import Feed
import Orders

## The Million-Row Explorer's tasks, its page state, and every decision the
## view makes, pure so that `expect`s and specs reach them.
##
## The database is split into four shards. Each shard is a preparation
## whose input is only its seed, its number and its size, so its orders are
## generated inside a worker and never cross to the page. A question (the
## categories and the value range) is asked of every shard at once with
## `Worker.gather`; each answer is a few kilobytes of counts, which the page
## adds together, with the live orders it has folded in, and draws.
Explorer := [].{

	# -- In the workers -----------------------------------------------------

	## Why a shard has no orders: it was asked to hold more than a worker
	## keeps under the default memory bound.
	Problem : [TooManyOrders]

	## The most orders one shard holds: 40 MB of packed orders.
	most_per_shard : U64
	most_per_shard = 10000000

	## A shard's orders, generated in the worker from its seed. The worker
	## keeps them, so later questions cost only the summary.
	shard : Worker.Preparation(Orders.Shard, List(Orders.Order), Problem)
	shard = Worker.prepared({ name: "roc-signals.example/million-row-explorer/shard", prepare!: |wanted| if (wanted.rows > Explorer.most_per_shard) Err(TooManyOrders) else Ok(Orders.generate(wanted)) })

	## A question of one shard. A question the user has moved past (a
	## slider dragged on) is let finish rather than stopped, because stopping
	## a running job ends its worker and the shard with it; the next
	## question waits the few milliseconds for that worker instead of
	## generating the shard again elsewhere. The deadline only bounds a job
	## that never ends: questions take milliseconds.
	summary : Worker.PreparedTask(Orders.Shard, List(Orders.Order), Orders.Filter, Orders.Summary, Problem)
	summary = Explorer.shard.task({ name: "roc-signals.example/million-row-explorer/summary", run!: |orders, filter| Ok(Orders.summarise(orders, filter)), on_cancel: Finish, deadline: Ms(30000) })

	# -- On the page --------------------------------------------------------

	## How many shards the database is split into: one per worker of the
	## pool the site mounts (`max_workers = 4`). With fewer workers than
	## shards a worker holds one shard at a time, so every question
	## generates shards again.
	shards : U64
	shards = 4

	## The database's seed: the same orders on every visit.
	seed : U64
	seed = 2026

	## The sizes the user can choose, in orders.
	sizes : List(U64)
	sizes = [200000, 2000000, 8000000]

	## The live feed's paces the user can choose, in orders a second.
	rates : List(U32)
	rates = [200, 2000, 20000]

	## Whether the live feed is folded in.
	Flow : [Live, Paused]

	## How often a slider being dragged asks its question, in milliseconds.
	## A question takes tens of milliseconds, and a newer question stops the
	## older one's answer from being shown, so a slider that asked at every
	## step of a drag would show nothing until the drag ended. Asking at most
	## this often lets each question be answered while the drag goes on.
	sample_ms : U32
	sample_ms = 100

	## Whether the controls show a question that has not been asked yet.
	Sampling : [Asked, Waiting]

	## The page's state: the database's size, the question the controls
	## show (categories and a value range in whole bins) and the question
	## asked of the shards, the live feed and what it has delivered, and a
	## note when something it sent was refused.
	S : {
		size : U64,
		categories : List(Orders.Category),
		lowest : U64,
		highest : U64,
		asked : Orders.Filter,
		flow : Flow,
		rate : U32,
		live : Orders.Tally,
		live_orders : U64,
		dropped : U32,
		note : Str,
	}

	initial : S
	initial = {
		size: 2000000,
		categories: Orders.categories,
		lowest: 0,
		highest: Orders.bins - 1,
		asked: Orders.everything,
		flow: Live,
		rate: 200,
		live: Orders.no_orders,
		live_orders: 0,
		dropped: 0,
		note: "",
	}

	## The question the controls show.
	filter : S -> Orders.Filter
	filter = |s| { categories: s.categories, lowest: s.lowest, highest: s.highest }

	## Whether the shards have been asked what the controls show.
	sampling : S -> Sampling
	sampling = |s| if (Explorer.filter(s) == s.asked) Asked else Waiting

	## Ask the shards what the controls show: at once for a click, and when
	## the sampling timer fires for a slider.
	asking : S -> S
	asking = |s| { ..s, asked: Explorer.filter(s) }

	## One question per shard: equal shards, the last taking the remainder.
	questions : S -> List(Worker.Question(Orders.Shard, Orders.Filter))
	questions = |s| {
		size = s.size // Explorer.shards
		var $out = []
		for i in 0..<Explorer.shards {
			rows = if (i + 1 == Explorer.shards) s.size - size * i else size
			$out = $out.append({ input: { seed: Explorer.seed, shard: i, rows }, query: s.asked })
		}
		$out
	}

	## A category's box was ticked (`"true"`) or cleared, and the question
	## asked at once. The categories stay in their fixed order, so the same
	## choice is the same question.
	toggled : S, Orders.Category, Str -> S
	toggled = |s, category, checked|
		Explorer.asking({
			..s,
			categories: Orders.categories.keep_if(|c| if (c == category) checked == "true" else s.categories.contains(c)),
		})

	## The value range's ends, as the sliders send them: a bin number. An
	## end moved past the other takes the other with it. The question waits
	## for the sampling timer (`sample_ms`).
	lowest_set : S, Str -> S
	lowest_set = |s, text| match U64.from_str(text) {
		Ok(bin) if bin < Orders.bins => { ..s, lowest: bin, highest: s.highest.max(bin) }
		_ => s
	}

	highest_set : S, Str -> S
	highest_set = |s, text| match U64.from_str(text) {
		Ok(bin) if bin < Orders.bins => { ..s, highest: bin, lowest: s.lowest.min(bin) }
		_ => s
	}

	## A size from the menu; anything else is ignored.
	sized : S, Str -> S
	sized = |s, text| match U64.from_str(text) {
		Ok(size) if Explorer.sizes.contains(size) => Explorer.asking({ ..s, size })
		_ => s
	}

	## A pace from the menu; anything else is ignored.
	paced : S, Str -> S
	paced = |s, text| match U32.from_str(text) {
		Ok(rate) if Explorer.rates.contains(rate) => { ..s, rate }
		_ => s
	}

	## The live feed switched on (`"true"`) or off.
	flowing : S, Str -> S
	flowing = |s, checked| { ..s, flow: if (checked == "true") Live else Paused }

	## A message of the live feed. A batch is checked at the door: an order
	## with a region the shop does not ship to, or a value outside what an
	## order can be, refuses the whole batch, and the note says which.
	received : S, Try(Feed.Batch, Port.Error) -> S
	received = |s, message| match message {
		Ok(batch) =>
			match batch.sales.map_try(sale_order) {
				Ok(orders) => { ..s, live: Orders.tally(s.live, orders), live_orders: s.live_orders + orders.len(), dropped: batch.dropped }
				Err(UnknownRegion(region)) => { ..s, note: "A batch of live orders was refused: no region is called \"${region}\"." }
				Err(ValueOutOfRange(cents)) => { ..s, note: "A batch of live orders was refused: an order worth ${cents.to_str()} cents is outside $0.01 to $399.99." }
			}
		Err(Closed) => { ..s, flow: Paused, note: "The live feed closed." }
		Err(Threw(why)) => { ..s, flow: Paused, note: "The live feed failed: ${why}" }
		Err(Undecodable(why)) => { ..s, note: "A batch of live orders was not understood: ${why}" }
		Err(TooLarge) => { ..s, note: "A batch of live orders was too large to take." }
		Err(Refused) | Err(Timeout) => { ..s, note: "The live feed could not start: too many requests at once." }
	}

	## What the page shows: the shards' last complete answer added to the
	## live orders, the question it shows, and how far the current question
	## has got.
	Board : {
		summary : Orders.Summary,
		filter : Orders.Filter,
		status : Str,
		shards : List(Str),
	}

	## The board for a state and the shards' answers, for the question
	## asked of them (which a slider being dragged may be ahead of). While a question is
	## being answered the charts keep the last complete answer: a sum of
	## some shards' answers would be a wrong total, not a partial one. A
	## failed question has no answer to keep (the gather keeps none past a
	## failure), so the history is empty until the next question is
	## answered, and the status says so. The live orders always follow the
	## current question.
	board : S, Engine.Gathered(Orders.Summary, Worker.Error(Problem)) -> Board
	board = |s, gathered| {
		history = gathered.all.answered() ?? []
		unanswered = " Only today's live orders are shown; change the question to ask again."
		answered = gathered.jobs.count_if(
			|job| match job {
				Answered(_) => Bool.True
				_ => Bool.False
			},
		)
		status = match Worker.status(gathered.all) {
			Unasked => ""
			Working if history.is_empty() => "Generating ${with_commas(s.size)} orders in ${Explorer.shards.to_str()} workers… ${answered.to_str()} of ${Explorer.shards.to_str()} shards ready."
			Working => "Asking ${Explorer.shards.to_str()} shards… ${answered.to_str()} answered; the charts show the last complete answer."
			Answered(_) => "${Explorer.shards.to_str()} of ${Explorer.shards.to_str()} shards answered."
			Failed(TooManyOrders) => "A shard was asked to hold more orders than a worker keeps.${unanswered}"
			Timeout => "A shard took too long to answer.${unanswered}"
			Refused => "Too many requests at once: a shard was not asked.${unanswered}"
			Lost(fault) => "A shard's worker stopped (${Str.inspect(fault)}).${unanswered}"
		}
		{
			summary: Orders.merge(history.append(Orders.summarise_tally(s.live, s.asked))),
			filter: s.asked,
			status,
			shards: gathered.jobs.map(shard_text),
		}
	}

	## A count with thousands separated: `1,234,567`.
	grouped : U64 -> Str
	grouped = |n| with_commas(n)

	## An amount in cents as whole dollars: `$1,234`.
	dollars : U64 -> Str
	dollars = |cents| "$${with_commas((cents + 50) // 100)}"

	## The headline figures of a summary.
	headline : Orders.Summary -> { orders : Str, revenue : Str, average : Str }
	headline = |answer| {
		orders: with_commas(answer.orders),
		revenue: Explorer.dollars(answer.revenue),
		average: if (answer.orders == 0) "–" else "$${((answer.revenue // answer.orders) // 100).to_str()}.${pad2((answer.revenue // answer.orders) % 100)}",
	}

	## The value range as the user reads it.
	range_text : S -> Str
	range_text = |s| "From $${(s.lowest * Orders.bin_cents // 100).to_str()} to $${((s.highest + 1) * Orders.bin_cents // 100).to_str()}"

	## The live feed's line.
	live_text : S -> Str
	live_text = |s| {
		state = match s.flow {
			Live => "Live: ${with_commas(s.rate.to_u64())} orders a second"
			Paused => "Paused"
		}
		dropped = if (s.dropped == 0) "" else ", ${with_commas(s.dropped.to_u64())} dropped by the feed"
		"${state}. ${with_commas(s.live_orders)} live orders folded in today${dropped}."
	}
}

## A live order at the door: placed today, in a region the shop ships to,
## worth between a cent and the most an order can be.
sale_order : Feed.Sale -> Try(Orders.Order, [UnknownRegion(Str), ValueOutOfRange(U32)])
sale_order = |sale| {
	region = Orders.regions.find_first_index(|name| name == sale.region) ? |_| UnknownRegion(sale.region)
	cents = sale.cents.to_u64()
	if cents == 0 or cents >= Orders.bins * Orders.bin_cents {
		return Err(ValueOutOfRange(sale.cents))
	}
	category = Orders.categories.find_first_index(|c| c == sale.category) ?? crash "Explorer.sale_order: every category is in Orders.categories"
	Ok(Orders.Order.pack({ day: Orders.today, category, region, cents }))
}

## A shard's line: working, how many of its orders match, or why not.
shard_text : Engine.JobState(Orders.Summary, Worker.Error(Explorer.Problem)) -> Str
shard_text = |job| match job {
	Working => "asking…"
	Answered(summary) => "${with_commas(summary.orders)} match"
	Failed(Failed(TooManyOrders)) => "too many orders"
	Failed(Timeout) => "timed out"
	Failed(Refused) => "not asked"
	Failed(Lost(_)) => "worker lost"
}

with_commas : U64 -> Str
with_commas = |n| {
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

pad2 : U64 -> Str
pad2 = |n| if (n < 10) "0${n.to_str()}" else n.to_str()

## Two million orders split into four shards that cover them exactly, each
## asked the same question; a slider's question waits to be asked, and a
## click asks everything the controls show.
expect {
	asked = Explorer.questions(Explorer.initial)
	odd = Explorer.questions({ ..Explorer.initial, size: 10 })
	actual =
		\\shards: ${asked.len().to_str()}
		\\rows: ${Str.inspect(asked.map(|q| q.input.rows))}
		\\numbers: ${Str.inspect(asked.map(|q| q.input.shard))}
		\\odd: ${Str.inspect(odd.map(|q| q.input.rows))}
		\\same question: ${Str.inspect(asked.all(|q| q.query == Orders.everything))}
		\\slid: ${Str.inspect(Explorer.sampling(Explorer.lowest_set(Explorer.initial, "3")))}
		\\asked: ${Str.inspect(Explorer.questions(Explorer.asking(Explorer.lowest_set(Explorer.initial, "3"))).map(|q| q.query.lowest))}
		\\clicked: ${Str.inspect(Explorer.sampling(Explorer.toggled(Explorer.lowest_set(Explorer.initial, "3"), Toys, "false")))}
	expected =
		\\shards: 4
		\\rows: [500000, 500000, 500000, 500000]
		\\numbers: [0, 1, 2, 3]
		\\odd: [2, 2, 2, 4]
		\\same question: True
		\\slid: Waiting
		\\asked: [3, 3, 3, 3]
		\\clicked: Asked
	actual == expected
}

## The controls: categories keep their order, a range end pushes the other,
## and values that are not on the menus change nothing.
expect {
	s = Explorer.initial
	no_toys = Explorer.toggled(s, Toys, "false")
	back = Explorer.toggled(Explorer.toggled(no_toys, Books, "false"), Toys, "true")
	pushed = Explorer.lowest_set({ ..s, highest: 5 }, "9")
	pulled = Explorer.highest_set({ ..s, lowest: 7 }, "3")
	actual =
		\\no toys: ${Str.inspect(no_toys.categories.len())}
		\\back: ${Str.inspect(back.categories)}
		\\pushed: ${pushed.lowest.to_str()} ${pushed.highest.to_str()}
		\\pulled: ${pulled.lowest.to_str()} ${pulled.highest.to_str()}
		\\past the end: ${Str.inspect(Explorer.lowest_set(s, "40").lowest)}
		\\not a size: ${Str.inspect(Explorer.sized(s, "12345").size)}
		\\a size: ${Str.inspect(Explorer.sized(s, "200000").size)}
		\\range: ${Explorer.range_text({ ..s, lowest: 2, highest: 4 })}
	expected =
		\\no toys: 7
		\\back: [Electronics, Fashion, Garden, Grocery, Home, Sports, Toys]
		\\pushed: 9 9
		\\pulled: 3 3
		\\past the end: 0
		\\not a size: 2000000
		\\a size: 200000
		\\range: From $20 to $50
	actual == expected
}

## Live orders are checked at the door: a good batch is folded in, a batch
## with an unknown region or an impossible value is refused whole.
expect {
	s = Explorer.initial
	good = Explorer.received(s, Ok({ sales: [{ category: Toys, region: "Canada", cents: 1999 }, { category: Books, region: "Nordics", cents: 500 }], dropped: 0 }))
	region = Explorer.received(good, Ok({ sales: [{ category: Toys, region: "Mars", cents: 100 }], dropped: 0 }))
	value = Explorer.received(good, Ok({ sales: [{ category: Toys, region: "Canada", cents: 40000 }], dropped: 3 }))
	closed = Explorer.received(good, Err(Closed))
	actual =
		\\good: ${good.live_orders.to_str()} ${Explorer.headline(Orders.summarise_tally(good.live, Orders.everything)).revenue}
		\\region: ${region.live_orders.to_str()} ${region.note}
		\\value: ${value.live_orders.to_str()} ${value.note}
		\\closed: ${Str.inspect(closed.flow)} ${closed.note}
		\\line: ${Explorer.live_text({ ..good, dropped: 12 })}
	expected =
		\\good: 2 $25
		\\region: 2 A batch of live orders was refused: no region is called "Mars".
		\\value: 2 A batch of live orders was refused: an order worth 40000 cents is outside $0.01 to $399.99.
		\\closed: Paused The live feed closed.
		\\line: Live: 200 orders a second. 2 live orders folded in today, 12 dropped by the feed.
	actual == expected
}
