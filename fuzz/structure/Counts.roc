import Reference
import Vectors

## The count and shape model of the structure target's valued programs:
## how many signal reads a turn must make (work counter 21,
## `derived_calls_into_roc`, as design.md's "Work assertions" defines it),
## which scopes it creates and disposes (counters 25 and 26), and which
## written layers it refreshes (counter 27, `dirty_source_roots`, and the
## layers the probe sees settled). It compares the page before a turn with
## the page after it, both drawn from the local states held, and carries
## no state of its own: it is a specification of the work, not an
## algorithm, and it imports nothing of the platform.
##
## A reader is due when its scope is new (it is evaluated once, as it is
## created) or when it reads something the turn changed above it: a layer
## the turn wrote, or a `derive`, a `resource` or a row's item whose value
## the turn changed. A layer's change is carried only below its own site,
## so a reader is due by what is on its own path, and a `derive` that
## recomputes an equal value carries nothing. Equality pruning saves the
## command, never the read: a due reader is counted whether or not its
## value changed. States do not prune on write: a written state is
## refreshed, and counted, whatever value it was given.
##
## The engine's reads are those of the generated program (`Node`, as the
## target's builder builds it in its valued modes): a text, an attribute
## or a property is one read; a `when`'s condition, a `switch`'s value, a
## `derive`'s or a `resource`'s input, an `each`'s list, a `watch`'s and a
## guard's value one each; a row's text and each varying hole of its body
## one each. The page also holds, for each node of the tree, a `when` on
## the root's parity whose even branch holds a document shortcut and whose
## odd branch a constant text.
Counts := [].{

	## What a turn did, by the model: signal reads, scopes created and
	## disposed, and the layer indices of the written states it refreshes,
	## outermost first.
	Turn : { evals : U64, created : U64, disposed : U64, layers : List(U64) }

	## What mounting the page with the states `held` does: every reader is
	## new.
	mount : List(Reference.Node), Reference.Held -> Turn
	mount = |tree, held| {
		walked = root(tree, { before: held, after: held, writes: [], count: Engine }, Bool.True)
		{ evals: walked.evals, created: scopes(tree, held).len(), disposed: 0, layers: [] }
	}

	## What the turn from the states `before` to the states `after` does,
	## when it wrote the states `writes` (by identity, as `Reference`
	## names them).
	turn : List(Reference.Node), Reference.Held, Reference.Held, List(Str) -> Turn
	turn = |tree, before, after, writes| {
		walked = root(tree, { before, after, writes, count: Engine }, Bool.False)
		was = scopes(tree, before)
		now = scopes(tree, after)
		{
			evals: walked.evals,
			created: now.keep_if(|id| !was.contains(id)).len(),
			disposed: was.keep_if(|id| !now.contains(id)).len(),
			layers: walked.layers,
		}
	}

	## The kernel's count of the same turn (see `Count`): what the structure
	## vectors' `evaluations` column records.
	kernel_evaluations : List(Reference.Node), Reference.Held, Reference.Held, List(Str) -> U64
	kernel_evaluations = |tree, before, after, writes| root(tree, { before, after, writes, count: Kernel }, Bool.False).evals

	## Replay a vector's clicks against the kernel's count: `Agrees` when
	## every step's recorded count is the model's (a step with none recorded
	## is not compared), else the first step (from 1) whose count differs.
	replay : Vectors.Trace -> [Agrees, Differs(U64)]
	replay = |trace| {
		var $held = []
		var $n = 0.U64
		for step in trace.steps {
			$n = $n + 1
			writes = Reference.writes_at(trace.tree, $held, step.button)
			after = Reference.clicked(trace.tree, $held, step.button)
			match step.evaluations {
				Counted(recorded) =>
					if recorded != kernel_evaluations(trace.tree, $held, after, writes) {
						return Differs($n)
					}
				Uncounted => {}
			}
			$held = after
		}
		Agrees
	}
}

## A visible value before and after the turn, and the signature bit of the
## layer it is (a value reads exactly one layer: the state, the `derive`,
## the `resource` or the row it comes from).
Val : { old : U64, new : U64, bit : U64 }

## What a node can read and write where it is drawn.
Scope : { vals : List(Val), wrs : List(Str) }

## The turn: the states held before and after, and those it wrote.
World : { before : Reference.Held, after : Reference.Held, writes : List(Str), count : Count }

