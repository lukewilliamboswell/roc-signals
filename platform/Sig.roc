## Read signatures and exact write sets: how the engine names what a value
## reads and what an event wrote (design.md, "Contexts, layers and cells").
##
## A layer is named by its index on the path from the root: a `state`,
## `derive`, `resource` or `each` row below a layer at index `d` takes
## index `d + 1`. Indices grow without bound: nesting is limited only by
## memory.
##
## Two representations meet. A *read signature* (`Signal.mask`, a hole's
## mask, a block's reads, the mask of a `Changed` pass) is 128 bits. Its
## low 64 bits are the layers': index `i` at bit `i % 64`. It can only
## over-approximate: two layers on one path share a bit only when their
## indices differ by a multiple of 64, and a shared bit costs an evaluation
## that equality pruning then discards; a reader of a changed layer is never
## skipped. While every index on every path is below 64 the low word has
## one bit for each layer.
##
## Its high 64 bits are the root store's cells': cell `c` at bit
## `64 + c % 64` (`cell_bit`). A cell is not a layer on any path: it has no
## depth, every scope reaches it, and it never shares a bit with a layer,
## so a store of any size leaves the layers' precision as it was. Cells
## 64 apart in the store share a bit, at the cost of a pruned evaluation.
##
## A *write set* ([Wrote]) names the layers and the cells an event wrote
## exactly. Every decision that must be exact reads it: which site settles
## a written layer, what a site hands up, what an orphan's write may still
## touch, which tables' turns end. A refresh pass is then driven by the
## signature of what a site settles, and costs one 128-bit test per hole.
##
## Everything here is pure and shares nothing with the sites, so the
## `fuzz/masks` target checks it directly against exact sets.
Sig :: [].{

	## A read signature: the layers' word low, the cells' word high.
	Mask : U128

	## An exact set of layer indices and of store cells: what an event wrote.
	## Layer index `i` is bit `i % 64` of `lo` when `i < 64`, else of
	## `hi[i / 64 - 1]`; store cell `c` is bit `c % 64` of `cells` when
	## `c < 64`, else of `more[c / 64 - 1]`. Neither list has a trailing zero
	## word, so a set whose layers and cells are all below 64 holds two empty
	## lists, an empty set is all zero, and `==` is equality of the sets.
	##
	## Only the root settles cells, so every site hands them up untouched. The
	## root refreshes their readers by the signature (`mask_of`), in which
	## cells 64 apart share a bit, and rearms each table's next writing turn
	## by the exact cells.
	Wrote : { lo : U64, hi : List(U64), cells : U64, more : List(U64) }

	## What a `Changed` message is for. `Turn(mask)` is a pass of a turn: it
	## refreshes the readers of what `mask` names and descends only where a
	## child reads some of it. `Check` is the settle check (`Core.settled`),
	## a harness's pass over a copy of the instance: it re-evaluates every
	## hole, descends into every child whatever its reads, makes every view
	## site compare its view with one built from scratch, and asks every table
	## cell whether it was rearmed. A site that settles layers of its own (the
	## rows of an `each`) passes `Check` inward whole.
	##
	## The two are different tags so that no turn can be taken for the check:
	## a turn whose mask has every bit set is still a turn.
	Pass : [Turn(Mask), Check]

	## Whether a pass reaches a reader of `reads`: a turn when its mask
	## shares a bit with them, the check whenever they are not empty.
	meets : Pass, Mask -> Bool
	meets = |pass, reads| match pass {
		Turn(mask) => mask.bitwise_and(reads) != 0
		Check => reads != 0
	}

	## A pass that also carries `bits` from here down: what a layer's site
	## hands its subtree when its own layer changed in the same pass (a
	## `derive` that recomputed, a waiting state that joins). The check
	## already carries everything.
	joined : Pass, Mask -> Pass
	joined = |pass, bits| match pass {
		Turn(mask) => Turn(mask.bitwise_or(bits))
		Check => Check
	}

	## The read-signature bit of layer index `index`.
	bit : U64 -> Mask
	bit = |index| (1.U128).shl_wrap(index.bitwise_and(63).to_u8_wrap())

	## The read-signature bit of store cell `cell` (see above).
	cell_bit : U64 -> Mask
	cell_bit = |cell| (1.U128).shl_wrap(64 + cell.bitwise_and(63).to_u8_wrap())

	## Every store cell's signature bit.
	all_cells : Mask
	all_cells = 0xFFFF_FFFF_FFFF_FFFF_0000_0000_0000_0000

	## Every layer's signature bit, and no cell's.
	all_layer_bits : Mask
	all_layer_bits = 0xFFFF_FFFF_FFFF_FFFF

	## The index of a new layer below the layer at `depth`.
	layer : U64 -> U64
	layer = |depth| depth + 1

	## The bit of layer index `index` that a site may strip from the reads it
	## reports above it, or 0. A site strips its own layer's bit because no
	## pass from above carries it, but a bit is shared by every index congruent
	## modulo 64: stripping it would also hide a read of an ancestor that
	## shares it, and the parent would not descend when that ancestor changes.
	## Below index 64 no layer above can share it; from 64 on the site keeps
	## it and pays an extra visit, pruned by equality, when the other layer
	## changes.
	own_bit : U64 -> Mask
	own_bit = |index| if (index < 64) Sig.bit(index) else 0

	## The signature bits of every layer strictly above index `index` on a
	## path, for a site that keeps only those (an `each` site, of its rows'
	## reads): exact below 64, every bit from 64 on (any bit may then belong to
	## an ancestor). A store cell is above every layer.
	above_bits : U64 -> Mask
	above_bits = |index| if (index < 64) (Sig.bit(index) - 1).bitwise_or(Sig.all_cells) else Sig.every

	## Every layer bit and every cell bit. It is an ordinary mask: a turn may
	## carry it, and the settle check is `Check`, not this.
	every : Mask
	every = 0xFFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF

	## The signature bits of every index from 0 to `depth`, both included
	## (every layer bit once `depth` reaches 63).
	upto : U64 -> Mask
	upto = |depth| if (depth >= 63) Sig.all_layer_bits else Sig.bit(depth).shl_wrap(1) - 1

	## No layer and no cell.
	none : Wrote
	none = { lo: 0, hi: [], cells: 0, more: [] }

	## The one layer at index `i`.
	one_layer : U64 -> Wrote
	one_layer = |i| {
		{ lo, hi } = index_words(i)
		{ lo, hi, cells: 0, more: [] }
	}

	## The one store cell `c`.
	one_cell : U64 -> Wrote
	one_cell = |c| {
		{ lo, hi } = index_words(c)
		{ lo: 0, hi: [], cells: lo, more: hi }
	}

	## The `total` store cells from `first`: what a write of a group names.
	cells_span : U64, U64 -> Wrote
	cells_span = |first, total| {
		var $set = Sig.none
		var $k = 0.U64
		while $k < total {
			$set = Sig.union($set, Sig.one_cell(first + $k))
			$k = $k + 1
		}
		$set
	}

	## Whether a set names no layer and no cell.
	is_empty : Wrote -> Bool
	is_empty = |a| a.lo == 0 and a.cells == 0 and a.hi.is_empty() and a.more.is_empty()

	## The union of two sets.
	union : Wrote, Wrote -> Wrote
	union = |a, b| { lo: a.lo.bitwise_or(b.lo), hi: words_or(a.hi, b.hi), cells: a.cells.bitwise_or(b.cells), more: words_or(a.more, b.more) }

	## The store cells of a set, without its layers.
	cells_of : Wrote -> Wrote
	cells_of = |a| { lo: 0, hi: [], cells: a.cells, more: a.more }

	## Whether a set names layer index `i`.
	has_layer : Wrote, U64 -> Bool
	has_layer = |a, i| words_have(a.lo, a.hi, i)

	## Whether a set names store cell `c`.
	has_cell : Wrote, U64 -> Bool
	has_cell = |a, c| words_have(a.cells, a.more, c)

	## The indices of `a` below `i`: the layers above index `i` on its path,
	## and every cell (the store is above every layer).
	below : Wrote, U64 -> Wrote
	below = |a, i| {
		w = i.shr_zf_wrap(6)
		low = wbit(i) - 1
		if w == 0 {
			{ lo: a.lo.bitwise_and(low), hi: [], cells: a.cells, more: a.more }
		} else if a.hi.len() < w {
			a
		} else {
			kept = a.hi.take_first(w)
			last = (kept.get(w - 1) ?? 0).bitwise_and(low)
			{ lo: a.lo, hi: trim(kept.set(w - 1, last) ?? kept), cells: a.cells, more: a.more }
		}
	}

	## The indices of `a` at or above `i`: index `i` and the layers below it.
	## No cell: a cell is never below a layer.
	from : Wrote, U64 -> Wrote
	from = |a, i| {
		w = i.shr_zf_wrap(6)
		high = (wbit(i) - 1).bitwise_not()
		if w == 0 {
			{ lo: a.lo.bitwise_and(high), hi: a.hi, cells: 0, more: [] }
		} else if a.hi.len() < w {
			Sig.none
		} else {
			var $hi = a.hi
			var $k = 0.U64
			while $k + 1 < w {
				$hi = $hi.set($k, 0) ?? $hi
				$k = $k + 1
			}
			cut = ($hi.get(w - 1) ?? 0).bitwise_and(high)
			{ lo: 0, hi: trim($hi.set(w - 1, cut) ?? $hi), cells: 0, more: [] }
		}
	}

	## The read signature of a write set: what a refresh pass for it tests
	## holes and children against. Its cells go to the high word.
	mask_of : Wrote -> Mask
	mask_of = |a| a.hi.fold(a.lo, |acc, w| acc.bitwise_or(w)).to_u128().bitwise_or(a.more.fold(a.cells, |acc, w| acc.bitwise_or(w)).to_u128().shl_wrap(64))

	## Fold `step` over the store cells a set names, in increasing order of
	## position. A word that names no cell costs one test; one that does costs
	## a step per bit up to its highest. The root ends a turn's tables with
	## it, so only a table cell the turn wrote is visited, whichever cells
	## share its signature bit.
	fold_cells : Wrote, state, (state, U64 -> state) -> state
	fold_cells = |a, start, step| {
		var $state = fold_word(start, { bits: a.cells, base: 0 }, step)
		var $base = 64.U64
		for word in a.more {
			$state = fold_word($state, { bits: word, base: $base }, step)
			$base = $base + 64
		}
		$state
	}

	## What the site of the layer at index `depth` does with an event's write
	## set when the event unwinds through it (design.md, "Glitch freedom and
	## ordering"). A layer the event did not write is `Untouched` and hands
	## the set up. A written layer `Waits` at its site when the event also
	## wrote a layer above it on its path, or a store cell. Otherwise it is
	## the outermost write and `Starts` the event's pass at its own site,
	## followed by a walk down the event's path for the layers written below
	## it (`walk`).
	##
	## A reader below the layer may also read the outer write, or something
	## derived from either: a `derive`, a `resource`, a row's item. Refreshed
	## for one write at a time, it would be evaluated with one new value beside
	## one old one, a pair that never held: a text would be written twice, and
	## an effect site would issue a request for it. So an event's writes are
	## settled by one pass, from the outermost. The inner layer hands its write
	## up and waits; the outermost written layer (or the root, for a cell)
	## starts the pass; and when the pass reaches the waiting layer's site, the
	## site adds its own layer to what the pass carries, for its subtree alone.
	## Order within the pass follows nesting, so every `derive` of either write
	## is recomputed before anything below it reads it, and a reader of both is
	## evaluated once.
	##
	## A layer is readable only below its own site, so nothing outside the
	## waiting layer's subtree can need it, and no reader of a sibling layer at
	## the same index is woken. A waiting layer the pass does not reach has no
	## reader in common with it: nothing in its subtree reads what the pass
	## carried. The walk that follows the pass refreshes each such layer at its
	## own site.
	at_state : Wrote, U64 -> [Untouched, Waits, Starts({ walk : Wrote })]
	at_state = |wrote, depth|
		if !Sig.has_layer(wrote, depth) {
			Untouched
		} else if !Sig.is_empty(Sig.below(wrote, depth)) {
			Waits
		} else {
			Starts({ walk: Sig.from(wrote, depth + 1) })
		}

	## What the root does with an event's write set once the event is back:
	## a pass of the cells written, when there are any (`Cells`, with their
	## signature), and then a walk down the event's path for every written
	## layer, each of which either joined that pass where it reached its site
	## or still waits. A layer written with no cell has started its own pass
	## at its site, and the walk reaches those below it.
	at_root : Wrote -> { pass : [NoPass, Cells(Mask)], walk : Wrote }
	at_root = |wrote| {
		cells = Sig.cells_of(wrote)
		{ pass: if (Sig.is_empty(cells)) NoPass else Cells(Sig.mask_of(cells)), walk: Sig.from(wrote, 0) }
	}

	## Whether a walk at the site of the layer at index `depth` goes on down
	## the event's path: while it names a layer below that one, or always when
	## it is `forced` by a browser echo, which marks a hole the walk must reach
	## at the event's target.
	walk_on : Wrote, U64, Bool -> [Further, Ends]
	walk_on = |walk, depth, forced| if (!forced and Sig.is_empty(Sig.from(walk, depth + 1))) Ends else Further

	## How many layers and cells a set names.
	count : Wrote -> U64
	count = |a| a.more.fold(a.hi.fold(popcount(a.lo) + popcount(a.cells), |acc, w| acc + popcount(w)), |acc, w| acc + popcount(w))
}

