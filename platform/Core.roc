## The reactive engine behind the roc-signals web platform, written in Roc:
## the platform's internal module, which apps never import.
##
## `Core.roc` is the authoring API over it; this module holds the
## implementation and the interfaces only the platform's hosts and test
## harnesses use: the [Program] glue the hosts call (`driver`), and mounting,
## driving and inspecting an instance directly (`mount`, `event`, `result`,
## `take_cmds`, `fx_stats`, ...). `design.md` ("Representation D") describes
## the model; Appendix B specifies the command stream and the host protocol.

Core := [].{

	## The context at the top of the application: the context of the [Elem] that
	## `program`'s view returns. Nested contexts ([In], [Row], [Comp]) are built
	## on top of it.
	Root := [Root]

	## The context inside a `state` or `derive` body: a layer holding a value of
	## type `s`, nested in `outer`. Values and handlers from `outer` enter with
	## `lift`.
	In(outer, s) := { outer : outer, value : s }

	## The context inside one row of an `each` template: the row's key and item,
	## nested in `outer`. Values and handlers from `outer` enter with `lift_row`.
	Row(outer, item) := { outer : outer, key : Str, item : item }

	# Nominal rather than opaque (`::`): with the pinned compiler an opaque
	# `Val` grows the Conduit wasm by about 220 KB at --opt=size.
	## A reactive value of type `a`, readable in context `ctx`.
	##
	## A value records which layers it reads, so only the text, attributes and sites
	## that read a changed layer are re-evaluated. Make one with `const`,
	## `State.val`, a [RowRef] accessor or `derive`, and transform it with `map` and
	## `map2`. A value is a recipe, not a cache: mapping functions run each time a
	## reader is re-evaluated, so they must be pure and should be cheap (`derive`
	## memoises an expensive or shared result).
	Val(ctx, a) := { mask : U64, read : (ctx -> a), sel : Sel(ctx) }.{

		## Transform a value with a pure function. The result reads the same layers
		## as the input; the function runs wherever the result is read, each time a
		## read layer changes.
		map : Val(ctx, a), (a -> b) -> Val(ctx, b)
		map = |{ mask, read, sel }, f| { mask, read: |env| f(read(env)), sel }

		## Combine two values with a pure function. The result reads the union of
		## both inputs' layers.
		map2 : Val(ctx, a), Val(ctx, b), (a, b -> c) -> Val(ctx, c)
		map2 = |l, r, f| {
			lr = l.read
			rr = r.read
			m = l.mask.bitwise_or(r.mask).bitwise_or(sel_mask(l.sel)).bitwise_or(sel_mask(r.sel))
			{ mask: m, read: |env| f(lr(env), rr(env)), sel: NoSel }
		}

		## Use a value from the enclosing context inside a `state` or `derive` body
		## nested in it. The value keeps reading the same layers.
		lift : Val(ctx, a) -> Val(In(ctx, s), a)
		lift = |{ mask, read, sel }| {
			sel2 = match sel {
				NoSel => NoSel
				Sel(m, k) => Sel(m, |e| k(e.outer))
			}
			{ mask, read: |e| read(e.outer), sel: sel2 }
		}

		## Use a value from the enclosing context inside an `each` row template
		## nested in it. The value keeps reading the same layers.
		lift_row : Val(ctx, a) -> Val(Row(ctx, item), a)
		lift_row = |{ mask, read, sel }| {
			sel2 = match sel {
				NoSel => NoSel
				Sel(m, k) => Sel(m, |e| k(e.outer))
			}
			{ mask, read: |e| read(e.outer), sel: sel2 }
		}
	}

	## The page's handle on a browser `Blob`: a box the host minted in its
	## resource heap, holding the token the runtime knows the `Blob` by. Roc's
	## reference count is the handle's lifetime: when the last value holding it
	## goes, the host lists the token and the runtime lets the `Blob` go. The
	## platform alone mints one, so an app cannot name a file it was not given.
	Blob :: Box(U64).{

		## The token the runtime knows the browser `Blob` by.
		token : Blob -> U64
		token = |Blob.(b)| Box.unbox(b)
	}

	## A file the user gave the app, or a range of one: a handle with its name,
	## size and type, never its bytes on the page. Read its bytes in a worker
	## program, where the file's range arrives as a list of its own (`contents`),
	## read once into the worker's memory and handed over without a copy; or
	## ask for them on the page with an awaited request (`read_bytes`,
	## `read_utf8`) when bringing them into the page's memory is acceptable.
	##
	## A file stays available while any value holds it: keep it in a state for
	## as long as the app needs it, and it is released when nothing refers to it
	## any more. Two files are equal when they are the same range of the same
	## file.
	File :: { at : [Page(Blob), Worker(List(U8))], name : Str, mime : Str, size : U64, start : U64, len : U64 }.{

		## The file's name, as the browser reports it (no directory).
		name : File -> Str
		name = |f| f.name

		## The file's media type as the browser reports it (`""` when it does not
		## know one).
		mime : File -> Str
		mime = |f| f.mime

		## How many bytes this file, or this range of one, holds.
		size : File -> U64
		size = |f| f.len

		## A range of the file, `len` bytes from `start` (relative to this file
		## or range). A worker reading it reads only those bytes. A range that
		## does not lie within the file is a contract error.
		slice : File, { start : U64, len : U64 } -> File
		slice = |f, { start, len }| {
			if start > f.len or len > f.len - start {
				crash "contract: File.slice of ${start.to_str()}+${len.to_str()} bytes lies outside \"${f.name}\" (${f.len.to_str()} bytes)"
			}
			{ ..f, start: f.start + start, len }
		}

		## The file's bytes, in a worker program that was sent it. On the page a
		## file has no bytes: calling it there is a contract error; ask for them
		## with `read_bytes`, or send the file to a worker program and read them
		## there.
		contents : File -> List(U8)
		contents = |f| match f.at {
			Worker(bytes) => bytes
			Page(_) => crash "contract: File.contents of \"${f.name}\" on the page: a file's bytes are not on the page; request them with File.read_bytes or File.read_utf8, or send the file in a worker program's input and call contents there"
		}

		## The file's bytes as text, in a worker program that was sent it, or
		## `InvalidUtf8` when they are not UTF-8. A byte-order mark is kept. On the
		## page it is a contract error, as `contents` is; ask with `read_utf8`.
		contents_utf8 : File -> Try(Str, [InvalidUtf8])
		contents_utf8 = |f| Str.from_utf8(File.contents(f)).map_err(|_| InvalidUtf8)

		## A request to read the file's bytes into the page, for an effect
		## site's plan. Its result is `FileBytes(bytes)`, or `FileFailed` with
		## `TooLarge` (more than the `maxReadBytes` mount option allows, 8 MiB by
		## default) or `Unreadable` (the user's file changed or went away); read
		## it with `file_bytes`. The browser reads the file on the page's thread
		## into a buffer of its own and the bytes are copied once into the
		## page's memory, so keep it for small files and send large ones to a
		## worker program. The request holds the file until it is answered, and
		## disposing its site cancels it.
		read_bytes : File -> Req
		read_bytes = |f| ReadBytes(f)

		## A request to read the file into the page as text: as `read_bytes`,
		## answered `FileText(text)`, or `FileFailed(InvalidUtf8)` when the bytes
		## are not UTF-8. A byte-order mark is kept. Read it with `file_text`.
		read_utf8 : File -> Req
		read_utf8 = |f| ReadUtf8(f)

		## A request that sends the file, or its range, as the body of an HTTP
		## request, for an effect site's plan. The browser streams it from the
		## file: its bytes never enter the page's memory. It is answered as any
		## HTTP request is (`Http`, `Network`, `Timeout`; read it with
		## `http_text`), and like one it is kept when its site is disposed and
		## answered to the nearest surviving ancestor. A file the browser can no
		## longer read fails the request, which the browser reports as a network
		## failure. `timeout_ms` 0 means no timeout; it is capped at 10 minutes.
		upload : File, { method : Str, url : Str, headers : List((Str, Str)), timeout_ms : U32 } -> Req
		upload = |f, { method, url, headers, timeout_ms }| Upload({ method, url, headers, body: f, timeout_ms })

		## A request for the SHA-256 digest of the file, or its range: answered
		## `Digest(bytes)` with its 32 bytes, read with `file_digest`. The
		## browser reads the range into a buffer of its own, off the page's
		## memory, and digests it with WebCrypto. A range over the
		## `maxFileBytes` mount option (256 MiB by default) is
		## `FileFailed(TooLarge)`, a browser without WebCrypto (a page not
		## served over HTTPS or from localhost) `FileFailed(Unavailable)`. Like a
		## timer it belongs to its site.
		sha256 : File -> Req
		sha256 = |f| Sha256(f)

		## A request for a URL the page can show the file, or its range, by:
		## an `<img>`'s or a `<video>`'s `src`. Answered `FileUrl(url)`, read with
		## `file_url`. The URL is valid exactly as long as the file's handle:
		## when no value holds the file any more, the browser forgets the URL,
		## so keep the file beside the URL for as long as it is shown. Asking
		## twice for the same range answers the same URL; a file gives at most
		## 16 ranges URLs, and a 17th is `FileFailed(TooLarge)`. Like a timer it
		## belongs to its site.
		object_url : File -> Req
		object_url = |f| ObjectUrl(f)

		## Equal when they are the same range of the same file.
		is_eq : File, File -> Bool
		is_eq = |a, b| a.start == b.start and a.len == b.len and a.name == b.name and match (a.at, b.at) {
			(Page(x), Page(y)) => x.token() == y.token()
			(Worker(x), Worker(y)) => x == y
			_ => Bool.False
		}

		## Write the file with the format's `encode_file`: in a worker request
		## the handle and range travel beside the payload, which refers to them.
		encoder_for : encoding -> (File, state -> Try(state, err))
			where [encoding.encode_file : encoding, File, state -> Try(state, err)]
		encoder_for = |encoding| {
			## The format's type, named so its methods can be called.
			Encoding : encoding
			|file, state| Encoding.encode_file(encoding, file, state)
		}

		## Read the file with the format's `parse_file`.
		parser_for : encoding -> (state -> Try({ value : File, rest : state }, err))
			where [encoding.parse_file : encoding, state -> Try({ value : File, rest : state }, err)]
		parser_for = |encoding| {
			## The format's type, named so its methods can be called.
			Encoding : encoding
			|state| Encoding.parse_file(encoding, state)
		}
	}

	## The files one event delivered, and how many more it carried than the
	## instance could take.
	Received : { files : List(File), refused : U64 }

	## A handler for the files an event carries; make one with
	## `State.on_files` and attach it with `on_files`.
	FilesHandler(ctx) := { h : Handler(ctx) }

	## An event handler usable in context `ctx`: a write to one state layer that
	## also receives the event's payload (an input's value, `"true"`/`"false"` for
	## a checkbox, `""` for a click). Make one with the [State] methods and attach
	## it with `on`, `on_click` or an `Html` control. A handler runs once per event,
	## in the transaction that delivers it.
	Handler(ctx) := { mask : U64, run : (ctx, Payload -> ctx) }.{

		## Use a handler from the enclosing context inside a `state` or `derive` body
		## nested in it.
		lift : Handler(ctx) -> Handler(In(ctx, s))
		lift = |{ mask, run }| {
			mask,
			run: |e, p| {
				{ outer, value } = e
				In.{ outer: run(outer, p), value }
			},
		}

		## Use a handler from the enclosing context inside an `each` row template
		## nested in it.
		lift_row : Handler(ctx) -> Handler(Row(ctx, item))
		lift_row = |{ mask, run }| {
			mask,
			run: |e, p| {
				{ outer, key, item } = e
				Row.{ outer: run(outer, p), key, item }
			},
		}
	}

	## A handle on one `state` layer holding an `s`, usable in context `ctx`.
	##
	## Read it with `val`; write it only through handlers (`update`, `set_value`,
	## ...) and reactions (`on_result`). A write marks the layer changed and its
	## readers refresh; equality pruning happens where the value is read (text,
	## attributes, rows, `derive`), not at the state, so a reducer that returns an
	## equal value still costs a refresh pass but emits no DOM commands. Reducers
	## receive the value uniquely owned, so list and record updates happen in place.
	State(ctx, s) := { mask : U64, get : (ctx -> s), modify : (ctx, (s -> s) -> ctx) }.{

		## The state's current value.
		val : State(ctx, s) -> Val(ctx, s)
		val = |{ mask, get, modify: _ }| { mask, read: get, sel: NoSel }

		## A handler that replaces the state with `f` of it, ignoring the event's
		## payload.
		update : State(ctx, s), (s -> s) -> Handler(ctx)
		update = |{ mask, get: _, modify }, f| { mask, run: |e, _| modify(e, f) }

		## A handler whose reducer also receives `v`, read in the handler's context
		## when the event fires (typically the row key or a row field), so a row's
		## handler needs no captured row.
		update_by : State(ctx, s), Val(ctx, b), (s, b -> s) -> Handler(ctx)
		update_by = |{ mask, get: _, modify }, v, f| {
			read = v.read
			{
				mask,
				run: |e, _| {
					b = read(e)
					modify(e, |s| f(s, b))
				},
			}
		}

		## An effect site's [Reaction] that writes this state: the reducer receives
		## the value the request was issued for and its [Res]. If the state has been
		## disposed by the time a reparented result arrives, the write is skipped and
		## counted (`skipped`).
		on_result : State(ctx, s), (s, a, Res -> s) -> Reaction(ctx, a)
		on_result = |{ mask, get: _, modify }, f| { mask, run: |e, a, r| modify(e, |s| f(s, a, r)) }

		## A handler whose reducer receives the event's payload, such as an input's
		## new value or `"true"`/`"false"` from a checkbox.
		set_value : State(ctx, s), (s, Str -> s) -> Handler(ctx)
		set_value = |{ mask, get: _, modify }, f| { mask, run: |e, p| modify(e, |s| f(s, ev_str(p))) }

		## A handler whose reducer receives both `v`, read when the event fires, and
		## the event's payload.
		set_value_by : State(ctx, s), Val(ctx, b), (s, b, Str -> s) -> Handler(ctx)
		set_value_by = |{ mask, get: _, modify }, v, f| {
			read = v.read
			{
				mask,
				run: |e, p| {
					b = read(e)
					modify(e, |s| f(s, b, ev_str(p)))
				},
			}
		}

		## For a component's outward action list (the second argument of a `component`
		## body): a handler that appends `a`. After the event settles, the boundary
		## hands each pushed action, in order, to the caller's [Sink].
		push : State(ctx, List(a)), a -> Handler(ctx)
		push = |{ mask, get: _, modify }, a| { mask, run: |e, _| modify(e, |l| l.append(a)) }

		## Like `push`, appending an action built from `v` read when the event fires
		## (typically the row key).
		push_by : State(ctx, List(a)), Val(ctx, b), (b -> a) -> Handler(ctx)
		push_by = |{ mask, get: _, modify }, v, f| {
			read = v.read
			{
				mask,
				run: |e, _| {
					b = read(e)
					modify(e, |l| l.append(f(b)))
				},
			}
		}

		## Like `push`, appending an action built from `v` read when the event fires
		## and the event's payload.
		push_value_by : State(ctx, List(a)), Val(ctx, b), (b, Str -> a) -> Handler(ctx)
		push_value_by = |{ mask, get: _, modify }, v, f| {
			read = v.read
			{
				mask,
				run: |e, p| {
					b = read(e)
					modify(e, |l| l.append(f(b, ev_str(p))))
				},
			}
		}

		## A handler for files the user chose, dropped or pasted: the reducer
		## receives the files, each a handle with its name, size and type, and
		## how many more there were than the instance could take. Attach it with
		## `on_files`. A file stays available while any value holds its handle.
		on_files : State(ctx, s), (s, Received -> s) -> FilesHandler(ctx)
		on_files = |{ mask, get: _, modify }, f| {
			h: {
				mask,
				run: |e, p| match p {
					Files(files, refused) => modify(e, |s| f(s, { files, refused }))
					_ => e
				},
			},
		}

		## Use a state handle from the enclosing context inside a `state` or `derive`
		## body nested in it.
		lift : State(ctx, s) -> State(In(ctx, t), s)
		lift = |{ mask, get, modify }| {
			mask,
			get: |e| get(e.outer),
			modify: |e, f| {
				{ outer, value } = e
				In.{ outer: modify(outer, f), value }
			},
		}

		## Use a state handle from the enclosing context inside an `each` row template
		## nested in it.
		lift_row : State(ctx, s) -> State(Row(ctx, item), s)
		lift_row = |{ mask, get, modify }| {
			mask,
			get: |e| get(e.outer),
			modify: |e, f| {
				{ outer, key, item } = e
				Row.{ outer: modify(outer, f), key, item }
			},
		}
	}

	## A keyed selection for `RowRef.select`: the selected key and the values a
	## selected and an unselected row see. Make one with `keyed`.
	Keyed(ctx, v) :: { mask : U64, selected : (ctx -> Str), yes : v, no : v }

	## `keyed(selected, yes, no)`: rows whose key equals `selected` see `yes`, all
	## others `no`. Read through `RowRef.select`, a change of `selected`
	## re-evaluates exactly the previously and the newly selected rows instead of
	## every row.
	keyed : Val(ctx, Str), v, v -> Keyed(ctx, v)
	keyed = |sv, yes, no| {
		{ mask, read, sel } = sv
		{ mask: mask.bitwise_or(sel_mask(sel)), selected: read, yes, no }
	}

	## The current row of an `each` template. The template runs once per `each`
	## site, not once per row, so it reads the row through these accessors rather
	## than receiving a row value.
	RowRef(outer, item) := { depth : U64 }.{

		## The row's key. It is fixed for the row's lifetime, so it never triggers a refresh.
		key : RowRef(outer, item) -> Val(Row(outer, item), Str)
		key = |_| { mask: 0, read: |e| e.key, sel: NoSel }

		## A projection of the row's item. It is re-evaluated only for rows whose new
		## item differs from the old one.
		field : RowRef(outer, item), (item -> a) -> Val(Row(outer, item), a)
		field = |{ depth }, f| { mask: bit(depth), read: |e| f(e.item), sel: NoSel }

		## `yes` or `no` from a [Keyed] selection, depending on whether this row's key
		## is the selected one.
		select : RowRef(outer, item), Keyed(outer, v) -> Val(Row(outer, item), v)
		select = |_, kd| {
			{ mask, selected, yes, no } = kd
			{ mask: 0, read: |e| if (selected(e.outer) == e.key) yes else no, sel: Sel(mask, |e| selected(e.outer)) }
		}
	}

	## An attribute, event listener or focus reference on an element, in context
	## `ctx`. Make one with `attr`, `attr_v`, `class`, `class_v`, `test_id`,
	## `test_id_v`, `on`, `on_click` or `ref`.
	Attr(ctx) :: [Static(Str, Str), Dyn(Str, Val(ctx, Str)), On(Str, Handler(ctx)), Ref(Str)]

	## A piece of UI in context `ctx`: an element, a text node or a dynamic site
	## (`state`, `derive`, `resource`, `when`, `switch`, `each`, `component` or an effect site).
	## An `Elem` is a description; the engine mounts it once and afterwards updates
	## only what reads a changed layer.
	Elem(ctx) :: [
		Element(Str, List(Attr(ctx)), List(Elem(ctx))),
		Text(Str),
		TextV(Val(ctx, Str)),

		## A dynamic site and its conservative read mask, given the depth the
		## site is mounted at (computed without mounting it).
		Site(Mount(ctx), (U64 -> U64)),
	]

	## `state(init, body)` adds a state layer, starting at `init`, for the elements
	## `body` builds. There is one instance per mount of the site (so one per row
	## inside an `each` row) and it lives as long as the enclosing scope: it is
	## dropped when its branch, row or component is disposed, and starts again at
	## `init` if remounted. Values from the enclosing context enter `body` with
	## `lift`. More than 63 nested `state`, `derive` or `each` layers within one
	## component is a `resource_limit` error.
	state : s, (State(In(ctx, s), s) -> Elem(In(ctx, s))) -> Elem(ctx)
	state = |init, body| Site(
		Mount(
			|env, args, tx| {
				depth = layer(args.depth, args.path)
				elem = body(state_handle(depth))
				(block, tx1) = mount_block(In.{ outer: env, value: init }, elem, depth, args.path, args.parent, args.before, { cap: args.cap, local: args.local }, tx)
				reads = block.reads
				(state_inst(init, block, depth, args.local), reads, tx1)
			},
		),
		# The static reads are the mounted ones, this layer and those below
		# it included. Outside a row or a component a write to
		# them reports its bit upward, so a conditional whose unmounted branch
		# holds this site must listen to them too.
		|d| {
			d1 = layer_reads(d)
			elem_reads(body(state_handle(d1)), d1)
		},
	)

	## `each(rows, key, template)` renders one row per item of `rows`, identified by
	## `key(item)`. Rows are matched by key across updates: a surviving row is kept
	## (and moved if needed) rather than rebuilt, a row whose item is unchanged does
	## no work, and a changed item re-evaluates only that row's holes that read it.
	##
	## `template` runs once per site against a [RowRef] and must return a single
	## element. A duplicate key is a contract error, as is a focus `ref` directly in
	## the row template (put it in a nested site instead).
	each : Val(ctx, List(item)), (item -> Str), (RowRef(ctx, item) -> Elem(Row(ctx, item))) -> Elem(ctx)
		where [item.is_eq : item, item -> Bool]
	each = |rows, key, template| Site(
		Mount(
			|env, args, tx| {
				depth = layer(args.depth, args.path)
				row_bit = bit(depth)
				plan = compile(template(RowRef.{ depth }), depth)
				(site, tx1) = alloc_site(tx, args.path)
				tpl = template_bytes(plan)
				tx2 = emit_op(tx1, 7, |c| put_u32(put_u32(c, site), tpl.len().to_u32_wrap()).concat(tpl))
				(anchor, tx3) = if args.sole {
					(0, tx2)
				} else {
					(a, t) = alloc_id(tx2)
					before = args.before
					(a, emit_op(t, 10, |c| put_str(put_u32(put_u32(put_u32(c, a), args.parent), before), "")))
				}
				var $om = 0.U64
				var $sm = 0.U64
				for h in plan.holes {
					$om = $om.bitwise_or(h.mask)
					$sm = $sm.bitwise_or(h.smask)
				}
				outer_mask = $om.bitwise_and(row_bit - 1)
				smask_all = $sm
				dynamic = !plan.mounts.is_empty()
				cfg = { site, parent: args.parent, anchor, sole: args.sole, depth, path: args.path, key, plan, dynamic, outer_mask, sel_mask: smask_all }
				ncols = plan.ncols
				nholes = plan.holes.len()
				list = (rows.read)(env)
				(cols, tx4) = append_rows(cfg, cols_empty(ncols, nholes), |k, it| Row.{ outer: env, key: k, item: it }, list, 0, count_evals(tx3, 1))
				# Nested sites in the template report their static reads (kreads),
				# which also covers rows mounted later.
				reads = eff_mask(rows).bitwise_or(outer_mask).bitwise_or(smask_all).bitwise_or(plan.kreads.bitwise_and(row_bit - 1))
				(each_inst(cfg, rows, [], cols), reads, tx4)
			},
		),
		|d| {
			d1 = layer_reads(d)
			eff_mask(rows).bitwise_or(elem_reads(template(RowRef.{ depth: d1 }), d1).bitwise_and(bit(d1) - 1))
		},
	)

	## `when(cond, yes, no)` builds only the branch `cond` selects, and rebuilds it
	## when `cond` changes, disposing the old branch with everything it owns.
	## Because the unselected branch is never built, recursive UI can be expressed
	## directly.
	when : Val(ctx, Bool), (() -> Elem(ctx)), (() -> Elem(ctx)) -> Elem(ctx)
	when = |cond, yes, no| Site(
		Mount(
			|env, args, tx| {
				(anchor, tx1) = alloc_id(tx)
				before = args.before
				tx2 = emit_op(tx1, 10, |c| put_str(put_u32(put_u32(put_u32(c, anchor), args.parent), before), ""))
				c = (cond.read)(env)
				elem = if (c) yes() else no()
				(block, tx3) = mount_block(env, elem, args.depth, args.path, 0, anchor, { cap: args.cap, local: args.local }, bump(count_evals(tx2, 1), w_scopes_created, 1))
				# Listen to the condition, this branch, and what the other branch
				# would read once mounted (or the cap, when the parent knows it).
				reads = if args.cap != 0 {
					args.cap
				} else {
					other = if (c) no() else yes()
					eff_mask(cond).bitwise_or(block.reads).bitwise_or(elem_reads(other, args.depth))
				}
				w = { cond, yes, no, anchor, depth: args.depth, path: args.path, cap: args.cap, local: args.local }
				(when_inst(w, c, [], block), reads, tx3)
			},
		),
		|d| eff_mask(cond).bitwise_or(elem_reads(yes(), d)).bitwise_or(elem_reads(no(), d)),
	)

	## `switch(sel, cases, body)` builds `body(k)` for the current value `k` of
	## `sel`, and rebuilds it when `sel` changes to a different case. `cases` lists
	## every value `sel` can take, so the site listens to everything any branch
	## could read; a value outside `cases` is a contract error.
	switch : Val(ctx, k), List(k), (k -> Elem(ctx)) -> Elem(ctx)
		where [k.is_eq : k, k -> Bool]
	switch = |sel, cases, body| Site(
		Mount(
			|env, args, tx| {
				(anchor, tx1) = alloc_id(tx)
				before = args.before
				tx2 = emit_op(tx1, 10, |c| put_str(put_u32(put_u32(put_u32(c, anchor), args.parent), before), ""))
				k = switch_value(sel, cases, env, args.path)
				(block, tx3) = mount_block(env, body(k), args.depth, args.path, 0, anchor, { cap: args.cap, local: args.local }, bump(count_evals(tx2, 1), w_scopes_created, 1))
				reads = if (args.cap != 0) args.cap else switch_reads(sel, cases, body, args.depth)
				w = { sel, cases, body, anchor, depth: args.depth, path: args.path, cap: args.cap, local: args.local }
				(switch_inst(w, k, [], block), reads, tx3)
			},
		),
		|d| switch_reads(sel, cases, body, d),
	)

	## `derive(input, body)` evaluates `input` once per change of the layers it
	## reads and gives `body` the result as a new layer. Readers inside `body` that
	## read only the derived value do no work while it is equal to the previous
	## result, so use `derive` for a value that is expensive or read in many
	## places. Values from the enclosing context enter `body` with `lift`.
	derive : Val(ctx, a), (Val(In(ctx, a), a) -> Elem(In(ctx, a))) -> Elem(ctx)
		where [a.is_eq : a, a -> Bool]
	derive = |input, body| Site(
		Mount(
			|env, args, tx| {
				depth = layer(args.depth, args.path)
				v = (input.read)(env)
				elem = body({ mask: bit(depth), read: |e| e.value, sel: NoSel })
				(block, tx1) = mount_block(In.{ outer: env, value: v }, elem, depth, args.path, args.parent, args.before, { cap: args.cap, local: args.local }, count_evals(tx, 1))
				# Everything the body reads except this layer, which only this
				# site changes (refreshing its block itself): a state below it
				# reports its bit upward, and the Changed pass must find it here.
				reads = block.reads.bitwise_and(bit(depth).bitwise_not()).bitwise_or(eff_mask(input))
				(derive_inst(input, v, block, depth), reads, tx1)
			},
		),
		|d| {
			d1 = layer_reads(d)
			eff_mask(input).bitwise_or(elem_reads(body({ mask: bit(d1), read: |e| e.value, sel: NoSel }), d1).bitwise_and(bit(d1).bitwise_not()))
		},
	)

	## The context inside a `component` body: the prop of type `p` and the outward
	## action list of type `List(a)`. A body typed over `Comp(p, a)` is specialised
	## once per prop and action type, not once per call site.
	Comp(p, a) := { prop : p, out : List(a) }

	## Where a component's outward actions go in the caller: each action becomes a
	## write of a caller state. Make one with `sink`, or route actions to two sinks
	## with `split`.
	Sink(ctx, a) :: { run : (ctx, a -> (ctx, U64)) }

	## A [Sink] that folds each action into state `st` with the reducer `f`.
	sink : State(ctx, s), (s, a -> s) -> Sink(ctx, a)
	sink = |st, f| {
		{ mask, get: _, modify } = st
		{ run: |e, a| (modify(e, |s| f(s, a)), mask) }
	}

	## A [Sink] that drops every action, for a component that reports none.
	discard : {} -> Sink(ctx, a)
	discard = |_| { run: |e, _| (e, 0) }

	## A [Sink] that routes each action to one of two sinks: `route` tags it `L`
	## for the first or `R` for the second.
	split : Sink(ctx, a), Sink(ctx, b), (c -> [L(a), R(b)]) -> Sink(ctx, c)
	split = |l, r, route| {
		lr = l.run
		rr = r.run
		{
			run: |e, c| match route(c) {
				L(a) => lr(e, a)
				R(b) => rr(e, b)
			},
		}
	}

	## `component(prop, sink, body)` mounts a reusable piece of UI with its own
	## context. `body` sees the prop as a value read from the caller (re-read, not
	## retained, whenever a caller layer it reads changes) and a handle on its
	## outward action list; actions pushed during an event are delivered, in order,
	## to `sink` when the event settles. The body is specialised once per prop and
	## action type, which keeps code size bounded as an app grows.
	component : Val(ctx, p), Sink(ctx, a), (Val(Comp(p, a), p), State(Comp(p, a), List(a)) -> Elem(Comp(p, a))) -> Elem(ctx)
	component = |prop, snk, body| Site(
		Mount(
			|env, args, tx| {
				v = (prop.read)(env)
				out_handle = {
					mask: 0,
					get: |e| e.out,
					modify: |e, f| {
						{ prop: pv, out } = e
						Comp.{ prop: pv, out: f(out) }
					},
				}
				elem = body({ mask: 1, read: |e| e.prop, sel: NoSel }, out_handle)
				(block, tx1) = mount_block(Comp.{ prop: v, out: [] }, elem, 0, args.path, args.parent, args.before, { cap: 0, local: True }, bump(count_evals(tx, 1), w_scopes_created, 1))
				(comp_inst(prop, snk, block), eff_mask(prop), tx1)
			},
		),
		|_| eff_mask(prop),
	)

	## A request from an effect site.
	##
	## Commands are emitted and forgotten: `Push` and `Replace` (history), `Title`,
	## `StorageSet` and `StorageRemove` (local storage), and `Focus`, `Blur` and
	## `SelectText` on a reference named with `ref` (resolved at the end of the
	## turn; a reference that is not mounted then is counted stale).
	##
	## Awaited requests deliver results to the site's [Reaction]: `Http`,
	## `StorageGet` and `Timer` deliver one; `Interval`, `Popstate`,
	## `OnlineChanges` and `VisibilityChanges` are subscriptions that deliver any
	## number until their site is disposed. `Self` asks for a follow-up turn whose
	## result is `Now`, so a site can write state in response to its value changing.
	## `Http`'s `timeout_ms` of 0 means no timeout; it is capped at 10 minutes.
	##
	## `Work` runs the pure program registered under `program` (see
	## `with_workers`) on `input`, off the page's thread, and delivers one
	## `Work(output)` or `WorkLost(fault)`. Like a timer it belongs to its site:
	## disposing the site cancels it. `deadline_ms` 0 means no deadline; it is
	## capped at 10 minutes and delivers `Timeout` when it expires. Issuing work
	## for a program that is not registered is a contract error. `files` are the
	## files the input refers to, read into the worker's memory for the run
	## (`[]` for a program that takes bytes alone; `Worker` fills it in).
	##
	## `ReadBytes` and `ReadUtf8` read a file into the page (`File.read_bytes`,
	## `File.read_utf8`) and deliver one `FileBytes`, `FileText` or
	## `FileFailed`. `Sha256` digests a file and `ObjectUrl` makes a URL that
	## shows it (`File.sha256`, `File.object_url`), delivering `Digest`,
	## `FileUrl` or `FileFailed`. Like a timer these belong to their site.
	## `Upload` is an HTTP request whose body is a file (`File.upload`): it is
	## answered and kept as `Http` is.
	Req : [
		## `timeout_ms` 0 = no timeout; capped at `max_timeout_ms`.
		Http({ method : Str, url : Str, headers : List((Str, Str)), body : Str, timeout_ms : U32 }),
		StorageGet(Str),
		Timer(U32),
		Work({ program : Str, input : List(U8), files : List(File), deadline_ms : U32 }),
		Interval(U32),
		Popstate,

		## Subscriptions to the browser's connectivity (`online`/`offline`)
		## and page visibility (`visibilitychange`). Each change delivers
		## `Online(Bool)` or `Visible(Bool)`; the value at mount is in `Boot`.
		OnlineChanges,
		VisibilityChanges,
		Self,
		Push(Str),
		Replace(Str),
		Title(Str),
		Focus(Str),
		Blur(Str),
		SelectText(Str),
		StorageSet(Str, Str),
		StorageRemove(Str),
		ReadBytes(File),
		ReadUtf8(File),
		Upload({ method : Str, url : Str, headers : List((Str, Str)), body : File, timeout_ms : U32 }),
		Sha256(File),
		ObjectUrl(File),

		## A query of a prepared program (design.md, "Prepared programs"): a
		## `Work` request whose input is a query input, `prep:str
		## init_len:u32 init_files:u32 policy:u8`, then the preparation's
		## input and the query's. It delivers what `Work` delivers and is
		## scoped like it. `Worker` builds it; an input without that header is
		## a contract error.
		Ask({ program : Str, input : List(U8), files : List(File), deadline_ms : U32 }),
	]

	## The result of an awaited request: an HTTP response (`Http`, with any status),
	## a network failure (`Network`) or `Timeout`, a storage `Value` or `Missing`, a
	## timer or interval tick (`Fired`), the URL after `Popstate` (`Location`), a
	## connectivity or visibility change (`Online`, `Visible`), a `Self` follow-up
	## (`Now`), `Refused` when the in-flight bound turned the request away, or a
	## worker program's output (`Work`) or the reason it produced none
	## (`WorkLost`), a file's bytes or text read into the page (`FileBytes`,
	## `FileText`), a file's digest (`Digest`) or a URL that shows it
	## (`FileUrl`), or why an operation on a file produced nothing
	## (`FileFailed`).
	Res : [Http({ status : U16, headers : List((Str, Str)), body : Str }), Network(Str), Timeout, Value(Str), Missing, Fired, Location(Str), Online(Bool), Visible(Bool), Now, Refused, Work(List(U8)), WorkLost(WorkFault), FileFailed(FileError), FileBytes(List(U8)), FileText(Str), Digest(List(U8)), FileUrl(Str)]

	## Why an operation on a file produced nothing: a file could not be read
	## (`Unreadable`: the user's file changed or went away since it was
	## given), it is more than the operation reads (`TooLarge`), its bytes are
	## not UTF-8 (`InvalidUtf8`, reading text), the browser cannot perform the
	## operation (`Unavailable`), or the in-flight bound turned the request
	## away (`Refused`, as the typed readers report it). One type for every
	## operation on a file; each says which arms it can produce.
	FileError : [Unreadable, TooLarge, InvalidUtf8, Unavailable, Refused]

	## A `read_bytes` result as the file's bytes or a typed [FileError]. Any
	## other result is a contract error.
	file_bytes : Res -> Try(List(U8), FileError)
	file_bytes = |res| match res {
		FileBytes(bytes) => Ok(bytes)
		FileFailed(e) => Err(e)
		Refused => Err(Refused)
		_ => crash "contract: file_bytes was given a result that is not from File.read_bytes"
	}

	## A `read_utf8` result as the file's text or a typed [FileError]. Any
	## other result is a contract error.
	file_text : Res -> Try(Str, FileError)
	file_text = |res| match res {
		FileText(text) => Ok(text)
		FileFailed(e) => Err(e)
		Refused => Err(Refused)
		_ => crash "contract: file_text was given a result that is not from File.read_utf8"
	}

	## A `sha256` result as the digest's 32 bytes or a typed [FileError]. Any
	## other result is a contract error.
	file_digest : Res -> Try(List(U8), FileError)
	file_digest = |res| match res {
		Digest(bytes) => Ok(bytes)
		FileFailed(e) => Err(e)
		Refused => Err(Refused)
		_ => crash "contract: file_digest was given a result that is not from File.sha256"
	}

	## An `object_url` result as the URL or a typed [FileError]. Any other
	## result is a contract error.
	file_url : Res -> Try(Str, FileError)
	file_url = |res| match res {
		FileUrl(url) => Ok(url)
		FileFailed(e) => Err(e)
		Refused => Err(Refused)
		_ => crash "contract: file_url was given a result that is not from File.object_url"
	}

	## Why a `Work` request produced no output: the worker's instance faulted
	## running the program (`Contract`, `ResourceLimit`, `OutOfMemory`,
	## `AppCrash` and `ExpectFailed`, the fault classes of an instance), the
	## browser has no workers (`Unavailable`), or the worker itself failed
	## (`Executor`). The diagnostic goes to the page's console, never into the
	## result.
	WorkFault : [Contract, ResourceLimit, OutOfMemory, AppCrash, ExpectFailed, Unavailable, Executor]

	## Why an HTTP request did not produce a successful response, as `http_text`
	## reports it: the browser could not reach the server (`Network`, with the
	## browser's message), the request's `timeout_ms` expired (`Timeout`), the
	## server answered outside 2xx (`Status`), or the in-flight bound refused the
	## request (`Refused`).
	HttpError : [Network(Str), Timeout, Status(U16), Refused]

	## An HTTP result as the body of a 2xx response or a typed [HttpError]. Apps
	## that classify statuses themselves match on `Http` directly. Any result that
	## is not from an HTTP request is a contract error.
	http_text : Res -> Try(Str, HttpError)
	http_text = |res| match res {
		Http({ status, body, .. }) => if (status >= 200 and status < 300) Ok(body) else Err(Status(status))
		Network(message) => Err(Network(message))
		Timeout => Err(Timeout)
		Refused => Err(Refused)
		_ => crash "contract: http_text was given a result that is not an HTTP result"
	}

	## What an effect site does with a result: a write to a state given the value
	## the request was issued for and the [Res]. Make one with `State.on_result`,
	## or use `ignore`.
	Reaction(ctx, a) :: { mask : U64, run : (ctx, a, Res -> ctx) }

	## A reaction that discards every result, for sites that only issue commands.
	ignore : {} -> Reaction(ctx, a)
	ignore = |_| { mask: 0, run: |e, _, _| e }

	## `on_cleanup(name, v, plan)` runs `plan` on `v`, read in the scope's last
	## environment, when the scope this site is mounted in is disposed, and issues
	## the requests in the disposing turn. Only commands are allowed (history,
	## title, storage writes, focus): a request that awaits a result would outlive
	## its owner, so it is a contract error. Each run is counted by `name`. The site
	## renders nothing and reads nothing while it is live.
	on_cleanup : Str, Val(ctx, a), (a -> List(Req)) -> Elem(ctx)
	on_cleanup = |name, v, plan| Site(
		Mount(|_env, _args, tx| (cleanup_inst(name, v, plan), 0, tx)),
		|_| 0,
	)

	## A cleanup site that issues nothing and only counts its runs under `name`.
	cleanup : Str -> Elem(ctx)
	cleanup = |name| Core.on_cleanup(name, Core.const({}), |_| [])

	## `watch(v, plan, react)` issues `plan(v)` when the site mounts and again
	## whenever `v` changes to an unequal value; results go to `react`. Awaited
	## requests belong to the site: when it is disposed, its subscriptions, timers
	## and work are cancelled, and admitted `Http` and `StorageGet` requests are
	## delivered to the nearest surviving ancestor instead. At most 32 requests are
	## in flight by default (see `program_boot`); beyond that a request is answered
	## with `Refused`.
	watch : Val(ctx, a), (a -> List(Req)), Reaction(ctx, a) -> Elem(ctx)
		where [a.is_eq : a, a -> Bool]
	watch = |v, plan, react| effect(v, True, plan, react)

	## Like `watch`, but issues only when `v` changes after mount, never for its
	## initial value.
	on_change : Val(ctx, a), (a -> List(Req)), Reaction(ctx, a) -> Elem(ctx)
		where [a.is_eq : a, a -> Bool]
	on_change = |v, plan, react| effect(v, False, plan, react)

	## `latest(v, plan, react)` issues like `watch`, under one more rule: the site
	## owns only the requests of its current value. Before it issues for a new
	## value it cancels every awaited request it still holds from earlier values
	## (`CANCEL`, counted `cancelled`), whatever its kind, and drops their queued
	## follow-ups and refusals (counted `stale`), so a late answer for an earlier
	## value never reaches `react`. A `plan` that returns `[]` makes a change a
	## pure cancel. Disposal follows `watch`'s rules.
	latest : Val(ctx, a), (a -> List(Req)), Reaction(ctx, a) -> Elem(ctx)
		where [a.is_eq : a, a -> Bool]
	latest = |v, plan, react| Site(
		Mount(
			|env, args, tx| {
				a = (v.read)(env)
				cfg = { v, plan, react, path: args.path }
				(t1, owned) = issue(count_evals(tx, 1), args.path, plan(a), a, [])
				(latest_inst(cfg, a, owned), eff_mask(v), t1)
			},
		),
		|_| eff_mask(v),
	)

	## `resource(input, cfg, body)` is an asynchronous `derive`: a layer whose
	## value follows the answers to the requests issued for `input`. At mount the
	## layer starts at `cfg.begin(cfg.init, a)` and `cfg.plan(a)` is issued; when
	## `input` changes to an unequal value the site supersedes its requests as
	## `latest` does, sets the layer to `cfg.begin(s, a)` in the same pass (before
	## anything below reads it) and issues again. Each result for a request the
	## site owns sets the layer to `cfg.fold(s, a, res)`, where `a` is the value
	## the request was issued for. Readers inside `body` do no work while the
	## layer is equal to its previous value. Disposal follows `watch`'s rules; a
	## reparented answer's write to the retired layer is skipped and counted.
	resource : Val(ctx, a), { init : s, begin : (s, a -> s), plan : (a -> List(Req)), fold : (s, a, Res -> s) }, (Val(In(ctx, s), s) -> Elem(In(ctx, s))) -> Elem(ctx)
		where [a.is_eq : a, a -> Bool, s.is_eq : s, s -> Bool]
	resource = |input, cfg, body| Site(
		Mount(
			|env, args, tx| {
				depth = layer(args.depth, args.path)
				a = (input.read)(env)
				s = (cfg.begin)(cfg.init, a)
				(t1, owned) = issue(count_evals(tx, 1), args.path, (cfg.plan)(a), a, [])
				elem = body({ mask: bit(depth), read: |e| e.value, sel: NoSel })
				(block, t2) = mount_block(In.{ outer: env, value: s }, elem, depth, args.path, args.parent, args.before, { cap: args.cap, local: args.local }, t1)
				# Like a state's, the reads include this layer and those below
				# it: outside a row or a component an answer reports the layer
				# upward, and the root's Changed pass must find its way back here.
				reads = block.reads.bitwise_or(eff_mask(input))
				rc = { input, begin: cfg.begin, plan: cfg.plan, fold: cfg.fold, path: args.path, depth, local: args.local }
				(resource_inst(rc, a, s, owned, block), reads, t2)
			},
		),
		|d| {
			d1 = layer_reads(d)
			eff_mask(input).bitwise_or(elem_reads(body({ mask: bit(d1), read: |e| e.value, sel: NoSel }), d1))
		},
	)

	## For test platforms and harnesses: the instance's effect counters (issued,
	## delivered, stale, refused, cancelled, reparented, skipped) and the number
	## of requests in flight.
	fx_stats : App -> { issued : U64, delivered : U64, stale : U64, refused : U64, cancelled : U64, live : U64, reparented : U64, skipped : U64 }
	fx_stats = |a| {
		fx = a.tx.fx
		{ issued: fx.issued, delivered: fx.delivered, stale: fx.stale, refused: fx.refused, cancelled: fx.cancelled, live: fx.live.len(), reparented: fx.reparented, skipped: fx.skipped }
	}

	## For test platforms and harnesses: the ids of the requests in flight, in issue order.
	fx_live : App -> List(U32)
	fx_live = |a| a.tx.fx.live.map(|l| l.id)

	## For the wire format: what a file's encoding carries beside its handle.
	file_parts : File -> { name : Str, mime : Str, size : U64, start : U64, len : U64 }
	file_parts = |f| { name: f.name, mime: f.mime, size: f.size, start: f.start, len: f.len }

	## For the wire format: a file as a worker program receives it, holding
	## the bytes of its range.
	worker_file : List(U8), { name : Str, mime : Str, size : U64, start : U64, len : U64 } -> File
	worker_file = |bytes, { name, mime, size, start, len }| { at: Worker(bytes), name, mime, size, start, len }

	## For test platforms and harnesses: decode an effect result payload as the
	## host encodes it (design.md, Appendix B). A payload that does not follow the
	## encoding (unknown tag, truncated, trailing bytes, text that is not UTF-8) is
	## a contract error: the host broke the protocol, and nothing is guessed.
	decode_res : List(U8) -> Res
	decode_res = |b| {
		tag = b.first() ?? crash "contract: empty effect result"
		text = |n| Str.from_utf8(b.drop_first(n)) ?? crash "contract: effect result text is not UTF-8"
		bare = |r| if (b.len() == 1) r else crash "contract: effect result tag ${tag.to_str()} carries unexpected bytes"
		flag = || match b {
			[_, 0] => Bool.False
			[_, 1] => Bool.True
			_ => crash "contract: effect result tag ${tag.to_str()} needs one byte 0 or 1"
		}
		if tag == 1 {
			if b.len() < 7 {
				crash "contract: truncated HTTP effect result"
			}
			status = (b.get(1) ?? 0).to_u16() + (b.get(2) ?? 0).to_u16().shl_wrap(8)
			n = get_u32(b, 3, "HTTP effect result").to_u64()
			var $at = 7.U64
			var $hs = []
			var $i = 0.U64
			while $i < n {
				(k, a1) = get_str(b, $at, "HTTP effect result")
				(v, a2) = get_str(b, a1, "HTTP effect result")
				$hs = $hs.append((k, v))
				$at = a2
				$i = $i + 1
			}
			Http({ status, headers: $hs, body: text($at) })
		} else if tag == 7 {
			bare(Timeout)
		} else if tag == 2 {
			Network(text(1))
		} else if tag == 3 {
			Value(text(1))
		} else if tag == 4 {
			bare(Missing)
		} else if tag == 5 {
			bare(Fired)
		} else if tag == 6 {
			Location(text(1))
		} else if tag == 8 {
			Online(flag())
		} else if tag == 9 {
			Visible(flag())
		} else if tag == 10 {
			Work(b.drop_first(1))
		} else if tag == 11 {
			match b {
				[_, class] => WorkLost(work_fault(class))
				_ => crash "contract: effect result tag 11 needs one fault class byte"
			}
		} else if tag == 13 {
			match b {
				[_, 1] => FileFailed(Unreadable)
				[_, 2] => FileFailed(TooLarge)
				[_, 3] => FileFailed(Unavailable)
				_ => crash "contract: effect result tag 13 needs one reason byte, 1, 2 or 3"
			}
		} else if tag == 16 {
			FileBytes(b.drop_first(1))
		} else if tag == 17 {
			# A file's text is the file's own bytes: not being UTF-8 is an
			# answer about the file, not the host breaking the protocol.
			match Str.from_utf8(b.drop_first(1)) {
				Ok(t) => FileText(t)
				Err(_) => FileFailed(InvalidUtf8)
			}
		} else if tag == 18 {
			if b.len() != 33 {
				crash "contract: effect result tag 18 needs a 32-byte SHA-256 digest"
			}
			Digest(b.drop_first(1))
		} else if tag == 19 {
			FileUrl(text(1))
		} else {
			crash "contract: unknown effect result tag ${tag.to_str()}"
		}
	}

	## What the host knows before the first render: the URL, the declared storage
	## keys' values (missing keys are absent), whether the browser is online and
	## the page visible, and whether local storage is available at all. When it is
	## not, the storage list is empty and `StorageSet`/`StorageRemove` do not
	## persist, so an app that relies on reloads surviving can say so.
	Boot : { url : Str, storage : List((Str, Str)), online : Bool, visible : Bool, storage_available : Bool }

	## The boot value of a declared storage key, or `Missing` if it has none.
	boot_storage : Boot, Str -> Try(Str, [Missing])
	boot_storage = |boot, key| match boot.storage.find_first(|(k, _)| k == key) {
		Ok((_, v)) => Ok(v)
		Err(_) => Err(Missing)
	}

	## A value that never changes. It reads no layer, so it never triggers a refresh.
	const : a -> Val(ctx, a)
	const = |value| { mask: 0, read: |_| value, sel: NoSel }

	## `element(tag, attrs, children)`: an HTML element. `Html` offers typed
	## helpers for common elements and controls.
	element : Str, List(Attr(ctx)), List(Elem(ctx)) -> Elem(ctx)
	element = |tag, attrs, kids| Element(tag, attrs, kids)

	## A static text node.
	text : Str -> Elem(ctx)
	text = |s| Text(s)

	## A text node whose content follows a value; the DOM is written only when
	## the text changes.
	text_v : Val(ctx, Str) -> Elem(ctx)
	text_v = |v| TextV(v)

	## A static attribute.
	attr : Str, Str -> Attr(ctx)
	attr = |name, value| Static(name, value)

	## An attribute that follows a value; the DOM is written only when it changes.
	## An empty string removes the attribute. `value` and `checked` update the
	## control's live state (a focused text control keeps the user's draft until
	## blur).
	attr_v : Str, Val(ctx, Str) -> Attr(ctx)
	attr_v = |name, v| Dyn(name, v)

	## A static `class` attribute.
	class : Str -> Attr(ctx)
	class = |c| Static("class", c)

	## A `class` attribute that follows a value.
	class_v : Val(ctx, Str) -> Attr(ctx)
	class_v = |v| Dyn("class", v)

	## A static `data-testid` attribute, for spec locators.
	test_id : Str -> Attr(ctx)
	test_id = |v| Static("data-testid", v)

	## A `data-testid` attribute that follows a value.
	test_id_v : Val(ctx, Str) -> Attr(ctx)
	test_id_v = |v| Dyn("data-testid", v)

	## `on(event, handler)` listens for a DOM event by name (`"input"`, `"keydown"`,
	## ...). A `:prevent` suffix (`"click:prevent"`) calls `preventDefault` when the
	## handler runs. The handler's payload depends on the event type (design.md,
	## Appendix B).
	on : Str, Handler(ctx) -> Attr(ctx)
	on = |ev, h| On(ev, h)

	## Name this element as a focus reference for `Focus`, `Blur` and `SelectText`
	## requests, so the app never handles engine node ids. A name refers to one
	## element at a time (the latest mounted wins) and is released when that
	## element is removed. A `ref` directly in an `each` row template is a contract
	## error; put it in a nested site.
	ref : Str -> Attr(ctx)
	ref = |name| Ref(name)

	## A `click` listener; its payload is empty.
	on_click : Handler(ctx) -> Attr(ctx)
	on_click = |h| On("click", h)

	## `on_files(event, handler)` listens for the files an event carries:
	## `"change"` on a file input, `"drop"` (whose default the runtime
	## prevents, with `dragover`'s, so the browser does not open the file) and
	## `"paste"`. The handler receives the files as handles, never their bytes.
	on_files : Str, FilesHandler(ctx) -> Attr(ctx)
	on_files = |ev, { h }| On(if (ev == "drop") "drop:prevent:files" else "${ev}:files", h)

	## A mounted engine instance: the site tree and the transaction state. The host
	## holds it between calls through [Program]; test platforms and harnesses drive
	## it directly with `mount`, `event`, `result` and `take_cmds`.
	App :: { root : Inst(Root), tx : Tx, programs : List(Str) }

	## For test platforms and harnesses: mount an app under host node 0 with the
	## default in-flight bound of 32. The mount's commands wait in the instance
	## until `take_cmds`.
	mount : Elem(Root) -> App
	mount = |elem| Core.mount_with(32, elem)

	## For test platforms and harnesses: mount with an explicit in-flight effect
	## bound, running any follow-up turns the mount queued.
	mount_with : U64, Elem(Root) -> App
	mount_with = |max, elem| mount_in(max, [], elem)

	## For test platforms and harnesses: deliver a DOM event to `node` and its
	## handler number with the event's payload, as one transaction (plus any
	## follow-up turns). An event on a node that has since been removed is ignored.
	event : App, U32, U32, Str -> App
	event = |inst, node, handler, payload| deliver(inst, node, handler, Ev(payload))

	## For test platforms and harnesses: deliver the files a `:files` event
	## carries, as one transaction like `event`. `record` is the event's file
	## record (Appendix B) and `blobs` the handles the host minted for it, in
	## the record's order; a record that does not match them is a contract
	## error. An event on a removed node is ignored, and its handles go with it.
	event_files : App, U32, U32, List(U8), List(Blob) -> App
	event_files = |inst, node, handler, record, blobs| {
		(files, refused) = decode_files(record, blobs)
		deliver(inst, node, handler, Files(files, refused))
	}

	## Route an event's payload to its node's handler.
	deliver : App, U32, U32, Payload -> App
	deliver = |{ root, tx, programs }, node, handler, payload| {
		# O(1): the route gives a static node's block path or a row's site and
		# slot (the site's path + slot). The handler number comes from the host
		# (LISTEN or the template carried it per event name), so an element
		# with several handlers reaches each one. A freed node id has NoRoute.
		target = match tx.routes.get(node.to_u64()) ?? NoRoute {
			NoRoute => Err(Stale)
			Route(path, _) => Ok((path, handler))
			RowOf(site, slot) => {
				match tx.paths.get(site.to_u64()) {
					Ok(path) => if (path.is_empty()) Err(Stale) else Ok((path.append(slot), handler))
					Err(_) => Err(Stale)
				}
			}
		}
		match target {
			Err(Stale) => { root, tx, programs }
			Ok((path, h)) => drain(turn({ root, tx, programs }, path, h, payload))
		}
	}

	## For test platforms and harnesses: deliver an effect result for request `id`,
	## as one transaction exactly like an event. An id that is not in flight is
	## dropped and counted `stale`.
	result : App, U32, Res -> App
	result = |{ root, tx, programs }, id, res| {
		match tx.fx.live.find_first(|l| l.id == id) {
			Err(_) => { root, tx: fx_count(tx, Stale), programs }
			Ok(entry) => {
				tx1 = if (entry.sub) tx else with_fx(tx, |fx| { ..fx, live: fx.live.keep_if(|l| l.id != id) })
				drain(turn({ root, tx: tx1, programs }, entry.path, id, Fx(res)))
			}
		}
	}

	## For test platforms and harnesses: take the commands accumulated since the
	## last call, leaving `buf` (cleared) in the instance to accumulate the next
	## batch.
	take_cmds : App, List(U8) -> (App, List(U8))
	take_cmds = |{ root, tx, programs }, buf| {
		{ cmds, next, free, routes, work, paths, site_free, fx } = tx
		({ root, tx: { cmds: buf.clear(), next, free, routes, work, paths, site_free, fx }, programs }, cmds)
	}

	## For test platforms and harnesses: how many app closures (holes, values,
	## reducers) the instance has evaluated so far.
	evals : App -> U64
	evals = |a| work_get(a.tx.work, w_evals)

	## For test platforms and harnesses: the instance's work counters so far, in
	## the order of the host's work record (design.md, "Work assertions").
	work_counters : App -> List(U64)
	work_counters = |a| {
		var $out = []
		var $i = 0.U64
		while $i < w_count {
			$out = $out.append(work_get(a.tx.work, $i))
			$i = $i + 1
		}
		$out.concat(fx_counters(a))
	}

	# ------------------------------------------------------------------
	# The settle check: a propagation-completeness oracle for harnesses.

	## For test platforms and harnesses: whether every reader in the instance
	## already shows what its layers imply, which is what a complete turn
	## leaves behind (design.md, "Fuzzing, soak and contract tests").
	##
	## It runs one root `Changed` pass with every layer bit set on a copy of
	## the instance and discards the copy. That pass re-evaluates every hole,
	## re-decides every `when` and `switch`, reconciles every `each`, re-reads
	## every `derive` and `resource` input, every component prop and every
	## effect site's watched value, and reaches into every row and component
	## body; each of those prunes against what it last emitted or holds. So on
	## a settled instance it emits nothing and changes no effect state, and a
	## reader the last turn missed shows up as the command that turn should
	## have emitted: `Err` carries the pass's commands (from opcode 1, as the
	## wire encodes them) and a note naming any change it made to the effect
	## channel without a command (a follow-up queued, a request refused).
	## The end of the turn ([TurnEnd]: focus, program checks) is not run and
	## follow-ups do not run; a request the pass queues for it is a change.
	##
	## The instance passed in is never changed: while the copy is alive it
	## shares the instance's storage, so the pass copies what it touches, and
	## once the result is dropped the instance owns its storage alone again.
	## Run it outside any region that measures allocations.
	settled : App -> Try({}, { cmds : List(U8), note : Str })
	settled = |{ root, tx, programs: _ }| {
		before = tx.fx
		(_, _, after) = call(root, Root, Changed(every_layer), { ..tx, cmds: [] })
		note = settle_note(before, after.fx)
		if (after.cmds.is_empty() and note.is_empty()) Ok({}) else Err({ cmds: after.cmds, note })
	}

	## The wire protocol version this engine speaks (design.md, Appendix B). The
	## host exports it, and the runtime refuses an instance whose version it does
	## not implement.
	protocol_version : U32
	protocol_version = 4

	## A worker program: a namespaced name (`"example.org/search/filter"`) and a
	## pure function from input bytes to output bytes. Make one with
	## `registration` and list it in `with_workers`.
	##
	## A preparation registers under its own name with the names of the
	## queries it answers (`queries`), and `prepare` builds the [Kept] value
	## those queries read; an ordinary program has no queries.
	Registration :: { name : Str, run : (List(U8), List(List(U8)) -> List(U8)), queries : List(Str), prepare : (List(U8), List(List(U8)) -> Kept) }

	## `registration(name, run)`: the worker program `name`, which turns a `Work`
	## request's input bytes into its output bytes with `run`. `run` must be pure:
	## it runs in a separate instance of the same module that shares nothing with
	## the page's instance but the bytes it is given.
	registration : Str, (List(U8) -> List(U8)) -> Registration
	registration = |name, run| { name, run: |input, _| run(input), queries: [], prepare: not_prepared }

	## For the worker layer: a program that also reads the files its request
	## named, each the bytes of its range, read into the worker's memory.
	registration_with_files : Str, (List(U8), List(List(U8)) -> List(U8)) -> Registration
	registration_with_files = |name, run| { name, run, queries: [], prepare: not_prepared }

	## For the worker layer: the preparation `name`, which answers the
	## queries `queries`. `prepare` turns the preparation's input bytes and
	## files into the [Kept] value a worker instance may keep between jobs;
	## it must be pure, and every answer must be what preparing afresh and
	## asking would give.
	registration_prepared : Str, List(Str), (List(U8), List(List(U8)) -> Kept) -> Registration
	registration_prepared = |name, queries, prepare| { name, run: |_, _| crash "contract: worker program \"${name}\" is a preparation; ask one of its queries", queries, prepare }

	## A prepared program's state as a worker instance holds it between jobs
	## (design.md, "Prepared programs"): the preparation's name and `ask`,
	## a closure over the typed state that answers one of its queries,
	## `ask(query, query_bytes, query_files)`. The state never crosses a
	## boundary; the worker's host keeps one `Box(Kept)` as the page's host
	## keeps `Box(App)`, and every answer is what preparing afresh would give.
	Kept :: { prep : Str, ask : (Str, List(U8), List(List(U8)) -> List(U8)) }

	## For the worker layer: the kept state of the preparation `prep`.
	kept : Str, (Str, List(U8), List(List(U8)) -> List(U8)) -> Kept
	kept = |prep, ask| { prep, ask }

	## What the host drives: the protocol version, the declared storage keys (read
	## before mount), mount once with the boot bytes, then one transaction per
	## event or effect result. Each call returns the state, the command batch and
	## the work record, and the host lends both buffers back on the next call so
	## they are reused in place. A worker instance of the same module never
	## mounts; it only runs the catalogue's programs. Apps build one with
	## `program` or `program_boot` and bind it as `main`.
	Program :: {
		version : U32,
		keys : () -> List(U8),
		init : List(Str), List(U8) -> (App, List(U8), List(U8)),
		event : App, List(U8), List(U8), U32, U32, List(U8) -> (App, List(U8), List(U8)),
		workers : List(Registration),
	}.{

		## Add worker programs to the program's catalogue, so its effect sites can
		## issue `Work` requests for them. The page's instance and every worker
		## instance evaluate the same `main`, so both see the same catalogue. At most
		## 64 programs may be registered and each name once; anything else is a
		## contract error when the catalogue is built.
		with_workers : Program, List(Registration) -> Program
		with_workers = |p, registrations| { ..p, workers: p.workers.concat(registrations) }
	}

	## For the platform's hosts and test harnesses: the entry points of a
	## [Program], as the host calls them. `work` is a worker instance's only
	## entry: it runs the catalogue's program named in `name:str input:rest` on
	## the input and returns the output bytes. `settled` is the settle check
	## (`Core.settled`), which only harnesses call.
	driver : Program -> { version : U32, keys : () -> List(U8), init : List(U8) -> (App, List(U8), List(U8)), event : App, List(U8), List(U8), U32, U32, List(U8) -> (App, List(U8), List(U8)), files : App, List(U8), List(U8), U32, U32, List(U8), List(Box(U64)) -> (App, List(U8), List(U8)), work : List(U8), List(List(U8)) -> List(U8), settled : App -> Try({}, { cmds : List(U8), note : Str }) }
	driver = |p| {
		init = p.init
		workers = p.workers
		{
			version: p.version,
			keys: p.keys,
			init: |boot| init(catalogue_names(workers), boot),
			event: p.event,
			files: |inst, buf, wbuf, node, handler, record, blobs| {
				{ root, tx, programs } = inst
				{ cmds: _, next, free, routes, work, paths, site_free, fx } = tx
				fresh = { root, tx: { cmds: buf.clear(), next, free, routes, work, paths, site_free, fx }, programs }
				finish(Core.event_files(fresh, node, handler, record, blobs.map(|b| Blob.(b))), [], wbuf)
			},
			work: |payload, files| run_work(workers, payload, files),
			settled: Core.settled,
		}
	}

	## For the platform's hosts: a worker instance's preparation entry
	## (design.md, "Prepared programs"). It runs the preparation named in
	## `prep:str init:rest` on the input and the preparation's files and
	## returns the state the instance keeps.
	work_prepare : Program, List(U8), List(List(U8)) -> Kept
	work_prepare = |p, payload, files| run_prepare(p.workers, payload, files)

	## For the platform's hosts: a query, `query:str input:rest`, on the
	## state an instance keeps, returning the query's output bytes.
	work_ask : Kept, List(U8), List(List(U8)) -> List(U8)
	work_ask = |kept_state, payload, files| run_ask(kept_state, payload, files)

	## For test platforms and harnesses: the catalogue rule `with_workers`
	## enforces, as a value: the registered names in order, or the contract
	## diagnostic for a duplicate name or more than 64 registrations.
	catalogue : List(Registration) -> Try(List(Str), Str)
	catalogue = |registrations| {
		var $names = []
		for r in registrations {
			for name in [r.name].concat(r.queries) {
				if $names.len() >= max_programs {
					return Err("contract: with_workers registers more than ${max_programs.to_str()} worker programs (program \"${name}\" is over the bound)")
				}
				if $names.contains(name) {
					return Err("contract: worker program \"${name}\" is registered twice in with_workers")
				}
				$names = $names.append(name)
			}
		}
		Ok($names)
	}

	## The [Program] for an app that needs no boot data: mount `view()` with the
	## default in-flight bound of 32.
	program : (() -> Elem(Root)) -> Program
	program = |view| Core.program_boot({ storage_keys: [], max_inflight: 32 }, |_| view())

	## The [Program] for an app that reads boot data: the host reads
	## `storage_keys` from local storage before mount, and `view` receives them in
	## the [Boot] with the URL and connectivity. `max_inflight` bounds the awaited
	## requests in flight at once.
	program_boot : { storage_keys : List(Str), max_inflight : U64 }, (Boot -> Elem(Root)) -> Program
	program_boot = |cfg, view| {
		version: Core.protocol_version,
		keys: || {
			var $b = put_u32([], cfg.storage_keys.len().to_u32_wrap())
			for k in cfg.storage_keys {
				$b = put_str($b, k)
			}
			$b
		},
		init: |names, boot| finish(mount_in(cfg.max_inflight, names, view(decode_boot(boot))), [], []),
		event: |inst, buf, wbuf, node, handler, payload| {
			{ root, tx, programs } = inst
			{ cmds: _, next, free, routes, work, paths, site_free, fx } = tx
			fresh = { root, tx: { cmds: buf.clear(), next, free, routes, work, paths, site_free, fx }, programs }
			if node == fx_node {
				finish(Core.result(fresh, handler, Core.decode_res(payload)), [], wbuf)
			} else {
				finish(Core.event(fresh, node, handler, Str.from_utf8(payload) ?? crash "contract: event payload is not UTF-8"), [], wbuf)
			}
		},
		workers: [],
	}
}

