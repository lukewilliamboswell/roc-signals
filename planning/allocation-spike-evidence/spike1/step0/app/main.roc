app [main!] { pf: platform "../platform/main.roc" }

import pf.Cell

Rec : { name : Str, items : List(Str), tag : [Note(Str), Empty], n : U64 }

Reader : [A, B]

share : Box(a) -> { keep : Box(a), out : Box(a) }
share = |boxed| { keep: boxed, out: boxed }

read! : Reader, Cell => Box(a)
read! = |variant, cell|
	match variant {
		A => Cell.alias!(cell)
		B => Cell.share!(cell, Box.box(share))
	}

drop! : Box(a) => {}
drop! = |_boxed| {}

## The wrapper shape that the compiler's box_reuse pass rewrites to
## box_prepare_update. It must not update a shared box in place.
update : Box(a), (a -> a) -> Box(a)
update = |boxed, f| Box.box(f(Box.unbox(boxed)))

big : Str, U64 -> Str
big = |label, seed| {
	text = Str.with_capacity(256)
	text.concat(label).concat(" a string that is long enough to live on the heap ").concat(seed.to_str())
}

make_rec : U64 -> Rec
make_rec = |seed| {
	empty : List(Str)
	empty = List.with_capacity(16)
	{
		name: big("name", seed),
		items: empty.append(big("first", seed)).append(big("second", seed)),
		tag: Note(big("tag", seed)),
		n: seed,
	}
}

rec_mutate : Rec -> Rec
rec_mutate = |r| {
	items1 = r.items.append(big("third", r.n))
	# `set` overwrites in place when the list is unique, so a wrong uniqueness
	# decision corrupts the sibling alias rather than merely copying.
	items2 = match items1.set(0, big("replaced", r.n)) {
		Ok(list) => list
		Err(_) => crash "set"
	}
	tag =
		match r.tag {
			Note(s) => Note(s.concat(" tagged"))
			Empty => Empty
		}
	{ name: r.name.concat(" mutated"), items: items2, tag, n: r.n + 1 }
}

rec_orig : U64, Rec -> Bool
rec_orig = |seed, r| {
	tag_ok =
		match r.tag {
			Note(s) => s == big("tag", seed)
			Empty => Bool.False
		}
	r.name == big("name", seed) and r.items == [big("first", seed), big("second", seed)] and tag_ok and r.n == seed
}

rec_changed : U64, Rec -> Bool
rec_changed = |seed, r| {
	tag_ok =
		match r.tag {
			Note(s) => s == big("tag", seed).concat(" tagged")
			Empty => Bool.False
		}
	r.name == big("name", seed).concat(" mutated") and r.items == [big("replaced", seed), big("second", seed), big("third", seed)] and tag_ok and r.n == seed + 1
}

Ops(a) : { make : U64 -> a, mutate : a -> a, orig : U64, a -> Bool, changed : U64, a -> Bool }

id_of : Reader, U64, U64, U64 -> U64
id_of = |variant, payload, scenario, step| {
	v : U64
	v =
		match variant {
			A => 1
			B => 2
		}
	v * 1000000 + payload * 10000 + scenario * 100 + step
}

drop_cell! : Cell, Box(a) => {}
drop_cell! = |cell, _witness| {
	boxed = Cell.take!(cell)
	drop!(boxed)
}

## Read-only aliases, dropping the first holder before the second.
s1! : Reader, U64, U64, Ops(a) => {}
s1! = |variant, payload, seed, ops| {
	id = |step| id_of(variant, payload, 1, step)
	start = Cell.live!()
	initial : Box(a)
	initial = Box.box((ops.make)(seed))
	c1 = Cell.store!(initial)
	Cell.check!(id(0), Cell.rc!(c1) == 1)
	boxed : Box(a)
	boxed = read!(variant, c1)
	c2 = Cell.store!(boxed)
	Cell.check!(id(1), Cell.rc!(c1) == 2)
	Cell.check!(id(2), Cell.same!(c1, c2))
	held = Cell.live!()
	dropped : Box(a)
	dropped = Cell.take!(c1)
	drop!(dropped)
	Cell.check!(id(3), Cell.live!() == held)
	Cell.check!(id(4), Cell.rc!(c2) == 1)
	boxed2 : Box(a)
	boxed2 = read!(variant, c2)
	Cell.check!(id(5), (ops.orig)(seed, Box.unbox(boxed2)))
	dropped2 : Box(a)
	dropped2 = Cell.take!(c2)
	drop!(dropped2)
	Cell.check!(id(6), Cell.live!() == start)
}

