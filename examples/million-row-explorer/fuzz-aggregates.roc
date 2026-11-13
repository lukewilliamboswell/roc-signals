app [target] {
	fz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.6.1/GDoZFRDnzMRiVk9nE8wdWn52btGsM1GhcY9VDKqy9f1Y.tar.zst",
}

import fz.Fuzz
import Orders

## The explorer's aggregates against a model that reads every order as a
## plain record. In the app a shard's orders are packed into one `U32`
## each, summarised in one pass, the shards' answers are added together,
## and the live orders are folded into a fixed-size tally that answers by
## value bin; the bugs to fear are in the packing, in a filter's edges (the
## value range's ends, a category left out), in adding answers, and in the
## tally's cell arithmetic.
##
## Each input decodes into a database (a seed and up to four shards of up
## to 255 orders), a question (a set of categories and a value range), and
## live batches of up to 255 orders, and orders of any value and place
## the feed may send, as the door packs them. Its properties:
##
## - every generated order unpacks to a day of the history, a category, a
##   region the shop ships to and a value between $1 and $399.99, and live
##   orders are all placed today;
## - each shard's summary is what the model counts from its orders;
## - the merged shards' answers are the model's counts of every order;
## - the live tally, folded batch by batch, answers the question as the
##   model counts the live orders, and its answer merged with the shards'
##   is the model's count of all of them together.
Input : { seed : U64, shards : List(U8), categories : U8, lowest : U8, highest : U8, batches : List(U8), sent : List(U64) }

## An order as the model reads it.
Plain : { day : U64, category : U64, region : U64, cents : U64 }

plain : Orders.Order -> Plain
plain = |order| { day: order.day(), category: order.category(), region: order.region(), cents: order.cents() }

## The question an input asks: the categories its bits pick, and a range
## of bins whose ends may come in either order.
question : Input -> Orders.Filter
question = |input| {
	low = input.lowest.to_u64() % Orders.bins
	high = input.highest.to_u64() % Orders.bins
	{
		categories: index_list(Orders.categories).keep_if(|(i, _)| input.categories.to_u64().shr_zf_wrap(i.to_u8_wrap()).bitwise_and(1) == 1).map(|(_, c)| c),
		lowest: low.min(high),
		highest: low.max(high),
	}
}

index_list : List(a) -> List((U64, a))
index_list = |items| items.map_with_index(|item, i| (i, item))