# ------------------------------------------------------------------
# Core internals. Nothing below is visible outside this module.
#
# Command stream (little endian, u32 ids, strings are u32 length + bytes):
#   1 INST     node parent before tpl  then per template hole: text/attr: str,
#              click: nothing, bind: u32 node id for the hole's placeholder
#   2 TEXT     node hole:u8 str        (row text hole)
#   3 HATTR    node hole:u8 str        (row attribute hole)
#   4 MOVE     node before             (0 = append to its parent)
#   5 REMOVE   node
#   6 CLEAR    parent site             (remove all children; drop site rows)
#   7 TEMPLATE tpl len bytes
#   8 ELEM     node parent before tag  (before != 0: insert before it)
#   9 ATTR     node name value         (static or dynamic attribute)
#  10 TEXTNODE node parent before text
#  11 LISTEN   node handler event:str
#  12 SETTEXT  node text
# Node ids: one dense u32 space for every element (rows included), recycled
# through a free list; the routes table maps each to a block path or to a
# row's (site, slot). Each sites are dense u32 ids (template ids), recycled.
# Limits are memory, not bit widths (2^32 - 2 live nodes; fx_node reserved).
# Effect commands (13-18) are described before `max_timeout_ms`.

## A row-selection dependency: a structural alias, so the public `Val` may
## carry it without exposing a private nominal type.
Sel(ctx) : [NoSel, Sel(U64, (ctx -> Str))]

