## Indexed adjacency shared by the whole model, rather than one heap list per owner.
Links := {}.{
	Chain : { first : U64, last : U64 }
	Entry : { value : U64, next : U64 }
	empty : Chain
	empty = { first: 0, last: 0 }

	append : List(Entry), Chain, U64 -> { entries : List(Entry), chain : Chain }
	append = |entries, chain, value| {
		id = entries.len() + 1
		var $entries = entries
		if chain.last != 0 {
			old = $entries.get(chain.last - 1) ?? crash "missing chain tail"
			$entries = $entries.set(chain.last - 1, { ..old, next: id }) ?? crash "missing chain tail"
		}
		{ entries: $entries.append({ value, next: 0 }), chain: { first: if chain.first == 0 { id } else { chain.first }, last: id } }
	}

	entry : List(Entry), U64 -> Entry
	entry = |entries, id| entries.get(id - 1) ?? crash "missing chain entry"

	contains : List(Entry), Chain, U64 -> Bool
	contains = |entries, chain, value| {
		var $cursor = chain.first
		var $found = False
		while $cursor != 0 {
			current = entry(entries, $cursor)
			if current.value == value { $found = True }
			$cursor = current.next
		}
		$found
	}
}

## Two chains can interleave allocations without changing either chain's order.
expect {
	a = Links.append([], Links.empty, 7)
	b = Links.append(a.entries, Links.empty, 99)
	c = Links.append(b.entries, a.chain, 8)
	Links.entry(c.entries, a.chain.first).next == c.chain.last and Links.entry(c.entries, b.chain.first).value == 99 and Links.contains(c.entries, c.chain, 8)
}
