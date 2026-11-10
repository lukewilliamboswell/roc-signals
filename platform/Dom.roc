## An independent decoder of the unified engine's command stream into a small
## DOM model, used as the test and fuzz oracle. It shares no code with the
## engine. Nodes live in one list; engine ids map to node indices (+1).
Dom := [].{

	## The wire protocol version this oracle decodes (design.md, Appendix B).
	## It is spelled here independently of the engine; the spec runner
	## refuses a program that speaks another.
	protocol_version : U32
	protocol_version = 4

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

	## A `u32` length and that many raw bytes (not necessarily UTF-8).
	raw : List(U8), U64 -> (List(U8), U64)
	raw = |b, at| {
		n = Dom.u32(b, at).to_u64()
		bytes = b.sublist({ start: at + 4, len: n })
		if bytes.len() != n {
			crash "short byte string"
		}
		(bytes, at + 4 + n)
	}

	byte : List(U8), U64 -> U8
	byte = |b, at| b.get(at) ?? crash "short command"

	## Engine id -> node index.
	lookup : Model, U32 -> U64
	lookup = |dom, id| {
		if id == 0 {
			return dom.root
		}
		# statics[id]: node index + 1 in the low 40 bits, row site + 1 above.
		r = (dom.statics.get(id.to_u64()) ?? 0).bitwise_and(1099511627775)
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

	## Bind a row element: its node index, its site (recorded with the id and
	## in the site's row list, so CLEAR can forget the site's rows).
	set_row : Model, U32, U64, U64 -> Model
	set_row = |{ nodes, statics, rows, tpls, root }, id, idx, site| {
		var $s = statics
		while $s.len() <= id.to_u64() {
			$s = $s.append(0)
		}
		var $r = rows
		while $r.len() <= site {
			$r = $r.append([])
		}
		{ list, prev } = $r.replace(site, []) ?? crash "row"
		packed = (idx + 1).bitwise_or((site + 1).shl_wrap(40))
		{ nodes, statics: $s.set(id.to_u64(), packed) ?? crash "static", rows: list.set(site, prev.append(id.to_u64())) ?? crash "row", tpls, root }
	}

	## The site of a bound row element (Err for a static node).
	site_of : Model, U32 -> Try(U64, [Static])
	site_of = |dom, id| {
		v = (dom.statics.get(id.to_u64()) ?? 0).shr_zf_wrap(40)
		if (v == 0) Err(Static) else Ok(v - 1)
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
	bind = |dom, id, idx| Dom.set_static(dom, id, idx)

	unbind : Model, U32 -> Model
	unbind = |{ nodes, statics, rows, tpls, root }, id| {
		packed = statics.get(id.to_u64()) ?? 0
		statics2 = statics.set(id.to_u64(), 0) ?? statics
		site1 = packed.shr_zf_wrap(40)
		if site1 == 0 {
			{ nodes, statics: statics2, rows, tpls, root }
		} else {
			site = site1 - 1
			{ list, prev } = rows.replace(site, []) ?? crash "row"
			{ nodes, statics: statics2, rows: list.set(site, prev.keep_if(|r| r != id.to_u64())) ?? crash "row", tpls, root }
		}
	}

	detach : Model, U64 -> Model
	detach = |dom, i| {
		n = Dom.node(dom, i)
		if n.parent == 0 {
			dom
		} else {
			d1 = Dom.modify(
				dom,
				n.parent - 1,
				|p| {
					{ tag, text, attrs, kids, parent, rn, hs, ht } = p
					kept = match kids.find_last_index(|k| k == i) {
						Ok(pos) => kids.drop_at(pos)
						Err(_) => kids
					}
					{ tag, text, attrs, kids: kept, parent, rn, hs, ht }
				},
			)
			Dom.modify(d1, i, |m| { ..m, parent: 0 })
		}
	}

	## Insert node i into parent (before node `before`, or at the end).
	insert : Model, U64, U64, Try(U64, [End]) -> Model
	insert = |dom, parent, i, before| {
		d0 = Dom.detach(dom, i)
		d1 = Dom.modify(
			d0,
			parent,
			|p| {
				{ tag, text, attrs, kids, parent: pp, rn, hs, ht } = p
				kids2 = match before {
					Err(End) => kids.append(i)
					Ok(b) => {
						pos = kids.find_first_index(|k| k == b) ?? crash "insert before a non-child"
						kids.sublist({ start: 0, len: pos }).append(i).concat(kids.sublist({ start: pos, len: kids.len() - pos }))
					}
				}
				{ tag, text, attrs, kids: kids2, parent: pp, rn, hs, ht }
			},
		)
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
		attrs = if (n.attrs.any(|(k, _)| k == name)) n.attrs.map(|(k, v)| if (k == name) (k, value) else (k, v)) else n.attrs.append((name, value))
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
	op_name = |op| ["?", "INST", "TEXT", "HATTR", "MOVE", "REMOVE", "CLEAR", "TEMPLATE", "ELEM", "ATTR", "TEXTNODE", "LISTEN", "SETTEXT", "FX", "CANCEL", "NAV", "STORE", "TITLE", "FOCUS", "PORT", "SAVE"].get(op.to_u64()) ?? "?"

	## Opcode histogram of a batch, e.g. "SETTEXT=1 ATTR=1".
	describe : List(U8) -> Str
	describe = |ops| {
		var $parts = []
		var $op = 1.U8
		while $op <= 20 {
			n = ops.count_if(|o| o == $op)
			if n > 0 {
				$parts = $parts.append("${Dom.op_name($op)}=${n.to_str()}")
			}
			$op = $op + 1
		}
		Str.join_with($parts, " ")
	}

	## An effect command, decoded independently of the engine.
	FxCmd : [
		Http(U32, Str, Str, List((Str, Str)), Str, U32),
		Get(U32, Str),
		Timer(U32, U32),
		Interval(U32, U32),
		Pop(U32),
		OnlineSub(U32),
		VisibilitySub(U32),

		## A worker job (`FX` kind 8): its id, then its task's name, input
		## bytes, the files it names (each a handle's token and a range of its
		## file), deadline (ms, 0 none), cancel policy (1 stop, 2 finish) and,
		## for a preparation's task, the preparation and where its input lies.
		Work(U32, WorkJob),
		Cancel(U32),
		Push(Str),
		Replace(Str),
		Set(Str, Str),
		Remove(Str),
		Title(Str),
		Focus(U8, U32),

		## A read of a file into the page: id, mode (1 bytes, 2 text) and the
		## file's handle token and range.
		FileRead(U32, U8, { token : U64, start : U64, len : U64 }, U64),

		## An HTTP request whose body is a file's range: id, method, URL,
		## headers, the file and the timeout (ms, 0 none).
		Upload(U32, Str, Str, List((Str, Str)), { token : U64, start : U64, len : U64 }, U32),

		## A digest of a file's range: id, algorithm (1 SHA-256) and the file.
		Digest(U32, U8, { token : U64, start : U64, len : U64 }),

		## A URL that shows a file's range: id and the file.
		FileUrl(U32, { token : U64, start : U64, len : U64 }),

		## A port command (`PORT`): the port and its message.
		PortSend(Str, PortMsg),

		## A port call (`FX` kind 9): id, port, message and timeout (ms, 0
		## none).
		PortCall(U32, Str, PortMsg, U32),

		## A port subscription (`FX` kind 10): id, port and message.
		PortListen(U32, Str, PortMsg),

		## An HTTP request whose body becomes a file (`FX` kind 15): id,
		## method, URL, headers and timeout (ms, 0 none).
		Fetch(U32, Str, Str, List((Str, Str)), U32),

		## A file's range saved as a download (`SAVE`), and the name it is
		## saved under.
		Save({ token : U64, start : U64, len : U64 }, Str),
	]

	## A port message as the wire carries it: JSON text, the byte blocks its
	## bytes markers name, and the handles and ranges of the files its file
	## markers name.
	PortMsg : { json : Str, blobs : List(List(U8)), files : List({ token : U64, start : U64, len : U64 }) }

	## A worker job as `FX` kind 8 describes it (see [FxCmd]'s `Work`).
	WorkJob : { task : Str, input : List(U8), files : List({ token : U64, start : U64, len : U64 }), deadline_ms : U32, cancel : U8, prepared : [Unprepared, Prepared({ name : Str, input_len : U64, input_files : U64 })] }

	## A port message at `at`: `json:str nblobs:u32 (len:u32 bytes)* nfiles:u32
	## (token:u64 start:u64 len:u64)*`, and where it ends.
	port_msg : List(U8), U64 -> (PortMsg, U64)
	port_msg = |b, at| {
		(json, a1) = Dom.str(b, at)
		nblobs = Dom.u32(b, a1).to_u64()
		var $a = a1 + 4
		var $blobs = []
		while $blobs.len() < nblobs {
			(blob, next) = Dom.raw(b, $a)
			$blobs = $blobs.append(blob)
			$a = next
		}
		nfiles = Dom.u32(b, $a).to_u64()
		$a = $a + 4
		var $files = []
		while $files.len() < nfiles {
			$files = $files.append({ token: Dom.u64(b, $a), start: Dom.u64(b, $a + 8), len: Dom.u64(b, $a + 16) })
			$a = $a + 24
		}
		({ json, blobs: $blobs, files: $files }, $a)
	}

	## Apply one batch and also return its opcode sequence.
	apply_ops : Model, List(U8) -> (Model, List(U8))
	apply_ops = |dom0, b| {
		(d, ops, _) = Dom.apply_fx(dom0, b)
		(d, ops)
	}

	## Apply one batch; also return its opcodes and its effect commands in
	## stream order.
	apply_fx : Model, List(U8) -> (Model, List(U8), List(FxCmd))
	apply_fx = |dom0, b| {
		r = Dom.apply_full(dom0, b)
		(r.dom, r.ops, r.fx)
	}

	## Apply one batch; also return its opcodes, its effect commands in
	## stream order, the node indices each `ATTR`, `HATTR`, `SETTEXT` or
	## `TEXT` wrote (one entry per command, in order), and the `value`
	## writes of `ATTR` and `HATTR` (node index and value, in order: the
	## spec runner defers them on a focused control as the runtime does).
	## Node indices only grow, so a node created by this batch has an index
	## at or above the model's node count before it.
	apply_full : Model, List(U8) -> { dom : Model, ops : List(U8), fx : List(FxCmd), written : List(U64), values : List((U64, Str)) }
	apply_full = |dom0, b| {
		var $written = []
		var $values = []
		var $fx = []
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
				site_id = Dom.u32(b, $at + 12).to_u64()
				tpl = $d.tpls.get(site_id) ?? crash "unknown template"
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
				$d = Dom.set_row($dd, nid, root, site_id)
			} else if op == 2 or op == 3 {
				nid = Dom.u32(b, $at)
				h = Dom.byte(b, $at + 4).to_u64()
				(v, next) = Dom.str(b, $at + 5)
				$at = next
				row = Dom.lookup($d, nid)
				tpl = $d.tpls.get(Dom.site_of($d, nid) ?? crash "TEXT/HATTR on a non-row node") ?? crash "unknown template"
				hole = tpl.holes.get(h) ?? crash "unknown hole"
				target = Dom.node($d, row).ht.get(h) ?? crash "hole target"
				$written = $written.append(target)
				if op == 3 and hole.name == "value" {
					$values = $values.append((target, v))
				}
				$d = if (op == 2) Dom.set_text_on($d, target, v) else Dom.set_attr_on($d, target, hole.name, v)
			} else if op == 4 {
				i = Dom.lookup($d, Dom.u32(b, $at))
				before = Dom.u32(b, $at + 4)
				$at = $at + 8
				parent = Dom.node($d, i).parent
				if parent == 0 {
					crash "move of a detached node"
				}
				$d = if (before == 0) Dom.insert($d, parent - 1, i, Err(End)) else Dom.insert($d, parent - 1, i, Ok(Dom.lookup($d, before)))
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
				var $st = statics
				for rid in rows.get(site) ?? [] {
					$st = $st.set(rid, 0) ?? $st
				}
				$d = { nodes, statics: $st, rows: if (site < rows.len()) rows.set(site, []) ?? rows else rows, tpls, root }
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
				# A TEMPLATE starts a new lifetime of this site id (ids are
				# recycled): rows of an earlier site that was disposed with an
				# ancestor are forgotten, as the runtime does, or its next CLEAR
				# would unbind node ids reused since.
				$d = { nodes, statics, rows: $r.set(tpl, []) ?? $r, tpls: $t.set(tpl, t) ?? $t, root }
			} else if op == 8 or op == 10 {
				nid = Dom.u32(b, $at)
				parent = Dom.u32(b, $at + 4)
				before = Dom.u32(b, $at + 8)
				(s, next) = Dom.str(b, $at + 12)
				$at = next
				fresh = if (op == 8) { tag: s, text: "", attrs: [], kids: [], parent: 0, rn: 0, hs: [], ht: [] } else { tag: "", text: s, attrs: [], kids: [], parent: 0, rn: 0, hs: [], ht: [] }
				(d1, i) = Dom.add_node($d, fresh)
				$d = Dom.bind(Dom.place(d1, i, parent, before), nid, i)
			} else if op == 9 {
				i = Dom.lookup($d, Dom.u32(b, $at))
				(name, n1) = Dom.str(b, $at + 4)
				(value, n2) = Dom.str(b, n1)
				$at = n2
				$written = $written.append(i)
				if name == "value" {
					$values = $values.append((i, value))
				}
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
				$written = $written.append(i)
				$d = Dom.set_text_on($d, i, t)
			} else if op == 13 {
				id = Dom.u32(b, $at)
				kind = Dom.byte(b, $at + 4)
				$at = $at + 5
				if kind == 1 {
					(method, a1) = Dom.str(b, $at)
					(url, a2) = Dom.str(b, a1)
					n = Dom.u32(b, a2).to_u64()
					var $hs = []
					var $a = a2 + 4
					var $k = 0.U64
					while $k < n {
						(hk, h1) = Dom.str(b, $a)
						(hv, h2) = Dom.str(b, h1)
						$hs = $hs.append((hk, hv))
						$a = h2
						$k = $k + 1
					}
					(body, a3) = Dom.str(b, $a)
					timeout = Dom.u32(b, a3)
					$at = a3 + 4
					$fx = $fx.append(Http(id, method, url, $hs, body, timeout))
				} else if kind == 2 {
					(key, a1) = Dom.str(b, $at)
					$at = a1
					$fx = $fx.append(Get(id, key))
				} else if kind == 3 {
					$fx = $fx.append(Timer(id, Dom.u32(b, $at)))
					$at = $at + 4
				} else if kind == 4 {
					$fx = $fx.append(Interval(id, Dom.u32(b, $at)))
					$at = $at + 4
				} else if kind == 5 {
					$fx = $fx.append(Pop(id))
				} else if kind == 6 {
					$fx = $fx.append(OnlineSub(id))
				} else if kind == 7 {
					$fx = $fx.append(VisibilitySub(id))
				} else if kind == 8 {
					(task, a1) = Dom.str(b, $at)
					(input, a2) = Dom.raw(b, a1)
					n = Dom.u32(b, a2).to_u64()
					var $refs = []
					var $r = a2 + 4
					while $refs.len() < n {
						$refs = $refs.append({ token: Dom.u64(b, $r), start: Dom.u64(b, $r + 8), len: Dom.u64(b, $r + 16) })
						$r = $r + 24
					}
					deadline_ms = Dom.u32(b, $r)
					cancel = b.get($r + 4) ?? crash "truncated work request"
					flag = b.get($r + 5) ?? crash "truncated work request"
					if cancel < 1 or cancel > 2 {
						crash "work request cancel policy ${cancel.to_str()} is not 1 or 2"
					}
					$at = $r + 6
					# A preparation's task names its preparation and where the
					# preparation's input lies at the start of `input`.
					prepared = if flag == 1 {
						(name, a3) = Dom.str(b, $at)
						input_len = Dom.u32(b, a3).to_u64()
						input_files = Dom.u32(b, a3 + 4).to_u64()
						if input_len > input.len() or input_files > n {
							crash "malformed preparation operands for worker task \"${task}\""
						}
						$at = a3 + 8
						Prepared({ name, input_len, input_files })
					} else if flag == 0 {
						Unprepared
					} else {
						crash "work request flag ${flag.to_str()} is not 0 or 1"
					}
					$fx = $fx.append(Work(id, { task, input, files: $refs, deadline_ms, cancel, prepared }))
				} else if kind == 11 {
					mode = Dom.byte(b, $at)
					if mode != 1 and mode != 2 {
						crash "unknown file read mode ${mode.to_str()}"
					}
					$fx = $fx.append(FileRead(id, mode, Dom.file_ref(b, $at + 1), Dom.u64(b, $at + 25)))
					$at = $at + 33
				} else if kind == 12 {
					(method, a1) = Dom.str(b, $at)
					(url, a2) = Dom.str(b, a1)
					n = Dom.u32(b, a2).to_u64()
					var $hs = []
					var $a = a2 + 4
					while $hs.len() < n {
						(hk, h1) = Dom.str(b, $a)
						(hv, h2) = Dom.str(b, h1)
						$hs = $hs.append((hk, hv))
						$a = h2
					}
					$fx = $fx.append(Upload(id, method, url, $hs, Dom.file_ref(b, $a), Dom.u32(b, $a + 24)))
					$at = $a + 28
				} else if kind == 13 {
					algorithm = Dom.byte(b, $at)
					if algorithm != 1 {
						crash "unknown digest algorithm ${algorithm.to_str()}"
					}
					$fx = $fx.append(Digest(id, algorithm, Dom.file_ref(b, $at + 1)))
					$at = $at + 25
				} else if kind == 14 {
					$fx = $fx.append(FileUrl(id, Dom.file_ref(b, $at)))
					$at = $at + 24
				} else if kind == 9 {
					(port, a1) = Dom.str(b, $at)
					(msg, a2) = Dom.port_msg(b, a1)
					$fx = $fx.append(PortCall(id, port, msg, Dom.u32(b, a2)))
					$at = a2 + 4
				} else if kind == 10 {
					(port, a1) = Dom.str(b, $at)
					(msg, a2) = Dom.port_msg(b, a1)
					$fx = $fx.append(PortListen(id, port, msg))
					$at = a2
				} else if kind == 15 {
					(method, a1) = Dom.str(b, $at)
					(url, a2) = Dom.str(b, a1)
					n = Dom.u32(b, a2).to_u64()
					var $hs = []
					var $a = a2 + 4
					while $hs.len() < n {
						(hk, h1) = Dom.str(b, $a)
						(hv, h2) = Dom.str(b, h1)
						$hs = $hs.append((hk, hv))
						$a = h2
					}
					$fx = $fx.append(Fetch(id, method, url, $hs, Dom.u32(b, $a)))
					$at = $a + 4
				} else {
					crash "unknown effect kind ${kind.to_str()}"
				}
			} else if op == 14 {
				$fx = $fx.append(Cancel(Dom.u32(b, $at)))
				$at = $at + 4
			} else if op == 15 {
				mode = Dom.byte(b, $at)
				(url, a1) = Dom.str(b, $at + 1)
				$at = a1
				$fx = $fx.append(if (mode == 1) Push(url) else if (mode == 2) Replace(url) else crash "unknown nav mode")
			} else if op == 16 {
				mode = Dom.byte(b, $at)
				(key, a1) = Dom.str(b, $at + 1)
				if mode == 1 {
					(v, a2) = Dom.str(b, a1)
					$at = a2
					$fx = $fx.append(Set(key, v))
				} else if mode == 2 {
					$at = a1
					$fx = $fx.append(Remove(key))
				} else {
					crash "unknown store op"
				}
			} else if op == 18 {
				$fx = $fx.append(Focus(Dom.byte(b, $at), Dom.u32(b, $at + 1)))
				$at = $at + 5
			} else if op == 17 {
				(t, a1) = Dom.str(b, $at)
				$at = a1
				$fx = $fx.append(Title(t))
			} else if op == 19 {
				(port, a1) = Dom.str(b, $at)
				(msg, a2) = Dom.port_msg(b, a1)
				$at = a2
				$fx = $fx.append(PortSend(port, msg))
			} else if op == 20 {
				file = Dom.file_ref(b, $at)
				(name, a1) = Dom.str(b, $at + 24)
				$at = a1
				$fx = $fx.append(Save(file, name))
			} else {
				crash "unknown command ${op.to_str()}"
			}
		}
		{ dom: $d, ops: $ops, fx: $fx, written: $written, values: $values }
	}

	## A file's handle token and range on the wire, `token:u64 start:u64
	## len:u64`, at `at`.
	file_ref : List(U8), U64 -> { token : U64, start : U64, len : U64 }
	file_ref = |b, at| { token: Dom.u64(b, at), start: Dom.u64(b, at + 8), len: Dom.u64(b, at + 16) }

	## The engine's work record (design.md, Appendix B): `count:u32
	## (counter:u64)*count`, then `n:u32 (name:str runs:u64)*`. Decoded here,
	## independently of the engine that wrote it.
	Work : { counters : List(U64), cleanups : List((Str, U64)) }

	decode_work : List(U8) -> Work
	decode_work = |b| {
		n = Dom.u32(b, 0).to_u64()
		var $at = 4.U64
		var $cs = []
		var $i = 0.U64
		while $i < n {
			$cs = $cs.append(Dom.u64(b, $at))
			$at = $at + 8
			$i = $i + 1
		}
		m = Dom.u32(b, $at).to_u64()
		$at = $at + 4
		var $runs = []
		$i = 0
		while $i < m {
			(name, a1) = Dom.str(b, $at)
			$runs = $runs.append((name, Dom.u64(b, a1)))
			$at = a1 + 8
			$i = $i + 1
		}
		if $at != b.len() {
			crash "work record length mismatch"
		}
		{ counters: $cs, cleanups: $runs }
	}

	u64 : List(U8), U64 -> U64
	u64 = |b, at| Dom.u32(b, at).to_u64() + Dom.u32(b, at + 4).to_u64().shl_wrap(32)

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
				# A handler name may carry a policy suffix ("click:prevent").
				match n.hs.find_first(|(e, _)| e == ev or e.starts_with("${ev}:")) {
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

	## The (node, handler) pair a `:files` event `ev` on node index i
	## dispatches: as `target`, but the nearest handler for `ev` must take
	## files (a `:files` suffix), as the runtime requires before it hands an
	## event's files over.
	files_target : Model, U64, Str -> Try((U32, U32), [NoHandler])
	files_target = |dom, i, ev| {
		var $n = i
		var $h = -1.I64
		while True {
			n = Dom.node(dom, $n)
			if $h < 0 {
				match n.hs.find_first(|(e, _)| e == ev or e.starts_with("${ev}:")) {
					Ok((e, hh)) => {
						if !e.ends_with(":files") {
							return Err(NoHandler)
						}
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

	## Whether the handler event `ev` dispatches from node index i asks the
	## browser to prevent the event's default action (a `:prevent` suffix), as
	## the runtime decides it when it dispatches (design.md, "Browser events
	## and policies"). An event that reaches no handler prevents nothing.
	prevents : Model, U64, Str -> Bool
	prevents = |dom, i, ev| {
		var $n = i
		var $name = ""
		while True {
			n = Dom.node(dom, $n)
			if $name == "" {
				match n.hs.find_first(|(e, _)| e == ev or e.starts_with("${ev}:")) {
					Ok((e, _)) => {
						$name = e
					}
					Err(_) => {}
				}
			}
			if n.rn != 0 and $name != "" {
				return $name.ends_with(":prevent") or $name.contains(":prevent:")
			}
			if n.parent == 0 {
				return Bool.False
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
		if (n.tag == "") n.text else Str.join_with(n.kids.map(|k| Dom.text_of(dom, k)), "")
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

	## A recycled `each` site id starts empty: rows of the site disposed with
	## an ancestor are not unbound by the next site's CLEAR, even when their
	## node ids were reused for static nodes meanwhile.
	expect {
		le32 = |n| [n.bitwise_and(0xFF).to_u8_wrap(), n.shr_zf_wrap(8).bitwise_and(0xFF).to_u8_wrap(), 0, 0]
		lstr = |t| le32(t.to_utf8().len().to_u32_wrap()).concat(t.to_utf8())
		elem = |id, tag| [8.U8].concat(le32(id)).concat(le32(0.U32)).concat(le32(0.U32)).concat(lstr(tag))
		tpl_bytes = [1.U8].concat(lstr("li")).concat([0, 0, 0])
		template = [7.U8].concat(le32(0.U32)).concat(le32(tpl_bytes.len().to_u32_wrap())).concat(tpl_bytes)
		cmds =
			elem(1.U32, "ul")
				.concat(template)
				.concat([1.U8].concat(le32(2.U32)).concat(le32(1.U32)).concat(le32(0.U32)).concat(le32(0.U32)))
				.concat([5.U8].concat(le32(1.U32)))
				.concat(elem(2.U32, "p"))
				.concat(elem(3.U32, "ul"))
				.concat(template)
				.concat([6.U8].concat(le32(3.U32)).concat(le32(0.U32)))
		dom = Dom.apply(Dom.new({}), cmds)
		(dom.statics.get(2) ?? 0) != 0
	}
}
