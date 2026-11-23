import fz.Fuzz
import pf.Reconcile

## The plan of a keyed reconciliation, held to the lists it reconciles:
## bytes decode into an old list of distinct keys, up to 3000 of them, and
## edits that make a new list from it (insertions, removals, moves, swaps,
## reversals, rotations, a shuffle, a clear, fresh keys, and a repeated key).
## `Reconcile.plan` is run with a sink that keeps its steps, and the steps
## are applied to the old rows by a model that knows nothing of how they
## were planned.
##
## When the new list repeats no key:
## - the plan succeeds, and every old position is kept or dropped exactly
##   once and every new position kept or created exactly once; a kept row is
##   one whose key both lists hold, a created row's key is not in the old
##   list and a dropped row's key is not in the new one;
## - applying the steps to the old rows in order, each at the place its
##   `before` names (an old row still present, the row the latest `Create`
##   made, or the end), leaves exactly the new list, with each row at the
##   new position its `Keep` or `Create` named;
## - a row moves at most once and before its `Keep`; drops are in old
##   order, and none follows a `Create`, or a `Move` made after a drop;
## - the moves are as few as the plan's shape allows: two for each pair of
##   swapped ends, and on the general path the kept rows of the middle less
##   one longest increasing run of their old positions;
## - `find` is asked at most once for each new position.
## When it repeats a key, the plan refuses one that repeats, or it creates
## a row whose key a live row holds, which is where an `each` site's key
## index refuses it.

Edit : { kind : U64, a : U64, b : U64 }

Input : { size : U64, edits : List(Edit) }

Step : Reconcile.Step

## The numbers 0 up to `n`.
range : U64 -> List(U64)
range = |n| {
	var $out = List.with_capacity(n)
	while $out.len() < n {
		$out = $out.append($out.len())
	}
	$out
}

## The keys of the old list: 0 up to `size`, distinct.
old_of : Input -> List(U64)
old_of = |input| range(input.size % 3001)

## The new list the edits make from the old one. Fresh keys are numbered
## from 1000000 up, so none is an old key.
new_of : Input -> List(U64)
new_of = |input| {
	var $keys = old_of(input)
	var $fresh = 1000000.U64
	for edit0 in input.edits {
		# A saved or mutated input is decoded without the generator's
		# ranges, so every operand is brought into them here: a stride of
		# 2^63 would overflow the shuffle's multiplication.
		edit = { kind: edit0.kind, a: edit0.a % 4096, b: edit0.b % 4096 }
		len = $keys.len()
		at = edit.a % (len + 1)
		match edit.kind % 12 {
			0 => {
				count = edit.b % 8 + 1
				$keys = $keys.take_first(at).concat(range(count).map(|k| $fresh + k)).concat($keys.drop_first(at))
				$fresh = $fresh + count
			}
			1 => {
				count = edit.b % 8 + 1
				$keys = $keys.take_first(at).concat($keys.drop_first(at + count))
			}
			2 => {
				if len > 0 {
					from = edit.a % len
					key = $keys.get(from) ?? 0
					rest = $keys.drop_at(from)
					to = edit.b % (rest.len() + 1)
					$keys = rest.take_first(to).append(key).concat(rest.drop_first(to))
				}
			}
			3 => {
				if len > 0 {
					x = edit.a % len
					y = edit.b % len
					$keys = $keys.swap(x, y) ?? $keys
				}
			}
			4 => {
				count = edit.b % (len - at + 1)
				$keys = $keys.take_first(at).concat($keys.sublist({ start: at, len: count }).rev()).concat($keys.drop_first(at + count))
			}
			5 => {
				if len > 0 {
					key = $keys.get(edit.a % len) ?? 0
					to = edit.b % (len + 1)
					$keys = $keys.take_first(to).append(key).concat($keys.drop_first(to))
				}
			}
			6 => {
				if len > 0 {
					$keys = $keys.set(edit.a % len, $fresh) ?? $keys
					$fresh = $fresh + 1
				}
			}
			7 => {
				count = edit.b % (len - at + 1)
				part = $keys.sublist({ start: at, len: count })
				rotated = part.drop_first(1).concat(part.take_first(1))
				$keys = $keys.take_first(at).concat(rotated).concat($keys.drop_first(at + count))
			}
			8 => {
				if len > 1 {
					$keys = $keys.swap(0, len - 1) ?? $keys
				}
			}
			9 => {
				# A shuffle: position i takes the key at i * stride, stride odd
				# and so prime to a power of two; other lengths repeat some keys
				# and lose others, which the dedup below undoes.
				stride = edit.b * 2 + 1
				shuffled = range(len).map(|i| $keys.get((i * stride) % len.max(1)) ?? 0)
				$keys = distinct_in_order(shuffled)
			}
			10 => {
				$keys = []
			}
			_ => {
				count = edit.b % 16
				$keys = range(count).map(|k| $fresh + k)
				$fresh = $fresh + count
			}
		}
	}
	$keys
}