sel_mask : Sel(ctx) -> U64
sel_mask = |sel| match sel {
	NoSel => 0
	Sel(m, _) => m
}

## Mask a plain block must watch for a value: its layers and its selector's.
eff_mask : Val(ctx, a) -> U64
eff_mask = |v| v.mask.bitwise_or(sel_mask(v.sel))

## `sole`: the site is the only child of `parent` and sits at its end.
## `cap` != 0: a known superset of what the site can read; the site may
## report it instead of computing its reads (set inside each rows).
## `local`: the site is inside an each row or a component, where the
## root's Changed pass cannot reach its layers by mask.
Args : { depth : U64, path : List(U32), parent : U32, before : U32, sole : Bool, cap : U64, local : Bool }

Scope : { cap : U64, local : Bool }

Mount(ctx) := [Mount((ctx, Args, Tx -> (Inst(ctx), U64, Tx)))]

## An event's payload: a DOM event's value, or an effect result.
## What fires a handler: a DOM event's text, the files a `:files` event
## carries (and how many were refused), or an effect result.
Payload : [Ev(Str), Files(List(Core.File), U64), Fx(Res)]

ev_str : Payload -> Str
ev_str = |p| match p {
	Ev(s) => s
	_ => ""
}

Msg := [Fire(List(U32), U64, U32, Payload), Changed(U64), Dispose(Bool)]

## Fire always hands the (possibly transformed) environment back up with
## the mask of the layer it changed (0 = nothing changed).
Out(ctx) := [Done, Pending(ctx, U64), Orphaned(List(Orphan(ctx)))]

## An admitted request whose issuing site was disposed (design.md,
## "Requests, effects, and cancellation"): it survives and reparents to the
## nearest surviving ancestor site. `run` applies its reaction in that
## ancestor's current environment: writes to states that were retired
## with the disposed scope land in a snapshot that is discarded (the third
## component counts them), writes to surviving states commit, and the
## mask reports only surviving layers.
Orphan(ctx) : { id : U32, run : (ctx, Res -> (ctx, U64, U64)) }

orphans_of : Out(ctx) -> List(Orphan(ctx))
orphans_of = |out| match out {
	Orphaned(l) => l
	_ => []
}

Inst(ctx) := [Inst((ctx, Msg, Tx -> (Inst(ctx), Out(ctx), Tx)))]

## A node's route: a static node's block path, or a row element's site
## and slot (resolved through the site's current path).
Route := [NoRoute, Route(List(U32), U32), RowOf(U32, U32)]

## Storage captured by a site closure. Wrapping a site's captures in a
## single-tag nominal and unwrapping them inside the closure body keeps
## --opt=speed/size from treating them as borrowed and copying every list
## they hold on each update (roc-lang/roc#12846).
Held(a) := [Held(a)]

Tx : {
	cmds : List(U8),
	next : U32,
	free : List(U32),
	routes : List(Route),
	work : Work,
	paths : List(List(U32)),
	site_free : List(U32),
	fx : Fx,
}

## Work counters (design.md, "Work assertions"): one `Work` record in the
## transaction accumulator, cumulative over the instance. Indices 1-18
## count the commands emitted, by opcode (`INST` is a row created, `MOVE`
## a row moved); the named indices below count engine work.
w_set_value : U64
w_set_value = 19

w_set_checked : U64
w_set_checked = 20

w_evals : U64
w_evals = 21

w_rows_removed : U64
w_rows_removed = 22

w_rows_reused : U64
w_rows_reused = 23

w_rows_updated : U64
w_rows_updated = 24

w_scopes_created : U64
w_scopes_created = 25

w_scopes_disposed : U64
w_scopes_disposed = 26

w_dirty_roots : U64
w_dirty_roots = 27

w_key_hashes : U64
w_key_hashes = 28

w_key_compares : U64
w_key_compares = 29

w_turns : U64
w_turns = 30

w_cleanups : U64
w_cleanups = 31

## The number of work counters (index 0 is unused).
w_count : U64
w_count = 32

## The effect counters follow the work counters in the work record, at
## indices 32-39 (design.md, Appendix B): issued, delivered, stale, refused,
## cancelled, reparented, skipped, and the live ids (a gauge, not a count).
## They are read from the effect table when the record is written, so the
## accumulator keeps no second copy.
fx_counters : App -> List(U64)
fx_counters = |a| {
	fx = a.tx.fx
	[fx.issued, fx.delivered, fx.stale, fx.refused, fx.cancelled, fx.reparented, fx.skipped, fx.live.len()]
}

## The number of counters in the work record: the work counters, then the
## eight effect counters.
w_record_count : U64
w_record_count = w_count + 8

## The work counters as plain fields (`c01` is counter 1): bumping one
## updates a value in the accumulator and never allocates, so counting
## cannot cost an allocation or a copy on any path.
Work : { c01 : U64, c02 : U64, c03 : U64, c04 : U64, c05 : U64, c06 : U64, c07 : U64, c08 : U64, c09 : U64, c10 : U64, c11 : U64, c12 : U64, c13 : U64, c14 : U64, c15 : U64, c16 : U64, c17 : U64, c18 : U64, c19 : U64, c20 : U64, c21 : U64, c22 : U64, c23 : U64, c24 : U64, c25 : U64, c26 : U64, c27 : U64, c28 : U64, c29 : U64, c30 : U64, c31 : U64 }

work_zero : Work
work_zero = { c01: 0, c02: 0, c03: 0, c04: 0, c05: 0, c06: 0, c07: 0, c08: 0, c09: 0, c10: 0, c11: 0, c12: 0, c13: 0, c14: 0, c15: 0, c16: 0, c17: 0, c18: 0, c19: 0, c20: 0, c21: 0, c22: 0, c23: 0, c24: 0, c25: 0, c26: 0, c27: 0, c28: 0, c29: 0, c30: 0, c31: 0 }

## Add `n` to counter `i`; counter 0 (and any index past the last) is the
## unused sink.
add_work : Work, U64, U64 -> Work
add_work = |w, i, n| match i {
	1 => { ..w, c01: w.c01 + n }
	2 => { ..w, c02: w.c02 + n }
	3 => { ..w, c03: w.c03 + n }
	4 => { ..w, c04: w.c04 + n }
	5 => { ..w, c05: w.c05 + n }
	6 => { ..w, c06: w.c06 + n }
	7 => { ..w, c07: w.c07 + n }
	8 => { ..w, c08: w.c08 + n }
	9 => { ..w, c09: w.c09 + n }
	10 => { ..w, c10: w.c10 + n }
	11 => { ..w, c11: w.c11 + n }
	12 => { ..w, c12: w.c12 + n }
	13 => { ..w, c13: w.c13 + n }
	14 => { ..w, c14: w.c14 + n }
	15 => { ..w, c15: w.c15 + n }
	16 => { ..w, c16: w.c16 + n }
	17 => { ..w, c17: w.c17 + n }
	18 => { ..w, c18: w.c18 + n }
	19 => { ..w, c19: w.c19 + n }
	20 => { ..w, c20: w.c20 + n }
	21 => { ..w, c21: w.c21 + n }
	22 => { ..w, c22: w.c22 + n }
	23 => { ..w, c23: w.c23 + n }
	24 => { ..w, c24: w.c24 + n }
	25 => { ..w, c25: w.c25 + n }
	26 => { ..w, c26: w.c26 + n }
	27 => { ..w, c27: w.c27 + n }
	28 => { ..w, c28: w.c28 + n }
	29 => { ..w, c29: w.c29 + n }
	30 => { ..w, c30: w.c30 + n }
	31 => { ..w, c31: w.c31 + n }
	_ => w
}

## Counter `i` (0 for the unused index 0).
work_get : Work, U64 -> U64
work_get = |w, i| match i {
	1 => w.c01
	2 => w.c02
	3 => w.c03
	4 => w.c04
	5 => w.c05
	6 => w.c06
	7 => w.c07
	8 => w.c08
	9 => w.c09
	10 => w.c10
	11 => w.c11
	12 => w.c12
	13 => w.c13
	14 => w.c14
	15 => w.c15
	16 => w.c16
	17 => w.c17
	18 => w.c18
	19 => w.c19
	20 => w.c20
	21 => w.c21
	22 => w.c22
	23 => w.c23
	24 => w.c24
	25 => w.c25
	26 => w.c26
	27 => w.c27
	28 => w.c28
	29 => w.c29
	30 => w.c30
	31 => w.c31
	_ => 0
}

Hole(ctx) : { node : U32, mask : U64, attr : Str, read : (ctx -> Str), last : Str }

Block(ctx) : {
	holes : List(Hole(ctx)),
	handlers : List(Handler(ctx)),
	children : List(Inst(ctx)),
	child_reads : List(U64),
	child_top : List(Bool),
	nodes : List(U32),
	tops : List(U32),
	reads : U64,
}

## ------------------------------------------------------------------
## Command encoding.
put_u32 : List(U8), U32 -> List(U8)
put_u32 = |buf, v| buf.append(v.to_u8_wrap()).append(v.shr_zf_wrap(8).to_u8_wrap()).append(v.shr_zf_wrap(16).to_u8_wrap()).append(v.shr_zf_wrap(24).to_u8_wrap())

put_u64 : List(U8), U64 -> List(U8)
put_u64 = |buf, v| put_u32(put_u32(buf, v.to_u32_wrap()), v.shr_zf_wrap(32).to_u32_wrap())

put_str : List(U8), Str -> List(U8)
put_str = |buf, s| {
	var $b = put_u32(buf, s.count_utf8_bytes().to_u32_wrap())
	for byte in s.iter_utf8() {
		$b = $b.append(byte)
	}
	$b
}

## Append one command: its opcode, then the operands `write` adds. The
## opcode is counted in the work counters (design.md, "Work assertions").
emit_op : Tx, U8, (List(U8) -> List(U8)) -> Tx
emit_op = |{ cmds, next, free, routes, work, paths, site_free, fx }, op, write| { cmds: write(cmds.append(op)), next, free, routes, work: add_work(work, op.to_u64(), 1), paths, site_free, fx }

## Add `n` to work counter `i`.
bump : Tx, U64, U64 -> Tx
bump = |{ cmds, next, free, routes, work, paths, site_free, fx }, i, n| { cmds, next, free, routes, work: add_work(work, i, n), paths, site_free, fx }

## One evaluation of an app closure (a hole, a condition, a list read, a
## `derive` input, a prop read, an effect site's watched value).
count_evals : Tx, U64 -> Tx
count_evals = |tx, n| bump(tx, w_evals, n)

## An attribute command (`ATTR` or `HATTR`) that sets a control's live
## state is also counted by name.
count_attr : Tx, Str -> Tx
count_attr = |tx, name| bump(tx, ctl_of(name), 1)

## The work counter an attribute name counts in besides its opcode: 0
## (the unused counter, so the accumulator is always rebuilt the same
## way, roc-lang/roc#12846) when it names no control state.
ctl_of : Str -> U64
ctl_of = |name| if (name == "value") w_set_value else if (name == "checked") w_set_checked else 0

## Allocate a static node id, reusing a freed one first.
alloc_id : Tx -> (U32, Tx)
alloc_id = |{ cmds, next, free, routes, work, paths, site_free, fx }| {
	match free.last() {
		Ok(id) => (id, { cmds, next, free: free.drop_last(1), routes, work, paths, site_free, fx })
		Err(_) => {
			if next >= 4294967294 {
				crash "resource_limit: node ids exhausted (4294967294 live nodes)"
			}
			(next, { cmds, next: next + 1, free, routes, work, paths, site_free, fx })
		}
	}
}

## Release a static node id and its route.
free_id : Tx, U32 -> Tx
free_id = |{ cmds, next, free, routes, work, paths, site_free, fx }, id| {
	routes2 = if (id.to_u64() < routes.len()) routes.set(id.to_u64(), NoRoute) ?? routes else routes
	fx2 = if ((fx.ref_pos.get(id.to_u64()) ?? 0) == 0) fx else drop_ref(fx, id)
	{ cmds, next, free: free.append(id), routes: routes2, work, paths, site_free, fx: fx2 }
}

## Name `node` as focus reference `name`; a reference of the same name
## on another live node moves here (the later mount wins).
add_ref : Fx, Str, U32 -> Fx
add_ref = |fx, name, node| with_refs(
	fx,
	|refs, ref_pos| {
		var $at = ref_pos
		while $at.len() <= node.to_u64() {
			$at = $at.append(0)
		}
		match refs.find_first_index(|(n, _)| n == name) {
			Ok(i) => {
				(_, old) = refs.get(i) ?? crash "internal: ref"
				at2 = $at.set(old.to_u64(), 0) ?? crash "internal: ref"
				(refs.set(i, (name, node)) ?? crash "internal: ref", at2.set(node.to_u64(), (i + 1).to_u32_wrap()) ?? crash "internal: ref")
			}
			Err(_) => {
				n = refs.len() + 1
				(refs.append((name, node)), $at.set(node.to_u64(), n.to_u32_wrap()) ?? crash "internal: ref")
			}
		}
	},
)

## Forget the reference `node` carries: swap-remove it from `refs` and
## re-point the entry that moved.
drop_ref : Fx, U32 -> Fx
drop_ref = |fx, node| with_refs(
	fx,
	|refs, ref_pos| {
		pos = (ref_pos.get(node.to_u64()) ?? 0).to_u64()
		last = refs.len()
		at1 = ref_pos.set(node.to_u64(), 0) ?? crash "internal: ref"
		if pos == last {
			(refs.drop_last(1), at1)
		} else {
			(lname, lnode) = refs.get(last - 1) ?? crash "internal: ref"
			refs2 = (refs.set(pos - 1, (lname, lnode)) ?? crash "internal: ref").drop_last(1)
			(refs2, at1.set(lnode.to_u64(), pos.to_u32_wrap()) ?? crash "internal: ref")
		}
	},
)

## Update the reference table with both lists moved out of `fx`, so
## they stay uniquely owned and update in place.
with_refs : Fx, (List((Str, U32)), List(U32) -> (List((Str, U32)), List(U32))) -> Fx
with_refs = |{ next, inner, live, queue, max, issued, delivered, stale, refused, cancelled, reparented, skipped, refs, focus, ref_pos, cleanups }, f| {
	(refs2, at2) = f(refs, ref_pos)
	{ next, inner, live, queue, max, issued, delivered, stale, refused, cancelled, reparented, skipped, refs: refs2, focus, ref_pos: at2, cleanups }
}

