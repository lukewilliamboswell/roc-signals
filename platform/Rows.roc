## Immutable keyed rows for dynamic UI structure. `Rows(item)` owns its key
## function, caches exact UTF-8 keys, preserves stable slot identity, and records
## an authenticated one-generation transition for the host. Applications use the
## collection operations below; the `platform_*` functions are internal adapter
## hooks for `Ui.each` and the shared engine.

RowsGenerationCallable : Box(({} -> Box({})))

RowsEntry(item) : { slot : U64, key : Str, item : item }

RowsTransition(item) : [
	ClearRows,
	InsertRows({ at : U64, entries : List(RowsEntry(item)) }),
	MoveRows({ from : U64, count : U64, to : U64 }),
	RemoveRows({ at : U64, entries : List(RowsEntry(item)) }),
	SetRow({ at : U64, before : RowsEntry(item), after : RowsEntry(item) }),
]

RowsStorage(item) : {
	token : RowsGenerationCallable,
	parent : [NoParent, Parent(RowsGenerationCallable)],
	transition : [Delta(List(RowsTransition(item))), Snapshot],
	key_of : Box((item -> Str)),
	entries : List(RowsEntry(item)),
	key_index : Dict(Str, U64),
	slot_index : Dict(U64, U64),
	next_slot : U64,
}

RowsBuild(item) : {
	entries_rev : List(RowsEntry(item)),
	key_index : Dict(Str, U64),
	slot_index : Dict(U64, U64),
	next_slot : U64,
}

RowsEditState(item) : {
	entries : List(RowsEntry(item)),
	key_index : Dict(Str, U64),
	slot_index : Dict(U64, U64),
	next_slot : U64,
	removed : Dict(Str, RowsEntry(item)),
	transitions_rev : List(RowsTransition(item)),
}

rows_generation_callable : () -> RowsGenerationCallable
rows_generation_callable = || {
	marker = Box.box({})
	identity : {} -> Box({})
	identity = |_unit| marker
	Box.box(identity)
}

rows_empty_indexes : () -> { key_index : Dict(Str, U64), slot_index : Dict(U64, U64) }
rows_empty_indexes = || {
	key_index : Dict(Str, U64)
	key_index = Dict.empty()
	slot_index : Dict(U64, U64)
	slot_index = Dict.empty()
	{ key_index, slot_index }
}

rows_reindex : List(RowsEntry(item)) -> { key_index : Dict(Str, U64), slot_index : Dict(U64, U64) }
rows_reindex = |entries| {
	indexes = rows_empty_indexes()
	var $key_index = indexes.key_index
	var $slot_index = indexes.slot_index
	var $index = 0
	while $index < entries.len() {
		entry = entries.get($index) ?? crash "Rows internal order index was invalid"
		$key_index = $key_index.insert(entry.key, $index)
		$slot_index = $slot_index.insert(entry.slot, $index)
		$index = $index + 1
	}
	{ key_index: $key_index, slot_index: $slot_index }
}

rows_allocate_slot : U64 -> Try({ slot : U64, next_slot : U64 }, Rows.Error)
rows_allocate_slot = |next_slot|
	if next_slot == 18446744073709551615 {
		Err(SlotExhausted)
	} else {
		Ok({ slot: next_slot, next_slot: next_slot + 1 })
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
				allocated = rows_allocate_slot(build.next_slot)?
				entry = { slot: allocated.slot, key, item }
				rows_build_fresh(
					items,
					key_of,
					index + 1,
					len,
					{
						entries_rev: build.entries_rev.prepend(entry),
						key_index: build.key_index.insert(key, index),
						slot_index: build.slot_index.insert(entry.slot, index),
						next_slot: allocated.next_slot,
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
				entry_and_next =
					match old.key_index.get(key) {
						Ok(old_index) => {
							old_entry = old.entries.get(old_index) ?? crash "Rows key index did not name an entry"
							{ entry: { slot: old_entry.slot, key, item }, next_slot: build.next_slot }
						}
						Err(_) => {
							allocated = rows_allocate_slot(build.next_slot)?
							{ entry: { slot: allocated.slot, key, item }, next_slot: allocated.next_slot }
						}
					}
				entry = entry_and_next.entry
				rows_build_replacement(
					items,
					key_of,
					old,
					index + 1,
					len,
					{
						entries_rev: build.entries_rev.prepend(entry),
						key_index: build.key_index.insert(key, index),
						slot_index: build.slot_index.insert(entry.slot, index),
						next_slot: entry_and_next.next_slot,
					},
				)
			}
		}
	}

