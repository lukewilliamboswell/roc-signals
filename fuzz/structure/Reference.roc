## The value model of the structure target's generated programs: the page a
## program draws from scratch for the local states that are alive, and a
## click as "apply the handler's writes, then draw again". Nothing here is
## incremental, and this module imports nothing of the platform: it is
## written from the meaning of each `Node`, so it shares no code with the
## engine it checks.
##
## `Node`, `Sel`, `place` and `rows_of` are the generated program's own
## description, which the target's builder and this model both read. The
## builder turns a `Node` into sites; the model turns it into the leaves the
## page shows.
##
## A turn's meaning is the reference's: every write of the handler is
## applied (writes compose, so a second write of a state adds to the
## first), then the page is drawn again, and a local state is carried
## exactly when its structural identity (its path of child positions,
## branches taken and row keys) is live before and after. A state that is
## not carried starts again at 0 when it is next drawn.
Reference := [].{

	## What a `when`, a `switch` or an `each` follows: one visible value, or
	## the sum of two read together, so that one click can write both things
	## a structural reader reads.
	Sel : [One(U64), Two(U64, U64)]

	## A generated node. Indices name visible values and writable states by
	## `place`. Levels decide where a `Layer` or an `Each` adds a scope (see
	## `Level`):
	## - `Show(i)`: a text of value `i`;
	## - `Guard(i)`, `Control(i)`, `Watch(k, i)`: read value `i` without a
	##   text (a guard, two form controls, a title effect);
	## - `Bump(i)`: a button `+` adding 1 to state `i`; `Bump2(i, j)`: a
	##   button `++` adding 1 to state `i` and then 1 to state `j`, one event;
	## - `Pair(i, j)`: a `derive` of value `i` and below it a text
	##   `pair x~d~y` of value `i`, the derived `2x + 1` and value `j`;
	## - `When(sel, yes, no)`: `yes` when the selected value is even;
	##   `Switch(sel, a, b, c)`: the case of the selected value modulo 3;
	## - `Layer(kind, i, body)`: by `kind % 5`, a `state` starting at 0 with
	##   a text and a `+` button of its own, a `derive` of value `i`
	##   (`derived`), or (kinds 2 to 4, as the valued modes build them) a `resource`
	##   whose value is `x + 7` of value `i`; each draws its value and then
	##   `body`, which sees it as its newest value;
	## - `Each(sel, body)`: the rows `rows_of` gives for the selected value,
	##   each drawing `key:item` and then `body`, which sees the row's item
	##   as its newest value.
	Node := [
		Show(U64),
		Guard(U64),
		Control(U64),
		Bump(U64),
		Bump2(U64, U64),
		Pair(U64, U64),
		When(Sel, List(Node), List(Node)),
		Switch(Sel, List(Node), List(Node), List(Node)),
		Layer(U64, U64, List(Node)),
		Each(Sel, List(Node)),
		Watch(U64, U64),
	]

	## A row of an `Each`: its key, stable while the key stays drawn, and an
	## item that can change under that key.
	Row : { key : U64, item : U64 }

	## What the model draws, in document order: a text; a button with its
	## label and the states a click writes (by identity, in the handler's
	## order); a state that is alive and its value; a row drawn at its
	## identity with its item; and a structural reader with the states its
	## selector depends on (`Live`, `Drawn` and `Reads` draw nothing).
	Leaf : [Text(Str), Button(Str, List(Str)), Live(Str, U64), Drawn(Str, U64), Reads(Deps)]

	## The states a value depends on: those it reads directly, and those it
	## reaches through a `derive`, a `resource` or a row's item.
	Deps : { direct : List(Str), derived : List(Str) }

	## Local state by structural identity. A state not held is at 0; the
	## root state's identity is the empty text.
	Held : List((Str, U64))

	## A session so far: the states held, and the identities of the rows
	## that were drawn and are no longer (to count reinsertions).
	Seen : { held : Held, gone : List(Str) }

	## What a session exercised, per click: clicks; clicks writing two
	## different states that one live structural reader depends on; of those,
	## clicks where the reader reaches one of them through a derived value;
	## clicks that disposed a state below the root that was not at 0; rows
	## drawn again under a key that an earlier click removed; and rows kept by
	## a click whose item changed.
	Tally : { clicks : U64, both_read : U64, through_derived : U64, disposed_live : U64, reinserted : U64, kept_changed : U64 }

	## The position index `i` names in a list of `len` entries: counted from
	## the start below 128, and from the end at 128 and above (128 is the
	## last), so a generated node can name the value or state nearest it.
	place : U64, U64 -> U64
	place = |len, i| {
		n = len.max(1)
		if (i >= 128) n - 1 - (i - 128) % n else i % n
	}

	## The entry `i` names (`place`), or `fallback` in an empty list.
	pick : List(a), U64, a -> a
	pick = |list, i, fallback| list.get(place(list.len(), i)) ?? fallback

	## The rows of an `Each` that follows `x`. Key `k` of 0 to 4 is drawn
	## unless `(x + k) % 4` is 0, so as `x` grows by one a key leaves and the
	## key that left one step before comes back; no rows are drawn when
	## `x % 6` is 5. The keys are ordered by `(k * m) % 5` with
	## `m = 1 + (x // 2) % 4`, which moves them, and a row's item is
	## `k + 10 * ((x // 3) % 3)`, so a kept key's item changes.
	rows_of : U64 -> List(Row)
	rows_of = |x| {
		# The key at position p of the order is p times the inverse of m modulo 5.
		inverse = match 1 + (x // 2) % 4 {
			1 => 1
			2 => 3
			3 => 2
			_ => 4
		}
		[0, 1, 2, 3, 4].map(|p| (p * inverse) % 5).keep_if(|k| x % 6 != 5 and (x + k) % 4 != 0).map(|k| { key: k, item: k + 10 * ((x // 3) % 3) })
	}

	## What a `derive` layer of kind `kind` (`kind % 5 == 1`) computes from
	## `x`: `2x + 1` when `(kind // 5)` is even, and `x // 2` when it is odd,
	## which maps two values to one, so a woken `derive` can recompute an
	## equal value and must prune its readers.
	derived : U64, U64 -> U64
	derived = |kind, x| if ((kind // 5) % 2 == 0) x * 2 + 1 else x // 2

	## The page drawn from scratch for the states held: the root state, its
	## button, then the tree.
	page : List(Node), Held -> List(Leaf)
	page = |tree, held| {
		root = held_value(held, "")
		[Live("", root), Text(root.to_str()), Button("+", [""])].concat(drawn_list(tree, { vals: [{ value: root, deps: { direct: [""], derived: [] } }], wrs: [""] }, Root, "", held))
	}

	## The states the `k`-th button in document order writes, in its
	## handler's order.
	writes_at : List(Node), Held, U64 -> List(Str)
	writes_at = |tree, held, k| {
		offered = page(tree, held).fold(
			[],
			|acc, leaf| match leaf {
				Button(_, writes) => acc.append(writes)
				_ => acc
			},
		)
		offered.get(k) ?? []
	}

	## One click on the `k`-th button in document order: each write of the
	## handler adds 1 to its state, in order; then a state is kept exactly
	## when the page drawn from the result still holds it.
	clicked : List(Node), Held, U64 -> Held
	clicked = |tree, held, k| {
		written = writes_at(tree, held, k).fold(held, |acc, at| acc.keep_if(|(name, _)| name != at).append((at, held_value(acc, at) + 1)))
		alive = page(tree, written).fold(
			[],
			|acc, leaf| match leaf {
				Live(at, _) => acc.append(at)
				_ => acc
			},
		)
		written.keep_if(|(name, _)| alive.contains(name))
	}

	## A session's start: nothing held, no row gone.
	start : Seen
	start = { held: [], gone: [] }

	## A click (`clicked`) and what it exercised (`Tally`).
	click : List(Node), Seen, U64 -> { seen : Seen, tally : Tally }
	click = |tree, seen, k| {
		before = page(tree, seen.held)
		writes = writes_at(tree, seen.held, k)
		held = clicked(tree, seen.held, k)
		after = page(tree, held)
		rows_before = drawn_rows(before)
		rows_after = drawn_rows(after)
		two = match writes {
			[a, b] if a != b => Ok((a, b))
			_ => Err(One)
		}
		readers = before.fold(
			[],
			|acc, leaf| match leaf {
				Reads(deps) => acc.append(deps)
				_ => acc
			},
		)
		(both, through) = match two {
			Ok((a, b)) => {
				reads_both = readers.keep_if(|deps| depends(deps, a) and depends(deps, b))
				(!reads_both.is_empty(), reads_both.any(|deps| deps.derived.contains(a) or deps.derived.contains(b)))
			}
			Err(_) => (False, False)
		}
		lost = seen.held.any(|(name, value)| name != "" and value > 0 and !held.any(|(kept, _)| kept == name))
		returned = rows_after.keep_if(|(at, _)| seen.gone.contains(at) and !rows_before.any(|(was, _)| was == at)).len()
		changed = rows_after.keep_if(|(at, item)| rows_before.any(|(was, old)| was == at and old != item)).len()
		left = rows_before.keep_if(|(at, _)| !rows_after.any(|(now, _)| now == at)).map(|(at, _)| at)
		gone = seen.gone.keep_if(|at| !rows_after.any(|(now, _)| now == at)).concat(left.keep_if(|at| !seen.gone.contains(at)))
		{
			seen: { held, gone },
			tally: {
				clicks: 1,
				both_read: if (both) 1 else 0,
				through_derived: if (through) 1 else 0,
				disposed_live: if (lost) 1 else 0,
				reinserted: returned,
				kept_changed: changed,
			},
		}
	}

	## No clicks.
	no_tally : Tally
	no_tally = { clicks: 0, both_read: 0, through_derived: 0, disposed_live: 0, reinserted: 0, kept_changed: 0 }

	## Two tallies together.
	add : Tally, Tally -> Tally
	add = |a, b| {
		clicks: a.clicks + b.clicks,
		both_read: a.both_read + b.both_read,
		through_derived: a.through_derived + b.through_derived,
		disposed_live: a.disposed_live + b.disposed_live,
		reinserted: a.reinserted + b.reinserted,
		kept_changed: a.kept_changed + b.kept_changed,
	}

	## A session of clicks over `tree` in the model alone: byte `b` clicks
	## the button `b` modulo the page's button count, as the target's valued
	## mode clicks the engine.
	session : List(Node), List(U8) -> Tally
	session = |tree, clicks| clicks.fold(
		(start, no_tally),
		|(seen, tally), b| {
			r = click(tree, seen, b.to_u64() % buttons(page(tree, seen.held)).max(1))
			(r.seen, add(tally, r.tally))
		},
	).1

	## What a page shows of the leaves: each text and each button's label,
	## in document order.
	texts : List(Leaf) -> List(Str)
	texts = |leaves| leaves.fold(
		[],
		|acc, leaf| match leaf {
			Text(text) => acc.append(text)
			Button(label, _) => acc.append(label)
			_ => acc
		},
	)

	## How many buttons the leaves offer.
	buttons : List(Leaf) -> U64
	buttons = |leaves| leaves.fold(
		0,
		|acc, leaf| match leaf {
			Button(_, _) => acc + 1
			_ => acc
		},
	)
}

## Where the generator's typed levels put a body: the level a layer's body
## and a row's body are built at, or `Err(InPlace)` at the last level, where
## a `Layer` and an `Each` add no scope and draw their body in place.
Level : [Root, Second, Third, Last, InRow, Flat]

level_below : Level -> Try({ layer : Level, row : Level }, [InPlace])
level_below = |level| match level {
	Root => Ok({ layer: Second, row: InRow })
	Second => Ok({ layer: Third, row: InRow })
	Third => Ok({ layer: Last, row: InRow })
	Last => Ok({ layer: Flat, row: Flat })
	InRow => Ok({ layer: Last, row: Flat })
	Flat => Err(InPlace)
}

## A visible value and the states it depends on.
Val : { value : U64, deps : Reference.Deps }

## The values a node can read and the states it can write where it is built,
## as the builder holds signals and states.
Scope : { vals : List(Val), wrs : List(Str) }

held_value : Reference.Held, Str -> U64
held_value = |held, at| match held.find_first(|(name, _)| name == at) {
	Ok((_, value)) => value
	Err(_) => 0
}

seen : Scope, U64 -> Val
seen = |scope, i| Reference.pick(scope.vals, i, { value: 0, deps: { direct: [], derived: [] } })

## What a structural reader follows.
chosen : Scope, Reference.Sel -> Val
chosen = |scope, sel| match sel {
	One(i) => seen(scope, i)
	Two(i, j) => {
		a = seen(scope, i)
		b = seen(scope, j)
		{ value: a.value + b.value, deps: { direct: a.deps.direct.concat(b.deps.direct), derived: a.deps.derived.concat(b.deps.derived) } }
	}
}

## A value computed from `from`: everything `from` depends on, reached
## through a derived value.
derived_from : U64, Val -> Val
derived_from = |value, from| { value, deps: { direct: [], derived: from.deps.direct.concat(from.deps.derived) } }

depends : Reference.Deps, Str -> Bool
depends = |deps, at| deps.direct.contains(at) or deps.derived.contains(at)

wrote : Scope, U64 -> Str
wrote = |scope, i| Reference.pick(scope.wrs, i, "")

drawn_rows : List(Reference.Leaf) -> List((Str, U64))
drawn_rows = |leaves| leaves.fold(
	[],
	|acc, leaf| match leaf {
		Drawn(at, item) => acc.append((at, item))
		_ => acc
	},
)

drawn_list : List(Reference.Node), Scope, Level, Str, Reference.Held -> List(Reference.Leaf)
drawn_list = |ns, scope, level, at, held| {
	var $out = []
	var $k = 0.U64
	for n in ns {
		$out = $out.concat(drawn(n, scope, level, "${at}/${$k.to_str()}", held))
		$k = $k + 1
	}
	$out
}

drawn : Reference.Node, Scope, Level, Str, Reference.Held -> List(Reference.Leaf)
drawn = |n, scope, level, at, held| match n {
	Show(i) => [Text(seen(scope, i).value.to_str())]
	Guard(_) | Control(_) | Watch(_, _) => []
	Bump(i) => if (scope.wrs.is_empty()) [Text("-")] else [Button("+", [wrote(scope, i)])]
	Bump2(i, j) => if (scope.wrs.is_empty()) [Text("-")] else [Button("++", [wrote(scope, i), wrote(scope, j)])]
	Pair(i, j) => {
		x = seen(scope, i).value
		[Text("pair ${x.to_str()}~${(x * 2 + 1).to_str()}~${seen(scope, j).value.to_str()}")]
	}
	When(sel, yes, no) => {
		v = chosen(scope, sel)
		[Reads(v.deps)].concat(if (v.value % 2 == 0) drawn_list(yes, scope, level, "${at}y", held) else drawn_list(no, scope, level, "${at}n", held))
	}
	Switch(sel, a, b, c) => {
		v = chosen(scope, sel)
		k = v.value % 3
		[Reads(v.deps)].concat(drawn_list(if (k == 0) a else if (k == 1) b else c, scope, level, "${at}s${k.to_str()}", held))
	}
	Layer(kind, i, body) => match level_below(level) {
		Err(_) => drawn_list(body, scope, level, at, held)
		Ok(below) =>
			if kind % 5 == 0 {
				value = held_value(held, at)
				own = { value, deps: { direct: [at], derived: [] } }
				[Live(at, value), Text(value.to_str()), Button("+", [at])].concat(drawn_list(body, { vals: scope.vals.append(own), wrs: scope.wrs.append(at) }, below.layer, at, held))
			} else {
				x = seen(scope, i)
				v = derived_from(if (kind % 5 == 1) Reference.derived(kind, x.value) else x.value + 7, x)
				[Text(v.value.to_str())].concat(drawn_list(body, { vals: scope.vals.append(v), wrs: scope.wrs }, below.layer, at, held))
			}
	}
	Each(sel, body) => match level_below(level) {
		Err(_) => drawn_list(body, scope, level, at, held)
		Ok(below) => {
			v = chosen(scope, sel)
			Reference.rows_of(v.value).fold(
				[Reads(v.deps)],
				|acc, row| {
					id = "${at}k${row.key.to_str()}"
					item = derived_from(row.item, v)
					acc.concat([Drawn(id, row.item), Text("${row.key.to_str()}:${row.item.to_str()}")]).concat(drawn_list(body, { vals: scope.vals.append(item), wrs: scope.wrs }, below.row, id, held))
				},
			)
		}
	}
}

## A key leaves and is drawn again as the value grows one at a time, the
## empty list is reached, keys move, and a kept key's item changes.
expect {
	keys = |x| Reference.rows_of(x).map(|row| row.key)
	{ x0: keys(0), x1: keys(1), x2: keys(2), x5: keys(5), items: (Reference.rows_of(2), Reference.rows_of(3)) } == {
		x0: [1, 2, 3],
		x1: [0, 1, 2, 4],
		x2: [0, 3, 1, 4],
		x5: [],
		items: ([{ key: 0, item: 0 }, { key: 3, item: 3 }, { key: 1, item: 1 }, { key: 4, item: 4 }], [{ key: 0, item: 10 }, { key: 3, item: 13 }, { key: 4, item: 14 }, { key: 2, item: 12 }]),
	}
}

## `place` counts from the start below 128 and from the end at 128 and above.
expect [Reference.place(4, 1), Reference.place(4, 5), Reference.place(4, 128), Reference.place(4, 129), Reference.place(4, 133), Reference.place(0, 129)] == [1, 1, 3, 2, 2, 0]

## A click on a `Bump2` that writes one state twice adds 2 to it, and a
## state in a branch the click leaves is dropped from what is held.
expect {
	tree = [Layer(0, 0, [Bump2(128, 128), When(One(128), [Layer(0, 0, [])], [])])]
	# Buttons: the root's, the state's own, the `++`, and in the even branch
	# the inner state's.
	h1 = Reference.clicked(tree, [], 3)
	h2 = Reference.clicked(tree, h1, 1)
	h3 = Reference.clicked(tree, h2, 2)
	{ h1, h2, h3 } == { h1: [("/0/1y/0", 1)], h2: [("/0", 1)], h3: [("/0", 3)] }
}
