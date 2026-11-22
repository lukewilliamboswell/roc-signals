## The plan of a keyed reconciliation: which old rows a new list keeps,
## which of its rows are created, which old rows are dropped, which kept
## rows move, and where each placed row goes (design.md, "Keyed lists:
## templates and typed columns").
##
## The planner knows positions and nothing else. Its caller says how long
## the old rows and the new list are, whether the old row at a position
## holds the key of the new row at a position (`same`), and which old row,
## if any, holds a new row's key (`find`). It answers by handing each step
## to the caller's own function, which applies it to whatever the caller
## keeps (a `sink`): an `each` site applies them to its columns and its
## turn accumulator, a test to a list. No list of steps is built.
##
## `same` and `find` are handed the sink rather than capturing what they
## read. An `each` site's sink holds its columns, which the steps write; a
## test that captured them would be a second holder, and the first write of
## every column would copy it (the roc-lang/roc#12846 class of
## `Core.each_fire_kid`). `find` answers a new sink, so the caller can count
## the lookups it made and keep the hashes it computed.
##
## The plan fixes the order of an `each` site's commands (design.md, "Keyed
## lists"): the common prefix and suffix are kept, then the
## two ends of what is left are swapped while they match, then what is left
## is a pure insertion, a pure removal or, otherwise, the general path:
## every old row of the middle the new list does not hold is dropped, in old
## order, and then the new middle is placed from its last position to its
## first, each created row and each kept row off one longest increasing run
## of old positions placed before the row placed just after it.
##
## Cost: the prefix, the suffix, the swapped ends, a pure insertion and a
## pure removal allocate nothing here. The general path allocates two lists
## and a longest run, each the length of the middle.
Reconcile :: [].{

	## One step of a plan. Positions are fixed: an old position names a row
	## of the old order as it was before the plan, a new position a row of
	## the new list, and neither shifts as steps apply.
	##
	## - `Keep(old, new)`: the old row at `old` is the new list's row at
	##   `new`, whose item may differ.
	## - `Create(new, before)`: the new list's row at `new` is created,
	##   placed before `before`.
	## - `Drop(old)`: the old row at `old` is removed.
	## - `Move(old, before)`: the old row at `old` is moved before `before`.
	##   The `Keep` of the same row follows it.
	##
	## Every old position is kept or dropped exactly once, every new position
	## is kept or created exactly once, and a row moves at most once. `Drop`s
	## come after the swapped ends' `Move`s and before any `Create` or other
	## `Move`, in old order.
	Step : [Keep(U64, U64), Create(U64, Before), Drop(U64), Move(U64, Before)]

	## Where a row is placed: before the old row at an old position (`Old`),
	## which is never one the plan drops; before the row created for a new
	## position (`New`), which is always the row the latest `Create` made; or
	## at the end of the rows (`End`).
	Before : [Old(U64), New(U64), End]

	## `find`'s answer: the old position of the row that holds a new row's
	## key, or `Fresh` when no old row holds it.
	Found : [Old(U64), Fresh]

	## The plan that turns `old` rows into `new` ones, folded into `sink`
	## with `step`. A new key that an old row outside the range still to be
	## planned holds, or that two new rows of the range share with one old
	## row, is `DuplicateKey` of a new position whose key another new row
	## also holds, refused before any step of the general path is taken. Two new rows whose key no
	## old row holds are both created: the caller refuses the second where it
	## indexes it.
	plan : { old : U64, new : U64, same : (sink, U64, U64 -> Bool), find : (sink, U64 -> (sink, Found)) }, sink, (sink, Step -> sink) -> Try(sink, [DuplicateKey(U64)])
	plan = |lists, sink, step| {
		same = lists.same
		var $sink = sink
		var $i = 0.U64
		var $oe = lists.old
		var $ne = lists.new
		# The row the middle is placed before: the first row after it, which
		# is the suffix's first or the end.
		var $after = End
		var $go = Bool.True
		while $go {
			while $i < $oe and $i < $ne and same($sink, $i, $i) {
				$sink = step($sink, Keep($i, $i))
				$i = $i + 1
			}
			while $i < $oe and $i < $ne and same($sink, $oe - 1, $ne - 1) {
				$sink = step($sink, Keep($oe - 1, $ne - 1))
				$after = Old($oe - 1)
				$oe = $oe - 1
				$ne = $ne - 1
			}
			$go = Bool.False
			if $oe - $i >= 2 and $ne - $i >= 2 {
				a = $i
				b = $oe - 1
				if same($sink, b, $i) and same($sink, a, $ne - 1) {
					$sink = step(step($sink, Move(b, Old(a))), Move(a, $after))
					$sink = step(step($sink, Keep(b, $i)), Keep(a, $ne - 1))
					$after = Old(a)
					$i = $i + 1
					$oe = $oe - 1
					$ne = $ne - 1
					$go = Bool.True
				}
			}
		}
		if $i == $oe {
			var $k = $i
			while $k < $ne {
				$sink = step($sink, Create($k, $after))
				$k = $k + 1
			}
			Ok($sink)
		} else if $i == $ne {
			var $k = $i
			while $k < $oe {
				$sink = step($sink, Drop($k))
				$k = $k + 1
			}
			Ok($sink)
		} else {
			general(lists.find, $sink, step, { start: $i, old_end: $oe, new_end: $ne, after: $after })
		}
	}

	## Marks one longest strictly increasing subsequence of the nonzero
	## entries of `values`: `True` at each of its positions. A zero is never
	## marked, so a caller with positions that may be absent passes each
	## position plus one and zero for none. Of several longest runs it marks
	## the one patience sorting ends on, which every caller relies on to emit
	## the same moves. O(n log n).
	longest_run : List(U64) -> List(Bool)
	longest_run = |values| {
		n = values.len()
		# `tails[j]`: the position of the smallest last value of a run of
		# length j + 1 so far; `previous[i]`: the position before `i` on the
		# run that ends at `i`, plus one, or zero at a run's start.
		var $tails = []
		var $previous = List.repeat(0.U64, n)
		var $i = 0.U64
		while $i < n {
			v = values.get($i) ?? 0
			if v != 0 {
				var $lo = 0.U64
				var $hi = $tails.len()
				while $lo < $hi {
					mid = $lo + ($hi - $lo) // 2
					if (values.get($tails.get(mid) ?? 0) ?? 0) < v {
						$lo = mid + 1
					} else {
						$hi = mid
					}
				}
				before = if ($lo > 0) ($tails.get($lo - 1) ?? 0) + 1 else 0
				$previous = $previous.set($i, before) ?? crash "Reconcile.longest_run: index"
				$tails = if ($lo == $tails.len()) $tails.append($i) else ($tails.set($lo, $i) ?? crash "Reconcile.longest_run: tail")
			}
			$i = $i + 1
		}
		var $marks = List.repeat(Bool.False, n)
		var $at = match $tails.last() {
			Ok(t) => t + 1
			Err(_) => 0
		}
		while $at != 0 {
			$marks = $marks.set($at - 1, Bool.True) ?? crash "Reconcile.longest_run: index"
			$at = $previous.get($at - 1) ?? 0
		}
		$marks
	}
}

