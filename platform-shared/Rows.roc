## Immutable keyed rows for dynamic UI structure. `Rows(item)` owns its key
## function, caches exact UTF-8 keys, preserves stable slot identity, and records
## an authenticated one-generation transition for the host. Applications use the
## collection operations below; the `platform_*` functions are internal adapter
## hooks for `Ui.each` and the shared engine.

## A persistent AVL directory. Every edit rebuilds its search path and any
## adjacent rotation nodes; retained generations never copy a flat entry table.
## Cached heights and sizes describe live entries, not historical capacity.
RowsIndex(key, value) := [IndexEmpty, IndexNode({ key : key, value : value, left : RowsIndex(key, value), right : RowsIndex(key, value), height : U64, size : U64 })].{
	empty : () -> RowsIndex(key, value)
	empty = || IndexEmpty

	len : RowsIndex(key, value) -> U64
	len = |tree| match tree {
		IndexEmpty => 0
		IndexNode(node) => node.size
	}

	is_empty : RowsIndex(key, value) -> Bool
	is_empty = |tree| tree.len() == 0

	get : RowsIndex(key, value), key -> Try(value, [Missing])
		where [key.is_lt : key, key -> Bool]
	get = |tree, key| match tree {
		IndexEmpty => Err(Missing)
		IndexNode(node) => if key.is_lt(node.key) {
			RowsIndex.get(node.left, key)
		} else if node.key.is_lt(key) {
			RowsIndex.get(node.right, key)
		} else {
			Ok(node.value)
		}
	}

	insert : RowsIndex(key, value), key, value -> RowsIndex(key, value)
		where [key.is_lt : key, key -> Bool]
	insert = |tree, key, value| match tree {
		IndexEmpty => rows_index_node(key, value, IndexEmpty, IndexEmpty)
		IndexNode(node) => if key.is_lt(node.key) {
			rows_index_balance(node.key, node.value, node.left.insert(key, value), node.right)
		} else if node.key.is_lt(key) {
			rows_index_balance(node.key, node.value, node.left, node.right.insert(key, value))
		} else {
			rows_index_node(key, value, node.left, node.right)
		}
	}

	remove : RowsIndex(key, value), key -> RowsIndex(key, value)
		where [key.is_lt : key, key -> Bool]
	remove = |tree, key| match tree {
		IndexEmpty => IndexEmpty
		IndexNode(node) => if key.is_lt(node.key) {
			rows_index_balance(node.key, node.value, node.left.remove(key), node.right)
		} else if node.key.is_lt(key) {
			rows_index_balance(node.key, node.value, node.left, node.right.remove(key))
		} else {
			match node.right {
				IndexEmpty => node.left
				IndexNode(_) => {
					first = rows_index_take_first(node.right)
					rows_index_balance(first.key, first.value, node.left, first.rest)
				}
			}
		}
	}
}

rows_index_height : RowsIndex(key, value) -> U64
rows_index_height = |tree| match tree {
	IndexEmpty => 0
	IndexNode(node) => node.height
}

rows_index_node : key, value, RowsIndex(key, value), RowsIndex(key, value) -> RowsIndex(key, value)
rows_index_node = |key, value, left, right| {
	left_height = rows_index_height(left)
	right_height = rows_index_height(right)
	IndexNode({
		key,
		value,
		left,
		right,
		height: 1 + if left_height > right_height {
			left_height
		} else {
			right_height
		},
		size: 1 + left.len() + right.len(),
	})
}

rows_index_balance : key, value, RowsIndex(key, value), RowsIndex(key, value) -> RowsIndex(key, value)
rows_index_balance = |key, value, left, right| {
	if rows_index_height(left) > rows_index_height(right) + 1 {
		match left {
			IndexEmpty => crash "Rows index missing heavy left branch"
			IndexNode(child) => if rows_index_height(child.left) >= rows_index_height(child.right) {
				rows_index_node(child.key, child.value, child.left, rows_index_node(key, value, child.right, right))
			} else {
				match child.right {
					IndexEmpty => crash "Rows index missing left rotation pivot"
					IndexNode(pivot) => rows_index_node(pivot.key, pivot.value, rows_index_node(child.key, child.value, child.left, pivot.left), rows_index_node(key, value, pivot.right, right))
				}
			}
		}
	} else if rows_index_height(right) > rows_index_height(left) + 1 {
		match right {
			IndexEmpty => crash "Rows index missing heavy right branch"
			IndexNode(child) => if rows_index_height(child.right) >= rows_index_height(child.left) {
				rows_index_node(child.key, child.value, rows_index_node(key, value, left, child.left), child.right)
			} else {
				match child.left {
					IndexEmpty => crash "Rows index missing right rotation pivot"
					IndexNode(pivot) => rows_index_node(pivot.key, pivot.value, rows_index_node(key, value, left, pivot.left), rows_index_node(child.key, child.value, pivot.right, child.right))
				}
			}
		}
	} else {
		rows_index_node(key, value, left, right)
	}
}

rows_index_take_first : RowsIndex(key, value) -> { key : key, value : value, rest : RowsIndex(key, value) }
rows_index_take_first = |tree| match tree {
	IndexEmpty => crash "Rows index minimum of empty tree"
	IndexNode(node) => match node.left {
		IndexEmpty => { key: node.key, value: node.value, rest: node.right }
		IndexNode(_) => {
			first = rows_index_take_first(node.left)
			{ ..first, rest: rows_index_balance(node.key, node.value, first.rest, node.right) }
		}
	}
}

## Exact UTF-8 ordering makes key comparison deterministic without a hash
## collision bucket. Its byte comparison cost is explicit in every key lookup.
RowsKey := [RowsKey(Str)].{
	is_lt : RowsKey, RowsKey -> Bool
	is_lt = |RowsKey(left), RowsKey(right)| {
		left_bytes = left.to_utf8()
		right_bytes = right.to_utf8()
		var $index = 0
		var $less = left_bytes.len() < right_bytes.len()
		var $done = False
		while !$done and $index < left_bytes.len() and $index < right_bytes.len() {
			a = left_bytes.get($index) ?? crash "Rows key byte missing"
			b = right_bytes.get($index) ?? crash "Rows key byte missing"
			if a != b {
				$less = a < b
				$done = True
			}
			$index = $index + 1
		}
		$less
	}
}

RowsKeyIndex := [RowsKeyIndex(RowsIndex(RowsKey, U64))].{
	empty : () -> RowsKeyIndex
	empty = || RowsKeyIndex(RowsIndex.empty())
	get : RowsKeyIndex, Str -> Try(U64, [Missing])
	get = |RowsKeyIndex(tree), key| RowsIndex.get(tree, RowsKey(key))
	insert : RowsKeyIndex, Str, U64 -> RowsKeyIndex
	insert = |RowsKeyIndex(tree), key, value| RowsKeyIndex(tree.insert(RowsKey(key), value))
	remove : RowsKeyIndex, Str -> RowsKeyIndex
	remove = |RowsKeyIndex(tree), key| RowsKeyIndex(tree.remove(RowsKey(key)))
	len : RowsKeyIndex -> U64
	len = |RowsKeyIndex(tree)| tree.len()
}

## Free IDs and edit history use a persistent stack indexed by dense positions.
## Retained edit states must not force full-list copying on every new touch. Push/pop
## copy only logarithmic AVL paths, and releasing a retained stack has bounded
## tree depth rather than one recursive destructor frame per vacant slot.
RowsIdStack := { items : RowsIndex(U64, U64) }.{
	empty : () -> RowsIdStack
	empty = || { items: RowsIndex.empty() }
	prepend : RowsIdStack, U64 -> RowsIdStack
	prepend = |free, value| { items: free.items.insert(free.items.len(), value) }
	first : RowsIdStack -> Try(U64, [Missing])
	first = |free| if free.items.is_empty() {
		Err(Missing)
	} else {
		free.items.get(free.items.len() - 1)
	}
	drop_first : RowsIdStack, U64 -> RowsIdStack
	drop_first = |free, count| {
		var $items = free.items
		var $remaining = count
		while $remaining > 0 and !$items.is_empty() {
			$items = $items.remove($items.len() - 1)
			$remaining = $remaining - 1
		}
		{ items: $items }
	}
	len : RowsIdStack -> U64
	len = |free| free.items.len()
	is_empty : RowsIdStack -> Bool
	is_empty = |free| free.items.is_empty()
	from_list : List(U64) -> RowsIdStack
	from_list = |values| { items: rows_id_stack_from_range(values, 0, values.len()) }
	to_list : RowsIdStack -> List(U64)
	to_list = |free| {
		var $items = List.with_capacity(free.len())
		var $remaining = free.len()
		while $remaining > 0 {
			$remaining = $remaining - 1
			$items = $items.append(free.items.get($remaining) ?? crash "Rows free stack position missing")
		}
		$items
	}
}

## Build the complete free stack in linear work without retaining a chain of
## intermediate AVL roots. Descending stack positions preserve list-first reuse.
rows_id_stack_from_range : List(U64), U64, U64 -> RowsIndex(U64, U64)
rows_id_stack_from_range = |values, first, count| if count == 0 {
	RowsIndex.empty()
} else {
	left_count = count.div_trunc_by(2)
	middle = first + left_count
	value = values.get(values.len() - 1 - middle) ?? crash "Rows free stack builder index missing"
	rows_index_node(middle, value, rows_id_stack_from_range(values, first, left_count), rows_id_stack_from_range(values, middle + 1, count - left_count - 1))
}

## Slot IDs reserve 32 bits for the index; 32-cell chunks leave 27 directory
## bits. Six bounded 32-way levels cover that complete space. Copy-on-write
## retains at most 32 child lists at each level, even when old generations live.
## Empty branches allocate nothing, and directory shape depends on slot IDs,
## never the number of generations or a retained flat-table capacity.
## Keep the directory structural and its helpers top-level: generic nominal
## methods currently fail with application-item payloads on the pinned compiler.
## https://github.com/roc-lang/roc/issues/11377
RowsDirectoryCell(value) : [DirectoryEmpty, DirectoryValue(value)]

RowsSlotDirectory(value) : { root : List(List(List(List(List(List(RowsDirectoryCell(value))))))), count : U64 }

rows_slot_directory_empty : () -> RowsSlotDirectory(value)
rows_slot_directory_empty = || { root: [], count: 0 }

rows_slot_directory_len : RowsSlotDirectory(value) -> U64
rows_slot_directory_len = |directory| directory.count

rows_slot_directory_is_empty : RowsSlotDirectory(value) -> Bool
rows_slot_directory_is_empty = |directory| directory.count == 0

rows_slot_directory_get : RowsSlotDirectory(value), U64 -> Try(value, [Missing])
rows_slot_directory_get = |directory, key| {
	if key >= 134217728 {
		Err(Missing)
	} else {
		level_0 = directory.root.get(key.div_trunc_by(33554432).rem_by(32)) ? |_| Missing
		level_1 = level_0.get(key.div_trunc_by(1048576).rem_by(32)) ? |_| Missing
		level_2 = level_1.get(key.div_trunc_by(32768).rem_by(32)) ? |_| Missing
		level_3 = level_2.get(key.div_trunc_by(1024).rem_by(32)) ? |_| Missing
		level_4 = level_3.get(key.div_trunc_by(32).rem_by(32)) ? |_| Missing
		level_5 = level_4.get(key.div_trunc_by(1).rem_by(32)) ? |_| Missing
		match level_5 {
			DirectoryEmpty => Err(Missing)
			DirectoryValue(value) => Ok(value)
		}
	}
}

## Keep each bounded branch update behind one call boundary. Besides sharing
## the operation, this prevents ownership paths from multiplying across levels.
rows_directory_set_child : List(List(value)), U64, List(value) -> List(List(value))
rows_directory_set_child = |children, index, child| {
	var $children = children
	while $children.len() <= index {
		$children = $children.append([])
	}
	$children.set(index, child) ?? crash "Rows slot directory branch was missing"
}

rows_slot_directory_insert : RowsSlotDirectory(value), U64, value -> RowsSlotDirectory(value)
rows_slot_directory_insert = |directory, key, value| {
	if key >= 134217728 {
		crash "Rows slot directory exceeds the packed index space"
	}
	offset_0 = key.div_trunc_by(33554432).rem_by(32)
	offset_1 = key.div_trunc_by(1048576).rem_by(32)
	offset_2 = key.div_trunc_by(32768).rem_by(32)
	offset_3 = key.div_trunc_by(1024).rem_by(32)
	offset_4 = key.div_trunc_by(32).rem_by(32)
	offset_5 = key.div_trunc_by(1).rem_by(32)
	var $level_0 = directory.root
	var $level_1 = $level_0.get(offset_0) ?? []
	var $level_2 = $level_1.get(offset_1) ?? []
	var $level_3 = $level_2.get(offset_2) ?? []
	var $level_4 = $level_3.get(offset_3) ?? []
	var $level_5 = $level_4.get(offset_4) ?? []
	added = match $level_5.get(offset_5) {
		Ok(DirectoryValue(_)) => False
		_ => True
	}
	while $level_5.len() <= offset_5 {
		$level_5 = $level_5.append(DirectoryEmpty)
	}
	$level_5 = $level_5.set(offset_5, DirectoryValue(value)) ?? crash "Rows slot directory leaf was missing"
	$level_4 = rows_directory_set_child($level_4, offset_4, $level_5)
	$level_3 = rows_directory_set_child($level_3, offset_3, $level_4)
	$level_2 = rows_directory_set_child($level_2, offset_2, $level_3)
	$level_1 = rows_directory_set_child($level_1, offset_1, $level_2)
	$level_0 = rows_directory_set_child($level_0, offset_0, $level_1)
	{
		root: $level_0,
		count: directory.count + if added {
			1
		} else {
			0
		},
	}
}

RowsGenerationCallable : Box(({} -> Box({})))

RowsEntry(item) : { slot : U64, key : Str, item : item }

RowsOrderNode := [OrderBranch({ children : List(U64), len : U64 }), OrderLeaf({ slots : List(U64), len : U64 })]

RowsOrderParent : [OrderParent({ node : U64, child : U64 }), OrderRoot]

RowsOrderCell(value) : [OrderCellEmpty, OrderCellValue(value)]

RowsOrderTable(value) : RowsIndex(U64, List(RowsOrderCell(value)))

RowsOrderEntry(value) : { key : U64, value : value }

rows_order_table_chunk_size : U64
rows_order_table_chunk_size = 32

rows_order_table_location : U64 -> { chunk : U64, offset : U64 }
rows_order_table_location = |key| {
	if key == 0 {
		crash "Rows order table key must be nonzero"
	}
	zero_index = key - 1
	{ chunk: zero_index.div_trunc_by(rows_order_table_chunk_size), offset: zero_index.rem_by(rows_order_table_chunk_size) }
}