## Whose count of reads: the engine's (work counter 21), or the kernel's
## (`oracle/turns`' `Turns.Expect`, the `evaluations` column of the
## structure vectors), which leaves out `Guard`, `Control` and `Watch`,
## counts a `Pair`'s text and its watch as one joined reader, and does not
## model the document shortcuts.
Count : [Engine, Kernel]

## Reads counted and written layers refreshed so far.
Acc : { evals : U64, layers : List(U64) }

## Where the generator's typed levels put a layer's body and a row's body.
Level : [Root, Second, Third, Last, InRow, Flat]

none : Acc
none = { evals: 0, layers: [] }

plus : Acc, Acc -> Acc
plus = |a, b| { evals: a.evals + b.evals, layers: a.layers.concat(b.layers) }

reads : U64 -> Acc
reads = |n| { evals: n, layers: [] }

## The signature bit of layer index `depth`. Generated programs nest
## fewer than 64 layers, so each index has a bit of its own.
bit : U64 -> U64
bit = |depth| (1.U64).shl_wrap(depth.to_u8_wrap())

held_value : Reference.Held, Str -> U64
held_value = |held, at| match held.find_first(|(name, _)| name == at) {
	Ok((_, value)) => value
	Err(_) => 0
}

## Whether a reader of `bits` is due: in a new scope always, otherwise when
## the turn carries one of them here.
due : Bool, U64, U64 -> U64
due = |fresh, carried, bits| if (fresh or carried.bitwise_and(bits) != 0) 1 else 0

val_at : Scope, U64 -> Val
val_at = |scope, i| Reference.pick(scope.vals, i, { old: 0, new: 0, bit: 0 })

chosen : Scope, Reference.Sel -> Val
chosen = |scope, sel| match sel {
	One(i) => val_at(scope, i)
	Two(i, j) => {
		a = val_at(scope, i)
		b = val_at(scope, j)
		{ old: a.old + b.old, new: a.new + b.new, bit: a.bit.bitwise_or(b.bit) }
	}
}

level_below : Level -> Try({ layer : Level, row : Level }, [InPlace])
level_below = |level| match level {
	Root => Ok({ layer: Second, row: InRow })
	Second => Ok({ layer: Third, row: InRow })
	Third => Ok({ layer: Last, row: InRow })
	Last => Ok({ layer: Flat, row: Flat })
	InRow => Ok({ layer: Last, row: Flat })
	Flat => Err(InPlace)
}

## The page: the root state (layer index 1), its text and button, the
## tree, and the document shortcut of each tree node.
root : List(Reference.Node), World, Bool -> Acc
root = |tree, world, fresh| {
	b = bit(1)
	old = held_value(world.before, "")
	new = held_value(world.after, "")
	written = world.writes.contains("")
	carried = if (written) b else 0
	own = { evals: due(fresh, carried, b), layers: if (written and !fresh) [1] else [] }
	body = drawn_list(tree, { vals: [{ old, new, bit: b }], wrs: [""] }, Root, "", world, fresh, carried)
	# Each shortcut is a `when` on the root's parity. Its even branch holds a
	# key handler, whose keymap is a property hole read once as the branch
	# is built, though it reads no layer; its odd branch reads nothing.
	built = if (fresh or (old % 2 == 0) != (new % 2 == 0)) Bool.True else Bool.False
	keymap = if (built and new % 2 == 0) 1 else 0
	shortcuts = match world.count {
		Engine => reads(tree.len() * (due(fresh, carried, b) + keymap))
		Kernel => none
	}
	plus(plus(own, body), shortcuts)
}

drawn_list : List(Reference.Node), Scope, Level, Str, World, Bool, U64 -> Acc
drawn_list = |ns, scope, level, at, world, fresh, carried| {
	var $acc = none
	var $k = 0.U64
	for n in ns {
		$acc = plus($acc, drawn(n, scope, level, "${at}/${$k.to_str()}", world, fresh, carried))
		$k = $k + 1
	}
	$acc
}