## The general path over old positions `start` up to `old_end` and new
## positions `start` up to `new_end`: find every new row's old row, refuse a
## repeated key, drop the old rows no new row holds, then place from the
## last new position to the first.
general : (sink, U64 -> (sink, Reconcile.Found)), sink, (sink, Reconcile.Step -> sink), { start : U64, old_end : U64, new_end : U64, after : Reconcile.Before } -> Try(sink, [DuplicateKey(U64)])
general = |find, sink, step, { start, old_end, new_end, after }| {
	var $sink = sink
	# Which old rows of the middle a new row holds, and each new row's old
	# position plus one, or zero for a new key.
	var $held = List.repeat(Bool.False, old_end - start)
	var $found = List.with_capacity(new_end - start)
	var $k = start
	while $k < new_end {
		(s2, f) = find($sink, $k)
		$sink = s2
		match f {
			Old(o) => {
				if o < start or o >= old_end or ($held.get(o - start) ?? Bool.False) {
					return Err(DuplicateKey($k))
				}
				$held = $held.set(o - start, Bool.True) ?? crash "Reconcile.plan: old position"
				$found = $found.append(o + 1)
			}
			Fresh => {
				$found = $found.append(0)
			}
		}
		$k = $k + 1
	}
	$k = start
	while $k < old_end {
		if !($held.get($k - start) ?? Bool.False) {
			$sink = step($sink, Drop($k))
		}
		$k = $k + 1
	}
	stays = Reconcile.longest_run($found)
	var $before = after
	var $p = new_end
	while $p > start {
		$p = $p - 1
		at = $p - start
		f = $found.get(at) ?? 0
		if f == 0 {
			$sink = step($sink, Create($p, $before))
			$before = New($p)
		} else {
			o = f - 1
			if !(stays.get(at) ?? Bool.False) {
				$sink = step($sink, Move(o, $before))
			}
			$sink = step($sink, Keep(o, $p))
			$before = Old(o)
		}
	}
	Ok($sink)
}