rows_order_table_get : RowsOrderTable(value), U64 -> Try(value, [Missing])
rows_order_table_get = |table, key| {
	location = rows_order_table_location(key)
	chunk = table.get(location.chunk) ? |_| Missing
	cell = chunk.get(location.offset) ? |_| Missing
	match cell {
		OrderCellEmpty => Err(Missing)
		OrderCellValue(value) => Ok(value)
	}
}

## Store one value in a bounded 32-cell chunk and path-copy its AVL directory.
## Retaining the old table never copies or retains every directory entry.
rows_order_table_set : RowsOrderTable(value), U64, value -> RowsOrderTable(value)
rows_order_table_set = |table, key, value| {
	location = rows_order_table_location(key)
	var $chunk = table.get(location.chunk) ?? []
	while $chunk.len() <= location.offset {
		$chunk = $chunk.append(OrderCellEmpty)
	}
	updated = $chunk.set(location.offset, OrderCellValue(value)) ?? crash "Rows order table offset was invalid"
	table.insert(location.chunk, updated)
}

rows_order_table_remove : RowsOrderTable(value), U64 -> RowsOrderTable(value)
rows_order_table_remove = |table, key| {
	location = rows_order_table_location(key)
	match table.get(location.chunk) {
		Err(_) => table
		Ok(chunk) =>
			match chunk.set(location.offset, OrderCellEmpty) {
				Err(_) => table
				Ok(updated) => table.insert(location.chunk, updated)
			}
		}
}

## Build a table from arbitrary nonzero keys by sorting once, then publishing
## each completed 32-cell chunk with one persistent directory insertion.
rows_order_table_from_entries : List(RowsOrderEntry(value)) -> RowsOrderTable(value)
rows_order_table_from_entries = |entries| {
	sorted = entries.sort_with(
		|left, right| if left.key < right.key {
			Before
		} else if left.key > right.key {
			After
		} else {
			Same
		},
	)
	var $table = RowsIndex.empty()
	var $chunk_key = 0
	var $chunk = []
	var $has_chunk = False
	for entry in sorted {
		location = rows_order_table_location(entry.key)
		if $has_chunk and location.chunk != $chunk_key {
			$table = $table.insert($chunk_key, $chunk)
			$chunk = []
		}
		$has_chunk = True
		$chunk_key = location.chunk
		while $chunk.len() < location.offset {
			$chunk = $chunk.append(OrderCellEmpty)
		}
		$chunk = $chunk.append(OrderCellValue(entry.value))
	}
	if $has_chunk {
		$table.insert($chunk_key, $chunk)
	} else {
		$table
	}
}

RowsOrder : {
	root : U64,
	nodes : RowsOrderTable(RowsOrderNode),
	parents : RowsOrderTable(RowsOrderParent),
	slot_leaf : RowsOrderTable(U64),
	next_node : U64,
	free_nodes : RowsIdStack,
}

rows_order_node_len : RowsOrderNode -> U64
rows_order_node_len = |node|
	match node {
		OrderLeaf({ len, .. }) => len
		OrderBranch({ len, .. }) => len
	}

rows_order_empty : () -> RowsOrder
rows_order_empty = || {
	nodes = rows_order_table_set(RowsIndex.empty(), 1, OrderLeaf({ slots: [], len: 0 }))
	parents = rows_order_table_set(RowsIndex.empty(), 1, OrderRoot)
	slot_leaf : RowsOrderTable(U64)
	slot_leaf = RowsIndex.empty()
	{ root: 1, nodes, parents, slot_leaf, next_node: 2, free_nodes: RowsIdStack.empty() }
}

## Build a fresh 32-way order tree bottom-up. Snapshot construction already
## knows the complete stable-slot sequence, so inserting each slot through the
## persistent edit path would repeatedly rewrite the same root-to-leaf paths.
rows_order_from_slots : List(U64) -> RowsOrder
rows_order_from_slots = |slots| {
	if slots.is_empty() {
		rows_order_empty()
	} else {
		leaf_count = (slots.len() + 31).div_trunc_by(32)
		var $node_capacity = leaf_count
		var $level_count = leaf_count
		while $level_count > 1 {
			$level_count = ($level_count + 31).div_trunc_by(32)
			$node_capacity = $node_capacity + $level_count
		}
		var $node_lengths = List.with_capacity($node_capacity)
		var $node_entries = List.with_capacity($node_capacity)
		var $parent_entries = List.with_capacity($node_capacity)
		var $slot_leaf_entries = List.with_capacity(slots.len())
		var $next_node = 1
		var $offset = 0
		var $level = List.with_capacity(leaf_count)
		while $offset < slots.len() {
			leaf_slots = slots.drop_first($offset).take_first(32)
			leaf_id = $next_node
			$next_node = $next_node + 1
			leaf = OrderLeaf({ slots: leaf_slots, len: leaf_slots.len() })
			$node_lengths = $node_lengths.append(leaf_slots.len())
			$node_entries = $node_entries.append({ key: leaf_id, value: leaf })
			for slot in leaf_slots {
				$slot_leaf_entries = $slot_leaf_entries.append({ key: rows_slot_index(slot), value: leaf_id })
			}
			$level = $level.append(leaf_id)
			$offset = $offset + leaf_slots.len()
		}

		while $level.len() > 1 {
			var $next_level = List.with_capacity(($level.len() + 31).div_trunc_by(32))
			var $child_offset = 0
			while $child_offset < $level.len() {
				children = $level.drop_first($child_offset).take_first(32)
				branch_id = $next_node
				$next_node = $next_node + 1
				var $len = 0
				var $child_index = 0
				for child_id in children {
					child_len = $node_lengths.get(child_id - 1) ?? crash "Rows bulk order child was missing"
					$len = $len + child_len
					$parent_entries = $parent_entries.append({ key: child_id, value: OrderParent({ node: branch_id, child: $child_index }) })
					$child_index = $child_index + 1
				}
				branch = OrderBranch({ children, len: $len })
				$node_lengths = $node_lengths.append($len)
				$node_entries = $node_entries.append({ key: branch_id, value: branch })
				$next_level = $next_level.append(branch_id)
				$child_offset = $child_offset + children.len()
			}
			$level = $next_level
		}

		root = $level.get(0) ?? crash "Rows bulk order lost its root"
		$parent_entries = $parent_entries.append({ key: root, value: OrderRoot })
		{
			root,
			nodes: rows_order_table_from_entries($node_entries),
			parents: rows_order_table_from_entries($parent_entries),
			slot_leaf: rows_order_table_from_entries($slot_leaf_entries),
			next_node: $next_node,
			free_nodes: RowsIdStack.empty(),
		}
	}
}

rows_order_allocate_node : RowsOrder -> { node : U64, order : RowsOrder }
rows_order_allocate_node = |order|
	match order.free_nodes.first() {
		Ok(node) => { node, order: { ..order, free_nodes: order.free_nodes.drop_first(1) } }
		Err(_) => {
			if order.next_node == 18446744073709551615 {
				crash "Rows order node id space exhausted"
			}
			{ node: order.next_node, order: { ..order, next_node: order.next_node + 1 } }
		}
	}

rows_order_len : RowsOrder -> U64
rows_order_len = |order| {
	root = rows_order_table_get(order.nodes, order.root) ?? crash "Rows order root was missing"
	rows_order_node_len(root)
}

RowsOrderLocation : { leaf : U64, offset : U64 }

rows_order_locate_node : RowsOrder, U64, U64, Bool -> RowsOrderLocation
rows_order_locate_node = |order, node_id, index, allow_end| {
	node = rows_order_table_get(order.nodes, node_id) ?? crash "Rows order node was missing"
	match node {
		OrderLeaf({ slots, .. }) => {
			if index < slots.len() or (allow_end and index == slots.len()) {
				{ leaf: node_id, offset: index }
			} else {
				crash "Rows order index exceeded its leaf"
			}
		}
		OrderBranch({ children, len }) => {
			if index > len or (!allow_end and index == len) {
				crash "Rows order index exceeded its branch"
			}
			var $remaining = index
			var $child_index = 0
			var $chosen = children.len() - 1
			var $found = False
			while $found == False and $child_index < children.len() {
				child_id = children.get($child_index) ?? crash "Rows order child index was invalid"
				child = rows_order_table_get(order.nodes, child_id) ?? crash "Rows order child was missing"
				child_len = rows_order_node_len(child)
				if $remaining < child_len or (allow_end and $remaining == child_len and $child_index + 1 == children.len()) {
					$chosen = $child_index
					$found = True
				} else {
					$remaining = $remaining - child_len
					$child_index = $child_index + 1
				}
			}
			chosen_id = children.get($chosen) ?? crash "Rows order branch had no child"
			rows_order_locate_node(order, chosen_id, $remaining, allow_end)
		}
	}
}

rows_order_locate : RowsOrder, U64, Bool -> RowsOrderLocation
rows_order_locate = |order, index, allow_end| rows_order_locate_node(order, order.root, index, allow_end)

rows_order_get : RowsOrder, U64 -> Try(U64, [Missing])
rows_order_get = |order, index|
	if index >= rows_order_len(order) {
		Err(Missing)
	} else {
		location = rows_order_locate(order, index, False)
		leaf = rows_order_table_get(order.nodes, location.leaf) ?? crash "Rows order leaf was missing"
		match leaf {
			OrderLeaf({ slots, .. }) =>
				match slots.get(location.offset) {
					Ok(slot) => Ok(slot)
					Err(_) => Err(Missing)
				}
			OrderBranch(_) => crash "Rows order location named a branch"
		}
	}

RowsOrderRewrite : { order : RowsOrder, replacements : List(U64) }

rows_order_children_len : RowsOrder, List(U64) -> U64
rows_order_children_len = |order, children| {
	var $len = 0
	for child_id in children {
		child = rows_order_table_get(order.nodes, child_id) ?? crash "Rows order child was missing while measuring"
		$len = $len + rows_order_node_len(child)
	}
	$len
}

rows_order_set_child_parents : RowsOrder, U64, List(U64) -> RowsOrder
rows_order_set_child_parents = |order, parent_id, children| {
	var $parents = order.parents
	var $index = 0
	while $index < children.len() {
		child_id = children.get($index) ?? crash "Rows order child index was invalid while parenting"
		existing = rows_order_table_get($parents, child_id)
		unchanged = match existing {
			Ok(OrderParent(parent)) => parent.node == parent_id and parent.child == $index
			_ => False
		}
		if !unchanged {
			$parents = rows_order_table_set($parents, child_id, OrderParent({ node: parent_id, child: $index }))
		}
		$index = $index + 1
	}
	{ ..order, parents: $parents }
}

rows_order_insert_node : RowsOrder, U64, U64, U64 -> RowsOrderRewrite
rows_order_insert_node = |order, node_id, index, slot| {
	node = rows_order_table_get(order.nodes, node_id) ?? crash "Rows order insertion node was missing"
	match node {
		OrderLeaf({ slots, len }) => {
			inserted = slots.take_first(index).concat([slot]).concat(slots.drop_first(index))
			if inserted.len() <= 32 {
				nodes = rows_order_table_set(order.nodes, node_id, OrderLeaf({ slots: inserted, len: len + 1 }))
				updated_leaf_order = { ..order, nodes, slot_leaf: rows_order_table_set(order.slot_leaf, rows_slot_index(slot), node_id) }
				{ order: updated_leaf_order, replacements: [node_id] }
			} else {
				left_slots = inserted.take_first(16)
				right_slots = inserted.drop_first(16)
				allocation = rows_order_allocate_node(order)
				right_id = allocation.node
				left_nodes = rows_order_table_set(allocation.order.nodes, node_id, OrderLeaf({ slots: left_slots, len: left_slots.len() }))
				nodes = rows_order_table_set(left_nodes, right_id, OrderLeaf({ slots: right_slots, len: right_slots.len() }))
				var $slot_leaf = allocation.order.slot_leaf
				if index < 16 {
					$slot_leaf = rows_order_table_set($slot_leaf, rows_slot_index(slot), node_id)
				}
				for right_slot in right_slots {
					$slot_leaf = rows_order_table_set($slot_leaf, rows_slot_index(right_slot), right_id)
				}
				{
					order: { ..allocation.order, nodes, slot_leaf: $slot_leaf },
					replacements: [node_id, right_id],
				}
			}
		}
		OrderBranch({ children, len }) => {
			var $remaining = index
			var $child_index = 0
			var $chosen = children.len() - 1
			var $found = False
			while $found == False and $child_index < children.len() {
				child_id = children.get($child_index) ?? crash "Rows order branch child was missing"
				child = rows_order_table_get(order.nodes, child_id) ?? crash "Rows order branch child node was missing"
				child_len = rows_order_node_len(child)
				if $remaining < child_len or ($remaining == child_len and $child_index + 1 == children.len()) {
					$chosen = $child_index
					$found = True
				} else {
					$remaining = $remaining - child_len
					$child_index = $child_index + 1
				}
			}
			chosen_id = children.get($chosen) ?? crash "Rows order branch had no insertion child"
			child_rewrite = rows_order_insert_node(order, chosen_id, $remaining, slot)
			replaced_children =
				children.take_first($chosen).concat(child_rewrite.replacements).concat(children.drop_first($chosen + 1))
			if replaced_children.len() <= 32 {
				updated_order = {
					..child_rewrite.order,
					nodes: rows_order_table_set(child_rewrite.order.nodes, node_id, OrderBranch({ children: replaced_children, len: len + 1 })),
				}
				parented = if child_rewrite.replacements.len() == 1 {
					updated_order
				} else {
					rows_order_set_child_parents(updated_order, node_id, replaced_children)
				}
				{ order: parented, replacements: [node_id] }
			} else {
				left_children = replaced_children.take_first(16)
				right_children = replaced_children.drop_first(16)
				allocation = rows_order_allocate_node(child_rewrite.order)
				right_id = allocation.node
				left_len = rows_order_children_len(child_rewrite.order, left_children)
				right_len = rows_order_children_len(child_rewrite.order, right_children)
				left_nodes = rows_order_table_set(allocation.order.nodes, node_id, OrderBranch({ children: left_children, len: left_len }))
				nodes = rows_order_table_set(left_nodes, right_id, OrderBranch({ children: right_children, len: right_len }))
				split_order = { ..allocation.order, nodes }
				left_parented = rows_order_set_child_parents(split_order, node_id, left_children)
				right_parented = rows_order_set_child_parents(left_parented, right_id, right_children)
				{ order: right_parented, replacements: [node_id, right_id] }
			}
		}
	}
}

rows_order_insert : RowsOrder, U64, U64 -> RowsOrder
rows_order_insert = |order, index, slot| {
	if index > rows_order_len(order) {
		crash "Rows order insertion index exceeded its length"
	}
	rewrite = rows_order_insert_node(order, order.root, index, slot)
	if rewrite.replacements.len() == 1 {
		rewrite.order
	} else {
		allocation = rows_order_allocate_node(rewrite.order)
		root_id = allocation.node
		root_len = rows_order_children_len(rewrite.order, rewrite.replacements)
		nodes = rows_order_table_set(allocation.order.nodes, root_id, OrderBranch({ children: rewrite.replacements, len: root_len }))
		parents = rows_order_table_set(allocation.order.parents, root_id, OrderRoot)
		rooted = { ..allocation.order, root: root_id, nodes, parents }
		rows_order_set_child_parents(rooted, root_id, rewrite.replacements)
	}
}