## Fold `step` over the positions `base + k` for each bit `k` set in `bits`.
fold_word : state, { bits : U64, base : U64 }, (state, U64 -> state) -> state
fold_word = |start, { bits, base }, step| {
	var $state = start
	var $bits = bits
	var $at = base
	while $bits != 0 {
		if $bits.bitwise_and(1) != 0 {
			$state = step($state, $at)
		}
		$bits = $bits.shr_zf_wrap(1)
		$at = $at + 1
	}
	$state
}

## The bit of layer index `index` in its word of a write set.
wbit : U64 -> U64
wbit = |index| (1.U64).shl_wrap(index.bitwise_and(63).to_u8_wrap())

## The words of a set holding index `i` alone: its low word and the rest.
index_words : U64 -> { lo : U64, hi : List(U64) }
index_words = |i| {
	w = i.shr_zf_wrap(6)
	if w == 0 {
		{ lo: wbit(i), hi: [] }
	} else {
		{ lo: 0, hi: List.repeat(0, w - 1).append(wbit(i)) }
	}
}

## The union of the words past the first of two sets.
words_or : List(U64), List(U64) -> List(U64)
words_or = |a, b| {
	if a.is_empty() {
		b
	} else if b.is_empty() {
		a
	} else {
		n = if (a.len() > b.len()) a.len() else b.len()
		var $out = List.with_capacity(n)
		var $k = 0.U64
		while $k < n {
			$out = $out.append((a.get($k) ?? 0).bitwise_or(b.get($k) ?? 0))
			$k = $k + 1
		}
		$out
	}
}

