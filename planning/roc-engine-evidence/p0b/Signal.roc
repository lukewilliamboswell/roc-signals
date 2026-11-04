import Val

## A site-level reactive value: one graph node, the same for every row.
##
## Unchanged from today's vocabulary except that a `Signal(a)` can be used
## wherever a `Val(ctx, a)` is accepted, in any context, through `to_val`.
## Sketch representation only.
Signal(a) :: { read : Box((() -> a)) }.{

	## One exact-key selector shared by every row of a site. Read it per row with
	## `Ui.RowRef.select`; a change dirties only the old and new key's rows.
	Keyed(value) :: { selected : Box((() -> Str)), when_selected : value, otherwise : value }

	## Use this site-level signal as a context value. A function, so it is
	## polymorphic in `ctx` at every call site.
	to_val : Signal(a) -> Val(ctx, a)
	to_val = |signal| Val.platform_site(Box.unbox(signal.read))

	## A constant signal.
	const : a -> Signal(a)
		where [
			a.is_eq : a, a -> Bool,
		]
	const = |value| { read: Box.box(|| value) }

	## Equality-pruned derived signal.
	map : Signal(a), (a -> b) -> Signal(b)
		where [
			b.is_eq : b, b -> Bool,
		]
	map = |signal, f| {
		read = Box.unbox(signal.read)
		{ read: Box.box(|| f(read())) }
	}

	## Derived signal from two inputs; also the record-builder hook.
	map2 : Signal(a), Signal(b), (a, b -> c) -> Signal(c)
		where [
			c.is_eq : c, c -> Bool,
		]
	map2 = |left, right, f| {
		l = Box.unbox(left.read)
		r = Box.unbox(right.read)
		{ read: Box.box(|| f(l(), r())) }
	}

	## Prepare an exact-key selector once per site.
	keyed : Signal(Str), value, value -> Keyed(value)
		where [
			value.is_eq : value, value -> Bool,
		]
	keyed = |selected, when_selected, otherwise| { selected: selected.read, when_selected, otherwise }

	## Platform-private: build from a read thunk.
	platform_from_read : (() -> a) -> Signal(a)
	platform_from_read = |read| { read: Box.box(read) }

	## Platform-private: evaluate a keyed selector for one key.
	platform_keyed_for : Keyed(value), Str -> value
	platform_keyed_for = |selector, key|
		if Box.unbox(selector.selected)() == key {
			selector.when_selected
		} else {
			selector.otherwise
		}
}