RowsOrderRemoval : { order : RowsOrder, removed : U64, replacements : List(U64) }

rows_order_remove_node : RowsOrder, U64, U64 -> RowsOrderRemoval
rows_order_remove_node = |order, node_id, index| {
	node = rows_order_table_get(order.nodes, node_id) ?? crash "Rows order removal node was missing"
	match node {
		OrderLeaf({ slots, len }) => {
			removed = slots.get(index) ?? crash "Rows order removal index exceeded its leaf"
			remaining = slots.take_first(index).concat(slots.drop_first(index + 1))
			nodes =
				if remaining.is_empty() {
					rows_order_table_remove(order.nodes, node_id)
				} else {
					rows_order_table_set(order.nodes, node_id, OrderLeaf({ slots: remaining, len: len - 1 }))
				}
			parents = if remaining.is_empty() {
				rows_order_table_remove(order.parents, node_id)
			} else {
				order.parents
			}
			free_nodes = if remaining.is_empty() {
				order.free_nodes.prepend(node_id)
			} else {
				order.free_nodes
			}
			next_order = { ..order, nodes, parents, free_nodes, slot_leaf: rows_order_table_remove(order.slot_leaf, rows_slot_index(removed)) }
			{
				order: next_order,
				removed,
				replacements: if remaining.is_empty() {
					[]
				} else {
					[node_id]
				},
			}
		}
		OrderBranch({ children, len }) => {
			var $remaining = index
			var $child_index = 0
			var $chosen = 0
			var $found = False
			while $found == False and $child_index < children.len() {
				child_id = children.get($child_index) ?? crash "Rows order removal child was missing"
				child = rows_order_table_get(order.nodes, child_id) ?? crash "Rows order removal child node was missing"
				child_len = rows_order_node_len(child)
				if $remaining < child_len {
					$chosen = $child_index
					$found = True
				} else {
					$remaining = $remaining - child_len
					$child_index = $child_index + 1
				}
			}
			chosen_id = children.get($chosen) ?? crash "Rows order removal branch had no child"
			child_removal = rows_order_remove_node(order, chosen_id, $remaining)
			replaced_children =
				children.take_first($chosen).concat(child_removal.replacements).concat(children.drop_first($chosen + 1))
			nodes =
				if replaced_children.is_empty() {
					rows_order_table_remove(child_removal.order.nodes, node_id)
				} else {
					rows_order_table_set(child_removal.order.nodes, node_id, OrderBranch({ children: replaced_children, len: len - 1 }))
				}
			parents = if replaced_children.is_empty() {
				rows_order_table_remove(child_removal.order.parents, node_id)
			} else {
				child_removal.order.parents
			}
			free_nodes = if replaced_children.is_empty() {
				child_removal.order.free_nodes.prepend(node_id)
			} else {
				child_removal.order.free_nodes
			}
			updated = { ..child_removal.order, nodes, parents, free_nodes }
			parented = rows_order_set_child_parents(updated, node_id, replaced_children)
			{
				order: parented,
				removed: child_removal.removed,
				replacements: if replaced_children.is_empty() {
					[]
				} else {
					[node_id]
				},
			}
		}
	}
}

rows_order_remove : RowsOrder, U64 -> { order : RowsOrder, removed : U64 }
rows_order_remove = |order, index| {
	removal = rows_order_remove_node(order, order.root, index)
	if removal.replacements.is_empty() {
		fresh = rows_order_empty()
		{ order: fresh, removed: removal.removed }
	} else {
		root_id = removal.replacements.get(0) ?? crash "Rows order removal lost its root"
		root_node = rows_order_table_get(removal.order.nodes, root_id) ?? crash "Rows order removal root was missing"
		collapsed_root =
			match root_node {
				OrderBranch({ children, .. }) =>
					if children.len() == 1 {
						children.get(0) ?? crash "Rows order unary branch had no child"
					} else {
						root_id
					}
				OrderLeaf(_) => root_id
			}
		collapsed_order =
			if collapsed_root == root_id {
				removal.order
			} else {
				{ ..removal.order, nodes: rows_order_table_remove(removal.order.nodes, root_id), parents: rows_order_table_remove(removal.order.parents, root_id), free_nodes: removal.order.free_nodes.prepend(root_id) }
			}
		parents = rows_order_table_set(collapsed_order.parents, collapsed_root, OrderRoot)
		{ order: { ..collapsed_order, root: collapsed_root, parents }, removed: removal.removed }
	}
}

rows_order_rank : RowsOrder, U64 -> Try(U64, [Missing])
rows_order_rank = |order, slot| {
	leaf_id = rows_order_table_get(order.slot_leaf, rows_slot_index(slot)) ? |_| Missing
	leaf = rows_order_table_get(order.nodes, leaf_id) ?? crash "Rows slot leaf was missing"
	leaf_offset =
		match leaf {
			OrderBranch(_) => crash "Rows slot leaf named a branch"
			OrderLeaf({ slots, .. }) => {
				var $index = 0
				var $found = False
				var $offset = 0
				while $found == False and $index < slots.len() {
					candidate = slots.get($index) ?? crash "Rows leaf slot index was invalid"
					if candidate == slot {
						$found = True
						$offset = $index
					}
					$index = $index + 1
				}
				if $found == True {
					$offset
				} else {
					crash "Rows slot leaf did not contain its slot"
				}
			}
		}
	var $rank = leaf_offset
	var $node_id = leaf_id
	var $done = False
	while $done == False {
		parent = rows_order_table_get(order.parents, $node_id) ?? crash "Rows order parent was missing"
		match parent {
			OrderRoot => {
				$done = True
			}
			OrderParent({ node: parent_id, child: child_index }) => {
				parent_node = rows_order_table_get(order.nodes, parent_id) ?? crash "Rows order parent node was missing"
				match parent_node {
					OrderLeaf(_) => crash "Rows order parent was a leaf"
					OrderBranch({ children, .. }) => {
						var $sibling = 0
						while $sibling < child_index {
							sibling_id = children.get($sibling) ?? crash "Rows order sibling index was invalid"
							sibling_node = rows_order_table_get(order.nodes, sibling_id) ?? crash "Rows order sibling was missing"
							$rank = $rank + rows_order_node_len(sibling_node)
							$sibling = $sibling + 1
						}
					}
				}
				$node_id = parent_id
			}
		}
	}
	Ok($rank)
}

rows_order_fold_node : RowsOrder, U64, state, (state, U64 -> state) -> state
rows_order_fold_node = |order, node_id, initial, push| {
	node = rows_order_table_get(order.nodes, node_id) ?? crash "Rows order fold node was missing"
	match node {
		OrderLeaf({ slots, .. }) => slots.fold(initial, push)
		OrderBranch({ children, .. }) =>
			children.fold(initial, |state, child_id| rows_order_fold_node(order, child_id, state, push))
		}
}

rows_order_fold : RowsOrder, state, (state, U64 -> state) -> state
rows_order_fold = |order, initial, push| rows_order_fold_node(order, order.root, initial, push)

RowsSlotCell(item) : [RowsSlotLive({ generation : U64, key : Str, item : item }), RowsSlotVacant({ generation : U64 }), RowsSlotRetired]

RowsSlotStore(item) : {
	chunks : RowsSlotDirectory(List(RowsSlotCell(item))),
	free : RowsIdStack,
	next_index : U64,
}

RowsSlotAllocation(item) : { slot : U64, slots : RowsSlotStore(item) }

rows_slot_base : U64
rows_slot_base = 4294967296

rows_slot_pack : U64, U64 -> U64
rows_slot_pack = |index, generation| generation * rows_slot_base + index

rows_slot_index : U64 -> U64
rows_slot_index = |slot| slot.rem_by(rows_slot_base)

rows_slot_generation : U64 -> U64
rows_slot_generation = |slot| slot.div_trunc_by(rows_slot_base)

rows_slots_empty : () -> RowsSlotStore(item)
rows_slots_empty = || {
	chunks : RowsSlotDirectory(List(RowsSlotCell(item)))
	chunks = rows_slot_directory_empty()
	{ chunks, free: RowsIdStack.empty(), next_index: 1 }
}

rows_slots_cell : RowsSlotStore(item), U64 -> Try(RowsSlotCell(item), [Missing])
rows_slots_cell = |slots, index| {
	if index == 0 {
		Err(Missing)
	} else {
		zero_index = index - 1
		chunk_index = zero_index.div_trunc_by(32)
		offset = zero_index.rem_by(32)
		chunk = rows_slot_directory_get(slots.chunks, chunk_index) ? |_| Missing
		match chunk.get(offset) {
			Ok(cell) => Ok(cell)
			Err(_) => Err(Missing)
		}
	}
}

rows_slots_set_cell : RowsSlotStore(item), U64, RowsSlotCell(item) -> RowsSlotStore(item)
rows_slots_set_cell = |slots, index, cell| {
	zero_index = index - 1
	chunk_index = zero_index.div_trunc_by(32)
	offset = zero_index.rem_by(32)
	chunk = rows_slot_directory_get(slots.chunks, chunk_index) ?? []
	updated_chunk =
		if offset == chunk.len() {
			chunk.append(cell)
		} else {
			chunk.set(offset, cell) ?? crash "Rows slot chunk offset was invalid"
		}
	{ ..slots, chunks: rows_slot_directory_insert(slots.chunks, chunk_index, updated_chunk) }
}

rows_slots_get : RowsSlotStore(item), U64 -> Try({ key : Str, item : item }, [Missing])
rows_slots_get = |slots, slot| {
	index = rows_slot_index(slot)
	generation = rows_slot_generation(slot)
	cell = rows_slots_cell(slots, index)?
	match cell {
		RowsSlotLive(live) =>
			if live.generation == generation {
				Ok({ key: live.key, item: live.item })
			} else {
				Err(Missing)
			}
		RowsSlotVacant(_) => Err(Missing)
		RowsSlotRetired => Err(Missing)
	}
}

rows_slots_allocate : RowsSlotStore(item), Str, item -> Try(RowsSlotAllocation(item), Rows.Error)
rows_slots_allocate = |slots, key, item| {
	match slots.free.first() {
		Ok(index) => {
			cell = rows_slots_cell(slots, index) ?? crash "Rows free slot was missing"
			generation =
				match cell {
					RowsSlotVacant({ generation: stored_generation }) => stored_generation
					_ => crash "Rows free slot was not vacant"
				}
			next_slots = { ..slots, free: slots.free.drop_first(1) }
			stored = rows_slots_set_cell(next_slots, index, RowsSlotLive({ generation, key, item }))
			Ok({ slot: rows_slot_pack(index, generation), slots: stored })
		}
		Err(_) => {
			if slots.next_index >= rows_slot_base {
				Err(Rows.Error.SlotExhausted)
			} else {
				index = slots.next_index
				generation = 1
				stored = rows_slots_set_cell({ ..slots, next_index: index + 1 }, index, RowsSlotLive({ generation, key, item }))
				Ok({ slot: rows_slot_pack(index, generation), slots: stored })
			}
		}
	}
}

rows_slots_replace : RowsSlotStore(item), U64, Str, item -> Try(RowsSlotStore(item), [Missing])
rows_slots_replace = |slots, slot, key, item| {
	index = rows_slot_index(slot)
	generation = rows_slot_generation(slot)
	cell = rows_slots_cell(slots, index)?
	match cell {
		RowsSlotLive(live) =>
			if live.generation == generation {
				Ok(rows_slots_set_cell(slots, index, RowsSlotLive({ generation, key, item })))
			} else {
				Err(Missing)
			}
		_ => Err(Missing)
	}
}

rows_slots_release : RowsSlotStore(item), U64 -> Try(RowsSlotStore(item), [Missing])
rows_slots_release = |slots, slot| {
	index = rows_slot_index(slot)
	generation = rows_slot_generation(slot)
	cell = rows_slots_cell(slots, index)?
	match cell {
		RowsSlotLive(live) =>
			if live.generation != generation {
				Err(Missing)
			} else if generation == 4294967295 {
				Ok(rows_slots_set_cell(slots, index, RowsSlotRetired))
			} else {
				next_generation = generation + 1
				vacant = rows_slots_set_cell(slots, index, RowsSlotVacant({ generation: next_generation }))
				Ok({ ..vacant, free: vacant.free.prepend(index) })
			}
		_ => Err(Missing)
	}
}

RowsTransition : [
	ClearRows,
	InsertRow({ before_slot : U64, key : Str, op_index : U64, slot : U64 }),
	MoveRows({ before_slot : U64, count : U64, first_slot : U64, op_index : U64 }),
	RemoveRows({ count : U64, first_slot : U64, op_index : U64 }),
	UpdateRow({ key : Str, op_index : U64, slot : U64 }),
]

RowsStorage(item) : {
	token : RowsGenerationCallable,
	parent : [NoParent, Parent(RowsGenerationCallable)],
	transition : [Delta(List(RowsTransition)), Snapshot],
	key_of : Box((item -> Str)),
	order : RowsOrder,
	slots : RowsSlotStore(item),
	key_index : RowsKeyIndex,
	snapshot_key_bytes : U64,
	op_count : U64,
	delta_key_count : U64,
	delta_key_bytes : U64,
}

RowsBuild(item) : {
	order_slots : List(U64),
	slots : RowsSlotStore(item),
	key_index : RowsKeyIndex,
	key_bytes : U64,
	slot_chunks_written : U64,
}

RowsFreshBuild(item) : {
	order_slots : List(U64),
	chunks : RowsSlotDirectory(List(RowsSlotCell(item))),
	current_chunk : List(RowsSlotCell(item)),
	key_index : RowsKeyIndex,
	key_bytes : U64,
	chunk_writes : U64,
}

RowsSlotWrite(item) : { cell : RowsSlotCell(item), offset : U64 }

## Replacement reservations retain prior records while inspecting old slots.
## Both patch lookup and publication order therefore need shared paths rather
## than flat containers that could copy all accumulated work on each write.
RowsSlotPatches(item) : {
	by_chunk : RowsSlotDirectory(List(RowsSlotWrite(item))),
	chunk_ids : RowsIdStack,
}

## Keep reserved order IDs persistent too; materialize the final ordered List
## once after every key and slot reservation has succeeded.
RowsReplacementBuild(item) : {
	order_slots : RowsIdStack,
	key_index : RowsKeyIndex,
	key_bytes : U64,
	patches : RowsSlotPatches(item),
	free_cursor : RowsIdStack,
	next_index : U64,
}

RowsEditState(item) : {
	order : RowsOrder,
	slots : RowsSlotStore(item),
	key_index : RowsKeyIndex,
	key_bytes : U64,
	removed : RowsKeyIndex,
	touched_history : RowsIdStack,
}

