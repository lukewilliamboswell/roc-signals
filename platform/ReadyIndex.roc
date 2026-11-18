## The placeholder queue's private numeric-address index. It stores only live
## eligible owners, not application values or historical scope identities.
##
## A compressed binary radix tree has Q leaves and Q-1 forks. Fork bits strictly
## decrease, so each traversal visits at most 64 forks. Lookup uses one traversal;
## insert and remove use at most two. Removing a leaf
## collapses its parent immediately. No operation scans pending owners. Updating
## copies only bounded-size nodes on that path; it never copies the whole index.
##
## This avoids the supplied compiler's shape-dependent Wasm Dict remove/reinsert
## allocation growth: https://github.com/roc-lang/roc/issues/13194. The standalone
## reproduction measures both dev and size; this is a narrow internal workaround,
## not a change to public table storage or to placeholder scheduling meaning.
ReadyIndex(a) :: { tree : [Empty, Filled(Node(a))], count : U64 }.{

	## Empty has no retained nodes or earlier owner data.
	empty : () -> ReadyIndex(a)
	empty = || { tree: Empty, count: 0 }

	## Count live entries without walking the tree.
	len : ReadyIndex(a) -> U64
	len = |index| index.count

	## Follow at most 64 discriminating bits. A missing key is not repaired.
	get : ReadyIndex(a), U64 -> Try(a, [Missing])
	get = |index, key| match index.tree {
		Empty => Err(Missing)
		Filled(node) => find(node, key)
	}

	## Membership has the same bounded traversal and retains no sampled owner.
	contains : ReadyIndex(a), U64 -> Bool
	contains = |index, key| index.get(key).is_ok()

	## Insert or overwrite one key. The tree shape is canonical for its key set;
	## at most 64 old forks are reconstructed, independently of entry count.
	insert : ReadyIndex(a), { key : U64, value : a } -> ReadyIndex(a)
	insert = |index, entry| match index.tree {
		Empty => { tree: Filled(Leaf(entry)), count: 1 }
		Filled(node) => {
			other = nearest_key(node, entry.key)
			if other == entry.key {
				{ tree: Filled(replace(node, entry)), count: index.count }
			} else {
				{ tree: Filled(insert_new(node, { entry, bit: split_bit(entry.key, other) })), count: index.count + 1 }
			}
		}
	}

	## Remove one live key and its now-unary parent. The removed value and
	## obsolete path nodes are released here. Membership and removal each visit
	## at most 64 forks.
	remove : ReadyIndex(a), U64 -> ReadyIndex(a)
	remove = |index, key| {
		if !index.contains(key) {
			return index
		}
		match index.tree {
			Empty => crash "internal: ReadyIndex.remove found a key in an empty index"
			Filled(node) => { tree: remove_known(node, key), count: index.count - 1 }
		}
	}

	## A diagnostic-only structural comparison. Canonical forks make equality
	## independent of insertion order; cost is O(Q), never part of an update.
	is_eq : ReadyIndex(a), ReadyIndex(a) -> Bool
		where [a.is_eq : a, a -> Bool]
	is_eq = |first, second| first.count == second.count and match (first.tree, second.tree) {
		(Empty, Empty) => True
		(Filled(left), Filled(right)) => same(left, right)
		_ => False
	}

	## Validate branch ordering, key separation and the exact live count. This
	## diagnostic walk costs O(Q); only expects and engine settled checks use it.
	is_valid : ReadyIndex(a) -> Bool
	is_valid = |index| match index.tree {
		Empty => index.count == 0
		Filled(node) => match validate(node, 64) {
			Ok(report) => report.count == index.count
			Err(InvalidIndex) => False
		}
	}
}

## Both fork children are nonempty by type; no tombstones or vacant slots can
## keep a removed owner alive. A box breaks the recursive layout, not ownership.
Node(a) := [Leaf({ key : U64, value : a }), Fork(Box({ bit : U8, left : Node(a), right : Node(a) }))]

has_bit : U64, U8 -> Bool
has_bit = |key, bit| key.shr_zf_wrap(bit).bitwise_and(1) == 1

split_bit : U64, U64 -> U8
split_bit = |first, second| {
	difference = first.bitwise_xor(second)
	var $bit = 63.U8
	while True {
		if has_bit(difference, $bit) {
			return $bit
		}
		if $bit == 0 {
			crash "internal: ReadyIndex.split_bit requires different keys"
		}
		$bit = $bit - 1
	}
}

find : Node(a), U64 -> Try(a, [Missing])
find = |node, key| match node {
	Leaf(entry) => if (entry.key == key) Ok(entry.value) else Err(Missing)
	Fork(boxed) => {
		fork = Box.unbox(boxed)
		find(if (has_bit(key, fork.bit)) fork.right else fork.left, key)
	}
}

nearest_key : Node(a), U64 -> U64
nearest_key = |node, key| match node {
	Leaf(entry) => entry.key
	Fork(boxed) => {
		fork = Box.unbox(boxed)
		nearest_key(if (has_bit(key, fork.bit)) fork.right else fork.left, key)
	}
}

replace : Node(a), { key : U64, value : a } -> Node(a)
replace = |node, entry| match node {
	Leaf(old) => {
		if old.key != entry.key {
			crash "internal: ReadyIndex.replace followed a different key"
		}
		Leaf(entry)
	}
	Fork(boxed) => {
		{ bit, left, right } = Box.unbox(boxed)
		if has_bit(entry.key, bit) {
			Fork(Box.box({ bit, left, right: replace(right, entry) }))
		} else {
			Fork(Box.box({ bit, left: replace(left, entry), right }))
		}
	}
}