set_route : Tx, U32, List(U32), U32 -> Tx
set_route = |{ cmds, next, free, routes, work, paths, site_free, fx }, id, path, handler| {
	var $r = routes
	while $r.len() <= id.to_u64() {
		$r = $r.append(NoRoute)
	}
	{ cmds, next, free, routes: $r.set(id.to_u64(), Route(path, handler)) ?? $r, work, paths, site_free, fx }
}

set_row_route : Tx, U32, U32, U32 -> Tx
set_row_route = |{ cmds, next, free, routes, work, paths, site_free, fx }, id, site, slot| {
	var $r = routes
	while $r.len() <= id.to_u64() {
		$r = $r.append(NoRoute)
	}
	{ cmds, next, free, routes: $r.set(id.to_u64(), RowOf(site, slot)) ?? $r, work, paths, site_free, fx }
}

## Allocate an each-site id (template id).
alloc_site : Tx, List(U32) -> (U32, Tx)
alloc_site = |{ cmds, next, free, routes, work, paths, site_free, fx }, path| {
	match site_free.last() {
		Ok(s) => (s, { cmds, next, free, routes, work, paths: paths.set(s.to_u64(), path) ?? crash "site", site_free: site_free.drop_last(1), fx })
		Err(_) => {
			s = paths.len().to_u32_wrap()
			(s, { cmds, next, free, routes, work, paths: paths.append(path), site_free, fx })
		}
	}
}

free_site : Tx, U32 -> Tx
free_site = |{ cmds, next, free, routes, work, paths, site_free, fx }, s| {
	{ cmds, next, free, routes, work, paths: paths.set(s.to_u64(), []) ?? paths, site_free: site_free.append(s), fx }
}

## The deepest layer a mask can name: a component body nests at most 63
## layers below its prop (design.md, "Contexts and layers").
max_depth : U64
max_depth = 63

## A layer's bit in a read mask. Every layer is created through `layer`,
## which refuses a depth beyond `max_depth`, so this never wraps.
bit : U64 -> U64
bit = |depth| (1.U64).shl_wrap(depth.to_u8_wrap())

## The depth of a new layer below `depth`, at construction site `path`.
## Nesting deeper than `max_depth` is a resource limit, never a wrap.
layer : U64, List(U32) -> U64
layer = |depth, path| {
	if depth >= max_depth {
		crash "resource_limit: more than ${max_depth.to_str()} nested state, derive or each layers in one component at site ${show_path(path)}"
	}
	depth + 1
}

## The read-mask depth of a layer below `depth` (static reads, computed
## before mounting; the mount reports the same limit with its path).
layer_reads : U64 -> U64
layer_reads = |depth| {
	if depth >= max_depth {
		crash "resource_limit: more than ${max_depth.to_str()} nested state, derive or each layers in one component"
	}
	depth + 1
}

## Every layer at once: the mask of the settle check (`Core.settled`). A
## `Changed` with it re-evaluates every hole and descends into every child
## whatever its read mask, and the sites that settle layers of their own (an
## `each` row, a component body) pass it inward whole instead of translating
## it. The root's turn mask never has bit 0 (no layer of the root's context is
## at depth 0), so a turn never sends it; inside a component only a chain of 63
## nested `derive`s that all changed at once could build it, and the extra
## evaluations it then forces are pruned like any other.
every_layer : U64
every_layer = 0xFFFF_FFFF_FFFF_FFFF

## All layers at or above `depth`.
upto : U64 -> U64
upto = |depth| if (depth >= 63) 0xFFFF_FFFF_FFFF_FFFF else bit(depth).shl_wrap(1) - 1

## ------------------------------------------------------------------
## Blocks: the static content of one non-each site, flattened at mount.
empty_block : {} -> Block(ctx)
empty_block = |_| { holes: [], handlers: [], children: [], child_reads: [], child_top: [], nodes: [], tops: [], reads: 0 }

mount_elem : Block(ctx), ctx, Elem(ctx), U64, List(U32), U32, U32, Bool, Bool, Scope, Tx -> (Block(ctx), Tx)
mount_elem = |block, env, elem, depth, path, parent, before, top, sole, scope, tx| {
	at = if (top) before else 0
	match elem {
		Element(tag, attrs, kids) => {
			(id, tx1) = alloc_id(tx)
			tx2 = emit_op(tx1, 8, |c| put_str(put_u32(put_u32(put_u32(c, id), parent), at), tag))
			var $b = add_node(block, id, top)
			var $t = tx2
			for attr in attrs {
				(b2, t2) = mount_attr($b, env, attr, id, path, $t)
				$b = b2
				$t = t2
			}
			kid_sole = kids.len() == 1
			for kid in kids {
				(b3, t3) = mount_elem($b, env, kid, depth, path, id, 0, False, kid_sole, scope, $t)
				$b = b3
				$t = t3
			}
			($b, $t)
		}
		Text(s) => {
			(id, tx1) = alloc_id(tx)
			tx2 = emit_op(tx1, 10, |c| put_str(put_u32(put_u32(put_u32(c, id), parent), at), s))
			(add_node(block, id, top), tx2)
		}
		TextV(v) => {
			(id, tx1) = alloc_id(tx)
			read = v.read
			s = read(env)
			tx2 = emit_op(count_evals(tx1, 1), 10, |c| put_str(put_u32(put_u32(put_u32(c, id), parent), at), s))
			b1 = add_node(block, id, top)
			(add_hole(b1, { node: id, mask: eff_mask(v), attr: "", read, last: s }), tx2)
		}
		Site(Mount(mount), _) => {
			k = block.children.len().to_u32_wrap()
			(inst, reads, tx1) = mount(env, { depth, path: path.append(k), parent, before: at, sole: sole and !top, cap: scope.cap, local: scope.local }, tx)
			(add_child(block, inst, reads, top), tx1)
		}
	}
}

mount_attr : Block(ctx), ctx, Attr(ctx), U32, List(U32), Tx -> (Block(ctx), Tx)
mount_attr = |block, env, attr, id, path, tx| {
	match attr {
		Static(name, value) => (block, emit_op(count_attr(tx, name), 9, |c| put_str(put_str(put_u32(c, id), name), value)))
		Dyn(name, v) => {
			read = v.read
			value = read(env)
			tx1 = emit_op(count_attr(count_evals(tx, 1), name), 9, |c| put_str(put_str(put_u32(c, id), name), value))
			(add_hole(block, { node: id, mask: eff_mask(v), attr: name, read, last: value }), tx1)
		}
		On(ev, handler) => {
			h = block.handlers.len().to_u32_wrap()
			tx1 = emit_op(tx, 11, |c| put_str(put_u32(put_u32(c, id), h), ev))
			(add_handler(block, handler), set_route(tx1, id, path, h))
		}
		Ref(name) => (block, with_fx(tx, |fx| add_ref(fx, name, id)))
	}
}

add_node : Block(ctx), U32, Bool -> Block(ctx)
add_node = |{ holes, handlers, children, child_reads, child_top, nodes, tops, reads }, id, top| {
	{ holes, handlers, children, child_reads, child_top, nodes: nodes.append(id), tops: if (top) tops.append(id) else tops, reads }
}

add_hole : Block(ctx), Hole(ctx) -> Block(ctx)
add_hole = |{ holes, handlers, children, child_reads, child_top, nodes, tops, reads }, hole| {
	m = hole.mask
	{ holes: holes.append(hole), handlers, children, child_reads, child_top, nodes, tops, reads: reads.bitwise_or(m) }
}

add_handler : Block(ctx), Handler(ctx) -> Block(ctx)
add_handler = |{ holes, handlers, children, child_reads, child_top, nodes, tops, reads }, h| {
	{ holes, handlers: handlers.append(h), children, child_reads, child_top, nodes, tops, reads }
}

add_child : Block(ctx), Inst(ctx), U64, Bool -> Block(ctx)
add_child = |{ holes, handlers, children, child_reads, child_top, nodes, tops, reads }, inst, r, top| {
	{ holes, handlers, children: children.append(inst), child_reads: child_reads.append(r), child_top: child_top.append(top), nodes, tops, reads: reads.bitwise_or(r) }
}

mount_block : ctx, Elem(ctx), U64, List(U32), U32, U32, Scope, Tx -> (Block(ctx), Tx)
mount_block = |env, elem, depth, path, parent, before, scope, tx| mount_elem(empty_block({}), env, elem, depth, path, parent, before, True, False, scope, tx)

noop : {} -> Inst(ctx)
noop = |_| Inst(
	|env, msg, tx| {
		match msg {
			Fire(_, _, _, _) => (noop({}), Pending(env, 0), tx)
			_ => (noop({}), Done, tx)
		}
	},
)

call : Inst(ctx), ctx, Msg, Tx -> (Inst(ctx), Out(ctx), Tx)
call = |Inst(f), env, msg, tx| f(env, msg, tx)

## Re-evaluate the holes that read a changed layer, then descend into the
## children whose subtrees read one. With `every_layer` it re-evaluates every
## hole and descends into every child, whatever the masks say.
refresh : Block(ctx), ctx, U64, Tx -> (Block(ctx), Tx)
refresh = |{ holes, handlers, children, child_reads, child_top, nodes, tops, reads }, env, mask, tx| {
	all = mask == every_layer
	var $holes = holes
	var $tx = tx
	var $i = 0.U64
	while $i < $holes.len() {
		hm = $holes.get($i).map_ok(|h| h.mask) ?? 0
		if all or hm.bitwise_and(mask) != 0 {
			{ list, prev } = $holes.replace($i, { node: 0, mask: 0, attr: "", read: |_| "", last: "" }) ?? crash "hole"
			{ node, mask: m, attr, read, last } = prev
			v = read(env)
			t1 = count_evals($tx, 1)
			if v == last {
				$holes = list.set($i, { node, mask: m, attr, read, last }) ?? crash "hole"
				$tx = t1
			} else {
				$tx = if attr.is_empty() {
					emit_op(t1, 12, |c| put_str(put_u32(c, node), v))
				} else {
					emit_op(count_attr(t1, attr), 9, |c| put_str(put_str(put_u32(c, node), attr), v))
				}
				$holes = list.set($i, { node, mask: m, attr, read, last: v }) ?? crash "hole"
			}
		}
		$i = $i + 1
	}
	var $kids = children
	var $j = 0.U64
	while $j < $kids.len() {
		r = child_reads.get($j) ?? 0
		if all or r.bitwise_and(mask) != 0 {
			{ list, prev } = $kids.replace($j, noop({})) ?? crash "child"
			(next, _, t2) = call(prev, env, Changed(mask), $tx)
			$kids = list.set($j, next) ?? crash "child"
			$tx = t2
		}
		$j = $j + 1
	}
	({ holes: $holes, handlers, children: $kids, child_reads, child_top, nodes, tops, reads }, $tx)
}

## Route an event down the site path; the owning block runs the handler.
## The environment always comes back up (Pending with mask 0 if untouched).
##
## The three cases are separate functions and every site closure returns
## from each case directly: a block that is passed through unchanged on one
## path and rebuilt on another must never meet in one value, or
## --opt=speed/size treats the captured block as borrowed and copies the
## lists of every site below it (roc-lang/roc#12846).
fire_target : Block(ctx), List(U32), U64 -> [Leaf, Kid, Miss]
fire_target = |block, path, pos| {
	if pos >= path.len() {
		Leaf
	} else if (path.get(pos) ?? 0).to_u64() < block.children.len() {
		Kid
	} else {
		Miss
	}
}

## Run handler `h` of this block (the event's target is this block).
fire_leaf : Block(ctx), ctx, U32, Payload -> Out(ctx)
fire_leaf = |block, env, h, payload| {
	match block.handlers.get(h.to_u64()) {
		Ok(handler) => Pending((handler.run)(env, payload), handler.mask)
		Err(_) => Pending(env, 0)
	}
}

## Forward the event to child `path[pos]`, which must exist.
fire_kid : Block(ctx), ctx, List(U32), U64, U32, Payload, Tx -> (Block(ctx), Out(ctx), Tx)
fire_kid = |block, env, path, pos, h, payload, tx| {
	k = (path.get(pos) ?? 0).to_u64()
	{ holes, handlers, children, child_reads, child_top, nodes, tops, reads } = block
	{ list, prev } = children.replace(k, noop({})) ?? crash "child"
	(next, out, tx1) = call(prev, env, Fire(path, pos + 1, h, payload), tx)
	({ holes, handlers, children: list.set(k, next) ?? crash "child", child_reads, child_top, nodes, tops, reads }, out, tx1)
}

## Dispose a block's children (and its nodes); returns the orphans its
## nested sites left, typed by this block's environment.
dispose_block : Block(ctx), ctx, Bool, Tx -> (List(Orphan(ctx)), Tx)
dispose_block = |{ holes: _, handlers: _, children, child_reads: _, child_top, nodes, tops, reads: _ }, env, remove, tx| {
	var $tx = tx
	var $j = 0.U64
	var $ks = children
	var $orph = []
	while $j < $ks.len() {
		kid_top = child_top.get($j) ?? False
		{ list, prev } = $ks.replace($j, noop({})) ?? crash "child"
		(_, out, t1) = call(prev, env, Dispose(remove and kid_top), $tx)
		$orph = $orph.concat(orphans_of(out))
		$ks = list
		$tx = t1
		$j = $j + 1
	}
	if remove {
		for id in tops {
			$tx = emit_op($tx, 5, |c| put_u32(c, id))
		}
	}
	for id in nodes {
		$tx = free_id($tx, id)
	}
	($orph, $tx)
}

## ------------------------------------------------------------------
## Site kinds.

## After an event below a state site: take this layer's value back from
## the environment and refresh the block if this layer changed.
state_settle : Block(In(ctx, s)), U64, Bool, Out(In(ctx, s)), Tx -> (Inst(ctx), Out(ctx), Tx)
state_settle = |block, depth, local, out, tx| {
	match out {
		Done => crash "internal: fire must hand the environment back"
		Orphaned(_) => crash "internal: fire must hand the environment back"
		Pending(next_inner, mask) => {
			{ outer: next_outer, value: s2 } = next_inner
			own = bit(depth)
			above = mask.bitwise_and(own - 1)
			if !local or above != 0 or mask.bitwise_and(own) == 0 {
				# Hand the change up: the root (or the outer layer that
				# changed) runs the Changed pass once the event has unwound.
				(state_inst(s2, block, depth, local), Pending(next_outer, mask), tx)
			} else {
				# Every write of the turn is in place by now, and a component's
				# sinks can write several nested layers in one turn: refresh
				# this layer and every written layer below it, which no one
				# above will see again.
				written = mask.bitwise_and((own - 1).bitwise_not())
				(b3, t3) = refresh(block, In.{ outer: next_outer, value: s2 }, written, bump(tx, w_dirty_roots, popcount(written)))
				(state_inst(s2, b3, depth, local), Pending(next_outer, 0), t3)
			}
		}
	}
}

## A state site: `s` is this layer's value at absolute depth `depth`.
state_inst : s, Block(In(ctx, s)), U64, Bool -> Inst(ctx)
state_inst = |s0, block0, depth0, local0| {
	held = Held({ s: s0, block: block0, depth: depth0, local: local0 })
	Inst(
		|env, msg, tx| {
			Held({ s, block, depth, local }) = held
			match msg {
				Changed(mask) => {
					(b2, t2) = refresh(block, In.{ outer: env, value: s }, mask, tx)
					(state_inst(s, b2, depth, local), Done, t2)
				}
				Fire(path, pos, h, payload) => {
					# `s` moves into the environment here and is never used again on
					# this path, so a reducer below sees it uniquely owned.
					match fire_target(block, path, pos) {
						Leaf => state_settle(block, depth, local, fire_leaf(block, In.{ outer: env, value: s }, h, payload), tx)
						Kid => {
							(b2, out, t2) = fire_kid(block, In.{ outer: env, value: s }, path, pos, h, payload, tx)
							state_settle(b2, depth, local, out, t2)
						}
						Miss => state_settle(block, depth, local, Pending(In.{ outer: env, value: s }, 0), tx)
					}
				}
				Dispose(remove) => {
					(orph, t2) = dispose_block(block, In.{ outer: env, value: s }, remove, tx)
					(noop({}), Orphaned(lower_in(orph, s, depth)), t2)
				}
			}
		},
	)
}

## A conditional site. The branch is rebuilt when the condition changes.
When(ctx) : { cond : Val(ctx, Bool), yes : (() -> Elem(ctx)), no : (() -> Elem(ctx)), anchor : U32, depth : U64, path : List(U32), cap : U64, local : Bool }

## `adopted`: orphans reparented to this site when a branch it disposed
## left admitted requests behind.
when_inst : When(ctx), Bool, List(Orphan(ctx)), Block(ctx) -> Inst(ctx)
when_inst = |w0, cur0, adopted0, block0| {
	held = Held({ w: w0, cur: cur0, adopted: adopted0, block: block0 })
	Inst(
		|env, msg, tx| {
			Held({ w, cur, adopted, block }) = held
			match msg {
				Changed(mask) => {
					cm = eff_mask(w.cond)
					if cm.bitwise_and(mask) != 0 {
						c = (w.cond.read)(env)
						t1 = count_evals(tx, 1)
						if c == cur {
							(b2, t2) = refresh(block, env, mask, t1)
							(when_inst(w, cur, adopted, b2), Done, t2)
						} else {
							(orph, t2) = dispose_block(block, env, True, bump(bump(t1, w_scopes_disposed, 1), w_scopes_created, 1))
							elem = if (c) (w.yes)() else (w.no)()
							(b3, t3) = mount_block(env, elem, w.depth, w.path, 0, w.anchor, { cap: w.cap, local: w.local }, fx_adopt(t2, w.path, orph))
							(when_inst(w, c, adopted.concat(orph), b3), Done, t3)
						}
					} else {
						(b2, t2) = refresh(block, env, mask, tx)
						(when_inst(w, cur, adopted, b2), Done, t2)
					}
				}
				Fire(path, pos, h, payload) => {
					match leaf_fx(path, pos, payload) {
						Ok(res) => {
							(ad2, out, t2) = adopt_deliver(adopted, env, h, res, tx)
							(when_inst(w, cur, ad2, block), out, t2)
						}
						Err(_) => {
							match fire_target(block, path, pos) {
								Leaf => {
									out = fire_leaf(block, env, h, payload)
									(when_inst(w, cur, adopted, block), out, tx)
								}
								Kid => {
									(b2, out, t2) = fire_kid(block, env, path, pos, h, payload, tx)
									(when_inst(w, cur, adopted, b2), out, t2)
								}
								Miss => (when_inst(w, cur, adopted, block), Pending(env, 0), tx)
							}
						}
					}
				}
				Dispose(remove) => {
					(orph, t1) = dispose_block(block, env, remove, bump(tx, w_scopes_disposed, 1))
					t2 = if (remove) emit_op(t1, 5, |c| put_u32(c, w.anchor)) else t1
					(noop({}), Orphaned(adopted.concat(orph)), free_id(t2, w.anchor))
				}
			}
		},
	)
}

## A plain block site (the root).
block_inst : Block(ctx) -> Inst(ctx)
block_inst = |block0| {
	held = Held({ block: block0 })
	Inst(
		|env, msg, tx| {
			Held({ block }) = held
			match msg {
				Changed(mask) => {
					(b2, t2) = refresh(block, env, mask, tx)
					(block_inst(b2), Done, t2)
				}
				Fire(path, pos, h, payload) => {
					match fire_target(block, path, pos) {
						Leaf => {
							out = fire_leaf(block, env, h, payload)
							(block_inst(block), out, tx)
						}
						Kid => {
							(b2, out, t2) = fire_kid(block, env, path, pos, h, payload, tx)
							(block_inst(b2), out, t2)
						}
						Miss => (block_inst(block), Pending(env, 0), tx)
					}
				}
				Dispose(remove) => {
					(orph, t2) = dispose_block(block, env, remove, tx)
					(noop({}), Orphaned(orph), t2)
				}
			}
		},
	)
}

## ------------------------------------------------------------------
## Key index: open addressing Str key -> slot (linear probing, backward
## shift delete). `hs` holds the key hash, `vals` slot + 1 (0 = empty);
## keys are compared against the site's key column. Load factor <= 1/2.
## `by_slot[slot]` is the hash of the key the slot holds, so removing a
## row never hashes its key again.
KeyIndex : { hs : List(U64), vals : List(U32), count : U64, bits : U8, by_slot : List(U64) }

index_empty : KeyIndex
index_empty = { hs: [], vals: [], count: 0, bits: 0, by_slot: [] }

hash_str : Str -> U64
hash_str = |s| {
	var $h = 14695981039346656037.U64
	for b in s.iter_utf8() {
		$h = $h.bitwise_xor(b.to_u64()).times_wrap(1099511628211)
	}
	$h
}

bucket : U64, U8 -> U64
bucket = |h, bits| h.times_wrap(11400714819323198485).shr_zf_wrap(64 - bits)

index_find : KeyIndex, List(Str), Str, U64 -> Try(U32, [Missing])
index_find = |index, keys, key, h| index_probe(index, keys, key, h).found

## A lookup that also reports how many stored keys it compared with the
## probe in full (only entries whose hash matches are compared).
index_probe : KeyIndex, List(Str), Str, U64 -> { found : Try(U32, [Missing]), compares : U64 }
index_probe = |index, keys, key, h| {
	if index.count == 0 {
		return { found: Err(Missing), compares: 0 }
	}
	mask = ((1.U64).shl_wrap(index.bits)) - 1
	var $b = bucket(h, index.bits)
	var $n = 0.U64
	while True {
		v = index.vals.get($b) ?? 0
		if v == 0 {
			return { found: Err(Missing), compares: $n }
		}
		if (index.hs.get($b) ?? 0) == h {
			$n = $n + 1
			if (keys.get((v - 1).to_u64()) ?? "") == key {
				return { found: Ok(v - 1), compares: $n }
			}
		}
		$b = ($b + 1).bitwise_and(mask)
	}
}

raw_insert : List(U64), List(U32), U8, U64, U32 -> { hs : List(U64), vals : List(U32) }
raw_insert = |hs, vals, bits, h, slot| {
	mask = ((1.U64).shl_wrap(bits)) - 1
	var $b = bucket(h, bits)
	while (vals.get($b) ?? 0) != 0 {
		$b = ($b + 1).bitwise_and(mask)
	}
	{ hs: hs.set($b, h) ?? crash "index bucket", vals: vals.set($b, slot + 1) ?? crash "index bucket" }
}

## The table at the next size (`by_slot` is not part of it: it stays out
## of this branch so it is never treated as borrowed, roc-lang/roc#12846).
Table : { hs : List(U64), vals : List(U32), count : U64, bits : U8 }

grow : Table -> Table
grow = |{ hs, vals, count, bits }| {
	new_bits = if (bits == 0) 4 else bits + 1
	size = (1.U64).shl_wrap(new_bits)
	var $h = List.repeat(0.U64, size)
	var $v = List.repeat(0.U32, size)
	var $i = 0.U64
	while $i < vals.len() {
		v = vals.get($i) ?? 0
		if v != 0 {
			r = raw_insert($h, $v, new_bits, hs.get($i) ?? 0, v - 1)
			$h = r.hs
			$v = r.vals
		}
		$i = $i + 1
	}
	{ hs: $h, vals: $v, count, bits: new_bits }
}

## Insert a fresh key (the key column must already hold it at `slot`)
## whose hash is `h`. A duplicate key is a contract error, never an
## alias. Also returns the full-key comparisons the duplicate check made.
index_insert : KeyIndex, List(Str), Str, U64, U32, List(U32) -> (KeyIndex, U64)
index_insert = |index, keys, key, h, slot, path| {
	probe = index_probe(index, keys, key, h)
	match probe.found {
		Ok(_) => crash dup_key(path, key)
		Err(Missing) => {}
	}
	{ hs: hs0, vals: vals0, count: count0, bits: bits0, by_slot } = index
	table = { hs: hs0, vals: vals0, count: count0, bits: bits0 }
	grown = if ((count0 + 1) * 2 > (1.U64).shl_wrap(bits0)) grow(table) else table
	{ hs, vals, count, bits } = grown
	r = raw_insert(hs, vals, bits, h, slot)
	({ hs: r.hs, vals: r.vals, count: count + 1, bits, by_slot: put_at(by_slot, slot.to_u64(), h) }, probe.compares)
}

index_remove : KeyIndex, U32 -> KeyIndex
index_remove = |{ hs, vals, count, bits, by_slot }, slot| {
	if count == 0 {
		crash "internal: remove of missing key"
	}
	mask = ((1.U64).shl_wrap(bits)) - 1
	h = by_slot.get(slot.to_u64()) ?? crash "internal: remove of missing key"
	var $b = bucket(h, bits)
	while (vals.get($b) ?? 0) != slot + 1 {
		if (vals.get($b) ?? 0) == 0 {
			crash "internal: remove of missing key"
		}
		$b = ($b + 1).bitwise_and(mask)
	}
	var $h = hs
	var $v = vals
	var $hole = $b
	var $j = ($b + 1).bitwise_and(mask)
	while ($v.get($j) ?? 0) != 0 {
		jh = $h.get($j) ?? 0
		home = bucket(jh, bits)
		dist_home = ($j + mask + 1 - home).bitwise_and(mask)
		dist_hole = ($j + mask + 1 - $hole).bitwise_and(mask)
		if dist_home >= dist_hole {
			$h = $h.set($hole, jh) ?? crash "index"
			$v = $v.set($hole, $v.get($j) ?? 0) ?? crash "index"
			$hole = $j
		}
		$j = ($j + 1).bitwise_and(mask)
	}
	$v = $v.set($hole, 0) ?? crash "index"
	{ hs: $h, vals: $v, count: count - 1, bits, by_slot }
}

## ------------------------------------------------------------------
## Row templates, compiled once per each site.
##
## Template encoding: node := 1 tag:str nattr:u8 (name:str value:str)*
## nchild:u8 node* | 2 text:str; then nholes:u8, each hole := kind:u8
## depth:u8 path:u8* [attr: name:str | click: handler:u8].
## Hole kinds: 1 text, 2 attr, 3 click, 4 bind (placeholder for a nested
## site). `col` is the value column for text/attr holes whose value can
## change (none for row-constant holes), the handler index for clicks and
## the mount index for binds.
## `ctl`: the work counter an attribute hole's updates also count in
## (`w_set_value`, `w_set_checked`), or 0.
RHole(ctx) : { kind : U8, mask : U64, smask : U64, skey : (ctx -> Str), read : (ctx -> Str), col : U64, live : Bool, ctl : U64 }

Plan(ctx) : {
	tree : List(U8),
	htab : List(U8),
	holes : List(RHole(ctx)),
	handlers : List(Handler(ctx)),
	mounts : List(Mount(ctx)),
	ncols : U64,
	kreads : U64,
}

plan_empty : {} -> Plan(ctx)
plan_empty = |_| { tree: [], htab: [], holes: [], handlers: [], mounts: [], ncols: 0, kreads: 0 }