rows_generation_callable : () -> RowsGenerationCallable
rows_generation_callable = || {
	marker = Box.box({})
	identity : {} -> Box({})
	identity = |_unit| marker
	Box.box(identity)
}

rows_empty_indexes : () -> { key_index : RowsKeyIndex }
rows_empty_indexes = || {
	key_index : RowsKeyIndex
	key_index = RowsKeyIndex.empty()
	{ key_index }
}

rows_entry_for_slot : RowsSlotStore(item), U64 -> Try(RowsEntry(item), [Missing])
rows_entry_for_slot = |slots, slot| {
	stored = rows_slots_get(slots, slot)?
	Ok({ slot, key: stored.key, item: stored.item })
}

rows_entry_at : RowsOrder, RowsSlotStore(item), U64 -> Try(RowsEntry(item), [Missing])
rows_entry_at = |order, slots, index| {
	slot = rows_order_get(order, index)?
	rows_entry_for_slot(slots, slot)
}

rows_slots_patch : RowsSlotPatches(item), U64, RowsSlotCell(item) -> RowsSlotPatches(item)
rows_slots_patch = |patches, index, cell| {
	if index == 0 {
		crash "Rows slot patch index must be nonzero"
	}
	zero_index = index - 1
	chunk_id = zero_index.div_trunc_by(32)
	offset = zero_index.rem_by(32)
	write = { cell, offset }
	match rows_slot_directory_get(patches.by_chunk, chunk_id) {
		Ok(writes) => {
			duplicate = writes.find_first(|existing| existing.offset == offset)
			match duplicate {
				Ok(_) => crash "Rows slot patch wrote one cell twice"
				Err(_) => { ..patches, by_chunk: rows_slot_directory_insert(patches.by_chunk, chunk_id, writes.prepend(write)) }
			}
		}
		Err(_) => {
			{
				by_chunk: rows_slot_directory_insert(patches.by_chunk, chunk_id, [write]),
				chunk_ids: patches.chunk_ids.prepend(chunk_id),
			}
		}
	}
}

rows_slots_patched_cell : List(RowsSlotWrite(item)), U64 -> Try(RowsSlotCell(item), [Missing])
rows_slots_patched_cell = |writes, offset|
	match writes.find_first(|write| write.offset == offset) {
		Ok(write) => Ok(write.cell)
		Err(_) => Err(Missing)
	}

## Publish each touched slot chunk once. A touched chunk is rebuilt from its
## old immutable cells plus at most 32 replacement cells; untouched chunks stay
## shared with the previous generation.
rows_slots_apply_patches : RowsSlotStore(item), RowsSlotPatches(item), RowsIdStack, U64 -> { slot_chunks_written : U64, slots : RowsSlotStore(item) }
rows_slots_apply_patches = |old, patches, free, next_index| {
	var $chunks = old.chunks
	var $written = 0
	for chunk_id in rows_reverse(patches.chunk_ids.to_list()) {
		writes = rows_slot_directory_get(patches.by_chunk, chunk_id) ?? crash "Rows touched slot chunk had no patches"
		old_chunk = rows_slot_directory_get(old.chunks, chunk_id) ?? []
		first_index = chunk_id * 32 + 1
		available = next_index - first_index
		final_len = if available < 32 {
			available
		} else {
			32
		}
		var $chunk = List.with_capacity(final_len)
		var $offset = 0
		while $offset < final_len {
			cell =
				match rows_slots_patched_cell(writes, $offset) {
					Ok(patched) => patched
					Err(_) => old_chunk.get($offset) ?? crash "Rows slot patch omitted an existing cell"
				}
			$chunk = $chunk.append(cell)
			$offset = $offset + 1
		}
		$chunks = rows_slot_directory_insert($chunks, chunk_id, $chunk)
		$written = $written + 1
	}
	{ slot_chunks_written: $written, slots: { chunks: $chunks, free, next_index } }
}

rows_build_fresh_loop : List(item), Box((item -> Str)), U64, U64, RowsFreshBuild(item) -> Try(RowsFreshBuild(item), Rows.Error)
rows_build_fresh_loop = |items, key_of, index, len, build|
	if index == len {
		Ok(build)
	} else {
		item = items.get(index) ?? crash "Rows input length changed during construction"
		key = Box.unbox(key_of)(item)
		match build.key_index.get(key) {
			Ok(_) => Err(DuplicateKey(key))
			Err(_) => {
				slot_index = index + 1
				slot = rows_slot_pack(slot_index, 1)
				chunk = build.current_chunk.append(RowsSlotLive({ generation: 1, key, item }))
				chunk_complete = chunk.len() == 32
				chunk_id = index.div_trunc_by(32)
				rows_build_fresh_loop(
					items,
					key_of,
					index + 1,
					len,
					{
						order_slots: build.order_slots.append(slot),
						chunks: if chunk_complete {
							rows_slot_directory_insert(build.chunks, chunk_id, chunk)
						} else {
							build.chunks
						},
						current_chunk: if chunk_complete {
							List.with_capacity(32)
						} else {
							chunk
						},
						key_index: build.key_index.insert(key, slot),
						key_bytes: build.key_bytes + key.count_utf8_bytes(),
						chunk_writes: build.chunk_writes + if chunk_complete {
							1
						} else {
							0
						},
					},
				)
			}
		}
	}

## Build slot chunks directly and publish each once into the bounded directory.
## Ordered slots append into their final preallocated sequence. The exact-key
## index rejects each duplicate before later input items are examined.
rows_build_fresh : List(item), Box((item -> Str)) -> Try(RowsBuild(item), Rows.Error)
rows_build_fresh = |items, key_of| {
	len = items.len()
	if len >= rows_slot_base {
		Err(Rows.Error.SlotExhausted)
	} else {
		built = rows_build_fresh_loop(
			items,
			key_of,
			0,
			len,
			{
				order_slots: List.with_capacity(len),
				chunks: rows_slot_directory_empty(),
				current_chunk: List.with_capacity(32),
				key_index: RowsKeyIndex.empty(),
				key_bytes: 0,
				chunk_writes: 0,
			},
		)?
		if built.current_chunk.is_empty() {
			Ok({
				order_slots: built.order_slots,
				slots: { chunks: built.chunks, free: RowsIdStack.empty(), next_index: len + 1 },
				key_index: built.key_index,
				key_bytes: built.key_bytes,
				slot_chunks_written: built.chunk_writes,
			})
		} else {
			last_chunk_id = len.div_trunc_by(32)
			Ok({
				order_slots: built.order_slots,
				slots: { chunks: rows_slot_directory_insert(built.chunks, last_chunk_id, built.current_chunk), free: RowsIdStack.empty(), next_index: len + 1 },
				key_index: built.key_index,
				key_bytes: built.key_bytes,
				slot_chunks_written: built.chunk_writes + 1,
			})
		}
	}
}

rows_build_replacement_loop : List(item), Box((item -> Str)), RowsStorage(item), U64, U64, RowsReplacementBuild(item) -> Try(RowsReplacementBuild(item), Rows.Error)
rows_build_replacement_loop = |items, key_of, old, index, len, build|
	if index == len {
		Ok(build)
	} else {
		item = items.get(index) ?? crash "Rows replacement length changed during construction"
		key = Box.unbox(key_of)(item)
		match build.key_index.get(key) {
			Ok(_) => Err(DuplicateKey(key))
			Err(_) => {
				reserved_result =
					match old.key_index.get(key) {
						Ok(old_slot) => {
							old_cell = rows_slots_cell(old.slots, rows_slot_index(old_slot)) ?? crash "Rows key index named a missing slot"
							generation =
								match old_cell {
									RowsSlotLive(live) =>
										if live.generation == rows_slot_generation(old_slot) {
											live.generation
										} else {
											crash "Rows key index named a stale generation"
										}
									_ => crash "Rows key index named a non-live slot"
								}
							Ok({
								free_cursor: build.free_cursor,
								next_index: build.next_index,
								slot: old_slot,
								cell: RowsSlotLive({ generation, key, item }),
							})
						}
						Err(_) => {
							match build.free_cursor.first() {
								Ok(slot_index) => {
									free_cell = rows_slots_cell(old.slots, slot_index) ?? crash "Rows free slot was missing"
									generation =
										match free_cell {
											RowsSlotVacant({ generation: stored_generation }) => stored_generation
											_ => crash "Rows free slot was not vacant"
										}
									Ok({
										free_cursor: build.free_cursor.drop_first(1),
										next_index: build.next_index,
										slot: rows_slot_pack(slot_index, generation),
										cell: RowsSlotLive({ generation, key, item }),
									})
								}
								Err(_) => {
									if build.next_index >= rows_slot_base {
										Err(Rows.Error.SlotExhausted)
									} else {
										Ok({
											free_cursor: build.free_cursor,
											next_index: build.next_index + 1,
											slot: rows_slot_pack(build.next_index, 1),
											cell: RowsSlotLive({ generation: 1, key, item }),
										})
									}
								}
							}
						}
					}
				reserved = reserved_result?
				rows_build_replacement_loop(
					items,
					key_of,
					old,
					index + 1,
					len,
					{
						order_slots: build.order_slots.prepend(reserved.slot),
						key_index: build.key_index.insert(key, reserved.slot),
						key_bytes: build.key_bytes + key.count_utf8_bytes(),
						patches: rows_slots_patch(build.patches, rows_slot_index(reserved.slot), reserved.cell),
						free_cursor: reserved.free_cursor,
						next_index: reserved.next_index,
					},
				)
			}
		}
	}

rows_build_replacement : List(item), Box((item -> Str)), RowsStorage(item) -> Try(RowsBuild(item), Rows.Error)
rows_build_replacement = |items, key_of, old| {
	len = items.len()
	partial = rows_build_replacement_loop(
		items,
		key_of,
		old,
		0,
		len,
		{
			order_slots: RowsIdStack.empty(),
			key_index: RowsKeyIndex.empty(),
			key_bytes: 0,
			patches: { by_chunk: rows_slot_directory_empty(), chunk_ids: RowsIdStack.empty() },
			free_cursor: old.slots.free,
			next_index: old.slots.next_index,
		},
	)?
	var $patches = partial.patches
	var $released = List.with_capacity(rows_order_len(old.order))
	var $index = 0
	while $index < rows_order_len(old.order) {
		entry = rows_entry_at(old.order, old.slots, $index) ?? crash "Rows replacement old index was invalid"
		match partial.key_index.get(entry.key) {
			Ok(_) => {}
			Err(_) => {
				generation = rows_slot_generation(entry.slot)
				slot_index = rows_slot_index(entry.slot)
				if generation == 4294967295 {
					$patches = rows_slots_patch($patches, slot_index, RowsSlotRetired)
				} else {
					$patches = rows_slots_patch($patches, slot_index, RowsSlotVacant({ generation: generation + 1 }))
					$released = $released.append(slot_index)
				}
			}
		}
		$index = $index + 1
	}
	final_free = $released.fold(partial.free_cursor, |free, index| free.prepend(index))
	patched = rows_slots_apply_patches(old.slots, $patches, final_free, partial.next_index)
	Ok({
		order_slots: rows_reverse(partial.order_slots.to_list()),
		slots: patched.slots,
		key_index: partial.key_index,
		key_bytes: partial.key_bytes,
		slot_chunks_written: patched.slot_chunks_written,
	})
}

## Retire every live slot one chunk at a time. Rebuilding complete chunks avoids
## copying one 32-cell chunk for every row. The old generation retains its immutable storage; this
## produces the independently owned slot generation used by the new empty
## collection. Vacant generations remain unchanged, saturated live slots retire
## permanently, and the free list is rebuilt without duplicates from the cells
## that the new generation actually owns.
rows_release_all_slots : RowsStorage(item) -> RowsSlotStore(item)
rows_release_all_slots = |old| {
	chunk_count = rows_slot_directory_len(old.slots.chunks)
	free_capacity = old.slots.free.len() + rows_order_len(old.order)
	empty_chunks : RowsSlotDirectory(List(RowsSlotCell(item)))
	empty_chunks = rows_slot_directory_empty()
	var $chunks = empty_chunks
	var $free = List.with_capacity(free_capacity)
	var $chunk_id = 0
	while $chunk_id < chunk_count {
		old_chunk = rows_slot_directory_get(old.slots.chunks, $chunk_id) ?? crash "Rows clear slot chunk was missing"
		var $new_chunk = List.with_capacity(old_chunk.len())
		var $offset = 0
		for cell in old_chunk {
			index = $chunk_id * 32 + $offset + 1
			match cell {
				RowsSlotLive({ generation, .. }) =>
					if generation == 4294967295 {
						$new_chunk = $new_chunk.append(RowsSlotRetired)
					} else {
						$new_chunk = $new_chunk.append(RowsSlotVacant({ generation: generation + 1 }))
						$free = $free.append(index)
					}
				RowsSlotVacant(vacant) => {
					$new_chunk = $new_chunk.append(RowsSlotVacant(vacant))
					$free = $free.append(index)
				}
				RowsSlotRetired => {
					$new_chunk = $new_chunk.append(RowsSlotRetired)
				}
			}
			$offset = $offset + 1
		}
		$chunks = rows_slot_directory_insert($chunks, $chunk_id, $new_chunk)
		$chunk_id = $chunk_id + 1
	}
	{ chunks: $chunks, free: RowsIdStack.from_list($free), next_index: old.slots.next_index }
}

rows_reverse : List(a) -> List(a)
rows_reverse = |items| {
	var $reversed = List.with_capacity(items.len())
	var $remaining = items.len()
	while $remaining > 0 {
		$remaining = $remaining - 1
		$reversed = $reversed.append(items.get($remaining) ?? crash "Rows reversal index was invalid")
	}
	$reversed
}

rows_remove_at_loop : RowsEditState(item), U64, U64 -> RowsEditState(item)
rows_remove_at_loop = |state, at, remaining|
	if remaining == 0 {
		state
	} else {
		entry = rows_entry_at(state.order, state.slots, at) ?? crash "Rows removal index exceeded its order"
		order_removal = rows_order_remove(state.order, at)
		next = {
			..state,
			order: order_removal.order,
			key_index: state.key_index.remove(entry.key),
			key_bytes: state.key_bytes - entry.key.count_utf8_bytes(),
			removed: state.removed.insert(entry.key, entry.slot),

			touched_history: state.touched_history.prepend(entry.slot),
		}
		rows_remove_at_loop(next, at, remaining - 1)
	}

rows_remove_at : RowsEditState(item), U64, U64 -> RowsEditState(item)
rows_remove_at = |state, at, count| rows_remove_at_loop(state, at, count)

