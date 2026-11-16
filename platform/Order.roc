## Small ordered values for table-view plans and ordinary Roc sorting. Each
## comparison uses its parts' order_relative_to; text uses explicit byte order,
## without locale collation, normalization or an encoded sort key.
Order := [].{

	## Compare two values by their type's own order, as List.sort does.
	compare : a, a -> [Before, Same, After]
		where [a.order_relative_to : a, a -> [Before, Same, After]]
	compare = |left, right| left.order_relative_to(right)

	## Order by the first part, then the second when the first ties.
	Pair(a, b) := [Pair(a, b)].{

		## Equality includes both stored priorities.
		is_eq : _

		## Compare both parts in priority order, preserving their own equality.
		order_relative_to : Pair(a, b), Pair(a, b) -> [Before, Same, After]
			where [a.order_relative_to : a, a -> [Before, Same, After], b.order_relative_to : b, b -> [Before, Same, After]]
		order_relative_to = |Pair(left, left_next), Pair(right, right_next)| match left.order_relative_to(right) {
			Same => left_next.order_relative_to(right_next)
			other => other
		}
	}

	## One type for an order whose direction can be chosen at runtime. Ascending
	## and descending groups are distinct when mixed in one collection.
	Direction(a) := [Asc(a), Desc(a)].{

		## Equality includes the direction as well as the stored value.
		is_eq : _

		## Ascending compares normally; descending reverses Before and After.
		## Across directions the ascending group comes first, giving a total order.
		order_relative_to : Direction(a), Direction(a) -> [Before, Same, After]
			where [a.order_relative_to : a, a -> [Before, Same, After]]
		order_relative_to = |left, right| match (left, right) {
			(Asc(a), Asc(b)) => a.order_relative_to(b)
			(Desc(a), Desc(b)) => b.order_relative_to(a)
			(Asc(_), Desc(_)) => Before
			(Desc(_), Asc(_)) => After
		}
	}

	## Text ordered lexicographically by its UTF-8 bytes. This agrees with Str
	## equality, but is not a reader's language-sensitive or normalized order.
	Utf8 := [Utf8(Str)].{

		## Equal text has exactly the same UTF-8 bytes.
		is_eq : _

		## Walk the two strings without allocating byte lists or sort keys.
		order_relative_to : Utf8, Utf8 -> [Before, Same, After]
		order_relative_to = |Utf8(left), Utf8(right)| compare_bytes(left.iter_utf8(), right.iter_utf8())
	}

	## Build a sort value with two priorities; nest pairs for more priorities.
	pair : a, b -> Pair(a, b)
	pair = |first, second| Pair(first, second)

	## Keep a value's own ordering in a direction that can later be changed.
	asc : a -> Direction(a)
	asc = |value| Asc(value)

	## Reverse a value's own order without negating or otherwise changing it.
	desc : a -> Direction(a)
	desc = |value| Desc(value)

	## Select descending when requested, keeping both directions in one type.
	directed : a, Bool -> Direction(a)
	directed = |value, descending| if (descending) Desc(value) else Asc(value)

	## Give text an explicit byte order, useful for stable identifier tie-breaks.
	utf8 : Str -> Utf8
	utf8 = |text| Utf8(text)
}

compare_bytes : Iter(U8), Iter(U8) -> [Before, Same, After]
compare_bytes = |left, right| match left.next() {
	Done => match right.next() {
		Done => Same
		Skip({ rest }) => compare_bytes(left, rest)
		One(_) => Before
	}
	Skip({ rest }) => compare_bytes(rest, right)
	One(a) => match right.next() {
		Done => After
		Skip({ rest }) => compare_bytes(left, rest)
		One(b) => match a.item.order_relative_to(b.item) {
			Same => compare_bytes(a.rest, b.rest)
			other => other
		}
	}
}

## A second priority decides only when the first is equal.
expect [Order.pair(2.U64, 0.U64), Order.pair(1, 2), Order.pair(1, 1)].sort() == [Order.pair(1, 1), Order.pair(1, 2), Order.pair(2, 0)]

## Reversing order preserves extreme values instead of negating them.
expect [Order.desc((-9223372036854775808.I64)), Order.desc(9223372036854775807.I64), Order.desc(0)].sort() == [Order.desc(9223372036854775807.I64), Order.desc(0), Order.desc((-9223372036854775808.I64))]

## A runtime direction has one type, with Same for equal values in that direction.
expect {
	{ up: Order.compare(Order.directed(1.U64, False), Order.asc(2)), down: Order.compare(Order.directed(1.U64, True), Order.desc(2)), same: Order.compare(Order.desc(2.U64), Order.desc(2)) } == { up: Before, down: After, same: Same }
}

## Mixed directions keep a total ordering by group, then by the group's direction.
expect [Order.desc(1.U64), Order.asc(2), Order.desc(2), Order.asc(1)].sort() == [Order.asc(1), Order.asc(2), Order.desc(2), Order.desc(1)]

## Byte ordering handles empty text, prefixes, ASCII case and multi-byte scalars.
expect ["é", "ab", "a", "", "Z"].map(Order.utf8).sort() == ["", "Z", "a", "ab", "é"].map(Order.utf8)

## Different normalization forms remain different, agreeing with Str equality.
expect Order.compare(Order.utf8("e\u(0301)"), Order.utf8("é")) == Before and Order.utf8("e\u(0301)") != Order.utf8("é")

## Several priorities compose without deriving or encoding an application's data.
expect Order.compare(Order.pair(Order.desc(2.U64), Order.utf8("b")), Order.pair(Order.desc(2.U64), Order.utf8("c"))) == Before