## Whether the words `lo` and `hi` of a set name index `i`.
words_have : U64, List(U64), U64 -> Bool
words_have = |lo, hi, i| {
	w = i.shr_zf_wrap(6)
	word = if (w == 0) lo else (hi.get(w - 1) ?? 0)
	word.bitwise_and(wbit(i)) != 0
}

## `hi` without its trailing zero words.
trim : List(U64) -> List(U64)
trim = |hi| {
	var $hi = hi
	while ($hi.last() ?? 1) == 0 {
		$hi = $hi.drop_last(1)
	}
	$hi
}

popcount : U64 -> U64
popcount = |m| {
	var $m = m
	var $n = 0.U64
	while $m != 0 {
		$m = $m.bitwise_and($m - 1)
		$n = $n + 1
	}
	$n
}

## A write set names layers exactly across words: index 130 is not index 66
## or index 2, though all three share signature bit 2, and the split at an
## index keeps every layer on the right side of it.
expect {
	a = Sig.union(Sig.one_layer(3), Sig.one_layer(130))
	actual = {
		holds: (Sig.has_layer(a, 130), Sig.has_layer(a, 66), Sig.has_layer(a, 2)),
		below: Sig.below(a, 130),
		from: (Sig.from(a, 4), Sig.from(a, 129), Sig.from(a, 131)),
		sig: Sig.mask_of(a),
		count: Sig.count(a),
	}
	expected = {
		holds: (Bool.True, Bool.False, Bool.False),
		below: Sig.one_layer(3),
		from: (Sig.one_layer(130), Sig.one_layer(130), Sig.none),
		sig: Sig.bit(3).bitwise_or(Sig.bit(130)),
		count: 2,
	}
	actual == expected
}