## The members of `keys` in their order, each kept once.
distinct_in_order : List(U64) -> List(U64)
distinct_in_order = |keys| {
	var $seen = Set.empty()
	var $out = []
	for key in keys {
		if !$seen.contains(key) {
			$seen = $seen.insert(key)
			$out = $out.append(key)
		}
	}
	$out
}

## What the test's sink keeps: the steps in order, and the new positions
## `find` was asked about.
Sink : { steps : List(Step), finds : List(U64) }

## The plan of `old` into `new`, through `same` and `find` over the lists.
plan_of : List(U64), List(U64) -> Try(Sink, [DuplicateKey(U64)])
plan_of = |old, new| {
	at = positions_of(old)
	Reconcile.plan(
		{
			old: old.len(),
			new: new.len(),
			same: |_, o, n| old.get(o) == new.get(n),
			find: |sink, n| {
				found = match new.get(n) {
					Ok(key) => match at.get(key) {
						Ok(o) => Old(o)
						Err(_) => Fresh
					}
					Err(_) => Fresh
				}
				({ steps: sink.steps, finds: sink.finds.append(n) }, found)
			},
		},
		{ steps: [], finds: [] },
		|sink, step| { steps: sink.steps.append(step), finds: sink.finds },
	)
}

## Each key's position in `keys`.
positions_of : List(U64) -> Dict(U64, U64)
positions_of = |keys| {
	var $at = Dict.empty()
	var $o = 0.U64
	for key in keys {
		$at = $at.insert(key, $o)
		$o = $o + 1
	}
	$at
}

## Whether a step changes the rows: anything but a `Keep`.
is_structural : Step -> Bool
is_structural = |step| match step {
	Keep(_, _) => Bool.False
	_ => Bool.True
}

## A row of the model: the old row at an old position, or the row created
## for a new position.
Row : [Was(U64), Made(U64)]

## Where `before` puts a row in `rows`, or why it names no row it may.
anchor : List(Row), Reconcile.Before, Try(U64, [None]), List(U8) -> Try(U64, Str)
anchor = |rows, before, latest, old_fate| match before {
	End => Ok(rows.len())
	Old(o) => {
		if (old_fate.get(o) ?? 2) == 2 {
			Err("a row is placed before old row ${o.to_str()}, which is dropped or out of range")
		} else {
			rows.find_first_index(|row| row == Was(o)).map_err(|_| "a row is placed before old row ${o.to_str()}, which is not among the rows")
		}
	}
	New(n) => {
		if latest != Ok(n) {
			Err("a row is placed before the row created for ${n.to_str()}, which is not the row the latest Create made")
		} else {
			rows.find_first_index(|row| row == Made(n)).map_err(|_| "the row created for ${n.to_str()} is not among the rows")
		}
	}
}

## `row` inserted at `at`.
insert_at : List(Row), U64, Row -> List(Row)
insert_at = |rows, at, row| rows.take_first(at).append(row).concat(rows.drop_first(at))