## One longest run is marked, zeros are never marked, and of two longest
## runs the one patience sorting ends on is chosen: for 2, 1 that is the 1.
expect {
	actual = (
		Reconcile.longest_run([]),
		Reconcile.longest_run([0, 0]),
		Reconcile.longest_run([3, 1, 2, 0, 4]),
		Reconcile.longest_run([2, 1]),
		Reconcile.longest_run([5, 4, 3, 2, 1]),
		Reconcile.longest_run([1, 2, 3]),
	)
	expected = (
		[],
		[Bool.False, Bool.False],
		[Bool.False, Bool.True, Bool.True, Bool.False, Bool.True],
		[Bool.False, Bool.True],
		[Bool.False, Bool.False, Bool.False, Bool.False, Bool.True],
		[Bool.True, Bool.True, Bool.True],
	)
	actual == expected
}

## A plan applied to keys in a list: the steps, and the rows they leave.
steps_of : List(Str), List(Str) -> Try(List(Reconcile.Step), [DuplicateKey(U64)])
steps_of = |old, new| Reconcile.plan(
	{
		old: old.len(),
		new: new.len(),
		same: |_, o, n| old.get(o) == new.get(n),
		find: |s, n| (
			s,
			match old.find_first_index(|key| Ok(key) == new.get(n)) {
				Ok(o) => Old(o)
				Err(_) => Fresh
			},
		),
	},
	[],
	|steps, step| steps.append(step),
)

## The fast paths: an equal list keeps every row in place; swapped ends move
## both rows, the first before the second and the second before the row
## after the middle; a pure insertion creates from the first row to the last
## before the suffix; a pure removal drops in old order.
expect {
	actual = (
		steps_of(["a", "b"], ["a", "b"]),
		steps_of(["a", "b", "c", "d"], ["a", "c", "b", "d"]),
		steps_of(["a", "d"], ["a", "b", "c", "d"]),
		steps_of(["a", "b", "c", "d"], ["a", "d"]),
	)
	expected = (
		Ok([Keep(0, 0), Keep(1, 1)]),
		Ok([Keep(0, 0), Keep(3, 3), Move(2, Old(1)), Move(1, Old(3)), Keep(2, 1), Keep(1, 2)]),
		Ok([Keep(0, 0), Keep(1, 3), Create(1, Old(1)), Create(2, Old(1))]),
		Ok([Keep(0, 0), Keep(3, 1), Drop(1), Drop(2)]),
	)
	actual == expected
}

## The general path drops first, then places from the end: the row off the
## longest run moves, a new row is created before the row placed after it,
## and a repeated key is refused before any of it.
expect {
	actual = (
		steps_of(["a", "b", "c", "d"], ["c", "x", "a", "b"]),
		steps_of(["a", "b", "c"], ["b", "a", "b"]),
	)
	expected = (
		Ok([Drop(3), Keep(1, 3), Keep(0, 2), Create(1, Old(0)), Move(2, New(1)), Keep(2, 0)]),
		Err(DuplicateKey(2)),
	)
	actual == expected
}