## Read-only aliases, dropping the second holder before the first.
s2! : Reader, U64, U64, Ops(a) => {}
s2! = |variant, payload, seed, ops| {
	id = |step| id_of(variant, payload, 2, step)
	start = Cell.live!()
	initial : Box(a)
	initial = Box.box((ops.make)(seed))
	c1 = Cell.store!(initial)
	boxed : Box(a)
	boxed = read!(variant, c1)
	c2 = Cell.store!(boxed)
	held = Cell.live!()
	dropped : Box(a)
	dropped = Cell.take!(c2)
	drop!(dropped)
	Cell.check!(id(1), Cell.live!() == held)
	Cell.check!(id(2), Cell.rc!(c1) == 1)
	boxed2 : Box(a)
	boxed2 = read!(variant, c1)
	Cell.check!(id(3), (ops.orig)(seed, Box.unbox(boxed2)))
	dropped2 : Box(a)
	dropped2 = Cell.take!(c1)
	drop!(dropped2)
	Cell.check!(id(4), Cell.live!() == start)
}

## Mutate through one alias while shared, then drop the original first and
## require the mutated value to survive it.
s3! : Reader, U64, U64, Ops(a) => {}
s3! = |variant, payload, seed, ops| {
	id = |step| id_of(variant, payload, 3, step)
	start = Cell.live!()
	initial : Box(a)
	initial = Box.box((ops.make)(seed))
	c1 = Cell.store!(initial)
	out : Box(a)
	out = read!(variant, c1)
	mutated = (ops.mutate)(Box.unbox(out))
	m = Cell.store!(Box.box(mutated))
	Cell.check!(id(1), payload == 3 or Cell.rc!(c1) == 1)
	other : Box(a)
	other = read!(variant, c1)
	Cell.check!(id(2), (ops.orig)(seed, Box.unbox(other)))
	dropped : Box(a)
	dropped = Cell.take!(c1)
	drop!(dropped)
	after : Box(a)
	after = read!(variant, m)
	Cell.check!(id(3), (ops.changed)(seed, Box.unbox(after)))
	dropped2 : Box(a)
	dropped2 = Cell.take!(m)
	drop!(dropped2)
	Cell.check!(id(4), Cell.live!() == start)
}

## Mutate through one alias while shared, then drop the mutated value first and
## require the original to survive it.
s4! : Reader, U64, U64, Ops(a) => {}
s4! = |variant, payload, seed, ops| {
	id = |step| id_of(variant, payload, 4, step)
	start = Cell.live!()
	initial : Box(a)
	initial = Box.box((ops.make)(seed))
	c1 = Cell.store!(initial)
	out : Box(a)
	out = read!(variant, c1)
	m = Cell.store!(Box.box((ops.mutate)(Box.unbox(out))))
	dropped : Box(a)
	dropped = Cell.take!(m)
	drop!(dropped)
	other : Box(a)
	other = read!(variant, c1)
	Cell.check!(id(1), (ops.orig)(seed, Box.unbox(other)))
	dropped2 : Box(a)
	dropped2 = Cell.take!(c1)
	drop!(dropped2)
	Cell.check!(id(2), Cell.live!() == start)
}

## Drop the cell while Roc holds the only remaining alias, then unbox and
## mutate it: the unique path.
s5! : Reader, U64, U64, Ops(a) => {}
s5! = |variant, payload, seed, ops| {
	id = |step| id_of(variant, payload, 5, step)
	start = Cell.live!()
	initial : Box(a)
	initial = Box.box((ops.make)(seed))
	c1 = Cell.store!(initial)
	out : Box(a)
	out = read!(variant, c1)
	dropped : Box(a)
	dropped = Cell.take!(c1)
	drop!(dropped)
	m = Cell.store!(Box.box((ops.mutate)(Box.unbox(out))))
	after : Box(a)
	after = read!(variant, m)
	Cell.check!(id(1), (ops.changed)(seed, Box.unbox(after)))
	dropped2 : Box(a)
	dropped2 = Cell.take!(m)
	drop!(dropped2)
	Cell.check!(id(2), Cell.live!() == start)
}