## `row` taken out of `rows`.
without : List(Row), Row -> Try(List(Row), [Absent])
without = |rows, row| match rows.find_first_index(|r| r == row) {
	Ok(i) => Ok(rows.drop_at(i))
	Err(_) => Err(Absent)
}

## The steps applied to the old rows, held to every rule of a plan of
## `old` into `new` (which repeat no key). Answers the moves made.
applied : List(U64), List(U64), List(Step) -> Try(U64, Str)
applied = |old, new, steps| {
	in_new = Set.from_list(new)
	in_old = Set.from_list(old)
	var $rows = range(old.len()).map(|o| Was(o))
	# 0: undecided, 1: kept, 2: dropped.
	var $old_fate = List.repeat(0.U8, old.len())
	var $assigned = List.repeat(Err(None), new.len())
	var $moved = List.repeat(Bool.False, old.len())
	var $latest = Err(None)
	var $last_drop = Err(None)
	var $placing = Bool.False
	var $dropped = Bool.False
	var $moves = 0.U64
	for step in steps {
		match step {
			Keep(o, n) => {
				if (($old_fate.get(o) ?? 3) != 0) or (($assigned.get(n) ?? Ok(Made(0))) != Err(None)) {
					return Err("Keep(${o.to_str()}, ${n.to_str()}) names a row already decided or out of range")
				}
				if old.get(o) != new.get(n) {
					return Err("Keep(${o.to_str()}, ${n.to_str()}) keeps old key ${Str.inspect(old.get(o))} as new key ${Str.inspect(new.get(n))}")
				}
				$old_fate = $old_fate.set(o, 1) ?? $old_fate
				$assigned = $assigned.set(n, Ok(Was(o))) ?? $assigned
			}
			Create(n, before) => {
				if ($assigned.get(n) ?? Ok(Made(0))) != Err(None) {
					return Err("Create(${n.to_str()}) names a new row already decided or out of range")
				}
				key = new.get(n) ?? 0
				if in_old.contains(key) {
					return Err("Create(${n.to_str()}) creates key ${key.to_str()}, which an old row holds: a kept key reported as created")
				}
				place = anchor($rows, before, $latest, $old_fate)?
				$rows = insert_at($rows, place, Made(n))
				$assigned = $assigned.set(n, Ok(Made(n))) ?? $assigned
				$latest = Ok(n)
				$placing = Bool.True
			}
			Drop(o) => {
				if ($old_fate.get(o) ?? 3) != 0 {
					return Err("Drop(${o.to_str()}) names a row already decided or out of range")
				}
				key = old.get(o) ?? 0
				if in_new.contains(key) {
					return Err("Drop(${o.to_str()}) drops key ${key.to_str()}, which the new list holds")
				}
				if $placing {
					return Err("Drop(${o.to_str()}) comes after a Create, or after a Move made after a drop")
				}
				out_of_order = match $last_drop {
					Ok(p) => p >= o
					Err(None) => Bool.False
				}
				if out_of_order {
					return Err("Drop(${o.to_str()}) does not follow the drop before it in old order")
				}
				$last_drop = Ok(o)
				$dropped = Bool.True
				$old_fate = $old_fate.set(o, 2) ?? $old_fate
				$rows = without($rows, Was(o)).map_err(|_| "Drop(${o.to_str()}): the row is not among the rows")?
			}
			Move(o, before) => {
				if ($old_fate.get(o) ?? 3) != 0 or ($moved.get(o) ?? Bool.True) {
					return Err("Move(${o.to_str()}) names a row that is kept, dropped, moved already or out of range")
				}
				if before == Old(o) {
					return Err("Move(${o.to_str()}) places the row before itself")
				}
				if $dropped {
					$placing = Bool.True
				}
				$moved = $moved.set(o, Bool.True) ?? $moved
				$moves = $moves + 1
				rest = without($rows, Was(o)).map_err(|_| "Move(${o.to_str()}): the row is not among the rows")?
				place = anchor(rest, before, $latest, $old_fate)?
				$rows = insert_at(rest, place, Was(o))
			}
		}
	}
	if $old_fate.any(|fate| fate == 0) {
		return Err("an old row is neither kept nor dropped")
	}
	if $assigned.any(|a| a == Err(None)) {
		return Err("a new row is neither kept nor created")
	}
	if $rows.len() != new.len() {
		return Err("the steps leave ${$rows.len().to_str()} rows for a new list of ${new.len().to_str()}")
	}
	var $n = 0.U64
	for row in $rows {
		if ($assigned.get($n) ?? Err(None)) != Ok(row) {
			return Err("new position ${$n.to_str()} holds ${Str.inspect(row)}, not the row its Keep or Create named: a step applied at the wrong position")
		}
		$n = $n + 1
	}
	Ok($moves)
}

