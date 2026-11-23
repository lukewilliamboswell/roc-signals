import fz.Fuzz
import pf.Sig

## Two generated sets of layer indices and of store cells, an index for a
## site, and a choice that often puts that index in the same word position
## as one of the first set's layers. Indices span five words, so every
## operation meets indices of 64 and more and indices 64 apart.
Input : { layers : List(U64), others : List(U64), cells : List(U64), other_cells : List(U64), at_word : U64, pick : U64 }

## Past every generated index, so a membership sweep also sees the words a
## set must not grow.
limit : U64
limit = 6 * 64

## The model's signature bit of layer `index`: bit `index % 64` of the low
## word, written from the representation design.md states, not from Sig.
model_bit : U64 -> U128
model_bit = |index| (1.U128).shl_wrap((index % 64).to_u8_wrap())

## The model's signature bit of store cell `cell`: bit `cell % 64` of the
## high word.
model_cell_bit : U64 -> U128
model_cell_bit = |cell| (1.U128).shl_wrap((64 + cell % 64).to_u8_wrap())

## The signature of exact sets of layers and cells, by the model's bits.
model_mask : List(U64), List(U64) -> U128
model_mask = |layers, cells| cells.fold(layers.fold(0, |mask, i| mask.bitwise_or(model_bit(i))), |mask, c| mask.bitwise_or(model_cell_bit(c)))

## The distinct members of a list, in increasing order.
canon : List(U64) -> List(U64)
canon = |items| items.sort_with(|a, b| if (a < b) Before else if (a > b) After else Same).fold(
	[],
	|seen, item| if (seen.last() == Ok(item)) seen else seen.append(item),
)

## The write set naming exactly these layers and cells, one member at a time.
build : List(U64), List(U64) -> Sig.Wrote
build = |layers, cells| cells.fold(layers.fold(Sig.none, |set, i| Sig.union(set, Sig.one_layer(i))), |set, c| Sig.union(set, Sig.one_cell(c)))

## The same members in another order: rotated by a third of the list.
rotated : List(U64) -> List(U64)
rotated = |items| {
	k = items.len() // 3
	items.drop_first(k).concat(items.take_first(k))
}

## Masks and write sets against exact sets, at every index generated:
##
## - the canonical form makes `==` set equality, however a set was built;
## - a set names exactly its members, and its mask is the model's mask, so
##   a member's bit is in it at any index, and the mask of a union is the
##   union of the masks;
## - `below(at)` and `from(at)` partition the layers at `at`, with every
##   cell in `below` and none in `from`, each in canonical form;
## - `above_bits(at)` covers every layer above `at` on a path and every
##   cell, exactly while `at` is below 64; `upto(at)` covers every layer
##   to `at` and no cell;
## - stripping a site's own bit from the reads it reports never drops a
##   read of a layer above it or of a cell;
## - `fold_cells` visits exactly the cells, in order;
## - the schedule's decisions at `at` follow from the exact sets.
test : Input -> Fuzz.Outcome
test = |input| {
	# A saved or mutated input is decoded without the generator's ranges, so
	# every index is brought into the five words here: a write set is as long
	# as its largest index.
	words = |items| items.map(|i| i % (5 * 64))
	layers = words(input.layers)
	others = words(input.others)
	cells = words(input.cells)
	other_cells = words(input.other_cells)
	at_word = input.at_word % 5
	pick = input.pick % 64
	a = build(layers, cells)
	b = build(others, other_cells)
	at = at_word * 64 + (layers.get(pick) ?? pick) % 64
	members = canon(layers)
	member_cells = canon(cells)

	if build(rotated(layers), rotated(cells)) != a or build(members, member_cells) != a {
		crash "a set built in another order is not equal to itself"
	}
	half = layers.len() // 2
	if Sig.union(build(layers.take_first(half), cells), build(layers.drop_first(half), [])) != a {
		crash "a union of two parts of a set is not equal to the set"
	}
	if (a == b) != (members == canon(others) and member_cells == canon(other_cells)) {
		crash "== on write sets is not equality of the sets"
	}
	if Sig.is_empty(a) != (members.is_empty() and member_cells.is_empty()) or Sig.count(a) != members.len() + member_cells.len() {
		crash "is_empty or count disagrees with the set"
	}

	for j in (0.U64).until(limit) {
		if Sig.has_layer(a, j) != members.contains(j) {
			crash "has_layer(${j.to_str()}) disagrees with the set"
		}
		if Sig.has_cell(a, j) != member_cells.contains(j) {
			crash "has_cell(${j.to_str()}) disagrees with the set"
		}
	}

	if Sig.mask_of(a) != model_mask(layers, cells) {
		crash "the mask of a set is not the union of its members' bits"
	}
	for i in layers {
		if Sig.bit(i) != model_bit(i) {
			crash "the bit of layer ${i.to_str()} is not bit ${(i % 64).to_str()}"
		}
	}
	if Sig.mask_of(Sig.union(a, b)) != Sig.mask_of(a).bitwise_or(Sig.mask_of(b)) {
		crash "the mask of a union is not the union of the masks"
	}

	below = Sig.below(a, at)
	from = Sig.from(a, at)
	for j in (0.U64).until(limit) {
		if Sig.has_layer(below, j) != (members.contains(j) and j < at) {
			crash "below(${at.to_str()}) is wrong about layer ${j.to_str()}"
		}
		if Sig.has_layer(from, j) != (members.contains(j) and j >= at) {
			crash "from(${at.to_str()}) is wrong about layer ${j.to_str()}"
		}
		if Sig.has_cell(below, j) != member_cells.contains(j) {
			crash "below(${at.to_str()}) is wrong about cell ${j.to_str()}"
		}
		if Sig.has_cell(from, j) {
			crash "from(${at.to_str()}) keeps cell ${j.to_str()}"
		}
	}
	if below != build(members.keep_if(|j| j < at), cells) or from != build(members.keep_if(|j| j >= at), []) {
		crash "below or from at ${at.to_str()} is not in canonical form"
	}
	if Sig.union(below, from) != a {
		crash "below and from at ${at.to_str()} do not make up the set"
	}

	above = Sig.above_bits(at)
	for j in (0.U64).until(at.min(limit)) {
		if model_bit(j).bitwise_and(above) == 0 {
			crash "above_bits(${at.to_str()}) misses layer ${j.to_str()}"
		}
	}
	for c in (0.U64).until(64) {
		if model_cell_bit(c).bitwise_and(above) == 0 {
			crash "above_bits(${at.to_str()}) misses cell ${c.to_str()}"
		}
	}
	if at < 64 {
		for j in at.until(64) {
			if model_bit(j).bitwise_and(above) != 0 {
				crash "above_bits(${at.to_str()}) holds layer ${j.to_str()}, at or below the site"
			}
		}
	}
	upto = Sig.upto(at)
	for j in (0.U64).until((at + 1).min(limit)) {
		if model_bit(j).bitwise_and(upto) == 0 {
			crash "upto(${at.to_str()}) misses layer ${j.to_str()}"
		}
	}
	if upto.bitwise_and(Sig.all_cells) != 0 {
		crash "upto(${at.to_str()}) holds a cell"
	}

	reported = model_mask(layers, cells).bitwise_and(Sig.own_bit(at).bitwise_not())
	for j in layers {
		if j < at and model_bit(j).bitwise_and(reported) == 0 {
			crash "stripping the own bit of layer ${at.to_str()} drops a read of layer ${j.to_str()}"
		}
	}
	for c in cells {
		if model_cell_bit(c).bitwise_and(reported) == 0 {
			crash "stripping the own bit of layer ${at.to_str()} drops a read of cell ${c.to_str()}"
		}
	}

	if Sig.fold_cells(a, [], |visited, c| visited.append(c)) != member_cells {
		crash "fold_cells does not visit exactly the set's cells in order"
	}

	expected_state =
		if !members.contains(at) {
			Untouched
		} else if !member_cells.is_empty() or members.any(|j| j < at) {
			Waits
		} else {
			Starts({ walk: build(members.keep_if(|j| j > at), []) })
		}
	if Sig.at_state(a, at) != expected_state {
		crash "at_state(${at.to_str()}) disagrees with the set"
	}
	{ pass, walk } = Sig.at_root(a)
	if pass != (if (member_cells.is_empty()) NoPass else Cells(model_mask([], cells))) or walk != build(members, []) {
		crash "at_root disagrees with the set"
	}
	if Sig.walk_on(a, at, Bool.False) != (if (members.any(|j| j > at)) Further else Ends) or Sig.walk_on(a, at, Bool.True) != Further {
		crash "walk_on(${at.to_str()}) disagrees with the set"
	}
	Fuzz.keep
}