drawn : Reference.Node, Scope, Level, Str, World, Bool, U64 -> Acc
drawn = |n, scope, level, at, world, fresh, carried| match n {
	Show(i) => reads(due(fresh, carried, val_at(scope, i).bit))
	Watch(_, i) => match world.count {
		Engine => reads(due(fresh, carried, val_at(scope, i).bit))
		Kernel => none
	}
	Guard(i) | Control(i) => match world.count {
		Engine => reads(2 * due(fresh, carried, val_at(scope, i).bit))
		Kernel => none
	}
	Bump(_) | Bump2(_, _) => none
	Pair(i, j) => {
		# A `derive` of `x`, and a text and a watch of `x`, the derived
		# value and `y` together.
		x = val_at(scope, i)
		y = val_at(scope, j)
		d = bit(scope.vals.len() + 1)
		input = due(fresh, carried, x.bit)
		inner = if (input == 1 and !fresh and x.old != x.new) carried.bitwise_or(d) else carried
		readers = match world.count {
			Engine => 2
			Kernel => 1
		}
		reads(input + readers * due(fresh, inner, x.bit.bitwise_or(d).bitwise_or(y.bit)))
	}
	When(sel, yes, no) => {
		v = chosen(scope, sel)
		even = v.new % 2 == 0
		kept = !fresh and (v.old % 2 == 0) == even
		plus(reads(due(fresh, carried, v.bit)), drawn_list(if (even) yes else no, scope, level, if (even) "${at}y" else "${at}n", world, !kept, carried))
	}
	Switch(sel, a, b, c) => {
		v = chosen(scope, sel)
		k = v.new % 3
		kept = !fresh and v.old % 3 == k
		plus(reads(due(fresh, carried, v.bit)), drawn_list(if (k == 0) a else if (k == 1) b else c, scope, level, "${at}s${k.to_str()}", world, !kept, carried))
	}
	Layer(kind, i, body) => match level_below(level) {
		Err(_) => drawn_list(body, scope, level, at, world, fresh, carried)
		Ok(below) => {
			depth = scope.vals.len() + 1
			b = bit(depth)
			if kind % 5 == 0 {
				new = held_value(world.after, at)
				old = if (fresh) new else held_value(world.before, at)
				written = world.writes.contains(at)
				inner = if (written) carried.bitwise_or(b) else carried
				own = { evals: due(fresh, inner, b), layers: if (written and !fresh) [depth] else [] }
				plus(own, drawn_list(body, { vals: scope.vals.append({ old, new, bit: b }), wrs: scope.wrs.append(at) }, below.layer, at, world, fresh, inner))
			} else {
				# A `derive`, or a `resource` whose `pending` is `x + 7`:
				# either recomputes for a changed input and carries its bit
				# only when its value changed.
				x = val_at(scope, i)
				of = |value| if (kind % 5 == 1) Reference.derived(kind, value) else value + 7
				new = of(x.new)
				old = if (fresh) new else of(x.old)
				input = due(fresh, carried, x.bit)
				inner = if (input == 1 and old != new) carried.bitwise_or(b) else carried
				plus(reads(input + due(fresh, inner, b)), drawn_list(body, { vals: scope.vals.append({ old, new, bit: b }), wrs: scope.wrs }, below.layer, at, world, fresh, inner))
			}
		}
	}
	Each(sel, body) => match level_below(level) {
		Err(_) => drawn_list(body, scope, level, at, world, fresh, carried)
		Ok(below) => {
			v = chosen(scope, sel)
			b = bit(scope.vals.len() + 1)
			was = if (fresh) [] else Reference.rows_of(v.old)
			Reference.rows_of(v.new).fold(
				reads(due(fresh, carried, v.bit)),
				|acc, row| {
					id = "${at}k${row.key.to_str()}"
					match was.find_first(|old| old.key == row.key) {
						Ok(old) => {
							# A kept row: its item's bit is carried when the item changed.
							inner = if (old.item != row.item) carried.bitwise_or(b) else carried
							plus(plus(acc, reads(due(Bool.False, inner, b))), drawn_list(body, { vals: scope.vals.append({ old: old.item, new: row.item, bit: b }), wrs: scope.wrs }, below.row, id, world, Bool.False, inner))
						}
						Err(_) => plus(plus(acc, reads(1)), drawn_list(body, { vals: scope.vals.append({ old: row.item, new: row.item, bit: b }), wrs: scope.wrs }, below.row, id, world, Bool.True, 0))
					}
				},
			)
		}
	}
}