rows_slice : List(a), U64, U64 -> List(a)
rows_slice = |items, at, count| items.drop_first(at).take_first(count)

rows_splice : List(a), U64, U64, List(a) -> List(a)
rows_splice = |items, at, remove_count, inserted|
	items.take_first(at).concat(inserted).concat(items.drop_first(at + remove_count))

rows_reverse : List(a) -> List(a)
rows_reverse = |items| {
	var $reversed = []
	for item in items {
		$reversed = $reversed.prepend(item)
	}
	$reversed
}

rows_state_with_entries : RowsEditState(item), List(RowsEntry(item)) -> RowsEditState(item)
rows_state_with_entries = |state, entries| {
	indexes = rows_reindex(entries)
	{ ..state, entries, key_index: indexes.key_index, slot_index: indexes.slot_index }
}

rows_remove_at : RowsEditState(item), U64, U64 -> RowsEditState(item)
rows_remove_at = |state, at, count| {
	removed_entries = rows_slice(state.entries, at, count)
	var $removed = state.removed
	for removed_entry in removed_entries {
		$removed = $removed.insert(removed_entry.key, removed_entry)
	}
	remaining = rows_splice(state.entries, at, count, [])
	next = rows_state_with_entries(state, remaining)
	{
		..next,
		removed: $removed,
		transitions_rev: next.transitions_rev.prepend(RemoveRows({ at, entries: removed_entries })),
	}
}

rows_insert_items : RowsEditState(item), Box((item -> Str)), U64, List(item), U64, U64, List(RowsEntry(item)) -> Try(RowsEditState(item), Rows.Error)
rows_insert_items = |state, key_of, at, items, item_index, item_len, entries_rev|
	if item_index == item_len {
		inserted = rows_reverse(entries_rev)
		with_entries = rows_state_with_entries(state, rows_splice(state.entries, at, 0, inserted))
		Ok({ ..with_entries, transitions_rev: with_entries.transitions_rev.prepend(InsertRows({ at, entries: inserted })) })
	} else {
		item = items.get(item_index) ?? crash "Rows inserted item length changed during construction"
		key = Box.unbox(key_of)(item)
		match state.key_index.get(key) {
			Ok(_) => Err(DuplicateKey(key))
			Err(_) => {
				entry_and_state =
					match state.removed.get(key) {
						Ok(removed_entry) => {
							{
								entry: { slot: removed_entry.slot, key, item },
								state: { ..state, removed: state.removed.remove(key) },
							}
						}
						Err(_) => {
							allocated = rows_allocate_slot(state.next_slot)?
							{
								entry: { slot: allocated.slot, key, item },
								state: { ..state, next_slot: allocated.next_slot },
							}
						}
					}
				reserved_index = at + item_index
				next_state = {
					..entry_and_state.state,
					key_index: entry_and_state.state.key_index.insert(key, reserved_index),
				}
				rows_insert_items(next_state, key_of, at, items, item_index + 1, item_len, entries_rev.prepend(entry_and_state.entry))
			}
		}
	}

rows_apply_one : RowsEditState(item), Box((item -> Str)), Rows.Edit(item) -> Try(RowsEditState(item), Rows.Error)
	where [item.is_eq : item, item -> Bool]