rows_insert_items : RowsEditState(item), Box((item -> Str)), U64, List(item), U64, U64 -> Try(RowsEditState(item), Rows.Error)
rows_insert_items = |state, key_of, at, items, item_index, item_len|
	if item_index == item_len {
		Ok(state)
	} else {
		item = items.get(item_index) ?? crash "Rows inserted item length changed during construction"
		key = Box.unbox(key_of)(item)
		match state.key_index.get(key) {
			Ok(_) => Err(DuplicateKey(key))
			Err(_) => {
				entry_and_state =
					match state.removed.get(key) {
						Ok(removed_slot) => {
							replaced_slots = rows_slots_replace(state.slots, removed_slot, key, item) ?? crash "Rows removed entry slot became stale"
							{
								entry: { slot: removed_slot, key, item },
								state: { ..state, slots: replaced_slots, removed: state.removed.remove(key) },
							}
						}
						Err(_) => {
							allocated = rows_slots_allocate(state.slots, key, item)?
							{
								entry: { slot: allocated.slot, key, item },
								state: { ..state, slots: allocated.slots },
							}
						}
					}
				reserved_index = at + item_index
				next_state = {
					..entry_and_state.state,
					order: rows_order_insert(entry_and_state.state.order, reserved_index, entry_and_state.entry.slot),
					key_index: entry_and_state.state.key_index.insert(key, entry_and_state.entry.slot),
					key_bytes: entry_and_state.state.key_bytes + key.count_utf8_bytes(),

					touched_history: entry_and_state.state.touched_history.prepend(entry_and_state.entry.slot),
				}
				rows_insert_items(next_state, key_of, at, items, item_index + 1, item_len)
			}
		}
	}

rows_order_take_range : RowsOrder, U64, U64 -> { order : RowsOrder, slots : List(U64) }
rows_order_take_range = |order, from, count| {
	var $order = order
	var $slots = List.with_capacity(count)
	var $remaining = count
	while $remaining > 0 {
		removal = rows_order_remove($order, from)
		$order = removal.order
		$slots = $slots.append(removal.removed)
		$remaining = $remaining - 1
	}
	{ order: $order, slots: $slots }
}

rows_order_insert_range : RowsOrder, U64, List(U64) -> RowsOrder
rows_order_insert_range = |order, at, slots| {
	var $order = order
	var $offset = 0
	for slot in slots {
		$order = rows_order_insert($order, at + $offset, slot)
		$offset = $offset + 1
	}
	$order
}

rows_apply_one : RowsEditState(item), Box((item -> Str)), Rows.Edit(item) -> Try(RowsEditState(item), Rows.Error)
	where [item.is_eq : item, item -> Bool]
rows_apply_one = |state, key_of, edit|
	match edit {
		Append(items) =>
			if items.is_empty() {
				Ok(state)
			} else {
				rows_insert_items(state, key_of, rows_order_len(state.order), items, 0, items.len())
			}
		Clear =>
			if rows_order_len(state.order) == 0 {
				Ok(state)
			} else {
				Ok(rows_remove_at(state, 0, rows_order_len(state.order)))
			}
		InsertAt({ at, items }) =>
			if at > rows_order_len(state.order) {
				Err(IndexOutOfBounds({ index: at, len: rows_order_len(state.order) }))
			} else if items.is_empty() {
				Ok(state)
			} else {
				rows_insert_items(state, key_of, at, items, 0, items.len())
			}
		InsertBefore({ before, items }) =>
			match state.key_index.get(before) {
				Err(_) => Err(KeyNotFound(before))
				Ok(before_slot) =>
					if items.is_empty() {
						Ok(state)
					} else {
						at = rows_order_rank(state.order, before_slot) ?? crash "Rows key slot was absent from order"
						rows_insert_items(state, key_of, at, items, 0, items.len())
					}
				}
		MoveKeyBefore({ key, before }) =>
			match state.key_index.get(key) {
				Err(_) => Err(KeyNotFound(key))
				Ok(moving_slot) => {
					from = rows_order_rank(state.order, moving_slot) ?? crash "Rows moving key slot was absent from order"
					to_result : Try(U64, Rows.Error)
					to_result =
						match before {
							End => Ok(rows_order_len(state.order) - 1)
							Key(before_key) =>
								if before_key == key {
									Ok(from)
								} else {
									match state.key_index.get(before_key) {
										Err(_) => Err(KeyNotFound(before_key))
										Ok(before_slot) => {
											before_index = rows_order_rank(state.order, before_slot) ?? crash "Rows before key slot was absent from order"
											Ok(
												if before_index > from {
													before_index - 1
												} else {
													before_index
												},
											)
										}
									}
								}
							}
					to = to_result?
					if from == to {
						Ok(state)
					} else {
						taken = rows_order_take_range(state.order, from, 1)
						moved_order = rows_order_insert_range(taken.order, to, taken.slots)
						next = { ..state, order: moved_order, touched_history: state.touched_history.prepend(moving_slot) }
						Ok(next)
					}
				}
			}
		MoveRange({ from, count, to }) => {
			len = rows_order_len(state.order)
			if from > len or count > len - from {
				Err(RangeOutOfBounds({ at: from, count, len }))
			} else if to > len - count {
				Err(IndexOutOfBounds({ index: to, len: len - count }))
			} else if count == 0 or from == to {
				Ok(state)
			} else {
				taken = rows_order_take_range(state.order, from, count)
				moved_order = rows_order_insert_range(taken.order, to, taken.slots)
				var $touched_history = state.touched_history
				for moved_slot in taken.slots {
					$touched_history = $touched_history.prepend(moved_slot)
				}
				next = { ..state, order: moved_order, touched_history: $touched_history }
				Ok(next)
			}
		}
		RemoveKey(key) =>
			match state.key_index.get(key) {
				Err(_) => Err(KeyNotFound(key))
				Ok(slot) => {
					at = rows_order_rank(state.order, slot) ?? crash "Rows removed key slot was absent from order"
					Ok(rows_remove_at(state, at, 1))
				}
			}
		RemoveRange({ at, count }) => {
			len = rows_order_len(state.order)
			if at > len or count > len - at {
				Err(RangeOutOfBounds({ at, count, len }))
			} else if count == 0 {
				Ok(state)
			} else {
				Ok(rows_remove_at(state, at, count))
			}
		}
		SetAt({ at, item }) => {
			len = rows_order_len(state.order)
			if at >= len {
				Err(IndexOutOfBounds({ index: at, len }))
			} else {
				before_entry = rows_entry_at(state.order, state.slots, at) ?? crash "Rows set index did not name an entry"
				new_key = Box.unbox(key_of)(item)
				if new_key == before_entry.key {
					if before_entry.item.is_eq(item) {
						Ok(state)
					} else {
						updated_slots = rows_slots_replace(state.slots, before_entry.slot, new_key, item) ?? crash "Rows set slot became stale"
						next = { ..state, slots: updated_slots, touched_history: state.touched_history.prepend(before_entry.slot) }
						Ok(next)
					}
				} else {
					match state.key_index.get(new_key) {
						Ok(_) => Err(DuplicateKey(new_key))
						Err(_) => {
							removed = rows_remove_at(state, at, 1)
							rows_insert_items(removed, key_of, at, [item], 0, 1)
						}
					}
				}
			}
		}
		SetKey({ key, item }) =>
			match state.key_index.get(key) {
				Err(_) => Err(KeyNotFound(key))
				Ok(slot) => {
					at = rows_order_rank(state.order, slot) ?? crash "Rows set key slot was absent from order"
					rows_apply_one(state, key_of, SetAt({ at, item }))
				}
			}
		}

rows_apply_many : RowsEditState(item), Box((item -> Str)), List(Rows.Edit(item)), U64, U64 -> Try(RowsEditState(item), Rows.Error)
	where [item.is_eq : item, item -> Bool]
rows_apply_many = |state, key_of, edits, index, len|
	if index == len {
		Ok(state)
	} else {
		edit = edits.get(index) ?? crash "Rows edit length changed during application"
		next = rows_apply_one(state, key_of, edit)?
		rows_apply_many(next, key_of, edits, index + 1, len)
	}

rows_touched_equal : RowsStorage(item), RowsEditState(item) -> Bool
	where [item.is_eq : item, item -> Bool]
rows_touched_equal = |old, final| {
	if rows_order_len(old.order) != rows_order_len(final.order) {
		False
	} else {
		var $equal = True
		for slot in final.touched_history.to_list() {
			if $equal {
				old_rank = rows_order_rank(old.order, slot)
				final_rank = rows_order_rank(final.order, slot)
				match old_rank {
					Err(_) =>
						match final_rank {
							Err(_) => {}
							Ok(_) => {
								$equal = False
							}
						}
					Ok(old_at) =>
						match final_rank {
							Err(_) => {
								$equal = False
							}
							Ok(final_at) => {
								old_entry = rows_entry_for_slot(old.slots, slot) ?? crash "Rows original touched slot was stale"
								final_entry = rows_entry_for_slot(final.slots, slot) ?? crash "Rows final touched slot was stale"
								if old_at != final_at or old_entry.key != final_entry.key or !old_entry.item.is_eq(final_entry.item) {
									$equal = False
								}
							}
						}
					}
			}
		}
		$equal
	}
}

rows_number_transitions : List(RowsTransition) -> List(RowsTransition)
rows_number_transitions = |transitions| {
	var $numbered = List.with_capacity(transitions.len())
	var $op_index = 0
	for transition in transitions {
		numbered_transition =
			match transition {
				ClearRows => ClearRows
				InsertRow(payload) => InsertRow({ ..payload, op_index: $op_index })
				MoveRows(payload) => MoveRows({ ..payload, op_index: $op_index })
				RemoveRows(payload) => RemoveRows({ ..payload, op_index: $op_index })
				UpdateRow(payload) => UpdateRow({ ..payload, op_index: $op_index })
			}
		$numbered = $numbered.append(numbered_transition)
		$op_index = $op_index + 1
	}
	$numbered
}

rows_canonical_transitions : RowsStorage(item), RowsEditState(item) -> List(RowsTransition)
	where [item.is_eq : item, item -> Bool]
rows_canonical_transitions = |old, final| {
	if rows_order_len(final.order) == 0 {
		rows_number_transitions([ClearRows])
	} else {
		seen : Dict(U64, Bool)
		seen = Dict.empty()
		var $seen = seen
		var $touched = List.with_capacity(final.touched_history.len())
		for slot in final.touched_history.to_list() {
			match $seen.get(slot) {
				Ok(_) => {}
				Err(_) => {
					$seen = $seen.insert(slot, True)
					$touched = $touched.append(slot)
				}
			}
		}

		$touched = rows_reverse($touched)
		var $working = old.order
		var $canonical = List.with_capacity($touched.len())
		for slot in $touched {
			match rows_order_rank($working, slot) {
				Err(_) => {}
				Ok(at) =>
					match rows_order_rank(final.order, slot) {
						Ok(_) => {}
						Err(_) => {
							removal = rows_order_remove($working, at)
							$working = removal.order
							$canonical = $canonical.append(RemoveRows({ op_index: 0, first_slot: slot, count: 1 }))
						}
					}
				}
		}

		target_rows =
			$touched
				.keep_if(
					|slot|
						match rows_order_rank(final.order, slot) {
							Ok(_) => True
							Err(_) => False
						},
				)
				.map(|slot| { slot, rank: rows_order_rank(final.order, slot) ?? crash "Rows canonical target slot was absent" })
				.sort_with(
					|left, right|
						if left.rank < right.rank {
							Before
						} else if left.rank > right.rank {
							After
						} else {
							Same
						},
				)

		# Appended slots already have authenticated final ranks. If every old
		# touched slot stayed at its old rank and new slots form the exact tail,
		# emit their before-slot-zero transitions without rebuilding that tail
		# in a second persistent order tree just for normalization.
		old_len = rows_order_len(old.order)
		var $append_only = rows_order_len(final.order) > old_len and rows_order_len($working) == old_len
		var $appended = 0
		if $append_only {
			for target in target_rows {
				match rows_order_rank(old.order, target.slot) {
					Ok(rank) => {
						$append_only = $append_only and rank == target.rank
					}
					Err(_) => {
						$append_only = $append_only and target.rank == old_len + $appended
						$appended = $appended + 1
					}
				}
			}
		}
		$append_only = $append_only and rows_order_len(final.order) == old_len + $appended

		for target in target_rows {
			match rows_order_rank($working, target.slot) {
				Err(_) => {
					before_slot = if $append_only {
						0
					} else {
						rows_order_get($working, target.rank) ?? 0
					}
					if !$append_only {
						$working = rows_order_insert($working, target.rank, target.slot)
					}
					entry = rows_entry_for_slot(final.slots, target.slot) ?? crash "Rows canonical inserted slot was stale"
					$canonical = $canonical.append(InsertRow({ op_index: 0, before_slot, slot: target.slot, key: entry.key }))
				}
				Ok(current_rank) =>
					if current_rank != target.rank {
						removal = rows_order_remove($working, current_rank)
						before_slot = rows_order_get(removal.order, target.rank) ?? 0
						$working = rows_order_insert(removal.order, target.rank, target.slot)
						$canonical = $canonical.append(MoveRows({ op_index: 0, first_slot: target.slot, count: 1, before_slot }))
					}
				}
		}

		for target in target_rows {
			match rows_order_rank(old.order, target.slot) {
				Err(_) => {}
				Ok(_) => {
					old_entry = rows_entry_for_slot(old.slots, target.slot) ?? crash "Rows canonical old slot was stale"
					final_entry = rows_entry_for_slot(final.slots, target.slot) ?? crash "Rows canonical final slot was stale"
					if old_entry.key != final_entry.key or !old_entry.item.is_eq(final_entry.item) {
						$canonical = $canonical.append(UpdateRow({ op_index: 0, slot: target.slot, key: final_entry.key }))
					}
				}
			}
		}
		rows_number_transitions($canonical)
	}
}

rows_release_absent_touched : RowsEditState(item) -> RowsSlotStore(item)
rows_release_absent_touched = |state| {
	seen : Dict(U64, Bool)
	seen = Dict.empty()
	var $seen = seen
	var $slots = state.slots
	for slot in state.touched_history.to_list() {
		match $seen.get(slot) {
			Ok(_) => {}
			Err(_) => {
				$seen = $seen.insert(slot, True)
				match rows_order_rank(state.order, slot) {
					Ok(_) => {}
					Err(_) => {
						$slots = rows_slots_release($slots, slot) ?? $slots
					}
				}
			}
		}
	}
	$slots
}

rows_delta_metadata : List(RowsTransition) -> { delta_key_bytes : U64, delta_key_count : U64, op_count : U64 }
rows_delta_metadata = |transitions| {
	var $key_bytes = 0
	var $key_count = 0
	for transition in transitions {
		match transition {
			InsertRow({ key, .. }) => {
				$key_bytes = $key_bytes + key.count_utf8_bytes()
				$key_count = $key_count + 1
			}
			UpdateRow({ key, .. }) => {
				$key_bytes = $key_bytes + key.count_utf8_bytes()
				$key_count = $key_count + 1
			}
			_ => {}
		}
	}
	{ delta_key_bytes: $key_bytes, delta_key_count: $key_count, op_count: transitions.len() }
}