put_path : List(U8), U8, List(U8) -> List(U8)
put_path = |buf, kind, path| buf.append(kind).append(narrow(path.len(), "nesting depth of a hole")).concat(path)

## A count the template encoding carries in one byte (design.md, Appendix
## B). Beyond 255 it is a resource limit, never a wrap.
narrow : U64, Str -> U8
narrow = |n, what| if (n > 255) crash "resource_limit: a row template's ${what} is ${n.to_str()}; the template encoding allows at most 255" else n.to_u8_wrap()

val_hole : Plan(ctx), U8, Str, Val(ctx, Str), List(U8) -> Plan(ctx)
val_hole = |{ tree, htab, holes, handlers, mounts, ncols, kreads }, kind, name, v, extra| {
	{ mask, read, sel } = v
	(smask, skey) = match sel {
		NoSel => (0, |_| "")
		Sel(m, k) => (m, k)
	}
	live = mask.bitwise_or(smask) != 0
	hole = { kind, mask, smask, skey, read, col: if (live) ncols else 0, live, ctl: ctl_of(name) }
	{ tree, htab: htab.concat(extra), holes: holes.append(hole), handlers, mounts, ncols: if (live) ncols + 1 else ncols, kreads }
}

compile_elem : Plan(ctx), Elem(ctx), List(U8), U64 -> Plan(ctx)
compile_elem = |plan, elem, path, depth| {
	match elem {
		Element(tag, attrs, kids) => {
			var $nstatic = 0.U64
			for a0 in attrs {
				match a0 {
					Static(_, _) => {
						$nstatic = $nstatic + 1
					}
					_ => {}
				}
			}
			nstatic = $nstatic
			var $p = plan
			{ tree, htab, holes, handlers, mounts, ncols, kreads } = $p
			var $tree = put_str(tree.append(1), tag).append(narrow(nstatic, "static attributes on one element"))
			var $htab = htab
			var $holes = holes
			var $handlers = handlers
			var $ncols = ncols
			for a in attrs {
				match a {
					Static(name, value) => {
						$tree = put_str(put_str($tree, name), value)
					}
					Dyn(name, v) => {
						r = val_hole({ tree: [], htab: [], holes: $holes, handlers: [], mounts: [], ncols: $ncols, kreads: 0 }, 2, name, v, put_str(put_path([], 2, path), name))
						$htab = $htab.concat(r.htab)
						$holes = r.holes
						$ncols = r.ncols
					}
					On(ev, handler) => {
						$htab = put_str(put_path($htab, 3, path).append(narrow($handlers.len(), "event handler count")), ev)
						$holes = $holes.append({ kind: 3, mask: 0, smask: 0, skey: |_| "", read: |_| "", col: $handlers.len(), live: False, ctl: 0 })
						$handlers = $handlers.append(handler)
					}
					Ref(_) => crash "contract: focus refs are not supported inside each rows (use one in a nested site)"
				}
			}
			$tree = $tree.append(narrow(kids.len(), "children of one element"))
			$p = { tree: $tree, htab: $htab, holes: $holes, handlers: $handlers, mounts, ncols: $ncols, kreads }
			var $i = 0.U8
			for kid in kids {
				$p = compile_elem($p, kid, path.append($i), depth)
				$i = $i + 1
			}
			$p
		}
		Text(s) => {
			{ tree, htab, holes, handlers, mounts, ncols, kreads } = plan
			{ tree: put_str(tree.append(2), s), htab, holes, handlers, mounts, ncols, kreads }
		}
		TextV(v) => {
			{ tree, htab, holes, handlers, mounts, ncols, kreads } = plan
			t2 = put_str(tree.append(2), "")
			val_hole({ tree: t2, htab, holes, handlers, mounts, ncols, kreads }, 1, "", v, put_path([], 1, path))
		}
		Site(m, rf) => {
			{ tree, htab, holes, handlers, mounts, ncols, kreads } = plan
			hole = { kind: 4, mask: 0, smask: 0, skey: |_| "", read: |_| "", col: mounts.len(), live: False, ctl: 0 }
			{ tree: put_str(tree.append(2), ""), htab: put_path(htab, 4, path), holes: holes.append(hole), handlers, mounts: mounts.append(m), ncols, kreads: kreads.bitwise_or(rf(depth)) }
		}
	}
}

compile : Elem(ctx), U64 -> Plan(ctx)
compile = |elem, depth| {
	match elem {
		Element(_, _, _) => compile_elem(plan_empty({}), elem, [], depth)
		_ => crash "contract: an each row template must be a single element"
	}
}

template_bytes : Plan(ctx) -> List(U8)
template_bytes = |plan| plan.tree.append(narrow(plan.holes.len(), "hole count")).concat(plan.htab)

## ------------------------------------------------------------------
## The each site.

## Fixed per site.
EachCfg(r, item) : {
	site : U32,
	parent : U32,
	anchor : U32,
	sole : Bool,
	depth : U64,
	path : List(U32),
	key : (item -> Str),
	plan : Plan(r),
	dynamic : Bool,
	outer_mask : U64,
	sel_mask : U64,
}

## Typed row columns, indexed by slot (except `order`, by position, and
## `sels`, by hole).
Cols(r, item) : {
	items : List(item),
	keys : List(Str),
	order : List(U32),
	free : List(U32),
	index : KeyIndex,
	lasts : List(List(Str)),
	kids : List(List(Inst(r))),
	binds : List(List(U32)),
	pend : List(U64),
	dirty : List(U32),
	sels : List(Str),
	known : Bool,
	kid_mask : U64,

	## Rows dropped since the site last took them, with the orphans their
	## nested sites left (admitted requests that outlive the row).
	dropped : List({ key : Str, item : item, orphans : List(Orphan(r)) }),

	## The host node id of each slot's row element (dense node ids,
	## shared with static nodes; routes map them back to site and slot).
	rnodes : List(U32),
}

cols_empty : U64, U64 -> Cols(r, item)
cols_empty = |ncols, nholes| {
	items: [],
	keys: [],
	order: [],
	free: [],
	index: index_empty,
	lasts: List.repeat([], ncols),
	kids: [],
	binds: [],
	pend: [],
	dirty: [],
	sels: List.repeat("", nholes),
	known: False,
	kid_mask: 0,
	dropped: [],
	rnodes: [],
}

## Construction-site path for diagnostics: child positions from the root.
show_path : List(U32) -> Str
show_path = |path| "/${Str.join_with(path.map(|p| p.to_str()), "/")}"

## The diagnostic for a duplicate each key (design.md: duplicate keys are
## errors, not aliases).
dup_key : List(U32), Str -> Str
dup_key = |path, key| "contract: duplicate key \"${key}\" in each at site ${show_path(path)}"

## The node id of a live row.
node_of : Cols(r, item), U32 -> U32
node_of = |cols, slot| cols.rnodes.get(slot.to_u64()) ?? crash "internal: row node"

put_at : List(a), U64, a -> List(a)
put_at = |list, i, v| if (i == list.len()) list.append(v) else (list.set(i, v) ?? crash "column")

## Create one row at slot (fresh or reused), emit INST before `before`,
## mount its nested sites. Returns the slot.
create_row : EachCfg(r, item), Cols(r, item), (Str, item -> r), item, U32, Tx -> (Cols(r, item), U32, Tx)
	where [item.is_eq : item, item -> Bool]
create_row = |cfg, cols, env, item, before, tx| create_row_h(cfg, cols, env, item, before, Err(Unhashed), tx)

## `create_row` given the key's hash when a lookup already computed it.
create_row_h : EachCfg(r, item), Cols(r, item), (Str, item -> r), item, U32, Try(U64, [Unhashed]), Tx -> (Cols(r, item), U32, Tx)
	where [item.is_eq : item, item -> Bool]
create_row_h = |cfg, cols, env, item, before, known_hash, tx| {
	{ items, keys, order, free, index, lasts, kids, binds, pend, dirty, sels, known, kid_mask, dropped, rnodes } = cols
	key = (cfg.key)(item)
	(slot, free2) = match free.last() {
		Ok(s) => (s, free.drop_last(1))
		Err(_) => (items.len().to_u32_wrap(), free)
	}
	si = slot.to_u64()
	keys2 = put_at(keys, si, key)
	(h, hashed) = match known_hash {
		Ok(kh) => (kh, 0)
		Err(Unhashed) => (hash_str(key), 1)
	}
	(index2, key_compares) = index_insert(index, keys2, key, h, slot, cfg.path)
	items2 = put_at(items, si, item)
	pend2 = put_at(pend, si, 0)
	(node, tx0) = alloc_id(tx)
	rnodes2 = put_at(rnodes, si, node)
	row_env = env(key, item)
	{ cmds, next, free: idfree, routes, work, paths, site_free, fx } = set_row_route(tx0, node, cfg.site, slot)
	var $c = put_u32(put_u32(put_u32(put_u32(cmds.append(1), node), cfg.parent), before), cfg.site)
	var $lasts = lasts
	var $sels = sels
	var $ev = 0.U64
	# Control state carried by INST (attribute holes named value or
	# checked) counts as set, like an ATTR would.
	var $set_value = 0.U64
	var $set_checked = 0.U64
	var $t = { cmds: [], next, free: idfree, routes, work, paths, site_free, fx }
	var $bound = []
	var $hi = 0.U64
	for hole in cfg.plan.holes {
		if hole.kind == 1 or hole.kind == 2 {
			v = (hole.read)(row_env)
			$ev = $ev + 1
			if hole.ctl == w_set_value {
				$set_value = $set_value + 1
			} else if hole.ctl == w_set_checked {
				$set_checked = $set_checked + 1
			}
			$c = put_str($c, v)
			if hole.live {
				{ list, prev } = $lasts.replace(hole.col, []) ?? crash "lasts"
				$lasts = list.set(hole.col, put_at(prev, si, v)) ?? crash "lasts"
			}
			if hole.smask != 0 and !known {
				$sels = $sels.set($hi, (hole.skey)(row_env)) ?? $sels
			}
		} else if hole.kind == 4 {
			(bid, t2) = alloc_id($t)
			$t = t2
			$c = put_u32($c, bid)
			$bound = $bound.append(bid)
		}
		$hi = $hi + 1
	}
	known2 = known or cfg.sel_mask != 0
	{ cmds: _, next: n3, free: f3, routes: r3, work: w3, paths: p3, site_free: sf3, fx: fx3 } = $t
	# One INST (a row and its scope created), its hole evaluations and the
	# key hash of the index insert.
	w4 = add_work(add_work(add_work(add_work(add_work(add_work(add_work(w3, 1, 1), w_evals, $ev), w_scopes_created, 1), w_key_hashes, hashed), w_key_compares, key_compares), w_set_value, $set_value), w_set_checked, $set_checked)
	var $tx = { cmds: $c, next: n3, free: f3, routes: r3, work: w4, paths: p3, site_free: sf3, fx: fx3 }
	if cfg.dynamic {
		var $insts = []
		var $km = kid_mask
		var $j = 0.U64
		for m in cfg.plan.mounts {
			mount = match m {
				Mount(f) => f
			}
			bid = $bound.get($j) ?? crash "bind"
			(inst, reads, t4) = mount(row_env, { depth: cfg.depth, path: cfg.path.concat([slot, $j.to_u32_wrap()]), parent: 0, before: bid, sole: False, cap: cfg.plan.kreads.bitwise_or(upto(cfg.depth).bitwise_not()), local: True }, $tx)
			$insts = $insts.append(inst)
			$km = $km.bitwise_or(reads)
			$tx = t4
			$j = $j + 1
		}
		cols2 = { items: items2, keys: keys2, order, free: free2, index: index2, lasts: $lasts, kids: put_at(kids, si, $insts), binds: put_at(binds, si, $bound), pend: pend2, dirty, sels: $sels, known: known2, kid_mask: $km, dropped, rnodes: rnodes2 }
		(cols2, slot, $tx)
	} else {
		cols2 = { items: items2, keys: keys2, order, free: free2, index: index2, lasts: $lasts, kids, binds, pend: pend2, dirty, sels: $sels, known: known2, kid_mask, dropped, rnodes: rnodes2 }
		(cols2, slot, $tx)
	}
}

## Release one row's storage and nested sites. `remove` emits REMOVE.
drop_row : EachCfg(r, item), Cols(r, item), (Str, item -> r), U32, Bool, Tx -> (Cols(r, item), Tx)
drop_row = |cfg, cols, env, slot, remove, tx| {
	{ items, keys, order, free, index, lasts, kids, binds, pend, dirty, sels, known, kid_mask, dropped, rnodes } = cols
	si = slot.to_u64()
	key = keys.get(si) ?? crash "key"
	index2 = index_remove(index, slot)
	pend2 = pend.set(si, 0) ?? pend
	node = rnodes.get(si) ?? crash "internal: row node"
	t0 = if (remove) emit_op(tx, 5, |c| put_u32(c, node)) else tx
	# A row removed by reconciliation: its scope is disposed.
	t1 = bump(bump(free_id(t0, node), w_rows_removed, 1), w_scopes_disposed, 1)
	if cfg.dynamic {
		{ list: kl, prev: row_kids } = kids.replace(si, []) ?? crash "kids"
		{ list: bl, prev: row_binds } = binds.replace(si, []) ?? crash "binds"
		item = items.get(si) ?? crash "item"
		row_env = env(key, item)
		var $t = t1
		var $rk = row_kids
		var $j = 0.U64
		var $orph = []
		while $j < $rk.len() {
			{ list: rl, prev: kid } = $rk.replace($j, noop({})) ?? crash "kid"
			(_, out, t2) = call(kid, row_env, Dispose(False), $t)
			$orph = $orph.concat(orphans_of(out))
			$rk = rl
			$t = t2
			$j = $j + 1
		}
		for b in row_binds {
			$t = free_id($t, b)
		}
		dropped2 = if ($orph.is_empty()) dropped else dropped.append({ key, item, orphans: $orph })
		({ items, keys, order, free: free.append(slot), index: index2, lasts, kids: kl, binds: bl, pend: pend2, dirty, sels, known, kid_mask, dropped: dropped2, rnodes }, $t)
	} else {
		({ items, keys, order, free: free.append(slot), index: index2, lasts, kids, binds, pend: pend2, dirty, sels, known, kid_mask, dropped, rnodes }, t1)
	}
}

mark_all : Cols(r, item), U64 -> Cols(r, item)
mark_all = |cols, m| {
	(c0, order) = take_order(cols)
	var $c = c0
	for s in order {
		$c = mark($c, s, m)
	}
	set_order($c, order)
}

mark : Cols(r, item), U32, U64 -> Cols(r, item)
mark = |{ items, keys, order, free, index, lasts, kids, binds, pend, dirty, sels, known, kid_mask, dropped, rnodes }, slot, m| {
	si = slot.to_u64()
	p = pend.get(si) ?? 0
	dirty2 = if (p == 0) dirty.append(slot) else dirty
	{ items, keys, order, free, index, lasts, kids, binds, pend: pend.set(si, p.bitwise_or(m)) ?? pend, dirty: dirty2, sels, known, kid_mask, dropped, rnodes }
}

## A kept row whose new item may differ: equal items are pruned here.
## Returns 1 when the item changed (the row is marked dirty).
keep_row_n : Cols(r, item), U32, item, U64 -> (Cols(r, item), U64)
	where [item.is_eq : item, item -> Bool]
keep_row_n = |cols, slot, item, row_bit| {
	si = slot.to_u64()
	same = match cols.items.get(si) {
		Ok(old) => old == item
		Err(_) => crash "item"
	}
	if same {
		(cols, 0)
	} else {
		{ items, keys, order, free, index, lasts, kids, binds, pend, dirty, sels, known, kid_mask, dropped, rnodes } = cols
		(mark({ items: items.set(si, item) ?? crash "item", keys, order, free, index, lasts, kids, binds, pend, dirty, sels, known, kid_mask, dropped, rnodes }, slot, row_bit), 1)
	}
}

set_order : Cols(r, item), List(U32) -> Cols(r, item)
set_order = |{ items, keys, order: _, free, index, lasts, kids, binds, pend, dirty, sels, known, kid_mask, dropped, rnodes }, order| {
	{ items, keys, order, free, index, lasts, kids, binds, pend, dirty, sels, known, kid_mask, dropped, rnodes }
}

take_order : Cols(r, item) -> (Cols(r, item), List(U32))
take_order = |{ items, keys, order, free, index, lasts, kids, binds, pend, dirty, sels, known, kid_mask, dropped, rnodes }| {
	({ items, keys, order: [], free, index, lasts, kids, binds, pend, dirty, sels, known, kid_mask, dropped, rnodes }, order)
}

end_ref : EachCfg(r, item) -> U32
end_ref = |cfg| if (cfg.sole) 0 else cfg.anchor

## The node a row inserted at position `pos` (of `order`) goes before.
ref_at : EachCfg(r, item), Cols(r, item), U64 -> U32
ref_at = |cfg, cols, pos| match cols.order.get(pos) {
	Ok(s) => node_of(cols, s)
	Err(_) => end_ref(cfg)
}

key_of_slot : Cols(r, item), U32 -> Str
key_of_slot = |cols, slot| cols.keys.get(slot.to_u64()) ?? crash "key"

same_row : EachCfg(r, item), Cols(r, item), U32, item -> Bool
	where [item.is_eq : item, item -> Bool]
same_row = |cfg, cols, slot, item| {
	match cols.items.get(slot.to_u64()) {
		Ok(old) => if (old == item) True else key_of_slot(cols, slot) == (cfg.key)(item)
		Err(_) => crash "item"
	}
}

## Release every live row's node id (the DOM goes with its parent).
free_rows : Cols(r, item), Tx -> Tx
free_rows = |cols, tx| {
	var $tx = bump(tx, w_scopes_disposed, cols.order.len())
	for slot in cols.order {
		$tx = free_id($tx, node_of(cols, slot))
	}
	$tx
}

## Remove every row.
clear_rows : EachCfg(r, item), Cols(r, item), (Str, item -> r), Bool, Tx -> (Cols(r, item), Tx)
clear_rows = |cfg, cols, env, dom, tx| {
	var $tx = bump(tx, w_scopes_disposed, cols.order.len())
	var $dropped = []
	if !dom {
		{}
	} else if cfg.sole {
		$tx = emit_op($tx, 6, |c| put_u32(put_u32(c, cfg.parent), cfg.site))
	} else {
		for slot in cols.order {
			$tx = emit_op($tx, 5, |c| put_u32(c, node_of(cols, slot)))
		}
	}
	for slot in cols.order {
		$tx = free_id($tx, node_of(cols, slot))
	}
	if cfg.dynamic {
		var $i = 0.U64
		while $i < cols.kids.len() {
			live = match cols.items.get($i) {
				Ok(item) => {
					key = cols.keys.get($i) ?? ""
					match index_find(cols.index, cols.keys, key, hash_str(key)) {
						Ok(s) => if (s.to_u64() == $i) Ok(item) else Err(Dead)
						Err(_) => Err(Dead)
					}
				}
				Err(_) => Err(Dead)
			}
			match live {
				Ok(item) => {
					key = cols.keys.get($i) ?? ""
					row_env = env(key, item)
					var $rk = cols.kids.get($i) ?? []
					var $j = 0.U64
					var $orph = []
					while $j < $rk.len() {
						{ list: rl, prev: kid } = $rk.replace($j, noop({})) ?? crash "kid"
						(_, out, t2) = call(kid, row_env, Dispose(False), $tx)
						$orph = $orph.concat(orphans_of(out))
						$rk = rl
						$tx = t2
						$j = $j + 1
					}
					if !$orph.is_empty() {
						$dropped = $dropped.append({ key, item, orphans: $orph })
					}
					for b in cols.binds.get($i) ?? [] {
						$tx = free_id($tx, b)
					}
				}
				Err(Dead) => {}
			}
			$i = $i + 1
		}
	}
	{ sels, known, kid_mask, lasts, dropped: dropped0, items: _, keys: _, order: _, free: _, index: _, kids: _, binds: _, pend: _, dirty: _, rnodes: _ } = cols
	dropped = dropped0.concat($dropped)
	ncols = lasts.len()
	({ items: [], keys: [], order: [], free: [], index: index_empty, lasts: List.repeat([], ncols), kids: [], binds: [], pend: [], dirty: [], sels, known, kid_mask, dropped, rnodes: [] }, $tx)
}

## Append rows new_list[from..] at the end of the site.
append_rows : EachCfg(r, item), Cols(r, item), (Str, item -> r), List(item), U64, Tx -> (Cols(r, item), Tx)
	where [item.is_eq : item, item -> Bool]
append_rows = |cfg, cols, env, list, from, tx| {
	var $cols = cols
	var $tx = tx
	var $i = from
	before = end_ref(cfg)
	while $i < list.len() {
		item = list.get($i) ?? crash "row"
		(c2, slot, t2) = create_row(cfg, $cols, env, item, before, $tx)
		(c3, order) = take_order(c2)
		$cols = set_order(c3, order.append(slot))
		$tx = t2
		$i = $i + 1
	}
	($cols, $tx)
}

## Keyed reconciliation of the site's rows against `list`. Fast paths:
## common prefix and suffix, swapped ends, pure insertion and pure
## removal; anything else falls back to a keyed move with an LIS.
## Reconcile and count the rows kept (`rows_reused`): the old rows that
## were not removed. Every reconciliation counts, including one whose new
## list is equal to the old: the engine keeps no previous list to prune
## by (design.md, "In-place ownership").
reconcile : EachCfg(r, item), Cols(r, item), (Str, item -> r), List(item), Tx -> (Cols(r, item), Tx)
	where [item.is_eq : item, item -> Bool]
reconcile = |cfg, cols, env, list, tx| {
	n_old = cols.order.len()
	w0 = change_marks(tx)
	(c2, t2) = reconcile_rows(cfg, cols, env, list, tx)
	w2 = change_marks(t2)
	# An equal new list (nothing created, moved, removed or changed)
	# reconciled nothing and reuses nothing. The accumulator is rebuilt
	# on both paths (roc-lang/roc#12846).
	reused = if (w2 == w0) 0 else n_old - (w2.removed - w0.removed)
	(c2, bump(t2, w_rows_reused, reused))
}

## The counters a reconciliation moves when the list changed: rows
## created, moved, removed, or kept with a changed item.
change_marks : Tx -> { created : U64, moved : U64, removed : U64, updated : U64 }
change_marks = |tx| {
	w = tx.work
	{ created: w.c01, moved: w.c04, removed: work_get(w, w_rows_removed), updated: work_get(w, w_rows_updated) }
}

reconcile_rows : EachCfg(r, item), Cols(r, item), (Str, item -> r), List(item), Tx -> (Cols(r, item), Tx)
	where [item.is_eq : item, item -> Bool]
reconcile_rows = |cfg, cols, env, list, tx| {
	n_old = cols.order.len()
	n_new = list.len()
	row_bit = bit(cfg.depth)
	if n_new == 0 {
		if (n_old == 0) (cols, tx) else clear_rows(cfg, cols, env, True, bump(tx, w_rows_removed, n_old))
	} else if n_old == 0 {
		append_rows(cfg, cols, env, list, 0, tx)
	} else {
		var $cols = cols
		var $tx = tx
		# Kept rows whose item changed, counted once after the loops so the
		# accumulator is not threaded through every kept row.
		var $updated = 0.U64
		var $i = 0.U64
		var $oe = n_old
		var $ne = n_new
		var $go = True
		while $go {
			# common prefix
			var $p = True
			while $p and $i < $oe and $i < $ne {
				slot = $cols.order.get($i) ?? crash "order"
				item = list.get($i) ?? crash "row"
				if same_row(cfg, $cols, slot, item) {
					(c2, u) = keep_row_n($cols, slot, item, row_bit)
					$cols = c2
					$updated = $updated + u
					$i = $i + 1
				} else {
					$p = False
				}
			}
			# common suffix
			var $q = True
			while $q and $i < $oe and $i < $ne {
				slot = $cols.order.get($oe - 1) ?? crash "order"
				item = list.get($ne - 1) ?? crash "row"
				if same_row(cfg, $cols, slot, item) {
					(c2, u) = keep_row_n($cols, slot, item, row_bit)
					$cols = c2
					$updated = $updated + u
					$oe = $oe - 1
					$ne = $ne - 1
				} else {
					$q = False
				}
			}
			# swapped ends
			$go = False
			if $oe - $i >= 2 and $ne - $i >= 2 and $i < $oe and $i < $ne {
				a = $cols.order.get($i) ?? crash "order"
				b = $cols.order.get($oe - 1) ?? crash "order"
				first = list.get($i) ?? crash "row"
				last = list.get($ne - 1) ?? crash "row"
				if same_row(cfg, $cols, b, first) and same_row(cfg, $cols, a, last) {
					na = node_of($cols, a)
					nb = node_of($cols, b)
					after = ref_at(cfg, $cols, $oe)
					$tx = emit_op(emit_op($tx, 4, |c| put_u32(put_u32(c, nb), na)), 4, |c| put_u32(put_u32(c, na), after))
					(c3, u3) = keep_row_n($cols, b, first, row_bit)
					(c4, u4) = keep_row_n(c3, a, last, row_bit)
					$cols = c4
					$updated = $updated + u3 + u4
					(c2, order) = take_order($cols)
					$cols = set_order(c2, order.swap($i, $oe - 1) ?? crash "order")
					$i = $i + 1
					$oe = $oe - 1
					$ne = $ne - 1
					$go = True
				}
			}
		}
		$tx = bump($tx, w_rows_updated, $updated)
		if $i == $oe and $i == $ne {
			($cols, $tx)
		} else if $i == $oe {
			# pure insertion of list[i..ne) before position oe
			if $oe == $cols.order.len() {
				append_rows(cfg, $cols, env, list, $i, $tx)
			} else {
				before = ref_at(cfg, $cols, $oe)
				var $new_slots = []
				var $k = $i
				while $k < $ne {
					item = list.get($k) ?? crash "row"
					(c2, slot, t2) = create_row(cfg, $cols, env, item, before, $tx)
					$cols = c2
					$tx = t2
					$new_slots = $new_slots.append(slot)
					$k = $k + 1
				}
				(c3, order) = take_order($cols)
				merged = order.sublist({ start: 0, len: $i }).concat($new_slots).concat(order.sublist({ start: $oe, len: order.len() - $oe }))
				(set_order(c3, merged), $tx)
			}
		} else if $i == $ne {
			# pure removal of order[i..oe)
			var $k = $i
			while $k < $oe {
				slot = $cols.order.get($k) ?? crash "order"
				(c2, t2) = drop_row(cfg, $cols, env, slot, True, $tx)
				$cols = c2
				$tx = t2
				$k = $k + 1
			}
			(c3, order) = take_order($cols)
			kept = if ($oe - $i == 1) order.drop_at($i) else order.sublist({ start: 0, len: $i }).concat(order.sublist({ start: $oe, len: order.len() - $oe }))
			(set_order(c3, kept), $tx)
		} else {
			reconcile_general(cfg, $cols, env, list, $i, $oe, $ne, $tx)
		}
	}
}