## A write set names cells exactly too: cell 70 is not cell 6, though they
## share a signature bit. A group's cells are named one by one, cells stay
## with the layers above an index and never with those below it.
expect {
	a = Sig.union(Sig.one_layer(3), Sig.union(Sig.one_cell(70), Sig.cells_span(4, 3)))
	actual = {
		holds: (Sig.has_cell(a, 70), Sig.has_cell(a, 6), Sig.has_cell(a, 7), Sig.has_cell(a, 134)),
		layer: (Sig.has_layer(a, 3), Sig.has_layer(a, 6)),
		above: Sig.below(a, 3) == Sig.union(Sig.one_cell(70), Sig.cells_span(4, 3)),
		below: Sig.from(a, 3),
		sig: Sig.mask_of(a),
		count: Sig.count(a),
	}
	expected = {
		holds: (Bool.True, Bool.True, Bool.False, Bool.False),
		layer: (Bool.True, Bool.False),
		above: Bool.True,
		below: Sig.one_layer(3),
		sig: Sig.bit(3).bitwise_or(Sig.cell_bit(4)).bitwise_or(Sig.cell_bit(5)).bitwise_or(Sig.cell_bit(6)),
		count: 5,
	}
	actual == expected
}

## A site strips its own signature bits from the reads it reports only below
## index 64, where no layer above it can share them.
expect {
	actual = (Sig.own_bit(36), Sig.own_bit(100), Sig.above_bits(40), Sig.above_bits(104))
	actual == (Sig.bit(36), 0, (Sig.bit(40) - 1).bitwise_or(Sig.all_cells), Sig.every)
}