Rows(item) :: [Rows(RowsStorage(item))].{

	## Opaque callable identity carried by one immutable Rows generation.
	RowsGenerationCallable : Box(({} -> Box({})))

	## O(1) metadata used to reserve exact snapshot or delta sinks before copying.
	Description : {
		generation : RowsGenerationCallable,
		parent : [NoParent, Parent(RowsGenerationCallable)],
		kind : [Delta, Snapshot],
		item_count : U64,
		snapshot_key_bytes : U64,
		op_count : U64,
		delta_key_count : U64,
		delta_key_bytes : U64,
	}

	## Errors are stable application values. Duplicate and missing-key errors carry
	## the exact UTF-8 key bytes supplied by the collection's key function.
	Error := [
		DuplicateKey(Str),
		IndexOutOfBounds({ index : U64, len : U64 }),
		KeyNotFound(Str),
		RangeOutOfBounds({ at : U64, count : U64, len : U64 }),
		SlotExhausted,
	]

	## Destination for a key-addressed move.
	Before := [End, Key(Str)]

	## A sequential collection edit. `MoveRange.to` is interpreted after the
	## source range has been removed.
	Edit(item) := [
		Append(List(item)),
		Clear,
		InsertAt({ at : U64, items : List(item) }),
		InsertBefore({ before : Str, items : List(item) }),
		MoveKeyBefore({ key : Str, before : Before }),
		MoveRange({ from : U64, count : U64, to : U64 }),
		RemoveKey(Str),
		RemoveRange({ at : U64, count : U64 }),
		SetAt({ at : U64, item : item }),
		SetKey({ key : Str, item : item }),
	]

	## Platform-private transition description. Applications should use `Edit`;
	## this form carries authenticated stable slots and cached keys to the engine.
	Delta(item) : RowsTransition

	## Platform-private snapshot entry passed to adapter callbacks.
	SnapshotEntry(item) : RowsEntry(item)

	## Hosted O(1) raw callable-identity comparison. `platform-web/main.roc` binds
	## this declaration to `roc_rows_same_generation_callable` in both hosts.
	same_generation_callable! : RowsGenerationCallable, RowsGenerationCallable -> Bool

	## Construct an empty collection that owns `key_of`.
	empty : (item -> Str) -> Rows(item)
	empty = |key_of| {
		indexes = rows_empty_indexes()
		Rows({
			token: rows_generation_callable(),
			parent: NoParent,
			transition: Snapshot,
			key_of: Box.box(key_of),
			order: rows_order_empty(),
			slots: rows_slots_empty(),
			key_index: indexes.key_index,
			snapshot_key_bytes: 0,
			op_count: 0,
			delta_key_count: 0,
			delta_key_bytes: 0,
		})
	}

	## Construct a snapshot collection, rejecting duplicate exact keys.
	from_list : List(item), (item -> Str) -> Try(Rows(item), Error)
	from_list = |items, key_of| {
		key_of_box = Box.box(key_of)
		built = rows_build_fresh(items, key_of_box)?
		Ok(
			Rows({
				token: rows_generation_callable(),
				parent: NoParent,
				transition: Snapshot,
				key_of: key_of_box,
				order: rows_order_from_slots(built.order_slots),
				slots: built.slots,
				key_index: built.key_index,
				snapshot_key_bytes: built.key_bytes,
				op_count: 0,
				delta_key_count: 0,
				delta_key_bytes: 0,
			}),
		)
	}

	## Replace all content as an explicit snapshot. Keys surviving from the old
	## collection retain their stable slots; newly appearing keys receive new ones.
	replace_all : Rows(item), List(item) -> Try(Rows(item), Error)
	replace_all = |Rows(old), items| {
		built =
			if old.slots.next_index == 1 and rows_slot_directory_len(old.slots.chunks) == 0 {
				rows_build_fresh(items, old.key_of)?
			} else {
				rows_build_replacement(items, old.key_of, old)?
			}
		Ok(
			Rows({
				token: rows_generation_callable(),
				parent: Parent(old.token),
				transition: Snapshot,
				key_of: old.key_of,
				order: rows_order_from_slots(built.order_slots),
				slots: built.slots,
				key_index: built.key_index,
				snapshot_key_bytes: built.key_bytes,
				op_count: 0,
				delta_key_count: 0,
				delta_key_bytes: 0,
			}),
		)
	}

	## Apply edits sequentially and publish one delta generation. A batch whose
	## edits normalize entirely away returns the original generation. Removing and
	## reinserting one key in the same unpublished batch preserves its stable slot.
	apply : Rows(item), List(Edit(item)) -> Try(Rows(item), Error)
		where [item.is_eq : item, item -> Bool]
	apply = |rows, edits| {
		Rows(old) = rows
		direct_clear =
			if edits.len() == 1 {
				match edits.get(0) {
					Ok(Clear) => True
					_ => False
				}
			} else {
				False
			}
		if direct_clear and rows_order_len(old.order) > 0 {
			empty_indexes = rows_empty_indexes()
			Ok(
				Rows({
					token: rows_generation_callable(),
					parent: Parent(old.token),
					transition: Delta([ClearRows]),
					key_of: old.key_of,
					order: rows_order_empty(),
					slots: rows_release_all_slots(old),
					key_index: empty_indexes.key_index,
					snapshot_key_bytes: 0,
					op_count: 1,
					delta_key_count: 0,
					delta_key_bytes: 0,
				}),
			)
		} else {
			removed : RowsKeyIndex
			removed = RowsKeyIndex.empty()
			state = {
				order: old.order,
				slots: old.slots,
				key_index: old.key_index,
				key_bytes: old.snapshot_key_bytes,
				removed,

				touched_history: RowsIdStack.empty(),
			}
			applied = rows_apply_many(state, old.key_of, edits, 0, edits.len())?
			if rows_touched_equal(old, applied) {
				Ok(rows)
			} else {
				normalized = rows_canonical_transitions(old, applied)
				metadata = rows_delta_metadata(normalized)
				final_slots = rows_release_absent_touched(applied)
				Ok(
					Rows({
						token: rows_generation_callable(),
						parent: Parent(old.token),
						transition: Delta(normalized),
						key_of: old.key_of,
						order: applied.order,
						slots: final_slots,
						key_index: applied.key_index,
						snapshot_key_bytes: applied.key_bytes,
						op_count: metadata.op_count,
						delta_key_count: metadata.delta_key_count,
						delta_key_bytes: metadata.delta_key_bytes,
					}),
				)
			}
		}
	}

	## Number of live rows.
	len : Rows(item) -> U64
	len = |Rows(storage)| rows_order_len(storage.order)

	## Read by order index.
	get : Rows(item), U64 -> Try(item, Error)
	get = |Rows(storage), index|
		match rows_entry_at(storage.order, storage.slots, index) {
			Ok(entry) => Ok(entry.item)
			Err(_) => Err(IndexOutOfBounds({ index, len: rows_order_len(storage.order) }))
		}

	## Read by exact UTF-8 key.
	get_key : Rows(item), Str -> Try(item, Error)
	get_key = |Rows(storage), key|
		match storage.key_index.get(key) {
			Err(_) => Err(KeyNotFound(key))
			Ok(slot) =>
				match rows_slots_get(storage.slots, slot) {
					Ok(stored) => Ok(stored.item)
					Err(_) => crash "Rows key index named a stale slot"
				}
			}

	## Iterate items in row order.
	iter : Rows(item) -> Iter(item)
	iter = |rows| Rows.to_list(rows).iter()

	## Materialize items in row order.
	to_list : Rows(item) -> List(item)
	to_list = |Rows(storage)| {
		rows_order_fold(
			storage.order,
			List.with_capacity(rows_order_len(storage.order)),
			|items, slot| {
				entry = rows_entry_for_slot(storage.slots, slot) ?? crash "Rows materialization slot was stale"
				items.append(entry.item)
			},
		)
	}

	## O(1) generation equality used by ordinary signal pruning. The hosted hook
	## compares raw boxed callable identity and never invokes the callable.
	is_eq : Rows(item), Rows(item) -> Bool
	is_eq = |Rows(left), Rows(right)| Rows.same_generation_callable!(left.token, right.token)

	## Explicit structural equality for callers that genuinely need it.
	content_is_eq : Rows(item), Rows(item) -> Bool
		where [item.is_eq : item, item -> Bool]
	content_is_eq = |Rows(left), Rows(right)| {
		if rows_order_len(left.order) != rows_order_len(right.order) {
			False
		} else {
			var $equal = True
			var $index = 0
			while $equal and $index < rows_order_len(left.order) {
				left_entry = rows_entry_at(left.order, left.slots, $index) ?? crash "Rows left content index was invalid"
				right_entry = rows_entry_at(right.order, right.slots, $index) ?? crash "Rows right content index was invalid"
				$equal = left_entry.key == right_entry.key and left_entry.item.is_eq(right_entry.item)
				$index = $index + 1
			}
			$equal
		}
	}

	## Platform-private generation token accessor. Engine adapters forward this
	## callable as opaque identity; applications must not invoke it.
	platform_generation_callable : Rows(item) -> RowsGenerationCallable
	platform_generation_callable = |Rows(storage)| storage.token

	## Platform-private immediate lineage accessor.
	platform_parent_generation_callable : Rows(item) -> [NoParent, Parent(RowsGenerationCallable)]
	platform_parent_generation_callable = |Rows(storage)| storage.parent

	## Platform-private transition discriminator.
	platform_transition_kind : Rows(item) -> [Delta, Snapshot]
	platform_transition_kind = |Rows(storage)|
		match storage.transition {
			Delta(_) => Delta
			Snapshot => Snapshot
		}

	## Return cached reservation metadata without walking the generation.
	platform_description : Rows(item) -> Description
	platform_description = |Rows(storage)| {
		kind =
			match storage.transition {
				Delta(_) => Delta
				Snapshot => Snapshot
			}
		{
			generation: storage.token,
			parent: storage.parent,
			kind,
			item_count: rows_order_len(storage.order),
			snapshot_key_bytes: storage.snapshot_key_bytes,
			op_count: storage.op_count,
			delta_key_count: storage.delta_key_count,
			delta_key_bytes: storage.delta_key_bytes,
		}
	}

	## Platform-private stable slot lookup by order index.
	platform_slot_at : Rows(item), U64 -> Try(U64, Error)
	platform_slot_at = |Rows(storage), index|
		match rows_order_get(storage.order, index) {
			Ok(slot) => Ok(slot)
			Err(_) => Err(IndexOutOfBounds({ index, len: rows_order_len(storage.order) }))
		}

	## Platform-private cached-key lookup by order index.
	platform_key_at : Rows(item), U64 -> Try(Str, Error)
	platform_key_at = |Rows(storage), index|
		match rows_entry_at(storage.order, storage.slots, index) {
			Ok(entry) => Ok(entry.key)
			Err(_) => Err(IndexOutOfBounds({ index, len: rows_order_len(storage.order) }))
		}

	## Platform-private typed item lookup by order index.
	platform_item_at : Rows(item), U64 -> Try(item, Error)
	platform_item_at = |rows, index| Rows.get(rows, index)

	## Platform-private typed item lookup by stable slot.
	platform_item_for_slot : Rows(item), U64 -> Try(item, [SlotNotFound(U64)])
	platform_item_for_slot = |Rows(storage), slot|
		match rows_slots_get(storage.slots, slot) {
			Err(_) => Err(SlotNotFound(slot))
			Ok(stored) => Ok(stored.item)
		}

	## Platform-private allocation-free snapshot fold. The callback receives the
	## order index plus stable slot, cached key, and typed item.
	platform_copy_snapshot : Rows(item), state, (state, U64, U64, Str -> state) -> state
	platform_copy_snapshot = |Rows(storage), initial, push| {
		folded =
			rows_order_fold(
				storage.order,
				{ index: 0, state: initial },
				|next, slot| {
					entry = rows_entry_for_slot(storage.slots, slot) ?? crash "Rows snapshot slot was stale"
					{ index: next.index + 1, state: push(next.state, next.index, entry.slot, entry.key) }
				},
			)
		folded.state
	}

	## Platform-private delta fold. Snapshot generations yield the initial state;
	## adapters must inspect `platform_transition_kind` before selecting a path.
	platform_copy_delta : Rows(item), state, (state, Delta(item) -> state) -> state
	platform_copy_delta = |Rows(storage), initial, push|
		match storage.transition {
			Snapshot => initial
			Delta(transitions) => transitions.fold(initial, push)
		}

}

RowsTestItem := [RowsTestItem({ key : Str, value : U64 })].{
	key : RowsTestItem -> Str
	key = |RowsTestItem(item)| item.key

	value : RowsTestItem -> U64
	value = |RowsTestItem(item)| item.value

	is_eq : RowsTestItem, RowsTestItem -> Bool
	is_eq = |RowsTestItem(left), RowsTestItem(right)| left.key == right.key and left.value == right.value
}

rows_test_item : Str, U64 -> RowsTestItem
rows_test_item = |key, value| RowsTestItem({ key, value })

rows_test_key : RowsTestItem -> Str
rows_test_key = |item| item.key()

rows_test_items : U64 -> List(RowsTestItem)
rows_test_items = |count| {
	var $items = List.with_capacity(count)
	var $index = 0
	while $index < count {
		$items = $items.append(rows_test_item($index.to_str(), $index))
		$index = $index + 1
	}
	$items
}

## Fresh snapshots publish one complete slot chunk at every 32-cell boundary
## and one final partial chunk, without manufacturing free slots.
expect {
	var $valid = True
	for count in [0, 1, 31, 32, 33, 63, 64, 65, 1000] {
		items = rows_test_items(count)
		built = rows_build_fresh(items, Box.box(rows_test_key))?
		expected_chunks = (count + 31).div_trunc_by(32)
		last_chunk_ok =
			if count == 0 {
				rows_slot_directory_len(built.slots.chunks) == 0
			} else {
				last_chunk_id = (count - 1).div_trunc_by(32)
				expected_last_len = (count - 1).rem_by(32) + 1
				last_chunk = rows_slot_directory_get(built.slots.chunks, last_chunk_id)?
				last_chunk.len() == expected_last_len
			}
		last_slot_ok =
			if count == 0 {
				True
			} else {
				last_slot = rows_slot_pack(count, 1)
				(rows_slots_get(built.slots, last_slot)?).item.value() == count - 1
			}
		order_ok =
			if count == 0 {
				built.order_slots.is_empty()
			} else {
				built.order_slots.len() == count
					and built.order_slots.get(0)? == rows_slot_pack(1, 1)
						and built.order_slots.get(count - 1)? == rows_slot_pack(count, 1)
			}
		$valid =
			$valid
				and built.slot_chunks_written == expected_chunks
					and rows_slot_directory_len(built.slots.chunks) == expected_chunks
						and built.slots.next_index == count + 1
							and built.slots.free.is_empty()
								and built.key_index.len() == count
									and last_chunk_ok
										and last_slot_ok
											and order_ok
	}
	$valid
}