## General keyed reconciliation of the middle ranges old order[i..oe) and
## new list[i..ne). Allocates scratch proportional to the site.
reconcile_general : EachCfg(r, item), Cols(r, item), (Str, item -> r), List(item), U64, U64, U64, Tx -> (Cols(r, item), Tx)
	where [item.is_eq : item, item -> Bool]
reconcile_general = |cfg, cols, env, list, i, oe, ne, tx| {
	row_bit = bit(cfg.depth)
	nslots = cols.items.len()
	# old position of every slot in the old middle (+1; 0 = not in middle)
	var $oldpos = List.repeat(0.U64, nslots)
	var $k = i
	while $k < oe {
		s = cols.order.get($k) ?? crash "order"
		$oldpos = $oldpos.set(s.to_u64(), $k + 1) ?? crash "pos"
		$k = $k + 1
	}
	# match new middle keys to existing slots
	var $found = []
	var $seen = List.repeat(False, nslots)
	var $compares = 0.U64
	var $hashes = []
	$k = i
	while $k < ne {
		item = list.get($k) ?? crash "row"
		key = (cfg.key)(item)
		h = hash_str(key)
		$hashes = $hashes.append(h)
		probe = index_probe(cols.index, cols.keys, key, h)
		$compares = $compares + probe.compares
		r = match probe.found {
			Ok(s) => {
				if ($oldpos.get(s.to_u64()) ?? 0) == 0 {
					crash dup_key(cfg.path, key)
				}
				if $seen.get(s.to_u64()) ?? False {
					crash dup_key(cfg.path, key)
				}
				$seen = $seen.set(s.to_u64(), True) ?? $seen
				s.to_u64() + 1
			}
			Err(Missing) => 0
		}
		$found = $found.append(r)
		$k = $k + 1
	}
	# drop old middle rows that are gone
	var $cols = cols
	var $tx = bump(bump(tx, w_key_hashes, ne - i), w_key_compares, $compares)
	$k = i
	while $k < oe {
		s = cols.order.get($k) ?? crash "order"
		if !($seen.get(s.to_u64()) ?? False) {
			(c2, t2) = drop_row(cfg, $cols, env, s, True, $tx)
			$cols = c2
			$tx = t2
		}
		$k = $k + 1
	}
	# longest increasing subsequence of old positions among kept rows
	var $seq = []
	for f in $found {
		$seq = $seq.append(if (f == 0) 0 else $oldpos.get(f - 1) ?? 0)
	}
	stable = lis_mark($seq)
	# place from the end
	var $slots = List.repeat(0.U32, ne - i)
	var $updated = 0.U64
	var $ref = ref_at(cfg, $cols, oe)
	var $p = ne
	while $p > i {
		$p = $p - 1
		idx = $p - i
		item = list.get($p) ?? crash "row"
		f = $found.get(idx) ?? 0
		if f == 0 {
			(c2, slot, t2) = create_row_h(cfg, $cols, env, item, $ref, Ok($hashes.get(idx) ?? crash "internal: hash"), $tx)
			$cols = c2
			$tx = t2
			$slots = $slots.set(idx, slot) ?? $slots
			$ref = node_of($cols, slot)
		} else {
			slot = (f - 1).to_u32_wrap()
			node = node_of($cols, slot)
			if !(stable.get(idx) ?? False) {
				r = $ref
				$tx = emit_op($tx, 4, |c| put_u32(put_u32(c, node), r))
			}
			(c4, u4) = keep_row_n($cols, slot, item, row_bit)
			$cols = c4
			$updated = $updated + u4
			$slots = $slots.set(idx, slot) ?? $slots
			$ref = node
		}
	}
	(c3, order) = take_order($cols)
	merged = order.sublist({ start: 0, len: i }).concat($slots).concat(order.sublist({ start: oe, len: order.len() - oe }))
	(set_order(c3, merged), bump($tx, w_rows_updated, $updated))
}

## Mark the members of one longest strictly increasing subsequence of the
## nonzero entries of `seq` (zeros are new rows and never stable).
lis_mark : List(U64) -> List(Bool)
lis_mark = |seq| {
	n = seq.len()
	var $tails = []
	var $prev = List.repeat(0.U64, n)
	var $i = 0.U64
	while $i < n {
		v = seq.get($i) ?? 0
		if v != 0 {
			# binary search the first tail whose value >= v
			var $lo = 0.U64
			var $hi = $tails.len()
			while $lo < $hi {
				mid = ($lo + $hi) // 2
				tv = seq.get($tails.get(mid) ?? 0) ?? 0
				if tv < v {
					$lo = mid + 1
				} else {
					$hi = mid
				}
			}
			p = if ($lo > 0) ($tails.get($lo - 1) ?? 0) + 1 else 0
			$prev = $prev.set($i, p) ?? $prev
			$tails = if ($lo == $tails.len()) $tails.append($i) else ($tails.set($lo, $i) ?? $tails)
		}
		$i = $i + 1
	}
	var $out = List.repeat(False, n)
	var $cur = match $tails.last() {
		Ok(t) => t + 1
		Err(_) => 0
	}
	while $cur != 0 {
		$out = $out.set($cur - 1, True) ?? $out
		$cur = $prev.get($cur - 1) ?? 0
	}
	$out
}

## Evaluate the marked holes of the dirty rows and forward changes to
## their nested sites.
settle : EachCfg(r, item), Cols(r, item), (Str, item -> r), Tx -> (Cols(r, item), Tx)
settle = |cfg, cols, env, tx| {
	{ items, keys, order, free, index, lasts, kids, binds, pend, dirty, sels, known, kid_mask, dropped, rnodes } = cols
	var $lasts = lasts
	var $pend = pend
	var $kids = kids
	var $tx = tx
	# Hole evaluations, counted once after the loop.
	var $evals = 0.U64
	for slot in dirty {
		si = slot.to_u64()
		m = $pend.get(si) ?? 0
		$pend = $pend.set(si, 0) ?? $pend
		key = keys.get(si) ?? crash "key"
		item = items.get(si) ?? crash "item"
		row_env = env(key, item)
		node = rnodes.get(si) ?? crash "internal: row node"
		var $hi = 0.U64
		for hole in cfg.plan.holes {
			if hole.live and hole.mask.bitwise_or(hole.smask).bitwise_and(m) != 0 {
				v = (hole.read)(row_env)
				{ list, prev } = $lasts.replace(hole.col, []) ?? crash "lasts"
				old = prev.get(si) ?? ""
				$evals = $evals + 1
				if v == old {
					$lasts = list.set(hole.col, prev) ?? crash "lasts"
				} else {
					op = if (hole.kind == 1) 2 else 3
					hidx = $hi.to_u8_wrap()
					$tx = emit_op(bump($tx, hole.ctl, 1), op, |c| put_str(put_u32(c, node).append(hidx), v))
					$lasts = list.set(hole.col, prev.set(si, v) ?? crash "lasts") ?? crash "lasts"
				}
			}
			$hi = $hi + 1
		}
		if cfg.dynamic and (m == every_layer or kid_mask.bitwise_and(m) != 0) {
			{ list: kl, prev: row_kids } = $kids.replace(si, []) ?? crash "kids"
			var $rk = row_kids
			var $j = 0.U64
			while $j < $rk.len() {
				{ list: rl, prev: kid } = $rk.replace($j, noop({})) ?? crash "kid"
				(k2, _, t2) = call(kid, row_env, Changed(m), $tx)
				$rk = rl.set($j, k2) ?? crash "kid"
				$tx = t2
				$j = $j + 1
			}
			$kids = kl.set(si, $rk) ?? crash "kids"
		}
	}
	({ items, keys, order, free, index, lasts: $lasts, kids: $kids, binds, pend: $pend, dirty: dirty.clear(), sels, known, kid_mask, dropped, rnodes }, count_evals($tx, $evals))
}

## Selection changed: mark only the previously and newly selected rows.
select_changed : EachCfg(r, item), Cols(r, item), (Str, item -> r), U64 -> Cols(r, item)
select_changed = |cfg, cols, env, mask| {
	first = cols.order.first()
	match first {
		Err(_) => {
			{ items, keys, order, free, index, lasts, kids, binds, pend, dirty, sels, known: _, kid_mask, dropped, rnodes } = cols
			{ items, keys, order, free, index, lasts, kids, binds, pend, dirty, sels, known: False, kid_mask, dropped, rnodes }
		}
		Ok(s0) => {
			key0 = cols.keys.get(s0.to_u64()) ?? crash "key"
			item0 = cols.items.get(s0.to_u64()) ?? crash "item"
			probe = env(key0, item0)
			var $cols = cols
			var $hi = 0.U64
			for hole in cfg.plan.holes {
				if hole.smask.bitwise_and(mask) != 0 {
					nk = (hole.skey)(probe)
					ok = $cols.sels.get($hi) ?? ""
					if !$cols.known or nk != ok {
						if $cols.known {
							match index_find($cols.index, $cols.keys, ok, hash_str(ok)) {
								Ok(s) => {
									$cols = mark($cols, s, hole.smask)
								}
								Err(_) => {}
							}
						} else {
							# Unknown previous selection: every row may be stale.
							$cols = mark_all($cols, hole.smask)
						}
						match index_find($cols.index, $cols.keys, nk, hash_str(nk)) {
							Ok(s) => {
								$cols = mark($cols, s, hole.smask)
							}
							Err(_) => {}
						}
						{ items, keys, order, free, index, lasts, kids, binds, pend, dirty, sels, known: _, kid_mask, dropped, rnodes } = $cols
						$cols = { items, keys, order, free, index, lasts, kids, binds, pend, dirty, sels: sels.set($hi, nk) ?? sels, known: True, kid_mask, dropped, rnodes }
					}
				}
				$hi = $hi + 1
			}
			$cols
		}
	}
}

is_live : Cols(r, item), U64 -> Bool
is_live = |cols, si| {
	match cols.keys.get(si) {
		Ok(key) => {
			match index_find(cols.index, cols.keys, key, hash_str(key)) {
				Ok(s) => s.to_u64() == si
				Err(_) => False
			}
		}
		Err(_) => False
	}
}

## Route an event into nested site `path[pos + 1]` of row slot `si`.
## Takes the columns owned and hands back only the outer environment, so
## nothing that references the columns or the row item is alive when the
## site is rebuilt (roc-lang/roc#12846 class).
each_fire_kid : Cols(Row(ctx, item), item), Row(ctx, item), U64, List(U32), U64, U32, Payload, Tx -> (Cols(Row(ctx, item), item), ctx, U64, Tx)
each_fire_kid = |cols, row_env, si, path, pos, h, payload, tx| {
	j = (path.get(pos + 1) ?? 0).to_u64()
	{ items, keys, order, free, index, lasts, kids, binds, pend, dirty, sels, known, kid_mask, dropped, rnodes } = cols
	{ list: kl, prev: row_kids } = kids.replace(si, []) ?? crash "kids"
	if j < row_kids.len() {
		{ list: rl, prev: kid } = row_kids.replace(j, noop({})) ?? crash "kid"
		(k2, out, t2) = call(kid, row_env, Fire(path, pos + 2, h, payload), tx)
		kids2 = kl.set(si, rl.set(j, k2) ?? crash "kid") ?? crash "kids"
		(outer, m) = row_out(out)
		({ items, keys, order, free, index, lasts, kids: kids2, binds, pend, dirty, sels, known, kid_mask, dropped, rnodes }, outer, m, t2)
	} else {
		{ outer, key: _, item: _ } = row_env
		({ items, keys, order, free, index, lasts, kids: kl.set(si, row_kids) ?? crash "kids", binds, pend, dirty, sels, known, kid_mask, dropped, rnodes }, outer, 0, tx)
	}
}

row_out : Out(Row(ctx, item)) -> (ctx, U64)
row_out = |out| match out {
	Pending(e2, m) => {
		{ outer, key: _, item: _ } = e2
		(outer, m)
	}
	Done => crash "internal: fire must hand the environment back"
	Orphaned(_) => crash "internal: fire must hand the environment back"
}

## `adopted`: orphans reparented here from removed rows.
each_inst : EachCfg(Row(ctx, item), item), Val(ctx, List(item)), List(Orphan(ctx)), Cols(Row(ctx, item), item) -> Inst(ctx)
	where [item.is_eq : item, item -> Bool]
each_inst = |cfg0, rows0, adopted0, cols0| {
	held = Held({ cfg: cfg0, rows: rows0, adopted: adopted0, cols: cols0 })
	Inst(
		|env, msg, tx| {
			Held({ cfg, rows, adopted, cols }) = held
			mk = |k, it| Row.{ outer: env, key: k, item: it }
			match msg {
				Changed(mask) => {
					# Mark existing rows first (outer layers, then the keyed selector),
					# then reconcile: rows created now are evaluated once, at creation;
					# rows removed now drop their marks. Rows settle their own layer
					# locally, so `every_layer` reaches into them whole.
					full = if (mask == every_layer) every_layer else mask.bitwise_and(cfg.outer_mask.bitwise_or(cols.kid_mask)).bitwise_and(bit(cfg.depth) - 1)
					c1 = if (full != 0) mark_all(cols, full) else cols
					c2 = if (cfg.sel_mask.bitwise_and(mask) != 0) select_changed(cfg, c1, mk, mask) else c1
					rows_mask = eff_mask(rows)
					(c3, t1) = if rows_mask.bitwise_and(mask) != 0 {
						list = (rows.read)(env)
						reconcile(cfg, c2, mk, list, count_evals(tx, 1))
					} else {
						(c2, tx)
					}
					(c4, t4) = settle(cfg, c3, mk, t1)
					(c5, orph) = take_dropped(c4, cfg.depth)
					(each_inst(cfg, rows, adopted.concat(orph), c5), Done, fx_adopt(t4, cfg.path, orph))
				}
				Fire(path, pos, h, payload) => {
					slot = path.get(pos) ?? 0
					si = slot.to_u64()
					fx = leaf_fx(path, pos, payload)
					if fx.is_ok() {
						res = fx ?? crash "fx"
						(ad2, out, t2) = adopt_deliver(adopted, env, h, res, tx)
						(each_inst(cfg, rows, ad2, cols), out, t2)
					} else if !is_live(cols, si) {
						(each_inst(cfg, rows, adopted, cols), Pending(env, 0), tx)
					} else {
						key = cols.keys.get(si) ?? crash "key"
						item = cols.items.get(si) ?? crash "item"
						row_env = Row.{ outer: env, key, item }
						if pos + 1 >= path.len() {
							match cfg.plan.handlers.get(h.to_u64()) {
								Ok(handler) => {
									# Rebuild the site before running the row handler: with the
									# handler call first, --opt=speed/size treated the captured
									# columns as borrowed and every later write copied them
									# (roc-lang/roc#12846).
									next = each_inst(cfg, rows, adopted, cols)
									{ outer, key: _, item: _ } = (handler.run)(row_env, payload)
									(next, Pending(outer, handler.mask), tx)
								}
								Err(_) => {
									{ outer, key: _, item: _ } = row_env
									(each_inst(cfg, rows, adopted, cols), Pending(outer, 0), tx)
								}
							}
						} else {
							(cols2, outer, m, t2) = each_fire_kid(cols, row_env, si, path, pos, h, payload, tx)
							(each_inst(cfg, rows, adopted, cols2), Pending(outer, m), t2)
						}
					}
				}
				Dispose(remove) => {
					# Row node ids come from the shared pool: release them even when
					# nothing else needs doing for a static row set.
					(c1, t1) = if (remove or cfg.dynamic) clear_rows(cfg, cols, mk, remove, tx) else (cols, free_rows(cols, tx))
					(_, orph) = take_dropped(c1, cfg.depth)
					t2 = if !cfg.sole {
						if (remove) free_id(emit_op(t1, 5, |c| put_u32(c, cfg.anchor)), cfg.anchor) else free_id(t1, cfg.anchor)
					} else t1
					(noop({}), Orphaned(adopted.concat(orph)), free_site(t2, cfg.site))
				}
			}
		},
	)
}

## ------------------------------------------------------------------
## Static read masks: the layers an element tree can read when mounted at
## `depth`, computed without mounting it (nested sites report their own).
elem_reads : Elem(ctx), U64 -> U64
elem_reads = |elem, depth| match elem {
	Element(_, attrs, kids) => {
		var $m = 0.U64
		for a in attrs {
			match a {
				Dyn(_, v) => {
					$m = $m.bitwise_or(eff_mask(v))
				}
				_ => {}
			}
		}
		for k in kids {
			$m = $m.bitwise_or(elem_reads(k, depth))
		}
		$m
	}
	Text(_) => 0
	TextV(v) => eff_mask(v)
	Site(_, rf) => rf(depth)
}

state_handle : U64 -> State(In(ctx, s), s)
state_handle = |depth| {
	mask: bit(depth),
	get: |e| e.value,
	modify: |e, f| {
		{ outer, value } = e
		In.{ outer, value: f(value) }
	},
}

## ------------------------------------------------------------------
## A conditional over a value: the content is `body(k)` for the current
## value `k` of `sel`, rebuilt when it changes. `cases` lists every value
## `sel` can take; the site's static reads are the union over them (so it
## listens exactly), and a value outside `cases` is a contract error.
Switch(ctx, k) : { sel : Val(ctx, k), cases : List(k), body : (k -> Elem(ctx)), anchor : U32, depth : U64, path : List(U32), cap : U64, local : Bool }

switch_reads : Val(ctx, k), List(k), (k -> Elem(ctx)), U64 -> U64
switch_reads = |sel, cases, body, d| {
	var $m = eff_mask(sel)
	for c in cases {
		$m = $m.bitwise_or(elem_reads(body(c), d))
	}
	$m
}

switch_value : Val(ctx, k), List(k), ctx, List(U32) -> k
	where [k.is_eq : k, k -> Bool]
switch_value = |sel, cases, env, path| {
	k = (sel.read)(env)
	if (cases.contains(k)) k else crash "contract: switch value is not one of its cases at site ${show_path(path)}"
}

switch_inst : Switch(ctx, k), k, List(Orphan(ctx)), Block(ctx) -> Inst(ctx)
	where [k.is_eq : k, k -> Bool]
switch_inst = |w0, cur0, adopted0, block0| {
	held = Held({ w: w0, cur: cur0, adopted: adopted0, block: block0 })
	Inst(
		|env, msg, tx| {
			Held({ w, cur, adopted, block }) = held
			match msg {
				Changed(mask) => {
					if eff_mask(w.sel).bitwise_and(mask) != 0 {
						k = switch_value(w.sel, w.cases, env, w.path)
						t1 = count_evals(tx, 1)
						if k == cur {
							(b2, t2) = refresh(block, env, mask, t1)
							(switch_inst(w, cur, adopted, b2), Done, t2)
						} else {
							(orph, t2) = dispose_block(block, env, True, bump(bump(t1, w_scopes_disposed, 1), w_scopes_created, 1))
							(b3, t3) = mount_block(env, (w.body)(k), w.depth, w.path, 0, w.anchor, { cap: w.cap, local: w.local }, fx_adopt(t2, w.path, orph))
							(switch_inst(w, k, adopted.concat(orph), b3), Done, t3)
						}
					} else {
						(b2, t2) = refresh(block, env, mask, tx)
						(switch_inst(w, cur, adopted, b2), Done, t2)
					}
				}
				Fire(path, pos, h, payload) => {
					match leaf_fx(path, pos, payload) {
						Ok(res) => {
							(ad2, out, t2) = adopt_deliver(adopted, env, h, res, tx)
							(switch_inst(w, cur, ad2, block), out, t2)
						}
						Err(_) => {
							match fire_target(block, path, pos) {
								Leaf => {
									out = fire_leaf(block, env, h, payload)
									(switch_inst(w, cur, adopted, block), out, tx)
								}
								Kid => {
									(b2, out, t2) = fire_kid(block, env, path, pos, h, payload, tx)
									(switch_inst(w, cur, adopted, b2), out, t2)
								}
								Miss => (switch_inst(w, cur, adopted, block), Pending(env, 0), tx)
							}
						}
					}
				}
				Dispose(remove) => {
					(orph, t1) = dispose_block(block, env, remove, bump(tx, w_scopes_disposed, 1))
					t2 = if (remove) emit_op(t1, 5, |c| put_u32(c, w.anchor)) else t1
					(noop({}), Orphaned(adopted.concat(orph)), free_id(t2, w.anchor))
				}
			}
		},
	)
}

derive_inst : Val(ctx, a), a, Block(In(ctx, a)), U64 -> Inst(ctx)
	where [a.is_eq : a, a -> Bool]
derive_inst = |input0, v0, block0, depth0| {
	held = Held({ input: input0, v: v0, block: block0, depth: depth0 })
	Inst(
		|env, msg, tx| {
			Held({ input, v, block, depth }) = held
			match msg {
				Changed(mask) => {
					if eff_mask(input).bitwise_and(mask) != 0 {
						v2 = (input.read)(env)
						t1 = count_evals(tx, 1)
						if v2 == v {
							(b2, t2) = refresh(block, In.{ outer: env, value: v }, mask, t1)
							(derive_inst(input, v, b2, depth), Done, t2)
						} else {
							(b2, t2) = refresh(block, In.{ outer: env, value: v2 }, mask.bitwise_or(bit(depth)), t1)
							(derive_inst(input, v2, b2, depth), Done, t2)
						}
					} else {
						(b2, t2) = refresh(block, In.{ outer: env, value: v }, mask, tx)
						(derive_inst(input, v, b2, depth), Done, t2)
					}
				}
				Fire(path, pos, h, payload) => {
					match fire_target(block, path, pos) {
						Leaf => derive_settle(input, block, depth, fire_leaf(block, In.{ outer: env, value: v }, h, payload), tx)
						Kid => {
							(b2, out, t2) = fire_kid(block, In.{ outer: env, value: v }, path, pos, h, payload, tx)
							derive_settle(input, b2, depth, out, t2)
						}
						Miss => (derive_inst(input, v, block, depth), Pending(env, 0), tx)
					}
				}
				Dispose(remove) => {
					(orph, t2) = dispose_block(block, In.{ outer: env, value: v }, remove, tx)
					(noop({}), Orphaned(lower_in(orph, v, depth)), t2)
				}
			}
		},
	)
}

## A derived layer has no write handle, so an event below it can only have
## changed an outer layer (which will refresh this site) or nothing.
derive_settle : Val(ctx, a), Block(In(ctx, a)), U64, Out(In(ctx, a)), Tx -> (Inst(ctx), Out(ctx), Tx)
	where [a.is_eq : a, a -> Bool]
derive_settle = |input, block, depth, out, tx| {
	match out {
		Done => crash "internal: fire must hand the environment back"
		Orphaned(_) => crash "internal: fire must hand the environment back"
		Pending(next_inner, mask) => {
			{ outer, value } = next_inner
			(derive_inst(input, value, block, depth), Pending(outer, mask), tx)
		}
	}
}

# The component boundary: any prop type `p` and an outward action type `a`.
#
# The body is typed over `Comp(p, a)` only, never over the caller's
# context, so it is specialised once per (p, a), not per call site.
# Inside, the prop is layer 0. The body also gets a write handle on the
# component's outward action list (`out.push(...)`, mask 0: writing it
# refreshes nothing inside). When an event inside the component settles,
# the boundary hands each pushed action to the caller's `Sink`, which
# turns it into an update of an outer state.
#
# The boundary does not retain the prop: it re-reads it from the caller's
# environment when an outer layer it reads changes, and when an event
# enters. Retaining it (for equality pruning at the boundary) would hold a
# second reference to whatever the prop projects out of an outer state
# (typically a list), and every reducer on that state would then copy it.
# Pruning happens at the holes and rows inside instead.

comp_inst : Val(ctx, p), Sink(ctx, a), Block(Comp(p, a)) -> Inst(ctx)
comp_inst = |prop0, snk0, block0| {
	held = Held({ prop: prop0, snk: snk0, block: block0 })
	Inst(
		|env, msg, tx| {
			Held({ prop, snk, block }) = held
			match msg {
				Changed(mask) => {
					if mask == every_layer {
						# Layers inside a component number from zero and settle
						# there, so `every_layer` reaches into the body whole.
						v = (prop.read)(env)
						(b2, t2) = refresh(block, Comp.{ prop: v, out: [] }, every_layer, count_evals(tx, 1))
						(comp_inst(prop, snk, b2), Done, t2)
					} else if eff_mask(prop).bitwise_and(mask) == 0 {
						(comp_inst(prop, snk, block), Done, tx)
					} else {
						v = (prop.read)(env)
						(b2, t2) = refresh(block, Comp.{ prop: v, out: [] }, 1, count_evals(tx, 1))
						(comp_inst(prop, snk, b2), Done, t2)
					}
				}
				Fire(path, pos, h, payload) => {
					match fire_target(block, path, pos) {
						Leaf => {
							inner = Comp.{ prop: (prop.read)(env), out: [] }
							comp_settle(prop, snk, block, env, fire_leaf(block, inner, h, payload), count_evals(tx, 1))
						}
						Kid => {
							inner = Comp.{ prop: (prop.read)(env), out: [] }
							(b2, out, t2) = fire_kid(block, inner, path, pos, h, payload, count_evals(tx, 1))
							comp_settle(prop, snk, b2, env, out, t2)
						}
						Miss => (comp_inst(prop, snk, block), Pending(env, 0), tx)
					}
				}
				Dispose(remove) => {
					(orph, t2) = dispose_block(block, Comp.{ prop: (prop.read)(env), out: [] }, remove, bump(tx, w_scopes_disposed, 1))
					(noop({}), Orphaned(lower_comp(orph, prop, snk)), t2)
				}
			}
		},
	)
}

## Take the pushed actions out of a settled component environment. A
## function of its own so the inner environment (and the prop it holds, a
## reference into an outer state) is dropped before any sink reducer runs.
comp_actions : Out(Comp(p, a)) -> List(a)
comp_actions = |out| match out {
	Done => crash "internal: fire must hand the environment back"
	Orphaned(_) => crash "internal: fire must hand the environment back"
	Pending(inner, _) => {
		{ prop: _, out: actions } = inner
		actions
	}
}

comp_settle : Val(ctx, p), Sink(ctx, a), Block(Comp(p, a)), ctx, Out(Comp(p, a)), Tx -> (Inst(ctx), Out(ctx), Tx)
comp_settle = |prop, snk, block, env, out, tx| {
	actions = comp_actions(out)
	match actions {
		_ => {
			if actions.is_empty() {
				(comp_inst(prop, snk, block), Pending(env, 0), tx)
			} else {
				run = snk.run
				var $e = env
				var $m = 0.U64
				for a in actions {
					(e2, m2) = run($e, a)
					$e = e2
					$m = $m.bitwise_or(m2)
				}
				(comp_inst(prop, snk, block), Pending($e, $m), tx)
			}
		}
	}
}