## Two unboxed values outlive every box, and mutating one leaves the other.
s6! : Reader, U64, U64, Ops(a) => {}
s6! = |variant, payload, seed, ops| {
	id = |step| id_of(variant, payload, 6, step)
	start = Cell.live!()
	initial : Box(a)
	initial = Box.box((ops.make)(seed))
	c1 = Cell.store!(initial)
	first_box : Box(a)
	first_box = read!(variant, c1)
	second_box : Box(a)
	second_box = read!(variant, c1)
	first = Box.unbox(first_box)
	second = Box.unbox(second_box)
	dropped : Box(a)
	dropped = Cell.take!(c1)
	drop!(dropped)
	changed = (ops.mutate)(first)
	Cell.check!(id(1), (ops.changed)(seed, changed))
	Cell.check!(id(2), (ops.orig)(seed, second))
	Cell.check!(id(3), Cell.live!() == start)
}

## The direct box-update wrapper on a shared box must leave the sibling alone.
s7! : Reader, U64, U64, Ops(a) => {}
s7! = |variant, payload, seed, ops| {
	id = |step| id_of(variant, payload, 7, step)
	start = Cell.live!()
	initial : Box(a)
	initial = Box.box((ops.make)(seed))
	c1 = Cell.store!(initial)
	out : Box(a)
	out = read!(variant, c1)
	m = Cell.store!(update(out, ops.mutate))
	Cell.check!(id(1), !Cell.same!(c1, m))
	Cell.check!(id(2), payload == 3 or Cell.rc!(c1) == 1)
	other : Box(a)
	other = read!(variant, c1)
	Cell.check!(id(3), (ops.orig)(seed, Box.unbox(other)))
	after : Box(a)
	after = read!(variant, m)
	Cell.check!(id(4), (ops.changed)(seed, Box.unbox(after)))
	dropped : Box(a)
	dropped = Cell.take!(c1)
	drop!(dropped)
	dropped2 : Box(a)
	dropped2 = Cell.take!(m)
	drop!(dropped2)
	Cell.check!(id(5), Cell.live!() == start)
}

## The same wrapper on a unique box reuses the allocation legitimately.
s8! : Reader, U64, U64, Ops(a) => {}
s8! = |variant, payload, seed, ops| {
	id = |step| id_of(variant, payload, 8, step)
	start = Cell.live!()
	initial : Box(a)
	initial = Box.box((ops.make)(seed))
	c1 = Cell.store!(initial)
	out : Box(a)
	out = read!(variant, c1)
	dropped : Box(a)
	dropped = Cell.take!(c1)
	drop!(dropped)
	m = Cell.store!(update(out, ops.mutate))
	after : Box(a)
	after = read!(variant, m)
	Cell.check!(id(1), (ops.changed)(seed, Box.unbox(after)))
	dropped2 : Box(a)
	dropped2 = Cell.take!(m)
	drop!(dropped2)
	Cell.check!(id(2), Cell.live!() == start)
}

## Comparing a box with its own alias, as an equality capability would.
s9! : Reader, U64, U64, Ops(a) => {}
s9! = |variant, payload, seed, ops| {
	id = |step| id_of(variant, payload, 9, step)
	start = Cell.live!()
	initial : Box(a)
	initial = Box.box((ops.make)(seed))
	c1 = Cell.store!(initial)
	left : Box(a)
	left = read!(variant, c1)
	right : Box(a)
	right = read!(variant, c1)
	Cell.check!(id(1), Cell.rc!(c1) == 3)
	Cell.check!(id(2), (ops.orig)(seed, Box.unbox(left)))
	Cell.check!(id(3), (ops.orig)(seed, Box.unbox(right)))
	Cell.check!(id(4), Cell.rc!(c1) == 1)
	dropped : Box(a)
	dropped = Cell.take!(c1)
	drop!(dropped)
	Cell.check!(id(5), Cell.live!() == start)
}

## Zero-sized payloads have no meaningful count, so only the holders' lifetimes
## and the ledger are checked.
matrix0! : U64, U64, Ops(a) => {}
matrix0! = |payload, seed, ops| {
	s4!(A, payload, seed, ops)
	s4!(B, payload, seed, ops)
	s5!(A, payload, seed, ops)
	s5!(B, payload, seed, ops)
	s6!(A, payload, seed, ops)
	s6!(B, payload, seed, ops)
	s8!(A, payload, seed, ops)
	s8!(B, payload, seed, ops)
}

matrix! : U64, U64, Ops(a) => {}
matrix! = |payload, seed, ops| {
	s1!(A, payload, seed, ops)
	s1!(B, payload, seed, ops)
	s2!(A, payload, seed, ops)
	s2!(B, payload, seed, ops)
	s3!(A, payload, seed, ops)
	s3!(B, payload, seed, ops)
	s4!(A, payload, seed, ops)
	s4!(B, payload, seed, ops)
	s5!(A, payload, seed, ops)
	s5!(B, payload, seed, ops)
	s6!(A, payload, seed, ops)
	s6!(B, payload, seed, ops)
	s7!(A, payload, seed, ops)
	s7!(B, payload, seed, ops)
	s8!(A, payload, seed, ops)
	s8!(B, payload, seed, ops)
	s9!(A, payload, seed, ops)
	s9!(B, payload, seed, ops)
}

