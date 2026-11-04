## An independent decoder of the unified engine's command stream into a small
## DOM model, used as the test and fuzz oracle. It shares no code with the
## engine. Nodes live in one list; engine ids map to node indices (+1).
Dom := [].{
	DNode : { tag : Str, text : Str, attrs : List((Str, Str)), kids : List(U64), parent : U64, rn : U32, hs : List((Str, U32)), ht : List(U64) }

	THole : { kind : U8, path : List(U8), name : Str, handler : U8 }

	Tpl : { bytes : List(U8), root_at : U64, holes : List(THole) }

	Model : { nodes : List(DNode), statics : List(U64), rows : List(List(U64)), tpls : List(Tpl), root : U64 }

	new : {} -> Model
	new = |_| { nodes: [{ tag: "root", text: "", attrs: [], kids: [], parent: 0, rn: 0, hs: [], ht: [] }], statics: [], rows: [], tpls: [], root: 0 }

	u32 : List(U8), U64 -> U32
	u32 = |b, at| {
		b0 = (b.get(at) ?? crash "short command").to_u32()
		b1 = (b.get(at + 1) ?? crash "short command").to_u32()
		b2 = (b.get(at + 2) ?? crash "short command").to_u32()
		b3 = (b.get(at + 3) ?? crash "short command").to_u32()
		b0 + b1.shl_wrap(8) + b2.shl_wrap(16) + b3.shl_wrap(24)
	}

	str : List(U8), U64 -> (Str, U64)
	str = |b, at| {
		n = Dom.u32(b, at).to_u64()
		bytes = b.sublist({ start: at + 4, len: n })
		if bytes.len() != n {
			crash "short string"
		}
		(Str.from_utf8(bytes) ?? crash "bad utf8", at + 4 + n)
	}

	byte : List(U8), U64 -> U8
	byte = |b, at| b.get(at) ?? crash "short command"

	## Engine id -> node index.
	lookup : Model, U32 -> U64
	lookup = |dom, id| {
		if id == 0 {
			return dom.root
		}
		site = id.shr_zf_wrap(20).to_u64()
		r = if site == 0 {
			dom.statics.get(id.to_u64()) ?? 0
		} else {
			slot = (id.bitwise_and(1048575) - 1).to_u64()
			(dom.rows.get(site) ?? []).get(slot) ?? 0
		}
		if r == 0 {
			crash "command names an unknown node ${id.to_str()}"
		}
		r - 1
	}

	node : Model, U64 -> DNode
	node = |dom, i| dom.nodes.get(i) ?? crash "node index"

	set_node : Model, U64, DNode -> Model
	set_node = |{ nodes, statics, rows, tpls, root }, i, n| { nodes: nodes.set(i, n) ?? crash "node index", statics, rows, tpls, root }

	add_node : Model, DNode -> (Model, U64)
	add_node = |{ nodes, statics, rows, tpls, root }, n| ({ nodes: nodes.append(n), statics, rows, tpls, root }, nodes.len())

	set_static : Model, U32, U64 -> Model
	set_static = |{ nodes, statics, rows, tpls, root }, id, idx| {
		var $s = statics
		while $s.len() <= id.to_u64() {
			$s = $s.append(0)
		}
		{ nodes, statics: $s.set(id.to_u64(), idx + 1) ?? crash "static", rows, tpls, root }
	}

	set_row : Model, U32, U64 -> Model
	set_row = |{ nodes, statics, rows, tpls, root }, id, idx| {
		site = id.shr_zf_wrap(20).to_u64()
		slot = (id.bitwise_and(1048575) - 1).to_u64()
		var $r = rows
		while $r.len() <= site {
			$r = $r.append([])
		}
		{ list, prev } = $r.replace(site, []) ?? crash "row"
		var $l = prev
		while $l.len() <= slot {
			$l = $l.append(0)
		}
		{ nodes, statics, rows: list.set(site, $l.set(slot, idx + 1) ?? crash "row") ?? crash "row", tpls, root }
	}

	empty_node : DNode
	empty_node = { tag: "", text: "", attrs: [], kids: [], parent: 0, rn: 0, hs: [], ht: [] }

	## Update node i in place (the node is moved out of the list first, so
	## its kid list stays uniquely owned).
	modify : Model, U64, (DNode -> DNode) -> Model
	modify = |{ nodes, statics, rows, tpls, root }, i, f| {
		{ list, prev } = nodes.replace(i, Dom.empty_node) ?? crash "node index"
		{ nodes: list.set(i, f(prev)) ?? crash "node index", statics, rows, tpls, root }
	}

	bind : Model, U32, U64 -> Model
	bind = |dom, id, idx| if id.shr_zf_wrap(20) == 0 Dom.set_static(dom, id, idx) else Dom.set_row(dom, id, idx)

	unbind : Model, U32 -> Model
	unbind = |{ nodes, statics, rows, tpls, root }, id| {
		site = id.shr_zf_wrap(20).to_u64()
		if site == 0 {
			{ nodes, statics: statics.set(id.to_u64(), 0) ?? statics, rows, tpls, root }
		} else {
			slot = (id.bitwise_and(1048575) - 1).to_u64()
			{ list, prev } = rows.replace(site, []) ?? crash "row"
			{ nodes, statics, rows: list.set(site, prev.set(slot, 0) ?? prev) ?? crash "row", tpls, root }
		}
	}

	detach : Model, U64 -> Model
	detach = |dom, i| {
		n = Dom.node(dom, i)
		if n.parent == 0 {
			dom
		} else {
			d1 = Dom.modify(dom, n.parent - 1, |p| {
				{ tag, text, attrs, kids, parent, rn, hs, ht } = p
				kept = match kids.find_last_index(|k| k == i) {
					Ok(pos) => kids.drop_at(pos)
					Err(_) => kids
				}
				{ tag, text, attrs, kids: kept, parent, rn, hs, ht }
			})
			Dom.modify(d1, i, |m| { ..m, parent: 0 })
		}
	}

	## Insert node i into parent (before node `before`, or at the end).
	insert : Model, U64, U64, Try(U64, [End]) -> Model
	insert = |dom, parent, i, before| {
		d0 = Dom.detach(dom, i)
		d1 = Dom.modify(d0, parent, |p| {
			{ tag, text, attrs, kids, parent: pp, rn, hs, ht } = p
			kids2 = match before {
				Err(End) => kids.append(i)
				Ok(b) => {
					pos = kids.find_first_index(|k| k == b) ?? crash "insert before a non-child"
					kids.sublist({ start: 0, len: pos }).append(i).concat(kids.sublist({ start: pos, len: kids.len() - pos }))
				}
			}
			{ tag, text, attrs, kids: kids2, parent: pp, rn, hs, ht }
		})
		Dom.modify(d1, i, |n| { ..n, parent: parent + 1 })
	}

	## Place a fresh node by (parent id, before id) as the engine encodes it.
	place : Model, U64, U32, U32 -> Model
	place = |dom, i, parent, before| {
		if before == 0 {
			Dom.insert(dom, Dom.lookup(dom, parent), i, Err(End))
		} else {
			b = Dom.lookup(dom, before)
			bp = Dom.node(dom, b).parent
			if bp == 0 {
				crash "insert before a detached node"
			}
			Dom.insert(dom, bp - 1, i, Ok(b))
		}
	}

	## Parse one template node, creating nodes; returns the index.
	build : Model, List(U8), U64 -> (Model, U64, U64)
	build = |dom, b, at| {
		kind = Dom.byte(b, at)
		if kind == 2 {
			(t, next) = Dom.str(b, at + 1)
			(d1, i) = Dom.add_node(dom, { tag: "", text: t, attrs: [], kids: [], parent: 0, rn: 0, hs: [], ht: [] })
			(d1, i, next)
		} else {
			(tag, a1) = Dom.str(b, at + 1)
			na = Dom.byte(b, a1).to_u64()
			var $at = a1 + 1
			var $attrs = []
			var $k = 0.U64
			while $k < na {
				(name, n1) = Dom.str(b, $at)
				(value, n2) = Dom.str(b, n1)
				$attrs = $attrs.append((name, value))
				$at = n2
				$k = $k + 1
			}
			nk = Dom.byte(b, $at).to_u64()
			$at = $at + 1
			(d1, i) = Dom.add_node(dom, { tag, text: "", attrs: $attrs, kids: [], parent: 0, rn: 0, hs: [], ht: [] })
			var $d = d1
			$k = 0
			while $k < nk {
				(d2, c, next) = Dom.build($d, b, $at)
				$d = Dom.insert(d2, i, c, Err(End))
				$at = next
				$k = $k + 1
			}
			($d, i, $at)
		}
	}

	## Skip one template node.
	skip : List(U8), U64 -> U64
	skip = |b, at| {
		kind = Dom.byte(b, at)
		if kind == 2 {
			Dom.str(b, at + 1).1
		} else {
			(_, a1) = Dom.str(b, at + 1)
			na = Dom.byte(b, a1).to_u64()
			var $at = a1 + 1
			var $k = 0.U64
			while $k < na {
				$at = Dom.str(b, Dom.str(b, $at).1).1
				$k = $k + 1
			}
			nk = Dom.byte(b, $at).to_u64()
			$at = $at + 1
			$k = 0
			while $k < nk {
				$at = Dom.skip(b, $at)
				$k = $k + 1
			}
			$at
		}
	}

	parse_tpl : List(U8) -> Tpl
	parse_tpl = |b| {
		var $at = Dom.skip(b, 0)
		n = Dom.byte(b, $at).to_u64()
		$at = $at + 1
		var $holes = []
		var $k = 0.U64
		while $k < n {
			kind = Dom.byte(b, $at)
			depth = Dom.byte(b, $at + 1).to_u64()
			path = b.sublist({ start: $at + 2, len: depth })
			$at = $at + 2 + depth
			if kind == 2 {
				(name, next) = Dom.str(b, $at)
				$holes = $holes.append({ kind, path, name, handler: 0 })
				$at = next
			} else if kind == 3 {
				hb = Dom.byte(b, $at)
				(ev, next) = Dom.str(b, $at + 1)
				$holes = $holes.append({ kind, path, name: ev, handler: hb })
				$at = next
			} else {
				$holes = $holes.append({ kind, path, name: "", handler: 0 })
			}
			$k = $k + 1
		}
		if $at != b.len() {
			crash "template length mismatch"
		}
		{ bytes: b, root_at: 0, holes: $holes }
	}

	walk : Model, U64, List(U8) -> U64
	walk = |dom, root, path| {
		var $n = root
		for k in path {
			$n = Dom.node(dom, $n).kids.get(k.to_u64()) ?? crash "template path"
		}
		$n
	}

	set_attr_on : Model, U64, Str, Str -> Model
	set_attr_on = |dom, i, name, value| {
		n = Dom.node(dom, i)
		attrs = if n.attrs.any(|(k, _)| k == name) n.attrs.map(|(k, v)| if k == name (k, value) else (k, v)) else n.attrs.append((name, value))
		Dom.set_node(dom, i, { ..n, attrs })
	}

	set_text_on : Model, U64, Str -> Model
	set_text_on = |dom, i, t| {
		n = Dom.node(dom, i)
		Dom.set_node(dom, i, { ..n, text: t })
	}

	## Apply one command batch.
	apply : Model, List(U8) -> Model
	apply = |dom0, b| Dom.apply_ops(dom0, b).0

	op_name : U8 -> Str
	op_name = |op| ["?", "INST", "TEXT", "HATTR", "MOVE", "REMOVE", "CLEAR", "TEMPLATE", "ELEM", "ATTR", "TEXTNODE", "LISTEN", "SETTEXT"].get(op.to_u64()) ?? "?"

	## Opcode histogram of a batch, e.g. "SETTEXT=1 ATTR=1".
	describe : List(U8) -> Str
	describe = |ops| {
		var $parts = []
		var $op = 1.U8
		while $op <= 12 {
			n = ops.count_if(|o| o == $op)
			if n > 0 {
				$parts = $parts.append("${Dom.op_name($op)}=${n.to_str()}")
			}
			$op = $op + 1
		}
		Str.join_with($parts, " ")
	}

	## Apply one batch and also return its opcode sequence.
	apply_ops : Model, List(U8) -> (Model, List(U8))
	apply_ops = |dom0, b| {
		var $d = dom0
		var $at = 0.U64
		var $ops = []
		while $at < b.len() {
			op = Dom.byte(b, $at)
			$ops = $ops.append(op)
			$at = $at + 1
			if op == 1 {
				nid = Dom.u32(b, $at)
				parent = Dom.u32(b, $at + 4)
				before = Dom.u32(b, $at + 8)
				tpl = $d.tpls.get(Dom.u32(b, $at + 12).to_u64()) ?? crash "unknown template"
				$at = $at + 16
				(d1, root, _) = Dom.build($d, tpl.bytes, 0)
				r = Dom.node(d1, root)
				# Hole targets are resolved once, here: content a nested site
				# inserts into the row later shifts sibling indices.
				var $ht = []
				for hole0 in tpl.holes {
					$ht = $ht.append(Dom.walk(d1, root, hole0.path))
				}
				var $dd = Dom.set_node(d1, root, { ..r, rn: nid, ht: $ht })
				for hole in tpl.holes {
					target = Dom.walk($dd, root, hole.path)
					if hole.kind == 1 {
						(v, next) = Dom.str(b, $at)
						$at = next
						$dd = Dom.set_text_on($dd, target, v)
					} else if hole.kind == 2 {
						(v, next) = Dom.str(b, $at)
						$at = next
						if v != "" or hole.name != "class" {
							$dd = Dom.set_attr_on($dd, target, hole.name, v)
						}
					} else if hole.kind == 3 {
						t = Dom.node($dd, target)
						$dd = Dom.set_node($dd, target, { ..t, hs: t.hs.append((hole.name, hole.handler.to_u32())) })
					} else {
						id = Dom.u32(b, $at)
						$at = $at + 4
						$dd = Dom.bind($dd, id, target)
					}
				}
				$dd = Dom.place($dd, root, parent, before)
				$d = Dom.bind($dd, nid, root)
			} else if op == 2 or op == 3 {
				nid = Dom.u32(b, $at)
				h = Dom.byte(b, $at + 4).to_u64()
				(v, next) = Dom.str(b, $at + 5)
				$at = next
				row = Dom.lookup($d, nid)
				tpl = $d.tpls.get(nid.shr_zf_wrap(20).to_u64()) ?? crash "unknown template"
				hole = tpl.holes.get(h) ?? crash "unknown hole"
				target = Dom.node($d, row).ht.get(h) ?? crash "hole target"
				$d = if op == 2 Dom.set_text_on($d, target, v) else Dom.set_attr_on($d, target, hole.name, v)
			} else if op == 4 {
				i = Dom.lookup($d, Dom.u32(b, $at))
				before = Dom.u32(b, $at + 4)
				$at = $at + 8
				parent = Dom.node($d, i).parent
				if parent == 0 {
					crash "move of a detached node"
				}
				$d = if before == 0 Dom.insert($d, parent - 1, i, Err(End)) else Dom.insert($d, parent - 1, i, Ok(Dom.lookup($d, before)))
			} else if op == 5 {
				id = Dom.u32(b, $at)
				$at = $at + 4
				$d = Dom.unbind(Dom.detach($d, Dom.lookup($d, id)), id)
			} else if op == 6 {
				p = Dom.lookup($d, Dom.u32(b, $at))
				site = Dom.u32(b, $at + 4).to_u64()
				$at = $at + 8
				old_kids = Dom.node($d, p).kids
				var $dd = Dom.modify($d, p, |pn| { ..pn, kids: [] })
				for k in old_kids {
					$dd = Dom.modify($dd, k, |kn| { ..kn, parent: 0 })
				}
				{ nodes, statics, rows, tpls, root } = $dd
				$d = { nodes, statics, rows: if site < rows.len() rows.set(site, []) ?? rows else rows, tpls, root }
			} else if op == 7 {
				tpl = Dom.u32(b, $at).to_u64()
				n = Dom.u32(b, $at + 4).to_u64()
				bytes = b.sublist({ start: $at + 8, len: n })
				$at = $at + 8 + n
				t = Dom.parse_tpl(bytes)
				{ nodes, statics, rows, tpls, root } = $d
				var $t = tpls
				while $t.len() <= tpl {
					$t = $t.append({ bytes: [], root_at: 0, holes: [] })
				}
				var $r = rows
				while $r.len() <= tpl {
					$r = $r.append([])
				}
				$d = { nodes, statics, rows: $r, tpls: $t.set(tpl, t) ?? $t, root }
			} else if op == 8 or op == 10 {
				nid = Dom.u32(b, $at)
				parent = Dom.u32(b, $at + 4)
				before = Dom.u32(b, $at + 8)
				(s, next) = Dom.str(b, $at + 12)
				$at = next
				fresh = if op == 8 { tag: s, text: "", attrs: [], kids: [], parent: 0, rn: 0, hs: [], ht: [] } else { tag: "", text: s, attrs: [], kids: [], parent: 0, rn: 0, hs: [], ht: [] }
				(d1, i) = Dom.add_node($d, fresh)
				$d = Dom.bind(Dom.place(d1, i, parent, before), nid, i)
			} else if op == 9 {
				i = Dom.lookup($d, Dom.u32(b, $at))
				(name, n1) = Dom.str(b, $at + 4)
				(value, n2) = Dom.str(b, n1)
				$at = n2
				$d = Dom.set_attr_on($d, i, name, value)
			} else if op == 11 {
				id = Dom.u32(b, $at)
				h = Dom.u32(b, $at + 4)
				(ev, next) = Dom.str(b, $at + 8)
				$at = next
				i = Dom.lookup($d, id)
				n = Dom.node($d, i)
				$d = Dom.set_node($d, i, { ..n, rn: id, hs: n.hs.append((ev, h)) })
			} else if op == 12 {
				i = Dom.lookup($d, Dom.u32(b, $at))
				(t, next) = Dom.str(b, $at + 4)
				$at = next
				$d = Dom.set_text_on($d, i, t)
			} else {
				crash "unknown command ${op.to_str()}"
			}
		}
		($d, $ops)
	}

	## The (node, handler) pair an event `ev` on node index i dispatches, as
	## the browser runtime computes it: the nearest handler for `ev` walking
	## up (bubbling), then the nearest node with an engine id.
	target : Model, U64, Str -> Try((U32, U32), [NoHandler])
	target = |dom, i, ev| {
		var $n = i
		var $h = -1.I64
		while True {
			n = Dom.node(dom, $n)
			if $h < 0 {
				match n.hs.find_first(|(e, _)| e == ev) {
					Ok((_, hh)) => {
						$h = hh.to_i64()
					}
					Err(_) => {}
				}
			}
			if n.rn != 0 and $h >= 0 {
				return Ok((n.rn, $h.to_u32_wrap()))
			}
			if n.parent == 0 {
				return Err(NoHandler)
			}
			$n = n.parent - 1
		}
	}

	render : Model, U64 -> Str
	render = |dom, i| {
		n = Dom.node(dom, i)
		if n.tag == "" {
			n.text
		} else {
			attrs = n.attrs.map(|(k, v)| " ${k}=\"${v}\"")
			inner = n.kids.map(|k| Dom.render(dom, k))
			"<${n.tag}${Str.join_with(attrs, "")}>${Str.join_with(inner, "")}</${n.tag}>"
		}
	}

	text_of : Model, U64 -> Str
	text_of = |dom, i| {
		n = Dom.node(dom, i)
		if n.tag == "" n.text else Str.join_with(n.kids.map(|k| Dom.text_of(dom, k)), "")
	}

	attr_of : DNode, Str -> Str
	attr_of = |n, name| n.attrs.find_first(|(k, _)| k == name).map_ok(|(_, v)| v) ?? ""

	## First node (depth-first) satisfying `pred`.
	find : Model, U64, (DNode -> Bool) -> Try(U64, [NotFound])
	find = |dom, i, pred| {
		n = Dom.node(dom, i)
		if pred(n) {
			return Ok(i)
		}
		for k in n.kids {
			match Dom.find(dom, k, pred) {
				Ok(r) => {
					return Ok(r)
				}
				Err(_) => {}
			}
		}
		Err(NotFound)
	}

	by_attr : Model, Str, Str -> Try(U64, [NotFound])
	by_attr = |dom, name, value| Dom.find(dom, dom.root, |n| Dom.attr_of(n, name) == value)

	## Every node (depth-first) whose text content equals `t` and has a handler.
	click_target : Model, U64 -> Try((U32, U32), [NoHandler])
	click_target = |dom, i| Dom.target(dom, i, "click")

	button_with_text : Model, Str -> Try(U64, [NotFound])
	button_with_text = |dom, t| Dom.find(dom, dom.root, |n| n.tag == "button" and n.kids.len() == 1 and (Dom.node(dom, n.kids.get(0) ?? 0)).text == t)
}