rows_apply_one = |state, key_of, edit|
	match edit {
		Append(items) =>
			if items.is_empty() {
				Ok(state)
			} else {
				rows_insert_items(state, key_of, state.entries.len(), items, 0, items.len(), [])
			}
		Clear =>
			if state.entries.is_empty() {
				Ok(state)
			} else {
				removed_state = rows_remove_at(state, 0, state.entries.len())
				Ok({ ..removed_state, transitions_rev: state.transitions_rev.prepend(ClearRows) })
			}
		InsertAt({ at, items }) =>
			if at > state.entries.len() {
				Err(IndexOutOfBounds({ index: at, len: state.entries.len() }))
			} else if items.is_empty() {
				Ok(state)
			} else {
				rows_insert_items(state, key_of, at, items, 0, items.len(), [])
			}
		InsertBefore({ before, items }) =>
			match state.key_index.get(before) {
				Err(_) => Err(KeyNotFound(before))
				Ok(at) =>
					if items.is_empty() {
						Ok(state)
					} else {
						rows_insert_items(state, key_of, at, items, 0, items.len(), [])
					}
				}
		MoveKeyBefore({ key, before }) =>
			match state.key_index.get(key) {
				Err(_) => Err(KeyNotFound(key))
				Ok(from) => {
					to_result : Try(U64, Rows.Error)
					to_result =
						match before {
							End => Ok(state.entries.len() - 1)
							Key(before_key) =>
								if before_key == key {
									Ok(from)
								} else {
									match state.key_index.get(before_key) {
										Err(_) => Err(KeyNotFound(before_key))
										Ok(before_index) => Ok(
											if before_index > from {
												before_index - 1
											} else {
												before_index
											},
										)
									}
								}
							}
					to = to_result?
					if from == to {
						Ok(state)
					} else {
						entry = state.entries.get(from) ?? crash "Rows move key index did not name an entry"
						without = rows_splice(state.entries, from, 1, [])
						moved = rows_splice(without, to, 0, [entry])
						next = rows_state_with_entries(state, moved)
						Ok({ ..next, transitions_rev: next.transitions_rev.prepend(MoveRows({ from, count: 1, to })) })
					}
				}
			}
		MoveRange({ from, count, to }) => {
			len = state.entries.len()
			if from > len or count > len - from {
				Err(RangeOutOfBounds({ at: from, count, len }))
			} else if to > len - count {
				Err(IndexOutOfBounds({ index: to, len: len - count }))
			} else if count == 0 or from == to {
				Ok(state)
			} else {
				moving = rows_slice(state.entries, from, count)
				without = rows_splice(state.entries, from, count, [])
				moved = rows_splice(without, to, 0, moving)
				next = rows_state_with_entries(state, moved)
				Ok({ ..next, transitions_rev: next.transitions_rev.prepend(MoveRows({ from, count, to })) })
			}
		}
		RemoveKey(key) =>
			match state.key_index.get(key) {
				Err(_) => Err(KeyNotFound(key))
				Ok(at) => Ok(rows_remove_at(state, at, 1))
			}
		RemoveRange({ at, count }) => {
			len = state.entries.len()
			if at > len or count > len - at {
				Err(RangeOutOfBounds({ at, count, len }))
			} else if count == 0 {
				Ok(state)
			} else {
				Ok(rows_remove_at(state, at, count))
			}
		}
		SetAt({ at, item }) => {
			len = state.entries.len()
			if at >= len {
				Err(IndexOutOfBounds({ index: at, len }))
			} else {
				before_entry = state.entries.get(at) ?? crash "Rows set index did not name an entry"
				new_key = Box.unbox(key_of)(item)
				if new_key == before_entry.key {
					if before_entry.item.is_eq(item) {
						Ok(state)
					} else {
						after_entry = { ..before_entry, item }
						next = rows_state_with_entries(state, state.entries.set(at, after_entry) ?? crash "Rows set index became invalid")
						Ok({ ..next, transitions_rev: next.transitions_rev.prepend(SetRow({ at, before: before_entry, after: after_entry })) })
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
				Ok(at) => rows_apply_one(state, key_of, SetAt({ at, item }))
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

rows_find_slot_from : List(RowsEntry(item)), U64, U64 -> [Found(U64), NotFound]
rows_find_slot_from = |entries, slot, from| {
	var $index = from
	var $result = NotFound
	while $result == NotFound and $index < entries.len() {
		entry = entries.get($index) ?? crash "Rows slot search index was invalid"
		if entry.slot == slot {
			$result = Found($index)
		}
		$index = $index + 1
	}
	$result
}

rows_normalize_delta_from : List(RowsEntry(item)), List(RowsEntry(item)), U64, List(RowsTransition(item)) -> List(RowsTransition(item))
	where [item.is_eq : item, item -> Bool]
rows_normalize_delta_from = |working, target, index, transitions_rev|
	if index == target.len() {
		remaining = working.len() - index
		if remaining == 0 {
			rows_reverse(transitions_rev)
		} else if index == 0 {
			rows_reverse(transitions_rev.prepend(ClearRows))
		} else {
			removed = rows_slice(working, index, remaining)
			rows_reverse(transitions_rev.prepend(RemoveRows({ at: index, entries: removed })))
		}
	} else {
		target_entry = target.get(index) ?? crash "Rows normalized target index was invalid"
		match rows_find_slot_from(working, target_entry.slot, index) {
			NotFound => {
				next_working = rows_splice(working, index, 0, [target_entry])
				next_transitions = transitions_rev.prepend(InsertRows({ at: index, entries: [target_entry] }))
				rows_normalize_delta_from(next_working, target, index + 1, next_transitions)
			}
			Found(found_at) => {
				moved =
					if found_at == index {
						working
					} else {
						entry = working.get(found_at) ?? crash "Rows normalized move index was invalid"
						rows_splice(rows_splice(working, found_at, 1, []), index, 0, [entry])
					}
				moved_transitions =
					if found_at == index {
						transitions_rev
					} else {
						transitions_rev.prepend(MoveRows({ from: found_at, count: 1, to: index }))
					}
				before_entry = moved.get(index) ?? crash "Rows normalized set index was invalid"
				if before_entry.key == target_entry.key and before_entry.item.is_eq(target_entry.item) {
					rows_normalize_delta_from(moved, target, index + 1, moved_transitions)
				} else {
					next_working = moved.set(index, target_entry) ?? crash "Rows normalized set index became invalid"
					next_transitions = moved_transitions.prepend(SetRow({ at: index, before: before_entry, after: target_entry }))
					rows_normalize_delta_from(next_working, target, index + 1, next_transitions)
				}
			}
		}
	}

rows_normalize_delta : List(RowsEntry(item)), List(RowsEntry(item)) -> List(RowsTransition(item))
	where [item.is_eq : item, item -> Bool]
rows_normalize_delta = |old_entries, new_entries| rows_normalize_delta_from(old_entries, new_entries, 0, [])

Rows(item) := [Rows(RowsStorage(item))].{

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
	Delta(item) : RowsTransition(item)

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
			entries: [],
			key_index: indexes.key_index,
			slot_index: indexes.slot_index,
			next_slot: 1,
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
			{ entries_rev: [], key_index: indexes.key_index, slot_index: indexes.slot_index, next_slot: 1 },
		)?
		Ok(
			Rows({
				token: rows_generation_callable(),
				parent: NoParent,
				transition: Snapshot,
				key_of: key_of_box,
				entries: rows_reverse(built.entries_rev),
				key_index: built.key_index,
				slot_index: built.slot_index,
				next_slot: built.next_slot,
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
			{ entries_rev: [], key_index: indexes.key_index, slot_index: indexes.slot_index, next_slot: old.next_slot },
		)?
		Ok(
			Rows({
				token: rows_generation_callable(),
				parent: Parent(old.token),
				transition: Snapshot,
				key_of: old.key_of,
				entries: rows_reverse(built.entries_rev),
				key_index: built.key_index,
				slot_index: built.slot_index,
				next_slot: built.next_slot,
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
		removed : Dict(Str, RowsEntry(item))
		removed = Dict.empty()
		state = {
			entries: old.entries,
			key_index: old.key_index,
			slot_index: old.slot_index,
			next_slot: old.next_slot,
			removed,
			transitions_rev: [],
		}
		applied = rows_apply_many(state, old.key_of, edits, 0, edits.len())?
		normalized = rows_normalize_delta(old.entries, applied.entries)
		if normalized.is_empty() {
			Ok(rows)
		} else {
			Ok(
				Rows({
					token: rows_generation_callable(),
					parent: Parent(old.token),
					transition: Delta(normalized),
					key_of: old.key_of,
					entries: applied.entries,
					key_index: applied.key_index,
					slot_index: applied.slot_index,
					next_slot: applied.next_slot,
				}),
			)
		}
	}

	## Number of live rows.
	len : Rows(item) -> U64
	len = |Rows(storage)| storage.entries.len()

	## Read by order index.
	get : Rows(item), U64 -> Try(item, Error)
	get = |Rows(storage), index|
		match storage.entries.get(index) {
			Ok(entry) => Ok(entry.item)
			Err(_) => Err(IndexOutOfBounds({ index, len: storage.entries.len() }))
		}

	## Read by exact UTF-8 key.
	get_key : Rows(item), Str -> Try(item, Error)
	get_key = |Rows(storage), key|
		match storage.key_index.get(key) {
			Err(_) => Err(KeyNotFound(key))
			Ok(index) =>
				match storage.entries.get(index) {
					Ok(entry) => Ok(entry.item)
					Err(_) => crash "Rows key index did not name an entry"
				}
			}

	## Iterate items in row order.
	iter : Rows(item) -> Iter(item)
	iter = |Rows(storage)| storage.entries.map(|entry| entry.item).iter()

	## Materialize items in row order.
	to_list : Rows(item) -> List(item)
	to_list = |Rows(storage)| storage.entries.map(|entry| entry.item)

	## O(1) generation equality used by ordinary signal pruning. The hosted hook
	## compares raw boxed callable identity and never invokes the callable.
	is_eq : Rows(item), Rows(item) -> Bool
	is_eq = |Rows(left), Rows(right)| Rows.same_generation_callable!(left.token, right.token)

	## Explicit structural equality for callers that genuinely need it.
	content_is_eq : Rows(item), Rows(item) -> Bool
		where [item.is_eq : item, item -> Bool]
	content_is_eq = |Rows(left), Rows(right)| {
		if left.entries.len() != right.entries.len() {
			False
		} else {
			var $equal = True
			var $index = 0
			while $equal and $index < left.entries.len() {
				left_entry = left.entries.get($index) ?? crash "Rows left content index was invalid"
				right_entry = right.entries.get($index) ?? crash "Rows right content index was invalid"
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

	## Platform-private stable slot lookup by order index.
	platform_slot_at : Rows(item), U64 -> Try(U64, Error)
	platform_slot_at = |Rows(storage), index|
		match storage.entries.get(index) {
			Ok(entry) => Ok(entry.slot)
			Err(_) => Err(IndexOutOfBounds({ index, len: storage.entries.len() }))
		}

	## Platform-private cached-key lookup by order index.
	platform_key_at : Rows(item), U64 -> Try(Str, Error)
	platform_key_at = |Rows(storage), index|
		match storage.entries.get(index) {
			Ok(entry) => Ok(entry.key)
			Err(_) => Err(IndexOutOfBounds({ index, len: storage.entries.len() }))
		}

	## Platform-private typed item lookup by order index.
	platform_item_at : Rows(item), U64 -> Try(item, Error)
	platform_item_at = |rows, index| Rows.get(rows, index)

	## Platform-private typed item lookup by stable slot.
	platform_item_for_slot : Rows(item), U64 -> Try(item, [SlotNotFound(U64)])
	platform_item_for_slot = |Rows(storage), slot|
		match storage.slot_index.get(slot) {
			Err(_) => Err(SlotNotFound(slot))
			Ok(index) =>
				match storage.entries.get(index) {
					Ok(entry) => Ok(entry.item)
					Err(_) => crash "Rows slot index did not name an entry"
				}
			}

	## Platform-private allocation-free snapshot fold. The callback receives the
	## order index plus stable slot, cached key, and typed item.
	platform_copy_snapshot : Rows(item), state, (state, U64, U64, Str, item -> state) -> state
	platform_copy_snapshot = |Rows(storage), initial, push| {
		var $state = initial
		var $index = 0
		while $index < storage.entries.len() {
			entry = storage.entries.get($index) ?? crash "Rows snapshot index was invalid"
			$state = push($state, $index, entry.slot, entry.key, entry.item)
			$index = $index + 1
		}
		$state
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
