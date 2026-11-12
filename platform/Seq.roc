## The ordered keys of a view: entries kept in the order of a comparison, as a
## list of chunks of at most `limit` entries.
##
## A flat list costs a move of up to the whole list per insert or remove; a
## chunk costs a move of at most `limit` entries, and finding the chunk costs a
## binary search over the chunks. Each entry carries the sort value it was
## placed by, so a search never reads a row: the sequence stays ordered by its
## own entries whatever the table holds meanwhile.
##
## The comparison is passed to every call rather than stored, and must be a
## total order on the entries held: two entries comparing `Same` is a contract
## error, since an entry is found again by its sort value alone.
Seq(k, s) :: { chunks : List(List({ sort : s, key : k })), count : U64, limit : U64 }.{

	## An empty sequence whose chunks hold at most `limit` entries. A `limit`
	## at least the largest size the sequence will reach makes it a flat list.
	empty : U64 -> Seq(k, s)
	empty = |limit| { chunks: [], count: 0, limit: limit.max(4) }

	## A sequence of entries already in order, filled to three quarters of
	## `limit` so that the first inserts into a chunk need not split it. Each
	## chunk is allocated with room for `limit` entries, so it never grows.
	from_sorted : List({ sort : s, key : k }), U64 -> Seq(k, s)
	from_sorted = |entries, limit0| {
		limit = limit0.max(4)
		total = entries.len()
		fill = (limit - limit // 4).min(total).max(1)
		var $chunks = List.with_capacity(total // fill + 1)
		var $start = 0
		while $start < total {
			$chunks = $chunks.append(List.with_capacity(limit.min(total) + 1).concat(entries.sublist({ start: $start, len: fill })))
			$start = $start + fill
		}
		{ chunks: $chunks, count: total, limit }
	}

	## The number of entries.
	len : Seq(k, s) -> U64
	len = |seq| seq.count

	## The largest number of entries a chunk holds.
	limit_of : Seq(k, s) -> U64
	limit_of = |seq| seq.limit

	## The number of chunks, for measuring.
	chunk_count : Seq(k, s) -> U64
	chunk_count = |seq| seq.chunks.len()

	## Insert an entry at its place under `compare`. An entry comparing `Same`
	## as one already held is a contract error.
	insert : Seq(k, s), { sort : s, key : k }, (s, s -> [Before, Same, After]) -> Seq(k, s)
	insert = |seq, entry, compare| {
		{ chunks, count, limit } = seq
		if chunks.is_empty() {
			{ chunks: [List.with_capacity(limit.min(64) + 1).append(entry)], count: 1, limit }
		} else {
			at_chunk = chunk_for(chunks, entry.sort, compare)
			{ list, prev } = match chunks.replace(at_chunk, []) {
				Ok(taken) => taken
				Err(_) => crash "Seq.insert: chunk index"
			}
			at = lower_bound(prev, entry.sort, compare)
			match prev.get(at) {
				Ok(there) =>
					if compare(there.sort, entry.sort) == Same {
						crash "contract: two rows of a table view compare Same; a table view's order must be total, so its sort value must break ties by key"
					} else {
						{}
					}
				Err(_) => {}
			}
			grown = insert_at(prev, at, entry)
			next_chunks =
				if grown.len() > limit {
					half = grown.len() // 2
					right = List.with_capacity(limit + 1).concat(grown.sublist({ start: half, len: grown.len() - half }))
					left = grown.take_first(half)
					match list.set(at_chunk, left) {
						Ok(placed) =>
							match placed.insert(at_chunk + 1, right) {
								Ok(split) => split
								Err(_) => crash "Seq.insert: split index"
							}
						Err(_) => crash "Seq.insert: chunk index"
					}
				} else {
					match list.set(at_chunk, grown) {
						Ok(placed) => placed
						Err(_) => crash "Seq.insert: chunk index"
					}
				}
			{ chunks: next_chunks, count: count + 1, limit }
		}
	}

	## Remove the entry with sort value `sort`. A missing entry is a contract
	## error: a view removes only what it placed. A chunk that falls below an
	## eighth of `limit` is merged into a neighbour when the two fit in one.
	remove : Seq(k, s), s, (s, s -> [Before, Same, After]) -> Seq(k, s)
	remove = |seq, sort, compare| {
		{ chunks, count, limit } = seq
		at_chunk = chunk_for(chunks, sort, compare)
		{ list, prev } = match chunks.replace(at_chunk, []) {
			Ok(taken) => taken
			Err(_) => crash "Seq.remove: the sequence is empty"
		}
		at = lower_bound(prev, sort, compare)
		found = match prev.get(at) {
			Ok(there) => compare(there.sort, sort) == Same
			Err(_) => False
		}
		if !found {
			crash "Seq.remove: no entry has this sort value"
		} else {
			{}
		}
		shrunk = prev.drop_at(at)
		small = (limit // 8).max(2)
		next_chunks =
			if shrunk.is_empty() {
				list.drop_at(at_chunk)
			} else if shrunk.len() < small and at_chunk + 1 < list.len() {
				merge_into_next(list, at_chunk, shrunk, limit)
			} else if shrunk.len() < small and at_chunk > 0 {
				merge_into_previous(list, at_chunk, shrunk, limit)
			} else {
				match list.set(at_chunk, shrunk) {
					Ok(placed) => placed
					Err(_) => crash "Seq.remove: chunk index"
				}
			}
		{ chunks: next_chunks, count: count - 1, limit }
	}

	## The `count` entries from position `start`, clamped to the sequence:
	## a `count` that reaches past the end, however large, gives the
	## entries there are and asks for room for no more. Costs a pass over
	## the chunk sizes and the entries returned.
	slice : Seq(k, s), { start : U64, count : U64 } -> List({ sort : s, key : k })
	slice = |seq, { start, count }| {
		var $out = List.with_capacity(count.min(seq.count - start.min(seq.count)))
		var $skipped = 0
		var $chunk = 0
		chunks = seq.chunks
		while $chunk < chunks.len() and $out.len() < count {
			current = match chunks.get($chunk) {
				Ok(c) => c
				Err(_) => crash "Seq.slice: chunk index"
			}
			size = current.len()
			if $skipped + size <= start {
				$skipped = $skipped + size
			} else {
				from = if (start > $skipped) start - $skipped else 0
				$out = $out.concat(current.sublist({ start: from, len: (count - $out.len()).min(size - from) }))
				$skipped = $skipped + size
			}
			$chunk = $chunk + 1
		}
		$out
	}

	## The entries just before and just after the entry with sort value
	## `sort`, which must be held. Costs the two binary searches of a lookup.
	neighbours : Seq(k, s), s, (s, s -> [Before, Same, After]) -> { before : Try({ sort : s, key : k }, [First]), after : Try({ sort : s, key : k }, [Last]) }
	neighbours = |seq, sort, compare| {
		chunks = seq.chunks
		at_chunk = chunk_for(chunks, sort, compare)
		chunk = match chunks.get(at_chunk) {
			Ok(c) => c
			Err(_) => crash "Seq.neighbours: the sequence is empty"
		}
		at = lower_bound(chunk, sort, compare)
		before =
			if at > 0 {
				Ok(chunk.get(at - 1) ?? crash "Seq.neighbours: index")
			} else if at_chunk > 0 {
				match chunks.get(at_chunk - 1) {
					Ok(previous) => Ok(previous.last() ?? crash "Seq.neighbours: an empty chunk")
					Err(_) => crash "Seq.neighbours: chunk index"
				}
			} else {
				Err(First)
			}
		after =
			if at + 1 < chunk.len() {
				Ok(chunk.get(at + 1) ?? crash "Seq.neighbours: index")
			} else {
				match chunks.get(at_chunk + 1) {
					Ok(next) => Ok(next.first() ?? crash "Seq.neighbours: an empty chunk")
					Err(_) => Err(Last)
				}
			}
		{ before, after }
	}

	## Every entry in order, for tests.
	to_list : Seq(k, s) -> List({ sort : s, key : k })
	to_list = |seq| seq.chunks.fold([], |acc, chunk| acc.concat(chunk))
}

## The index of the first chunk whose last entry is not before `sort`, or the
## last chunk if every entry is before it. The chunks must not be empty.
chunk_for : List(List({ sort : s, key : k })), s, (s, s -> [Before, Same, After]) -> U64
chunk_for = |chunks, sort, compare| {
	var $lo = 0
	var $hi = chunks.len()
	while $lo < $hi {
		mid = $lo + ($hi - $lo) // 2
		before = match chunks.get(mid) {
			Ok(chunk) =>
				match chunk.last() {
					Ok(last) => compare(last.sort, sort) == Before
					Err(_) => crash "Seq.chunk_for: an empty chunk"
				}
			Err(_) => crash "Seq.chunk_for: chunk index"
		}
		if before {
			$lo = mid + 1
		} else {
			$hi = mid
		}
	}
	$lo.min(chunks.len() - 1)
}

## The first position in `chunk` whose entry is not before `sort`.
lower_bound : List({ sort : s, key : k }), s, (s, s -> [Before, Same, After]) -> U64
lower_bound = |chunk, sort, compare| {
	var $lo = 0
	var $hi = chunk.len()
	while $lo < $hi {
		mid = $lo + ($hi - $lo) // 2
		before = match chunk.get(mid) {
			Ok(there) => compare(there.sort, sort) == Before
			Err(_) => crash "Seq.lower_bound: index"
		}
		if before {
			$lo = mid + 1
		} else {
			$hi = mid
		}
	}
	$lo
}

## Insert `item` at `at` in place: `List.insert` builds a new list, so append
## and swap it down instead. A uniquely held chunk with spare capacity is not
## reallocated.
insert_at : List(a), U64, a -> List(a)
insert_at = |list, at, item| {
	var $out = list.append(item)
	var $i = $out.len() - 1
	while $i > at {
		$out = match $out.swap($i - 1, $i) {
			Ok(swapped) => swapped
			Err(_) => crash "Seq.insert_at: index"
		}
		$i = $i - 1
	}
	$out
}

merge_into_next : List(List(a)), U64, List(a), U64 -> List(List(a))
merge_into_next = |chunks, at_chunk, small, limit| {
	{ list, prev: next } = match chunks.replace(at_chunk + 1, []) {
		Ok(taken) => taken
		Err(_) => crash "Seq.merge_into_next: chunk index"
	}
	if small.len() + next.len() <= limit {
		merged = small.concat(next)
		match list.set(at_chunk + 1, merged) {
			Ok(placed) => placed.drop_at(at_chunk)
			Err(_) => crash "Seq.merge_into_next: chunk index"
		}
	} else {
		restored = match list.set(at_chunk + 1, next) {
			Ok(placed) => placed
			Err(_) => crash "Seq.merge_into_next: chunk index"
		}
		match restored.set(at_chunk, small) {
			Ok(placed) => placed
			Err(_) => crash "Seq.merge_into_next: chunk index"
		}
	}
}

merge_into_previous : List(List(a)), U64, List(a), U64 -> List(List(a))
merge_into_previous = |chunks, at_chunk, small, limit| {
	{ list, prev: previous } = match chunks.replace(at_chunk - 1, []) {
		Ok(taken) => taken
		Err(_) => crash "Seq.merge_into_previous: chunk index"
	}
	if small.len() + previous.len() <= limit {
		merged = previous.concat(small)
		match list.set(at_chunk - 1, merged) {
			Ok(placed) => placed.drop_at(at_chunk)
			Err(_) => crash "Seq.merge_into_previous: chunk index"
		}
	} else {
		restored = match list.set(at_chunk - 1, previous) {
			Ok(placed) => placed
			Err(_) => crash "Seq.merge_into_previous: chunk index"
		}
		match restored.set(at_chunk, small) {
			Ok(placed) => placed
			Err(_) => crash "Seq.merge_into_previous: chunk index"
		}
	}
}

upto : U64, U64 -> List(U64)
upto = |lo, hi| {
	var $out = List.with_capacity(hi - lo)
	var $i = lo
	while $i < hi {
		$out = $out.append($i)
		$i = $i + 1
	}
	$out
}

compare_u64 : U64, U64 -> [Before, Same, After]
compare_u64 = |a, b| if (a < b) Before else if (a > b) After else Same

## Inserting and removing keeps the entries in order across chunk splits and
## merges.
expect {
	start = Seq.empty(8)
	keys = upto(0, 200).map(|i| (i * 7919) % 211)
	full = keys.fold(start, |seq, key| seq.insert({ sort: key, key }, compare_u64))
	halved = keys.keep_if(|key| key % 4 != 0).fold(full, |seq, key| seq.remove(key, compare_u64))
	expected = keys.keep_if(|key| key % 4 == 0).sort_with(compare_u64)
	halved.to_list().map(|e| e.key) == expected and halved.len() == expected.len()
}

## A slice reads across chunk boundaries and clamps at the end.
expect {
	seq = Seq.from_sorted(upto(0, 50).map(|i| { sort: i, key: i }), 8)
	seq.slice({ start: 4, count: 10 }).map(|e| e.key) == upto(4, 14)
		and seq.slice({ start: 45, count: 10 }).map(|e| e.key) == [45, 46, 47, 48, 49]
}

## A slice of the largest count there is gives every entry from its start,
## and one that starts past the end gives none.
expect {
	seq = Seq.from_sorted(upto(0, 50).map(|i| { sort: i, key: i }), 8)
	seq.slice({ start: 0, count: U64.highest }).map(|e| e.key) == upto(0, 50)
		and seq.slice({ start: 47, count: U64.highest }).map(|e| e.key) == [47, 48, 49]
		and seq.slice({ start: U64.highest, count: U64.highest }).is_empty()
}