capture_fn : U64 -> (Str -> Str)
capture_fn = |seed| {
	captured = big("captured", seed)
	|suffix| captured.concat(suffix)
}

Boxed : { inner : Box(Str), label : Str }

WithFn : { call : Str -> Str, label : Str }

Choice : [Plain, WithStr(Str), WithBoth(Str, List(Str))]

main! : () => {}
main! = || {
	seed = Cell.seed!()
	matrix!(1, seed, { make: make_rec, mutate: rec_mutate, orig: rec_orig, changed: rec_changed })
	matrix!(
		2,
		seed,
		{
			make: |s| big("plain", s),
			mutate: |text| text.concat(" changed"),
			orig: |s, text| text == big("plain", s),
			changed: |s, text| text == big("plain", s).concat(" changed"),
		},
	)

	# 3: a boxed closure capturing a heap Str.
	matrix!(
		3,
		seed,
		{
			make: capture_fn,
			mutate: |old| |suffix| old(suffix).concat(" wrapped"),
			orig: |s, f| f(" tail") == big("captured", s).concat(" tail"),
			changed: |s, f| f(" tail") == big("captured", s).concat(" tail").concat(" wrapped"),
		},
	)

	# 4: a record holding a closure and a heap Str, as a capability bundle does.
	make_with_fn : U64 -> WithFn
	make_with_fn = |s| { call: capture_fn(s), label: big("label", s) }
	matrix!(
		4,
		seed,
		{
			make: make_with_fn,
			mutate: |r| {
				old = r.call
				{ call: |suffix| old(suffix).concat(" wrapped"), label: r.label.concat(" changed") }
			},
			orig: |s, r| (r.call)(" tail") == big("captured", s).concat(" tail") and r.label == big("label", s),
			changed: |s, r| (r.call)(" tail") == big("captured", s).concat(" tail").concat(" wrapped") and r.label == big("label", s).concat(" changed"),
		},
	)

	# 5: a nested box.
	make_boxed : U64 -> Boxed
	make_boxed = |s| { inner: Box.box(big("inner", s)), label: big("label", s) }
	matrix!(
		5,
		seed,
		{
			make: make_boxed,
			mutate: |r| { inner: Box.box(Box.unbox(r.inner).concat(" changed")), label: r.label },
			orig: |s, r| Box.unbox(r.inner) == big("inner", s) and r.label == big("label", s),
			changed: |s, r| Box.unbox(r.inner) == big("inner", s).concat(" changed") and r.label == big("label", s),
		},
	)

	# 6: a tag union whose payload is refcounted in only some variants.
	make_choice : U64 -> Choice
	make_choice = |s| WithBoth(big("left", s), [big("right", s)])
	matrix!(
		6,
		seed,
		{
			make: make_choice,
			mutate: |c|
				match c {
					WithBoth(left, right) => WithBoth(left.concat(" changed"), right.append(big("more", 0)))
					other => other
				},
			orig: |s, c|
				match c {
					WithBoth(left, right) => left == big("left", s) and right == [big("right", s)]
					_ => Bool.False
				},
			changed: |s, c|
				match c {
					WithBoth(left, right) => left == big("left", s).concat(" changed") and right == [big("right", s), big("more", 0)]
					_ => Bool.False
				},
		},
	)

	# 7: a scalar, with no nested refcounts at all.
	matrix!(
		7,
		seed,
		{
			make: |s| s,
			mutate: |n| n + 1,
			orig: |s, n| n == s,
			changed: |s, n| n == s + 1,
		},
	)

	# 9: a zero-sized payload, which may have no refcount word to raise.
	matrix0!(9, seed, { make: |_s| {}, mutate: |u| u, orig: |_s, _u| Bool.True, changed: |_s, _u| Bool.True })

	# 8: a list of scalars, which has no element refcounts.
	matrix!(
		8,
		seed,
		{
			make: |s| List.with_capacity(16).append(s).append(s + 1),
			mutate: |l| l.append(99),
			orig: |s, l| l == [s, s + 1],
			changed: |s, l| l == [s, s + 1, 99],
		},
	)
}
