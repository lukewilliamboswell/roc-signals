## Immutable keyed rows for dynamic UI structure. `Rows(item)` owns its key
## function, caches exact UTF-8 keys, preserves stable slot identity, and records
## an authenticated one-generation transition for the host. Applications use the
## collection operations below; the `platform_*` functions are internal adapter
## hooks for `Ui.each` and the shared engine.

RowsGenerationCallable : Box(({} -> Box({})))

RowsEntry(item) : { slot : U64, key : Str, item : item }

RowsOrderNode := [OrderBranch({ children : List(U64), len : U64 }), OrderLeaf({ slots : List(U64), len : U64 })]

RowsOrderParent : [OrderParent({ node : U64, child : U64 }), OrderRoot]

RowsOrder : {
	root : U64,
	nodes : Dict(U64, RowsOrderNode),
	parents : Dict(U64, RowsOrderParent),
	slot_leaf : Dict(U64, U64),
	next_node : U64,
	free_nodes : List(U64),
}

rows_order_node_len : RowsOrderNode -> U64
rows_order_node_len = |node|
	match node {
		OrderLeaf({ len, .. }) => len
		OrderBranch({ len, .. }) => len
	}

rows_order_empty : () -> RowsOrder
rows_order_empty = || {
	nodes : Dict(U64, RowsOrderNode)
	nodes = Dict.empty().insert(1, OrderLeaf({ slots: [], len: 0 }))
	parents : Dict(U64, RowsOrderParent)
	parents = Dict.empty().insert(1, OrderRoot)
	slot_leaf : Dict(U64, U64)
	slot_leaf = Dict.empty()
	{ root: 1, nodes, parents, slot_leaf, next_node: 2, free_nodes: [] }
}

rows_reverse_u64 : List(U64) -> List(U64)
rows_reverse_u64 = |values| values.fold([], |reversed, value| reversed.prepend(value))

## Build a fresh 32-way order tree bottom-up. Snapshot construction already
## knows the complete stable-slot sequence, so inserting each slot through the
## persistent edit path would repeatedly rewrite the same root-to-leaf paths.
rows_order_from_slots : List(U64) -> RowsOrder
rows_order_from_slots = |slots| {
	if slots.is_empty() {
		rows_order_empty()
	} else {
		nodes : Dict(U64, RowsOrderNode)
		nodes = Dict.empty()
		parents : Dict(U64, RowsOrderParent)
		parents = Dict.empty()
		slot_leaf : Dict(U64, U64)
		slot_leaf = Dict.empty()
		var $nodes = nodes
		var $parents = parents
		var $slot_leaf = slot_leaf
		var $next_node = 1
		var $offset = 0
		var $level = []
		while $offset < slots.len() {
			leaf_slots = slots.drop_first($offset).take_first(32)
			leaf_id = $next_node
			$next_node = $next_node + 1
			$nodes = $nodes.insert(leaf_id, OrderLeaf({ slots: leaf_slots, len: leaf_slots.len() }))
			for slot in leaf_slots {
				$slot_leaf = $slot_leaf.insert(slot, leaf_id)
			}
			$level = $level.prepend(leaf_id)
			$offset = $offset + leaf_slots.len()
		}
		$level = rows_reverse_u64($level)

		while $level.len() > 1 {
			var $next_level = []
			var $child_offset = 0
			while $child_offset < $level.len() {
				children = $level.drop_first($child_offset).take_first(32)
				branch_id = $next_node
				$next_node = $next_node + 1
				var $len = 0
				var $child_index = 0
				for child_id in children {
					child = $nodes.get(child_id) ?? crash "Rows bulk order child was missing"
					$len = $len + rows_order_node_len(child)
					$parents = $parents.insert(child_id, OrderParent({ node: branch_id, child: $child_index }))
					$child_index = $child_index + 1
				}
				$nodes = $nodes.insert(branch_id, OrderBranch({ children, len: $len }))
				$next_level = $next_level.prepend(branch_id)
				$child_offset = $child_offset + children.len()
			}
			$level = rows_reverse_u64($next_level)
		}

		root = $level.get(0) ?? crash "Rows bulk order lost its root"
		$parents = $parents.insert(root, OrderRoot)
		{ root, nodes: $nodes, parents: $parents, slot_leaf: $slot_leaf, next_node: $next_node, free_nodes: [] }
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
	root = order.nodes.get(order.root) ?? crash "Rows order root was missing"
	rows_order_node_len(root)
}

RowsOrderLocation : { leaf : U64, offset : U64 }

rows_order_locate_node : RowsOrder, U64, U64, Bool -> RowsOrderLocation
rows_order_locate_node = |order, node_id, index, allow_end| {
	node = order.nodes.get(node_id) ?? crash "Rows order node was missing"
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
				child = order.nodes.get(child_id) ?? crash "Rows order child was missing"
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
		leaf = order.nodes.get(location.leaf) ?? crash "Rows order leaf was missing"
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
		child = order.nodes.get(child_id) ?? crash "Rows order child was missing while measuring"
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
		$parents = $parents.insert(child_id, OrderParent({ node: parent_id, child: $index }))
		$index = $index + 1
	}
	{ ..order, parents: $parents }
}