## Snapshot replacement rebuilds each affected scattered chunk once, preserves
## surviving slot identities, and advances reused vacant-slot generations.
expect {
	initial = Rows.from_list(rows_test_items(65), rows_test_key)?
	initial_survivor_slot = Rows.platform_slot_at(initial, 64)?
	removed = Rows.apply(initial, [RemoveKey("1"), RemoveKey("33")])?
	Rows(removed_storage) = removed
	replacement_items = [rows_test_item("64", 640), rows_test_item("0", 100), rows_test_item("x", 1), rows_test_item("y", 2)]
	planned = rows_build_replacement(replacement_items, removed_storage.key_of, removed_storage)?
	replaced = Rows.replace_all(removed, replacement_items)?
	Rows(replaced_storage) = replaced

	replaced_survivor_slot = Rows.platform_slot_at(replaced, 0)?
	x_slot = Rows.platform_slot_at(replaced, 2)?
	y_slot = Rows.platform_slot_at(replaced, 3)?
	reused_indexes = [rows_slot_index(x_slot), rows_slot_index(y_slot)].sort_with(
		|left, right| if left < right {
			Before
		} else if left > right {
			After
		} else {
			Same
		},
	)

	planned.slot_chunks_written == 3
		and rows_slot_directory_len(replaced_storage.slots.chunks) == 3
			and replaced_storage.slots.next_index == 66
				and replaced_survivor_slot == initial_survivor_slot
					and reused_indexes == [2, 34]
						and rows_slot_generation(x_slot) == 2
							and rows_slot_generation(y_slot) == 2
								and Rows.to_list(replaced).map(|item| item.key()) == ["64", "0", "x", "y"]
									and Rows.get_key(initial, "1")?.value() == 1
										and Rows.get_key(removed, "64")?.value() == 64
											and Rows.get_key(replaced, "64")?.value() == 640
}

## A saturated removed slot retires permanently during snapshot replacement and
## is never added to the next generation's free list.
expect {
	max_generation = 4294967295
	old_slot = rows_slot_pack(1, max_generation)
	chunks : RowsSlotDirectory(List(RowsSlotCell(RowsTestItem)))
	chunks = rows_slot_directory_insert(rows_slot_directory_empty(), 0, [RowsSlotLive({ generation: max_generation, key: "a", item: rows_test_item("a", 1) })])
	key_index : RowsKeyIndex
	key_index = RowsKeyIndex.empty().insert("a", old_slot)
	old : RowsStorage(RowsTestItem)
	old = {
		token: rows_generation_callable(),
		parent: NoParent,
		transition: Snapshot,
		key_of: Box.box(rows_test_key),
		order: rows_order_from_slots([old_slot]),
		slots: { chunks, free: RowsIdStack.empty(), next_index: 2 },
		key_index,
		snapshot_key_bytes: 1,
		op_count: 0,
		delta_key_count: 0,
		delta_key_bytes: 0,
	}
	built = rows_build_replacement([], old.key_of, old)?
	retired =
		match rows_slots_cell(built.slots, 1)? {
			RowsSlotRetired => True
			_ => False
		}

	retired and built.slots.free.is_empty() and built.slot_chunks_written == 1 and (rows_slots_get(old.slots, old_slot)?).item.value() == 1
}

## Bulk clear advances each live slot exactly once, keeps already-vacant
## generations unchanged, and leaves the old immutable generations readable.
expect {
	initial = Rows.from_list([rows_test_item("a", 1), rows_test_item("b", 2), rows_test_item("c", 3)], rows_test_key)?
	initial_a = Rows.platform_slot_at(initial, 0)?
	initial_b = Rows.platform_slot_at(initial, 1)?
	initial_c = Rows.platform_slot_at(initial, 2)?
	removed = Rows.apply(initial, [RemoveKey("b")])?
	cleared = Rows.apply(removed, [Clear])?
	rebuilt = Rows.replace_all(cleared, [rows_test_item("x", 10), rows_test_item("y", 20), rows_test_item("z", 30)])?
	rebuilt_a = Rows.platform_slot_at(rebuilt, 0)?
	rebuilt_b = Rows.platform_slot_at(rebuilt, 1)?
	rebuilt_c = Rows.platform_slot_at(rebuilt, 2)?
	reused_indexes = [rows_slot_index(rebuilt_a), rows_slot_index(rebuilt_b), rows_slot_index(rebuilt_c)].sort_with(
		|left, right| if left < right {
			Before
		} else if left > right {
			After
		} else {
			Same
		},
	)

	reused_indexes == [rows_slot_index(initial_a), rows_slot_index(initial_b), rows_slot_index(initial_c)]
		and rows_slot_generation(rebuilt_a) == 2
			and rows_slot_generation(rebuilt_b) == 2
				and rows_slot_generation(rebuilt_c) == 2
					and Rows.get(initial, 1)?.value() == 2
						and Rows.get(removed, 0)?.value() == 1
}

## Bulk clear handles live, vacant, retired, and saturated cells in one chunk.
## Reusable cells appear once in deterministic dense-index order, while both
## live values remain readable through the previous immutable generation.
expect {
	max_generation = 4294967295
	first_slot = rows_slot_pack(1, 1)
	saturated_slot = rows_slot_pack(4, max_generation)
	chunks : RowsSlotDirectory(List(RowsSlotCell(RowsTestItem)))
	chunks = rows_slot_directory_insert(
		rows_slot_directory_empty(),
		0,
		[
			RowsSlotLive({ generation: 1, key: "a", item: rows_test_item("a", 1) }),
			RowsSlotVacant({ generation: 7 }),
			RowsSlotRetired,
			RowsSlotLive({ generation: max_generation, key: "d", item: rows_test_item("d", 4) }),
		],
	)
	key_index : RowsKeyIndex
	key_index = RowsKeyIndex.empty().insert("a", first_slot).insert("d", saturated_slot)
	old_storage : RowsStorage(RowsTestItem)
	old_storage = {
		token: rows_generation_callable(),
		parent: NoParent,
		transition: Snapshot,
		key_of: Box.box(rows_test_key),
		order: rows_order_from_slots([first_slot, saturated_slot]),
		slots: { chunks, free: RowsIdStack.from_list([2]), next_index: 5 },
		key_index,
		snapshot_key_bytes: 2,
		op_count: 0,
		delta_key_count: 0,
		delta_key_bytes: 0,
	}
	old = Rows(old_storage)
	cleared = Rows.apply(old, [Clear])?
	Rows(cleared_storage) = cleared
	first_vacant =
		match rows_slots_cell(cleared_storage.slots, 1)? {
			RowsSlotVacant({ generation: 2 }) => True
			_ => False
		}
	second_preserved =
		match rows_slots_cell(cleared_storage.slots, 2)? {
			RowsSlotVacant({ generation: 7 }) => True
			_ => False
		}
	third_retired =
		match rows_slots_cell(cleared_storage.slots, 3)? {
			RowsSlotRetired => True
			_ => False
		}
	saturated_retired =
		match rows_slots_cell(cleared_storage.slots, 4)? {
			RowsSlotRetired => True
			_ => False
		}

	first_vacant
		and second_preserved
			and third_retired
				and saturated_retired
					and cleared_storage.slots.free.to_list() == [1, 2]
						and Rows.platform_item_for_slot(old, first_slot)?.value() == 1
							and Rows.platform_item_for_slot(old, saturated_slot)?.value() == 4
}

## Clearing an empty collection is a no-op snapshot and allocates no slot
## generation solely to restate the existing empty value.
expect {
	empty = Rows.empty(rows_test_key)
	cleared = Rows.apply(empty, [Clear])?
	Rows(storage) = cleared

	cleared.len() == 0
		and Rows.platform_transition_kind(cleared) == Snapshot
			and storage.slots.next_index == 1
				and rows_slot_directory_is_empty(storage.slots.chunks)
					and storage.slots.free.is_empty()
}

## Replacement failures publish no generation and leave the previous snapshot
## independently readable.
expect {
	initial = Rows.from_list([rows_test_item("a", 1), rows_test_item("b", 2)], rows_test_key)?
	duplicate = Rows.replace_all(initial, [rows_test_item("same", 3), rows_test_item("same", 4)])
	Rows(initial_storage) = initial
	exhausted_storage : RowsStorage(RowsTestItem)
	exhausted_storage = {
		..initial_storage,
		order: rows_order_empty(),
		slots: { chunks: rows_slot_directory_empty(), free: RowsIdStack.empty(), next_index: rows_slot_base },
		key_index: RowsKeyIndex.empty(),
		snapshot_key_bytes: 0,
	}
	exhausted = Rows.replace_all(Rows(exhausted_storage), [rows_test_item("new", 5)])
	duplicate_failed =
		match duplicate {
			Err(DuplicateKey("same")) => True
			_ => False
		}
	exhausted_failed =
		match exhausted {
			Err(SlotExhausted) => True
			_ => False
		}

	duplicate_failed and exhausted_failed and Rows.get_key(initial, "a")?.value() == 1 and Rows.get_key(initial, "b")?.value() == 2
}

## Chunked order tables keep boundary keys dense, support arbitrary bulk input
## order, and preserve bounded edit-time replacement and removal.
expect {
	table = rows_order_table_from_entries([{ key: 65, value: 650 }, { key: 32, value: 320 }, { key: 33, value: 330 }, { key: 1, value: 10 }])
	edited = rows_order_table_set(table, 33, 331)
	removed = rows_order_table_remove(edited, 32)

	rows_order_table_get(removed, 1)? == 10 and rows_order_table_get(removed, 33)? == 331 and rows_order_table_get(removed, 65)? == 650 and removed.len() == 3 and removed.get(0)?.len() == 32 and removed.get(1)?.len() == 1
}

## The persistent order tree splits at the 32-way fanout and retains exact
## indexed/rank lookup while path-copying inserts and removals.
expect {
	var $order = rows_order_empty()
	var $slot = 1
	while $slot <= 2048 {
		$order = rows_order_insert($order, rows_order_len($order), $slot)
		$slot = $slot + 1
	}

	all_indexed = rows_order_get($order, 1023)? == 1024 and rows_order_rank($order, 1537)? == 1536

	var $removed = 0
	while $removed < 1024 {
		removal = rows_order_remove($order, 0)
		$order = removal.order
		$removed = $removed + 1
	}

	all_indexed and rows_order_len($order) == 1024 and rows_order_get($order, 0)? == 1025 and rows_order_rank($order, 2048)? == 1023
}

## Fresh bulk construction creates exactly the packed 32-way shape: 32 leaves
## and one root for 1k rows, with no edit-path nodes or free-list churn.
expect {
	var $slots = []
	var $slot = 1
	while $slot <= 1000 {
		$slots = $slots.append($slot)
		$slot = $slot + 1
	}
	order = rows_order_from_slots($slots)

	rows_order_len(order) == 1000 and order.nodes.len() == 2 and order.parents.len() == 2 and order.slot_leaf.len() == 32 and order.next_node == 34 and order.free_nodes.is_empty() and rows_order_get(order, 999)? == 1000 and rows_order_rank(order, 513)? == 512
}

## Chunked slots advance their generation before reuse, so an old packed id
## cannot read a new occupant of the same dense index.
expect {
	empty_slots : RowsSlotStore(RowsTestItem)
	empty_slots = rows_slots_empty()
	first = rows_slots_allocate(empty_slots, "a", rows_test_item("a", 1))?
	released = rows_slots_release(first.slots, first.slot)?
	second = rows_slots_allocate(released, "b", rows_test_item("b", 2))?
	stale_missing =
		match rows_slots_get(second.slots, first.slot) {
			Err(Missing) => True
			_ => False
		}

	stale_missing and rows_slot_index(first.slot) == rows_slot_index(second.slot) and rows_slot_generation(second.slot) == rows_slot_generation(first.slot) + 1 and (rows_slots_get(second.slots, second.slot)?).item.value() == 2
}

## Clearing a repeatedly split order tree releases dead node and parent records
## in the new persistent generation instead of retaining the high-water shape.
expect {
	var $order = rows_order_empty()
	var $cycle = 0
	while $cycle < 64 {
		var $slot = 1
		while $slot <= 256 {
			$order = rows_order_insert($order, rows_order_len($order), $slot)
			$slot = $slot + 1
		}
		var $remaining = 256
		while $remaining > 0 {
			$order = rows_order_remove($order, 0).order
			$remaining = $remaining - 1
		}
		$cycle = $cycle + 1
	}

	rows_order_len($order) == 0 and $order.nodes.len() == 1 and $order.parents.len() == 1 and $order.next_node == 2
}

## Construction caches keys and rejects duplicate exact UTF-8 identity.
expect {
	duplicate = Rows.from_list([rows_test_item("same", 1), rows_test_item("same", 2)], rows_test_key)
	valid = Rows.from_list([rows_test_item("a", 1), rows_test_item("b", 2)], rows_test_key)?

	duplicate_is_error =
		match duplicate {
			Err(DuplicateKey("same")) => True
			_ => False
		}

	duplicate_is_error and (Rows.get_key(valid, "b")?).value() == 2 and Rows.platform_key_at(valid, 0)? == "a"
}

## Sequential edits use post-removal move destinations and key-addressed updates.
expect {
	initial = Rows.from_list(
		[rows_test_item("a", 1), rows_test_item("b", 2), rows_test_item("c", 3), rows_test_item("d", 4)],
		rows_test_key,
	)?
	updated = Rows.apply(
		initial,
		[
			MoveRange({ from: 1, count: 2, to: 0 }),
			SetKey({ key: "b", item: rows_test_item("b", 20) }),
			RemoveKey("a"),
			Append([rows_test_item("e", 5)]),
		],
	)?

	Rows.to_list(updated).map(|item| item.value()) == [20, 3, 4, 5]
}

## A remove/reinsert pair in one unpublished batch preserves the stable slot.
expect {
	initial = Rows.from_list([rows_test_item("a", 1), rows_test_item("b", 2)], rows_test_key)?
	before_slot = Rows.platform_slot_at(initial, 0)?
	updated = Rows.apply(
		initial,
		[
			RemoveKey("a"),
			Append([rows_test_item("a", 9)]),
		],
	)?
	after_slot = Rows.platform_slot_at(updated, 1)?

	before_slot == after_slot and (Rows.get_key(updated, "a")?).value() == 9
}

## Equal same-key sets normalize away without manufacturing a delta.
expect {
	initial = Rows.from_list([rows_test_item("a", 1)], rows_test_key)?
	updated = Rows.apply(initial, [SetAt({ at: 0, item: rows_test_item("a", 1) })])?

	Rows.platform_transition_kind(updated) == Snapshot
}

## A value changed away and back in one batch preserves the original generation.
expect {
	initial = Rows.from_list([rows_test_item("a", 1)], rows_test_key)?
	updated = Rows.apply(
		initial,
		[
			SetKey({ key: "a", item: rows_test_item("a", 2) }),
			SetKey({ key: "a", item: rows_test_item("a", 1) }),
		],
	)?

	Rows.platform_transition_kind(updated) == Snapshot
}

