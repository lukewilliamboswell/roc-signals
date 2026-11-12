import pf.Engine exposing [Val]
import pf.Port
import pf.Worker
import Feed
import Orders

## The Million-Row Explorer's tasks, its store, and every decision the view
## makes, pure so that `expect`s and specs reach them.
##
## The database is split into four shards. Each shard is a preparation
## whose input is only its seed, its number and its size, so its orders are
## generated inside a worker and never cross to the page. A question (the
## categories and the value range) is asked of every shard at once with
## `Worker.gather`; each answer is a few kilobytes of counts, which the page
## adds together, with the live orders it has folded in, and draws.
##
## The page's state is a store, held at the root and read wherever it is
## drawn:
##
## - `shown`: the question the controls show (categories and a value range
##   in whole bins).
## - `asked`: the question asked of the shards, which a slider being
##   dragged may be ahead of.
## - `flow` and `rate`: the live feed's switch and its pace.
## - `live`: what the feed has delivered, folded into a fixed-size tally.
## - `note`: what the page says when something it was sent was refused.
##
## The database's size is not state: the address chooses it before the
## page mounts and it never changes (`Setup`).
Explorer := [Shop].{

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

	## The sizes the page links to, in orders. The size is part of the
	## address (`?orders=200000`), so a size can be shared, and choosing one
	## loads the page afresh.
	sizes : List(U64)
	sizes = [200000, 2000000, 8000000]

	## The size without `?orders=` in the address.
	default_size : U64
	default_size = 2000000

	## The sizes the address may ask for, from a few orders a shard to what
	## four workers keep comfortably.
	smallest : U64
	smallest = 1000

	largest : U64
	largest = 8000000

	## The size the address asks for, read at the door: none, a size in
	## range, or text that is not one.
	size_of_url : Str -> [Unasked, Size(U64), NotASize(Str)]
	size_of_url = |url| match query_value(url, "orders") {
		Err(NotInAddress) => Unasked
		Ok(text) =>
			match U64.from_str(text) {
				Ok(size) if size >= Explorer.smallest and size <= Explorer.largest => Size(size)
				_ => NotASize(text)
			}
	}

	## What the address chose before the page mounted: the database's size,
	## the live feed paused when it says `feed=paused` (a page to share, or
	## a test that must return to where it started), and a note when the
	## size it asked for is not one the page can generate.
	Setup : { size : U64, flow : Flow, note : Str }

	## The setup an address names.
	setup_of : Str -> Setup
	setup_of = |url| {
		flow = if (query_value(url, "feed") == Ok("paused")) Paused else Live
		match Explorer.size_of_url(url) {
			Unasked => { size: Explorer.default_size, flow, note: "" }
			Size(size) => { size, flow, note: "" }
			NotASize(text) => { size: Explorer.default_size, flow, note: "\"${text}\" is not a number of orders this page can generate (from ${with_commas(Explorer.smallest)} to ${with_commas(Explorer.largest)}): showing ${with_commas(Explorer.default_size)}." }
		}
	}

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

	## What the live feed has delivered: its orders folded into a tally,
	## how many there were, and how many the feed last said it dropped.
	LiveOrders : { tally : Orders.Tally, orders : U64, dropped : U32 }

	store = Engine.store(
		Explorer.Shop,
		{
			shown: Engine.cell(Orders.everything),
			asked: Engine.cell(Orders.everything),
			flow: Engine.cell(Live),
			rate: Engine.cell(200.U32),
			live: Engine.cell({ tally: Orders.no_orders, orders: 0, dropped: 0 }),
			note: Engine.cell(""),
		}.Engine.Cells,
	)

	## The handles on the store's cells.
	h = Explorer.store.handles()

	## The store a page starts with, for the setup its address chose.
	start : Setup -> Engine.Store(_, _)
	start = |setup| Explorer.store
		.with_initial(Explorer.h.flow, setup.flow)
		.with_initial(Explorer.h.note, setup.note)

	## The question the controls show beside the one asked of the shards.
	question : {} -> Val(ctx, { shown : Orders.Filter, asked : Orders.Filter })
		where [ctx.store : () -> Engine.Reach(ctx, _)]
	question = |{}| { shown: Explorer.h.shown.val(), asked: Explorer.h.asked.val() }.Val

	## Whether the shards have been asked what the controls show.
	sampling : { shown : Orders.Filter, asked : Orders.Filter } -> Sampling
	sampling = |{ shown, asked }| if (shown == asked) Asked else Waiting

	## One question per shard of a database of `size` orders: equal shards,
	## the last taking the remainder.
	questions : U64, Orders.Filter -> List(Worker.Question(Orders.Shard, Orders.Filter))
	questions = |size, asked| {
		share = size // Explorer.shards
		var $out = []
		for i in 0..<Explorer.shards {
			rows = if (i + 1 == Explorer.shards) size - share * i else share
			$out = $out.append({ input: { seed: Explorer.seed, shard: i, rows }, query: asked })
		}
		$out
	}

	## A category's box was ticked (`"true"`) or cleared while the controls
	## showed `shown`: the question changes and is asked at once, with
	## whatever a slider still had waiting. The categories stay in their
	## fixed order, so the same choice is the same question.
	ticked : Orders.Filter, Orders.Category, Str -> List(Engine.Write(_))
	ticked = |shown, category, checked| {
		next = { ..shown, categories: Orders.categories.keep_if(|c| if (c == category) checked == "true" else shown.categories.contains(c)) }
		[Explorer.h.shown.put(next), Explorer.h.asked.put(next)]
	}

	## An end of the value range.
	End : [Lowest, Highest]

	## A slider moved an end of the value range to a bin, as the slider
	## sends it. An end moved past the other takes the other with it. Only
	## the controls change: the question waits for the sampling timer
	## (`sample_ms`).
	slid : End, Str -> List(Engine.Write(_))
	slid = |which, text| [
		Explorer.h.shown.change(
			|shown| match (which, U64.from_str(text)) {
				(Lowest, Ok(bin)) if bin < Orders.bins => { ..shown, lowest: bin, highest: shown.highest.max(bin) }
				(Highest, Ok(bin)) if bin < Orders.bins => { ..shown, highest: bin, lowest: shown.lowest.min(bin) }
				_ => shown
			},
		),
	]

	## The sampling timer fired while the controls showed `shown`: the
	## shards are asked it.
	sampled : Orders.Filter -> List(Engine.Write(_))
	sampled = |shown| [Explorer.h.asked.put(shown)]

	## A pace from the menu; anything else is ignored.
	paced : Str -> List(Engine.Write(_))
	paced = |text| match U32.from_str(text) {
		Ok(rate) if Explorer.rates.contains(rate) => [Explorer.h.rate.put(rate)]
		_ => []
	}

	## The live feed switched on (`"true"`) or off.
	switched : Str -> List(Engine.Write(_))
	switched = |checked| [Explorer.h.flow.put(if (checked == "true") Live else Paused)]

	## A message of the live feed. A batch is checked at the door: an order
	## with a region the shop does not ship to, or a value outside what an
	## order can be, refuses the whole batch, and the note says which. A
	## good batch is folded into the tally where it is held.
	received : Try(Feed.Batch, Port.Error) -> List(Engine.Write(_))
	received = |message| {
		noted = |text| [Explorer.h.note.put(text)]
		match message {
			Ok(batch) =>
				match batch.sales.map_try(sale_order) {
					Ok(orders) => [Explorer.h.live.change(|live| { tally: Orders.tally(live.tally, orders), orders: live.orders + orders.len(), dropped: batch.dropped })]
					Err(UnknownRegion(region)) => noted("A batch of live orders was refused: no region is called \"${region}\".")
					Err(ValueOutOfRange(cents)) => noted("A batch of live orders was refused: an order worth ${cents.to_str()} cents is outside $0.01 to $399.99.")
				}
			Err(Closed) => [Explorer.h.flow.put(Paused)].concat(noted("The live feed closed."))
			Err(Threw(why)) => [Explorer.h.flow.put(Paused)].concat(noted("The live feed failed: ${why}"))
			Err(Undecodable(why)) => noted("A batch of live orders was not understood: ${why}")
			Err(TooLarge) => noted("A batch of live orders was too large to take.")
			Err(Refused) | Err(Timeout) => noted("The live feed could not start: too many requests at once.")
		}
	}

	## What the shards' answers are added to and judged against: the
	## database's size, the live orders and the question asked.
	Answering : { size : U64, live : LiveOrders, asked : Orders.Filter }

	## What a board is drawn from, for a database of `size` orders.
	answering : U64 -> Val(ctx, Answering)
		where [ctx.store : () -> Engine.Reach(ctx, _)]
	answering = |size| Explorer.h.live.val().map2(Explorer.h.asked.val(), |live, asked| { size, live, asked })

	## What the page shows: the shards' last complete answer added to the
	## live orders, the question it shows, and how far the current question
	## has got.
	Board : {
		summary : Orders.Summary,
		filter : Orders.Filter,
		status : Str,
		shards : List(Str),
	}

	## The board for the shards' answers to the question asked of them
	## (which a slider being dragged may be ahead of). While a question is
	## being answered the charts keep the last complete answer: a sum of
	## some shards' answers would be a wrong total, not a partial one. A
	## failed question has no answer to keep (the gather keeps none past a
	## failure), so the history is empty until the next question is
	## answered, and the status says so. The live orders always follow the
	## current question.
	board : Answering, Engine.Gathered(Orders.Summary, Worker.Error(Problem)) -> Board
	board = |{ size, live, asked }, gathered| {
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
			Working if history.is_empty() => "Generating ${with_commas(size)} orders in ${Explorer.shards.to_str()} workers… ${answered.to_str()} of ${Explorer.shards.to_str()} shards ready."
			Working => "Asking ${Explorer.shards.to_str()} shards… ${answered.to_str()} answered; the charts show the last complete answer."
			Answered(_) => "${Explorer.shards.to_str()} of ${Explorer.shards.to_str()} shards answered."
			Failed(TooManyOrders) => "A shard was asked to hold more orders than a worker keeps.${unanswered}"
			Timeout => "A shard took too long to answer.${unanswered}"
			Refused => "Too many requests at once: a shard was not asked.${unanswered}"
			Lost(fault) => "A shard's worker stopped (${Str.inspect(fault)}).${unanswered}"
		}
		{
			summary: Orders.merge(history.append(Orders.summarise_tally(live.tally, asked))),
			filter: asked,
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
	range_text : Orders.Filter -> Str
	range_text = |shown| "From $${(shown.lowest * Orders.bin_cents // 100).to_str()} to $${((shown.highest + 1) * Orders.bin_cents // 100).to_str()}"

	## The live feed's line.
	live_text : { flow : Flow, rate : U32, live : LiveOrders } -> Str
	live_text = |{ flow, rate, live }| {
		state = match flow {
			Live => "Live: ${with_commas(rate.to_u64())} orders a second"
			Paused => "Paused"
		}
		dropped = if (live.dropped == 0) "" else ", ${with_commas(live.dropped.to_u64())} dropped by the feed"
		"${state}. ${with_commas(live.orders)} live orders folded in today${dropped}."
	}
}

## The value of `name` in the address's query (`?name=value&…`).
query_value : Str, Str -> Try(Str, [NotInAddress])
query_value = |url, name| {
	before_hash = url.split_on("#").first() ?? ""
	query = before_hash.split_on("?").drop_first(1).first() ?? ""
	match query.split_on("&").find_first(|part| part.starts_with("${name}=")) {
		Ok(part) => Ok(part.drop_prefix("${name}="))
		Err(_) => Err(NotInAddress)
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

## The question a store shows beside the one it has asked of the shards.
question_in : Engine.Store(_, _) -> { shown : Orders.Filter, asked : Orders.Filter }
question_in = |store| { shown: store.read(Explorer.h.shown), asked: store.read(Explorer.h.asked) }

## Two million orders split into four shards that cover them exactly, each
## asked the same question; a slider's question waits to be asked, and a
## click asks everything the controls show.
expect {
	asked = Explorer.questions(Explorer.default_size, Orders.everything)
	odd = Explorer.questions(10, Orders.everything)
	slid = Explorer.store.after(Explorer.slid(Lowest, "3"))
	sampled = slid.after(Explorer.sampled(slid.read(Explorer.h.shown)))
	clicked = slid.after(Explorer.ticked(slid.read(Explorer.h.shown), Toys, "false"))
	actual =
		\\shards: ${asked.len().to_str()}
		\\rows: ${Str.inspect(asked.map(|q| q.input.rows))}
		\\numbers: ${Str.inspect(asked.map(|q| q.input.shard))}
		\\odd: ${Str.inspect(odd.map(|q| q.input.rows))}
		\\same question: ${Str.inspect(asked.all(|q| q.query == Orders.everything))}
		\\slid: ${Str.inspect(Explorer.sampling(question_in(slid)))}, asked from ${slid.read(Explorer.h.asked).lowest.to_str()}
		\\sampled: ${Str.inspect(Explorer.sampling(question_in(sampled)))}, asked from ${sampled.read(Explorer.h.asked).lowest.to_str()}
		\\clicked: ${Str.inspect(Explorer.sampling(question_in(clicked)))}, asked from ${clicked.read(Explorer.h.asked).lowest.to_str()}
	expected =
		\\shards: 4
		\\rows: [500000, 500000, 500000, 500000]
		\\numbers: [0, 1, 2, 3]
		\\odd: [2, 2, 2, 4]
		\\same question: True
		\\slid: Waiting, asked from 0
		\\sampled: Asked, asked from 3
		\\clicked: Asked, asked from 3
	actual == expected
}

## The controls: categories keep their order, a range end pushes the other,
## and the address's size and the feed's switch are read at the door.
expect {
	shown_after = |store, writes| store.after(writes).read(Explorer.h.shown)
	no_toys = Explorer.store.after(Explorer.ticked(Orders.everything, Toys, "false"))
	no_books = no_toys.after(Explorer.ticked(no_toys.read(Explorer.h.shown), Books, "false"))
	back = shown_after(no_books, Explorer.ticked(no_books.read(Explorer.h.shown), Toys, "true"))
	pushed = shown_after(Explorer.store.with_initial(Explorer.h.shown, { ..Orders.everything, highest: 5 }), Explorer.slid(Lowest, "9"))
	pulled = shown_after(Explorer.store.with_initial(Explorer.h.shown, { ..Orders.everything, lowest: 7 }), Explorer.slid(Highest, "3"))
	actual =
		\\no toys: ${Str.inspect(no_toys.read(Explorer.h.shown).categories.len())}
		\\back: ${Str.inspect(back.categories)}
		\\pushed: ${pushed.lowest.to_str()} ${pushed.highest.to_str()}
		\\pulled: ${pulled.lowest.to_str()} ${pulled.highest.to_str()}
		\\past the end: ${Str.inspect(shown_after(Explorer.store, Explorer.slid(Lowest, "40")).lowest)}
		\\no size: ${Str.inspect(Explorer.setup_of("/examples/x/#/").size)}
		\\a size: ${Str.inspect(Explorer.setup_of("/x/?a=1&orders=200000#y").size)}
		\\not a size: ${Str.inspect(Explorer.size_of_url("/?orders=9000000"))} ${Str.inspect(Explorer.size_of_url("/?orders=lots"))}
		\\note: ${Explorer.setup_of("/?orders=12").note}
		\\paused: ${Str.inspect(Explorer.setup_of("/?orders=4000&feed=paused#/").flow)} ${Str.inspect(Explorer.setup_of("/?feed=on").flow)}
		\\started: ${Str.inspect(Explorer.start(Explorer.setup_of("/?feed=paused")).read(Explorer.h.flow))}
		\\range: ${Explorer.range_text({ ..Orders.everything, lowest: 2, highest: 4 })}
	expected =
		\\no toys: 7
		\\back: [Electronics, Fashion, Garden, Grocery, Home, Sports, Toys]
		\\pushed: 9 9
		\\pulled: 3 3
		\\past the end: 0
		\\no size: 2000000
		\\a size: 200000
		\\not a size: NotASize("9000000") NotASize("lots")
		\\note: "12" is not a number of orders this page can generate (from 1,000 to 8,000,000): showing 2,000,000.
		\\paused: Paused Live
		\\started: Paused
		\\range: From $20 to $50
	actual == expected
}

## Live orders are checked at the door: a good batch is folded in, a batch
## with an unknown region or an impossible value is refused whole, and a
## feed that closes pauses the switch.
expect {
	good = Explorer.store.after(Explorer.received(Ok({ sales: [{ category: Toys, region: "Canada", cents: 1999 }, { category: Books, region: "Nordics", cents: 500 }], dropped: 0 })))
	region = good.after(Explorer.received(Ok({ sales: [{ category: Toys, region: "Mars", cents: 100 }], dropped: 0 })))
	value = good.after(Explorer.received(Ok({ sales: [{ category: Toys, region: "Canada", cents: 40000 }], dropped: 3 })))
	closed = good.after(Explorer.received(Err(Closed)))
	behind = good.after(Explorer.received(Ok({ sales: [], dropped: 12 })))
	orders_in = |store| store.read(Explorer.h.live).orders.to_str()
	actual =
		\\good: ${orders_in(good)} ${Explorer.headline(Orders.summarise_tally(good.read(Explorer.h.live).tally, Orders.everything)).revenue}
		\\region: ${orders_in(region)} ${region.read(Explorer.h.note)}
		\\value: ${orders_in(value)} ${value.read(Explorer.h.note)}
		\\closed: ${Str.inspect(closed.read(Explorer.h.flow))} ${closed.read(Explorer.h.note)}
		\\line: ${Explorer.live_text({ flow: behind.read(Explorer.h.flow), rate: behind.read(Explorer.h.rate), live: behind.read(Explorer.h.live) })}
	expected =
		\\good: 2 $25
		\\region: 2 A batch of live orders was refused: no region is called "Mars".
		\\value: 2 A batch of live orders was refused: an order worth 40000 cents is outside $0.01 to $399.99.
		\\closed: Paused The live feed closed.
		\\line: Live: 200 orders a second. 2 live orders folded in today, 12 dropped by the feed.
	actual == expected
}