## The model: each count by filtering the plain orders, one count at a time.
model : List(Plain), Orders.Filter -> Orders.Summary
model = |orders, filter| {
	chosen = index_list(Orders.categories).keep_if(|(_, c)| filter.categories.contains(c)).map(|(i, _)| i)
	of_chosen = orders.keep_if(|o| chosen.contains(o.category))
	inside = of_chosen.keep_if(|o| o.cents // Orders.bin_cents >= filter.lowest and o.cents // Orders.bin_cents <= filter.highest)
	revenue = |keep| inside.keep_if(keep).map(|o| o.cents).sum()
	{
		orders: inside.len(),
		revenue: revenue(|_| Bool.True),
		per_day: List.from_iter((0.U64..<(Orders.history_days + 1)).iter()).map(|d| inside.count_if(|o| o.day == d)),
		histogram: List.from_iter((0.U64..<Orders.bins).iter()).map(|b| of_chosen.count_if(|o| o.cents // Orders.bin_cents == b)),
		by_category: List.from_iter((0.U64..<Orders.categories.len()).iter()).map(|c| revenue(|o| o.category == c)),
		by_region: List.from_iter((0.U64..<Orders.regions.len()).iter()).map(|r| revenue(|o| o.region == r)),
	}
}

## Where an order breaks the packing's rules, if anywhere.
out_of_range : Plain, [History, Today] -> Try({}, Str)
out_of_range = |o, placed| {
	day_ok = match placed {
		History => o.day < Orders.history_days
		Today => o.day == Orders.today
	}
	if day_ok and o.category < Orders.categories.len() and o.region < Orders.regions.len() and o.cents >= 100 and o.cents < Orders.bins * Orders.bin_cents {
		Ok({})
	} else {
		Err("an order out of range: ${Str.inspect(o)} (${Str.inspect(placed)})")
	}
}

check : Input -> Try({}, Str)
check = |input| {
	filter = question(input)
	shards = input.shards.take_first(4).map_with_index(|rows, i| Orders.generate({ seed: input.seed, shard: i, rows: rows.to_u64() }))
	every = shards.join().map(plain)
	for o in every {
		out_of_range(o, History)?
	}
	answers = shards.map(|orders| Orders.summarise(orders, filter))
	for (orders, answer) in List.map2(shards, answers, |orders, answer| (orders, answer)) {
		if answer != model(orders.map(plain), filter) {
			return Err("a shard's summary is not the model's for ${Str.inspect(filter)}")
		}
	}
	if Orders.merge(answers) != model(every, filter) {
		return Err("the merged answers are not the model's count of every order")
	}
	var $state = input.seed
	var $tally = Orders.no_orders
	var $live = []
	for count in input.batches.take_first(8) {
		batch = Orders.live($state, count.to_u64())
		$state = batch.state
		$tally = Orders.tally($tally, batch.orders)
		$live = $live.concat(batch.orders.map(plain))
	}
	# Orders the feed sent: any category, region and value the door lets in.
	sent = input.sent.take_first(64).map(
		|word| Orders.Order.pack({
			day: Orders.today,
			category: word % Orders.categories.len(),
			region: (word // 8) % Orders.regions.len(),
			cents: 1 + (word // 96) % (Orders.bins * Orders.bin_cents - 1),
		}),
	)
	$tally = Orders.tally($tally, sent)
	$live = $live.concat(sent.map(plain))
	for o in $live {
		day_ok = o.day == Orders.today and o.category < Orders.categories.len() and o.region < Orders.regions.len()
		if !day_ok {
			return Err("a live order out of range: ${Str.inspect(o)}")
		}
	}
	if Orders.summarise_tally($tally, filter) != model($live, filter) {
		return Err("the live tally's answer is not the model's count of the live orders")
	}
	if Orders.merge(answers.append(Orders.summarise_tally($tally, filter))) != model(every.concat($live), filter) {
		return Err("the shards and the live tally together are not the model's count of all the orders")
	}
	Ok({})
}

test! : Input => Fuzz.Outcome
test! = |input| match check(input) {
	Ok({}) => Fuzz.keep
	Err(problem) => crash problem
}

ex : Str, Input -> Fuzz.Example(Input)
ex = |name, input| Fuzz.example({ name, revision: "1", make: || input })

target = Fuzz.target_with!({
	name: "million-row-explorer-aggregates",
	examples: [
		ex("everything", { seed: 2026, shards: [200, 150, 255, 1], categories: 255, lowest: 0, highest: 39, batches: [40, 3], sent: [0, 95, 96 * 39998 + 7, 96 * 38999 + 90] }),
		ex("one-bin", { seed: 7, shards: [255, 255], categories: 255, lowest: 4, highest: 4, batches: [255], sent: [] }),
		ex("reversed-range", { seed: 1, shards: [100, 100, 100, 100], categories: 0b10100101, lowest: 30, highest: 2, batches: [10, 0, 10], sent: [5, 96 * 3000 + 11] }),
		ex("no-categories", { seed: 3, shards: [50], categories: 0, lowest: 0, highest: 39, batches: [9], sent: [1, 2, 3] }),
		ex("empty", { seed: 0, shards: [], categories: 255, lowest: 0, highest: 39, batches: [], sent: [] }),
	],
	generator: { seed: Fuzz.u64, shards: Fuzz.list(Fuzz.u8, 4), categories: Fuzz.u8, lowest: Fuzz.u8, highest: Fuzz.u8, batches: Fuzz.list(Fuzz.u8, 8), sent: Fuzz.list(Fuzz.u64, 64) }.Fuzz,
	test!,
	show: Str.inspect,
})