## A move away and back in one batch preserves the original generation.
expect {
	initial = Rows.from_list(
		[rows_test_item("a", 1), rows_test_item("b", 2), rows_test_item("c", 3)],
		rows_test_key,
	)?
	updated = Rows.apply(
		initial,
		[
			MoveKeyBefore({ key: "c", before: Key("a") }),
			MoveKeyBefore({ key: "c", before: End }),
		],
	)?

	Rows.platform_transition_kind(updated) == Snapshot
}

## An inserted row removed again in one batch does not consume a generation.
expect {
	initial = Rows.from_list([rows_test_item("a", 1)], rows_test_key)?
	updated = Rows.apply(
		initial,
		[
			Append([rows_test_item("temporary", 2)]),
			RemoveKey("temporary"),
		],
	)?

	Rows.platform_transition_kind(updated) == Snapshot
}

## Clearing and restoring the same rows preserves their slots and generation.
expect {
	initial = Rows.from_list([rows_test_item("a", 1), rows_test_item("b", 2)], rows_test_key)?
	initial_slots = [Rows.platform_slot_at(initial, 0)?, Rows.platform_slot_at(initial, 1)?]
	updated = Rows.apply(
		initial,
		[
			Clear,
			Append([rows_test_item("a", 1), rows_test_item("b", 2)]),
		],
	)?
	updated_slots = [Rows.platform_slot_at(updated, 0)?, Rows.platform_slot_at(updated, 1)?]

	Rows.platform_transition_kind(updated) == Snapshot and initial_slots == updated_slots
}

## A changed batch exposes only the canonical net transition sequence.
expect {
	initial = Rows.from_list([rows_test_item("a", 1), rows_test_item("b", 2)], rows_test_key)?
	updated = Rows.apply(
		initial,
		[
			SetKey({ key: "a", item: rows_test_item("a", 2) }),
			SetKey({ key: "a", item: rows_test_item("a", 3) }),
		],
	)?
	transition_count = Rows.platform_copy_delta(updated, 0, |count, _transition| count + 1)

	Rows.platform_transition_kind(updated) == Delta and transition_count == 1
}

## Cached descriptions count exact UTF-8 bytes and canonical stable-slot ops.
expect {
	initial = Rows.from_list([rows_test_item("a", 1), rows_test_item("é", 2)], rows_test_key)?
	snapshot = Rows.platform_description(initial)
	updated = Rows.apply(
		initial,
		[
			SetKey({ key: "a", item: rows_test_item("a", 10) }),
			Append([rows_test_item("xyz", 3)]),
		],
	)?
	delta = Rows.platform_description(updated)
	stable_operands =
		Rows.platform_copy_delta(
			updated,
			True,
			|valid, transition|
				valid and match transition {
					InsertRow({ op_index, before_slot, slot, key }) => op_index == 0 and before_slot == 0 and slot != 0 and key == "xyz"
					UpdateRow({ op_index, slot, key }) => op_index == 1 and slot != 0 and key == "a"
					_ => False
				},
		)

	snapshot.kind == Snapshot and snapshot.snapshot_key_bytes == 3 and delta.kind == Delta and delta.item_count == 3 and delta.snapshot_key_bytes == 6 and delta.op_count == 2 and delta.delta_key_count == 2 and delta.delta_key_bytes == 4 and stable_operands
}

## A key-changing set resets slot identity while a same-key replacement keeps it.
expect {
	initial = Rows.from_list([rows_test_item("a", 1)], rows_test_key)?
	initial_slot = Rows.platform_slot_at(initial, 0)?
	same_key = Rows.apply(initial, [SetKey({ key: "a", item: rows_test_item("a", 2) })])?
	same_key_slot = Rows.platform_slot_at(same_key, 0)?
	changed_key = Rows.apply(same_key, [SetAt({ at: 0, item: rows_test_item("b", 3) })])?
	changed_key_slot = Rows.platform_slot_at(changed_key, 0)?

	initial_slot == same_key_slot and same_key_slot != changed_key_slot and (Rows.get_key(changed_key, "b")?).value() == 3
}

## Snapshot replacement reuses slots for surviving keys and remains structurally comparable.
expect {
	initial = Rows.from_list([rows_test_item("a", 1), rows_test_item("b", 2)], rows_test_key)?
	old_b_slot = Rows.platform_slot_at(initial, 1)?
	replaced = Rows.replace_all(initial, [rows_test_item("b", 20), rows_test_item("c", 3)])?
	new_b_slot = Rows.platform_slot_at(replaced, 0)?
	expected = Rows.from_list([rows_test_item("b", 20), rows_test_item("c", 3)], rows_test_key)?

	old_b_slot == new_b_slot and Rows.content_is_eq(replaced, expected)
}

## Published remove/reinsert churn reuses chunked slots and bounded order nodes.
expect {
	initial = Rows.from_list([rows_test_item("a", 1), rows_test_item("b", 2)], rows_test_key)?
	var $rows = initial
	var $cycle = 0
	while $cycle < 256 {
		removed = Rows.apply($rows, [RemoveKey("a")])?
		$rows = Rows.apply(removed, [InsertAt({ at: 0, items: [rows_test_item("a", $cycle)] })])?
		$cycle = $cycle + 1
	}
	Rows(storage) = $rows

	storage.slots.next_index == 3 and rows_slot_directory_len(storage.slots.chunks) == 1 and storage.order.nodes.len() <= 3 and storage.order.parents.len() <= 3
}

## A 10k direct clear publishes one structural operation, retires every old
## slot generation, and leaves the reusable slot store at a fixed high-water
## mark instead of repeatedly rewriting the persistent order and key index.
expect {
	items = rows_test_items(10000)
	initial = Rows.from_list(items, rows_test_key)?
	old_slot = Rows.platform_slot_at(initial, 0)?
	cleared = Rows.apply(initial, [Clear])?
	description = Rows.platform_description(cleared)
	transition_count = Rows.platform_copy_delta(
		cleared,
		0,
		|count, transition|
			count
				+ match transition {
					ClearRows => 1
					_ => 1000
				},
	)
	Rows(cleared_storage) = cleared
	rebuilt = Rows.replace_all(cleared, items)?
	Rows(rebuilt_storage) = rebuilt
	old_slot_retired =
		match Rows.platform_item_for_slot(cleared, old_slot) {
			Err(_) => True
			Ok(_) => False
		}

	Rows(initial_storage) = initial
	bulk_shape =
		initial_storage.order.nodes.len() == 11
			and initial_storage.order.parents.len() == 11
				and initial_storage.order.slot_leaf.len() == 313
					and initial_storage.order.next_node == 325
						and initial_storage.order.free_nodes.is_empty()
							and rows_slot_directory_len(initial_storage.slots.chunks) == 313
								and initial_storage.key_index.len() == 10000
									and Rows.get(initial, 0)?.value() == 0
										and Rows.get(initial, 9999)?.value() == 9999

	cleared.len() == 0 and description.kind == Delta and description.op_count == 1 and transition_count == 1 and old_slot_retired and cleared_storage.slots.next_index == 10001 and rebuilt_storage.slots.next_index == 10001 and rebuilt.len() == 10000 and bulk_shape
}

## Invalid edits return structured errors at the narrow public boundary.
expect {
	initial = Rows.from_list([rows_test_item("a", 1), rows_test_item("b", 2)], rows_test_key)?
	bad_range = Rows.apply(initial, [RemoveRange({ at: 1, count: 2 })])
	duplicate = Rows.apply(initial, [Append([rows_test_item("a", 9)])])

	range_is_error =
		match bad_range {
			Err(RangeOutOfBounds({ at: 1, count: 2, len: 2 })) => True
			_ => False
		}
	duplicate_is_error =
		match duplicate {
			Err(DuplicateKey("a")) => True
			_ => False
		}

	range_is_error and duplicate_is_error
}

rows_index_valid : RowsIndex(key, value) -> Bool
	where [key.is_lt : key, key -> Bool]
rows_index_valid = |tree| match tree {
	IndexEmpty => True
	IndexNode(node) => {
		left_height = rows_index_height(node.left)
		right_height = rows_index_height(node.right)
		left_ordered = match node.left {
			IndexEmpty => True
			IndexNode(left) => left.key.is_lt(node.key)
		}
		right_ordered = match node.right {
			IndexEmpty => True
			IndexNode(right) => node.key.is_lt(right.key)
		}
		expected_height = 1 + if left_height > right_height {
			left_height
		} else {
			right_height
		}
		left_ordered and right_ordered and left_height <= right_height + 1 and right_height <= left_height + 1 and node.height == expected_height and node.size == 1 + node.left.len() + node.right.len() and rows_index_valid(node.left) and rows_index_valid(node.right)
	}
}

## All AVL rotation shapes and repeated retirement preserve surviving entries,
## exact cached sizes, bounded height, and an independently retained old root.
expect {
	initial : RowsIndex(U64, U64)
	initial = RowsIndex.empty()
	var $index = initial
	var $key = 0.U64
	while $key < 1024 {
		$index = $index.insert(($key * 613).rem_by(1024), $key)
		$index = $index.insert(($key * 613).rem_by(1024), ($key * 613).rem_by(1024))
		$key = $key + 1
	}
	retained = $index
	var $valid = rows_index_valid(retained)
	$key = 0
	while $key < 1024 {
		removed = ($key * 613).rem_by(1024)
		$index = $index.remove(removed)
		$valid = $valid and rows_index_valid($index) and $index.len() == 1023 - $key and retained.get(removed)? == removed
		$key = $key + 1
	}
	$valid and $index.is_empty() and retained.len() == 1024 and rows_index_height(retained) <= 15
}

## The slot directory shares untouched chunks across multiple forks and grows
## across both leaf and directory boundaries without changing retained values.
expect {
	var $directory = rows_slot_directory_empty()
	var $key = 0.U64
	while $key < 3125 {
		$directory = rows_slot_directory_insert($directory, $key, [$key])
		$key = $key + 1
	}
	old = $directory
	left = rows_slot_directory_insert(old, 31, [9999])
	right = rows_slot_directory_insert(old, 1024, [8888])
	grown = rows_slot_directory_insert(left, 3125, [3125])
	rows_slot_directory_get(old, 31)? == [31] and rows_slot_directory_get(left, 31)? == [9999] and rows_slot_directory_get(right, 31)? == [31] and rows_slot_directory_get(old, 1024)? == [1024] and rows_slot_directory_get(right, 1024)? == [8888] and rows_slot_directory_get(grown, 3125)? == [3125] and rows_slot_directory_len(old) == 3125 and rows_slot_directory_len(grown) == 3126
}

## A retained large collection survives edits that split leaves and branches,
## grow roots, remove middle ranges, and reuse retired order nodes. A separate
## List models the exact order, including moves interpreted after removal.
expect {
	items = rows_test_items(1050)
	initial = Rows.from_list(items, rows_test_key)?
	var $rows = initial
	var $model = items
	var $step = 0.U64
	var $valid = True
	while $step < 64 {
		at = ($step * 37).rem_by($model.len())
		item = rows_test_item("new-${$step.to_str()}", 2000 + $step)
		old = $rows
		$rows = Rows.apply($rows, [InsertAt({ at, items: [item] })])?
		$model = $model.take_first(at).concat([item]).concat($model.drop_first(at))
		$valid = $valid and old.len() + 1 == $rows.len() and Rows.to_list($rows) == $model
		if $step.rem_by(3) == 0 {
			from = $model.len() - 2
			moving = $model.drop_first(from)
			$rows = Rows.apply($rows, [MoveRange({ from, count: 2, to: 0 })])?
			$model = moving.concat($model.take_first(from))
		} else {
			$rows = Rows.apply($rows, [RemoveRange({ at: 1, count: 1 })])?
			$model = $model.take_first(1).concat($model.drop_first(2))
		}
		$valid = $valid and Rows.to_list($rows) == $model
		$step = $step + 1
	}
	$valid and Rows.to_list(initial) == items
}

## A clear of a large collection must not leave a linear ownership chain: both
## retained generations and the active free stack have logarithmic drop depth.
expect {
	var $values = List.with_capacity(10000)
	var $index = 0.U64
	while $index < 10000 {
		$values = $values.append($index)
		$index = $index + 1
	}
	retained = RowsIdStack.from_list($values)
	free = retained.drop_first(100)
	changed = free.prepend(20000)
	retained.first()? == 0 and free.first()? == 100 and changed.first()? == 20000 and retained.to_list() == $values and rows_index_valid(retained.items) and rows_index_valid(changed.items) and rows_index_height(retained.items) <= 15 and rows_index_height(changed.items) <= 15
}

## Retirement visits newest touches first before pushing free IDs, so
## multiple removals reuse slots in the same order as their original edits.
expect {
	initial = Rows.from_list(rows_test_items(5), rows_test_key)?
	removed = Rows.apply(initial, [RemoveKey("1"), RemoveKey("3")])?
	reused = Rows.apply(removed, [Append([rows_test_item("a", 10), rows_test_item("b", 11)])])?
	first = Rows.platform_slot_at(reused, 3)?
	second = Rows.platform_slot_at(reused, 4)?
	rows_slot_index(first) == 2 and rows_slot_index(second) == 4 and rows_slot_generation(first) == 2 and rows_slot_generation(second) == 2 and Rows.get(initial, 1)?.value() == 1 and Rows.get(initial, 3)?.value() == 3
}

## Sparse patch directories distinguish absent cells from stored values, even
## at the highest representable chunk ID. Forks retain their independent cells.
expect {
	empty = rows_slot_directory_empty()
	high = rows_slot_directory_insert(empty, 134217727, [7.U64])
	low = rows_slot_directory_insert(high, 0, [1])
	middle = rows_slot_directory_insert(low, 1025, [2])
	fork = rows_slot_directory_insert(middle, 134217727, [8])
	missing = match rows_slot_directory_get(middle, 1024) {
		Err(Missing) => True
		_ => False
	}
	missing and rows_slot_directory_is_empty(empty) and rows_slot_directory_len(high) == 1 and rows_slot_directory_len(middle) == 3 and rows_slot_directory_len(fork) == 3 and rows_slot_directory_get(middle, 134217727)? == [7] and rows_slot_directory_get(fork, 134217727)? == [8] and rows_slot_directory_get(middle, 0)? == [1] and rows_slot_directory_get(middle, 1025)? == [2]
}

## Exact key lookup distinguishes prefixes and canonically equivalent Unicode
## spellings by their original UTF-8 bytes, including through retained forks.
expect {
	original = RowsKeyIndex.empty().insert("", 1).insert("a", 2).insert("aa", 3).insert("é", 4).insert("é", 5).insert("😀", 6)
	changed = original.remove("a").insert("é", 7)
	absent = match changed.get("a") {
		Err(Missing) => True
		_ => False
	}
	absent and original.get("a")? == 2 and changed.get("")? == 1 and changed.get("aa")? == 3 and changed.get("é")? == 7 and original.get("é")? == 4 and changed.get("é")? == 5 and changed.get("😀")? == 6
}
