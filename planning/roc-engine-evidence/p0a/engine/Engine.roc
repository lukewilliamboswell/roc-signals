## Phase 0a storage probe: a pure Roc reactive engine core with typed per-site
## column storage. No effects. The application's site set is a nested generic
## type (`Both(a, b)` of `EachSite(item, msg)` leaves), so every site's rows are
## stored with their concrete type and site dispatch resolves at compile time.
## Nothing is erased per row or per site.
##
## Ownership discipline: every update destructures the consumed record and
## rebuilds it from its fields. Never write `{ ..r, f: g(r.f) }`; reading a field
## of a record that stays alive shares the field and forces a copy on write.
##
## Command stream (little endian), appended to one List(U8):
##   1 CREATE  node:u32 parent:u32 key:u64 class:u8 len:u32 text  (append to parent)
##   2 TEXT    node:u32 len:u32 text
##   3 CLASS   node:u32 class:u8
##   4 MOVE    node:u32 before:u32                               (move node before `before`)
##   5 REMOVE  node:u32
##   6 CLEAR   parent:u32                                        (remove all children)
## Node ids: (site_id << 24) | (slot + 1) for rows; (site_id << 24) for a
## site's count text node; `summary_node` for the cross-site summary.
Engine := [].{
	op_create : U8
	op_create = 1

	op_text : U8
	op_text = 2

	op_class : U8
	op_class = 3

	op_move : U8
	op_move = 4

	op_remove : U8
	op_remove = 5

	op_clear : U8
	op_clear = 6

	summary_node : U32
	summary_node = 16777215

	put_u32 : List(U8), U32 -> List(U8)
	put_u32 = |buf, v| buf.append(v.to_u8_wrap()).append(v.shr_zf_wrap(8).to_u8_wrap()).append(v.shr_zf_wrap(16).to_u8_wrap()).append(v.shr_zf_wrap(24).to_u8_wrap())

	put_u64 : List(U8), U64 -> List(U8)
	put_u64 = |buf, v| Engine.put_u32(Engine.put_u32(buf, v.to_u32_wrap()), v.shr_zf_wrap(32).to_u32_wrap())

	put_str : List(U8), Str -> List(U8)
	put_str = |buf, s| {
		var $b = Engine.put_u32(buf, s.count_utf8_bytes().to_u32_wrap())
		for byte in s.iter_utf8() {
			$b = $b.append(byte)
		}
		$b
	}

	## One logical trace event, recorded only when tracing is on.
	## rank 0 = source write, 1 = row derivation, 2 = site count, 3 = summary.
	Ev : { rank : U8, site : U32, key : U64, kind : [Eval, Prune, SourcePrune] }

	## Per-transaction context threaded through every edit and settle step.
	Ctx : { cmds : List(U8), log : List(Ev), tracing : Bool, evals : U64, prunes : U64, dirty3 : Bool }

	new_ctx : Bool -> Ctx
	new_ctx = |tracing| { cmds: [], log: [], tracing, evals: 0, prunes: 0, dirty3: False }

	## Record a derived evaluation (counted always, logged when tracing).
	note_eval : Ctx, U8, U32, U64 -> Ctx
	note_eval = |{ cmds, log, tracing, evals, prunes, dirty3 }, rank, site, key| {
		if tracing {
			{ cmds, log: log.append({ rank, site, key, kind: Eval }), tracing, evals: evals + 1, prunes, dirty3 }
		} else {
			{ cmds, log, tracing, evals: evals + 1, prunes, dirty3 }
		}
	}

	note_prune : Ctx, U8, U32, U64 -> Ctx
	note_prune = |{ cmds, log, tracing, evals, prunes, dirty3 }, rank, site, key| {
		if tracing {
			kind = if rank == 0 SourcePrune else Prune
			{ cmds, log: log.append({ rank, site, key, kind }), tracing, evals, prunes: prunes + 1, dirty3 }
		} else {
			{ cmds, log, tracing, evals, prunes: prunes + 1, dirty3 }
		}
	}

	emit : Ctx, (List(U8) -> List(U8)) -> Ctx
	emit = |{ cmds, log, tracing, evals, prunes, dirty3 }, write| { cmds: write(cmds), log, tracing, evals, prunes, dirty3 }

	## Mark (or clear) the rank-3 summary dirty.
	set_dirty3 : Ctx, Bool -> Ctx
	set_dirty3 = |{ cmds, log, tracing, evals, prunes, dirty3: _ }, flag| { cmds, log, tracing, evals, prunes, dirty3: flag }

	## ------------------------------------------------------------------
	## Open-addressing U64 -> slot index (linear probing, backward-shift delete).
	## vals hold slot + 1; 0 marks an empty bucket. Load factor <= 1/2.
	KeyIndex : { keys : List(U64), vals : List(U32), count : U64, bits : U8 }

	index_empty : KeyIndex
	index_empty = { keys: [], vals: [], count: 0, bits: 0 }

	bucket : U64, U8 -> U64
	bucket = |key, bits| key.times_wrap(11400714819323198485).shr_zf_wrap(64 - bits)

	index_get : KeyIndex, U64 -> Try(U32, [Missing])
	index_get = |index, key| {
		if index.count == 0 {
			return Err(Missing)
		}
		mask = (1.U64.shl_wrap(index.bits)) - 1
		var $b = Engine.bucket(key, index.bits)
		while True {
			v = index.vals.get($b) ?? 0
			if v == 0 {
				return Err(Missing)
			}
			if (index.keys.get($b) ?? 0) == key {
				return Ok(v - 1)
			}
			$b = ($b + 1).bitwise_and(mask)
		}
	}

	## Insert into a table known to have room and not to contain the key.
	raw_insert : List(U64), List(U32), U8, U64, U32 -> { keys : List(U64), vals : List(U32) }
	raw_insert = |keys, vals, bits, key, slot| {
		mask = (1.U64.shl_wrap(bits)) - 1
		var $b = Engine.bucket(key, bits)
		while (vals.get($b) ?? 0) != 0 {
			$b = ($b + 1).bitwise_and(mask)
		}
		{ keys: keys.set($b, key) ?? crash "index bucket", vals: vals.set($b, slot + 1) ?? crash "index bucket" }
	}

	grow : KeyIndex -> KeyIndex
	grow = |{ keys, vals, count, bits }| {
		new_bits = if bits == 0 4 else bits + 1
		size = 1.U64.shl_wrap(new_bits)
		var $k = List.repeat(0.U64, size)
		var $v = List.repeat(0.U32, size)
		var $i = 0.U64
		while $i < vals.len() {
			v = vals.get($i) ?? 0
			if v != 0 {
				r = Engine.raw_insert($k, $v, new_bits, keys.get($i) ?? 0, v - 1)
				$k = r.keys
				$v = r.vals
			}
			$i = $i + 1
		}
		{ keys: $k, vals: $v, count, bits: new_bits }
	}

	## Insert a fresh key. A duplicate key is a contract error, never an alias.
	index_insert : KeyIndex, U64, U32 -> KeyIndex
	index_insert = |index, key, slot| {
		when_ok = match Engine.index_get(index, key) {
			Ok(_) => crash "duplicate key"
			Err(Missing) => {}
		}
		_ = when_ok
		grown = if (index.count + 1) * 2 > 1.U64.shl_wrap(index.bits) Engine.grow(index) else index
		{ keys, vals, count, bits } = grown
		r = Engine.raw_insert(keys, vals, bits, key, slot)
		{ keys: r.keys, vals: r.vals, count: count + 1, bits }
	}

	index_remove : KeyIndex, U64 -> KeyIndex
	index_remove = |{ keys, vals, count, bits }, key| {
		if count == 0 {
			crash "remove of missing key"
		}
		mask = (1.U64.shl_wrap(bits)) - 1
		var $b = Engine.bucket(key, bits)
		while (keys.get($b) ?? 0) != key or (vals.get($b) ?? 0) == 0 {
			if (vals.get($b) ?? 0) == 0 {
				crash "remove of missing key"
			}
			$b = ($b + 1).bitwise_and(mask)
		}
		# Backward-shift deletion keeps probe chains contiguous.
		var $k = keys
		var $v = vals
		var $hole = $b
		var $j = ($b + 1).bitwise_and(mask)
		while ($v.get($j) ?? 0) != 0 {
			jk = $k.get($j) ?? 0
			home = Engine.bucket(jk, bits)
			# Move j into the hole if its home is not cyclically in (hole, j].
			dist_home = ($j + mask + 1 - home).bitwise_and(mask)
			dist_hole = ($j + mask + 1 - $hole).bitwise_and(mask)
			if dist_home >= dist_hole {
				$k = $k.set($hole, jk) ?? crash "index"
				$v = $v.set($hole, $v.get($j) ?? 0) ?? crash "index"
				$hole = $j
			}
			$j = ($j + 1).bitwise_and(mask)
		}
		$v = $v.set($hole, 0) ?? crash "index"
		{ keys: $k, vals: $v, count: count - 1, bits }
	}

	## ------------------------------------------------------------------
	## One keyed `each` site, stored as typed columns.

	## Built once per site; handlers receive the row key when they fire.
	RowDesc(item, msg) : {
		key : item -> U64,
		label : item -> Str,
		class : item, Bool -> U8,
		on_select : U64 -> msg,
		on_remove : U64 -> msg,
	}

	## dirty bits: 1 = item changed, 2 = selection changed.
	Live(item) : { item : item, key : U64, text : Str, cls : U8, dirty : U8 }

	Slot(item) : [Live(Live(item)), Free]

	EachSite(item, msg) := {
		id : U32,
		parent : U32,
		desc : RowDesc(item, msg),
		slots : List(Slot(item)),
		order : List(U32),
		free : List(U32),
		index : KeyIndex,
		sel_key : U64,
		has_sel : Bool,
		dirty : List(U32),
		count : U64,
		count_dirty : Bool,
	}.{
		new : U32, U32, RowDesc(item, msg) -> EachSite(item, msg)
		new = |id, parent, desc| EachSite.{
			id,
			parent,
			desc,
			slots: [],
			order: [],
			free: [],
			index: Engine.index_empty,
			sel_key: 0,
			has_sel: False,
			dirty: [],
			count: 0,
			count_dirty: False,
		}

		node_of : EachSite(item, msg), U32 -> U32
		node_of = |site, slot| site.id.shl_wrap(24) + slot + 1

		len : EachSite(item, msg) -> U64
		len = |site| site.order.len()

		key_at : EachSite(item, msg), U64 -> Try(U64, [OutOfBounds])
		key_at = |site, pos| {
			slot = site.order.get(pos)?
			match site.slots.get(slot.to_u64()) {
				Ok(Live(r)) => Ok(r.key)
				_ => crash "order references a free slot"
			}
		}

		get : EachSite(item, msg), U64 -> Try(item, [Missing])
		get = |site, key| {
			slot = Engine.index_get(site.index, key)?
			match site.slots.get(slot.to_u64()) {
				Ok(Live(r)) => Ok(r.item)
				_ => crash "index references a free slot"
			}
		}

		## Append a new row. Evaluates its row derivations once and emits CREATE.
		push : EachSite(item, msg), item, Ctx -> (EachSite(item, msg), Ctx)
			where [item.is_eq : item, item -> Bool]
		push = |site, item, ctx0| {
			{ id, parent, desc, slots, order, free, index, sel_key, has_sel, dirty, count, count_dirty: _ } = site
			key = (desc.key)(item)
			taken = match free.last() {
				Ok(s) => { slot: s, free: free.drop_last(1) }
				Err(_) => { slot: slots.len().to_u32_wrap(), free }
			}
			slot = taken.slot
			new_index = Engine.index_insert(index, key, slot)
			text = (desc.label)(item)
			ctx1 = Engine.note_eval(ctx0, 1, id, key)
			cls = (desc.class)(item, has_sel and sel_key == key)
			ctx2 = Engine.note_eval(ctx1, 1, id, key)
			node = id.shl_wrap(24) + slot + 1
			ctx3 = Engine.emit(ctx2, |b| Engine.put_str(Engine.put_u64(Engine.put_u32(Engine.put_u32(b.append(Engine.op_create), node), parent), key).append(cls), text))
			row = Live({ item, key, text, cls, dirty: 0 })
			new_slots = if slot.to_u64() == slots.len() slots.append(row) else (slots.set(slot.to_u64(), row) ?? crash "slot")
			(
				EachSite.{ id, parent, desc, slots: new_slots, order: order.append(slot), free: taken.free, index: new_index, sel_key, has_sel, dirty, count, count_dirty: True },
				ctx3,
			)
		}

		## Write a row's source item. An equal write is pruned at the source.
		set : EachSite(item, msg), U64, item, Ctx -> (EachSite(item, msg), Ctx)
			where [item.is_eq : item, item -> Bool]
		set = |site, key, item, ctx| {
			{ id, parent, desc, slots, order, free, index, sel_key, has_sel, dirty, count, count_dirty } = site
			if (desc.key)(item) != key {
				crash "a row write may not change its key"
			}
			slot = Engine.index_get(index, key) ?? crash "write to unknown key"
			{ list: taken_list, prev: taken_prev } = slots.replace(slot.to_u64(), Free) ?? crash "slot"
			match taken_prev {
				Live({ item: old, key: k, text, cls, dirty: bits }) => {
					if old == item {
						restored = taken_list.set(slot.to_u64(), Live({ item: old, key: k, text, cls, dirty: bits })) ?? crash "slot"
						(EachSite.{ id, parent, desc, slots: restored, order, free, index, sel_key, has_sel, dirty, count, count_dirty }, Engine.note_prune(ctx, 0, id, key))
					} else {
						new_dirty = if bits == 0 dirty.append(slot) else dirty
						next = taken_list.set(slot.to_u64(), Live({ item, key: k, text, cls, dirty: bits.bitwise_or(1) })) ?? crash "slot"
						(EachSite.{ id, parent, desc, slots: next, order, free, index, sel_key, has_sel, dirty: new_dirty, count, count_dirty }, ctx)
					}
				}
				Free => crash "index references a free slot"
			}
		}

		## Mark one live row's selection bit dirty (deduplicated).
		mark_sel : List(Slot(item)), List(U32), U32 -> { slots : List(Slot(item)), dirty : List(U32) }
		mark_sel = |slots, dirty, slot| {
			{ list: taken_list, prev: taken_prev } = slots.replace(slot.to_u64(), Free) ?? crash "slot"
			match taken_prev {
				Live({ item, key, text, cls, dirty: bits }) => {
					new_dirty = if bits == 0 dirty.append(slot) else dirty
					{ slots: taken_list.set(slot.to_u64(), Live({ item, key, text, cls, dirty: bits.bitwise_or(2) })) ?? crash "slot", dirty: new_dirty }
				}
				Free => crash "index references a free slot"
			}
		}

		## Keyed selector source: only the previous and next selected rows go dirty.
		select : EachSite(item, msg), Try(U64, [None]), Ctx -> (EachSite(item, msg), Ctx)
		select = |site, next_sel, ctx| {
			{ id, parent, desc, slots, order, free, index, sel_key, has_sel, dirty, count, count_dirty } = site
			same = match next_sel {
				Ok(k) => has_sel and k == sel_key
				Err(None) => !has_sel
			}
			if same {
				(EachSite.{ id, parent, desc, slots, order, free, index, sel_key, has_sel, dirty, count, count_dirty }, Engine.note_prune(ctx, 0, id, sel_key))
			} else {
				var $slots = slots
				var $dirty = dirty
				if has_sel {
					match Engine.index_get(index, sel_key) {
						Ok(s) => {
							r = EachSite.mark_sel($slots, $dirty, s)
							$slots = r.slots
							$dirty = r.dirty
						}
						Err(Missing) => {}
					}
				}
				new_key = match next_sel {
					Ok(k) => {
						match Engine.index_get(index, k) {
							Ok(s) => {
								r = EachSite.mark_sel($slots, $dirty, s)
								$slots = r.slots
								$dirty = r.dirty
							}
							Err(Missing) => {}
						}
						k
					}
					Err(None) => 0
				}
				new_has = match next_sel {
					Ok(_) => True
					Err(None) => False
				}
				(EachSite.{ id, parent, desc, slots: $slots, order, free, index, sel_key: new_key, has_sel: new_has, dirty: $dirty, count, count_dirty }, ctx)
			}
		}

		## Swap the rows at two display positions; emits two MOVEs.
		swap_positions : EachSite(item, msg), U64, U64, Ctx -> (EachSite(item, msg), Ctx)
		swap_positions = |site, p0, p1, ctx| {
			{ id, parent, desc, slots, order, free, index, sel_key, has_sel, dirty, count, count_dirty } = site
			i = if p0 < p1 p0 else p1
			j = if p0 < p1 p1 else p0
			if i == j or j >= order.len() {
				(EachSite.{ id, parent, desc, slots, order, free, index, sel_key, has_sel, dirty, count, count_dirty }, ctx)
			} else {
				a = order.get(i) ?? crash "order"
				b = order.get(j) ?? crash "order"
				na = id.shl_wrap(24) + a + 1
				nb = id.shl_wrap(24) + b + 1
				after = match order.get(j + 1) {
					Ok(s) => id.shl_wrap(24) + s + 1
					Err(_) => 0
				}
				# DOM: move B before A, then A before B's old successor.
				ctx1 = Engine.emit(ctx, |buf| Engine.put_u32(Engine.put_u32(buf.append(Engine.op_move), nb), na))
				ctx2 = Engine.emit(ctx1, |buf| Engine.put_u32(Engine.put_u32(buf.append(Engine.op_move), na), after))
				new_order = order.swap(i, j) ?? crash "order"
				(EachSite.{ id, parent, desc, slots, order: new_order, free, index, sel_key, has_sel, dirty, count, count_dirty }, ctx2)
			}
		}

		## Remove one row by key. Releases its slot, index entry and DOM node.
		## Finding its display position is a linear scan of `order` (as in Solid's
		## array splice); everything else is O(1).
		remove : EachSite(item, msg), U64, Ctx -> (EachSite(item, msg), Ctx)
		remove = |site, key, ctx| {
			{ id, parent, desc, slots, order, free, index, sel_key, has_sel, dirty, count, count_dirty: _ } = site
			slot = Engine.index_get(index, key) ?? crash "remove of unknown key"
			pos = order.find_first_index(|s| s == slot) ?? crash "slot missing from order"
			{ list: taken_list, prev: _taken_prev } = slots.replace(slot.to_u64(), Free) ?? crash "slot"
			node = id.shl_wrap(24) + slot + 1
			ctx1 = Engine.emit(ctx, |buf| Engine.put_u32(buf.append(Engine.op_remove), node))
			(
				EachSite.{ id, parent, desc, slots: taken_list, order: order.drop_at(pos), free: free.append(slot), index: Engine.index_remove(index, key), sel_key, has_sel, dirty, count, count_dirty: True },
				ctx1,
			)
		}

		## Remove every row: one CLEAR command; all row storage is released.
		clear : EachSite(item, msg), Ctx -> (EachSite(item, msg), Ctx)
		clear = |site, ctx| {
			{ id, parent, desc, slots: _, order: _, free: _, index: _, sel_key, has_sel, dirty: _, count, count_dirty: _ } = site
			ctx1 = Engine.emit(ctx, |buf| Engine.put_u32(buf.append(Engine.op_clear), parent))
			(
				EachSite.{ id, parent, desc, slots: [], order: [], free: [], index: Engine.index_empty, sel_key, has_sel, dirty: [], count, count_dirty: True },
				ctx1,
			)
		}

		## Run one rank of this site's pending derivations.
		## Rank 1: per-row label and class for dirty rows. Rank 2: the count text.
		settle : EachSite(item, msg), U8, Ctx -> (EachSite(item, msg), Ctx)
		settle = |site, rank, ctx| {
			{ id, parent, desc, slots, order, free, index, sel_key, has_sel, dirty, count, count_dirty } = site
			if rank == 1 {
				var $slots = slots
				var $ctx = ctx
				for slot in dirty {
					{ list: taken_list, prev: taken_prev } = $slots.replace(slot.to_u64(), Free) ?? crash "slot"
					match taken_prev {
						Live({ item, key, text, cls, dirty: bits }) => {
							if bits == 0 {
								$slots = taken_list.set(slot.to_u64(), Live({ item, key, text, cls, dirty: bits })) ?? crash "slot"
							} else {
								node = id.shl_wrap(24) + slot + 1
								new_text = if bits.bitwise_and(1) != 0 {
									t = (desc.label)(item)
									$ctx = Engine.note_eval($ctx, 1, id, key)
									if t == text {
										$ctx = Engine.note_prune($ctx, 1, id, key)
										text
									} else {
										$ctx = Engine.emit($ctx, |buf| Engine.put_str(Engine.put_u32(buf.append(Engine.op_text), node), t))
										t
									}
								} else {
									text
								}
								c = (desc.class)(item, has_sel and sel_key == key)
								$ctx = Engine.note_eval($ctx, 1, id, key)
								new_cls = if c == cls {
									$ctx = Engine.note_prune($ctx, 1, id, key)
									cls
								} else {
									$ctx = Engine.emit($ctx, |buf| Engine.put_u32(buf.append(Engine.op_class), node).append(c))
									c
								}
								$slots = taken_list.set(slot.to_u64(), Live({ item, key, text: new_text, cls: new_cls, dirty: 0 })) ?? crash "slot"
							}
						}
						Free => {
							# Removed after being marked; nothing to render.
							$slots = taken_list
						}
					}
				}
				(EachSite.{ id, parent, desc, slots: $slots, order, free, index, sel_key, has_sel, dirty: dirty.clear(), count, count_dirty }, $ctx)
			} else if rank == 2 and count_dirty {
				n = order.len()
				ctx1 = Engine.note_eval(ctx, 2, id, 0)
				if n == count {
					(EachSite.{ id, parent, desc, slots, order, free, index, sel_key, has_sel, dirty, count, count_dirty: False }, Engine.note_prune(ctx1, 2, id, 0))
				} else {
					header = id.shl_wrap(24)
					ctx2 = Engine.set_dirty3(Engine.emit(ctx1, |buf| Engine.put_str(Engine.put_u32(buf.append(Engine.op_text), header), n.to_str())), True)
					(EachSite.{ id, parent, desc, slots, order, free, index, sel_key, has_sel, dirty, count: n, count_dirty: False }, ctx2)
				}
			} else {
				(EachSite.{ id, parent, desc, slots, order, free, index, sel_key, has_sel, dirty, count, count_dirty }, ctx)
			}
		}

		## Resolve a DOM event to the application message. The row key is read
		## from the slot when the event fires, not captured when the row was built.
		fire : EachSite(item, msg), U32, U32, U8 -> Try(msg, [Stale, NotHere])
		fire = |site, site_id, slot, handler| {
			if site_id != site.id {
				Err(NotHere)
			} else {
				match site.slots.get(slot.to_u64()) {
					Ok(Live(r)) => if handler == 1 Ok((site.desc.on_select)(r.key)) else Ok((site.desc.on_remove)(r.key))
					_ => Err(Stale)
				}
			}
		}

		total : EachSite(item, msg) -> U64
		total = |site| site.count
	}

	## Static composition of two sites (or nested compositions).
	Both(a, b) := { left : a, right : b }.{
		new : a, b -> Both(a, b)
		new = |left, right| Both.{ left, right }

		## Consume the composition, handing both parts back uniquely owned.
		split : Both(a, b) -> { left : a, right : b }
		split = |both| {
			{ left, right } = both
			{ left, right }
		}

		settle : Both(a, b), U8, Ctx -> (Both(a, b), Ctx)
			where [a.settle : a, U8, Ctx -> (a, Ctx), b.settle : b, U8, Ctx -> (b, Ctx)]
		settle = |both, rank, ctx| {
			{ left, right } = both
			(l, c1) = left.settle(rank, ctx)
			(r, c2) = right.settle(rank, c1)
			(Both.{ left: l, right: r }, c2)
		}

		fire : Both(a, b), U32, U32, U8 -> Try(msg, [Stale, NotHere])
			where [a.fire : a, U32, U32, U8 -> Try(msg, [Stale, NotHere]), b.fire : b, U32, U32, U8 -> Try(msg, [Stale, NotHere])]
		fire = |both, site_id, slot, handler| {
			match both.left.fire(site_id, slot, handler) {
				Err(NotHere) => both.right.fire(site_id, slot, handler)
				other => other
			}
		}

		total : Both(a, b) -> U64
			where [a.total : a -> U64, b.total : b -> U64]
		total = |both| both.left.total() + both.right.total()
	}

	## ------------------------------------------------------------------
	## The engine: application model + typed sites + cross-site summary.

	Tx(model, sites) : { model : model, sites : sites, ctx : Ctx }

	Input(msg) : [Msg(msg), Fire(U32, U8)]

	## Rank-3 summary node: evaluated only when a site count changed this
	## transaction; an equal result is pruned.
	summarize : Ctx, U64, U64 -> { summary : U64, ctx : Ctx }
	summarize = |ctx, summary, total| {
		if !ctx.dirty3 {
			{ summary, ctx }
		} else {
			c3 = Engine.note_eval(Engine.set_dirty3(ctx, False), 3, 0, 0)
			if total == summary {
				{ summary, ctx: Engine.note_prune(c3, 3, 0, 0) }
			} else {
				{ summary: total, ctx: Engine.emit(c3, |buf| Engine.put_str(Engine.put_u32(buf.append(Engine.op_text), Engine.summary_node), total.to_str())) }
			}
		}
	}

	## Resolve an input to the application message; a DOM event reads the row
	## key from the site's slot at fire time.
	resolve : sites, Input(msg) -> Try(msg, [Stale])
		where [sites.fire : sites, U32, U32, U8 -> Try(msg, [Stale, NotHere])]
	resolve = |sites, input| match input {
		Msg(m) => Ok(m)
		Fire(node, handler) => {
			site_id = node.shr_zf_wrap(24)
			slot_plus = node - site_id.shl_wrap(24)
			if slot_plus == 0 {
				Err(Stale)
			} else {
				match sites.fire(site_id, slot_plus - 1, handler) {
					Ok(m) => Ok(m)
					Err(_) => Err(Stale)
				}
			}
		}
	}

	State(model, sites, msg) := {
		model : model,
		sites : sites,
		summary : U64,
		ctx : Ctx,
		stale : U64,
	}.{
		init : model, sites, Bool -> State(model, sites, msg)
		init = |model, sites, tracing| State.{ model, sites, summary: 0, ctx: Engine.new_ctx(tracing), stale: 0 }

		## Apply one input as one transaction: run the application's reducer
		## (source writes and structure), then settle ranks 1, 2 and 3 in order.
		## The command stream of this transaction is left in `ctx.cmds`.
		apply : State(model, sites, msg), Input(msg), (Tx(model, sites), msg -> Tx(model, sites)) -> State(model, sites, msg)
			where [
				sites.settle : sites, U8, Ctx -> (sites, Ctx),
				sites.fire : sites, U32, U32, U8 -> Try(msg, [Stale, NotHere]),
				sites.total : sites -> U64,
			]
		apply = |state, input, update| {
			{ model, sites, summary, ctx, stale } = state
			{ cmds, log, tracing, evals: _, prunes: _, dirty3: _ } = ctx
			fresh = { cmds: cmds.clear(), log: log.clear(), tracing, evals: 0, prunes: 0, dirty3: False }
			msg_or = Engine.resolve(sites, input)
			# Consume the sites exactly once on every path: a value consumed in one
			# match branch and kept in another was copied (see report).
			new_stale = match msg_or {
				Ok(_) => stale
				Err(_) => stale + 1
			}
			tx0 = { model, sites, ctx: fresh }
			tx = match msg_or {
				Ok(msg) => update(tx0, msg)
				Err(_) => tx0
			}
			{ model: m2, sites: s0, ctx: c0 } = tx
			(s1, c1) = s0.settle(1, c0)
			(s2, c2) = s1.settle(2, c1)
			# Rank 3: the summary depends on every site's count. Branch only on
			# scalars; the sites are rebuilt into State exactly once.
			total = if c2.dirty3 s2.total() else summary
			r3 = Engine.summarize(c2, summary, total)
			State.{ model: m2, sites: s2, summary: r3.summary, ctx: r3.ctx, stale: new_stale }
		}

		probe_a : State(model, sites, msg), msg, (Tx(model, sites), msg -> Tx(model, sites)) -> State(model, sites, msg)
		probe_a = |state, msg, update| {
			{ model, sites, summary, ctx, stale } = state
			tx = update({ model, sites, ctx }, msg)
			{ model: m2, sites: s0, ctx: c0 } = tx
			State.{ model: m2, sites: s0, summary, ctx: c0, stale }
		}

		probe_b : State(model, sites, msg), msg, (Tx(model, sites), msg -> Tx(model, sites)) -> State(model, sites, msg)
			where [sites.settle : sites, U8, Ctx -> (sites, Ctx)]
		probe_b = |state, msg, update| {
			{ model, sites, summary, ctx, stale } = state
			tx = update({ model, sites, ctx }, msg)
			{ model: m2, sites: s0, ctx: c0 } = tx
			(s1, c1) = s0.settle(1, c0)
			State.{ model: m2, sites: s1, summary, ctx: c1, stale }
		}

		probe_c : State(model, sites, msg), Input(msg), (Tx(model, sites), msg -> Tx(model, sites)) -> State(model, sites, msg)
			where [sites.settle : sites, U8, Ctx -> (sites, Ctx), sites.fire : sites, U32, U32, U8 -> Try(msg, [Stale, NotHere])]
		probe_c = |state, input, update| {
			{ model, sites, summary, ctx, stale } = state
			msg_or = Engine.resolve(sites, input)
			msg = match msg_or {
				Ok(m) => m
				Err(_) => crash "stale"
			}
			tx = update({ model, sites, ctx }, msg)
			{ model: m2, sites: s0, ctx: c0 } = tx
			(s1, c1) = s0.settle(1, c0)
			State.{ model: m2, sites: s1, summary, ctx: c1, stale }
		}

		probe_d : State(model, sites, msg), msg, (Tx(model, sites), msg -> Tx(model, sites)) -> State(model, sites, msg)
			where [sites.settle : sites, U8, Ctx -> (sites, Ctx)]
		probe_d = |state, msg, update| {
			{ model, sites, summary, ctx, stale } = state
			msg_or : Try(msg, [Stale])
			msg_or = Ok(msg)
			tx0 = { model, sites, ctx }
			tx = match msg_or {
				Ok(m) => update(tx0, m)
				Err(_) => tx0
			}
			{ model: m2, sites: s0, ctx: c0 } = tx
			(s1, c1) = s0.settle(1, c0)
			State.{ model: m2, sites: s1, summary, ctx: c1, stale }
		}

		commands : State(model, sites, msg) -> List(U8)
		commands = |state| state.ctx.cmds

		trace : State(model, sites, msg) -> List(Ev)
		trace = |state| state.ctx.log

		evals : State(model, sites, msg) -> U64
		evals = |state| state.ctx.evals

		prunes : State(model, sites, msg) -> U64
		prunes = |state| state.ctx.prunes

		sites : State(model, sites, msg) -> sites
		sites = |state| state.sites

		stale : State(model, sites, msg) -> U64
		stale = |state| state.stale
	}
}