# Effects.
#
# An effect site watches a value. At mount (`watch`; `on_change` skips
# mount) and whenever the value changes (equality-pruned), `plan` turns
# the value into requests.
#
# - Commands (Push, Replace, Title, StorageSet, StorageRemove) are
#   emitted into the command stream and forgotten.
# - Awaited requests (Http, StorageGet, Timer, Interval, Popstate) get a
#   fresh instance-wide id (issue order, from 1), are recorded in the
#   in-flight table with the issuing site's path, and are owned by that
#   site. Interval and Popstate are subscriptions: they stay in flight,
#   delivering any number of results, until the site is disposed.
# - Disposal (design.md, "Requests, effects, and cancellation" and the
#   lifetime table): subscriptions, intervals, timers and work are stopped
#   (CANCEL id, counted `cancelled`) and forgotten. Admitted requests (Http, StorageGet) are
#   not cancelled: they reparent to the nearest surviving ancestor site
#   (the `when`/`switch` that switched branch, or the `each` that removed
#   the row), which delivers the result by running the reaction in its
#   current environment. The disposed layers are snapshots there: writes
#   to retired states are skipped and counted (`skipped`), writes to
#   surviving states commit. Reading of the design: a reaction writes one
#   state, so "per-write" application is per reaction; the snapshot of a
#   retired layer is retained until the result arrives (bounded by `max`).
# - A result enters exactly as a DOM event does: one turn that fires down
#   the owning site's path, where the site's reaction runs as a handler
#   with the value the request was issued for, then the Changed pass.
# - A result whose id is not in flight (cancelled, already delivered,
#   never issued) is dropped before any state is touched and counted in
#   `stale`. The site checks its own ownership too, so a path that a
#   disposed site's successor now occupies never receives its results.
# - The in-flight table is bounded by `max`. A request beyond it is not
#   issued (no command): it is refused, counted, and its owner receives a
#   typed `Refused` result in a follow-up turn.
# - `Self` asks for a follow-up turn with result `Now`: how an effect site
#   changes state in response to its value changing, without writing
#   during the turn that is evaluating. Follow-up ids are a separate
#   space (high bit set) so host-visible ids stay consecutive.
# - Follow-up turns run after the current turn, in order. Each has
#   its chain depth: a follow-up queued by an external turn (a DOM event,
#   an effect result, the mount) is depth 1, one queued by a follow-up of
#   depth d is depth d + 1. A chain deeper than `max_turns` is a contract
#   error (an effect feedback loop) naming the depth and the site; a turn
#   that fans out into many independent follow-ups is not. `max_breadth`
#   bounds the follow-up turns of one host call (see `drain`).
#
# Command stream additions:
#  13 FX      id kind:u8 ... 1 HTTP method:str url:str n:u32 (name:str value:str)* body:str timeout_ms:u32
#                            2 STORAGE_GET key:str  3 TIMER ms:u32  4 INTERVAL ms:u32  5 POPSTATE
#                            6 ONLINE  7 VISIBILITY
#                            8 WORK program:str input:(u32 len, raw bytes) deadline_ms:u32
#                            11 READ mode:u8 token:u64 start:u64 len:u64 (a file's range)
#                            12 UPLOAD method:str url:str n:u32 (name:str value:str)* token start len timeout_ms:u32
#                            13 DIGEST algorithm:u8 token start len   14 URL token start len
#  14 CANCEL  id
#  15 NAV     mode:u8 (1 push, 2 replace) url:str
#  16 STORE   op:u8 (1 set: key:str value:str, 2 remove: key:str)
#  17 TITLE   text:str
#  18 FOCUS   op:u8 (1 focus, 2 blur, 3 select text) node   (end of turn)
# Results come back as an event on node `fx_node` with handler = id and
# payload bytes: 1 status:u16 n:u32 (name:str value:str)* body (HTTP
# response with its headers), 7 (HTTP timeout), 2 message (network
# failure), 3 value (storage value), 4 (storage missing), 5 (timer
# fired), 6 url (location), 8 online:u8, 9 visible:u8, 10 output (work
# result bytes), 11 class:u8 (work lost; design.md, Appendix B).

## Largest per-request HTTP timeout or work deadline the host will arm (10
## minutes).
max_timeout_ms : U32
max_timeout_ms = 600000

## The most worker programs one catalogue registers (design.md, "Boundedness").
max_programs : U64
max_programs = 64

## Mount `elem` with the in-flight bound `max` and the catalogue's program
## names, running any follow-up turns the mount queued.
mount_in : U64, List(Str), Elem(Root) -> App
mount_in = |max, programs, elem| {
	{ cmds, next, free, routes, work, paths, site_free, fx } = new_tx([])
	tx0 = { cmds, next, free, routes, work, paths, site_free, fx: { ..fx, max } }
	(block, tx) = mount_block(Root, elem, 0, [], 0, 0, { cap: 0, local: False }, tx0)
	drain({ root: block_inst(block), tx: flush_turn(tx, programs), programs })
}

## A `:files` event's record (design.md, Appendix B), `count:u32
## refused:u32 (size:u64 name:str type:str)*count`, paired in order with the
## handles the host minted for it. Anything else is a contract error: the
## runtime and the host broke the protocol, and nothing is guessed.
decode_files : List(U8), List(Blob) -> (List(File), U64)
decode_files = |record, blobs| {
	count = get_u32(record, 0, "file record").to_u64()
	refused = get_u32(record, 4, "file record").to_u64()
	if count != blobs.len() {
		crash "contract: a file record lists ${count.to_str()} files but the host minted ${blobs.len().to_str()} handles"
	}
	var $at = 8.U64
	var $files = List.with_capacity(count)
	for blob in blobs {
		size = get_u64(record, $at, "file record")
		(name, a1) = get_str(record, $at + 8, "file record")
		(mime, a2) = get_str(record, a1, "file record")
		$files = $files.append({ at: Page(blob), name, mime, size, start: 0, len: size })
		$at = a2
	}
	if $at != record.len() {
		crash "contract: a file record carries ${(record.len() - $at).to_str()} unexpected trailing bytes"
	}
	($files, refused)
}

## The catalogue's names, or the contract error that building it is.
catalogue_names : List(Registration) -> List(Str)
catalogue_names = |registrations| match Core.catalogue(registrations) {
	Ok(names) => names
	Err(message) => crash message
}

## A worker instance's one call: `name:str input:rest` in, the program's
## output out. The catalogue is checked as it is at mount, and a name it does
## not hold (or a payload without one) is a contract error that poisons this
## worker instance only.
run_work : List(Registration), List(U8), List(List(U8)) -> List(U8)
run_work = |registrations, payload, files| {
	_ = catalogue_names(registrations)
	(name, at) = get_str(payload, 0, "work payload")
	match registrations.find_first(|r| r.name == name) {
		Ok(r) => owned_bytes((r.run)(payload.drop_first(at), files))
		Err(_) =>
			match registrations.find_first(|r| r.queries.contains(name)) {
				# A query run afresh: prepare, ask, and keep nothing.
				Ok(r) => {
					input = payload.drop_first(at)
					q = query_header(input, name)
					if q.prep != r.name {
						crash "contract: worker program \"${name}\" was asked of the preparation \"${q.prep}\", but with_workers registers it with \"${r.name}\""
					}
					state = (r.prepare)(input.sublist({ start: q.init_at, len: q.init_len }), files.take_first(q.init_files))
					owned_bytes((state.ask)(name, input.drop_first(q.init_at + q.init_len), files.drop_first(q.init_files)))
				}
				Err(_) => crash "contract: worker program \"${name}\" is not registered in this module"
			}
	}
}

## A placeholder `prepare` for a registration that is not a preparation;
## nothing calls it, because only a preparation's name is prepared.
not_prepared : List(U8), List(List(U8)) -> Kept
not_prepared = |_, _| crash "internal: a program that is not a preparation was prepared"

## A query input's header (design.md, Appendix B): `prep:str init_len:u32
## init_files:u32 policy:u8`, then the preparation's input of `init_len`
## bytes and the query's input. `init_at` is where the preparation's input
## starts. Anything else is a contract error naming the program.
query_header : List(U8), Str -> { prep : Str, init_at : U64, init_len : U64, init_files : U64, policy : U8 }
query_header = |input, program| {
	what = "query input of worker program \"${program}\""
	(prep, a1) = get_str(input, 0, what)
	init_len = get_u32(input, a1, what).to_u64()
	init_files = get_u32(input, a1 + 4, what).to_u64()
	policy = input.get(a1 + 8) ?? crash "contract: truncated ${what}"
	init_at = a1 + 9
	if init_at + init_len > input.len() or policy < 1 or policy > 2 {
		crash "contract: malformed ${what}"
	}
	{ prep, init_at, init_len, init_files, policy }
}

## An `Ask` request's `FX` (design.md, Appendix B): kind 8 as for `Work`,
## then `1 prep:str init_at:u32 init_len:u32 init_files:u32 policy:u8`,
## read from the query input's header, so the runtime knows which
## preparation answers it without reading the input itself.
put_ask : List(U8), Str, List(U8), List(File), U32 -> List(U8)
put_ask = |head, program, input, files, deadline_ms| {
	q = query_header(input, program)
	if q.init_files > files.len() {
		crash "contract: the query input of worker program \"${program}\" names more files than its request carries"
	}
	b = put_str(put_work(head, program, input, files, deadline_ms).append(1), q.prep)
	put_u32(put_u32(put_u32(b, q.init_at.to_u32_wrap()), q.init_len.to_u32_wrap()), q.init_files.to_u32_wrap()).append(q.policy)
}

## FX kind 8 up to its deadline (design.md, Appendix B): what `Work` and
## `Ask` requests share, before the flag that tells them apart.
put_work : List(U8), Str, List(U8), List(File), U32 -> List(U8)
put_work = |head, program, input, files, deadline_ms| {
	var $b = put_u32(put_u32(put_str(head.append(8), program), input.len().to_u32_wrap()).concat(input), files.len().to_u32_wrap())
	for file in files {
		{ token, start, len } = file_ref(file)
		$b = put_u64(put_u64(put_u64($b, token), start), len)
	}
	put_u32($b, min_u32(deadline_ms, max_timeout_ms))
}

## A worker instance's preparation: `prep:str init:rest` and the
## preparation's files in, the [Kept] value out. A name that is not a
## preparation is a contract error that poisons this worker instance only.
run_prepare : List(Registration), List(U8), List(List(U8)) -> Kept
run_prepare = |registrations, payload, files| {
	_ = catalogue_names(registrations)
	(prep, at) = get_str(payload, 0, "prepare payload")
	match registrations.find_first(|r| r.name == prep and !r.queries.is_empty()) {
		Ok(r) => (r.prepare)(payload.drop_first(at), files)
		Err(_) => crash "contract: worker program \"${prep}\" is not a preparation registered in this module"
	}
}

## A query on the state an instance holds: `query:str input:rest` and the
## query's files in, the output out (a list of its own, as for `run_work`).
run_ask : Kept, List(U8), List(List(U8)) -> List(U8)
run_ask = |state, payload, files| {
	(query, at) = get_str(payload, 0, "ask payload")
	owned_bytes((state.ask)(query, payload.drop_first(at), files))
}

## A file's handle and range, for a request that names it. Only a page's
## file has a handle; a worker program's file in a request is a contract
## error.
file_ref : File -> { token : U64, start : U64, len : U64 }
file_ref = |f| match f.at {
	Page(blob) => { token: blob.token(), start: f.start, len: f.len }
	Worker(_) => crash "contract: a request names \"${f.name}\", a file a worker program was sent; only the page's files can be named in a request"
}

## A file's handle and range on the wire: `token:u64 start:u64 len:u64`.
put_file : List(U8), File -> List(U8)
put_file = |buf, f| {
	{ token, start, len } = file_ref(f)
	put_u64(put_u64(put_u64(buf, token), start), len)
}

## `out` as a list of its own. The host keeps the output between calls and
## never holds a seamless slice, and a program may well return a slice of
## its input. `concat` onto an empty list hands back its argument, slice and
## all, so the first byte goes into a fresh list sized for the whole output
## first: `concat` then copies the rest into that list's own allocation in
## one move, since it is uniquely owned and already holds the capacity.
owned_bytes : List(U8) -> List(U8)
owned_bytes = |out| match out {
	[] => []
	[first, .. as rest] => List.with_capacity(out.len()).append(first).concat(rest)
}

## Result tag 11's fault class byte (design.md, Appendix B).
work_fault : U8 -> WorkFault
work_fault = |class| match class {
	1 => Contract
	2 => ResourceLimit
	3 => OutOfMemory
	4 => AppCrash
	5 => ExpectFailed
	6 => Unavailable
	7 => Executor
	_ => crash "contract: effect result tag 11 carries unknown fault class ${class.to_str()}"
}

Live : { id : U32, path : List(U32), sub : Bool }

Queued : { id : U32, path : List(U32), res : Res }

Fx : {
	next : U32,
	inner : U32,
	live : List(Live),
	queue : List(Queued),
	max : U64,
	issued : U64,
	delivered : U64,
	stale : U64,
	refused : U64,
	cancelled : U64,
	reparented : U64,
	skipped : U64,

	## Focus references (name, node), and the checks awaiting the end of the
	## turn (see [TurnEnd]).
	refs : List((Str, U32)),
	focus : List(TurnEnd),

	## `ref_pos[node]`: the node's position in `refs` plus one (0: the node
	## carries no reference), so freeing a node id is O(1).
	ref_pos : List(U32),

	## `on_cleanup` runs, by name, in first-run order.
	cleanups : List((Str, U64)),
}

## What the end of a turn settles, in issue order: a focus command on a named
## reference (op 1 focus, 2 blur, 3 select text), resolved then so a reference
## mounted later in the turn is found; and the work requests the turn issued,
## each checked against the worker catalogue with its program and site path.
##
## The catalogue lives in [App], not in `Fx`: every site rebuilds `Fx` as it
## threads the transaction, and with the pinned compiler each inline field of
## it costs code at every one of those places (a catalogue field there grew
## every app by about 3%). Checking at the end of the turn is the same
## contract error with the same message; nothing the turn did is published,
## because the crash poisons the instance before the call returns.
TurnEnd : [Focus(U8, Str), CheckProgram(Str, List(U32))]

fx_empty : Fx
fx_empty = { next: 1, inner: fx_inner_base, live: [], queue: [], max: 32, issued: 0, delivered: 0, stale: 0, refused: 0, cancelled: 0, reparented: 0, skipped: 0, refs: [], focus: [], ref_pos: [], cleanups: [] }

## The first follow-up id: follow-ups are a space of their own, above
## every request id.
fx_inner_base : U32
fx_inner_base = 2147483648

## The host node id that marks an event as an effect result.
fx_node : U32
fx_node = 4294967295

## The deepest chain of follow-up turns one host call may run: a
## follow-up whose turn queues another, and so on. Breadth does not count:
## one turn may queue any number of independent follow-ups (a refusal for
## every request past the in-flight bound, say), each at the same depth.
max_turns : U64
max_turns = 64

## The most follow-up turns one host call may run: 64 for each in-flight
## slot, and at least 64 x 64. The depth bound alone stops every chain, but
## a feedback loop in which each follow-up queues two or more would grow
## exponentially before reaching it; this backstop stops that while leaving
## room for any fan-out up to 64 times the app's own `max_inflight`.
max_breadth : U64 -> U64
max_breadth = |inflight| max_turns * (if (inflight > max_turns) inflight else max_turns)

## A request the site owns: its id, whether it is a subscription, and the
## value it was issued for.
Owned(a) : { id : U32, sub : Bool, keep : Bool, a : a }

EffectCfg(ctx, a) : { v : Val(ctx, a), plan : (a -> List(Req)), react : Reaction(ctx, a), path : List(U32) }

with_fx : Tx, (Fx -> Fx) -> Tx
with_fx = |{ cmds, next, free, routes, work, paths, site_free, fx }, f| { cmds, next, free, routes, work, paths, site_free, fx: f(fx) }

fx_count : Tx, [Delivered, Stale] -> Tx
fx_count = |tx, k| with_fx(
	tx,
	|fx| match k {
		Delivered => { ..fx, delivered: fx.delivered + 1 }
		Stale => { ..fx, stale: fx.stale + 1 }
	},
)

is_sub : Req -> Bool
is_sub = |req| match req {
	Interval(_) => True
	Popstate => True
	OnlineChanges => True
	VisibilityChanges => True
	_ => False
}

## Requests that survive their site's disposal (design.md: an admitted
## effect reparents). Subscriptions, intervals, timers and work are scoped:
## disposal stops them (a pure computation has no external effect to keep,
## and unwanted compute is only cost).
is_kept : Req -> Bool
is_kept = |req| match req {
	Http(_) => True
	Upload(_) => True
	StorageGet(_) => True
	_ => False
}

min_u32 : U32, U32 -> U32
min_u32 = |a, b| if (a < b) a else b

put_req : List(U8), U32, Req -> List(U8)
put_req = |c, id, req| {
	head = put_u32(c.append(13), id)
	match req {
		Http({ method, url, headers, body, timeout_ms }) => {
			var $b = put_u32(put_str(put_str(head.append(1), method), url), headers.len().to_u32_wrap())
			for (k, v) in headers {
				$b = put_str(put_str($b, k), v)
			}
			put_u32(put_str($b, body), min_u32(timeout_ms, max_timeout_ms))
		}
		StorageGet(k) => put_str(head.append(2), k)
		Timer(ms) => put_u32(head.append(3), ms)
		Interval(ms) => put_u32(head.append(4), ms)
		Popstate => head.append(5)
		OnlineChanges => head.append(6)
		VisibilityChanges => head.append(7)
		Work({ program, input, files, deadline_ms }) => put_work(head, program, input, files, deadline_ms).append(0)
		ReadBytes(f) => put_file(head.append(11).append(1), f)
		ReadUtf8(f) => put_file(head.append(11).append(2), f)
		Upload({ method, url, headers, body, timeout_ms }) => {
			if method == "GET" or method == "HEAD" {
				crash "contract: File.upload of \"${body.name}\" to ${url} uses ${method}, which carries no body"
			}
			var $b = put_u32(put_str(put_str(head.append(12), method), url), headers.len().to_u32_wrap())
			for (k, v) in headers {
				$b = put_str(put_str($b, k), v)
			}
			put_u32(put_file($b, body), min_u32(timeout_ms, max_timeout_ms))
		}
		Sha256(f) => put_file(head.append(13).append(1), f)
		ObjectUrl(f) => put_file(head.append(14), f)
		Ask({ program, input, files, deadline_ms }) => put_ask(head, program, input, files, deadline_ms)
		_ => crash "not an awaited request"
	}
}

## Admit an awaited request (or refuse it when the table is full).
fx_admit : Tx, List(U32), Req -> (U32, Tx)
fx_admit = |{ cmds, next, free, routes, work, paths, site_free, fx }, path, req| {
	{ next: id, inner, live, queue, max, issued, delivered, stale, refused, cancelled, reparented, skipped, refs, focus, ref_pos, cleanups } = fx
	if live.len() >= max {
		fx2 = { next: id + 1, inner, live, queue: queue.append({ id, path, res: Refused }), max, issued, delivered, stale, refused: refused + 1, cancelled, reparented, skipped, refs, focus, ref_pos, cleanups }
		(id, { cmds, next, free, routes, work, paths, site_free, fx: fx2 })
	} else {
		fx2 = { next: id + 1, inner, live: live.append({ id, path, sub: is_sub(req) }), queue, max, issued: issued + 1, delivered, stale, refused, cancelled, reparented, skipped, refs, focus, ref_pos, cleanups }
		(id, { cmds: put_req(cmds, id, req), next, free, routes, work: add_work(work, 13, 1), paths, site_free, fx: fx2 })
	}
}

## Queue a follow-up turn for `path` with result `res`.
fx_follow : Tx, List(U32), Res -> (U32, Tx)
fx_follow = |tx, path, res| {
	id = tx.fx.inner
	(id, with_fx(tx, |fx| { ..fx, inner: id + 1, queue: fx.queue.append({ id, path, res }) }))
}

## Issue a site's requests for value `a`.
issue : Tx, List(U32), List(Req), a, List(Owned(a)) -> (Tx, List(Owned(a)))
issue = |tx, path, reqs, a, owned| {
	var $tx = tx
	var $owned = owned
	for req in reqs {
		match req {
			Push(url) => {
				$tx = emit_op($tx, 15, |c| put_str(c.append(1), url))
			}
			Replace(url) => {
				$tx = emit_op($tx, 15, |c| put_str(c.append(2), url))
			}
			Focus(n) => {
				$tx = with_fx($tx, |fx| { ..fx, focus: fx.focus.append(Focus(1, n)) })
			}
			Blur(n) => {
				$tx = with_fx($tx, |fx| { ..fx, focus: fx.focus.append(Focus(2, n)) })
			}
			SelectText(n) => {
				$tx = with_fx($tx, |fx| { ..fx, focus: fx.focus.append(Focus(3, n)) })
			}
			Title(t) => {
				$tx = emit_op($tx, 17, |c| put_str(c, t))
			}
			StorageSet(k, v) => {
				$tx = emit_op($tx, 16, |c| put_str(put_str(c.append(1), k), v))
			}
			StorageRemove(k) => {
				$tx = emit_op($tx, 16, |c| put_str(c.append(2), k))
			}
			Self => {
				(id, t1) = fx_follow($tx, path, Now)
				$tx = t1
				$owned = $owned.append({ id, sub: False, keep: False, a })
			}
			Work({ program, .. }) => {
				t0 = with_fx($tx, |fx| { ..fx, focus: fx.focus.append(CheckProgram(program, path)) })
				(id, t1) = fx_admit(t0, path, req)
				$tx = t1
				$owned = $owned.append({ id, sub: False, keep: False, a })
			}
			Ask({ program, .. }) => {
				t0 = with_fx($tx, |fx| { ..fx, focus: fx.focus.append(CheckProgram(program, path)) })
				(id, t1) = fx_admit(t0, path, req)
				$tx = t1
				$owned = $owned.append({ id, sub: False, keep: False, a })
			}
			_ => {
				(id, t1) = fx_admit($tx, path, req)
				$tx = t1
				$owned = $owned.append({ id, sub: is_sub(req), keep: is_kept(req), a })
			}
		}
	}
	($tx, $owned)
}

## A disposed site's requests (design.md, "Requests, effects, and
## cancellation"): admitted requests (HTTP, storage read) survive and
## become orphans that reparent to the nearest surviving ancestor;
## subscriptions, intervals and timers are stopped (CANCEL) and forgotten;
## queued follow-ups it would have received are dropped and counted stale.
fx_dispose : Tx, Reaction(ctx, a), List(Owned(a)) -> (List(Orphan(ctx)), Tx)
fx_dispose = |tx, react, owned| {
	var $tx = tx
	var $orph = []
	run = react.run
	mask = react.mask
	for o in owned {
		id = o.id
		if $tx.fx.live.any(|l| l.id == id) {
			if o.keep {
				a = o.a
				$orph = $orph.append({ id, run: |e, r| (run(e, a, r), mask, 0) })
			} else {
				t1 = with_fx($tx, |fx| { ..fx, live: fx.live.keep_if(|l| l.id != id), cancelled: fx.cancelled + 1 })
				$tx = emit_op(t1, 14, |c| put_u32(c, id))
			}
		} else if $tx.fx.queue.any(|q| q.id == id) {
			$tx = with_fx($tx, |fx| { ..fx, queue: fx.queue.keep_if(|q| q.id != id), stale: fx.stale + 1 })
		}
	}
	($orph, $tx)
}

## A surviving site takes over orphans: their results now route to it.
fx_adopt : Tx, List(U32), List(Orphan(ctx)) -> Tx
fx_adopt = |tx, path, orphans| {
	if orphans.is_empty() {
		tx
	} else {
		ids = orphans.map(|o| o.id)
		with_fx(
			tx,
			|fx| {
				..fx,
				live: fx.live.map(|l| if (ids.contains(l.id)) { id: l.id, path, sub: l.sub } else l),
				reparented: fx.reparented + ids.len(),
			},
		)
	}
}

## An effect result arriving at the site path itself (not below it).
leaf_fx : List(U32), U64, Payload -> Try(Res, [NotFx])
leaf_fx = |path, pos, payload| {
	if pos >= path.len() {
		match payload {
			Fx(r) => Ok(r)
			_ => Err(NotFx)
		}
	} else {
		Err(NotFx)
	}
}

## Deliver a result to an adopted orphan: its reaction runs in this
## site's current environment; writes to retired states are counted as
## skipped. An id this site does not hold is dropped and counted stale.
adopt_deliver : List(Orphan(ctx)), ctx, U32, Res, Tx -> (List(Orphan(ctx)), Out(ctx), Tx)
adopt_deliver = |adopted, env, id, res, tx| {
	match adopted.find_first_index(|o| o.id == id) {
		Ok(i) => {
			o = adopted.get(i) ?? crash "adopted"
			run = o.run
			kept = adopted.drop_at(i)
			(e2, m, sk) = run(env, res)
			(kept, Pending(e2, m), with_fx(tx, |fx| { ..fx, delivered: fx.delivered + 1, skipped: fx.skipped + sk }))
		}
		Err(_) => (adopted, Pending(env, 0), fx_count(tx, Stale))
	}
}

## Lower orphans through a state or derived layer at `depth` being
## disposed with final value `v`: the layer is a discarded snapshot.
lower_in : List(Orphan(In(ctx, s))), s, U64 -> List(Orphan(ctx))
lower_in = |os, v, depth| {
	keep = bit(depth) - 1
	os.map(
		|o| {
			run = o.run
			{
				id: o.id,
				run: |e, r| {
					(inner, m, sk) = run(In.{ outer: e, value: v }, r)
					{ outer, value: _ } = inner
					(outer, m.bitwise_and(keep), if (m.bitwise_and(keep.bitwise_not()) != 0) sk + 1 else sk)
				},
			}
		},
	)
}

## Lower orphans through a removed row (key and item are snapshots).
lower_row : List(Orphan(Row(ctx, item))), Str, item, U64 -> List(Orphan(ctx))
lower_row = |os, key, item, depth| {
	keep = bit(depth) - 1
	os.map(
		|o| {
			run = o.run
			{
				id: o.id,
				run: |e, r| {
					(row, m, sk) = run(Row.{ outer: e, key, item }, r)
					{ outer, key: _, item: _ } = row
					(outer, m.bitwise_and(keep), if (m.bitwise_and(keep.bitwise_not()) != 0) sk + 1 else sk)
				},
			}
		},
	)
}

## Lower orphans through a disposed component: the prop is re-read from
## the caller's environment, inner writes are discarded (counted), and
## pushed actions go through the sink as for a live event.
lower_comp : List(Orphan(Comp(p, a))), Val(ctx, p), Sink(ctx, a) -> List(Orphan(ctx))
lower_comp = |os, prop, snk| {
	read = prop.read
	srun = snk.run
	os.map(
		|o| {
			run = o.run
			{
				id: o.id,
				run: |e, r| {
					(inner, m, sk) = run(Comp.{ prop: read(e), out: [] }, r)
					{ prop: _, out: actions } = inner
					var $e = e
					var $m = 0.U64
					for act in actions {
						(e2, m2) = srun($e, act)
						$e = e2
						$m = $m.bitwise_or(m2)
					}
					($e, $m, if (m != 0) sk + 1 else sk)
				},
			}
		},
	)
}