## An index from one of five words, so indices 64 apart meet.
index : Fuzz.Generator(U64)
index = Fuzz.map2(Fuzz.u64_in(0, 4), Fuzz.u64_in(0, 63), |word, offset| word * 64 + offset)

example : Str, Input -> Fuzz.Example(Input)
example = |name, input| Fuzz.example({ name, revision: "1", make: || input })

fuzz_target = Fuzz.target_with({
	name: "masks",
	generator: { layers: Fuzz.list(index, 24), others: Fuzz.list(index, 24), cells: Fuzz.list(index, 24), other_cells: Fuzz.list(index, 24), at_word: Fuzz.u64_in(0, 4), pick: Fuzz.u64_in(0, 63) }.Fuzz,
	test,
	show: Str.inspect,
	examples: [
		example("empty", { layers: [], others: [], cells: [], other_cells: [], at_word: 0, pick: 0 }),
		# Layers 2, 66 and 130 share signature bit 2 and are three layers.
		example("one-bit-three-words", { layers: [2, 66, 130], others: [130, 2], cells: [], other_cells: [], at_word: 1, pick: 0 }),
		# A site at 70 strips nothing: layer 6 above it shares its bit.
		example("own-bit-shared-above", { layers: [6, 3], others: [], cells: [6], other_cells: [], at_word: 1, pick: 0 }),
		# A split inside the second word, with cells beside the layers.
		example("split-in-a-later-word", { layers: [1, 64, 100, 140, 200], others: [1, 64, 100, 140], cells: [0, 70, 255], other_cells: [70], at_word: 1, pick: 3 }),
		# Cells 6, 70 and 134 share a bit and are three cells.
		example("cells-one-bit", { layers: [5], others: [5], cells: [134, 6, 70], other_cells: [6, 70, 134], at_word: 0, pick: 0 }),
		# Indices at the edges of every word.
		example("word-edges", { layers: [0, 63, 64, 127, 128, 191, 192, 255, 256, 319], others: [], cells: [63, 64, 319], other_cells: [], at_word: 2, pick: 63 }),
	],
})

## The same property, model and saved inputs used by the standalone app and suite.
FuzzMasksProperty := [].{
	target = fuzz_target
}