## The check reaches every reader that reads anything and carries every
## bit already; a turn reaches only the readers its mask shares a bit with,
## even when that mask has every bit set.
expect {
	actual = {
		check: (Sig.meets(Check, 0), Sig.meets(Check, Sig.bit(5)), Sig.joined(Check, Sig.bit(5))),
		turn: (Sig.meets(Turn(Sig.bit(3)), Sig.bit(5)), Sig.meets(Turn(Sig.bit(3)), Sig.bit(67)), Sig.joined(Turn(Sig.bit(3)), Sig.bit(5))),
		every: (Sig.meets(Turn(Sig.every), 0), Sig.joined(Turn(Sig.every), Sig.bit(5)) == Check),
	}
	actual == {
		check: (Bool.False, Bool.True, Check),
		turn: (Bool.False, Bool.True, Turn(Sig.bit(3).bitwise_or(Sig.bit(5)))),
		every: (Bool.False, Bool.False),
	}
}

## A fold over a set's cells visits exactly the cells it names, in order,
## across words: cells 6, 70 and 134 share a signature bit and are three
## visits, and the set's layers are none of them.
expect {
	a = Sig.union(Sig.union(Sig.one_cell(134), Sig.one_cell(6)), Sig.union(Sig.one_cell(70), Sig.one_layer(6)))
	actual = (Sig.fold_cells(a, [], |cells, cell| cells.append(cell)), Sig.fold_cells(Sig.one_layer(9), [], |cells, cell| cells.append(cell)))
	actual == ([6, 70, 134], [])
}