rows_order_insert_node : RowsOrder, U64, U64, U64 -> RowsOrderRewrite
rows_order_insert_node = |order, node_id, index, slot| {
	node = order.nodes.get(node_id) ?? crash "Rows order insertion node was missing"
	match node {
		OrderLeaf({ slots, len }) => {
			inserted = slots.take_first(index).concat([slot]).concat(slots.drop_first(index))
			if inserted.len() <= 32 {
				nodes = order.nodes.insert(node_id, OrderLeaf({ slots: inserted, len: len + 1 }))
				updated_leaf_order = { ..order, nodes, slot_leaf: order.slot_leaf.insert(slot, node_id) }
				{ order: updated_leaf_order, replacements: [node_id] }
			} else {
				left_slots = inserted.take_first(16)
				right_slots = inserted.drop_first(16)
				allocation = rows_order_allocate_node(order)
				right_id = allocation.node
				nodes =
					allocation.order.nodes
						.insert(node_id, OrderLeaf({ slots: left_slots, len: left_slots.len() }))
						.insert(right_id, OrderLeaf({ slots: right_slots, len: right_slots.len() }))
				var $slot_leaf = allocation.order.slot_leaf
				for left_slot in left_slots {
					$slot_leaf = $slot_leaf.insert(left_slot, node_id)
				}
				for right_slot in right_slots {
					$slot_leaf = $slot_leaf.insert(right_slot, right_id)
				}
				parent = allocation.order.parents.get(node_id) ?? crash "Rows order leaf parent was missing"
				parents = allocation.order.parents.insert(right_id, parent)
				{
					order: { ..allocation.order, nodes, parents, slot_leaf: $slot_leaf },
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
				child = order.nodes.get(child_id) ?? crash "Rows order branch child node was missing"
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
					nodes: child_rewrite.order.nodes.insert(node_id, OrderBranch({ children: replaced_children, len: len + 1 })),
				}
				parented = rows_order_set_child_parents(updated_order, node_id, replaced_children)
				{ order: parented, replacements: [node_id] }
			} else {
				left_children = replaced_children.take_first(16)
				right_children = replaced_children.drop_first(16)
				allocation = rows_order_allocate_node(child_rewrite.order)
				right_id = allocation.node
				left_len = rows_order_children_len(child_rewrite.order, left_children)
				right_len = rows_order_children_len(child_rewrite.order, right_children)
				nodes =
					allocation.order.nodes
						.insert(node_id, OrderBranch({ children: left_children, len: left_len }))
						.insert(right_id, OrderBranch({ children: right_children, len: right_len }))
				parent = allocation.order.parents.get(node_id) ?? crash "Rows order branch parent was missing"
				parents = allocation.order.parents.insert(right_id, parent)
				split_order = { ..allocation.order, nodes, parents }
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
		nodes = allocation.order.nodes.insert(root_id, OrderBranch({ children: rewrite.replacements, len: root_len }))
		parents = allocation.order.parents.insert(root_id, OrderRoot)
		rooted = { ..allocation.order, root: root_id, nodes, parents }
		rows_order_set_child_parents(rooted, root_id, rewrite.replacements)
	}
}

RowsOrderRemoval : { order : RowsOrder, removed : U64, replacements : List(U64) }

rows_order_remove_node : RowsOrder, U64, U64 -> RowsOrderRemoval
rows_order_remove_node = |order, node_id, index| {
	node = order.nodes.get(node_id) ?? crash "Rows order removal node was missing"
	match node {
		OrderLeaf({ slots, len }) => {
			removed = slots.get(index) ?? crash "Rows order removal index exceeded its leaf"
			remaining = slots.take_first(index).concat(slots.drop_first(index + 1))
			nodes =
				if remaining.is_empty() {
					order.nodes.remove(node_id)
				} else {
					order.nodes.insert(node_id, OrderLeaf({ slots: remaining, len: len - 1 }))
				}
			parents = if remaining.is_empty() {
				order.parents.remove(node_id)
			} else {
				order.parents
			}
			free_nodes = if remaining.is_empty() {
				order.free_nodes.prepend(node_id)
			} else {
				order.free_nodes
			}
			next_order = { ..order, nodes, parents, free_nodes, slot_leaf: order.slot_leaf.remove(removed) }
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
				child = order.nodes.get(child_id) ?? crash "Rows order removal child node was missing"
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
					child_removal.order.nodes.remove(node_id)
				} else {
					child_removal.order.nodes.insert(node_id, OrderBranch({ children: replaced_children, len: len - 1 }))
				}
			parents = if replaced_children.is_empty() {
				child_removal.order.parents.remove(node_id)
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
		root_node = removal.order.nodes.get(root_id) ?? crash "Rows order removal root was missing"
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
				{ ..removal.order, nodes: removal.order.nodes.remove(root_id), parents: removal.order.parents.remove(root_id), free_nodes: removal.order.free_nodes.prepend(root_id) }
			}
		parents = collapsed_order.parents.insert(collapsed_root, OrderRoot)
		{ order: { ..collapsed_order, root: collapsed_root, parents }, removed: removal.removed }
	}
}

rows_order_rank : RowsOrder, U64 -> Try(U64, [Missing])
rows_order_rank = |order, slot| {
	leaf_id = order.slot_leaf.get(slot) ? |_| Missing
	leaf = order.nodes.get(leaf_id) ?? crash "Rows slot leaf was missing"
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
		parent = order.parents.get($node_id) ?? crash "Rows order parent was missing"
		match parent {
			OrderRoot => {
				$done = True
			}
			OrderParent({ node: parent_id, child: child_index }) => {
				parent_node = order.nodes.get(parent_id) ?? crash "Rows order parent node was missing"
				match parent_node {
					OrderLeaf(_) => crash "Rows order parent was a leaf"
					OrderBranch({ children, .. }) => {
						var $sibling = 0
						while $sibling < child_index {
							sibling_id = children.get($sibling) ?? crash "Rows order sibling index was invalid"
							sibling_node = order.nodes.get(sibling_id) ?? crash "Rows order sibling was missing"
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
	node = order.nodes.get(node_id) ?? crash "Rows order fold node was missing"
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
	chunks : Dict(U64, List(RowsSlotCell(item))),
	free : List(U64),
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
	chunks : Dict(U64, List(RowsSlotCell(item)))
	chunks = Dict.empty()
	{ chunks, free: [], next_index: 1 }
}

rows_slots_cell : RowsSlotStore(item), U64 -> Try(RowsSlotCell(item), [Missing])
rows_slots_cell = |slots, index| {
	if index == 0 {
		Err(Missing)
	} else {
		zero_index = index - 1
		chunk_index = zero_index.div_trunc_by(32)
		offset = zero_index.rem_by(32)
		chunk = slots.chunks.get(chunk_index) ? |_| Missing
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
	chunk = slots.chunks.get(chunk_index) ?? []
	updated_chunk =
		if offset == chunk.len() {
			chunk.append(cell)
		} else {
			chunk.set(offset, cell) ?? crash "Rows slot chunk offset was invalid"
		}
	{ ..slots, chunks: slots.chunks.insert(chunk_index, updated_chunk) }
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
	key_index : Dict(Str, U64),
	snapshot_key_bytes : U64,
	op_count : U64,
	delta_key_count : U64,
	delta_key_bytes : U64,
}

RowsBuild(item) : {
	order_slots : List(U64),
	slots : RowsSlotStore(item),
	key_index : Dict(Str, U64),
	key_bytes : U64,
}

RowsEditState(item) : {
	order : RowsOrder,
	slots : RowsSlotStore(item),
	key_index : Dict(Str, U64),
	key_bytes : U64,
	removed : Dict(Str, RowsEntry(item)),
	touched : Dict(U64, Bool),
	touched_rev : List(U64),
}

rows_generation_callable : () -> RowsGenerationCallable
rows_generation_callable = || {
	marker = Box.box({})
	identity : {} -> Box({})
	identity = |_unit| marker
	Box.box(identity)
}

rows_empty_indexes : () -> { key_index : Dict(Str, U64) }
rows_empty_indexes = || {
	key_index : Dict(Str, U64)
	key_index = Dict.empty()
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

rows_build_fresh : List(item), Box((item -> Str)), U64, U64, RowsBuild(item) -> Try(RowsBuild(item), Rows.Error)
rows_build_fresh = |items, key_of, index, len, build|
	if index == len {
		Ok(build)
	} else {
		item = items.get(index) ?? crash "Rows input length changed during construction"
		key = Box.unbox(key_of)(item)
		match build.key_index.get(key) {
			Ok(_) => Err(DuplicateKey(key))
			Err(_) => {
				allocated = rows_slots_allocate(build.slots, key, item)?
				rows_build_fresh(
					items,
					key_of,
					index + 1,
					len,
					{
						order_slots: build.order_slots.prepend(allocated.slot),
						slots: allocated.slots,
						key_index: build.key_index.insert(key, allocated.slot),
						key_bytes: build.key_bytes + key.to_utf8().len(),
					},
				)
			}
		}
	}

rows_build_replacement : List(item), Box((item -> Str)), RowsStorage(item), U64, U64, RowsBuild(item) -> Try(RowsBuild(item), Rows.Error)
rows_build_replacement = |items, key_of, old, index, len, build|
	if index == len {
		Ok(build)
	} else {
		item = items.get(index) ?? crash "Rows replacement length changed during construction"
		key = Box.unbox(key_of)(item)
		match build.key_index.get(key) {
			Ok(_) => Err(DuplicateKey(key))
			Err(_) => {
				entry_and_slots =
					match old.key_index.get(key) {
						Ok(old_slot) => {
							replaced = rows_slots_replace(build.slots, old_slot, key, item) ?? crash "Rows key index named a stale slot"
							{ slot: old_slot, slots: replaced }
						}
						Err(_) => {
							allocated = rows_slots_allocate(build.slots, key, item)?
							{ slot: allocated.slot, slots: allocated.slots }
						}
					}
				rows_build_replacement(
					items,
					key_of,
					old,
					index + 1,
					len,
					{
						order_slots: build.order_slots.prepend(entry_and_slots.slot),
						slots: entry_and_slots.slots,
						key_index: build.key_index.insert(key, entry_and_slots.slot),
						key_bytes: build.key_bytes + key.to_utf8().len(),
					},
				)
			}
		}
	}

rows_release_replaced_slots : RowsStorage(item), RowsBuild(item) -> RowsSlotStore(item)
rows_release_replaced_slots = |old, build| {
	var $slots = build.slots
	var $index = 0
	while $index < rows_order_len(old.order) {
		entry = rows_entry_at(old.order, old.slots, $index) ?? crash "Rows replacement old index was invalid"
		match build.key_index.get(entry.key) {
			Ok(_) => {}
			Err(_) => {
				$slots = rows_slots_release($slots, entry.slot) ?? crash "Rows replacement retired a stale slot"
			}
		}
		$index = $index + 1
	}
	$slots
}

## Retire every live slot without repeatedly path-copying the order tree or
## deleting exact-key index entries. The old generation retains its immutable
## storage; this produces the independently owned slot generation used by the
## new empty collection.
rows_release_all_slots : RowsStorage(item) -> RowsSlotStore(item)
rows_release_all_slots = |old| {
	var $slots = old.slots
	var $index = 0
	while $index < rows_order_len(old.order) {
		slot = rows_order_get(old.order, $index) ?? crash "Rows clear order contained an invalid slot"
		$slots = rows_slots_release($slots, slot) ?? crash "Rows clear retired a stale slot"
		$index = $index + 1
	}
	$slots
}

rows_reverse : List(a) -> List(a)
rows_reverse = |items| {
	var $reversed = []
	for item in items {
		$reversed = $reversed.prepend(item)
	}
	$reversed
}

rows_remove_at_loop : RowsEditState(item), U64, U64, List(RowsEntry(item)) -> RowsEditState(item)
rows_remove_at_loop = |state, at, remaining, removed_rev|
	if remaining == 0 {
		_ = removed_rev
		state
	} else {
		entry = rows_entry_at(state.order, state.slots, at) ?? crash "Rows removal index exceeded its order"
		order_removal = rows_order_remove(state.order, at)
		next = {
			..state,
			order: order_removal.order,
			key_index: state.key_index.remove(entry.key),
			key_bytes: state.key_bytes - entry.key.to_utf8().len(),
			removed: state.removed.insert(entry.key, entry),
			touched: state.touched.insert(entry.slot, True),
			touched_rev: state.touched_rev.prepend(entry.slot),
		}
		rows_remove_at_loop(next, at, remaining - 1, removed_rev.prepend(entry))
	}

rows_remove_at : RowsEditState(item), U64, U64 -> RowsEditState(item)
rows_remove_at = |state, at, count| rows_remove_at_loop(state, at, count, [])

rows_insert_items : RowsEditState(item), Box((item -> Str)), U64, List(item), U64, U64, List(RowsEntry(item)) -> Try(RowsEditState(item), Rows.Error)
rows_insert_items = |state, key_of, at, items, item_index, item_len, entries_rev|
	if item_index == item_len {
		_ = entries_rev
		Ok(state)
	} else {
		item = items.get(item_index) ?? crash "Rows inserted item length changed during construction"
		key = Box.unbox(key_of)(item)
		match state.key_index.get(key) {
			Ok(_) => Err(DuplicateKey(key))
			Err(_) => {
				entry_and_state =
					match state.removed.get(key) {
						Ok(removed_entry) => {
							replaced_slots = rows_slots_replace(state.slots, removed_entry.slot, key, item) ?? crash "Rows removed entry slot became stale"
							{
								entry: { slot: removed_entry.slot, key, item },
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
					key_bytes: entry_and_state.state.key_bytes + key.to_utf8().len(),
					touched: entry_and_state.state.touched.insert(entry_and_state.entry.slot, True),
					touched_rev: entry_and_state.state.touched_rev.prepend(entry_and_state.entry.slot),
				}
				rows_insert_items(next_state, key_of, at, items, item_index + 1, item_len, entries_rev.prepend(entry_and_state.entry))
			}
		}
	}

rows_order_take_range : RowsOrder, U64, U64 -> { order : RowsOrder, slots : List(U64) }
rows_order_take_range = |order, from, count| {
	var $order = order
	var $slots_rev = []
	var $remaining = count
	while $remaining > 0 {
		removal = rows_order_remove($order, from)
		$order = removal.order
		$slots_rev = $slots_rev.prepend(removal.removed)
		$remaining = $remaining - 1
	}
	{ order: $order, slots: rows_reverse($slots_rev) }
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
				rows_insert_items(state, key_of, rows_order_len(state.order), items, 0, items.len(), [])
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
				rows_insert_items(state, key_of, at, items, 0, items.len(), [])
			}
		InsertBefore({ before, items }) =>
			match state.key_index.get(before) {
				Err(_) => Err(KeyNotFound(before))
				Ok(before_slot) =>
					if items.is_empty() {
						Ok(state)
					} else {
						at = rows_order_rank(state.order, before_slot) ?? crash "Rows key slot was absent from order"
						rows_insert_items(state, key_of, at, items, 0, items.len(), [])
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
						next = { ..state, order: moved_order, touched: state.touched.insert(moving_slot, True), touched_rev: state.touched_rev.prepend(moving_slot) }
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
				var $touched = state.touched
				var $touched_rev = state.touched_rev
				for moved_slot in taken.slots {
					$touched = $touched.insert(moved_slot, True)
					$touched_rev = $touched_rev.prepend(moved_slot)
				}
				next = { ..state, order: moved_order, touched: $touched, touched_rev: $touched_rev }
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
						next = { ..state, slots: updated_slots, touched: state.touched.insert(before_entry.slot, True), touched_rev: state.touched_rev.prepend(before_entry.slot) }
						Ok(next)
					}
				} else {
					match state.key_index.get(new_key) {
						Ok(_) => Err(DuplicateKey(new_key))
						Err(_) => {
							removed = rows_remove_at(state, at, 1)
							rows_insert_items(removed, key_of, at, [item], 0, 1, [])
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
		for slot in final.touched_rev {
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
	var $numbered = []
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
		$numbered = $numbered.prepend(numbered_transition)
		$op_index = $op_index + 1
	}
	rows_reverse($numbered)
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
		var $touched = []
		for slot in final.touched_rev {
			match $seen.get(slot) {
				Ok(_) => {}
				Err(_) => {
					$seen = $seen.insert(slot, True)
					$touched = $touched.prepend(slot)
				}
			}
		}

		var $working = old.order
		var $canonical_rev = []
		for slot in $touched {
			match rows_order_rank($working, slot) {
				Err(_) => {}
				Ok(at) =>
					match rows_order_rank(final.order, slot) {
						Ok(_) => {}
						Err(_) => {
							removal = rows_order_remove($working, at)
							$working = removal.order
							$canonical_rev = $canonical_rev.prepend(RemoveRows({ op_index: 0, first_slot: slot, count: 1 }))
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

		for target in target_rows {
			match rows_order_rank($working, target.slot) {
				Err(_) => {
					before_slot = rows_order_get($working, target.rank) ?? 0
					$working = rows_order_insert($working, target.rank, target.slot)
					entry = rows_entry_for_slot(final.slots, target.slot) ?? crash "Rows canonical inserted slot was stale"
					$canonical_rev = $canonical_rev.prepend(InsertRow({ op_index: 0, before_slot, slot: target.slot, key: entry.key }))
				}
				Ok(current_rank) =>
					if current_rank != target.rank {
						removal = rows_order_remove($working, current_rank)
						before_slot = rows_order_get(removal.order, target.rank) ?? 0
						$working = rows_order_insert(removal.order, target.rank, target.slot)
						$canonical_rev = $canonical_rev.prepend(MoveRows({ op_index: 0, first_slot: target.slot, count: 1, before_slot }))
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
						$canonical_rev = $canonical_rev.prepend(UpdateRow({ op_index: 0, slot: target.slot, key: final_entry.key }))
					}
				}
			}
		}
		rows_number_transitions(rows_reverse($canonical_rev))
	}
}

rows_release_absent_touched : RowsEditState(item) -> RowsSlotStore(item)
rows_release_absent_touched = |state| {
	seen : Dict(U64, Bool)
	seen = Dict.empty()
	var $seen = seen
	var $slots = state.slots
	for slot in state.touched_rev {
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
				$key_bytes = $key_bytes + key.to_utf8().len()
				$key_count = $key_count + 1
			}
			UpdateRow({ key, .. }) => {
				$key_bytes = $key_bytes + key.to_utf8().len()
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

	## Hosted O(1) raw callable-identity comparison. `platform/main.roc` binds
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
		indexes = rows_empty_indexes()
		key_of_box = Box.box(key_of)
		built = rows_build_fresh(
			items,
			key_of_box,
			0,
			items.len(),
			{ order_slots: [], slots: rows_slots_empty(), key_index: indexes.key_index, key_bytes: 0 },
		)?
		Ok(
			Rows({
				token: rows_generation_callable(),
				parent: NoParent,
				transition: Snapshot,
				key_of: key_of_box,
				order: rows_order_from_slots(rows_reverse_u64(built.order_slots)),
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
		indexes = rows_empty_indexes()
		built = rows_build_replacement(
			items,
			old.key_of,
			old,
			0,
			items.len(),
			{ order_slots: [], slots: old.slots, key_index: indexes.key_index, key_bytes: 0 },
		)?
		final_slots = rows_release_replaced_slots(old, built)
		Ok(
			Rows({
				token: rows_generation_callable(),
				parent: Parent(old.token),
				transition: Snapshot,
				key_of: old.key_of,
				order: rows_order_from_slots(rows_reverse_u64(built.order_slots)),
				slots: final_slots,
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
			removed : Dict(Str, RowsEntry(item))
			removed = Dict.empty()
			state = {
				order: old.order,
				slots: old.slots,
				key_index: old.key_index,
				key_bytes: old.snapshot_key_bytes,
				removed,
				touched: Dict.empty(),
				touched_rev: [],
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
		reversed =
			rows_order_fold(
				storage.order,
				[],
				|items, slot| {
					entry = rows_entry_for_slot(storage.slots, slot) ?? crash "Rows materialization slot was stale"
					items.prepend(entry.item)
				},
			)
		rows_reverse(reversed)
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
	var $slots_rev = []
	var $slot = 1
	while $slot <= 1000 {
		$slots_rev = $slots_rev.prepend($slot)
		$slot = $slot + 1
	}
	order = rows_order_from_slots(rows_reverse_u64($slots_rev))

	rows_order_len(order) == 1000 and order.nodes.len() == 33 and order.parents.len() == 33 and order.slot_leaf.len() == 1000 and order.next_node == 34 and order.free_nodes.is_empty() and rows_order_get(order, 999)? == 1000 and rows_order_rank(order, 513)? == 512
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

	storage.slots.next_index == 3 and storage.slots.chunks.len() == 1 and storage.order.nodes.len() <= 3 and storage.order.parents.len() <= 3
}

## A 10k direct clear publishes one structural operation, retires every old
## slot generation, and leaves the reusable slot store at a fixed high-water
## mark instead of repeatedly rewriting the persistent order and key index.
expect {
	var $items = []
	var $index = 0
	while $index < 10000 {
		key = $index.to_str()
		$items = $items.prepend(rows_test_item(key, $index))
		$index = $index + 1
	}
	initial = Rows.from_list($items, rows_test_key)?
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
	rebuilt = Rows.replace_all(cleared, $items)?
	Rows(rebuilt_storage) = rebuilt
	old_slot_retired =
		match Rows.platform_item_for_slot(cleared, old_slot) {
			Err(_) => True
			Ok(_) => False
		}

	Rows(initial_storage) = initial
	bulk_shape = initial_storage.order.nodes.len() == 324 and initial_storage.order.parents.len() == 324 and initial_storage.order.slot_leaf.len() == 10000 and initial_storage.order.next_node == 325 and initial_storage.order.free_nodes.is_empty()

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