## The length of a longest strictly increasing subsequence, by patience
## sorting: `tops[j]` is the least value a run of length j + 1 can end with.
run_length : List(U64) -> U64
run_length = |values| values.fold(
	[],
	|tops, v| match tops.find_first_index(|t| t >= v) {
		Ok(j) => tops.set(j, v) ?? tops
		Err(_) => tops.append(v)
	},
).len()

## The plan's shape, from the lists alone: the swapped ends it takes, and
## the middle the general path gets (empty for a pure insertion or removal).
Shape : { swaps : U64, middle_old : List(U64), middle_new : List(U64) }

shape_of : List(U64), List(U64) -> Shape
shape_of = |old, new| {
	var $i = 0.U64
	var $oe = old.len()
	var $ne = new.len()
	var $swaps = 0.U64
	var $go = Bool.True
	while $go {
		while $i < $oe and $i < $ne and old.get($i) == new.get($i) {
			$i = $i + 1
		}
		while $i < $oe and $i < $ne and old.get($oe - 1) == new.get($ne - 1) {
			$oe = $oe - 1
			$ne = $ne - 1
		}
		$go = $oe - $i >= 2 and $ne - $i >= 2 and old.get($oe - 1) == new.get($i) and old.get($i) == new.get($ne - 1)
		if $go {
			$swaps = $swaps + 1
			$i = $i + 1
			$oe = $oe - 1
			$ne = $ne - 1
		}
	}
	if $i == $oe or $i == $ne {
		{ swaps: $swaps, middle_old: [], middle_new: [] }
	} else {
		{ swaps: $swaps, middle_old: old.sublist({ start: $i, len: $oe - $i }), middle_new: new.sublist({ start: $i, len: $ne - $i }) }
	}
}

## The fewest moves the plan's shape allows: two for each pair of swapped
## ends, and the kept rows of the middle less a longest run of their old
## positions in new order.
fewest_moves : List(U64), List(U64) -> U64
fewest_moves = |old, new| {
	shape = shape_of(old, new)
	at = positions_of(shape.middle_old)
	positions = shape.middle_new.keep_oks(|key| at.get(key))
	2 * shape.swaps + positions.len() - run_length(positions)
}

## Whether `keys` holds some key twice.
repeats : List(U64) -> Bool
repeats = |keys| Set.from_list(keys).len() != keys.len()

## Whether the steps create a row whose key a live row holds: an old row
## not yet dropped, or a row created before it.
creates_a_held_key : List(U64), List(U64), List(Step) -> Bool
creates_a_held_key = |old, new, steps| {
	var $held = Set.from_list(old)
	for step in steps {
		match step {
			Drop(o) => {
				$held = $held.remove(old.get(o) ?? 0)
			}
			Create(n, _) => {
				key = new.get(n) ?? 0
				if $held.contains(key) {
					return Bool.True
				}
				$held = $held.insert(key)
			}
			_ => {}
		}
	}
	Bool.False
}