insert_new : Node(a), { entry : { key : U64, value : a }, bit : U8 } -> Node(a)
insert_new = |node, { entry, bit: split }| match node {
	Leaf(_) => fork_at(node, { entry, bit: split })
	Fork(boxed) => {
		{ bit, left, right } = Box.unbox(boxed)
		if bit > split {
			if has_bit(entry.key, bit) {
				Fork(Box.box({ bit, left, right: insert_new(right, { entry, bit: split }) }))
			} else {
				Fork(Box.box({ bit, left: insert_new(left, { entry, bit: split }), right }))
			}
		} else {
			fork_at(Fork(Box.box({ bit, left, right })), { entry, bit: split })
		}
	}
}

fork_at : Node(a), { entry : { key : U64, value : a }, bit : U8 } -> Node(a)
fork_at = |node, { entry, bit }| if has_bit(entry.key, bit) {
	Fork(Box.box({ bit, left: node, right: Leaf(entry) }))
} else {
	Fork(Box.box({ bit, left: Leaf(entry), right: node }))
}

remove_known : Node(a), U64 -> [Empty, Filled(Node(a))]
remove_known = |node, key| match node {
	Leaf(entry) => {
		if entry.key != key {
			crash "internal: ReadyIndex.remove_known followed a different key"
		}
		Empty
	}
	Fork(boxed) => {
		{ bit, left, right } = Box.unbox(boxed)
		if has_bit(key, bit) {
			match remove_known(right, key) {
				Empty => Filled(left)
				Filled(next) => Filled(Fork(Box.box({ bit, left, right: next })))
			}
		} else {
			match remove_known(left, key) {
				Empty => Filled(right)
				Filled(next) => Filled(Fork(Box.box({ bit, left: next, right })))
			}
		}
	}
}

same : Node(a), Node(a) -> Bool
	where [a.is_eq : a, a -> Bool]
same = |first, second| match (first, second) {
	(Leaf(left), Leaf(right)) => left.key == right.key and left.value == right.value
	(Fork(left), Fork(right)) => {
		a = Box.unbox(left)
		b = Box.unbox(right)
		a.bit == b.bit and same(a.left, b.left) and same(a.right, b.right)
	}
	_ => False
}

validate : Node(a), U8 -> Try({ count : U64, representative : U64 }, [InvalidIndex])
validate = |node, limit| match node {
	Leaf(entry) => Ok({ count: 1, representative: entry.key })
	Fork(boxed) => {
		{ bit, left, right } = Box.unbox(boxed)
		if bit >= limit {
			return Err(InvalidIndex)
		}
		a = validate(left, bit)?
		b = validate(right, bit)?
		if has_bit(a.representative, bit) or !has_bit(b.representative, bit) {
			return Err(InvalidIndex)
		}
		if bit < 63 and a.representative.bitwise_xor(b.representative).shr_zf_wrap(bit + 1) != 0 {
			return Err(InvalidIndex)
		}
		Ok({ count: a.count + b.count, representative: a.representative })
	}
}

## High-bit boundaries, overwrites and every removal preserve exact lookup and
## release all forks when the last live entry is removed.
expect {
	keys = [0.U64, 1, 0x8000000000000000, 0xffffffffffffffff, 0x100000000, 0x100000001]
	var $index = ReadyIndex.empty()
	for key in keys {
		$index = $index.insert({ key, value: key })
		if !$index.is_valid() {
			crash "index insertion invariant"
		}
	}
	$index = $index.insert({ key: 1, value: 9 })
	if $index.len() != keys.len() or $index.get(1) != Ok(9) {
		crash "index overwrite changed count or failed lookup"
	}
	for key in keys {
		$index = $index.remove(key)
		if !$index.is_valid() or $index.contains(key) {
			crash "index removal invariant"
		}
	}
	$index == ReadyIndex.empty()
}

## Construction order cannot change the canonical key structure used by the
## settled diagnostic; overwriting and reinsert cycles do not retain history.
expect {
	keys = [5.U64, 0xffffffffffffffff, 0, 1, 256, 257, 0x8000000000000000]
	a = keys.fold(ReadyIndex.empty(), |out, key| out.insert({ key, value: key }))
	b = keys.fold([], |out, key| [key].concat(out)).fold(ReadyIndex.empty(), |out, key| out.insert({ key, value: key }))
	a == b and a.remove(5).insert({ key: 5, value: 5 }) == a
}

## An independent finite-map model checks every lookup after each edit, including
## absent keys, overwritten values and mixed high/low bit prefixes.
expect {
	keys = [0.U64, 1, 2, 3, 255, 256, 257, 0x7fffffffffffffff, 0x8000000000000000, 0x8000000000000001, 0xfffffffffffffffe, 0xffffffffffffffff]
	var $index = ReadyIndex.empty()
	var $model = Dict.empty()
	for turn in 0.U64..<96 {
		key = keys.get((turn * 7) % keys.len()) ?? crash "fixed key position"
		if turn % 3 == 0 {
			$index = $index.remove(key)
			$model = $model.remove(key)
		} else {
			$index = $index.insert({ key, value: turn })
			$model = $model.insert(key, turn)
		}
		if !$index.is_valid() or $index.len() != $model.len() {
			crash "ready index structure or live count differs from finite map"
		}
		for probe in keys.concat([42, 0x8000000000000042]) {
			if $index.get(probe) != $model.get(probe).map_err(|_| Missing) or $index.contains(probe) != $model.contains(probe) {
				crash "ready index lookup differs from finite map"
			}
		}
	}
	True
}
