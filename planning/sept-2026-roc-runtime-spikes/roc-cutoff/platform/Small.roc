## A single entry lives in the owning record; multiple entries use ARC overflow.
Small(a) := [Empty, One(a), Many(List(a))].{
	append : Small(a), a -> Small(a)
	append = |items, value| match items {
		Empty => One(value)
		One(a) => Many([a, value])
		Many(values) => Many(values.append(value))
	}

	len : Small(a) -> U64
	len = |items| match items { Empty => 0, One(_) => 1, Many(values) => values.len() }

	get : Small(a), U64 -> a
	get = |items, index| match (items, index) {
		(One(a), 0) => a
		(Many(values), i) => values.get(i) ?? crash "small collection index out of bounds"
		_ => crash "small collection index out of bounds"
	}
}

## Inline and overflow storage preserve insertion order and independent aliases.
expect {
	var $items = Small.Empty
	for i in U64.until(0, 12) { $items = $items.append(i) }
	alias = $items
	changed = $items.append(12)
	alias.len() == 12 and alias.get(4) == 4 and changed.len() == 13 and changed.get(12) == 12
}