## The property of one input, as a problem or none.
check : Input -> Try({}, Str)
check = |input| {
	old = old_of(input)
	new = new_of(input)
	match plan_of(old, new) {
		Err(DuplicateKey(n)) => {
			key = new.get(n) ?? 0
			if new.count_if(|k| k == key) < 2 {
				Err("the plan refuses new position ${n.to_str()} as a repeated key, but its key ${key.to_str()} occurs once")
			} else {
				Ok({})
			}
		}
		Ok({ steps, finds }) => {
			if repeats(new) {
				if creates_a_held_key(old, new, steps) {
					Ok({})
				} else {
					Err("the new list repeats a key, and the plan neither refuses it nor creates it beside a live row")
				}
			} else {
				moves = applied(old, new, steps)?
				fewest = fewest_moves(old, new)
				if moves != fewest {
					Err("the plan makes ${moves.to_str()} moves where its shape needs ${fewest.to_str()}")
				} else if repeats(finds) {
					Err("find is asked twice about one new position")
				} else {
					Ok({})
				}
			}
		}
	}
}

test : Input -> Fuzz.Outcome
test = |input| match check(input) {
	Ok({}) => Fuzz.keep
	Err(problem) => crash "reconcile: ${problem}"
}

## The inputs of a seeded series, decoded from a linear congruential
## sequence as the generator would make them.
seeded : U64 -> Input
seeded = |seed| {
	var $x = seed
	next = |x| x.times_wrap(6364136223846793005).plus_wrap(1442695040888963407)
	$x = next($x)
	scale = $x.shr_zf_wrap(33) % 4
	$x = next($x)
	size = $x.shr_zf_wrap(33) % (if (scale == 0) 8 else if (scale == 1) 64 else if (scale == 2) 512 else 3001)
	$x = next($x)
	count = $x.shr_zf_wrap(33) % 6
	var $edits = []
	while $edits.len() < count {
		$x = next($x)
		kind = $x.shr_zf_wrap(33) % 12
		$x = next($x)
		a = $x.shr_zf_wrap(33) % 4096
		$x = next($x)
		b = $x.shr_zf_wrap(33) % 4096
		$edits = $edits.append({ kind, a, b })
	}
	{ size, edits: $edits }
}

## What a plan's input reaches: refusals by the planner and at creation,
## swapped ends, pure insertions and removals, and the general path.
Reach : { refused : U64, created_twice : U64, swaps : U64, inserts : U64, removals : U64, general : U64, equal : U64 }

reach_of : List(Input) -> Reach
reach_of = |inputs| inputs.fold(
	{ refused: 0, created_twice: 0, swaps: 0, inserts: 0, removals: 0, general: 0, equal: 0 },
	|acc, input| {
		old = old_of(input)
		new = new_of(input)
		shape = shape_of(old, new)
		match plan_of(old, new) {
			Err(_) => { ..acc, refused: acc.refused + 1 }
			Ok({ steps, finds: _ }) => {
				if repeats(new) {
					{ ..acc, created_twice: acc.created_twice + 1 }
				} else {
					structural = steps.count_if(is_structural)
					kind =
						if structural == 0 {
							{ ..acc, equal: acc.equal + 1 }
						} else if !shape.middle_old.is_empty() {
							{ ..acc, general: acc.general + 1 }
						} else if new.len() > old.len() {
							{ ..acc, inserts: acc.inserts + 1 }
						} else if new.len() < old.len() {
							{ ..acc, removals: acc.removals + 1 }
						} else {
							acc
						}
					if (shape.swaps > 0) { ..kind, swaps: kind.swaps + 1 } else kind
				}
			}
		}
	},
)

## A seeded series of the generator's inputs holds to the property and
## reaches every shape of plan and both refusals.
expect {
	inputs = range(400).map(|k| seeded(k + 1))
	reach = reach_of(inputs)
	inputs.all(|input| check(input).is_ok())
		and reach.refused > 0
		and reach.created_twice > 0
		and reach.swaps > 0
		and reach.inserts > 0
		and reach.removals > 0
		and reach.general > 0
		and reach.equal > 0
}

edit : Fuzz.Generator(Edit)
edit = { kind: Fuzz.u64_in(0, 11), a: Fuzz.u64_in(0, 4095), b: Fuzz.u64_in(0, 4095) }.Fuzz

## A size from one of four scales, so small lists are as common as long ones.
size : Fuzz.Generator(U64)
size = Fuzz.map2(Fuzz.u64_in(0, 3), Fuzz.u64_in(0, 3000), |scale, n| if (scale == 0) n % 8 else if (scale == 1) n % 64 else if (scale == 2) n % 512 else n)