## The identities of the scopes the page holds for the states `held`:
## every branch of a `when` or a `switch`, every row, and the branch of each
## document shortcut.
scopes : List(Reference.Node), Reference.Held -> List(Str)
scopes = |tree, held| {
	root_value = held_value(held, "")
	branch = if (root_value % 2 == 0) "y" else "n"
	var $shortcuts = []
	var $k = 0.U64
	while $k < tree.len() {
		$shortcuts = $shortcuts.append("aside/${$k.to_str()}${branch}")
		$k = $k + 1
	}
	shortcuts = $shortcuts
	scopes_list(tree, { vals: [{ old: root_value, new: root_value, bit: bit(1) }], wrs: [""] }, Root, "", held).concat(shortcuts)
}

scopes_list : List(Reference.Node), Scope, Level, Str, Reference.Held -> List(Str)
scopes_list = |ns, scope, level, at, held| {
	var $out = []
	var $k = 0.U64
	for n in ns {
		$out = $out.concat(scopes_of(n, scope, level, "${at}/${$k.to_str()}", held))
		$k = $k + 1
	}
	$out
}

scopes_of : Reference.Node, Scope, Level, Str, Reference.Held -> List(Str)
scopes_of = |n, scope, level, at, held| match n {
	When(sel, yes, no) => {
		even = chosen(scope, sel).new % 2 == 0
		id = if (even) "${at}y" else "${at}n"
		[id].concat(scopes_list(if (even) yes else no, scope, level, id, held))
	}
	Switch(sel, a, b, c) => {
		k = chosen(scope, sel).new % 3
		id = "${at}s${k.to_str()}"
		[id].concat(scopes_list(if (k == 0) a else if (k == 1) b else c, scope, level, id, held))
	}
	Layer(kind, i, body) => match level_below(level) {
		Err(_) => scopes_list(body, scope, level, at, held)
		Ok(below) => {
			b = bit(scope.vals.len() + 1)
			value = if kind % 5 == 0 {
				held_value(held, at)
			} else {
				x = val_at(scope, i).new
				if (kind % 5 == 1) Reference.derived(kind, x) else x + 7
			}
			wrs = if (kind % 5 == 0) scope.wrs.append(at) else scope.wrs
			scopes_list(body, { vals: scope.vals.append({ old: value, new: value, bit: b }), wrs }, below.layer, at, held)
		}
	}
	Each(sel, body) => match level_below(level) {
		Err(_) => scopes_list(body, scope, level, at, held)
		Ok(below) => {
			b = bit(scope.vals.len() + 1)
			Reference.rows_of(chosen(scope, sel).new).fold(
				[],
				|acc, row| {
					id = "${at}k${row.key.to_str()}"
					acc.append(id).concat(scopes_list(body, { vals: scope.vals.append({ old: row.item, new: row.item, bit: b }), wrs: scope.wrs }, below.row, id, held))
				},
			)
		}
	}
	_ => []
}

## A page with nothing in its tree reads the root's text once, at mount
## and when the root is written, and holds no scope.
expect {
	{ mount: Counts.mount([], []), click: Counts.turn([], [], [("", 1)], [""]) } == {
		mount: { evals: 1, created: 0, disposed: 0, layers: [] },
		click: { evals: 1, created: 0, disposed: 0, layers: [1] },
	}
}

## A `when` on the root under the root: a click that keeps its parity
## would not exist, so each click moves it; the branch and the shortcut's
## branch are disposed and created, and the condition, the shortcut's
## condition and the root's text are read.
expect Counts.turn([When(One(0), [Show(0)], [])], [], [("", 1)], [""]) == { evals: 3, created: 2, disposed: 2, layers: [1] }

## Every vector Lean wrote agrees with the kernel's count, step by step.
expect Vectors.good.keep_if(|trace| Counts.replay(trace) != Agrees).map(|trace| trace.name) == []

## Every known-bad trace that only a count rejects is rejected by the
## kernel's count at the step Lean rejects it, and agrees before it.
expect {
	count_only = Vectors.bad.keep_oks(
		|trace| match trace.label {
			KnownBad({ observation: Count, step, algorithm }) => Ok({ trace, step, algorithm })
			_ => Err(ByPage)
		},
	)
	missed = count_only.keep_if(|known| Counts.replay(known.trace) != Differs(known.step)).map(|known| "${known.algorithm} ${known.trace.name}")
	{ missed, count: count_only.len() > 0 } == { missed: [], count: Bool.True }
}
