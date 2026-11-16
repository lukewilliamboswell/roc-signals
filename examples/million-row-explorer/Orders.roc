## The orders database the explorer asks questions of: a year of a shop's
## orders, generated from a seed, so the same shard is always the same rows.
## Everything here is pure; the worker calls `generate` to prepare a shard
## and `summarise` to answer a question of it, and the page calls `merge`
## to add the shards' answers and the live orders together.
##
## An order is four facts: the day it was placed, its category, the region
## it ships to and its value. A shard keeps them packed into one `U32` an
## order (`Order`), so two million orders take 8 MB across the workers and
## a question reads one list from start to end.
Orders := [].{

	## What a shop sells.
	Category : [Books, Electronics, Fashion, Garden, Grocery, Home, Sports, Toys]

	## Every category, in the order the charts and the answers list them.
	categories : List(Category)
	categories = [Books, Electronics, Fashion, Garden, Grocery, Home, Sports, Toys]

	category_name : Category -> Str
	category_name = |category| match category {
		Books => "Books"
		Electronics => "Electronics"
		Fashion => "Fashion"
		Garden => "Garden"
		Grocery => "Grocery"
		Home => "Home"
		Sports => "Sports"
		Toys => "Toys"
	}

	## Where orders ship to, in the order the answers list them.
	regions : List(Str)
	regions = ["Northeast", "Southeast", "Midwest", "Southwest", "Mountain", "Pacific", "Canada", "Mexico", "United Kingdom", "Germany", "Nordics", "Australia"]

	## Days of history in every shard; the live feed's orders are placed on
	## the day after them, `today`.
	history_days : U64
	history_days = 365

	## The day the live feed places its orders on.
	today : U64
	today = 365

	## The value histogram's bins: `bin_cents` wide, from $0 to the most an
	## order can be worth.
	bin_cents : U64
	bin_cents = 1000

	bins : U64
	bins = 40

	## What one shard is: the database's seed, which shard of it, and how
	## many orders it holds. This is all that crosses to the worker; the
	## orders themselves are generated there and never leave it.
	Shard : { seed : U64, shard : U64, rows : U64 }

	## One order, packed: the day in the top 9 bits, the category and the
	## region in the next 7, and the value in cents in the low 16.
	Order :: U32.{
		is_eq : _

		pack : { day : U64, category : U64, region : U64, cents : U64 } -> Order
		pack = |{ day: order_day, category: order_category, region: order_region, cents: order_cents }| Order.(order_day.shl_wrap(23).bitwise_or(order_category.shl_wrap(20)).bitwise_or(order_region.shl_wrap(16)).bitwise_or(order_cents).to_u32_wrap())

		day : Order -> U64
		day = |Order.(word)| word.shr_zf_wrap(23).to_u64()

		category : Order -> U64
		category = |Order.(word)| word.shr_zf_wrap(20).bitwise_and(7).to_u64()

		region : Order -> U64
		region = |Order.(word)| word.shr_zf_wrap(16).bitwise_and(15).to_u64()

		cents : Order -> U64
		cents = |Order.(word)| word.bitwise_and(65535).to_u64()
	}

	## A question: the categories to count and the range of value bins
	## (from `lowest` to `highest`, both included). The value histogram
	## counts every bin of the chosen categories, so it can show where the
	## range sits; everything else counts only the orders inside the range.
	Filter : { categories : List(Category), lowest : U64, highest : U64 }

	## Every order.
	everything : Filter
	everything = { categories: Orders.categories, lowest: 0, highest: Orders.bins - 1 }

	## An answer: the orders and revenue (in cents) inside the filter, per
	## day, per category and per region, and the value histogram of the
	## chosen categories. A few kilobytes, whatever the number of orders.
	Summary : {
		orders : U64,
		revenue : U64,
		per_day : List(U64),
		histogram : List(U64),
		by_category : List(U64),
		by_region : List(U64),
	}

	## The answer of no orders at all.
	empty : Summary
	empty = {
		orders: 0,
		revenue: 0,
		per_day: List.repeat(0, Orders.history_days + 1),
		histogram: List.repeat(0, Orders.bins),
		by_category: List.repeat(0, Orders.categories.len()),
		by_region: List.repeat(0, Orders.regions.len()),
	}

	## Generate a shard's orders. Each shard has a random stream of its own,
	## started from the seed and the shard's number, so any shard can be
	## made alone, in any worker, and is the same every time.
	generate : Shard -> List(Order)
	generate = |{ seed, shard, rows }| {
		var $state = mix(seed.bitwise_xor(mix(shard)))
		var $orders = List.with_capacity(rows)
		var $left = rows
		while $left > 0 {
			$state = $state.plus_wrap(golden)
			first = mix($state)
			$state = $state.plus_wrap(golden)
			second = mix($state)
			$orders = $orders.append(order_from({ first, second, day: Generated }))
			$left = $left - 1
		}
		$orders
	}

	## A batch of the live feed's orders, placed today: `count` orders from
	## the feed's random state, and the state after them. The page's own
	## JavaScript makes the feed in the browser; this is the same rule, for
	## the tests and the fuzz target.
	live : U64, U64 -> { orders : List(Order), state : U64 }
	live = |state, count| {
		var $state = state
		var $orders = []
		for _order in 0..<count {
			$state = $state.plus_wrap(golden)
			first = mix($state)
			$state = $state.plus_wrap(golden)
			second = mix($state)
			$orders = $orders.append(order_from({ first, second, day: Today }))
		}
		{ orders: $orders, state: $state }
	}

	## Count the orders a filter keeps. One pass over the list, with no
	## allocation beyond the answer's lists.
	summarise : List(Order), Filter -> Summary
	summarise = |orders, filter| {
		chosen = filter.categories.fold(0.U64, |mask, category| mask.bitwise_or((1.U64).shl_wrap(index_of(category).to_u8_wrap())))
		var $orders = 0
		var $revenue = 0
		var $per_day = List.repeat(0, Orders.history_days + 1)
		var $histogram = List.repeat(0, Orders.bins)
		var $by_category = List.repeat(0, Orders.categories.len())
		var $by_region = List.repeat(0, Orders.regions.len())
		for order in orders {
			category = order.category()
			if chosen.shr_zf_wrap(category.to_u8_wrap()).bitwise_and(1) == 1 {
				cents = order.cents()
				bin = cents // Orders.bin_cents
				$histogram = add_at($histogram, bin, 1)
				if bin >= filter.lowest and bin <= filter.highest {
					day = order.day()
					region = order.region()
					$orders = $orders + 1
					$revenue = $revenue + cents
					$per_day = add_at($per_day, day, 1)
					$by_category = add_at($by_category, category, cents)
					$by_region = add_at($by_region, region, cents)
				}
			}
		}
		{ orders: $orders, revenue: $revenue, per_day: $per_day, histogram: $histogram, by_category: $by_category, by_region: $by_region }
	}

	## The live orders the page has folded in, as counts and revenue per
	## category, region and value bin. Its size is fixed (3,840 cells of
	## each), however long the feed runs, and it answers any filter exactly,
	## because a filter's value range moves in whole bins.
	Tally : { orders : List(U64), cents : List(U64) }

	## A tally of no orders.
	no_orders : Tally
	no_orders = { orders: List.repeat(0, cells), cents: List.repeat(0, cells) }

	## Fold orders into a tally: work in proportion to the orders, not to
	## the tally.
	tally : Tally, List(Order) -> Tally
	tally = |counted, orders| {
		var $orders = counted.orders
		var $cents = counted.cents
		for order in orders {
			cell = cell_of({ category: order.category(), region: order.region(), bin: order.cents() // Orders.bin_cents })
			$orders = add_at($orders, cell, 1)
			$cents = add_at($cents, cell, order.cents())
		}
		{ orders: $orders, cents: $cents }
	}

	## A tally's answer to a filter: what `summarise` gives for the same
	## orders, every one of them placed `today`.
	summarise_tally : Tally, Filter -> Summary
	summarise_tally = |counted, filter| {
		var $s = Orders.empty
		for category in Orders.categories.keep_if(|category| filter.categories.contains(category)) {
			c = index_of(category)
			for region in 0..<Orders.regions.len() {
				for bin in 0..<Orders.bins {
					cell = cell_of({ category: c, region, bin })
					count = counted.orders.get(cell) ?? 0
					if count > 0 {
						$s = { ..$s, histogram: add_at($s.histogram, bin, count) }
						if bin >= filter.lowest and bin <= filter.highest {
							cents = counted.cents.get(cell) ?? 0
							$s = {
								orders: $s.orders + count,
								revenue: $s.revenue + cents,
								per_day: add_at($s.per_day, Orders.today, count),
								histogram: $s.histogram,
								by_category: add_at($s.by_category, c, cents),
								by_region: add_at($s.by_region, region, cents),
							}
						}
					}
				}
			}
		}
		$s
	}

	## Add answers together: the shards' answers, and the live orders'.
	merge : List(Summary) -> Summary
	merge = |summaries| summaries.fold(
		Orders.empty,
		|total, s| {
			orders: total.orders + s.orders,
			revenue: total.revenue + s.revenue,
			per_day: add_lists(total.per_day, s.per_day),
			histogram: add_lists(total.histogram, s.histogram),
			by_category: add_lists(total.by_category, s.by_category),
			by_region: add_lists(total.by_region, s.by_region),
		},
	)
}

## Where the generator places an order: on a day of the year's history, or
## today.
Placed : [Generated, Today]

## An order from two random words: the category and region first, then a day
## that follows the category's season and the shop's growth, then a value
## around the category's typical price.
order_from : { first : U64, second : U64, day : Placed } -> Orders.Order
order_from = |{ first, second, day }| {
	category = pick(category_weights, first.bitwise_and(1023))
	region = pick(region_weights, first.shr_zf_wrap(10).bitwise_and(1023))
	placed = match day {
		Today => Orders.today
		Generated => season_day({ category, a: first.shr_zf_wrap(20).bitwise_and(65535), b: first.shr_zf_wrap(36).bitwise_and(65535), choice: first.shr_zf_wrap(52).bitwise_and(1023) })
	}
	price = prices.get(category) ?? { centre: 5000, spread: 3000 }
	# Three uniform draws summed: a bell around the centre.
	spread_draw = second.bitwise_and(1023) + second.shr_zf_wrap(10).bitwise_and(1023) + second.shr_zf_wrap(20).bitwise_and(1023)
	offset = (price.spread * spread_draw) // 1534
	raw = price.centre + offset
	low = price.spread
	cents = (if (raw > low) raw - low else 100).max(100).min(Orders.bins * Orders.bin_cents - 1)
	Orders.Order.pack({ day: placed, category, region, cents })
}

## The day of an order of `category`: some orders cluster around the
## category's peak (Garden in spring, Toys before the holidays), some follow
## the shop's growth through the year, and the rest are spread evenly.
season_day : { category : U64, a : U64, b : U64, choice : U64 } -> U64
season_day = |{ category, a, b, choice }| {
	year = Orders.history_days
	season = seasons.get(category) ?? { peak: 180, share: 100 }
	if choice < season.share {
		# A triangle 60 days wide around the peak.
		offset = (a * 30) // 65536 + (b * 30) // 65536
		(season.peak + year + offset - 30) % year
	} else if choice < season.share + 300 {
		# Growth: the later of two days is more likely late in the year.
		(a.max(b) * year) // 65536
	} else {
		(a * year) // 65536
	}
}

## Each category's typical value and how far values stray from it, in cents.
prices : List({ centre : U64, spread : U64 })
prices = [
	{ centre: 1800, spread: 900 },
	{ centre: 21000, spread: 12000 },
	{ centre: 7000, spread: 4000 },
	{ centre: 5500, spread: 3500 },
	{ centre: 3800, spread: 1800 },
	{ centre: 11000, spread: 6000 },
	{ centre: 8500, spread: 5000 },
	{ centre: 3200, spread: 2000 },
]

## Each category's peak day (0 is the first day of the history) and how
## many of 1024 orders cluster around it.
seasons : List({ peak : U64, share : U64 })
seasons = [
	{ peak: 250, share: 120 },
	{ peak: 330, share: 300 },
	{ peak: 100, share: 160 },
	{ peak: 150, share: 520 },
	{ peak: 0, share: 40 },
	{ peak: 300, share: 140 },
	{ peak: 200, share: 220 },
	{ peak: 340, share: 560 },
]

## How many of 1024 orders fall in each category and each region.
category_weights : List(U64)
category_weights = [140, 120, 170, 90, 210, 110, 90, 94]

region_weights : List(U64)
region_weights = [150, 120, 130, 100, 60, 160, 70, 40, 70, 50, 34, 40]

## The index a number below 1024 falls on, given weights that add to 1024.
pick : List(U64), U64 -> U64
pick = |weights, at| {
	var $left = at
	var $index = 0
	for weight in weights {
		if $left < weight {
			return $index
		}
		$left = $left - weight
		$index = $index + 1
	}
	crash "Orders.pick: ${at.to_str()} is not below the weights' total"
}

index_of : Orders.Category -> U64
index_of = |category| match category {
	Books => 0
	Electronics => 1
	Fashion => 2
	Garden => 3
	Grocery => 4
	Home => 5
	Sports => 6
	Toys => 7
}

## A tally's cells: one per category, region and value bin.
cells : U64
cells = Orders.categories.len() * Orders.regions.len() * Orders.bins

cell_of : { category : U64, region : U64, bin : U64 } -> U64
cell_of = |{ category, region, bin }| (category * Orders.regions.len() + region) * Orders.bins + bin

## Add `amount` to the count at `index`, which the packing keeps in range.
add_at : List(U64), U64, U64 -> List(U64)
add_at = |counts, index, amount| match counts.get(index) {
	Ok(count) => counts.set(index, count + amount) ?? crash "Orders.add_at: ${index.to_str()} was in range a moment ago"
	Err(OutOfBounds) => crash "Orders.add_at: no count at ${index.to_str()} of ${counts.len().to_str()}"
}

add_lists : List(U64), List(U64) -> List(U64)
add_lists = |left, right| left.map_with_index(|n, i| n + (right.get(i) ?? 0))

## SplitMix64: the stream steps by `golden`, and `mix` turns each step into
## a word whose every bit is usable.
golden : U64
golden = 0x9E3779B97F4A7C15

mix : U64 -> U64
mix = |seed| {
	b = seed.bitwise_xor(seed.shr_zf_wrap(30)).times_wrap(0xBF58476D1CE4E5B9)
	c = b.bitwise_xor(b.shr_zf_wrap(27)).times_wrap(0x94D049BB133111EB)
	c.bitwise_xor(c.shr_zf_wrap(31))
}

## The weights each add to 1024, so `pick` reaches every index.
expect {
	actual =
		\\categories: ${category_weights.sum().to_str()}
		\\regions: ${region_weights.sum().to_str()}
	expected =
		\\categories: 1024
		\\regions: 1024
	actual == expected
}

## A shard is the same orders every time, shards differ, and a question of
## every order counts them all.
expect {
	first = Orders.generate({ seed: 2026, shard: 0, rows: 2000 })
	again = Orders.generate({ seed: 2026, shard: 0, rows: 2000 })
	other = Orders.generate({ seed: 2026, shard: 1, rows: 2000 })
	all = Orders.summarise(first, Orders.everything)
	actual =
		\\same: ${Str.inspect(first == again)}
		\\differs: ${Str.inspect(first != other)}
		\\orders: ${all.orders.to_str()}
		\\histogram: ${all.histogram.sum().to_str()}
		\\days: ${all.per_day.sum().to_str()}
		\\today: ${(all.per_day.get(Orders.today) ?? 99).to_str()}
		\\regions: ${Str.inspect(all.by_region.sum() == all.revenue)}
	expected =
		\\same: True
		\\differs: True
		\\orders: 2000
		\\histogram: 2000
		\\days: 2000
		\\today: 0
		\\regions: True
	actual == expected
}

## The live tally answers a filter as the orders themselves do, and a
## narrower filter keeps the whole histogram of its categories.
expect {
	sold = Orders.live(7, 500).orders
	narrow = { categories: [Toys, Books], lowest: 1, highest: 4 }
	tallied = Orders.tally(Orders.tally(Orders.no_orders, sold.take_first(200)), sold.drop_first(200))
	actual =
		\\everything: ${Str.inspect(Orders.summarise_tally(tallied, Orders.everything) == Orders.summarise(sold, Orders.everything))}
		\\narrow: ${Str.inspect(Orders.summarise_tally(tallied, narrow) == Orders.summarise(sold, narrow))}
		\\today: ${(Orders.summarise(sold, Orders.everything).per_day.get(Orders.today) ?? 0).to_str()}
	expected =
		\\everything: True
		\\narrow: True
		\\today: 500
	actual == expected
}

## Merging adds every count, and merging nothing is the empty answer.
expect {
	a = Orders.summarise(Orders.generate({ seed: 1, shard: 0, rows: 300 }), Orders.everything)
	b = Orders.summarise(Orders.generate({ seed: 1, shard: 1, rows: 200 }), Orders.everything)
	both = Orders.merge([a, b])
	actual =
		\\orders: ${both.orders.to_str()}
		\\revenue: ${Str.inspect(both.revenue == a.revenue + b.revenue)}
		\\nothing: ${Str.inspect(Orders.merge([]) == Orders.empty)}
	expected =
		\\orders: 500
		\\revenue: True
		\\nothing: True
	actual == expected
}