example : Str, Input -> Fuzz.Example(Input)
example = |name, input| Fuzz.example({ name, revision: "1", make: || input })

fuzz_target = Fuzz.target_with({
	name: "reconcile",
	generator: { size, edits: Fuzz.list(edit, 8) }.Fuzz,
	test,
	show: |input| "${old_of(input).len().to_str()} old rows into ${Str.inspect(new_of(input))} by ${Str.inspect(input.edits)}",
	examples: [
		example("empty-to-empty", { size: 0, edits: [] }),
		example("equal", { size: 5, edits: [] }),
		example("clear", { size: 5, edits: [{ kind: 10, a: 0, b: 0 }] }),
		example("from-empty", { size: 0, edits: [{ kind: 0, a: 0, b: 4 }] }),
		example("append", { size: 4, edits: [{ kind: 0, a: 4, b: 2 }] }),
		example("insert-in-the-middle", { size: 6, edits: [{ kind: 0, a: 3, b: 2 }] }),
		example("remove-in-the-middle", { size: 6, edits: [{ kind: 1, a: 2, b: 1 }] }),
		example("remove-the-end", { size: 6, edits: [{ kind: 1, a: 4, b: 3 }] }),
		example("swap-the-ends", { size: 6, edits: [{ kind: 8, a: 0, b: 0 }] }),
		example("swap-two-of-two", { size: 2, edits: [{ kind: 8, a: 0, b: 0 }] }),
		example("swap-inside", { size: 1000, edits: [{ kind: 3, a: 1, b: 998 }] }),
		example("nested-swaps", { size: 6, edits: [{ kind: 4, a: 0, b: 6 }] }),
		example("move-one-forward", { size: 8, edits: [{ kind: 2, a: 1, b: 6 }] }),
		example("move-one-back", { size: 8, edits: [{ kind: 2, a: 6, b: 1 }] }),
		example("rotate", { size: 10, edits: [{ kind: 7, a: 2, b: 6 }] }),
		example("shuffle-long", { size: 3000, edits: [{ kind: 9, a: 0, b: 1234 }] }),
		example("replace-and-move", { size: 12, edits: [{ kind: 6, a: 3, b: 0 }, { kind: 2, a: 8, b: 1 }, { kind: 1, a: 5, b: 1 }] }),
		example("fresh-all", { size: 6, edits: [{ kind: 11, a: 0, b: 5 }] }),
		example("repeat-in-the-middle", { size: 6, edits: [{ kind: 2, a: 1, b: 4 }, { kind: 5, a: 2, b: 3 }] }),
		example("repeat-at-the-end", { size: 3, edits: [{ kind: 5, a: 2, b: 3 }] }),
		example("repeat-a-fresh-key", { size: 4, edits: [{ kind: 0, a: 2, b: 0 }, { kind: 5, a: 2, b: 0 }] }),
		# A campaign's input: a shuffle of 3000 keys whose stride operand is
		# past the generator's range.
		Fuzz.saved({ name: "shuffle-stride-past-range", revision: "1", bytes: [82, 70, 90, 1, 1, 21, 2, 0, 0, 0, 0, 0, 0, 0, 5, 0, 0, 0, 0, 0, 0, 0, 101, 100, 105, 116, 115, 20, 1, 0, 0, 0, 0, 0, 0, 0, 21, 3, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 97, 8, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 98, 8, 210, 4, 0, 0, 0, 0, 128, 0, 4, 0, 0, 0, 0, 0, 0, 0, 107, 105, 110, 100, 8, 9, 0, 0, 0, 0, 0, 0, 0, 4, 0, 0, 0, 0, 0, 0, 0, 115, 105, 122, 101, 8, 184, 11, 0, 0, 0, 0, 0, 0] }),
	],
})

## The same property, model and saved inputs used by the standalone app and suite.
FuzzReconcileProperty := [].{
	target = fuzz_target
}