## Take a site's dropped rows and lower their orphans to the site.
take_dropped : Cols(Row(ctx, item), item), U64 -> (Cols(Row(ctx, item), item), List(Orphan(ctx)))
take_dropped = |cols, depth| {
	if cols.dropped.is_empty() {
		(cols, [])
	} else {
		{ items, keys, order, free, index, lasts, kids, binds, pend, dirty, sels, known, kid_mask, dropped, rnodes } = cols
		var $o = []
		for d in dropped {
			$o = $o.concat(lower_row(d.orphans, d.key, d.item, depth))
		}
		({ items, keys, order, free, index, lasts, kids, binds, pend, dirty, sels, known, kid_mask, dropped: [], rnodes }, $o)
	}
}

## An effect site. `initial`: also issue for the value at mount.
effect : Val(ctx, a), Bool, (a -> List(Req)), Reaction(ctx, a) -> Elem(ctx)
	where [a.is_eq : a, a -> Bool]
effect = |v, initial, plan, react| Site(
	Mount(
		|env, args, tx| {
			a = (v.read)(env)
			cfg = { v, plan, react, path: args.path }
			t1 = count_evals(tx, 1)
			if initial {
				(t2, owned) = issue(t1, args.path, plan(a), a, [])
				(effect_inst(cfg, a, owned), eff_mask(v), t2)
			} else {
				(effect_inst(cfg, a, []), eff_mask(v), t1)
			}
		},
	),
	|_| eff_mask(v),
)

cleanup_inst : Str, Val(ctx, a), (a -> List(Req)) -> Inst(ctx)
cleanup_inst = |name, v, plan| Inst(
	|env, msg, tx| {
		match msg {
			Changed(_) => (cleanup_inst(name, v, plan), Done, tx)
			Fire(_, _, _, _) => (cleanup_inst(name, v, plan), Pending(env, 0), tx)
			Dispose(_) => {
				reqs = plan((v.read)(env))
				var $tx = bump(count_evals(tx, 1), w_cleanups, 1)
				for req in reqs {
					if is_command(req) {
						(t2, _) = issue($tx, [], [req], {}, [])
						$tx = t2
					} else {
						crash "contract: cleanup \"${name}\" asked for a request that awaits a result; a cleanup may only issue commands"
					}
				}
				(noop({}), Orphaned([]), with_fx($tx, |fx| { ..fx, cleanups: count_name(fx.cleanups, name) }))
			}
		}
	},
)

## Requests that are emitted and forgotten.
is_command : Req -> Bool
is_command = |req| match req {
	Push(_) | Replace(_) | Title(_) | Focus(_) | Blur(_) | SelectText(_) | StorageSet(_, _) | StorageRemove(_) => True
	_ => False
}

count_name : List((Str, U64)), Str -> List((Str, U64))
count_name = |runs, name| match runs.find_first_index(|(n, _)| n == name) {
	Ok(i) => {
		(_, k) = runs.get(i) ?? crash "internal: cleanup"
		runs.set(i, (name, k + 1)) ?? crash "internal: cleanup"
	}
	Err(_) => runs.append((name, 1))
}

effect_inst : EffectCfg(ctx, a), a, List(Owned(a)) -> Inst(ctx)
	where [a.is_eq : a, a -> Bool]
effect_inst = |cfg0, last0, owned0| {
	held = Held({ cfg: cfg0, last: last0, owned: owned0 })
	Inst(
		|env, msg, tx| {
			Held({ cfg, last, owned }) = held
			match msg {
				Changed(mask) => {
					if eff_mask(cfg.v).bitwise_and(mask) == 0 {
						(effect_inst(cfg, last, owned), Done, tx)
					} else {
						a = (cfg.v.read)(env)
						t1 = count_evals(tx, 1)
						if a == last {
							(effect_inst(cfg, last, owned), Done, t1)
						} else {
							(t2, owned2) = issue(t1, cfg.path, (cfg.plan)(a), a, owned)
							(effect_inst(cfg, a, owned2), Done, t2)
						}
					}
				}
				Fire(path, pos, h, payload) => {
					if pos < path.len() {
						(effect_inst(cfg, last, owned), Pending(env, 0), tx)
					} else {
						match payload {
							Fx(res) => effect_deliver(cfg, last, owned, env, h, res, tx)
							_ => (effect_inst(cfg, last, owned), Pending(env, 0), tx)
						}
					}
				}
				Dispose(_) => {
					(orph, t2) = fx_dispose(tx, cfg.react, owned)
					(noop({}), Orphaned(orph), t2)
				}
			}
		},
	)
}

effect_deliver : EffectCfg(ctx, a), a, List(Owned(a)), ctx, U32, Res, Tx -> (Inst(ctx), Out(ctx), Tx)
	where [a.is_eq : a, a -> Bool]
effect_deliver = |cfg, last, owned, env, id, res, tx| {
	match owned.find_first_index(|o| o.id == id) {
		Ok(i) => {
			entry = owned.get(i) ?? crash "owned"
			kept = if (entry.sub) owned else owned.drop_at(i)
			react = cfg.react
			next = effect_inst(cfg, last, kept)
			(next, Pending((react.run)(env, entry.a, res), react.mask), fx_count(tx, Delivered))
		}
		Err(_) => (effect_inst(cfg, last, owned), Pending(env, 0), fx_count(tx, Stale))
	}
}

# Supersession (design.md, "Supersession and asynchronous layers").
#
# A `latest` or `resource` site owns only the requests of its current
# value. Before it issues for a new value it gives up everything it still
# owns: an awaited request still in flight, of any kind, is stopped
# (CANCEL id), leaves the in-flight table and counts `cancelled`, so its
# late result is stale like any other; a follow-up still queued for it (a
# `Self` or a refusal) is dropped and counts `stale`. Owned entries already
# answered are not in either table and cost nothing. The work is
# O(owned x in-flight), bounded by the in-flight cap.

## Give up every request a superseding site owns (the list is then empty).
fx_supersede : Tx, List(Owned(a)) -> Tx
fx_supersede = |tx, owned| {
	var $tx = tx
	for o in owned {
		id = o.id
		if $tx.fx.live.any(|l| l.id == id) {
			t1 = with_fx($tx, |fx| { ..fx, live: fx.live.keep_if(|l| l.id != id), cancelled: fx.cancelled + 1 })
			$tx = emit_op(t1, 14, |c| put_u32(c, id))
		} else if $tx.fx.queue.any(|q| q.id == id) {
			$tx = with_fx($tx, |fx| { ..fx, queue: fx.queue.keep_if(|q| q.id != id), stale: fx.stale + 1 })
		}
	}
	$tx
}

## A `latest` site: an effect site that supersedes its requests whenever
## its watched value changes. Results and disposal are an effect site's.
latest_inst : EffectCfg(ctx, a), a, List(Owned(a)) -> Inst(ctx)
	where [a.is_eq : a, a -> Bool]
latest_inst = |cfg0, last0, owned0| {
	held = Held({ cfg: cfg0, last: last0, owned: owned0 })
	Inst(
		|env, msg, tx| {
			Held({ cfg, last, owned }) = held
			match msg {
				Changed(mask) => {
					if eff_mask(cfg.v).bitwise_and(mask) == 0 {
						(latest_inst(cfg, last, owned), Done, tx)
					} else {
						a = (cfg.v.read)(env)
						t1 = count_evals(tx, 1)
						if a == last {
							(latest_inst(cfg, last, owned), Done, t1)
						} else {
							(t2, owned2) = issue(fx_supersede(t1, owned), cfg.path, (cfg.plan)(a), a, [])
							(latest_inst(cfg, a, owned2), Done, t2)
						}
					}
				}
				Fire(path, pos, h, payload) => {
					match leaf_fx(path, pos, payload) {
						Ok(res) => latest_deliver(cfg, last, owned, env, h, res, tx)
						Err(_) => (latest_inst(cfg, last, owned), Pending(env, 0), tx)
					}
				}
				Dispose(_) => {
					(orph, t2) = fx_dispose(tx, cfg.react, owned)
					(noop({}), Orphaned(orph), t2)
				}
			}
		},
	)
}

latest_deliver : EffectCfg(ctx, a), a, List(Owned(a)), ctx, U32, Res, Tx -> (Inst(ctx), Out(ctx), Tx)
	where [a.is_eq : a, a -> Bool]
latest_deliver = |cfg, last, owned, env, id, res, tx| {
	match owned.find_first_index(|o| o.id == id) {
		Ok(i) => {
			entry = owned.get(i) ?? crash "owned"
			kept = if (entry.sub) owned else owned.drop_at(i)
			react = cfg.react
			next = latest_inst(cfg, last, kept)
			(next, Pending((react.run)(env, entry.a, res), react.mask), fx_count(tx, Delivered))
		}
		Err(_) => (latest_inst(cfg, last, owned), Pending(env, 0), fx_count(tx, Stale))
	}
}

## Fixed per `resource` site.
ResourceCfg(ctx, a, s) : {
	input : Val(ctx, a),
	begin : (s, a -> s),
	plan : (a -> List(Req)),
	fold : (s, a, Res -> s),
	path : List(U32),
	depth : U64,
	local : Bool,
}

## A `resource` site: `last` is the input its requests were issued for, `s`
## the layer's value at absolute depth `rc.depth`. The layer keeps its
## previous value only while its replacement is compared with it, so
## `begin` and `fold` receive it shared: they should build a fresh value
## rather than update a large one in place.
resource_inst : ResourceCfg(ctx, a, s), a, s, List(Owned(a)), Block(In(ctx, s)) -> Inst(ctx)
	where [a.is_eq : a, a -> Bool, s.is_eq : s, s -> Bool]
resource_inst = |rc0, last0, s0, owned0, block0| {
	held = Held({ rc: rc0, last: last0, s: s0, owned: owned0, block: block0 })
	Inst(
		|env, msg, tx| {
			Held({ rc, last, s, owned, block }) = held
			match msg {
				Changed(mask) => {
					if eff_mask(rc.input).bitwise_and(mask) == 0 {
						(b2, t2) = refresh(block, In.{ outer: env, value: s }, mask, tx)
						(resource_inst(rc, last, s, owned, b2), Done, t2)
					} else {
						a = (rc.input.read)(env)
						t1 = count_evals(tx, 1)
						if a == last {
							(b2, t2) = refresh(block, In.{ outer: env, value: s }, mask, t1)
							(resource_inst(rc, last, s, owned, b2), Done, t2)
						} else {
							# Supersede, start the layer for the new input and issue,
							# all before the block below reads the layer.
							s2 = (rc.begin)(s, a)
							(t2, owned2) = issue(fx_supersede(t1, owned), rc.path, (rc.plan)(a), a, [])
							if s2 == s {
								(b3, t3) = refresh(block, In.{ outer: env, value: s2 }, mask, t2)
								(resource_inst(rc, a, s2, owned2, b3), Done, t3)
							} else {
								(b3, t3) = refresh(block, In.{ outer: env, value: s2 }, mask.bitwise_or(bit(rc.depth)), t2)
								(resource_inst(rc, a, s2, owned2, b3), Done, t3)
							}
						}
					}
				}
				Fire(path, pos, h, payload) => {
					match leaf_fx(path, pos, payload) {
						Ok(res) => resource_deliver(rc, last, s, owned, block, env, h, res, tx)
						Err(_) => {
							match fire_target(block, path, pos) {
								Leaf => resource_settle(rc, last, owned, block, fire_leaf(block, In.{ outer: env, value: s }, h, payload), tx)
								Kid => {
									(b2, out, t2) = fire_kid(block, In.{ outer: env, value: s }, path, pos, h, payload, tx)
									resource_settle(rc, last, owned, b2, out, t2)
								}
								Miss => (resource_inst(rc, last, s, owned, block), Pending(env, 0), tx)
							}
						}
					}
				}
				Dispose(remove) => {
					# The site's own requests follow the per-kind rules; an admitted
					# one becomes an orphan whose fold writes the retired layer, a
					# snapshot whose write `lower_in` skips and counts.
					fold = rc.fold
					react = {
						mask: bit(rc.depth),
						run: |e, a, r| {
							{ outer, value } = e
							In.{ outer, value: fold(value, a, r) }
						},
					}
					(mine, t1) = fx_dispose(tx, react, owned)
					(orph, t2) = dispose_block(block, In.{ outer: env, value: s }, remove, t1)
					(noop({}), Orphaned(lower_in(mine.concat(orph), s, rc.depth)), t2)
				}
			}
		},
	)
}

## A result for a request the site owns folds into the layer. An equal
## fold changes nothing. Otherwise, inside a row or a component the site
## refreshes its own subtree now (the root's Changed pass cannot reach its
## layer by mask there); elsewhere it reports its layer upward.
resource_deliver : ResourceCfg(ctx, a, s), a, s, List(Owned(a)), Block(In(ctx, s)), ctx, U32, Res, Tx -> (Inst(ctx), Out(ctx), Tx)
	where [a.is_eq : a, a -> Bool, s.is_eq : s, s -> Bool]
resource_deliver = |rc, last, s, owned, block, env, id, res, tx| {
	match owned.find_first_index(|o| o.id == id) {
		Ok(i) => {
			entry = owned.get(i) ?? crash "owned"
			kept = if (entry.sub) owned else owned.drop_at(i)
			s2 = (rc.fold)(s, entry.a, res)
			t1 = fx_count(tx, Delivered)
			if s2 == s {
				(resource_inst(rc, last, s2, kept, block), Pending(env, 0), t1)
			} else if rc.local {
				own = bit(rc.depth)
				(b2, t2) = refresh(block, In.{ outer: env, value: s2 }, own, bump(t1, w_dirty_roots, 1))
				(resource_inst(rc, last, s2, kept, b2), Pending(env, 0), t2)
			} else {
				(resource_inst(rc, last, s2, kept, block), Pending(env, bit(rc.depth)), t1)
			}
		}
		Err(_) => (resource_inst(rc, last, s, owned, block), Pending(env, 0), fx_count(tx, Stale))
	}
}

## An asynchronous layer has no write handle, so an event below it can only
## have changed an outer layer (which will refresh this site) or nothing.
resource_settle : ResourceCfg(ctx, a, s), a, List(Owned(a)), Block(In(ctx, s)), Out(In(ctx, s)), Tx -> (Inst(ctx), Out(ctx), Tx)
	where [a.is_eq : a, a -> Bool, s.is_eq : s, s -> Bool]
resource_settle = |rc, last, owned, block, out, tx| {
	match out {
		Done => crash "internal: fire must hand the environment back"
		Orphaned(_) => crash "internal: fire must hand the environment back"
		Pending(next_inner, mask) => {
			{ outer, value } = next_inner
			(resource_inst(rc, last, value, owned, block), Pending(outer, mask), tx)
		}
	}
}

get_u32 : List(U8), U64, Str -> U32
get_u32 = |b, at, what| {
	b0 = (b.get(at) ?? crash "contract: truncated ${what}").to_u32()
	b1 = (b.get(at + 1) ?? crash "contract: truncated ${what}").to_u32()
	b2 = (b.get(at + 2) ?? crash "contract: truncated ${what}").to_u32()
	b3 = (b.get(at + 3) ?? crash "contract: truncated ${what}").to_u32()
	b0 + b1.shl_wrap(8) + b2.shl_wrap(16) + b3.shl_wrap(24)
}

get_u64 : List(U8), U64, Str -> U64
get_u64 = |b, at, what| get_u32(b, at, what).to_u64() + get_u32(b, at + 4, what).to_u64().shl_wrap(32)

get_str : List(U8), U64, Str -> (Str, U64)
get_str = |b, at, what| {
	n = get_u32(b, at, what).to_u64()
	bytes = b.sublist({ start: at + 4, len: n })
	if bytes.len() != n {
		crash "contract: truncated ${what}"
	}
	(Str.from_utf8(bytes) ?? crash "contract: ${what} text is not UTF-8", at + 4 + n)
}

## Boot bytes: `url:str count:u32 (key:str value:str)* online:u8
## visible:u8 storage:u8`. Empty bytes mean no boot data (online, visible,
## storage available). Anything else that does not follow the encoding is
## a contract error.
decode_boot : List(U8) -> Boot
decode_boot = |b| {
	if b.is_empty() {
		{ url: "", storage: [], online: Bool.True, visible: Bool.True, storage_available: Bool.True }
	} else {
		(url, a1) = get_str(b, 0, "boot bytes")
		n = get_u32(b, a1, "boot bytes").to_u64()
		var $at = a1 + 4
		var $kv = []
		var $i = 0.U64
		while $i < n {
			(k, a2) = get_str(b, $at, "boot bytes")
			(v, a3) = get_str(b, a2, "boot bytes")
			$kv = $kv.append((k, v))
			$at = a3
			$i = $i + 1
		}
		flag = |at| match b.get(at) {
			Ok(0) => Bool.False
			Ok(1) => Bool.True
			_ => crash "contract: boot bytes end without online, visible and storage flags (0 or 1)"
		}
		online = flag($at)
		visible = flag($at + 1)
		storage_available = flag($at + 2)
		if b.len() != $at + 3 {
			crash "contract: boot bytes carry ${(b.len() - $at - 3).to_str()} unexpected trailing bytes"
		}
		{ url, storage: $kv, online, visible, storage_available }
	}
}

new_tx : List(U8) -> Tx
new_tx = |cmds| { cmds, next: 1, free: [], routes: [], work: work_zero, paths: [[]], site_free: [], fx: fx_empty }

## One turn: fire down `path`, then the root's Changed pass, then the
## turn's focus commands (resolved now, so a reference mounted later in
## the same turn is found; a missing one is counted stale).
turn : App, List(U32), U32, Payload -> App
turn = |{ root, tx, programs }, path, h, payload| {
	(root2, out, tx2) = call(root, Root, Fire(path, 0, h, payload), bump(tx, w_turns, 1))
	mask = out_mask(out)
	if mask == 0 {
		{ root: root2, tx: flush_turn(tx2, programs), programs }
	} else {
		(root3, _, tx3) = call(root2, Root, Changed(mask), bump(tx2, w_dirty_roots, popcount(mask)))
		{ root: root3, tx: flush_turn(tx3, programs), programs }
	}
}

## The end of a turn (see [TurnEnd]): command 18 FOCUS op:u8 node:u32 for
## each focus request, and the catalogue check of each work request against
## the instance's `programs`.
flush_turn : Tx, List(Str) -> Tx
flush_turn = |tx, programs| {
	if tx.fx.focus.is_empty() {
		tx
	} else {
		reqs = tx.fx.focus
		var $tx = with_fx(tx, |fx| { ..fx, focus: [] })
		for entry in reqs {
			match entry {
				Focus(op, name) =>
					match $tx.fx.refs.find_first(|(n, _)| n == name) {
						Ok((_, node)) => {
							$tx = emit_op($tx, 18, |c| put_u32(c.append(op), node))
						}
						Err(_) => {
							$tx = with_fx($tx, |fx| { ..fx, stale: fx.stale + 1 })
						}
					}
				CheckProgram(program, path) =>
					if !programs.contains(program) {
						crash "contract: worker program \"${program}\" is not registered; add its registration to with_workers (site ${show_path(path)})"
					}
			}
		}
		$tx
	}
}

## Run queued follow-up turns in order, after the external turn that
## queued the first of them.
##
## What is bounded is a chain: a follow-up whose turn queues another, and
## so on. A follow-up queued by the external turn has depth 1, one queued
## by a turn of depth d has depth d + 1. Running one deeper than
## `max_turns` is a contract error, because only a feedback loop (a
## reaction that issues again what is answered again, a refusal retried
## while the table is still full) keeps a chain going; a fan-out of
## independent follow-ups from one turn is any number of depth-one turns.
##
## The depth needs no field. The queue only grows at its end, so entries
## sit in the order they were queued and turns run in non-decreasing
## depth. Follow-up ids are minted in increasing order, refusals from the
## request space and `Self` from the follow-up space (high bit set), and
## only follow-ups are queued. So when the turns of depth d begin, the
## counters of both spaces are a threshold: the entry run next has depth d
## if its id is below the threshold of its space, and otherwise was queued
## by a depth-d turn and opens depth d + 1, whose threshold is the counters
## at that moment. O(1) per turn.
##
## Total work is bounded too: at most `max_breadth(max_inflight)` turns per
## host call, which a chain-free fan-out reaches only by refusing more than
## 64 requests for every slot of the in-flight table.
drain : App -> App
drain = |app0| {
	var $app = app0
	var $turns = 0.U64
	var $depth = 1.U64
	var $below_next = app0.tx.fx.next
	var $below_inner = app0.tx.fx.inner
	breadth = max_breadth(app0.tx.fx.max)
	while !$app.tx.fx.queue.is_empty() {
		{ root, tx, programs } = $app
		q = tx.fx.queue.first() ?? crash "queue"
		deeper = if (q.id >= fx_inner_base) q.id >= $below_inner else q.id >= $below_next
		if deeper {
			$depth = $depth + 1
			$below_next = tx.fx.next
			$below_inner = tx.fx.inner
			if $depth > max_turns {
				crash "contract: an effect follow-up chain reached depth 65 at site ${show_path(q.path)}: each follow-up's turn queued another, more than 64 deep in one call (feedback loop)"
			}
		}
		if $turns >= breadth {
			crash "resource_limit: effect follow-up turns in one call exceeded 64 per in-flight slot (at least 4096); follow-ups are multiplying (feedback loop) or a fan-out is far past the in-flight bound (raise max_inflight)"
		}
		tx1 = with_fx(tx, |fx| { ..fx, queue: fx.queue.drop_first(1) })
		$app = turn({ root, tx: tx1, programs }, q.path, q.id, Fx(q.res))
		$turns = $turns + 1
	}
	$app
}

popcount : U64 -> U64
popcount = |m| {
	var $m = m
	var $n = 0.U64
	while $m != 0 {
		$m = $m.bitwise_and($m - 1)
		$n = $n + 1
	}
	$n
}

out_mask : Out(Root) -> U64
out_mask = |out| match out {
	Pending(_, m) => m
	_ => 0
}

## Hand over the command batch (taking `buf` in its place) and write the
## work record into `wbuf`.
finish : App, List(U8), List(U8) -> (App, List(U8), List(U8))
finish = |inst, buf, wbuf| {
	w = work_bytes(inst, wbuf)
	(a2, cmds) = Core.take_cmds(inst, buf)
	(a2, cmds, w)
}

## The work record (design.md, Appendix B): `count:u32 (counter:u64)*`
## in `w_` index order followed by the effect counters (`fx_counters`),
## then `n:u32 (name:str runs:u64)*` for the cleanups that have run.
## Written into `buf`, which is cleared first.
work_bytes : App, List(U8) -> List(U8)
work_bytes = |inst, buf| {
	counters = inst.tx.work
	var $b = put_u32(buf.clear(), w_record_count.to_u32_wrap())
	var $i = 0.U64
	while $i < w_count {
		$b = put_u64($b, work_get(counters, $i))
		$i = $i + 1
	}
	fx = inst.tx.fx
	$b = put_u64(put_u64(put_u64(put_u64($b, fx.issued), fx.delivered), fx.stale), fx.refused)
	$b = put_u64(put_u64(put_u64(put_u64($b, fx.cancelled), fx.reparented), fx.skipped), fx.live.len())
	runs = inst.tx.fx.cleanups
	$b = put_u32($b, runs.len().to_u32_wrap())
	for (name, k) in runs {
		$b = put_u64(put_str($b, name), k)
	}
	$b
}

# ------------------------------------------------------------------
# The settle check (`Core.settled`).

## What a settle pass changed in the effect channel besides commands, or ""
## when it changed nothing: a request refused at the bound or a follow-up
## queued emits no command, so the check compares the counters too.
settle_note : Fx, Fx -> Str
settle_note = |a, b| {
	pairs = [
		("issued", a.issued, b.issued),
		("refused", a.refused, b.refused),
		("stale", a.stale, b.stale),
		("cancelled", a.cancelled, b.cancelled),
		("in flight", a.live.len(), b.live.len()),
		("queued follow-ups", a.queue.len(), b.queue.len()),
		("end-of-turn focus requests and program checks", a.focus.len(), b.focus.len()),
	]
	changed = pairs.keep_if(|(_, x, y)| x != y).map(|(name, x, y)| "${name} ${x.to_str()} -> ${y.to_str()}")
	Str.join_with(changed, ", ")
}

## The worker catalogue lists its names in order, and a duplicate name or a
## 65th registration is the contract error that names the program.
expect {
	reg = |name| Core.registration(name, |b| b)
	var $many = []
	var $i = 0.U64
	while $i < 65 {
		$many = $many.append(reg("p${$i.to_str()}"))
		$i = $i + 1
	}
	actual = [
		Str.inspect(Core.catalogue([reg("a"), reg("b")])),
		Str.inspect(Core.catalogue([reg("a"), reg("b"), reg("a")])),
		Str.inspect(Core.catalogue($many.take_first(64)).is_ok()),
		Str.inspect(Core.catalogue($many)),
	]
	expected = [
		"Ok([\"a\", \"b\"])",
		"Err(\"contract: worker program \\\"a\\\" is registered twice in with_workers\")",
		"True",
		"Err(\"contract: with_workers registers more than 64 worker programs (program \\\"p64\\\" is over the bound)\")",
	]
	actual == expected
}

## A worker entry runs the named program on the input after the name, and its
## output is a list of its own even when the program returns a slice.
expect {
	p = Core.program(|| Core.text("")).with_workers([Core.registration("t/tail", |b| b.drop_first(1))])
	(Core.driver(p).work)(put_str([], "t/tail").concat([1, 2, 3]), []) == [2, 3]
}

## Work is scoped: when the site that issued it is disposed it is cancelled
## (CANCEL, counted `cancelled`) and leaves the in-flight table, like a timer.
expect {
	elem = Core.state(
		Bool.True,
		|st|
			Core.element(
				"div",
				[],
				[
					Core.when(st.val(), || Core.watch(Core.const({}), |_| [Work({ program: "t/echo", input: [1], files: [], deadline_ms: 0 })], Core.ignore({})), || Core.text("")),
					Core.watch(Core.const({}), |_| [Self], st.on_result(|_, _, _| Bool.False)),
				],
			),
	)
	mounted = mount_in(32, ["t/echo"], elem)
	s = Core.fx_stats(mounted)
	[s.issued, s.cancelled, s.live, s.reparented] == [1, 1, 0, 0]
}

## A page read's result: bytes as they are; text only when it is UTF-8, which
## is an answer about the file rather than a broken protocol.
expect {
	bytes = Core.decode_res([16, 1, 2])
	text = Core.decode_res([17, 104, 105])
	cut = Core.decode_res([17, 0xC3])
	bytes == FileBytes([1, 2]) and text == FileText("hi") and cut == FileFailed(InvalidUtf8) and Core.file_text(cut) == Err(InvalidUtf8) and Core.file_bytes(Refused) == Err(Refused)
}

## A digest result is exactly 32 bytes and a URL is text; a browser that
## cannot digest answers Unavailable.
expect {
	digest = Core.decode_res([18].concat(List.repeat(7, 32)))
	url = Core.decode_res([19].concat("blob:x".to_utf8()))
	unavailable = Core.decode_res([13, 3])
	Core.file_digest(digest) == Ok(List.repeat(7, 32)) and Core.file_url(url) == Ok("blob:x") and Core.file_digest(unavailable) == Err(Unavailable)
}