## Every write set of layers 0 to 3, with and without cell 0: the layers it
## names and whether it names the cell, beside the set.
small_sets : List({ layers : List(U64), cell : Bool, wrote : Sig.Wrote })
small_sets = (0.U64).until(32).fold(
	[],
	|sets, n| {
		layers = [0, 1, 2, 3].keep_if(|i| n.shr_zf_wrap(i.to_u8_wrap()).bitwise_and(1) != 0)
		cell = n >= 16
		start = if (cell) Sig.one_cell(0) else Sig.none
		sets.append({ layers, cell, wrote: layers.fold(start, |acc, i| Sig.union(acc, Sig.one_layer(i))) })
	},
)

## At each of layers 0 to 3, over every small write set: an unwritten layer
## is untouched; a written one waits exactly when a layer above it or a cell
## was written, and otherwise starts the pass with a walk of the layers below
## it. So a set with a cell starts no pass at a layer, and one with layers
## and no cell starts exactly one, at the outermost.
expect {
	wrong = small_sets.keep_if(
		|{ layers, cell, wrote }| {
			decided = [0, 1, 2, 3].map(|depth| Sig.at_state(wrote, depth))
			expected = [0, 1, 2, 3].map(
				|depth|
					if !layers.contains(depth) {
						Untouched
					} else if cell or layers.any(|i| i < depth) {
						Waits
					} else {
						Starts({ walk: layers.keep_if(|i| i > depth).fold(Sig.none, |acc, i| Sig.union(acc, Sig.one_layer(i))) })
					},
			)
			starts = decided.keep_if(
				|d| match d {
					Starts(_) => Bool.True
					_ => Bool.False
				},
			)
			decided != expected or starts.len() != (if (cell or layers.is_empty()) 0 else 1)
		},
	)
	wrong.map(|set| set.wrote) == []
}

## Over every small write set, the root runs a pass exactly when a cell was
## written, with that cell's signature alone, and walks every written layer.
expect {
	wrong = small_sets.keep_if(
		|{ layers, cell, wrote }| {
			{ pass, walk } = Sig.at_root(wrote)
			expected_pass = if (cell) Cells(Sig.cell_bit(0)) else NoPass
			pass != expected_pass or walk != layers.fold(Sig.none, |acc, i| Sig.union(acc, Sig.one_layer(i)))
		},
	)
	wrong.map(|set| set.wrote) == []
}

## At each of layers 0 to 3, over every small write set and either echo: a
## walk goes on exactly while it names a deeper layer, or when it is forced.
expect {
	wrong = small_sets.keep_if(
		|{ layers, wrote, .. }|
			[0, 1, 2, 3].any(
				|depth| {
					deeper = layers.any(|i| i > depth)
					Sig.walk_on(wrote, depth, Bool.False) != (if (deeper) Further else Ends) or Sig.walk_on(wrote, depth, Bool.True) != Further
				},
			),
	)
	wrong.map(|set| set.wrote) == []
}
