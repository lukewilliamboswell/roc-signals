import Web
import PictureCapture
import Layout
import TableCore exposing [Table]
import View
import MarkupAdvice
import parser.Html as ParsedHtml
import parser.Markup

## The reactive engine behind the roc-signals web platform, written in Roc:
## the platform's internal module, which apps never import.
##
## `Engine.roc` is the authoring API over it; this module holds the
## implementation and the interfaces only the platform's hosts and test
## harnesses use: the [Program] glue the hosts call (`driver`), and mounting,
## driving and inspecting an instance directly (`mount`, `event`, `result`,
## `take_cmds`, `fx_stats`, ...). `design.md` ("Representation: Sites That
## Own Their Storage") describes the model; Appendix B specifies the command
## stream and the host protocol.

Core := [].{

	## The context at the top of the application: the context of the [Elem] that
	## `program`'s view returns. Nested contexts ([In], [Row]) are built on top
	## of it.
	##
	## It holds the program's store, of type `st` (`{}` for a program without
	## one; see [Store]). The instance owns the store beside its sites and moves
	## it into this context for each root call, taking it back from the answer.
	## As a state site moves its value, a write to a
	## cell is in place. Every scope type says how it reaches the store with
	## one method, `store`, which answers a [StoreReach] built on the
	## enclosing scope's, so a cell is read and written at any depth with no
	## `lift`.
	Root(st) := { store : st }.{

		## Evidence that this context has no enclosing row, without retaining its store.
		outside_rows : () -> OutsideRows(Root(st))
		outside_rows = || { proof: |context| context }

		## How the root reaches the store: it holds it.
		store : () -> StoreReach(Root(st), st)
		store = || {
			get: |r| r.store,
			over: |r, f| {
				{ store: held } = r
				Root.{ store: f(held) }
			},
		}
	}

	## The context inside a `state` or `derive` body: a layer holding a value of
	## type `s`, nested in `outer`. Values and handlers from `outer` enter with
	## `lift`.
	In(outer, s) := { outer : outer, value : s }.{

		## A layer remains outside rows only when its enclosing context is too.
		outside_rows : () -> OutsideRows(In(outer, s))
			where [outer.outside_rows : () -> OutsideRows(outer)]
		outside_rows = || {
			Outer : outer
			_ = Outer.outside_rows()
			{ proof: |context| context }
		}

		## How this scope reaches the root store: through the enclosing one.
		store : () -> StoreReach(In(outer, s), st)
			where [outer.store : () -> StoreReach(outer, st)]
		store = || {
			## The enclosing scope's type, named so its method can be called.
			Outer : outer
			up = Outer.store()
			up_get = up.get
			up_over = up.over
			{
				get: |i| up_get(i.outer),
				over: |i, f| {
					{ outer: held, value } = i
					In.{ outer: up_over(held, f), value }
				},
			}
		}
	}

	## The context inside one row of an `each` or a `table_view` template,
	## nested in `outer`: the row's key and item. Values and handlers from
	## `outer` enter with `lift_row`.
	##
	## A view's row is known by its item, the table's key, which its site
	## finds in an index of its own; it has no text key, so its `key` is
	## empty and nothing reads it.
	Row(outer, item) := { outer : outer, key : Str, item : item }.{

		## How this scope reaches the root store: through the enclosing one.
		store : () -> StoreReach(Row(outer, item), st)
			where [outer.store : () -> StoreReach(outer, st)]
		store = || {
			## The enclosing scope's type, named so its method can be called.
			Outer : outer
			up = Outer.store()
			up_get = up.get
			up_over = up.over
			{
				get: |r| up_get(r.outer),
				over: |r, f| {
					{ outer: held, key, item } = r
					Row.{ outer: up_over(held, f), key, item }
				},
			}
		}
	}

	## How a context `ctx` reaches the root store whose type is `st`: `get`
	## reads it, and `over` gives the context with a function applied to it,
	## which receives it uniquely owned. A context type answers one from its
	## `store` method, so reading and writing the store are one requirement
	## on a context: `where [ctx.store : () -> StoreReach(ctx, st)]`. The
	## method takes nothing because a `where` clause can require a method
	## of a type but not a value of it.
	StoreReach(ctx, st) :: { get : (ctx -> st), over : (ctx, (st -> st) -> ctx) }

	## The storage of the store that `tag` names: the nested pairs `st` its
	## [Cells] describe. `tag` is the type of the value given to `store_of`,
	## held nowhere, so two stores of one shape have different storage types
	## and a cell of one is a type error in a scope that reaches the other.
	Stored(tag, st) :: { st : st }

	## One cell of a root store whose type is `st`, holding an `a`. [Cells]
	## makes one for each `cell` it describes and [Store] gives them out
	## (`cells`). `cell` is the cell's position in the store,
	## which names it in a write set and gives its signature bit; `get` and
	## `modify` are the lens [Cells] generated for that position. The cell
	## is valid in every context whose root holds `st`: reading or writing it
	## needs no `lift`.
	Cell(st, a) := { cell : U64, get : (st -> a), modify : (st, (a -> a) -> st) }.{

		## The cell's current value, readable at any depth.
		signal : Cell(st, a) -> Signal(ctx, a)
			where [ctx.store : () -> StoreReach(ctx, st)]
		signal = |c| {
			## The context's type, named so its method can be called.
			Ctx : ctx
			store_get = Ctx.store().get
			g = c.get
			{ mask: cell_bit(c.cell), read: |e| g(store_get(e)), sel: NoSel }
		}

		## The cell as a [State] in the context where this is called: what a
		## component that takes a `State(ctx, a)` is given, so it cannot
		## tell a cell from a local state.
		state : Cell(st, a) -> State(ctx, a)
			where [ctx.store : () -> StoreReach(ctx, st)]
		state = |c| {
			## The context's type, named so its method can be called.
			Ctx : ctx
			reach = Ctx.store()
			store_get = reach.get
			store_over = reach.over
			g = c.get
			m = c.modify
			{ mask: cell_bit(c.cell), writes: one_cell(c.cell), get: |e| g(store_get(e)), modify: |e, f| store_over(e, |st| m(st, f)) }
		}

		## A [Write] that replaces the cell with `value`, for the list a
		## decision returns (`store_handler`, `store_reaction`).
		set : Cell(st, a), a -> Write(st)
		set = |c, value| {
			m = c.modify
			{ first: c.cell, count: 1, kind: Replace, apply: |st| m(st, |_| value) }
		}

		## A [Write] that replaces the cell with `f` of it. `f` receives the
		## value uniquely owned, so a large value is changed in place, as a
		## state's reducer changes its value.
		update : Cell(st, a), (a -> a) -> Write(st)
		update = |c, f| {
			m = c.modify
			{ first: c.cell, count: 1, kind: Change, apply: |st| m(st, f) }
		}
	}

	## One write to the store whose storage is `st`, as a value: which cells
	## it writes (`count` of them from position `first`) and how. A decision
	## (`store_handler`, `store_reaction`) returns a list of them, and the
	## engine applies the list to the store in order and reports exactly the
	## cells it names as written. Make one with `Cell.set`, `Cell.update` or
	## a group's reset (`Cells.with_reset`).
	##
	## `Replace` discards what the cells held; `Change` computes from it. A
	## `Change` after another write of its cell sees that write's result. A
	## decision must not throw away one of its own writes: a `Replace` of a
	## cell an earlier write of the same list wrote is a contract error,
	## unless that earlier write replaced a wider group of cells, which a
	## write of one of them refines (`writes_cells`).
	Write(st) :: { first : U64, count : U64, kind : [Replace, Change], apply : (st -> st) }

	## A handler that writes the cells `decide` names for the event's payload:
	## one pure function decides the whole transition. A cell it does not
	## name is not written, and its readers are not woken. The handler is
	## told the site that fired it, which the contract error of a replaced
	## write names.
	store_handler : (p -> List(Write(st))) -> HandlerOf(ctx, p)
		where [ctx.store : () -> StoreReach(ctx, st)]
	store_handler = |decide| {
		## The context's type, named so its method can be called.
		Ctx : ctx
		store_over = Ctx.store().over
		{ run: |e, p, site| store_writes(store_over, e, decide(p), Handler(site)) }
	}

	## As `store_handler`, where `decide` also receives `v`, read once when
	## the event fires, before any write of this decision: every write of
	## the decision is computed from that one reading. Composed after
	## another handler (`Handler.also`), it reads what that handler left.
	store_handler_by : Signal(ctx, b), (b, p -> List(Write(st))) -> HandlerOf(ctx, p)
		where [ctx.store : () -> StoreReach(ctx, st)]
	store_handler_by = |v, decide| {
		## The context's type, named so its method can be called.
		Ctx : ctx
		store_over = Ctx.store().over
		read = v.read
		{
			run: |e, p, site| {
				writes = decide(read(e), p)
				store_writes(store_over, e, writes, Handler(site))
			},
		}
	}

	## An effect site's [Reaction] that writes the cells `decide` names for
	## the value the request was issued for and its result.
	store_reaction : (r, result -> List(Write(st))) -> Reaction(ctx, r, result)
		where [ctx.store : () -> StoreReach(ctx, st)]
	store_reaction = |decide| {
		## The context's type, named so its method can be called.
		Ctx : ctx
		store_over = Ctx.store().over
		{ run: |e, r, res, site| store_writes(store_over, e, decide(r, res), Reaction(site)), progress: NoProgress }
	}

	## As `store_reaction`, where `decide` also receives `v`, read once when
	## the result arrives, before any write of this decision.
	store_reaction_by : Signal(ctx, b), (b, r, result -> List(Write(st))) -> Reaction(ctx, r, result)
		where [ctx.store : () -> StoreReach(ctx, st)]
	store_reaction_by = |v, decide| {
		## The context's type, named so its method can be called.
		Ctx : ctx
		store_over = Ctx.store().over
		read = v.read
		{
			run: |e, r, res, site| {
				writes = decide(read(e), r, res)
				store_writes(store_over, e, writes, Reaction(site))
			},
			progress: NoProgress,
		}
	}

	## A description of cells, for [Store]: the storage `st` the cells it
	## describes start with, how many there are, `make`, which builds their
	## cells `h` given the position of the first and the lens from the
	## whole store `whole` to `st`, and `restart`, which puts every one of
	## them back to the value it was described with, each through its own
	## lens. Combine descriptions with `map2`, which is what Roc's record
	## builder (`{ a: .., b: .. }.Cells`) calls: the storage of two
	## descriptions is the pair of theirs, so a description nested in
	## another (a feature's cells inside the app's) needs no lens either.
	## `tables` lists what the root needs of each table cell among them
	## (see [TableCell]), given the same position and modifier.
	Cells(whole, st, h) := { init : st, count : U64, make : (U64, (whole -> st), (whole, (st -> st) -> whole) -> h), restart : (st -> st), tables : (U64, (whole, (st -> st) -> whole) -> List(TableCell(whole))) }.{

		## Two descriptions side by side: `l`'s cells first, then `r`'s.
		map2 : Cells(whole, a, ha), Cells(whole, b, hb), (ha, hb -> hc) -> Cells(whole, (a, b), hc)
		map2 = |l, r, combine| {
			lm = l.make
			rm = r.make
			lr = l.restart
			rr = r.restart
			lt = l.tables
			rt = r.tables
			n = l.count
			{
				init: (l.init, r.init),
				count: l.count + r.count,
				make: |base, get, modify| {
					left = lm(base, |w| pair_first(get(w)), |w, f| modify(w, |(a, b)| (f(a), b)))
					right = rm(base + n, |w| pair_second(get(w)), |w, f| modify(w, |(a, b)| (a, f(b))))
					combine(left, right)
				},
				restart: |(a, b)| (lr(a), rr(b)),
				tables: |base, modify| lt(base, |w, f| modify(w, |(a, b)| (f(a), b))).concat(rt(base + n, |w, f| modify(w, |(a, b)| (a, f(b))))),
			}
		}

		## The same cells, handing out `f` of them.
		map : Cells(whole, st, h), (h -> k) -> Cells(whole, st, k)
		map = |d, f| {
			dm = d.make
			{ init: d.init, count: d.count, make: |base, get, modify| f(dm(base, get, modify)), restart: d.restart, tables: d.tables }
		}

		## The same cells, handing out `f` of them and of a [Write]
		## that starts every one of them again at the value its description
		## gave it. The write covers the description, not a list someone
		## keeps: a cell added to it later is started again by the same
		## write. Each cell is started again through its own lens, so a
		## table among them is taken as a whole rewrite and its views
		## rebuild.
		with_reset : Cells(whole, st, h), (h, Write(whole) -> k) -> Cells(whole, st, k)
		with_reset = |d, f| {
			dm = d.make
			restart = d.restart
			n = d.count
			{
				init: d.init,
				count: d.count,
				make: |base, get, modify| f(dm(base, get, modify), { first: base, count: n, kind: Replace, apply: |w| modify(w, restart) }),
				restart,
				tables: d.tables,
			}
		}
	}

	## The description of one cell starting at `init`, which is also what a
	## group's reset puts back in it.
	cell : a -> Cells(whole, a, Cell(whole, a))
	cell = |init| { init, count: 1, make: |base, get, modify| { cell: base, get, modify }, restart: |_| init, tables: |_, _| [] }

	## What the root site needs of a table cell of the store `st`: the cell's
	## position, `clear` for initialization, and `finish` to rearm the next
	## writing turn without changing the retained record. `stamp` gives a
	## Store value its table identity; `live` gives mounted storage an
	## identity no table read from a Store value carries.
	TableCell(st) : { cell : U64, clear : (st -> st), stamp : (st -> st), live : (st -> st), finish : (st -> st) }

	## The description of one cell holding a [Table] of `rows`, by key. It
	## is an ordinary cell: a decision changes it with `Cell.update` and the
	## table's own operations (`insert`, `put`, `update`, `remove`, `load`),
	## so each write records the rows it changed, and `table_view` draws a
	## filtered, sorted window of it from those changes.
	##
	## The cell's lens guards the changes: a write that leaves any other
	## table in the cell than the one it held (a `Cell.set` of a new one,
	## another cell's, an old copy, or the reset of the cell's group) is
	## taken as a whole rewrite (`Table.kept`), so no write can leave a view
	## stale. The first modifier of a turn clears the previous writing turn's
	## changes; the root rearms that step after every reader has refreshed.
	## Other modifiers of this event keep the first earlier row per key.
	table : List({ key : k, row : v }) -> Cells(whole, Table(k, v), Cell(whole, Table(k, v)))
		where [k.is_eq : k, k -> Bool, k.to_hash : k, Hasher -> Hasher]
	table = |rows| Core.table_of(rows, |table| table, |table| table)

	## Build the generated table lens through its public wrapper. Conversions
	## move the representation whole; the guard and bookkeeping remain here.
	table_of : List({ key : k, row : v }), (Table(k, v) -> wrapped), (wrapped -> Table(k, v)) -> Cells(whole, wrapped, Cell(whole, wrapped))
		where [k.is_eq : k, k -> Bool, k.to_hash : k, Hasher -> Hasher]
	table_of = |rows, wrap, unwrap| {
		init = wrap(Table.from_list(rows))
		{
			init,
			count: 1,
			make: |base, get, modify| {
				cell: base,
				get,
				modify: |w, f| modify(
					w,
					|t| {
						began = wrap(TableCore.begin_changes(unwrap(t)))
						before = TableCore.mark(unwrap(began))
						wrap(TableCore.kept(unwrap(f(began)), before))
					},
				),
			},
			restart: |t| wrap(TableCore.kept(unwrap(init), TableCore.mark(TableCore.begin_changes(unwrap(t))))),
			tables: |base, modify| [{ cell: base, clear: |w| modify(w, |t| wrap(TableCore.clear_changes(unwrap(t)))), stamp: |w| modify(w, |t| wrap(TableCore.with_id(unwrap(t), base + 1))), live: |w| modify(w, |t| wrap(TableCore.with_id(unwrap(t), base + 1 + live_ids))), finish: |w| modify(w, |t| wrap(TableCore.finish_changes(unwrap(t)))) }],
		}
	}

	## A program's store, built once from its [Cells]: the storage it starts
	## with, its cells, and the bookkeeping for its table cells.
	Store(st, h) := { init : st, cells : h, tables : List(TableCell(st)) }.{

		## The record of cells the [Cells] described.
		cells : Store(st, h) -> h
		cells = |s| s.cells

		## The same store with `c` starting at `value`, for a cell whose start
		## depends on the boot data. For a table cell, `value` is the table
		## `Table.from_list` gives. It is a start, not a write: the table's
		## changes are left empty, as it is for a table described with its
		## rows, so a pure test that applies writes after it (`after`) reads
		## those writes in the changes and nothing else.
		with_initial : Store(st, h), Cell(st, a), a -> Store(st, h)
		with_initial = |s, c, value| {
			m = c.modify
			{ init: s.tables.fold(m(s.init, |_| value), |st, t| (t.clear)(st)), cells: s.cells, tables: s.tables }
		}

		## What the root site starts with: storage whose tables have no changes
		## and carry live identities, and its table-cell bookkeeping. Restamping
		## only here keeps pure Store values out of the live identity space.
		initial : Store(st, h) -> Start(st)
		initial = |s| { st: s.tables.fold(s.init, |st, t| (t.live)((t.clear)(st))), tables: s.tables }

		## Apply one pure turn, validating the same-cell rule before any write.
		## Generated table modifiers begin recording once; the live root's
		## end-of-turn fold rearms only the exact table cells these writes name.
		## Unwritten tables retain their records. The metadata folds visit table
		## descriptors, never their rows; a first modifier may reclaim the
		## previous writing turn's recorded keys before applying its function.
		after : Store(st, h), List(Write(st)) -> Store(st, h)
		after = |{ init, cells: handles, tables }, writes| {
			wrote = writes_cells(writes, After)
			written = tables.fold(0.U128, |bits, descriptor| bits.bitwise_or(cell_bit(descriptor.cell)))
			next = writes.fold(init, |st, w| (w.apply)(st))
			{ init: end_tables(next, { cells: tables, written }, wrote), cells: handles, tables }
		}

		## What `c` holds in the store's starting storage: with `after`, what
		## a transition left in a cell.
		read : Store(st, h), Cell(st, a) -> a
		read = |s, c| (c.get)(s.init)
	}

	## What a root site starts with (see `Store.initial`).
	Start(st) : { st : st, tables : List(TableCell(st)) }

	## The start of a program without a store.
	no_store : Start({})
	no_store = { st: {}, tables: [] }

	## The store the cells `d` describe, named by `tag`: a value of a type
	## the app declares for this store and no other. Its storage is
	## `Stored(tag, st)`, so the cells of two stores whose cells have the
	## same types are still of different types. Each table among the cells
	## is given its cell's identity here.
	store_of : tag, Cells(Stored(tag, st), st, h) -> Store(Stored(tag, st), h)
	store_of = |_tag, d| {
		check_store_cells(d.count) ?? crash "resource_limit: store description has ${d.count.to_str()} cells; authored store structure must have fewer than ${live_ids.to_str()} cells to keep live and value table identities disjoint"
		m = d.make
		over = |w, f| {
			{ st: held } = w
			{ st: f(held) }
		}
		tables = (d.tables)(0, over)
		{ init: tables.fold({ st: d.init }, |st, t| (t.stamp)(st)), cells: m(0, |w| w.st, over), tables }
	}

	# Nominal rather than opaque (`::`): with the pinned compiler an opaque
	# `Signal` grows the Conduit wasm by about 220 KB at --opt=size.
	## A read-only signal of type `a`, readable in context `ctx`.
	##
	## A value records which layers it reads, so only the text, attributes and sites
	## that read a changed layer are re-evaluated. Make one with `const`,
	## `State.signal`, a [RowRef] accessor or `derive`, and transform it with `map` and
	## `map2`. A value is a recipe, not a cache: mapping functions run each time a
	## reader is re-evaluated, so they must be pure and should be cheap (`derive`
	## memoises an expensive or shared result).
	Signal(ctx, a) := { mask : U128, read : (ctx -> a), sel : Sel(ctx) }.{

		## Transform a value with a pure function. The result reads the same layers
		## as the input; the function runs wherever the result is read, each time a
		## read layer changes.
		map : Signal(ctx, a), (a -> b) -> Signal(ctx, b)
		map = |{ mask, read, sel }, f| { mask, read: |env| f(read(env)), sel }

		## Combine two values with a pure function. The result reads the union of
		## both inputs' layers.
		map2 : Signal(ctx, a), Signal(ctx, b), (a, b -> c) -> Signal(ctx, c)
		map2 = |l, r, f| {
			lr = l.read
			rr = r.read
			m = l.mask.bitwise_or(r.mask).bitwise_or(sel_mask(l.sel)).bitwise_or(sel_mask(r.sel))
			{ mask: m, read: |env| f(lr(env), rr(env)), sel: NoSel }
		}

		## Use a value from the enclosing context inside a `state` or `derive` body
		## nested in it. The value keeps reading the same layers.
		lift : Signal(ctx, a) -> Signal(In(ctx, s), a)
		lift = |{ mask, read, sel }| {
			sel2 = match sel {
				NoSel => NoSel
				Sel(m, k) => Sel(m, |e| k(e.outer))
			}
			{ mask, read: |e| read(e.outer), sel: sel2 }
		}

		## Use a value from the enclosing context inside an `each` row template
		## nested in it. The value keeps reading the same layers.
		lift_row : Signal(ctx, a) -> Signal(Row(ctx, item), a)
		lift_row = |{ mask, read, sel }| {
			sel2 = match sel {
				NoSel => NoSel
				Sel(m, k) => Sel(m, |e| k(e.outer))
			}
			{ mask, read: |e| read(e.outer), sel: sel2 }
		}
	}

	## Assemble an interpolation with one reader. Preserve a lone keyed
	## selector only when every other part reads no layer or cell; otherwise
	## selection dependencies join the ordinary signature as in map2.
	join_text : List({ prefix : Str, value : Signal(ctx, Str) }), Str -> Signal(ctx, Str)
	join_text = |parts, suffix| {
		if parts.is_empty() {
			return Core.const(suffix)
		}
		var $mask = 0.U128
		var $other_mask = 0.U128
		var $selection_mask = 0.U128
		var $selection_count = 0.U64
		var $selection = NoSel
		for part in parts {
			$mask = $mask.bitwise_or(part.value.mask)
			match part.value.sel {
				NoSel => {
					$other_mask = $other_mask.bitwise_or(part.value.mask)
				}
				Sel(mask, read) => {
					$selection_count = $selection_count + 1
					$selection_mask = $selection_mask.bitwise_or(mask)
					$selection = Sel(mask, read)
				}
			}
		}
		keeps_selection = $selection_count == 1 and $other_mask == 0
		readers = parts.map(|{ prefix, value }| { prefix, read: value.read })
		{
			mask: if (keeps_selection) $mask else $mask.bitwise_or($selection_mask),
			sel: if (keeps_selection) $selection else NoSel,
			read: |env| {
				var $pieces = []
				for { prefix, read } in readers {
					$pieces = $pieces.append(prefix).append(read(env))
				}
				Str.join_with($pieces.append(suffix), "")
			},
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
	## task's job, with effects that bring across exactly the range the job
	## asks for (`read!`, `contents!`); or ask for them on the page with an
	## awaited request (`read_bytes`, `read_utf8`) when bringing them into the
	## page's memory is acceptable.
	##
	## A file stays available while any value holds it: keep it in a state for
	## as long as the app needs it, and it is released when nothing refers to it
	## any more. Two files are equal when they are the same range of the same
	## file.
	##
	## A file in a worker job carries the platform's hosted effects with it,
	## handed to the engine when the job started, so its effects are methods
	## (`file.read!(...)`); the engine itself reaches no hosted function.
	File :: { blob : Blob, name : Str, mime : Str, size : U64, start : U64, len : U64, reach : Reach }.{

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

		## The ranges of `chunk` bytes, in order, that cover the file or range
		## (the last one shorter, none for an empty file), each one an argument
		## for `read!`: a job reads a large file a chunk at a time with
		## `for span in file.spans(n) { bytes = file.read!(span)? ... }`. A
		## chunk of 0 bytes is a contract error.
		spans : File, U64 -> List({ start : U64, len : U64 })
		spans = |f, chunk| {
			if chunk == 0 {
				crash "contract: File.spans of \"${f.name}\" asked for spans of 0 bytes"
			}
			var $spans = []
			var $at = 0
			while $at < f.len {
				len = (f.len - $at).min(chunk)
				$spans = $spans.append({ start: $at, len })
				$at = $at + len
			}
			$spans
		}

		## A request to read the file's bytes into the page, for an effect
		## site's plan: `file.read_bytes({})`, or `file.read_bytes({ max_bytes })`
		## to change how much the app accepts (see [ReadProps]). Its result is
		## `Ok(bytes)`, or `Err` with `TooLarge` (more than
		## `max_bytes`, or than the page's `maxFileBytes` mount option allows;
		## nothing is read) or `Unreadable` (the user's file changed or went
		## away). The browser reads the file on the
		## page's thread into a buffer of its own and the bytes are copied once
		## into the page's memory, so keep it for small files and send large
		## ones to a worker task. The request holds the file until it is
		## answered, and disposing its site cancels it.
		read_bytes : File, ReadProps -> Ask(List(U8), FileError)
		read_bytes = |f, ReadProps.({ max_bytes })| Core.make_ask(ReadBytes({ file: f, max_bytes }), Core.file_bytes)

		## A request to read the file into the page as text: as `read_bytes`,
		## answered `Ok(text)`, or `Err(InvalidUtf8)` when the bytes
		## are not UTF-8. A byte-order mark is kept.
		read_utf8 : File, ReadProps -> Ask(Str, FileError)
		read_utf8 = |f, ReadProps.({ max_bytes })| Core.make_ask(ReadUtf8({ file: f, max_bytes }), Core.file_text)

		## A request that sends the file, or its range, as the body of an HTTP
		## request, for an effect site's plan:
		## `file.upload({ url: "/upload" })` (see [UploadProps]). The browser
		## streams it from the file: its bytes never enter the page's memory.
		## Its typed result retains the response status, headers and text body,
		## or an HTTP failure. Like HTTP, it is kept when its site is
		## disposed and answered to the nearest surviving ancestor. A file the
		## browser can no longer read fails the request, which the browser
		## reports as a network failure.
		upload : File, UploadProps -> Ask(Response, HttpFailure)
		upload = |f, UploadProps.({ url, method, headers, timeout, credentials })| {
			timeout_ms = Core.timeout_wire(timeout)
			Core.make_ask(Upload({ method, url, headers, body: f, timeout_ms, credentials }), read_http_response)
		}

		## A request for the SHA-256 digest of the file, or its range: answered
		## `Ok(bytes)` with its 32 bytes. The
		## browser reads the range into a buffer of its own, off the page's
		## memory, and digests it with WebCrypto. A range over the
		## `maxFileBytes` mount option (256 MiB by default) is
		## `Err(TooLarge)`, a browser without WebCrypto (a page not
		## served over HTTPS or from localhost) `Err(Unavailable)`. Like a
		## timer it belongs to its site.
		sha256 : File -> Ask(List(U8), FileError)
		sha256 = |f| Core.make_ask(Sha256(f), Core.file_digest)

		## A request for a URL the page can show the file, or its range, by:
		## an `<img>`'s or a `<video>`'s `src`. Answered `Ok(url)`.
		## The URL is valid exactly as long as the file's handle:
		## when no value holds the file any more, the browser forgets the URL,
		## so keep the file beside the URL for as long as it is shown. Asking
		## twice for the same range answers the same URL; a file gives at most
		## 16 ranges URLs, and a 17th is `Err(TooLarge)`. Like a timer it
		## belongs to its site.
		object_url : File -> Ask(Str, FileError)
		object_url = |f| Core.make_ask(ObjectUrl(f), Core.file_url)

		## Equal when they are the same range of the same file.
		is_eq : File, File -> Bool
		is_eq = |a, b| a.start == b.start and a.len == b.len and a.name == b.name and a.blob.token() == b.blob.token()

		# -- Tasks: effects on a file, and saving and fetching ----------------

		## In a task's job (`Worker.task`, or a preparation's `prepare!`): `len`
		## bytes at `start` of the file (relative to this file or range), read
		## from the browser into the job's memory, or `Unreadable` when the
		## browser can no longer read the file (the user's file changed or went
		## away). One read copies the bytes once; reading a large file in chunks
		## keeps the job's memory to a chunk. A range that does not lie within
		## the file is a contract error. Outside a job a file has no reader:
		## page code cannot call an effect, and the host refuses one anywhere
		## else.
		read! : File, { start : U64, len : U64 } => Try(List(U8), [Unreadable])
		read! = |f, { start, len }| {
			if start > f.len or len > f.len - start {
				crash "contract: File.read! of ${start.to_str()}+${len.to_str()} bytes lies outside \"${f.name}\" (${f.len.to_str()} bytes)"
			}
			effects = job_effects(f, "File.read!")
			bytes = (effects.read!)(f.blob.token(), f.start + start, len)
			if (bytes.len() == len) Ok(bytes) else Err(Unreadable)
		}

		## In a task's job: the whole file, or range, as `read!` reads it.
		## For a file larger than a job should hold at once, read it in chunks
		## with `read!`.
		contents! : File => Try(List(U8), [Unreadable])
		contents! = |f| File.read!(f, { start: 0, len: f.len })

		## In a task's job: the whole file as text, `InvalidUtf8` when its
		## bytes are not UTF-8 (a byte-order mark is kept), or `Unreadable`.
		contents_utf8! : File => Try(Str, [Unreadable, InvalidUtf8])
		contents_utf8! = |f| {
			bytes = File.contents!(f)?
			Str.from_utf8(bytes).map_err(|_| InvalidUtf8)
		}

		## How a file is saved: under its own name (`Same`) or another
		## (`Named(name)`).
		SaveProps := { name : [Same, Named(Str)] ?? Same }

		## A command that saves the file, or its range, to the user's disk as
		## a download, for an effect site's plan. The browser decides where it
		## goes (usually the downloads folder, without asking). It is emitted
		## and forgotten: there is no result, and the app learns nothing of
		## whether the user kept it.
		##
		## A save issued in the turn of a click runs inside that click, and
		## browsers allow it. Issued later (from a task's answer, say) it runs
		## without the user's gesture, and a browser may hold back a second
		## automatic download from the page or ask the user first: give the
		## user a button to press when the file is ready instead.
		##
		## Its type is the one tag it returns, so it fits a list of
		## [Request]s and a cleanup's list of [Command]s alike.
		save : File, SaveProps -> [Save({ file : File, name : Str })]
		save = |f, props| {
			chosen = match props.name {
				Same => f.name
				Named(n) => n
			}
			Save({ file: f, name: chosen })
		}

		## How a download into a file is asked for: the URL, the method, the
		## request headers, and a timeout (`Unlimited` by default; capped at
		## ten minutes), with browser cache and credentials policies. `Ms(0)`
		## is a contract error; use `Unlimited` explicitly for no timeout.
		FetchProps := { url : Str, method : Web.Method ?? "GET", headers : List((Str, Str)) ?? [], timeout : [Unlimited, Ms(U32)] ?? Unlimited, cache : Cache ?? Default, credentials : Credentials ?? SameOrigin }

		## A request for an HTTP response whose body becomes a [File], for an
		## effect site's plan: the body stays outside Wasm, and the file can be read, digested, shown,
		## uploaded, saved or sent to a task like any other. It is answered
		## `Ok({ status, headers, body })` for any status, or an HTTP failure,
		## or `Err(TooLarge)` for a body over the `maxFileBytes` mount option.
		## Like an HTTP request it is kept when its site is
		## disposed and answered to the nearest surviving ancestor. With progress,
		## Default cache uses the browser’s Blob path; other cache policies collect
		## streamed chunks in JavaScript, bounded by maxFileBytes.
		fetch : FetchProps -> Ask(Fetched, FetchFailure)
		fetch = |props| {
			{ url, method, headers, timeout, cache, credentials } = props
			timeout_ms = Core.timeout_wire(timeout)
			Core.make_ask(Fetch({ method, url, headers, timeout_ms, cache, credentials }), read_fetch_response)
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

	## A file a task's job is writing (`Files.build!`): private to the job,
	## which appends to it and then finishes it into an immutable [File]. It
	## cannot be sent anywhere: only the file it finishes into can be in an
	## answer. The builder's parts go when the job ends, whether or not it
	## finished, and a builder used after the call that opened it has ended
	## is a contract error.
	Builder :: { handle : Box(U64), name : Str, mime : Str, effects : JobEffects }.{

		## Append a copy of `bytes`. `TooLarge` when the bytes this job has
		## appended to its builders would exceed the `maxOutputBytes` mount
		## option (256 MiB by default): nothing is appended, and the job
		## decides what to do. Appending to a builder after `finish!` is a
		## contract error.
		append! : Builder, List(U8) => Try({}, [TooLarge])
		append! = |b, bytes| match (b.effects.append!)(Box.unbox(b.handle), bytes) {
			0 => Ok({})
			1 => Err(TooLarge)
			status => builder_refused(b, "append!", status)
		}

		## Append a file the job holds, or a range of one, by reference: the
		## bytes are not copied and do not count against `maxOutputBytes`.
		## Appending to a builder after `finish!` is a contract error.
		append_file! : Builder, File => {}
		append_file! = |b, f| {
			{ token, start, len } = file_ref(f)
			match (b.effects.append_file!)(Box.unbox(b.handle), token, start, len) {
				0 => {}
				status => builder_refused(b, "append_file!", status)
			}
		}

		## Finish the builder into an immutable file holding everything
		## appended, in order. Finishing twice is a contract error.
		finish! : Builder => File
		finish! = |b| {
			handle = (b.effects.mint!)()
			token = Box.unbox(handle)
			match (b.effects.finish!)(Box.unbox(b.handle), token) {
				0 => {}
				status => builder_refused(b, "finish!", status)
			}
			size = (b.effects.size!)(token)
			{ blob: Blob.(handle), name: b.name, mime: b.mime, size, start: 0, len: size, reach: InJob(b.effects) }
		}
	}

	## How a task's [Builder] starts: the new file's `name`, its media
	## `mime` type (`Auto`: the type of the file it starts from, or none),
	## and what it starts with: nothing (`Empty`), or the bytes of a file
	## the job holds (`From(file)`), by reference, without copying them.
	BuildProps := { name : Str, mime : [Auto, Mime(Str)] ?? Auto, start_from : [Empty, From(File)] ?? Empty }

	## For the platform's `Files.build!`: open a [Builder] with the job's
	## hosted effects, which the builder and the file it finishes carry.
	## `build!` has no file to carry the effects to it, so it is the one
	## effect a task reaches through a platform-only module.
	open_builder! : JobEffects, BuildProps => Builder
	open_builder! = |effects, props| {
		{ name: called, mime: wanted, start_from } = props
		type = match (wanted, start_from) {
			(Mime(m), _) => m
			(Auto, From(source)) => source.mime
			(Auto, Empty) => ""
		}
		handle = (effects.mint!)()
		token = Box.unbox(handle)
		status = match start_from {
			Empty => (effects.open!)(token, called.to_utf8(), type.to_utf8(), 0, 0, 0)
			From(source) => {
				{ token: from, start, len } = file_ref(source)
				(effects.open!)(token, called.to_utf8(), type.to_utf8(), from, start, len)
			}
		}
		if status != 0 {
			crash "internal: the host could not open a builder (status ${status.to_str()})"
		}
		{ handle, name: called, mime: type, effects }
	}

	## The hosted effects of a worker job (design.md, "Workers"), as the
	## platform hands them to the engine when it starts a job, a
	## preparation or a question (`work!`, `work_prepare!`, `work_ask!`).
	## The engine never reaches a hosted function itself: the files and
	## builders made in that call carry these, and their methods call them.
	## Each takes a handle's token as `Hosted.roc` describes it.
	JobEffects : {
		read! : U64, U64, U64 => List(U8),
		size! : U64 => U64,
		mint! : () => Box(U64),
		open! : U64, List(U8), List(U8), U64, U64, U64 => U8,
		append! : U64, List(U8) => U8,
		append_file! : U64, U64, U64, U64 => U8,
		finish! : U64, U64 => U8,
	}

	## The files one event delivered, and how many more it carried than the
	## instance could take.
	Received : { files : List(File), refused : U64 }

	## How much a read of a file into the page accepts (`File.read_bytes`,
	## `File.read_utf8`): `max_bytes`, 8 MiB unless the app says otherwise.
	## A larger file or range is answered `FileFailed(TooLarge)` without
	## being read. The page's `maxFileBytes` mount option (256 MiB by
	## default) caps it whatever the app asks: what the app means is decided
	## here, what a deployment allows is the mount's.
	ReadProps := { max_bytes : U64 ?? 8388608 }

	## Browser cache policy carried unchanged to the network service.
	Cache : [Default, NoStore, Reload, NoCache, ForceCache]

	## Same-origin credentials by default; Include also permits cross-origin credentials.
	Credentials : [SameOrigin, Include]

	## A timeout as a request carries it. Zero means none on the wire, so
	## callers use Unlimited explicitly rather than asking for Ms(0).
	timeout_wire : [Unlimited, Ms(U32)] -> U32
	timeout_wire = |timeout| match timeout {
		Unlimited => 0
		Ms(0) => crash "contract: a timeout of Ms(0) would be read as no timeout; write Unlimited for none, or a timeout of at least 1 ms"
		Ms(ms) => ms
	}

	## HTTP options with browser defaults, for an effect site’s plan. A
	## finite timeout is at least one millisecond; Ms(0) is a contract error.
	HttpProps := { url : Str, method : Web.Method ?? "GET", headers : List((Str, Str)) ?? [], body : Str ?? "", timeout : [Unlimited, Ms(U32)] ?? Unlimited, cache : Cache ?? Default, credentials : Credentials ?? SameOrigin }

	## Build an HTTP request without repeating its default method, body or policies.
	http : HttpProps -> Ask(Response, HttpFailure)
	http = |props| Core.make_ask(
		Http({
			method: props.method,
			url: props.url,
			headers: props.headers,
			body: props.body,
			timeout_ms: Core.timeout_wire(props.timeout),
			cache: props.cache,
			credentials: props.credentials,
		}),
		read_http_response,
	)

	## How to send a file as an HTTP body (`File.upload`):
	##
	## - `url`: where to send it; required.
	## - `method`: `"POST"` unless the app says otherwise. A method that
	##   carries no body (`GET`, `HEAD`) is a contract error.
	## - `headers`: none by default; given as `(name, value)` pairs, as an
	##   `Http` request's are.
	## - `timeout`: `Ms(ms)` answers `Timeout` when the server has not
	##   answered in time, capped at ten minutes; `Unlimited` by default.
	##   `Ms(0)` is a contract error; a finite timeout is at least one millisecond.
	## - `credentials`: SameOrigin by default, or Include for credentials across origins.
	UploadProps := {
		url : Str,
		method : Web.Method ?? "POST",
		headers : List((Str, Str)) ?? [],
		timeout : [Unlimited, Ms(U32)] ?? Unlimited,
		credentials : Credentials ?? SameOrigin,
	}

	## A text handler is the generic family specialised to UTF-8 text.
	Handler(ctx) : HandlerOf(ctx, Str)

	## A file handler is the same family specialised to received handles.
	FilesHandler(ctx) : HandlerOf(ctx, Received)

	## An event handler usable in context `ctx`: what an event writes, given its
	## payload (an input's text, a checkbox's Boolean checked state or `""` for a
	## click). Make one with the [State] methods or with `store_handler`, and
	## attach it with `on`, `on_click` or an `Html` control. A handler runs once
	## per event, in the turn that delivers it.
	##
	## `run` is given the environment, the payload and the path of the site
	## that fired it (for a diagnostic), and returns the environment with its
	## writes applied and the exact set of layers and cells it wrote. The set
	## is the handler's answer, not a property known before it runs, so a
	## handler that decides what to write from what it reads (`store_handler`)
	## reports only the writes it made.
	HandlerOf(ctx, p) := { run : (ctx, p, List(U32) -> (ctx, Layers)) }.{

		## Map an incoming payload using a reading taken before this handler writes.
		from_payload_by : HandlerOf(ctx, q), Signal(ctx, b), (b, p -> q) -> HandlerOf(ctx, p)
		from_payload_by = |{ run }, { read, .. }, convert| {
			run: |env, payload, site| run(env, convert(read(env), payload), site),
		}

		## Use a handler from the enclosing context inside a `state` or `derive` body
		## nested in it.
		lift : HandlerOf(ctx, p) -> HandlerOf(In(ctx, s), p)
		lift = |{ run }| {
			run: |e, p, site| {
				{ outer, value } = e
				(next, wrote) = run(outer, p, site)
				(In.{ outer: next, value }, wrote)
			},
		}

		## Use a handler from the enclosing context inside an `each` row template
		## nested in it.
		lift_row : HandlerOf(ctx, p) -> HandlerOf(Row(ctx, item), p)
		lift_row = |{ run }| {
			run: |e, p, site| {
				{ outer, key, item } = e
				(next, wrote) = run(outer, p, site)
				(Row.{ outer: next, key, item }, wrote)
			},
		}

		## One handler that runs `first` and then `second` for the same
		## event, as one atomic write: `second` receives the environment
		## `first` returned, so it sees `first`'s writes (two writes of one
		## state compose), and the event reports the union of both write
		## sets, which one pass settles from the outermost down
		## (`waits_for_outer`). An element
		## takes one handler per event, so this is how a click writes local
		## state and also runs a decision, or a handler its owner passed
		## down. Costs one closure call more per event.
		also : HandlerOf(ctx, p), HandlerOf(ctx, p) -> HandlerOf(ctx, p)
		also = |first, second| {
			run_first = first.run
			run_second = second.run
			{
				run: |e, p, site| {
					(e1, w1) = run_first(e, p, site)
					(e2, w2) = run_second(e1, p, site)
					(e2, layers_or(w1, w2))
				},
			}
		}
	}

	## A handle on one `state` layer holding an `s`, usable in context `ctx`.
	##
	## Read it with `signal`; write it only through handlers (`update`, `set_value`,
	## ...) and reactions (`on_result`). A write marks the layer changed and its
	## readers refresh; equality pruning happens where the value is read (text,
	## attributes, rows, `derive`), not at the state, so a reducer that returns an
	## equal value still costs a refresh pass but emits no DOM commands. Reducers
	## receive the value uniquely owned, so list and record updates happen in place.
	##
	## `mask` is what a reader of the handle listens to and `writes` what a
	## write through it reports. For a state layer both name the layer; a
	## store cell seen as a state (`Cell.state`) names the cell, and a view
	## row's handle reads the row's layer and writes the table's cell.
	State(ctx, s) := { mask : U128, writes : Layers, get : (ctx -> s), modify : (ctx, (s -> s) -> ctx) }.{

		## The state's current value.
		signal : State(ctx, s) -> Signal(ctx, s)
		signal = |{ mask, writes: _, get, modify: _ }| { mask, read: get, sel: NoSel }

		## A handler that replaces the state with `f` of it, ignoring the event's
		## payload.
		update : State(ctx, s), (s -> s) -> HandlerOf(ctx, p)
		update = |{ mask: _, writes: wrote, get: _, modify }, f| {
			{ run: |e, _, _| (modify(e, f), wrote) }
		}

		## A handler whose reducer also receives `v`, read in the handler's context
		## when the event fires (typically the row key or a row field), so a row's
		## handler needs no captured row.
		update_by : State(ctx, s), Signal(ctx, b), (s, b -> s) -> HandlerOf(ctx, p)
		update_by = |{ mask: _, writes: wrote, get: _, modify }, v, f| {
			read = v.read
			{
				run: |e, _, _| {
					b = read(e)
					(modify(e, |s| f(s, b)), wrote)
				},
			}
		}

		## An effect site's [Reaction] that writes this state: the reducer receives
		## the value the request was issued for and its typed result. If the state has been
		## disposed by the time a reparented result arrives, the write is skipped and
		## counted (`skipped`).
		on_result : State(ctx, s), (s, a, result -> s) -> Reaction(ctx, a, result)
		on_result = |{ mask: _, writes: wrote, get: _, modify }, f| {
			{ run: |e, a, r, _| (modify(e, |s| f(s, a, r)), wrote), progress: NoProgress }
		}

		## Reduce a sampled transfer count into this state. Reparented writes to
		## retired state are skipped in the same way as final-result writes.
		on_progress : State(ctx, s), (s, a, Transfer -> s) -> ProgressReaction(ctx, a)
		on_progress = |{ mask: _, writes: wrote, get: _, modify }, f| { run: |env, a, transfer, _| (modify(env, |value| f(value, a, transfer)), wrote) }

		## A handler whose reducer receives its typed payload: text, received
		## file handles, or another kind chosen by its attach function.
		set_value : State(ctx, s), (s, p -> s) -> HandlerOf(ctx, p)
		set_value = |{ mask: _, writes: wrote, get: _, modify }, f| {
			{ run: |e, p, _| (modify(e, |s| f(s, p)), wrote) }
		}

		## A handler whose reducer receives both `v`, read when the event fires, and
		## the event's payload.
		set_value_by : State(ctx, s), Signal(ctx, b), (s, b, p -> s) -> HandlerOf(ctx, p)
		set_value_by = |{ mask: _, writes: wrote, get: _, modify }, v, f| {
			read = v.read
			{
				run: |e, p, _| {
					b = read(e)
					(modify(e, |s| f(s, b, p)), wrote)
				},
			}
		}

		## Use state from the enclosing context inside a `state` or `derive`
		## body nested in it.
		lift : State(ctx, s) -> State(In(ctx, t), s)
		lift = |{ mask, writes, get, modify }| {
			mask,
			writes,
			get: |e| get(e.outer),
			modify: |e, f| {
				{ outer, value } = e
				In.{ outer: modify(outer, f), value }
			},
		}

		## Use state from the enclosing context inside an `each` row template
		## nested in it.
		lift_row : State(ctx, s) -> State(Row(ctx, item), s)
		lift_row = |{ mask, writes, get, modify }| {
			mask,
			writes,
			get: |e| get(e.outer),
			modify: |e, f| {
				{ outer, key, item } = e
				Row.{ outer: modify(outer, f), key, item }
			},
		}
	}

	## A keyed selection for `RowRef.select`: the selected key and the values a
	## selected and an unselected row see. Make one with `keyed`.
	Keyed(ctx, v) :: { mask : U128, selected : (ctx -> Str), yes : v, no : v }

	## `keyed(selected, yes, no)`: rows whose key equals `selected` see `yes`, all
	## others `no`. Read through `RowRef.select`, a change of `selected`
	## re-evaluates exactly the previously and the newly selected rows instead of
	## every row.
	keyed : Signal(ctx, Str), v, v -> Keyed(ctx, v)
	keyed = |sv, yes, no| {
		{ mask, read, sel } = sv
		{ mask: mask.bitwise_or(sel_mask(sel)), selected: read, yes, no }
	}

	## The current row of an `each` template. The template runs once per `each`
	## site, not once per row, so it reads the row through these accessors rather
	## than receiving a row value.
	RowRef(outer, item) := { depth : U64 }.{

		## The row's key. It is fixed for the row's lifetime, so it never triggers a refresh.
		key : RowRef(outer, item) -> Signal(Row(outer, item), Str)
		key = |_| { mask: 0, read: |e| e.key, sel: NoSel }

		## A projection of the row's item. It is re-evaluated only for rows whose new
		## item differs from the old one.
		field : RowRef(outer, item), (item -> a) -> Signal(Row(outer, item), a)
		field = |{ depth }, f| { mask: bit(depth), read: |e| f(e.item), sel: NoSel }

		## The row's whole item: what a handler or a reaction of the row
		## takes as its reading. Like `field`, it is re-evaluated only for
		## rows whose new item differs from the old one.
		item : RowRef(outer, item) -> Signal(Row(outer, item), item)
		item = |{ depth }| { mask: bit(depth), read: |e| e.item, sel: NoSel }

		## `yes` or `no` from a [Keyed] selection, depending on whether this row's key
		## is the selected one.
		select : RowRef(outer, item), Keyed(outer, v) -> Signal(Row(outer, item), v)
		select = |_, kd| {
			{ mask, selected, yes, no } = kd
			{ mask: 0, read: |e| if (selected(e.outer) == e.key) yes else no, sel: Sel(mask, |e| selected(e.outer)) }
		}
	}

	## An attribute, event listener or focus reference on an element, in context
	## `ctx`. Make one with `attr`, `attr_s`, `attr_presence`, `class`,
	## `class_s`, `test_id`,
	## `test_id_s`, `on`, `on_click`, `ref` or `ref_s`.
	Attr(ctx) :: [Static(Web.AttrName, Str), Dyn(Web.AttrName, Signal(ctx, [Absent, Present(Str)])), On(EventDecl, RoutedHandler(ctx)), KeyOn(EventDecl, RoutedHandler(ctx), Signal(ctx, Str)), ShownOn(U8, Signal(ctx, Str), HandlerOf(ctx, Bool), Str), Property(U8, Str), PropertyV(U8, Signal(ctx, Str)), Ref(Signal(ctx, Str))]

	## A piece of UI in context `ctx`: an element, a text node or a dynamic site
	## (`state`, `derive`, `resource`, `when`, `switch`, `remount_on`, `each`,
	## `table_view` or an effect site).
	## An `Elem` is a description; the engine mounts it once and afterwards updates
	## only what reads a changed layer.
	Elem(ctx) :: [
		Element({ name : Web.Tag, container : [Children, TemplateContent] }, List(Attr(ctx)), List(Elem(ctx))),
		Comment(Str),
		Placed(List([Svg]), Elem(ctx)),
		Text(Str),
		Fragment(List(Elem(ctx))),
		TextV(Signal(ctx, Str)),

		## A dynamic site and its conservative read mask, given the depth the
		## site is mounted at (computed without mounting it).
		Site(Mount(ctx), (U64 -> U128)),
	]

	## `state(init, body)` adds a state layer, starting at `init`, for the elements
	## `body` builds. There is one instance per mount of the site (so one per row
	## inside an `each` row) and it lives as long as the enclosing scope: it is
	## dropped when its branch or row is disposed, and starts again at
	## `init` if remounted. Values from the enclosing context enter `body` with
	## `lift`. Layers nest without limit: past 64 nested layers on one path a
	## write can cost a few extra evaluations, which equality pruning discards.
	state : s, (State(In(ctx, s), s) -> Elem(In(ctx, s))) -> Elem(ctx)
	state = |init, body| Site(
		Mount(
			|env, args, tx| {
				depth = layer(args.depth)
				elem = body(state_handle(depth))
				(block, tx1) = mount_block(In.{ outer: env, value: init }, elem, depth, args.path, args.parent, args.before, { cap: args.cap, enclosing: args.enclosing }, tx)
				reads = block.reads
				(state_inst(init, block, depth, Settled), reads, tx1)
			},
		),
		# The static reads are the mounted ones, this layer and those below
		# it included: a pass that settles a write of them comes from this
		# site or from above it, so a conditional whose unmounted branch
		# holds this site must listen to them too.
		|d| {
			d1 = layer(d)
			elem_reads(body(state_handle(d1)), d1)
		},
	)

	## `each(rows, key, template)` renders one row per item of `rows`, identified by
	## `key(item)`. Rows are matched by key across updates: a surviving row is kept
	## (and moved if needed) rather than rebuilt, a row whose item is unchanged does
	## no work, and a changed item re-evaluates only that row's holes that read it.
	##
	## `template` runs once per site against a [RowRef] and must return a single
	## element. A duplicate key is a contract error. References in a template
	## are evaluated for each drawn row and must have distinct live names.
	each : Signal(ctx, List(item)), (item -> Str), (RowRef(ctx, item) -> Elem(Row(ctx, item))) -> Elem(ctx)
		where [item.is_eq : item, item -> Bool]
	each = |rows, key, template| Site(
		Mount(
			|env, args, tx| {
				depth = layer(args.depth)
				plan = compile(template(RowRef.{ depth }), depth, args.path, "an each", args.enclosing)
				(site, tx1) = alloc_site(tx, args.path)
				tpl = template_bytes(plan)
				tx2 = emit_op(tx1, 7, |c| put_u32(put_u32(c, site), tpl.len().to_u32_wrap()).concat(tpl))
				(anchor, tx3) = if args.sole {
					(0, tx2)
				} else {
					check_construction_text(args.enclosing.construction, { value: "", site: args.path, placement: " (row anchor)" })
					(a, t) = alloc_id(tx2)
					before = args.before
					(a, emit_op(t, 10, |c| put_str(put_u32(put_u32(put_u32(c, a), args.parent), before), "")))
				}
				var $om = 0.U128
				var $sm = 0.U128
				for h in plan.holes {
					$om = $om.bitwise_or(h.mask)
					$sm = $sm.bitwise_or(h.smask)
				}
				outer_mask = $om.bitwise_and(above_bits(depth))
				smask_all = $sm
				dynamic = !plan.mounts.is_empty() or plan.holes.any(|hole| hole.kind == 5)
				cfg = { site, parent: args.parent, anchor, sole: args.sole, depth, path: args.path, key, plan, dynamic, outer_mask, sel_mask: smask_all }
				ncols = plan.ncols
				nholes = plan.holes.len()
				list = (rows.read)(env)
				(cols, tx4) = append_rows(cfg, cols_empty(ncols, nholes), |k, it| Row.{ outer: env, key: k, item: it }, list, 0, count_evals(tx3, 1))
				# Nested sites in the template report their static reads (kreads),
				# which also covers rows mounted later.
				reads = eff_mask(rows).bitwise_or(outer_mask).bitwise_or(smask_all).bitwise_or(plan.kreads.bitwise_and(above_bits(depth)))
				(each_inst(cfg, rows, [], cols), reads, tx4)
			},
		),
		|d| {
			d1 = layer(d)
			eff_mask(rows).bitwise_or(elem_reads(template(RowRef.{ depth: d1 }), d1).bitwise_and(above_bits(d1)))
		},
	)

	## Which rows of a table a view shows and in what order: `keep`
	## says whether a row is in the view, `sort` gives the value it is
	## ordered by, and `compare` orders two sort values. Engine.sort_by builds
	## this record using the sort value's and key's own orders. An explicit
	## comparator must be total: `compare` answers `Same` only for one row's own sort value,
	## so a sort value includes the key wherever the sorted field can tie.
	## Two rows that compare `Same` are a contract error.
	QueryPlan(k, v, s) : { keep : k, v -> Bool, sort : k, v -> s, compare : s, s -> [Before, Same, After] }

	## The part of a view that is drawn: `count` rows from position
	## `start` of the view's order.
	Window : { start : U64, count : U64 }

	## What a `table_view` site shows of its table. `query` is plain
	## data the site can compare (a filter and an order the user chose),
	## and `plan` turns it into the [QueryPlan] that selects and orders rows;
	## `window` is the part of that order to draw.
	TableViewProps(ctx, q, k, v, s) : { query : Signal(ctx, q), plan : (q -> QueryPlan(k, v, s)), window : Signal(ctx, Window) }

	## `table_view(table, props, template)` renders one row for each
	## row of `table` in the window of a filtered, sorted view of it
	## ([TableViewProps]). The site owns the view (the ordered keys of every row
	## that passes the filter) and keeps it up to date from the table's
	## changes: a turn that wrote rows costs those rows, a search
	## and a move in the ordered keys each, whatever the size of the table.
	## No list of rows is built, kept or compared. The window's changes are
	## applied as row operations: a row that left is removed, one that
	## entered is created, one that moved is moved with its nodes and any
	## state nested in it, and one whose row was written re-evaluates its
	## holes.
	##
	## `template` runs once per site and must return a single element. It
	## is given the row's key and a handle on the row's value, a [State] of
	## the row's scope: a read is the row of that key in the table, and a
	## write is `Table.update` of that key in that table, so a row's
	## handlers cannot name another table by mistake, and a component drawn
	## over a `State` draws a row as it draws anything else. A change of
	## `query` (to an unequal value) or a whole rewrite of the table
	## rebuilds the view, in the size of the table; a change of `window`
	## costs the two windows.
	##
	## The site finds a mounted row by the table's key itself, in an index
	## it keeps through the key's `is_eq` and `to_hash`, never by a text of
	## the key.
	table_view : Cell(st, Table(k, v)), TableViewProps(ctx, q, k, v, s), (Signal(Row(ctx, k), k), State(Row(ctx, k), v) -> Elem(Row(ctx, k))) -> Elem(ctx)
		where [ctx.store : () -> StoreReach(ctx, st), k.is_eq : k, k -> Bool, k.to_hash : k, Hasher -> Hasher, q.is_eq : q, q -> Bool]
	table_view = |source, props, template| Site(
		Mount(
			|env, args, tx| {
				get = view_source(source)
				depth = layer(args.depth)
				plan = compile(template(view_key({}), view_row(source, depth, args.path)), depth, args.path, "a table view", args.enclosing)
				(site, tx1) = alloc_site(tx, args.path)
				tpl = template_bytes(plan)
				tx2 = emit_op(tx1, 7, |c| put_u32(put_u32(c, site), tpl.len().to_u32_wrap()).concat(tpl))
				(anchor, tx3) = if args.sole {
					(0, tx2)
				} else {
					check_construction_text(args.enclosing.construction, { value: "", site: args.path, placement: " (row anchor)" })
					(a, t) = alloc_id(tx2)
					before = args.before
					(a, emit_op(t, 10, |c| put_str(put_u32(put_u32(put_u32(c, a), args.parent), before), "")))
				}
				var $om = 0.U128
				for h in plan.holes {
					$om = $om.bitwise_or(h.mask)
				}
				outer_mask = $om.bitwise_and(above_bits(depth))
				dynamic = !plan.mounts.is_empty() or plan.holes.any(|hole| hole.kind == 5)
				cfg = { site, parent: args.parent, anchor, sole: args.sole, depth, path: args.path, key: {}, plan, dynamic, outer_mask, sel_mask: 0 }
				q = (props.query.read)(env)
				window = (props.window.read)(env)
				rows = get(env)
				view = View.build(rows, { query: (props.plan)(q), window, limit: view_chunk, site: show_path(args.path) })
				# The query, the window, and one placement for every row of the table.
				(cols, slots, tx4) = view_enter(cfg, cols_empty(plan.ncols, plan.holes.len()), |_, key| Row.{ outer: env, key: "", item: key }, view.shown_keys(), count_evals(tx3, 2 + rows.len()))
				reads = cell_bit(source.cell).bitwise_or(eff_mask(props.query)).bitwise_or(eff_mask(props.window)).bitwise_or(outer_mask).bitwise_or(plan.kreads.bitwise_and(above_bits(depth)))
				shows = { get, query: props.query, plan: props.plan, window: props.window }
				(view_inst(cfg, shows, q, view, [], cols, slots), reads, tx4)
			},
		),
		|d| {
			d1 = layer(d)
			cell_bit(source.cell).bitwise_or(eff_mask(props.query)).bitwise_or(eff_mask(props.window)).bitwise_or(elem_reads(template(view_key({}), view_row(source, d1, [])), d1).bitwise_and(above_bits(d1)))
		},
	)

	## `when(cond, yes, no)` builds only the branch `cond` selects, and rebuilds it
	## when `cond` changes, disposing the old branch with everything it owns.
	## Because the unselected branch is never built, recursive UI can be expressed
	## directly.
	when : Signal(ctx, Bool), (() -> Elem(ctx)), (() -> Elem(ctx)) -> Elem(ctx)
	when = |cond, yes, no| Site(
		Mount(
			|env, args, tx| {
				check_construction_text(args.enclosing.construction, { value: "", site: args.path, placement: " (branch anchor)" })
				(anchor, tx1) = alloc_id(tx)
				before = args.before
				tx2 = emit_op(tx1, 10, |c| put_str(put_u32(put_u32(put_u32(c, anchor), args.parent), before), ""))
				c = (cond.read)(env)
				elem = if (c) yes() else no()
				(block, tx3) = mount_block(env, elem, args.depth, args.path, 0, anchor, { cap: args.cap, enclosing: args.enclosing }, bump(count_evals(tx2, 1), w_scopes_created, 1))
				# Listen to the condition, this branch, and what the other branch
				# would read once mounted (or the cap, when the parent knows it).
				reads = if args.cap != 0 {
					args.cap
				} else {
					other = if (c) no() else yes()
					eff_mask(cond).bitwise_or(block.reads).bitwise_or(elem_reads(other, args.depth))
				}
				w = { cond, yes, no, anchor, depth: args.depth, path: args.path, cap: args.cap, enclosing: args.enclosing }
				(when_inst(w, c, [], block), reads, tx3)
			},
		),
		|d| eff_mask(cond).bitwise_or(elem_reads(yes(), d)).bitwise_or(elem_reads(no(), d)),
	)

	## `switch(sel, cases, body)` builds `body(k)` for the current value `k` of
	## `sel`, and rebuilds it when `sel` changes to a different case. `cases` lists
	## every value `sel` can take, so the site listens to everything any branch
	## could read; a value outside `cases` is a contract error.
	switch : Signal(ctx, k), List(k), (k -> Elem(ctx)) -> Elem(ctx)
		where [k.is_eq : k, k -> Bool]
	switch = |sel, cases, body| Site(
		Mount(
			|env, args, tx| {
				check_construction_text(args.enclosing.construction, { value: "", site: args.path, placement: " (branch anchor)" })
				(anchor, tx1) = alloc_id(tx)
				before = args.before
				tx2 = emit_op(tx1, 10, |c| put_str(put_u32(put_u32(put_u32(c, anchor), args.parent), before), ""))
				k = switch_value(sel, cases, env, args.path)
				(block, tx3) = mount_block(env, body(k), args.depth, args.path, 0, anchor, { cap: args.cap, enclosing: args.enclosing }, bump(count_evals(tx2, 1), w_scopes_created, 1))
				reads = if (args.cap != 0) args.cap else switch_reads(sel, cases, body, args.depth)
				w = { sel, cases, body, anchor, depth: args.depth, path: args.path, cap: args.cap, enclosing: args.enclosing }
				(switch_inst(w, k, [], block), reads, tx3)
			},
		),
		|d| switch_reads(sel, cases, body, d),
	)

	## `remount_on(key, body)` builds `body()` and, whenever `key`
	## changes to a value unequal to the one the body was built for,
	## disposes it and builds it again from scratch, as `switch` does when
	## its case changes: its nodes are removed, state inside starts again at
	## its initial value, timers and subscriptions inside are cancelled, and
	## requests in flight inside are kept and delivered to this site, where
	## a write to the disposed state is skipped. This is how state that
	## belongs to one key (a draft for one message) starts again when
	## the key changes. The body takes no argument, so what it reads does
	## not depend on the key, and the site's static reads are the key's and
	## the body's. An equal key costs one evaluation of the key and a
	## refresh of what else changed; an unequal one costs disposing and
	## mounting the body. The site keeps the key the body was built for, to
	## compare, so a key should be small, such as an id.
	remount_on : Signal(ctx, k), (() -> Elem(ctx)) -> Elem(ctx)
		where [k.is_eq : k, k -> Bool]
	remount_on = |key, body| Site(
		Mount(
			|env, args, tx| {
				check_construction_text(args.enclosing.construction, { value: "", site: args.path, placement: " (branch anchor)" })
				(anchor, tx1) = alloc_id(tx)
				before = args.before
				tx2 = emit_op(tx1, 10, |c| put_str(put_u32(put_u32(put_u32(c, anchor), args.parent), before), ""))
				k = (key.read)(env)
				(block, tx3) = mount_block(env, body(), args.depth, args.path, 0, anchor, { cap: args.cap, enclosing: args.enclosing }, bump(count_evals(tx2, 1), w_scopes_created, 1))
				reads = if (args.cap != 0) args.cap else eff_mask(key).bitwise_or(block.reads)
				w = { key, body, anchor, depth: args.depth, path: args.path, cap: args.cap, enclosing: args.enclosing }
				(remount_inst(w, k, [], block), reads, tx3)
			},
		),
		|d| eff_mask(key).bitwise_or(elem_reads(body(), d)),
	)

	## `derive(input, body)` evaluates `input` once per change of the layers it
	## reads and gives `body` the result as a new layer. Readers inside `body` that
	## read only the derived value do no work while it is equal to the previous
	## result, so use `derive` for a value that is expensive or read in many
	## places. Values from the enclosing context enter `body` with `lift`.
	derive : Signal(ctx, a), (Signal(In(ctx, a), a) -> Elem(In(ctx, a))) -> Elem(ctx)
		where [a.is_eq : a, a -> Bool]
	derive = |input, body| Site(
		Mount(
			|env, args, tx| {
				depth = layer(args.depth)
				v = (input.read)(env)
				elem = body({ mask: bit(depth), read: |e| e.value, sel: NoSel })
				(block, tx1) = mount_block(In.{ outer: env, value: v }, elem, depth, args.path, args.parent, args.before, { cap: args.cap, enclosing: args.enclosing }, count_evals(tx, 1))
				# Everything the body reads except this layer, which only this
				# site changes (refreshing its block itself): a state below it
				# reports its bit upward, and the Changed pass must find it here.
				reads = block.reads.bitwise_and(own_bit(depth).bitwise_not()).bitwise_or(eff_mask(input))
				(derive_inst(input, v, block, depth), reads, tx1)
			},
		),
		|d| {
			d1 = layer(d)
			eff_mask(input).bitwise_or(elem_reads(body({ mask: bit(d1), read: |e| e.value, sel: NoSel }), d1).bitwise_and(own_bit(d1).bitwise_not()))
		},
	)

	## A request from an effect site.
	##
	## Commands are emitted and forgotten: `Push` and `Replace` (history), `Title`,
	## `StorageSet` and `StorageRemove` (local-storage), and `Focus`, `Blur` and
	## `SelectText` on a reference named with `ref` (resolved at the end of the
	## turn; a reference that is not mounted then is counted stale). With
	## `PortCommand` and `Save` they are the tags of [Command].
	##
	## Awaited requests deliver results to the site's [Reaction]: `Http`,
	## `StorageGet` and `Timer` deliver one; `Interval`, `Popstate`,
	## `OnlineChanges` and `VisibilityChanges` are subscriptions that deliver any
	## number until their site is disposed. `Self` asks for a follow-up turn whose
	## result is `Now`, so a site can write state in response to its value changing.
	## `Http`'s `timeout_ms` of 0 means no timeout; it is capped at 10 minutes.
	##
	## `Work` runs a job of the task registered under `task` (see
	## `with_workers`) on `input` in a worker, which may read the `files` the
	## input refers to through effects and answer with files of its own; it
	## delivers one `Work` answer or `WorkLost(fault)`. `timeout_ms` 0 means
	## no timeout; it is capped at 10 minutes and delivers `Timeout` when it
	## expires. `on_dispose` says whether disposing its site stops the job
	## (`Stop`, like a timer) or keeps it and delivers its answer to the
	## nearest surviving ancestor (`Keep`, like `Http`); `on_cancel` whether a
	## running job that is cancelled ends its worker (`Stop`) or completes
	## with its answer dropped (`Finish`). A task of a preparation is
	## `Prepared`: `input` then starts with the preparation's input
	## (`input_len` bytes, referring to the first `input_files` files), which
	## a worker that already prepared it may skip. Issuing work for a task
	## that is not registered is a contract error. `Worker` builds it.
	##
	## `ReadBytes` and `ReadUtf8` read a file into the page (`File.read_bytes`,
	## `File.read_utf8`) and deliver one `FileBytes`, `FileText` or
	## `FileFailed`. `Sha256` digests a file and `ObjectUrl` makes a URL that
	## shows it (`File.sha256`, `File.object_url`), delivering `Digest`,
	## `FileUrl` or `FileFailed`. Like a timer these belong to their site.
	## `Upload` is an HTTP request whose body is a file (`File.upload`): it is
	## answered and kept as `Http` is.
	Request : [
		## `timeout_ms` 0 = no timeout; capped at `max_timeout_ms`.
		Http({ method : Web.Method, url : Str, headers : List((Str, Str)), body : Str, timeout_ms : U32, cache : Cache, credentials : Credentials }),
		StorageGet(Str),
		SessionStorageGet(Str),
		StorageChanges(Str),
		StorageWriteFailures,
		ClipboardWrite({ text : Str, html : [Plain, Html(Str)] }),
		Timer(U32),
		Work({ task : Str, input : List(U8), files : List(File), timeout_ms : U32, on_dispose : [Stop, Keep], on_cancel : [Stop, Finish], prepared : [Unprepared, Prepared({ name : Str, input_len : U64, input_files : U64 })] }),
		Interval(U32),
		Popstate,

		## Subscriptions to the browser's connectivity (`online`/`offline`)
		## and page visibility (`visibilitychange`). Each change delivers
		## `Online(Bool)` or `Visible(Bool)`; the value at mount is in `Boot`.
		OnlineChanges,
		VisibilityChanges,

		## Observe one declared media query; its first value is already in Boot.
		MediaChanges(Str),
		Self,
		Push(Str),
		Replace(Str),
		Title(Str),

		## Animate this call's batch with unique types in first-issue order. Mount
		## and its follow-ups are ignored; an unavailable browser API applies it
		## immediately. This command has no result or in-flight slot.
		ViewTransition(List(Str)),
		Focus(Str),
		Blur(Str),
		SelectText(Str),
		ApplyValue(Str),
		FocusInPlace(Str),
		ScrollIntoView(Str, { block : Align, inline : Align, behavior : ScrollBehavior }),
		ScrollTo(Str, { top : Edge, left : Edge, behavior : ScrollBehavior }),
		StorageSet(Str, Str),
		StorageRemove(Str),
		SessionStorageSet(Str, Str),
		SessionStorageRemove(Str),
		ReadBytes({ file : File, max_bytes : U64 }),
		ReadUtf8({ file : File, max_bytes : U64 }),
		Upload({ method : Web.Method, url : Str, headers : List((Str, Str)), body : File, timeout_ms : U32, credentials : Credentials }),
		Sha256(File),
		ObjectUrl(File),

		## Ports (see [PortDecl]): a message to the page's JavaScript for the
		## port named `port`. `PortCommand` is emitted and forgotten;
		## `PortCall` awaits one `PortAnswer` or `PortFailed` and, like `Http`,
		## survives its site's disposal (`timeout_ms` 0 = none, capped at 10
		## minutes); `PortSubscribe` delivers any number of messages until its
		## site is disposed or the JavaScript ends it.
		PortCommand({ port : Str, message : PortMessage }),
		PortCall({ port : Str, message : PortMessage, timeout_ms : U32 }),
		PortSubscribe({ port : Str, message : PortMessage }),

		## A command that saves `file` (its range) as a download named `name`
		## (`File.save`).
		Save({ file : File, name : Str }),

		## An HTTP request whose response body becomes a file
		## (`File.fetch`), delivering `Fetched`. `timeout_ms` 0 = none, capped
		## at 10 minutes; kept like `Http`.
		Fetch({ method : Web.Method, url : Str, headers : List((Str, Str)), timeout_ms : U32, cache : Cache, credentials : Credentials }),
	]

	## A request that is emitted and forgotten: the commands of [Request],
	## and nothing that awaits a result. It is what a cleanup's plan returns
	## (`on_cleanup`): a request that awaits a result would outlive the scope
	## that asked for it, and this type has no such tag, so a cleanup that
	## asks for one does not compile. Each tag carries what the tag of the
	## same name in [Request] carries.
	Command : [
		Push(Str),
		Replace(Str),
		Title(Str),

		## Animate this call's batch with unique types in first-issue order. Mount
		## and its follow-ups are ignored; an unavailable browser API applies it
		## immediately. This command has no result or in-flight slot.
		ViewTransition(List(Str)),
		Focus(Str),
		Blur(Str),
		SelectText(Str),
		ApplyValue(Str),
		FocusInPlace(Str),
		ScrollIntoView(Str, { block : Align, inline : Align, behavior : ScrollBehavior }),
		ScrollTo(Str, { top : Edge, left : Edge, behavior : ScrollBehavior }),
		StorageSet(Str, Str),
		StorageRemove(Str),
		SessionStorageSet(Str, Str),
		SessionStorageRemove(Str),
		PortCommand({ port : Str, message : PortMessage }),
		Save({ file : File, name : Str }),
	]

	## A request paired with its own result reader. Construct one with the
	## typed request functions, or use raw when the whole Result is intended.
	Ask(output, error) :: { request : Request, read : (Result -> Try(output, error)) }.{

		## Transform a successful answer without changing the request or its errors.
		map_ok : Ask(a, e), (a -> b) -> Ask(b, e)
		map_ok = |{ request, read }, f| { request, read: |result| read(result).map_ok(f) }

		## Transform an error without changing the request or its answer type.
		map_err : Ask(o, a), (a -> b) -> Ask(o, b)
		map_err = |{ request, read }, f| { request, read: |result| read(result).map_err(f) }

		## Classify the whole typed result, for example an HTTP status as an error.
		map : Ask(a, e), (Try(a, e) -> Try(b, f)) -> Ask(b, f)
		map = |{ request, read }, f| { request, read: |result| f(read(result)) }

		## The request as data, for pure tests of a plan's URL, payload and policies.
		sent : Ask(o, e) -> Request
		sent = |{ request, read: _ }| request
	}

	## Internal construction for the platform's typed request modules. The
	## public Ask exposes only transformations and inspection of what it sends.
	make_ask : Request, (Result -> Try(output, error)) -> Ask(output, error)
	make_ask = |request, read| { request, read }

	## Deliberately keep every raw result arm for a protocol-level reaction.
	raw : Request -> Ask(Result, [])
	raw = |request| { request, read: |result| Ok(result) }

	## Pair an asker's request with its declared reader once, when it is asked.
	ask_of : asker, input -> Ask(output, error)
		where [asker.request : asker, input -> Request, asker.result : asker, Result -> Try(output, error)]
	ask_of = |asker, input| { request: asker.request(input), read: |result| asker.result(result) }

	## A command has no answer, so it fits any result type a plan shares.
	command : Command -> Ask(output, error)
	command = |value| { request: command_request(value), read: |_| crash "contract: a command received a result" }

	## The result of an awaited request: an HTTP response (`Http`, with any status),
	## a network failure (`Network`) or `Timeout`, a storage `Value` or `Missing`, a
	## timer or interval tick (`Fired`), the URL after `Popstate` (`Location`), a
	## connectivity or visibility change (`Online`, `Visible`), a `Self` follow-up
	## (`Now`), `Refused` when the in-flight bound turned the request away, or a
	## task job's answer with the files it holds (`Work`) or the reason it
	## produced none (`WorkLost`), a file's bytes or text read into the page
	## (`FileBytes`, `FileText`), a file's digest (`Digest`) or a URL that
	## shows it (`FileUrl`), or why an operation on a file produced nothing
	## (`FileFailed`), or a port's answer or message (`PortAnswer`) or why
	## there is none (`PortFailed`), or a response whose body is a file
	## (`Fetched`).
	Result : [Http({ status : U16, headers : List((Str, Str)), body : Str }), Network(Str), Timeout, Value(Str), Missing, Fired(I64), Location(Str), Online(Bool), Visible(Bool), Matches(Bool), Now, Refused, Work({ output : List(U8), files : List(File) }), WorkLost(WorkFault), FileFailed(FileError), FileBytes(List(U8)), FileText(Str), Digest(List(U8)), FileUrl(Str), PortAnswer(PortMessage), PortFailed(PortFailure), Fetched({ status : U16, headers : List((Str, Str)), body : File }), Copied, ClipboardFailed([NotAllowed, Unavailable]), StorageFailed({ store : [Local, Session], key : Str, reason : [Quota, Unavailable] })]

	## A port message as it crosses: JSON text, the byte blocks its
	## `{"$bytes":N}` markers name, and the files its `{"$file":N}` markers
	## name, each by its place in the list (design.md, Appendix B). The typed
	## layer, `Port`, writes and reads it with `PortJson`.
	PortMessage : { json : Str, blobs : List(List(U8)), files : List(File) }

	## Why a port request has no answer: the page's JavaScript threw or
	## rejected, or answered with something that is not JSON data (`Threw`,
	## with the message), its answer was more than the runtime takes
	## (`TooLarge`), or it ended a subscription (`Closed`). `Threw` and `Closed` end a
	## subscription; `TooLarge` reports one message and the subscription goes
	## on.
	PortFailure : [Threw(Str), TooLarge, Closed]

	## How a subscription's messages wait for their turns while the app is
	## busy: `Latest` keeps only the newest undelivered message, for a value
	## whose newest state is all that matters; `Every(n)` keeps up to `n`
	## (1 to 1024) in order, and the JavaScript's `emit` is refused beyond them.
	PortDelivery : [Latest, Every(U32)]

	## A port the program declares (`Program.with_ports`): its name and its
	## shape. The runtime checks the page's handlers against these before it
	## mounts, and the engine checks every request against them.
	PortDecl :: { name : Str, kind : U8, delivery : U8, bound : U32 }

	## The declaration of the port `name` as a command, a call or a
	## subscription with its delivery policy.
	port_declaration : Str, [Command, Call, Subscription(PortDelivery)] -> PortDecl
	port_declaration = |name, shape| match shape {
		Command => { name, kind: 1, delivery: 0, bound: 0 }
		Call => { name, kind: 2, delivery: 0, bound: 0 }
		Subscription(Every(n)) => { name, kind: 3, delivery: 1, bound: n }
		Subscription(Latest) => { name, kind: 3, delivery: 2, bound: 1 }
	}

	## For test platforms and harnesses: the rules `with_ports` enforces, as
	## a value: the declarations, or the contract diagnostic for more than 64
	## ports, a name declared twice, a name that is empty or longer than 128
	## bytes, or an `Every` bound outside 1 to 1024.
	port_catalogue : List(PortDecl) -> Try(List(PortDecl), Str)
	port_catalogue = |decls| {
		var $seen = []
		for d in decls {
			name = d.name
			if $seen.len() >= max_ports {
				return Err("contract: a program declares more than ${max_ports.to_str()} ports (port \"${name}\" is over the bound)")
			}
			if name.is_empty() or name.count_utf8_bytes() > max_port_name {
				return Err("contract: a program declares a port named \"${name}\"; a port name is 1 to ${max_port_name.to_str()} bytes")
			}
			if $seen.contains(name) {
				return Err("contract: port \"${name}\" is declared twice")
			}
			if d.delivery == 1 and (d.bound < 1 or d.bound > max_port_every) {
				return Err("contract: port \"${name}\" delivers Every(${d.bound.to_str()}); a subscription keeps 1 to ${max_port_every.to_str()} undelivered messages")
			}
			$seen = $seen.append(name)
		}
		Ok(decls)
	}

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
	file_bytes : Result -> Try(List(U8), FileError)
	file_bytes = |res| match res {
		FileBytes(bytes) => Ok(bytes)
		FileFailed(e) => Err(e)
		Refused => Err(Refused)
		_ => crash "contract: file_bytes was given a result that is not from File.read_bytes"
	}

	## A `read_utf8` result as the file's text or a typed [FileError]. Any
	## other result is a contract error.
	file_text : Result -> Try(Str, FileError)
	file_text = |res| match res {
		FileText(text) => Ok(text)
		FileFailed(e) => Err(e)
		Refused => Err(Refused)
		_ => crash "contract: file_text was given a result that is not from File.read_utf8"
	}

	## A `sha256` result as the digest's 32 bytes or a typed [FileError]. Any
	## other result is a contract error.
	file_digest : Result -> Try(List(U8), FileError)
	file_digest = |res| match res {
		Digest(bytes) => Ok(bytes)
		FileFailed(e) => Err(e)
		Refused => Err(Refused)
		_ => crash "contract: file_digest was given a result that is not from File.sha256"
	}

	## An `object_url` result as the URL or a typed [FileError]. Any other
	## result is a contract error.
	file_url : Result -> Try(Str, FileError)
	file_url = |res| match res {
		FileUrl(url) => Ok(url)
		FileFailed(e) => Err(e)
		Refused => Err(Refused)
		_ => crash "contract: file_url was given a result that is not from File.object_url"
	}

	## Why a `Work` request produced no output: the worker's instance faulted
	## running the job (`Contract`, `ResourceLimit`, `OutOfMemory`,
	## `AppCrash` and `ExpectFailed`, the fault classes of an instance), the
	## browser has no workers (`Unavailable`), or the worker itself failed
	## (`Executor`). The diagnostic goes to the page's console, never into the
	## result.
	WorkFault : [Contract, ResourceLimit, OutOfMemory, AppCrash, ExpectFailed, Unavailable, Executor]

	## An HTTP answer at any status; classification of statuses belongs to the app.
	Response : { status : U16, headers : List((Str, Str)), body : Str }

	## Why an HTTP request produced no response.
	HttpFailure : [Network(Str), Timeout, Refused]

	## A fetched response retains its status and headers beside the file handle.
	Fetched : { status : U16, headers : List((Str, Str)), body : File }

	## Why a fetch produced no response file.
	FetchFailure : [Network(Str), Timeout, TooLarge, Refused]

	## Ask for the body of a successful HTTP response; non-2xx statuses are errors.
	http_body : HttpProps -> Ask(Str, HttpError)
	http_body = |props| Core.http(props).map(
		|result| match result {
			Ok(response) => if (response.status >= 200 and response.status < 300) Ok(response.body) else Err(Status(response.status))
			Err(error) => Err(error)
		},
	)

	## Sample the wall clock once after the given delay; zero is legal.
	timer : U32 -> Ask(I64, [Refused])
	timer = |ms| Core.make_ask(Timer(ms), read_fired)

	## Sample the wall clock at every tick until the site's interval is cancelled.
	interval : U32 -> Ask(I64, [Refused])
	interval = |ms| Core.make_ask(Interval(ms), read_fired)

	## Queue one follow-up in the same turn; it has no failure result.
	again : {} -> Ask({}, error)
	again = |_| Core.make_ask(
		Self,
		|result| match result {
			Now => Ok({})
			_ => crash "contract: again received a result other than Now"
		},
	)

	## Follow matching changes for the declared media query.
	media_changes : Str -> Ask(Bool, [Refused])
	media_changes = |query| Core.make_ask(
		MediaChanges(query),
		|result| match result {
			Matches(value) => Ok(value)
			Refused => Err(Refused)
			_ => crash "contract: media_changes received a non-media result"
		},
	)

	## Follow the current location after browser history traversal.
	popstate : {} -> Ask(Str, [Refused])
	popstate = |_| Core.make_ask(
		Popstate,
		|result| match result {
			Location(value) => Ok(value)
			Refused => Err(Refused)
			_ => crash "contract: popstate received a non-location result"
		},
	)

	## Read one local-storage key, distinguishing absence from an empty value.
	storage_get : Str -> Ask(Str, [Missing, Refused])
	storage_get = |key| Core.make_ask(StorageGet(key), read_storage)

	## Read one session-storage key with the same absence semantics.
	session_get : Str -> Ask(Str, [Missing, Refused])
	session_get = |key| Core.make_ask(SessionStorageGet(key), read_storage)

	## Follow another document's writes to the key, including removal.
	storage_changes : Str -> Ask([Set(Str), Removed], [Refused])
	storage_changes = |key| Core.make_ask(
		StorageChanges(key),
		|result| match result {
			Value(value) => Ok(Set(value))
			Missing => Ok(Removed)
			Refused => Err(Refused)
			_ => crash "contract: storage_changes received a non-storage result"
		},
	)

	## Follow failed local/session writes reported by the browser service.
	storage_write_failures : {} -> Ask({ store : [Local, Session], key : Str, reason : [Quota, Unavailable] }, [Refused])
	storage_write_failures = |_| Core.make_ask(
		StorageWriteFailures,
		|result| match result {
			StorageFailed(value) => Ok(value)
			Refused => Err(Refused)
			_ => crash "contract: storage_write_failures received another result"
		},
	)

	## Follow browser connectivity changes.
	online_changes : {} -> Ask(Bool, [Refused])
	online_changes = |_| Core.make_ask(
		OnlineChanges,
		|result| match result {
			Online(value) => Ok(value)
			Refused => Err(Refused)
			_ => crash "contract: online_changes received another result"
		},
	)

	## Follow document visibility changes.
	visibility_changes : {} -> Ask(Bool, [Refused])
	visibility_changes = |_| Core.make_ask(
		VisibilityChanges,
		|result| match result {
			Visible(value) => Ok(value)
			Refused => Err(Refused)
			_ => crash "contract: visibility_changes received another result"
		},
	)

	## Why an HTTP request did not produce a successful response, as `http_text`
	## reports it: the browser could not reach the server (`Network`, with the
	## browser's message), the request's `timeout_ms` expired (`Timeout`), the
	## server answered outside 2xx (`Status`), or the in-flight bound refused the
	## request (`Refused`).
	HttpError : [Network(Str), Timeout, Status(U16), Refused]

	## An HTTP result as the body of a 2xx response or a typed [HttpError]. Apps
	## that classify statuses themselves match on `Http` directly. Any result that
	## is not from an HTTP request is a contract error.
	http_text : Result -> Try(Str, HttpError)
	http_text = |res| match res {
		Http({ status, body, .. }) => if (status >= 200 and status < 300) Ok(body) else Err(Status(status))
		Network(message) => Err(Network(message))
		Timeout => Err(Timeout)
		Refused => Err(Refused)
		_ => crash "contract: http_text was given a result that is not an HTTP result"
	}

	## Why a `File.fetch` produced no file, as `fetched` reports it: the
	## browser could not reach the server (`Network`), the request's timeout
	## expired (`Timeout`), the server answered outside 2xx (`Status`), the
	## body is more than the `maxFileBytes` mount option allows (`TooLarge`),
	## or the in-flight bound refused the request (`Refused`).
	FetchError : [Network(Str), Timeout, Status(U16), TooLarge, Refused]

	## A `File.fetch` result as the body of a 2xx response, or a typed
	## [FetchError]. Apps that read the status or headers themselves match on
	## `Fetched` directly. Any other result is a contract error.
	fetched : Result -> Try(File, FetchError)
	fetched = |res| match res {
		Fetched({ status, body, .. }) => if (status >= 200 and status < 300) Ok(body) else Err(Status(status))
		Network(message) => Err(Network(message))
		Timeout => Err(Timeout)
		FileFailed(_) => Err(TooLarge)
		Refused => Err(Refused)
		_ => crash "contract: fetched was given a result that is not from File.fetch"
	}

	## A sampled transfer count. Unknown never substitutes a guessed total.
	Transfer : { direction : [Sending, Receiving], done : U64, total : [Known(U64), Unknown] }

	## A progress decision, separate from a request’s final result reaction.
	ProgressReaction(ctx, a) :: { run : (ctx, a, Transfer, List(U32) -> (ctx, Layers)) }

	## Sampling interval requested by an application; intervals below 16 ms use 16 ms.
	ProgressProps := { every_ms : U32 ?? 100 }

	## Apply a pure decision’s writes for a sampled transfer count and the original item.
	store_progress : (a, Transfer -> List(Write(st))) -> ProgressReaction(ctx, a)
		where [ctx.store : () -> StoreReach(ctx, st)]
	store_progress = |decide| {
		Ctx : ctx
		store_over = Ctx.store().over
		{ run: |env, a, transfer, site| store_writes(store_over, env, decide(a, transfer), Reaction(site)) }
	}

	## What an effect site does with a result: what it writes, given the value
	## the request was issued for and its typed result. Make one with `State.on_result`
	## or `store_reaction`, or use `ignore`. Like a handler's, its `run` is
	## also given the path of the site whose reaction it is, and returns the
	## set it wrote.
	Reaction(ctx, a, result) :: { run : (ctx, a, result, List(U32) -> (ctx, Layers)), progress : ProgressHandler(ctx, a) }.{

		## Ask every HTTP transfer issued by this site to sample progress, using
		## the original issued-for item and ordinary turn settlement.
		with_progress : Reaction(ctx, a, result), ProgressProps, ProgressReaction(ctx, a) -> Reaction(ctx, a, result)
		with_progress = |reaction, props, progress| { ..reaction, progress: Reporting({ every_ms: if (props.every_ms < 16) 16 else props.every_ms, run: progress.run }) }

		## One reaction that runs `first` and then `second` on the same
		## result, as one atomic write: `second` receives the environment
		## `first` returned, so it sees `first`'s writes, and the result's
		## turn reports the union of both write sets, which settle outermost
		## first. Costs one closure call more per result.
		also : Reaction(ctx, a, result), Reaction(ctx, a, result) -> Reaction(ctx, a, result)
		also = |first, second| {
			run_first = first.run
			run_second = second.run
			{
				run: |e, a, r, site| {
					(e1, w1) = run_first(e, a, r, site)
					(e2, w2) = run_second(e1, a, r, site)
					(e2, layers_or(w1, w2))
				},
				progress: combine_progress(first.progress, second.progress),
			}
		}
	}

	## A reaction that discards every result, for sites that only issue commands.
	ignore : {} -> Reaction(ctx, a, result)
	ignore = |_| { run: |e, _, _, _| (e, no_layers), progress: NoProgress }

	## `on_cleanup(name, v, plan)` runs `plan` on `v`, read in the scope's last
	## environment, when the scope this site is mounted in is disposed, and issues
	## the commands in the disposing turn. A plan returns [Command]s (history,
	## title, storage writes, focus, port commands, saves): a request that awaits
	## a result would outlive its owner, and the type has none, so the compiler
	## rejects it. Each run is counted by `name`. The site renders nothing and
	## reads nothing while it is live.
	on_cleanup : Str, Signal(ctx, a), (a -> List(Command)) -> Elem(ctx)
	on_cleanup = |name, v, plan| Site(
		Mount(|_env, _args, tx| (cleanup_inst(name, v, plan), 0, tx)),
		|_| 0,
	)

	## Keep the native leave warning while this site is mounted and its signal
	## is true. The turn settles all guards once; this site takes no awaited id.
	guard_leave : Signal(ctx, Bool) -> Elem(ctx)
	guard_leave = |value| Site(
		Mount(
			|env, _args, tx| {
				on = (value.read)(env)
				next = if (on) with_fx(tx, |fx| { ..fx, guard: { ..fx.guard, live: fx.guard.live + 1 } }) else tx
				(guard_inst(value, on), eff_mask(value), count_evals(next, 1))
			},
		),
		|_| eff_mask(value),
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
	watch : Signal(ctx, a), (a -> List(Ask(output, error))), Reaction(ctx, a, Try(output, error)) -> Elem(ctx)
		where [a.is_eq : a, a -> Bool]
	watch = |v, plan, react| effect(v, True, plan, replanned(plan), react, Every)

	## Keep every request, but deliver only the latest issuing step's results.
	## A reparented request must also still match the question in the surviving
	## ancestor. Older results and progress count as delivered without running
	## their readers or reactions. Subscriptions must use watch_latest instead.
	keep_current : Signal(ctx, a), (a -> List(Ask(output, error))), Reaction(ctx, a, Try(output, error)) -> Elem(ctx)
		where [a.is_eq : a, a -> Bool]
	keep_current = |v, plan, react| effect(v, True, plan, replanned(plan), react, Current)

	## Like `watch`, but issues only when `v` changes after mount, never for its
	## initial value.
	watch_changes : Signal(ctx, a), (a -> List(Ask(output, error))), Reaction(ctx, a, Try(output, error)) -> Elem(ctx)
		where [a.is_eq : a, a -> Bool]
	watch_changes = |v, plan, react| effect(v, False, plan, replanned(plan), react, Every)

	## `watch_latest(v, plan, react)` issues like `watch`, under one more rule: the site
	## owns only the requests of its current value. Before it issues for a new
	## value it cancels every awaited request it still holds from earlier values
	## (`CANCEL`, counted `cancelled`), whatever its kind, and drops their queued
	## follow-ups and refusals (counted `stale`), so a late answer for an earlier
	## value never reaches `react`. A `plan` that returns `[]` makes a change a
	## pure cancel. Disposal follows `watch`'s rules.
	watch_latest : Signal(ctx, a), (a -> List(Ask(output, error))), Reaction(ctx, a, Try(output, error)) -> Elem(ctx)
		where [a.is_eq : a, a -> Bool]
	watch_latest = |v, plan, react| Site(
		Mount(
			|env, args, tx| {
				a = (v.read)(env)
				cfg = { v, plan: |_, value| hold_asks(value, plan(value)), step: |_, old, value, path| hold_asks(value, replanned(plan)(old, value, path)), react: held_reaction(react), path: args.path, only: Every }
				(t1, owned) = issue_progress(count_evals(tx, 1), args.path, (cfg.plan)(env, a), [], progress_interval(cfg.react))
				(latest_inst(cfg, a, owned), eff_mask(v), t1)
			},
		),
		|_| eff_mask(v),
	)

	## `resource(input, cfg, body)` is an asynchronous `derive`: a layer whose
	## value follows the answers to the requests issued for `input`. At mount the
	## layer starts at `cfg.pending(cfg.init, a)` and `cfg.plan(a)` is issued; when
	## `input` changes to an unequal value the site supersedes its requests as
	## `watch_latest` does, sets the layer to `cfg.pending(s, a)` in the same pass (before
	## anything below reads it) and issues again. Each result for a request the
	## site owns sets the layer to `cfg.resolve(s, a, res)`, where `a` is the value
	## the request was issued for. Readers inside `body` do no work while the
	## layer is equal to its previous value. Disposal follows `watch`'s rules; a
	## reparented answer's write to the retired layer is skipped and counted.
	resource : Signal(ctx, a), { init : s, pending : (s, a -> s), plan : (a -> List(Ask(output, error))), resolve : (s, a, Try(output, error) -> s) }, (Signal(In(ctx, s), s) -> Elem(In(ctx, s))) -> Elem(ctx)
		where [a.is_eq : a, a -> Bool, s.is_eq : s, s -> Bool]
	resource = |input, cfg, body| {
		resolve = cfg.resolve
		Core.resource_at(input, { init: cfg.init, pending: cfg.pending, plan: cfg.plan, resolve: |s, a, _at, res| resolve(s, a, res) }, body)
	}

	## `resource` whose `resolve` is also told the position, in the list
	## `plan(a)` returned, of the request a result answers: how a `gather`
	## layer knows which job answered.
	resource_at : Signal(ctx, a), { init : s, pending : (s, a -> s), plan : (a -> List(Ask(output, error))), resolve : (s, a, U64, Try(output, error) -> s) }, (Signal(In(ctx, s), s) -> Elem(In(ctx, s))) -> Elem(ctx)
		where [a.is_eq : a, a -> Bool, s.is_eq : s, s -> Bool]
	resource_at = |input, cfg, body| {
		plan = cfg.plan
		resolve = cfg.resolve
		planned = |value| hold_asks(value, plan(value))
		Site(
			Mount(
				|env, args, tx| {
					depth = layer(args.depth)
					a = (input.read)(env)
					s = (cfg.pending)(cfg.init, a)
					(t1, owned) = issue(count_evals(tx, 1), args.path, planned(a), [])
					elem = body({ mask: bit(depth), read: |e| e.value, sel: NoSel })
					(block, t2) = mount_block(In.{ outer: env, value: s }, elem, depth, args.path, args.parent, args.before, { cap: args.cap, enclosing: args.enclosing }, t1)
					reads = block.reads.bitwise_or(eff_mask(input))
					rc = { input, pending: cfg.pending, plan: planned, resolve: |value, held, at, result| resolve(value, held.value, at, (held.read)(result)), path: args.path, depth }
					(resource_inst(rc, a, s, owned, block), reads, t2)
				},
			),
			|d| {
				d1 = layer(d)
				eff_mask(input).bitwise_or(elem_reads(body({ mask: bit(d1), read: |e| e.value, sel: NoSel }), d1))
			},
		)
	}

	## What a layer following one answer holds (`Engine.Remote`): whether a
	## request for the current input is in flight, and the latest answer.
	Remote(output, error) := { request : [Idle, Pending], answer : [Unanswered, Answered(output), Failed(error)] }.{

		## Compare the pending state and latest answer structurally, for pruning
		## equal observations of a remote result.
		is_eq : _

		## The latest answer, kept while a newer request is pending, or
		## `NoAnswer` before the first answer and after a failure.
		answered : Remote(output, error) -> Try(output, [NoAnswer])
		answered = |remote| match remote.answer {
			Answered(output) => Ok(output)
			_ => Err(NoAnswer)
		}
	}

	## One job of a gathered question: still working, answered, or failed.
	JobState(output, error) : [Working, Answered(output), Failed(error)]

	## What a layer gathering the answers of several jobs holds: the
	## current question's jobs in input order, and `all`, a [Remote] of the
	## whole list, answered once every job has answered and kept while the
	## next question is pending.
	Gathered(output, error) : { all : Remote(List(output), error), jobs : List(JobState(output, error)) }

	## The `resource_at` configuration of a layer that asks one request per
	## input and gathers the answers (`Engine.gather`). A new list marks
	## every job `Working` and `all` `Pending`, keeping its answer; each
	## result settles the job at its position, and once none is working
	## `all` settles too. An empty list is answered at once with `[]`.
	gather : asker -> { init : Gathered(output, error), pending : (Gathered(output, error), List(input) -> Gathered(output, error)), plan : (List(input) -> List(Ask(output, error))), resolve : (Gathered(output, error), List(input), U64, Try(output, error) -> Gathered(output, error)) }
		where [asker.request : asker, input -> Request, asker.result : asker, Result -> Try(output, error)]
	gather = |asker| {
		init: { all: { request: Idle, answer: Unanswered }, jobs: [] },
		pending: |gathered, inputs|
			if inputs.is_empty() {
				{ all: { request: Idle, answer: Answered([]) }, jobs: [] }
			} else {
				{ all: { ..gathered.all, request: Pending }, jobs: inputs.map(|_| Working) }
			},
		plan: |inputs| inputs.map(|input| Core.ask_of(asker, input)),
		resolve: |gathered, _inputs, at, res| {
			job = match res {
				Ok(output) => Answered(output)
				Err(error) => Failed(error)
			}
			jobs = match gathered.jobs.set(at, job) {
				Ok(updated) => updated
				Err(_) => crash "internal: a gathered answer for job ${at.to_str()} of ${gathered.jobs.len().to_str()}"
			}
			{ all: gathered_all(gathered.all, jobs), jobs }
		},
	}

	## An outbox: the latest thing a handler posted, numbered, for
	## `on_post` to send. It lives in the app's state, so the reducer that
	## changes the state also decides what is sent.
	Outbox(a) :: { serial : U64, posted : [Unposted, Posted(a)] }.{

		## Two outboxes are equal when they hold the same post: a post is
		## never equal to the one before it, even with an equal item, so
		## each post is sent and comparing costs nothing.
		is_eq : Outbox(a), Outbox(a) -> Bool
		is_eq = |x, y| x.serial == y.serial

		## Post `item`: the `on_post` site watching this outbox sends it in
		## the turn that posted it.
		post : Outbox(a), a -> Outbox(a)
		post = |box, item| { serial: box.serial + 1, posted: Posted(item) }

		## The latest post, or `Unposted`: for tests of the reducer.
		last : Outbox(a) -> [Unposted, Posted(a)]
		last = |box| box.posted
	}

	## An outbox with nothing posted.
	outbox : {} -> Outbox(a)
	outbox = |_| { serial: 0, posted: Unposted }

	## `on_post(v, plan, react)`: in the turn a handler posts `item` to the
	## outbox `v`, issue `plan(item)`; each result reaches `react` with the
	## item. Nothing is issued at mount and nothing is cancelled, as with
	## `watch_changes`. Two posts to one outbox in one turn are a contract
	## error, since the first would never be sent.
	on_post : Signal(ctx, Outbox(item)), (item -> List(Ask(output, error))), Reaction(ctx, item, Try(output, error)) -> Elem(ctx)
	on_post = |v, plan, react| effect(v, False, |_| [], posted_step(plan), posted_reaction(react), Every)

	## Issue a small posted intent using a reading sampled only when it is sent.
	## Both signals declare reads, but the site's retained value and each result's
	## issued-for value are the outbox item alone, never this transient reading.
	on_post_by : Signal(ctx, Outbox(item)), Signal(ctx, reading), (reading, item -> List(Ask(output, error))), Reaction(ctx, item, Try(output, error)) -> Elem(ctx)
	on_post_by = |box, reading, plan, react| {
		watched = { ..box, mask: eff_mask(box).bitwise_or(eff_mask(reading)), sel: NoSel }
		effect_reading(watched, False, |_, _| [], |env, before, value, path| posted_step(|item| plan((reading.read)(env), item))(before, value, path), posted_reaction(react), Every)
	}

	## The `resource` configuration of a layer that follows the answer to one
	## request for its input, for anything with `request` and `result` (a
	## worker task, a preparation's task, a port call). A new input
	## marks the layer `Pending` and keeps the previous answer; each result
	## settles it as `Answered` or `Failed`. `Worker.resource` and `Port.resource`
	## are this, so the policy has one home.
	follow : asker -> { init : Remote(output, error), pending : (Remote(output, error), input -> Remote(output, error)), plan : (input -> List(Ask(output, error))), resolve : (Remote(output, error), input, Try(output, error) -> Remote(output, error)) }
		where [asker.request : asker, input -> Request, asker.result : asker, Result -> Try(output, error)]
	follow = |asker| {
		init: { request: Idle, answer: Unanswered },
		pending: |remote, _| { ..remote, request: Pending },
		plan: |input| [Core.ask_of(asker, input)],
		resolve: |_, _, res| settled_remote(res),
	}

	## Like `follow`, for an input that is sometimes not a question: `Run(i)`
	## asks about `i`, and `Skip` asks nothing and clears the answer.
	follow_when : asker -> { init : Remote(output, error), pending : (Remote(output, error), [Run(input), Skip] -> Remote(output, error)), plan : ([Run(input), Skip] -> List(Ask(output, error))), resolve : (Remote(output, error), [Run(input), Skip], Try(output, error) -> Remote(output, error)) }
		where [asker.request : asker, input -> Request, asker.result : asker, Result -> Try(output, error)]
	follow_when = |asker| {
		init: { request: Idle, answer: Unanswered },
		pending: |remote, want| match want {
			Run(_) => { ..remote, request: Pending }
			Skip => { request: Idle, answer: Unanswered }
		},
		plan: |want| match want {
			Run(input) => [Core.ask_of(asker, input)]
			Skip => []
		},
		resolve: |_, _, res| settled_remote(res),
	}

	## For test platforms and harnesses: the instance's effect counters (issued,
	## delivered, stale, refused, cancelled, reparented, skipped) and the number
	## of requests in flight.
	fx_stats : App(st) -> { issued : U64, delivered : U64, stale : U64, refused : U64, cancelled : U64, live : U64, reparented : U64, skipped : U64 }
	fx_stats = |a| {
		fx = a.tx.fx
		{ issued: fx.issued, delivered: fx.delivered, stale: fx.stale, refused: fx.refused, cancelled: fx.cancelled, live: fx.live.len(), reparented: fx.reparented, skipped: fx.skipped }
	}

	## For test platforms and harnesses: the ids of the requests in flight, in issue order.
	fx_live : App(st) -> List(U32)
	fx_live = |a| a.tx.fx.live.map(|l| l.id)

	## For the wire format: what a file's encoding carries beside its handle.
	file_parts : File -> { name : Str, mime : Str, size : U64, start : U64, len : U64 }
	file_parts = |f| { name: f.name, mime: f.mime, size: f.size, start: f.start, len: f.len }

	## For the wire format: a file a job was sent, as the worker's host
	## minted its handle; decoding the payload gives it its name, type and
	## range (`placed_file`).
	held_file : Box(U64) -> File
	held_file = |handle| { blob: Blob.(handle), name: "", mime: "", size: 0, start: 0, len: 0, reach: OnPage }

	## For the wire format: the handle that arrived beside a payload at a
	## file's place, with the name, type, size and range the payload gives
	## it. A range outside the size is `Malformed`.
	placed_file : File, { name : Str, mime : Str, size : U64, start : U64, len : U64 } -> Try(File, [Malformed])
	placed_file = |source, { name, mime, size, start, len }| {
		if start > size or len > size - start {
			return Err(Malformed)
		}
		Ok({ blob: source.blob, name, mime, size, start, len, reach: source.reach })
	}

	## For test platforms and harnesses: decode an effect result payload as the
	## host encodes it (design.md, Appendix B). A payload that does not follow the
	## encoding (unknown tag, truncated, trailing bytes, text that is not UTF-8) is
	## a contract error: the host broke the protocol, and nothing is guessed.
	decode_res : List(U8) -> Result
	decode_res = |b| decode_res_with(b, decode_port_res)

	## A zone is an offset table over an inclusive UTC-millisecond span. The
	## first offset starts at from_ms; later offsets start strictly later.
	Zone : { name : Str, from_ms : I64, until_ms : I64, offsets : List({ from_ms : I64, minutes : I32 }) }

	## UTC has no transitions and is valid for every I64 wall-clock timestamp.
	utc : Zone
	utc = { name: "UTC", from_ms: -9223372036854775808, until_ms: 9223372036854775807, offsets: [{ from_ms: -9223372036854775808, minutes: 0 }] }

	## Find minutes east of UTC at a time the zone table covers. OutsideZone
	## is data the app handles; a malformed hand-built table is a contract error.
	zone_offset : Zone, I64 -> Try(I32, [OutsideZone])
	zone_offset = |zone, at_ms| {
		match check_zone(zone) {
			Ok(_) => {}
			Err(message) => crash "contract: zone_offset ${message}"
		}
		if at_ms < zone.from_ms or at_ms > zone.until_ms {
			return Err(OutsideZone)
		}
		var $low = 0.U64
		var $high = zone.offsets.len()
		while $low + 1 < $high {
			middle = $low + ($high - $low) // 2
			offset = zone.offsets.get(middle) ?? crash "internal: zone_offset index"
			if offset.from_ms <= at_ms {
				$low = middle
			} else {
				$high = middle
			}
		}
		Ok((zone.offsets.get($low) ?? crash "internal: zone_offset has no first offset").minutes)
	}

	## What the host knows before the first render: the URL, the declared storage
	## keys' values (missing keys are absent), whether the browser is online and
	## the page visible, and whether local storage is available at all. When it is
	## not, the storage list is empty and `StorageSet`/`StorageRemove` do not
	## persist, so an app that relies on reloads surviving can say so. All
	## fields have defaults: a URL of `/`, empty available storage, online
	## and visible, with no media queries, wall time and seed zero, en-US and
	## full-range UTC. Time, seed, languages and zone stay fixed for the instance;
	## timers supply fresh time through Fired. Pure tests may name only the facts
	## they need; a program supplies declared queries in their declaration order.
	Boot := {
		url : Str ?? "/",
		storage : List((Str, Str)) ?? [],
		online : Bool ?? True,
		visible : Bool ?? True,
		storage_available : Bool ?? True,
		session : List((Str, Str)) ?? [],
		session_available : Bool ?? True,
		media : List((Str, Bool)) ?? [],
		now_ms : I64 ?? 0,
		seed : U128 ?? 0,
		languages : List(Str) ?? ["en-US"],
		zone : Zone ?? utc,
	}.{

		## Compare all boot facts, including the initial storage and browser
		## environment, when a test needs to assert an exact starting context.
		is_eq : _
	}

	## The measured mount element, retained separately from app-visible Boot.
	## Namespace enum aliases retain framing here but resolve by URI identity.
	MountRoot : { namespace : Web.Namespace, prefix : Web.Prefix, local : Str }

	## Empty driver boot uses an ordinary HTML div, as native and browser specs
	## do unless they explicitly choose another actual mount element.
	default_mount_root : MountRoot
	default_mount_root = { namespace: Html, prefix: Unprefixed, local: "div" }

	## Decode engine-only root facts beside the app environment. Nonempty boot
	## must end in section13; every body is consumed and the root is bounded
	## before text decoding. Existing roots need not be reconstructible by an
	## element factory: these are measured identity facts, not creation requests.
	read_mount : List(U8), List(Str) -> Try({ boot : Boot, root : MountRoot }, Str)
	read_mount = |bytes, queries| {
		if bytes.is_empty() {
			return Ok({ boot: Core.read_environment([], queries)?, root: Core.default_mount_root })
		}
		var $boot = Core.read_environment([], queries)?
		var $at = 0.U64
		for section in boot_sections(queries) {
			context = "contract: boot section ${section.tag.to_str()} (${section.name})"
			if $at == bytes.len() {
				return Err("${context} missing section")
			}
			tag = bytes.get($at) ? |_| "${context} missing tag"
			if tag != section.tag {
				return Err("${context} expected tag ${section.tag.to_str()}, got ${tag.to_str()} (unknown, repeated or out-of-order section)")
			}
			length = boot_u32(bytes, $at + 1) ? |reason| "${context} ${reason}"
			start = $at + 5
			if start > bytes.len() or length.to_u64() > bytes.len() - start {
				return Err("${context} truncated body")
			}
			$boot = (section.read)($boot, bytes.sublist({ start, len: length.to_u64() })) ? |reason| "${context} ${reason}"
			$at = start + length.to_u64()
		}
		context = "contract: boot section 13 (mount-root)"
		if bytes.get($at) != Ok(13) {
			return Err("${context} missing, unknown, repeated or out-of-order section")
		}
		length = boot_u32(bytes, $at + 1) ? |reason| "${context} ${reason}"
		if length > 65_536 {
			return Err("${context} exceeds 65536 bytes")
		}
		start = $at + 5
		if start > bytes.len() or length.to_u64() > bytes.len() - start {
			return Err("${context} truncated body")
		}
		if start + length.to_u64() != bytes.len() {
			return Err("${context} trailing bytes or section")
		}
		root = read_mount_root(bytes.sublist({ start, len: length.to_u64() })) ? |reason| "${context} ${reason}"
		Ok({ boot: $boot, root })
	}

	## Decode boot sections without crashing. Empty bytes mean `Boot {}`;
	## otherwise every section must occur once in ascending order. Membership
	## of storage keys is checked separately when a program mounts.
	read_boot : List(U8) -> Try(Boot, Str)
	read_boot = |bytes| Core.read_boot_media(bytes, [])

	## Decode media flags against the declared query order; no names cross in
	## the media boot body. Empty bytes supply False for every declared query.
	read_boot_media : List(U8), List(Str) -> Try(Boot, Str)
	read_boot_media = |bytes, queries| Core.read_mount(bytes, queries).map_ok(|mounted| mounted.boot)

	## Decode only app-visible sections after the engine-only framing has been
	## separated. This preserves Boot's public shape and section diagnostics.
	read_environment : List(U8), List(Str) -> Try(Boot, Str)
	read_environment = |bytes, queries| {
		initial : Boot
		initial = { media: queries.map(|query| (query, False)) }
		var $boot = initial
		if bytes.is_empty() {
			return Ok($boot)
		}
		var $at = 0.U64
		for section in boot_sections(queries) {
			context = "contract: boot section ${section.tag.to_str()} (${section.name})"
			if $at == bytes.len() {
				return Err("${context} missing section")
			}
			tag = bytes.get($at) ? |_| "${context} missing tag"
			if tag != section.tag {
				return Err("${context} expected tag ${section.tag.to_str()}, got ${tag.to_str()} (unknown, repeated or out-of-order section)")
			}
			length = boot_u32(bytes, $at + 1) ? |reason| "${context} ${reason}"
			start = $at + 5
			if length.to_u64() > bytes.len() - start {
				return Err("${context} truncated body")
			}
			$boot = (section.read)($boot, bytes.sublist({ start, len: length.to_u64() })) ? |reason| "${context} ${reason}"
			$at = start + length.to_u64()
		}
		if $at != bytes.len() {
			tag = bytes.get($at) ? |_| "contract: boot section after session-storage missing tag"
			return Err("contract: boot section ${tag.to_str()} after section 11 (session-storage): unexpected section")
		}
		Ok($boot)
	}

	## Encode all boot sections in wire order. Harnesses supply only values
	## consistent with their program's declared storage keys.
	write_boot : Boot -> List(U8)
	write_boot = |boot| Core.write_mount(boot, Core.default_mount_root)

	## Encode an app environment beside engine-only root facts. Harnesses retain
	## both, while app code is handed only Boot. The root body has a 64 KiB bound.
	write_mount : Boot, MountRoot -> List(U8)
	write_mount = |boot, mount_root| {
		location = put_section([], 1, put_str([], boot.url))
		var $storage = put_u32([if (boot.storage_available) 1 else 0], boot.storage.len().to_u32_wrap())
		for (key, value) in boot.storage {
			$storage = put_str(put_str($storage, key), value)
		}
		local = put_section(location, 2, $storage)
		online = put_section(local, 3, [if (boot.online) 1 else 0])
		visible = put_section(online, 4, [if (boot.visible) 1 else 0])
		media = put_section(visible, 6, boot.media.map(|(_, matches)| if (matches) 1 else 0))
		time = put_section(media, 7, put_u64([], boot.now_ms.to_u64_wrap()))
		seed = put_section(time, 8, put_u128([], boot.seed))
		languages = boot.languages.fold(put_u32([], boot.languages.len().to_u32_wrap()), put_str)
		zone = boot.zone
		var $offsets = put_u32(put_u64(put_u64(put_str([], zone.name), zone.from_ms.to_u64_wrap()), zone.until_ms.to_u64_wrap()), zone.offsets.len().to_u32_wrap())
		for offset in zone.offsets {
			$offsets = put_u32(put_u64($offsets, offset.from_ms.to_u64_wrap()), offset.minutes.to_u32_wrap())
		}
		zone_bytes = put_section(put_section(seed, 9, languages), 10, $offsets)
		body = boot.session.fold(put_u32([if (boot.session_available) 1 else 0], boot.session.len().to_u32_wrap()), |bytes, (key, value)| put_str(put_str(bytes, key), value))
		environment = put_section(zone_bytes, 11, body)
		root_body = put_expanded_name([], mount_root.namespace, mount_root.prefix, mount_root.local)
		if root_body.len() > 65_536 {
			crash "contract: boot section 13 (mount-root) exceeds 65536 bytes"
		}
		put_section(environment, 13, root_body)
	}

	## The boot value of a declared storage key, or `Missing` if it has none.
	boot_storage : Boot, Str -> Try(Str, [Missing])
	boot_storage = |boot, key| match boot.storage.find_first(|(k, _)| k == key) {
		Ok((_, v)) => Ok(v)
		Err(_) => Err(Missing)
	}

	## The session draft read before mount, or Missing when that key was absent.
	boot_session : Boot, Str -> Try(Str, [Missing])
	boot_session = |boot, key| match boot.session.find_first(|(name, _)| name == key) {
		Ok((_, value)) => Ok(value)
		Err(_) => Err(Missing)
	}

	## Read a declared media query's boot value. An undeclared query is an
	## explicit error, so a pure test can catch a misspelt declaration.
	boot_media : Boot, Str -> Try(Bool, [Undeclared])
	boot_media = |boot, query| match boot.media.find_first(|(name, _)| name == query) {
		Ok((_, matches)) => Ok(matches)
		Err(_) => Err(Undeclared)
	}

	## Validate program text before mounting: at most 32 distinct nonempty
	## media queries, each no longer than 256 UTF-8 bytes.
	media_catalogue : List(Str) -> Try(List(Str), Str)
	media_catalogue = |queries| {
		var $seen = []
		for query in queries {
			if $seen.len() >= 32 {
				return Err("contract: more than 32 declared media queries (query \"${query}\" is over the bound)")
			}
			if query.is_empty() or query.count_utf8_bytes() > 256 {
				return Err("contract: media query \"${query}\" must be 1 to 256 UTF-8 bytes")
			}
			if $seen.contains(query) {
				return Err("contract: media query \"${query}\" is declared twice")
			}
			$seen = $seen.append(query)
		}
		Ok(queries)
	}

	## A value that never changes. It reads no layer, so it never triggers a refresh.
	const : a -> Signal(ctx, a)
	const = |value| { mask: 0, read: |_| value, sel: NoSel }

	## `element(tag, attrs, children)`: an HTML element. `Html` offers typed
	## helpers for common elements and controls.
	element : Str, List(Attr(ctx)), List(Elem(ctx)) -> Elem(ctx)
	element = |tag, attrs, kids| Core.element_named(Web.Tag.from_str(tag) ?? crash "internal: invalid element name", attrs, kids)

	## Keep checked construction facts whole until the enclosing context resolves
	## raw namespace inheritance. Only Engine calls this name-preserving boundary.
	element_named : Web.Tag, List(Attr(ctx)), List(Elem(ctx)) -> Elem(ctx)
	element_named = |tag, attrs, kids| Element(
		{ name: tag, container: Children },
		attrs.fold(
			[],
			|out, attribute| match attribute {
				KeyOn(event, handler, keymap) => out.concat([PropertyV(if (event.event == "keydown") 4 else 5, keymap), On(event, handler)])
				ShownOn(index, value, handler, showing) => out.concat([PropertyV(index, value), attach_open(index, showing, handler)])
				_ => out.append(attribute)
			},
		),
		kids,
	)

	## Internal vocabulary construction keeps its private shown row paired with its handler.
	controlled_dialog : { label : Str, open : Signal(ctx, Bool), on_close : HandlerOf(ctx, Bool), modal : [Modal, NonModal], attrs : List(Attr(ctx)), children : List(Elem(ctx)) } -> Elem(ctx)
	controlled_dialog = |props| Core.element(
		"dialog",
		[ShownOn(6, props.open.map(|open| if (!open) "hidden" else if (props.modal == Modal) "modal" else "open"), props.on_close, if (props.modal == Modal) "modal" else "open"), Core.attr("aria-label", props.label)].concat(props.attrs),
		[Core.when(props.open, || Fragment(props.children), || Fragment([]))],
	)

	## A controlled popover owns one static dismissal mode and its toggle echo.
	controlled_popover : { label : Str, open : Signal(ctx, Bool), on_toggle : HandlerOf(ctx, Bool), dismiss : [Auto, Manual], attrs : List(Attr(ctx)), children : List(Elem(ctx)) } -> Elem(ctx)
	controlled_popover = |props| Core.element(
		"div",
		[Core.attr("popover", if (props.dismiss == Auto) "auto" else "manual"), ShownOn(7, props.open.map(|open| if (open) "true" else "false"), props.on_toggle, "true"), Core.attr("aria-label", props.label)].concat(props.attrs),
		props.children,
	)

	## Preserve an authored literal comment as data. It occupies a child position
	## but never contributes to text content, diagnostics or routing.
	comment : Str -> Elem(ctx)
	comment = |value| Comment(value)

	## Select an HTML template's inert content fragment for its authored children.
	## The choice belongs to the description; ordinary element construction keeps
	## ordinary children, even on a template. Name validation waits for resolution.
	template_content : Elem(ctx) -> Elem(ctx)
	template_content = |elem| match elem {
		Element(description, attrs, kids) => Element({ ..description, container: TemplateContent }, attrs, kids)
		_ => crash "contract: template_content requires one element description"
	}

	## A literal fragment's finite placement requirement, checked at construction.
	## This wraps a description without allocating another reactive site.
	require_parent : Elem(ctx), List([Svg]) -> Elem(ctx)
	require_parent = |elem, allowed| Placed(allowed, elem)

	## A static text node.
	text : Str -> Elem(ctx)
	text = |s| Text(s)

	## A text node whose content follows a value; the DOM is written only when
	## the text changes.
	text_s : Signal(ctx, Str) -> Elem(ctx)
	text_s = |v| TextV(v)

	## Set literal attribute text, including empty and "false" text as present.
	## Typed Html helpers decide absence upstream. Use a property builder for
	## names a control claims.
	attr : Str, Str -> Attr(ctx)
	attr = |name, value| Core.attr_named(Web.AttrName.from_str(name) ?? crash "internal: invalid attribute name", value)

	## Preserve a checked attribute's expanded identity and exact-case intent.
	attr_named : Web.AttrName, Str -> Attr(ctx)
	attr_named = |name, value| Static(name, value)

	## Follow a signal with an attribute, writing only when it changes. An
	## empty string or "false" keeps any attribute present. Names claimed by
	## an element property are rejected on that property's elements; use
	## `prop_s` for live control state.
	attr_s : Str, Signal(ctx, Str) -> Attr(ctx)
	attr_s = |name, v| Core.attr_named_s(Web.AttrName.from_str(name) ?? crash "internal: invalid attribute name", v)

	## Classify an already-resolved attribute against the element's live property
	## claims. Literal lowering uses the same policy before emission, with its own
	## source position; the oracle implements its checks independently. This
	## internal query never folds exact names or infers an attribute namespace.
	attribute_claim : Web.Tag, Web.AttrName -> [Unclaimed, Claimed(Str)]
	attribute_claim = |resolved, attribute| {
		if resolved.namespace() != Explicit(Html) {
			return Unclaimed
		}
		for index in [1.U8, 2] {
			row = property_row(index)
			if row.elements.contains(resolved.local()) and ordinary_attribute_is(attribute, row.name) {
				return Claimed(row.name)
			}
		}
		Unclaimed
	}

	## One ordinary attribute reader with an explicitly checked name.
	attr_named_s : Web.AttrName, Signal(ctx, Str) -> Attr(ctx)
	attr_named_s = |name, value| Dyn(name, value.map(|encoded| Present(encoded)))

	## Follow explicit attribute presence. `Present("")` keeps an empty
	## attribute; `Absent` alone removes it. Names claimed by control properties
	## require their property builder. The same hole and equality
	## cutoff serve both this builder and `attr_s`.
	attr_presence : Str, Signal(ctx, [Absent, Present(Str)]) -> Attr(ctx)
	attr_presence = |name, value| Core.attr_named_presence(Web.AttrName.from_str(name) ?? crash "internal: invalid attribute name", value)

	## Explicit presence shares the ordinary reader and equality cutoff while
	## retaining the complete name through static and template construction.
	attr_named_presence : Web.AttrName, Signal(ctx, [Absent, Present(Str)]) -> Attr(ctx)
	attr_named_presence = |name, value| Dyn(name, value)

	## A static `class` attribute.
	class : Str -> Attr(ctx)
	class = |c| Core.attr("class", c)

	## A `class` attribute that follows a value.
	class_s : Signal(ctx, Str) -> Attr(ctx)
	class_s = |v| Core.attr_s("class", v)

	## A static `data-testid` attribute, for spec locators.
	test_id : Str -> Attr(ctx)
	test_id = |v| Core.attr("data-testid", v)

	## A `data-testid` attribute that follows a value.
	test_id_s : Signal(ctx, Str) -> Attr(ctx)
	test_id_s = |v| Core.attr_s("data-testid", v)

	## Static dispatch policies, checked by the compiler. Prevention and
	## propagation must be decided before an event's synchronous window closes.
	Policy := { prevent : Bool ?? False, stop : Bool ?? False }

	## A pointer's state at dispatch. Its nearest zone is application text;
	## coordinates are shares of that zone's box, from 0 to 10000 inclusive.
	## Capture affects routing, while the hit-tested zone stays under the pointer.
	Pointer : {
		id : U32,
		kind : [Mouse, Pen, Touch, Other],
		button : [None, Main, Middle, Secondary, Back, Forward, Other(U8)],
		buttons : U16,
		modifiers : { shift : Bool, ctrl : Bool, alt : Bool, meta : Bool },
		primary : Bool,
		at : [Outside, In({ zone : Str, x : U16, y : U16 })],
	}

	## Type evidence for an attachment whose lifetime cannot be owned by a row.
	OutsideRows(ctx) :: { proof : (ctx -> ctx) }

	## A browser key and the declared chord that caused its handler to hear it.
	Key : { key : Str, code : Str, ctrl : Bool, alt : Bool, shift : Bool, meta : Bool, repeat : Bool, composing : Bool, heard : Chord }

	## A key with exact modifiers. Compare a payload's heard chord with the
	## declared chord rather than repeating the browser's matching rules.
	Chord :: { key : Str, ctrl : Bool, alt : Bool, shift : Bool, meta : Bool }.{

		## A key without held modifiers.
		plain : Str -> Chord
		plain = |key| { key, ctrl: False, alt: False, shift: False, meta: False }

		## Require Shift with this chord.
		with_shift : Chord -> Chord
		with_shift = |chord| { ..chord, shift: True }

		## Require Control with this chord.
		with_ctrl : Chord -> Chord
		with_ctrl = |chord| { ..chord, ctrl: True }

		## Require Alt with this chord.
		with_alt : Chord -> Chord
		with_alt = |chord| { ..chord, alt: True }

		## Require Meta (Command on macOS) with this chord.
		with_meta : Chord -> Chord
		with_meta = |chord| { ..chord, meta: True }

		## The Control and Meta alternatives for a platform primary shortcut.
		primary : Chord -> List(Chord)
		primary = |chord| [chord.with_ctrl(), chord.with_meta()]

		## Compare the logical or physical key and every modifier exactly. A
		## primary shortcut therefore has distinct Control and Meta chords.
		is_eq : _
	}

	## An ordered rendered filter. Explicit entries are tried before every;
	## each matching entry states whether its browser default is prevented.
	Keymap :: { entries : List({ chord : Chord, prevent : Bool, outside : Bool }), every : [NoEvery, Every(Bool)] }.{

		## Hear these chords and prevent their browser defaults.
		prevent : List(Chord) -> Keymap
		prevent = |chords| { entries: chords.map(|chord| { chord, prevent: True, outside: False }), every: NoEvery }

		## Hear these chords while preserving their browser defaults.
		keep : List(Chord) -> Keymap
		keep = |chords| { entries: chords.map(|chord| { chord, prevent: False, outside: False }), every: NoEvery }

		## Hear any remaining key, including composition, without prevention.
		every : Keymap
		every = { entries: [], every: Every(False) }

		## Preserve listed order; an anywhere every wins over an outside-text every.
		concat : Keymap, Keymap -> Keymap
		concat = |first, second| {
			entries: first.entries.concat(second.entries),
			every: match (first.every, second.every) {
				(NoEvery, other) => other
				(other, NoEvery) => other
				(Every(a), Every(b)) => Every(a and b)
			},
		}

		## Ignore this map's entries in inputs, textareas, selects and editable text.
		outside_text : Keymap -> Keymap
		outside_text = |map| {
			entries: map.entries.map(|entry| { ..entry, outside: True }),
			every: match map.every {
				NoEvery => NoEvery
				Every(_) => Every(True)
			},
		}

		## Compare the ordered entries and their prevention rules. Entry order
		## is significant when several entries match the same keyboard event.
		is_eq : _
	}

	## A keymap paired with one key event handler; prevention belongs to the map.
	KeyProps(ctx) := { keymap : Signal(ctx, Keymap), on : [Down, Up] ?? Down, stop : Bool ?? False }

	## Document shortcuts have the same declared keymap and propagation policy.
	DocumentKeyProps(ctx) := { keymap : Signal(ctx, Keymap), on : [Down, Up] ?? Down, stop : Bool ?? False }

	## Receive keys heard by the rendered map, passing other keys to ancestors.
	on_key : KeyProps(ctx), HandlerOf(ctx, Key) -> Attr(ctx)
	on_key = |props, handler| attach_key(props.keymap, props.on, props.stop, False, handler)

	## Receive document keys after this mount's element handlers. The most
	## recently mounted matching declaration wins and disposal releases it.
	on_document_key : DocumentKeyProps(ctx), HandlerOf(ctx, Key) -> Attr(ctx)
		where [ctx.outside_rows : () -> OutsideRows(ctx)]
	on_document_key = |props, handler| {
		Context : ctx
		_ = Context.outside_rows()
		attach_key(props.keymap, props.on, props.stop, True, handler)
	}

	## One typed row of the platform's payload vocabulary. Only an attach
	## function chooses a kind; applications cannot construct a decoder.
	Kind(p) :: { code : U8, decode : (Payload, List(U32) -> p) }

	## A property row fixes both the value type and its wire encoding.
	Prop(a) :: { index : U8, encode : (a -> Str) }.{

		## A control's live text, under the controlled-input rule.
		value : Prop(Str)
		value = { index: 1, encode: |content| content }

		## An input's checked state, encoded as a canonical boolean.
		checked : Prop(Bool)
		checked = { index: 2, encode: |checked| if (checked) "true" else "false" }

		## The key the pointer hit test reports for this element. Empty text
		## disables the zone; the key is never interpreted or used as identity.
		pointer_zone : Prop(Str)
		pointer_zone = { index: 3, encode: |zone| zone }
	}

	## Set a property from its typed row; ordinary attributes remain attributes.
	prop : Prop(a), a -> Attr(ctx)
	prop = |{ index, encode }, value| Property(index, encode(value))

	## Follow a signal with a property, pruning equal encoded values at its hole.
	prop_s : Prop(a), Signal(ctx, a) -> Attr(ctx)
	prop_s = |{ index, encode }, value| PropertyV(index, value.map(encode))

	## Listen for a text event with no synchronous browser policy.
	on : Str, Handler(ctx) -> Attr(ctx)
	on = |event, handler| Core.on_with(event, {}, handler)

	## Listen for text with static prevention and propagation policies.
	on_with : Str, Policy, Handler(ctx) -> Attr(ctx)
	on_with = |event, policy, handler| attach_kind(event, text_kind, policy_bits(policy), handler)

	## Read a checkbox's or radio's checked state as a Boolean on change.
	on_checked : HandlerOf(ctx, Bool) -> Attr(ctx)
	on_checked = |handler| attach_kind("change", open_kind, 0, handler)

	## Receive a pointer record from one of the four pointer event types.
	## Every move is an occurrence unless `on_pointer_paced` declares otherwise.
	on_pointer : [Down, Move, Up, Cancel], HandlerOf(ctx, Pointer) -> Attr(ctx)
	on_pointer = |event, handler| attach_kind(pointer_event(event), pointer_kind(event), 0, handler)

	## Capture the pointer on this handler's element during pointerdown,
	## before its turn can wait. A refused browser capture still dispatches.
	on_pointer_capture : HandlerOf(ctx, Pointer) -> Attr(ctx)
	on_pointer_capture = |handler| attach_kind("pointerdown", pointer_kind(Down), 4, handler)

	## Receive the newest waiting move per pointer at the next frame. An up
	## or another occurrence first delivers moves queued ahead of it.
	on_pointer_paced : HandlerOf(ctx, Pointer) -> Attr(ctx)
	on_pointer_paced = |handler| attach_kind("pointermove", pointer_kind(Move), 8, handler)

	## Text captured during a paste, or a refusal before it enters Wasm.
	Paste : [Text(Str), TooLarge]

	## Attach the bounded text-paste codec; its element prevents the native paste.
	on_paste_text : HandlerOf(ctx, Paste) -> Attr(ctx)
	on_paste_text = |handler| attach_kind("paste", paste_kind, 1, handler)

	## Follow this element's scroll offsets as a report at the next frame.
	on_scroll : HandlerOf(ctx, Layout.Scroll) -> Attr(ctx)
	on_scroll = |handler| attach_kind("scroll", scroll_kind, 8, handler)

	## Observe the element's content box until its owning scope is disposed.
	on_size : HandlerOf(ctx, Layout.Size) -> Attr(ctx)
	on_size = |handler| attach_kind("size", size_kind, 8, handler)

	## Whether visibility should also report one screen ahead of the element.
	SeenProps := { ahead : Bool ?? False }

	## Observe intersection changes, optionally before the element is on screen.
	on_seen : SeenProps, HandlerOf(ctx, Layout.Seen) -> Attr(ctx)
	on_seen = |props, handler| attach_kind("seen", seen_kind, if (props.ahead) 40 else 8, handler)

	## Where the browser aligns a target within its scrolling ancestors.
	Align : [Start, Center, End, Nearest]

	## One axis of an explicit scroll; End is resolved by the browser.
	Edge : [Keep, Start, End, Px(U32)]

	## Whether a scroll uses CSS behavior, moves instantly or animates.
	ScrollBehavior : [Auto, Instant, Smooth]

	## Scroll alignment with nearest-edge behavior unless the caller chooses otherwise.
	ScrollProps := { block : Align ?? Nearest, inline : Align ?? Nearest, behavior : ScrollBehavior ?? Auto }

	## Scroll a named element after the batch; a missing name counts as stale.
	## Its narrow tag also fits a cleanup plan.
	scroll_into_view : Str, ScrollProps -> [ScrollIntoView(Str, { block : Align, inline : Align, behavior : ScrollBehavior })]
	scroll_into_view = |name, props| ScrollIntoView(name, { block: props.block, inline: props.inline, behavior: props.behavior })

	## Name this element as a focus reference for `Focus`, `Blur` and `SelectText`
	## requests, so the app never handles engine node ids. Names are unique
	## among live elements and released with the element. An empty name names
	## nothing. Use `ref_s` when the name depends on a signal or row key.
	ref : Str -> Attr(ctx)
	ref = |name| Ref(Core.const(name))

	## Name this element from a signal, including a row key. An empty name
	## registers nothing; two live elements with one name are a contract error
	## checked at the end of the turn. Changing a name emits no DOM command.
	ref_s : Signal(ctx, Str) -> Attr(ctx)
	ref_s = |value| Ref(value)

	## A `click` listener; its payload is empty.
	on_click : Handler(ctx) -> Attr(ctx)
	on_click = |h| Core.on("click", h)

	## `on_files(event, handler)` listens for the files an event carries:
	## `"change"` on a file input, `"drop"` (whose default the runtime
	## prevents, with `dragover`'s, so the browser does not open the file) and
	## `"paste"`. The handler receives the files as handles, never their bytes.
	on_files : [Change, Drop, Paste], FilesHandler(ctx) -> Attr(ctx)
	on_files = |event, handler| attach_kind(
		match event {
			Change => "change"
			Drop => "drop"
			Paste => "paste"
		},
		files_kind,
		0,
		handler,
	)

	## A mounted engine instance owns its store as plain data beside its site
	## tree and turn state. No site captures the store. The host
	## holds it between calls through [Program]; test platforms and harnesses drive
	## it directly with `mount`, `event`, `result` and `take_cmds`. `programs`
	## is the program's catalogue: its worker tasks' names and its ports.
	App(st) :: { root : Inst(Root(st)), store : st, tx : Tx, programs : Catalogue }

	## The site tree and engine bookkeeping, separated from the store only while
	## the platform moves both parts through its single opaque host handle.
	Sites(st) :: { root : Inst(Root(st)), tx : Tx, programs : Catalogue }

	## Move the store out as plain data; no site captures it.
	split : App(st) -> (st, Sites(st))
	split = |{ store, root, tx, programs }| (store, { root, tx, programs })

	## Reunite the uniquely owned store with its site tree after host transfer.
	join : st, Sites(st) -> App(st)
	join = |store, { root, tx, programs }| { store, root, tx, programs }

	## What a program declares beside its view, kept beside the engine root
	## (never in the turn, whose every field costs code at each site
	## that rebuilds it): the worker catalogue's names and the port
	## declarations with the port code that serves them.
	Catalogue : { workers : List(Str), ports : Ports, media : List(Str) }

	## A program's ports: the declarations, and every piece of port code the
	## engine runs outside the typed layer, reached only through these
	## closures. `with_ports` installs the real ones; a program that never
	## calls it holds stubs that write an empty port table and treat any port
	## request or port result as the contract error it is, so its module
	## carries no port codec (design.md, "Ports").
	##
	## - `table` writes the port table after the boot keys;
	## - `check` is the end-of-turn use check of one request;
	## - `write` puts a turn's port requests (the `Port` entries of its
	##   [TurnEnd] list) into its batch, each where it was issued;
	## - `decode` reads result tags 14 and 15 (and an answer's file handles);
	## - `ends` says whether a result ends a subscription.
	Ports : {
		decls : List(PortDecl),
		table : List(U8), List(PortDecl) -> List(U8),
		check : List(PortDecl), PortAt -> {},
		write : Tx, List(TurnEnd) -> Tx,
		decode : List(U8), List(Blob) -> Result,
		ends : Result -> Bool,
	}

	## For test platforms and harnesses: mount an app under host node 0 with the
	## default in-flight bound of 32. The mount's commands wait in the instance
	## until `take_cmds`.
	mount : Elem(Root({})) -> App({})
	mount = |elem| Core.mount_with(32, elem)

	## For test platforms and harnesses: mount with an explicit in-flight effect
	## bound, running any follow-up turns the mount queued.
	mount_with : U64, Elem(Root({})) -> App({})
	mount_with = |max, elem| mount_in(max, { workers: [], ports: no_ports, media: [] }, {}, elem)

	## For test platforms and harnesses: mount an app whose instance holds
	## the store that starts as `start` (`Store.initial`), with an explicit
	## in-flight bound.
	mount_store : U64, Start(st), Elem(Root(st)) -> App(st)
	mount_store = |max, start, elem| mount_start(max, { workers: [], ports: no_ports, media: [] }, start, elem)

	## For test platforms and harnesses: deliver a DOM event to `node` and its
	## handler number with the event's payload, as one turn (plus any
	## follow-up turns). An event on a node that has since been removed is ignored.
	event : App(st), U32, U32, Str -> App(st)
	event = |inst, node, handler, payload| deliver(inst, node, handler, Ev(payload.to_utf8()))

	## For test platforms and harnesses: deliver the files a files-kind event
	## carries, as one turn like `event`. `record` is the event's file
	## record (Appendix B) and `blobs` the handles the host minted for it, in
	## the record's order; a record that does not match them is a contract
	## error. An event on a removed node is ignored, and its handles go with it.
	event_files : App(st), U32, U32, List(U8), List(Blob) -> App(st)
	event_files = |inst, node, handler, record, blobs| {
		deliver(inst, node, handler, Files(record, blobs))
	}

	## Route an event's payload to its node's handler.
	deliver : App(st), U32, U32, Payload -> App(st)
	deliver = |{ store, root, tx, programs }, node, handler, payload| {
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
			Err(Stale) => { store, root, tx, programs }
			Ok((path, h)) => drain(turn({ store, root, tx: start_batch(tx), programs }, path, h, payload))
		}
	}

	## For test platforms and harnesses: deliver an effect result for request `id`,
	## as one turn exactly like an event. An id that is not in flight is
	## dropped and counted `stale`.
	result : App(st), U32, Result -> App(st)
	result = |{ store, root, tx, programs }, id, res| {
		match tx.fx.live.find_first(|l| l.id == id) {
			Err(_) => { store, root, tx: fx_count(tx, Stale), programs }
			Ok(entry) => {
				# A subscription stays live until it is cancelled, unless its
				# JavaScript ended it (a port's `Closed` or `Threw`).
				live = entry.sub and !(programs.ports.ends)(res)
				tx1 = if (live) tx else with_fx(tx, |fx| { ..fx, live: fx.live.keep_if(|l| l.id != id) })
				drain(turn({ store, root, tx: start_batch(tx1), programs }, entry.path, id, Fx(Final(res, live))))
			}
		}
	}

	## Deliver a sampled transfer through its live request’s owning path without
	## retiring the request. An unsolicited report is a contract error.
	progress : App(st), U32, Transfer -> App(st)
	progress = |{ store, root, tx, programs }, id, transfer| match tx.fx.live.find_first(|entry| entry.id == id) {
		Err(_) => { store, root, tx: fx_count(tx, Stale), programs }
		Ok(entry) => if entry.progress {
			drain(turn({ store, root, tx: start_batch(tx), programs }, entry.path, id, Fx(Progress(transfer))))
		} else crash "contract: transfer progress was not requested for effect ${id.to_str()} at site ${show_path(entry.path)}"
	}

	## For test platforms and harnesses: take the commands accumulated since the
	## last call, reusing `buf` (cleared) for the next batch.
	## Finalization merges transition types into one terminal command.
	take_cmds : App(st), List(U8) -> (App(st), List(U8))
	take_cmds = |{ store, root, tx, programs }, buf| {
		{ cmds, next, free, routes, work, paths, site_free, observations, fx } = tx
		{ next: fx_next, inner, live, queue, max, issued, delivered, stale, refused, cancelled, reparented, skipped, document_nodes, observed, refs, focus, ref_pos, cleanups, guard, batch } = fx
		{ mounting, asked, types, seen: _, capture: _ } = batch
		var $cmds = cmds
		if asked {
			$cmds = $cmds.set(0, 1) ?? crash "internal: missing batch header"
			$cmds = put_u32($cmds.append(24), types.len().to_u32_wrap())
			for name in types {
				$cmds = put_str($cmds, name)
			}
		} else if $cmds.len() == 1 {
			$cmds = $cmds.clear()
		}
		fx2 = { next: fx_next, inner, live, queue, max, issued, delivered, stale, refused, cancelled, reparented, skipped, document_nodes, observed, refs, focus, ref_pos, cleanups, guard, batch: { mounting, asked: False, types: [], seen: Dict.empty(), capture: PictureCapture.disabled } }
		({ store, root, tx: { cmds: buf.clear(), next, free, routes, work: add_work(work, 45, if (asked) 1 else 0), paths, site_free, observations, fx: fx2 }, programs }, $cmds)
	}

	## For test platforms and harnesses: how many app closures (holes, values,
	## reducers) the instance has evaluated so far.
	evals : App(st) -> U64
	evals = |a| work_get(a.tx.work, w_evals)

	## For test platforms and harnesses: the instance's work counters so far, in
	## the order of the host's work record (design.md, "Work assertions").
	work_counters : App(st) -> List(U64)
	work_counters = |a| {
		var $out = []
		var $i = 0.U64
		while $i < w_count {
			$out = $out.append(work_get(a.tx.work, $i))
			$i = $i + 1
		}
		$out.concat(fx_counters(a)).concat([work_get(a.tx.work, w_port_sends), work_get(a.tx.work, 41), work_get(a.tx.work, 42), work_get(a.tx.work, 43), a.tx.fx.observed.live, work_get(a.tx.work, 45), work_get(a.tx.work, 46), work_get(a.tx.work, 47), work_get(a.tx.work, 48)])
	}

	# ------------------------------------------------------------------
	# The settle check: a propagation-completeness oracle for harnesses.

	## For test platforms and harnesses: whether every reader in the instance
	## already shows what its layers imply, which is what a complete turn
	## leaves behind (design.md, "Fuzzing, walks, soak and contract tests").
	##
	## It runs one root `Changed` pass with every layer bit set on a copy of
	## the instance and discards the copy. That pass re-evaluates every hole,
	## re-decides every `when` and `switch`, reconciles every `each`, re-reads
	## every `derive` and `resource` input and every effect site's watched
	## value, and reaches into every row; each of those prunes against what
	## it last emitted or holds. So on
	## a settled instance it emits nothing and changes no effect state, and a
	## reader the last turn missed shows up as the command that turn should
	## have emitted: `Err` carries the pass's commands (from opcode 1, as the
	## wire encodes them) and a note naming any change it made to the effect
	## channel without a command (a follow-up queued, a request refused).
	##
	## A view site (`table_view`) keeps its storage from its table's
	## changes instead of comparing values, so pruning alone would
	## not catch a view the turn left behind. In this pass each view site
	## also builds its view from scratch and requires the one it holds to be
	## equal to it (the ordered keys, the window, the rows drawn), at the
	## table's version, with its recording phase ready for the next turn; a
	## difference is
	## part of the note.
	##
	## The end of the turn ([TurnEnd]: focus, program checks, port requests)
	## is not run and follow-ups do not run; a request the pass queues for it
	## is a change.
	##
	## The instance passed in is never changed: while the copy is alive it
	## shares the instance's storage, so the pass copies what it touches, and
	## once the result is dropped the instance owns its storage alone again.
	## Run it outside any region that measures allocations.
	settled : App(st) -> Try({}, { cmds : List(U8), note : Str })
	settled = |{ store, root, tx, programs: _ }| {
		before = tx.fx
		scratch = with_fx(tx, |effects| { ..effects, batch: { mounting: False, asked: False, types: [], seen: Dict.empty(), capture: PictureCapture.disabled } })
		(_, _, after) = call(root, Root.{ store }, Changed(every_layer), { ..scratch, cmds: [] })
		note = settle_note(before, after.fx)
		if (after.cmds.is_empty() and note.is_empty()) Ok({}) else Err({ cmds: after.cmds, note })
	}

	## The wire protocol version this engine speaks (design.md, Appendix B). The
	## host exports it, and the runtime refuses an instance whose version it does
	## not implement.
	protocol_version : U32
	protocol_version = 18

	## A worker task as the catalogue holds it (design.md, "Workers"): a
	## namespaced name (`"example.org/search/filter"`) and its effectful
	## entry `run!`, from input bytes and the handles the worker's host minted
	## for the job's files to its answer, `n:u32 (token:u64)* output:rest`.
	## `Worker` makes one from a typed task; apps list it in `with_workers`.
	##
	## A preparation registers under its own name with the names of the
	## tasks that read its state (`tasks`), and `prepare!` builds the
	## [Prepared] value those tasks read; a task that is not a preparation's has no
	## `tasks`. A preparation's `run!`, and a task's `prepare!`, are contract
	## errors.
	Registration :: { name : Str, tasks : List(Str), run! : (List(U8), List(File) => List(U8)), prepare! : (List(U8), List(File) => Prepared) }

	## For the worker layer: the task `name`, whose effectful entry `run!`
	## turns a request's input bytes and the handles of its files into its
	## answer, `n:u32 (token:u64)* output:rest`. It runs in a worker
	## instance, where it may call the platform's hosted effects on those
	## handles and on builders it opens.
	registration : Str, (List(U8), List(File) => List(U8)) -> Registration
	registration = |name, run!| { name, tasks: [], run!, prepare!: not_prepared }

	## For the worker layer: the preparation `name`, whose state the tasks
	## `tasks` read. `prepare!` turns the preparation's input bytes and its
	## files into the [Prepared] value a worker instance may keep between
	## jobs; every answer must be what preparing afresh and asking would give.
	registration_prepared : Str, List(Str), (List(U8), List(File) => Prepared) -> Registration
	registration_prepared = |name, tasks, prepare!| { name, tasks, run!: |_, _| crash "contract: worker task \"${name}\" is a preparation; ask one of its tasks", prepare! }

	## A preparation's state as the worker layer builds it: the
	## preparation's name and `ask!`, a closure over the typed state that
	## runs one of its tasks, `ask!(task, input_bytes, files)`, and answers as
	## a task's entry does. `work_prepare!` turns it into the [Kept] value
	## the worker's host holds.
	Prepared :: { prep : Str, ask! : (Str, List(U8), List(File) => List(U8)) }

	## For the worker layer: the prepared state of the preparation `prep`.
	kept : Str, (Str, List(U8), List(File) => List(U8)) -> Prepared
	kept = |prep, ask!| { prep, ask! }

	## A preparation's state as a worker instance holds it between jobs
	## (design.md, "Prepared state"): the preparation's name and `ask!`,
	## which runs one of its tasks on the job's handles, `ask!(task,
	## input_bytes, handles)`. It takes handles, not files, and captures the
	## job effects `work_prepare!` was handed, so no function value appears
	## in its type but the one the host boundary requires boxed. The state
	## never crosses a boundary; the worker's host keeps one `Box(Kept)` as
	## the page's host keeps one opaque instance handle, and every answer is what preparing
	## afresh would give. Compiler workaround
	## (https://github.com/roc-lang/roc/issues/12953): the host boundary
	## rejects `Box(Kept)` while `ask!` is a bare function, so `ask!` is boxed
	## on its own (`work_prepare!` boxes it, `work_ask!` unboxes it) until
	## the plain box is accepted again.
	Kept :: { prep : Str, ask! : Box((Str, List(U8), List(Box(U64)) => List(U8))) }

	## What the host drives: the protocol version, the declaration sections (read
	## before mount), mount once with the boot bytes, then one turn per
	## event or effect result. Each call returns the state, the command batch and
	## the work record, and the host lends both buffers back on the next call so
	## they are reused in place. A worker instance of the same module never
	## mounts; it only runs the catalogue's tasks. Apps build one with
	## `program` or `program_boot` and bind it as `main`.
	Program(st) :: {
		version : U32,
		keys : () -> List(U8),
		init : Catalogue, List(U8), PictureCapture.Capture -> App(st),
		event : App(st), List(U8), List(U8), U32, U32, List(U8) -> (App(st), List(U8), List(U8)),
		workers : List(Registration),
		ports : Ports,
		media : List(Str),
		zone_days : U16,
		session_keys : List(Str),
	}.{

		## Declare the ports the program's effect sites use (see [PortDecl]):
		## the services the page's JavaScript supplies at mount. At most 64,
		## each name once and 1 to 128 bytes long; anything else is a contract
		## error when these declarations and the program are built, at compile
		## time for a top-level program constant. A request for a port not declared
		## here, or for a declared port as another shape, is a contract error
		## naming the port and the site.
		with_ports : Program(st), List(PortDecl) -> Program(st)
		with_ports = |p, decls| { ..p, ports: ports_of(ports_checked(p.ports.decls.concat(decls))) }

		## Add worker tasks to the program's catalogue, so its effect sites can
		## issue `Work` requests for them. The page's instance and every worker
		## instance evaluate the same `main`, so both see the same catalogue. At
		## most 64 names may be registered (a preparation's and its tasks' each
		## count) and each name once; anything else is a contract error when the
		## catalogue is built.
		with_workers : Program(st), List(Registration) -> Program(st)
		with_workers = |p, registrations| {
			combined = p.workers.concat(registrations)
			match Core.catalogue(combined) {
				Ok(_) => { ..p, workers: combined }
				Err(message) => crash message
			}
		}
	}

	## For the platform's hosts and test harnesses: the entry points of a
	## [Program], as the page's host calls them. A worker instance's entries
	## are `work!`, `work_prepare!` and `work_ask!`. `settled` is the settle
	## check (`Core.settled`) and `live` the requests in flight
	## (`Core.fx_live`), which only harnesses call.
	driver : Program(st) -> { version : U32, keys : () -> List(U8), init : List(U8) -> (App(st), List(U8), List(U8)), event : App(st), List(U8), List(U8), U32, U32, List(U8) -> (App(st), List(U8), List(U8)), files : App(st), List(U8), List(U8), U32, U32, List(U8), List(Box(U64)) -> (App(st), List(U8), List(U8)), settled : App(st) -> Try({}, { cmds : List(U8), note : Str }), live : App(st) -> List(U32) }
	driver = |p| {
		init = p.init
		workers = p.workers
		ports = p.ports
		media = p.media
		keys = p.keys
		zone_days = p.zone_days
		session_keys = p.session_keys
		{
			version: p.version,
			keys: || put_section(put_section(put_media_table((ports.table)(keys(), ports.decls), media), 10, [zone_days.to_u8_wrap(), zone_days.shr_zf_wrap(8).to_u8_wrap()]), 11, session_keys.fold(put_u32([], session_keys.len().to_u32_wrap()), put_str)),
			init: |boot| finish(init({ workers: catalogue_names(workers), ports, media }, boot, PictureCapture.disabled), [], []),
			event: p.event,
			files: |inst, buf, wbuf, node, handler, record, blobs| {
				{ store, root, tx, programs } = inst
				{ cmds: _, next, free, routes, work, paths, site_free, observations, fx } = tx
				fresh = { store, root, tx: { cmds: buf.clear(), next, free, routes, work, paths, site_free, observations, fx }, programs }
				handles = blobs.map(|b| Blob.(b))
				if node == fx_node {
					# A result that carries files: a port's answer (result
					# tag 14), a job's answer (10) or a fetched body (21).
					res = match record {
						[10, ..] | [21, ..] => decode_held_res(record, handles)
						_ => (programs.ports.decode)(record, handles)
					}
					finish(Core.result(fresh, handler, res), [], wbuf)
				} else {
					finish(Core.event_files(fresh, node, handler, record, handles), [], wbuf)
				}
			},
			settled: Core.settled,
			live: Core.fx_live,
		}
	}

	## Native picture production mounts exactly once through the ordinary
	## initializer. Capture is moved out and disabled before App is returned;
	## neither the native runner nor the host inspects application storage.
	init_picture : Program(st), List(U8) -> { state : App(st), commands : List(U8), work : List(U8), capture : Try(List(PictureCapture.Frame), [NotCaptured, CaptureLimit, InvalidBoundary]) }
	init_picture = |program, boot| {
		capture = PictureCapture.start({ max_records: PictureCapture.max_records }) ?? crash "internal: picture capture protocol limit is valid"
		{ store, root, tx, programs } = (program.init)({ workers: catalogue_names(program.workers), ports: program.ports, media: program.media }, boot, capture)
		captured = PictureCapture.finish(tx.fx.batch.capture)
		cleared = with_fx(tx, |fx| with_capture(fx, |_finished| PictureCapture.disabled))
		(instance, commands, work) = finish({ store, root, tx: cleared, programs }, [], [])
		{ state: instance, commands, work, capture: captured }
	}

	## For the platform's hosts: a worker instance's job entry (design.md,
	## "Workers"). It runs the task named in `name:str input:rest` with the
	## handles the instance's host minted for the job's files, in the
	## request's order, and returns its answer, `n:u32 (token:u64)*
	## output:rest`: the instance's tokens of the files the answer holds,
	## then the answer's bytes. A name that is not a task registered in this
	## module, or the name of a preparation's task (those run through
	## `work_prepare!` and `work_ask!`), is a contract error that poisons this
	## worker instance only.
	work! : Program(st), JobEffects, List(U8), List(Box(U64)) => List(U8)
	work! = |p, effects, payload, handles| {
		registrations = p.workers
		_ = catalogue_names(registrations)
		(name, at) = get_str(payload, 0, "job payload")
		match registrations.find_first(|r| r.name == name) {
			Ok(r) if r.tasks.is_empty() => {
				run! = r.run!
				owned_bytes(run!(payload.drop_first(at), job_files(handles, effects)))
			}
			Ok(_) => crash "contract: worker task \"${name}\" is a preparation; ask one of its tasks"
			Err(_) =>
				if registrations.any(|r| r.tasks.contains(name)) {
					crash "contract: worker task \"${name}\" belongs to a preparation; its jobs run through the preparation"
				} else {
					crash "contract: worker task \"${name}\" is not registered in this module"
				}
		}
	}

	## For the platform's hosts: a worker instance's preparation entry
	## (design.md, "Prepared state"). It runs the preparation named in
	## `prep:str init:rest` on that input and the handles of the
	## preparation's files and returns the state the instance keeps. A name
	## that is not a preparation registered in this module is a contract
	## error that poisons this worker instance only.
	work_prepare! : Program(st), JobEffects, List(U8), List(Box(U64)) => Kept
	work_prepare! = |p, effects, payload, handles| {
		registrations = p.workers
		_ = catalogue_names(registrations)
		(prep, at) = get_str(payload, 0, "prepare payload")
		match registrations.find_first(|r| r.name == prep and !r.tasks.is_empty()) {
			Ok(r) => {
				prepare! = r.prepare!
				prepared = prepare!(payload.drop_first(at), job_files(handles, effects))
				ask! = prepared.ask!
				{ prep: prepared.prep, ask!: Box.box(|task, bytes, task_handles| ask!(task, bytes, job_files(task_handles, effects))) }
			}
			Err(_) => crash "contract: worker task \"${prep}\" is not a preparation registered in this module"
		}
	}

	## For the platform's hosts: a job of a preparation's task on the state an
	## instance keeps, `task:str input:rest` with the handles of the task's
	## own files, answering as `work!` does.
	work_ask! : Kept, List(U8), List(Box(U64)) => List(U8)
	work_ask! = |held, payload, handles| {
		(task, at) = get_str(payload, 0, "job payload")
		ask! = Box.unbox(held.ask!)
		owned_bytes(ask!(task, payload.drop_first(at), handles))
	}

	## For the worker layer: a job's answer as its entry returns it,
	## `n:u32 (token:u64)* output:rest`, from the answer's bytes and the
	## files it holds, in the order the bytes refer to them. Each must be a
	## handle the job holds. An answer may hold at most 16 files
	## (design.md, "Boundedness"); more is a contract error in the worker.
	task_answer : Str, List(U8), List(File) -> List(U8)
	task_answer = |name, bytes, files| {
		if files.len() > max_answer_files {
			crash "contract: worker task \"${name}\" answered with ${files.len().to_str()} files; an answer holds at most ${max_answer_files.to_str()}"
		}
		var $b = put_u32(List.with_capacity(4 + 8 * files.len() + bytes.len()), files.len().to_u32_wrap())
		for f in files {
			$b = put_u64($b, file_ref(f).token)
		}
		$b.concat(bytes)
	}

	## For test platforms and harnesses: the catalogue rule `with_workers`
	## enforces, as a value: the registered names in order, or the contract
	## diagnostic for a duplicate name or more than 64 registrations.
	catalogue : List(Registration) -> Try(List(Str), Str)
	catalogue = |registrations| {
		var $names = []
		for r in registrations {
			for name in [r.name].concat(r.tasks) {
				if $names.len() >= max_tasks {
					return Err("contract: with_workers registers more than ${max_tasks.to_str()} worker tasks (task \"${name}\" is over the bound)")
				}
				if $names.contains(name) {
					return Err("contract: worker task \"${name}\" is registered twice in with_workers")
				}
				$names = $names.append(name)
			}
		}
		Ok($names)
	}

	## Values read at boot are declared here; request catalogues are added
	## with `with_ports` or `with_workers`. Defaults let a caller name only
	## what differs, and let later boot declarations leave existing apps intact.
	## zone_days declares the zone probe span on each side of mount (default
	## 366, at most 7305); zero requests only the offset at mount.
	ProgramProps := { storage_keys : List(Str) ?? [], max_inflight : U64 ?? 32, media : List(Str) ?? [], zone_days : U16 ?? 366, session_keys : List(Str) ?? [] }

	## The [Program] for an app that needs no boot data: mount `view()` with the
	## default in-flight bound of 32.
	program : (() -> Elem(Root({}))) -> Program({})
	program = |view| Core.program_boot({}, |_| view())

	## The [Program] for an app that reads boot data: the host reads
	## `storage_keys` from local storage before mount, and `view` receives them in
	## the [Boot] with the URL and connectivity. `max_inflight` bounds the awaited
	## requests in flight at once.
	program_boot : ProgramProps, (Boot -> Elem(Root({}))) -> Program({})
	program_boot = |cfg, view| Core.program_store(cfg, |_| Core.no_store, view)

	## The [Program] for an app with a root store: `start` gives what
	## the store starts with at mount (`Store.initial`), from the boot data,
	## and `view` the UI over it.
	program_store : ProgramProps, (Boot -> Start(st)), (Boot -> Elem(Root(st))) -> Program(st)
	program_store = |cfg, start, view| {
		if cfg.zone_days > 7305 {
			crash "contract: ProgramProps.zone_days must be at most 7305"
		}
		media = match Core.media_catalogue(cfg.media) {
			Ok(queries) => queries
			Err(message) => crash message
		}
		{
			version: Core.protocol_version,
			keys: || {
				declarations = [
					{
						tag: 2.U8,
						write: || {
							var $body = put_u32([], cfg.storage_keys.len().to_u32_wrap())
							for key in cfg.storage_keys {
								$body = put_str($body, key)
							}
							$body
						},
					},
				]
				declarations.fold([], |bytes, section| put_section(bytes, section.tag, (section.write)()))
			},
			init: |names, boot, capture| {
				mounted = match Core.read_mount(boot, names.media) {
					Ok(value) => value
					Err(message) => crash message
				}
				b = mounted.boot
				match check_boot_keys(b, cfg.storage_keys) {
					Ok(_) => {}
					Err(message) => crash message
				}
				for (key, _) in b.session {
					if !cfg.session_keys.contains(key) {
						crash "contract: boot section 11 (session-storage) pair for undeclared key \"${key}\""
					}
				}
				mount_start_captured({ max: cfg.max_inflight, programs: names, start: start(b), elem: view(b), enclosing: enclosing_root(mounted.root), capture })
			},
			event: |inst, buf, wbuf, node, handler, payload| {
				{ store, root, tx, programs } = inst
				{ cmds: _, next, free, routes, work, paths, site_free, observations, fx } = tx
				fresh = { store, root, tx: { cmds: buf.clear(), next, free, routes, work, paths, site_free, observations, fx }, programs }
				if node == fx_node {
					finish(if (payload.first() == Ok(26)) Core.progress(fresh, handler, decode_progress(payload)) else Core.result(fresh, handler, decode_res_with(payload, programs.ports.decode)), [], wbuf)
				} else {
					finish(deliver(fresh, node, handler, Ev(payload)), [], wbuf)
				}
			},
			workers: [],
			ports: no_ports,
			media,
			zone_days: cfg.zone_days,
			session_keys: cfg.session_keys,
		}
	}
}

# ------------------------------------------------------------------
# Core internals. Nothing below is visible outside this module.
#
# Command stream (little endian, u32 ids, strings are u32 length + bytes):
#   1 INST     node parent before tpl  then per template hole: text/attr/prop: str,
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

## A row-selection dependency: a structural alias, so the public `Signal` may
## carry it without exposing a private nominal type.
Sel(ctx) : [NoSel, Sel(U128, (ctx -> Str))]

sel_mask : Sel(ctx) -> U128
sel_mask = |sel| match sel {
	NoSel => 0
	Sel(m, _) => m
}

## Mask a plain block must watch for a value: its layers and its selector's.
eff_mask : Signal(ctx, a) -> U128
eff_mask = |v| v.mask.bitwise_or(sel_mask(v.sel))

## `sole`: the site is the only child of `parent` and sits at its end.
## `cap` != 0: a known superset of what the site can read; the site may
## report it instead of computing its reads (set inside each rows).
Args : { depth : U64, path : List(U32), parent : U32, before : U32, sole : Bool, cap : U128, enclosing : Enclosing }

## Actual parent identity and the raw constructor's child namespace travel
## through sites, never recovered by walking the engine tree or the DOM.
Enclosing : { namespace : Web.Namespace, prefix : Web.Prefix, local : Str, raw_namespace : Web.Namespace, construction : ParsedHtml.Construction.Context }

Scope : { cap : U128, enclosing : Enclosing }

root_enclosing : Enclosing
root_enclosing = enclosing_root({ namespace: Html, prefix: Unprefixed, local: "div" })

Mount(ctx) := [Mount((ctx, Args, Tx -> (Inst(ctx), U128, Tx)))]

## What travels down a site path: what fires a handler (a DOM event's
## text, the files a files-kind event carries and how many were refused, or
## an effect result), or `Settle`, which fires nothing. A `Settle` follows
## the pass of an event's outermost write down the event's path, and names
## the written layers below it (`waits_for_outer`). Each of them joined that
## pass if the pass reached its site; the walk refreshes, at its own site,
## each one the pass did not reach, and stops at the deepest of them.
Payload : [Ev(List(U8)), Files(List(U8), List(Core.Blob)), Fx(EffectInput), Settle(Layers, Bool), OpenState(Bool)]

## Whether a payload is a `Settle` walk, and if so whether it names a
## layer below index `depth`, so that it goes on past the state site there.
settle_walk : Payload, U64 -> Try([Further, Ends], [Fires])
settle_walk = |payload, depth| match payload {
	Settle(left, forced) => if (!forced and layers_empty(layers_from(left, depth + 1))) Ok(Ends) else Ok(Further)
	_ => Err(Fires)
}

## Whether a payload fires handlers: a `Settle` does not.
fires : Payload -> Bool
fires = |payload| match payload {
	Settle(_, _) => False
	_ => True
}

## A handler in a mounted block has already fixed its payload kind. It
## decodes once at this boundary and then calls its typed handler.
RoutedHandler(ctx) : { run : (ctx, Payload, List(U32) -> (ctx, Layers)), echo : [NoEcho, Echo({ property : U8, hole : U64, showing : Str })] }

EventDecl : { event : Str, kind : U8, policies : U32 }

## Live shown state is a strict flag, decoded once at its routed site.
attach_open : U8, Str, Core.HandlerOf(ctx, Bool) -> Core.Attr(ctx)
attach_open = |property, showing, { run }| On(
	{ event: if (property == 6) "close" else "toggle", kind: 5, policies: 0 },
	{ run: |env, payload, site| run(env, (open_kind.decode)(payload, site), site), echo: Echo({ property, hole: 0, showing }) },
)

open_kind : Core.Kind(Bool)
open_kind = {
	code: 5,
	decode: |payload, site| match payload {
		OpenState(open) => open
		Ev([0]) => False
		Ev([1]) => True
		_ => crash "contract: event payload does not match open-state kind at site ${show_path(site)}"
	},
}

## Text events decode strictly as UTF-8 at their routed construction site.
text_kind : Core.Kind(Str)
text_kind = {
	code: 1,
	decode: |payload, site| match payload {
		Ev(bytes) => Str.from_utf8(bytes) ?? crash "contract: text event payload is not UTF-8 at site ${show_path(site)}"
		_ => crash "contract: event payload does not match text kind at site ${show_path(site)}"
	},
}

## Files stay handles until the typed handler consumes them; a stale route
## drops the staged handles without decoding.
files_kind : Core.Kind(Core.Received)
files_kind = {
	code: 2,
	decode: |payload, site| match payload {
		Files(record, blobs) => {
			(files, refused) = decode_files(record, blobs, site)
			{ files, refused }
		}
		_ => crash "contract: event payload does not match files kind at site ${show_path(site)}"
	},
}

## Layout reports carry only their fixed record, with no staging or handles.
scroll_kind : Core.Kind(Layout.Scroll)
scroll_kind = {
	code: 6,
	decode: |payload, site| {
		pair = match payload {
			Ev(bytes) => read_layout_pair(bytes) ?? crash "contract: event payload does not match scroll kind at site ${show_path(site)}"
			_ => crash "contract: event payload does not match scroll kind at site ${show_path(site)}"
		}
		{ top: pair.first, left: pair.second }
	},
}

size_kind : Core.Kind(Layout.Size)
size_kind = {
	code: 7,
	decode: |payload, site| {
		pair = match payload {
			Ev(bytes) => read_layout_pair(bytes) ?? crash "contract: event payload does not match size kind at site ${show_path(site)}"
			_ => crash "contract: event payload does not match size kind at site ${show_path(site)}"
		}
		{ width: pair.first, height: pair.second }
	},
}

seen_kind : Core.Kind(Layout.Seen)
seen_kind = {
	code: 8,
	decode: |payload, site| match payload {
		Ev(bytes) => read_seen(bytes) ?? crash "contract: event payload does not match seen kind at site ${show_path(site)}"
		_ => crash "contract: event payload does not match seen kind at site ${show_path(site)}"
	},
}

## Two little-endian U32 fields, consumed exactly, never truncated or wrapped.
read_layout_pair : List(U8) -> Try({ first : U32, second : U32 }, [InvalidLayout])
read_layout_pair = |bytes| if bytes.len() != 8 {
	Err(InvalidLayout)
} else {
	Ok({ first: get_u32(bytes, 0, "layout report"), second: get_u32(bytes, 4, "layout report") })
}

## Intersection accepts a strict flag and a ratio in thousandths.
read_seen : List(U8) -> Try(Layout.Seen, [InvalidSeen])
read_seen = |bytes| match bytes {
	[flag, low, high] if flag <= 1 => {
		ratio = low.to_u16() + high.to_u16().shl_wrap(8)
		if ratio > 1000 {
			Err(InvalidSeen)
		} else {
			Ok({ intersecting: flag == 1, ratio_permille: ratio })
		}
	}
	_ => Err(InvalidSeen)
}

## The event tag fixes which browser event can carry this typed record.
pointer_event : [Down, Move, Up, Cancel] -> Str
pointer_event = |event| match event {
	Down => "pointerdown"
	Move => "pointermove"
	Up => "pointerup"
	Cancel => "pointercancel"
}

## One pointer decoder is selected at declaration. Cancel additionally rules
## out a hit-tested location, which the browser cannot report for cancellation.
pointer_kind : [Down, Move, Up, Cancel] -> Core.Kind(Core.Pointer)
pointer_kind = |event| {
	code: 3,
	decode: |payload, site| {
		pointer = match payload {
			Ev(bytes) => read_pointer(bytes) ?? crash "contract: event payload does not match pointer kind at site ${show_path(site)}"
			_ => crash "contract: event payload does not match pointer kind at site ${show_path(site)}"
		}
		if event == Cancel and pointer.at != Outside {
			crash "contract: pointercancel payload must be outside at site ${show_path(site)}"
		}
		pointer
	},
}

## The map and handler lower together into a private property and listener.
attach_key : Core.Signal(ctx, Core.Keymap), [Down, Up], Bool, Bool, Core.HandlerOf(ctx, Core.Key) -> Core.Attr(ctx)
attach_key = |map, phase, stop, document, handler| {
	{ run } = handler
	KeyOn({ event: if (phase == Down) "keydown" else "keyup", kind: 4, policies: (if (stop) 2.U32 else 0).bitwise_or(if (document) 16 else 0) }, { run: |env, payload, site| run(env, (key_kind.decode)(payload, site), site), echo: NoEcho }, map.map(encode_keymap))
}

## Serialize only through the internal attach path; apps cannot inspect this encoding.
encode_keymap : Core.Keymap -> Str
encode_keymap = |{ entries, every }| {
	pieces = entries.map(
		|{ chord, prevent, outside }| {
			{ key, ctrl, alt, shift, meta } = chord
			"${if (prevent) "p" else "k"}${if (outside) "o" else "a"}${if (ctrl) "C" else "-"}${if (alt) "A" else "-"}${if (shift) "S" else "-"}${if (meta) "M" else "-"}${key.count_utf8_bytes().to_str()}:${key}"
		},
	)
	"${Str.join_with(pieces, "")}${
		match every {
			NoEvery => ""
			Every(outside) => if (outside) "o*" else "a*"
		}
	}"
}

key_kind : Core.Kind(Core.Key)
key_kind = {
	code: 4,
	decode: |payload, site| match payload {
		Ev(bytes) => read_key(bytes) ?? crash "contract: event payload does not match key kind at site ${show_path(site)}"
		_ => crash "contract: event payload does not match key kind at site ${show_path(site)}"
	},
}

## Validate all flags, UTF-8 fields and the exact end before exposing a key.
read_key : List(U8) -> Try(Core.Key, [InvalidKey])
read_key = |bytes| {
	flags = bytes.first() ? |_| InvalidKey
	if flags.bitwise_and(192) != 0 {
		return Err(InvalidKey)
	}
	(key, next) = boot_str(bytes, 1) ? |_| InvalidKey
	if key.is_empty() {
		return Err(InvalidKey)
	}
	(code, after) = boot_str(bytes, next) ? |_| InvalidKey
	heard = bytes.get(after) ? |_| InvalidKey
	if heard.bitwise_and(240) != 0 {
		return Err(InvalidKey)
	}
	(heard_key, end) = boot_str(bytes, after + 1) ? |_| InvalidKey
	if heard_key.is_empty() or end != bytes.len() {
		return Err(InvalidKey)
	}
	Ok({ key, code, ctrl: flags.bitwise_and(1) != 0, alt: flags.bitwise_and(2) != 0, shift: flags.bitwise_and(4) != 0, meta: flags.bitwise_and(8) != 0, repeat: flags.bitwise_and(16) != 0, composing: flags.bitwise_and(32) != 0, heard: Core.Chord.{ key: heard_key, ctrl: heard.bitwise_and(1) != 0, alt: heard.bitwise_and(2) != 0, shift: heard.bitwise_and(4) != 0, meta: heard.bitwise_and(8) != 0 } })
}

## Validate a bounded pointer record before a handler observes any field.
## Browser geometry is rounded before encoding; the decoder never clamps it.
read_pointer : List(U8) -> Try(Core.Pointer, [InvalidPointer])
read_pointer = |bytes| match bytes {
	[a, b, c, d, kind_byte, button_byte, buttons_low, buttons_high, mods, primary_byte, at_byte, .. as rest] => {
		id = a.to_u32() + b.to_u32().shl_wrap(8) + c.to_u32().shl_wrap(16) + d.to_u32().shl_wrap(24)
		kind = match kind_byte {
			0 => Mouse
			1 => Pen
			2 => Touch
			3 => Other
			_ => return Err(InvalidPointer)
		}
		button = match button_byte {
			0 => None
			1 => Main
			2 => Middle
			3 => Secondary
			4 => Back
			5 => Forward
			encoded => Other(encoded - 1)
		}
		if mods > 15 or primary_byte > 1 {
			return Err(InvalidPointer)
		}
		at = match (at_byte, rest) {
			(0, []) => Outside
			(1, [x_low, x_high, y_low, y_high, .. as text]) => {
				x = x_low.to_u16() + x_high.to_u16().shl_wrap(8)
				y = y_low.to_u16() + y_high.to_u16().shl_wrap(8)
				if x > 10000 or y > 10000 {
					return Err(InvalidPointer)
				}
				(zone, end) = boot_str(text, 0) ? |_| InvalidPointer
				if zone.is_empty() or end != text.len() {
					return Err(InvalidPointer)
				}
				In({ zone, x, y })
			}
			_ => return Err(InvalidPointer)
		}
		Ok({
			id,
			kind,
			button,
			buttons: buttons_low.to_u16() + buttons_high.to_u16().shl_wrap(8),
			modifiers: { shift: mods.bitwise_and(1) != 0, ctrl: mods.bitwise_and(2) != 0, alt: mods.bitwise_and(4) != 0, meta: mods.bitwise_and(8) != 0 },
			primary: primary_byte == 1,
			at,
		})
	}
	_ => Err(InvalidPointer)
}

policy_bits : Core.Policy -> U32
policy_bits = |{ prevent, stop }| (if (prevent) 1.U32 else 0).bitwise_or(if (stop) 2 else 0)

attach_kind : Str, Core.Kind(p), U32, Core.HandlerOf(ctx, p) -> Attr(ctx)
attach_kind = |event, { code, decode }, policies, { run }| On(
	{ event, kind: code, policies },
	{ run: |env, payload, site| run(env, decode(payload, site), site), echo: NoEcho },
)

Msg := [Fire(List(U32), U64, U32, Payload), Changed(U128), Dispose(Bool)]

## Fire always hands the (possibly transformed) environment back up with
## the exact set of layers it wrote that no site below has settled yet
## (`no_layers` when nothing was written).
Out(ctx) := [Done, Pending(ctx, Layers), Orphaned(List(Orphan(ctx)))]

## An admitted request whose issuing site was disposed (design.md,
## "Disposal and reparenting"): it survives and reparents to the
## nearest surviving ancestor site. `run` applies its reaction in that
## ancestor's current environment: writes to states that were retired
## with the disposed scope land in a snapshot that is discarded (the third
## part of its answer counts them), writes to surviving states commit, and
## the write set names only surviving layers.
Orphan(ctx) : { id : U32, run : (ctx, EffectInput -> (ctx, Layers, U64)) }

orphans_of : Out(ctx) -> List(Orphan(ctx))
orphans_of = |out| match out {
	Orphaned(l) => l
	_ => []
}

Inst(ctx) := [Inst((ctx, Msg, Tx -> (Inst(ctx), Out(ctx), Tx)))]

## A node's route: a static node's block path, or a row element's site
## and slot (resolved through the site's current path).
Route := [NoRoute, Route(List(U32), U32), RowOf(U32, U32)]

## Changed shown addresses are consumed only by rows on the active call path.
ShownChange : [SetShown({ node : U32, hole : U16, property : U8, value : Str }), DropShown(U32)]

Tx : {
	cmds : List(U8),
	next : U32,
	free : List(U32),
	routes : List(Route),
	work : Work,
	paths : List(List(U32)),
	site_free : List(U32),
	observations : { echo : Bool, shown : List(ShownChange) },
	fx : Fx,
}

## Work counters (design.md, "Work assertions"): one `Work` record in the
## turn accumulator, cumulative over the instance. Indices 1-18
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
fx_counters : App(st) -> List(U64)
fx_counters = |a| {
	fx = a.tx.fx
	[fx.issued, fx.delivered, fx.stale, fx.refused, fx.cancelled, fx.reparented, fx.skipped, fx.live.len()]
}

## Port commands sent (`PORT`, opcode 19). Counted here, at index 40 of the
## work record, never by opcode: index 19 is `set_value`.
w_port_sends : U64
w_port_sends = 40

## The number of counters in the work record: the work counters, the eight
## effect counters, port commands (40), property commands (41–42), and
## released registrations (43), live observations (44), marked batches (45),
## guard commands (46) and accepted transfer progress turns (47).
w_record_count : U64
w_record_count = w_count + 17

## The work counters as plain fields (`c01` is counter 1): bumping one
## updates a value in the accumulator and never allocates, so counting
## cannot cost an allocation or a copy on any path.
Work : { c01 : U64, c02 : U64, c03 : U64, c04 : U64, c05 : U64, c06 : U64, c07 : U64, c08 : U64, c09 : U64, c10 : U64, c11 : U64, c12 : U64, c13 : U64, c14 : U64, c15 : U64, c16 : U64, c17 : U64, c18 : U64, c19 : U64, c20 : U64, c21 : U64, c22 : U64, c23 : U64, c24 : U64, c25 : U64, c26 : U64, c27 : U64, c28 : U64, c29 : U64, c30 : U64, c31 : U64, c40 : U64, c41 : U64, c42 : U64, c43 : U64, c45 : U64, c46 : U64, c47 : U64, c48 : U64 }

work_zero : Work
work_zero = { c01: 0, c02: 0, c03: 0, c04: 0, c05: 0, c06: 0, c07: 0, c08: 0, c09: 0, c10: 0, c11: 0, c12: 0, c13: 0, c14: 0, c15: 0, c16: 0, c17: 0, c18: 0, c19: 0, c20: 0, c21: 0, c22: 0, c23: 0, c24: 0, c25: 0, c26: 0, c27: 0, c28: 0, c29: 0, c30: 0, c31: 0, c40: 0, c41: 0, c42: 0, c43: 0, c45: 0, c46: 0, c47: 0, c48: 0 }

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
	40 => { ..w, c40: w.c40 + n }
	41 => { ..w, c41: w.c41 + n }
	42 => { ..w, c42: w.c42 + n }
	43 => { ..w, c43: w.c43 + n }
	45 => { ..w, c45: w.c45 + n }
	46 => { ..w, c46: w.c46 + n }
	47 => { ..w, c47: w.c47 + n }
	48 => { ..w, c48: w.c48 + n }
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
	40 => w.c40
	41 => w.c41
	42 => w.c42
	43 => w.c43
	45 => w.c45
	46 => w.c46
	47 => w.c47
	48 => w.c48
	_ => 0
}

Hole(ctx) : { node : U32, mask : U128, attr : [NoAttribute, Attribute(Web.AttrName)], reference : [NotReference, Reference(List(U32), Bool)], property : U8, read : (ctx -> [Absent, Present(Str)]), last : [Absent, Present(Str)], dirty : Bool }

Block(ctx) : {
	holes : List(Hole(ctx)),
	handlers : List(RoutedHandler(ctx)),
	children : List(Inst(ctx)),
	child_reads : List(U128),
	child_top : List(Bool),
	nodes : List(U32),
	tops : List(U32),
	reads : U128,
}

## ------------------------------------------------------------------
## Attribute holes share the ordinary hole observation cache. Non-attribute
## readers always produce `Present`; absence has meaning only for attributes.
observed_text : [Absent, Present(Str)] -> Str
observed_text = |observation| match observation {
	Present(text) => text
	Absent => crash "internal: absence in a non-attribute hole"
}

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

## Presence is explicit on the wire, so empty text never encodes removal.
put_presence : List(U8), [Absent, Present(Str)] -> List(U8)
put_presence = |bytes, presence| match presence {
	Absent => bytes.append(0)
	Present(text) => put_str(bytes.append(1), text)
}

## Append one command: its opcode, then the operands `write` adds. The
## opcode is counted in the work counters; property commands use the
## dedicated PROP and HPROP slots (design.md, "Work assertions").
emit_op : Tx, U8, (List(U8) -> List(U8)) -> Tx
emit_op = |{ cmds, next, free, routes, work, paths, site_free, observations, fx }, op, write| {
	at = cmds.len()
	written = write(cmds.append(op))
	{ cmds: written, next, free, routes, work: add_work(work, if (op == 21) 41 else if (op == 22) 42 else if (op == 23) 43 else if (op == 25) 46 else if (op == 26) 48 else op.to_u64(), 1), paths, site_free, observations, fx: capture_command(fx, { bytes: written, at, opcode: op }) }
}

## Only fixed-prefix command addresses are read here. Effects' payloads are
## never decoded by capture, and no command or app state is interpreted by a host.
capture_command : Fx, { bytes : List(U8), at : U64, opcode : U8 } -> Fx
capture_command = |fx, emitted| with_capture(
	fx,
	|capture| {
		if !PictureCapture.is_collecting(capture) {
			return capture
		}
		address = match emitted.opcode {
			1 | 2 | 3 | 4 | 5 | 6 | 8 | 9 | 10 | 11 | 12 | 21 | 22 | 23 | 26 => get_u32(emitted.bytes, emitted.at + 1, "captured command address")
			18 => get_u32(emitted.bytes, emitted.at + 2, "captured reference address")
			_ => 0
		}
		slot = match emitted.opcode {
			1 => get_u32(emitted.bytes, emitted.at + 13, "captured row site")
			6 => get_u32(emitted.bytes, emitted.at + 5, "captured clear site")
			7 => get_u32(emitted.bytes, emitted.at + 1, "captured template site")
			_ => 0
		}
		PictureCapture.command(capture, { at: emitted.at, end: emitted.bytes.len(), opcode: emitted.opcode, address, slot })
	},
)

## Add `n` to work counter `i`.
bump : Tx, U64, U64 -> Tx
bump = |{ cmds, next, free, routes, work, paths, site_free, observations, fx }, i, n| { cmds, next, free, routes, work: add_work(work, i, n), paths, site_free, observations, fx }

## One evaluation of an app closure (a hole, a condition, a list read, a
## `derive` input, a prop read, an effect site's watched value).
count_evals : Tx, U64 -> Tx
count_evals = |tx, n| bump(tx, w_evals, n)

## A property's allowed elements, claimed attribute and work counter live
## beside its index. A later row extends this table, never attribute parsing.
property_row : U8 -> { name : Str, elements : List(Str), counter : U64 }
property_row = |index| match index {
	1 => { name: "value", elements: ["input", "textarea", "select", "option"], counter: w_set_value }
	2 => { name: "checked", elements: ["input"], counter: w_set_checked }
	3 => { name: "pointer_zone", elements: [], counter: 0 }
	4 => { name: "keymap_down", elements: [], counter: 0 }
	5 => { name: "keymap_up", elements: [], counter: 0 }
	6 => { name: "shown", elements: ["dialog"], counter: 0 }
	7 => { name: "popover_shown", elements: [], counter: 0 }
	_ => crash "internal: unknown property row ${index.to_str()}"
}

## Only control properties have a dedicated counter; every property command
## is counted once by its opcode independently of this optional measure.
count_property : Tx, U8 -> Tx
count_property = |tx, index| {
	counter = property_row(index).counter
	if (counter == 0) tx else bump(tx, counter, 1)
}

## Allocate a static node id, reusing a freed one first.
alloc_id : Tx -> (U32, Tx)
alloc_id = |{ cmds, next, free, routes, work, paths, site_free, observations, fx }| {
	match free.last() {
		Ok(id) => (id, { cmds, next, free: free.drop_last(1), routes, work, paths, site_free, observations, fx })
		Err(_) => {
			if next >= 4294967294 {
				crash "resource_limit: node ids exhausted (4294967294 live nodes)"
			}
			(next, { cmds, next: next + 1, free, routes, work, paths, site_free, observations, fx })
		}
	}
}

## A command address owns its registrations. The owner is the element's id
## in a block, or the row root for a static template observation.
observe_node : Tx, U32 -> Tx
observe_node = |tx, owner| with_fx(
	tx,
	|fx| with_registrations(
		fx,
		|documents, { owners, live }| {
			count = owners.get(owner) ?? 0
			(documents, { owners: owners.insert(owner, count + 1), live: live + 1 })
		},
	),
)

## Release only this owner's registrations before any ancestor is detached.
## The direct count index keeps disposal proportional to its own scope.
release_node : Tx, U32 -> Tx
release_node = |tx, owner| {
	count = tx.fx.observed.owners.get(owner) ?? 0
	document = tx.fx.document_nodes.contains(owner)
	if count == 0 and !document {
		return tx
	}
	with_fx(
		emit_op(tx, 23, |commands| put_u32(commands, owner)),
		|fx| with_registrations(
			fx,
			|documents, { owners, live }| (
				if (document) documents.keep_if(|node| node != owner) else documents,
				{ owners: owners.remove(owner), live: live - count },
			),
		),
	)
}

## Move the registration index out before modifying it, leaving no second
## holder in Fx that would make each observed-node change copy the index.
with_registrations : Fx, (List(U32), LiveObservations -> (List(U32), LiveObservations)) -> Fx
with_registrations = |{ next, inner, live, queue, max, issued, delivered, stale, refused, cancelled, reparented, skipped, document_nodes, observed, refs, focus, ref_pos, cleanups, guard, batch }, change| {
	(documents, observations) = change(document_nodes, observed)
	{ next, inner, live, queue, max, issued, delivered, stale, refused, cancelled, reparented, skipped, document_nodes: documents, observed: observations, refs, focus, ref_pos, cleanups, guard, batch }
}

## Release a static node id and its route.
free_id : Tx, U32 -> Tx
free_id = |{ cmds, next, free, routes, work, paths, site_free, observations, fx }, id| {
	routes2 = if (id.to_u64() < routes.len()) routes.set(id.to_u64(), NoRoute) ?? routes else routes
	fx2 = if ((fx.ref_pos.get(id.to_u64()) ?? []).is_empty()) fx else drop_ref(fx, id)
	{ cmds, next, free: free.append(id), routes: routes2, work, paths, site_free, observations: { ..observations, shown: observations.shown.append(DropShown(id)) }, fx: fx2 }
}

## Register a name with its node and construction site. The end-of-turn
## check permits a departing and an entering element to share a name while
## reconciliation is in progress. Empty names never enter either index.
add_ref : Fx, { name : Str, node : U32, path : List(U32), value_control : Bool } -> Fx
add_ref = |fx, { name, node, path, value_control }| if (name.is_empty()) fx else with_refs(
	fx,
	|refs, ref_pos, focus| {
		var $positions = ref_pos
		while $positions.len() <= node.to_u64() {
			$positions = $positions.append([])
		}
		live = refs.get(name) ?? []
		(refs.insert(name, live.append({ node, path, value_control })), $positions.set(node.to_u64(), ($positions.get(node.to_u64()) ?? []).append({ name, path })) ?? crash "internal: reference index", focus.append(CheckRef(name)))
	},
)

## Remove only this node's claim to its name. The reverse index makes node
## disposal one lookup; in a valid program the name's live list has one node.
drop_ref : Fx, U32 -> Fx
drop_ref = |fx, node| with_refs(
	fx,
	|refs, ref_pos, focus| {
		names = ref_pos.get(node.to_u64()) ?? []
		remaining = names.fold(
			refs,
			|index, owned| {
				live = (index.get(owned.name) ?? []).keep_if(|claim| claim.node != node)
				if (live.is_empty()) index.remove(owned.name) else index.insert(owned.name, live)
			},
		)
		(remaining, if (names.is_empty()) ref_pos else ref_pos.set(node.to_u64(), []) ?? crash "internal: reference index", focus)
	},
)

## A rename releases just this hole's previous name. Other references on
## the same element keep their addresses until they change or it is disposed.
drop_name : Fx, { node : U32, name : Str, path : List(U32) } -> Fx
drop_name = |fx, { node, name, path }| if (name.is_empty()) fx else with_refs(
	fx,
	|refs, ref_pos, focus| {
		live = (refs.get(name) ?? []).keep_if(|claim| claim.node != node or claim.path != path)
		names = (ref_pos.get(node.to_u64()) ?? []).keep_if(|prior| prior.path != path)
		(if (live.is_empty()) refs.remove(name) else refs.insert(name, live), ref_pos.set(node.to_u64(), names) ?? crash "internal: reference index", focus)
	},
)

## Move the reference indexes and pending checks out of the accumulator so
## updates retain one holder for each map, list and reverse-index column.
with_refs : Fx, (RefMap, List(List(RefOwned)), List(TurnEnd) -> (RefMap, List(List(RefOwned)), List(TurnEnd))) -> Fx
with_refs = |{ next, inner, live, queue, max, issued, delivered, stale, refused, cancelled, reparented, skipped, document_nodes, observed, refs, focus, ref_pos, cleanups, guard, batch }, change| {
	(names, positions, checks) = change(refs, ref_pos, focus)
	{ next, inner, live, queue, max, issued, delivered, stale, refused, cancelled, reparented, skipped, document_nodes, observed, refs: names, focus: checks, ref_pos: positions, cleanups, guard, batch }
}

set_route : Tx, U32, List(U32), U32 -> Tx
set_route = |{ cmds, next, free, routes, work, paths, site_free, observations, fx }, id, path, handler| {
	var $r = routes
	while $r.len() <= id.to_u64() {
		$r = $r.append(NoRoute)
	}
	{ cmds, next, free, routes: $r.set(id.to_u64(), Route(path, handler)) ?? $r, work, paths, site_free, observations, fx }
}

set_row_route : Tx, U32, U32, U32 -> Tx
set_row_route = |{ cmds, next, free, routes, work, paths, site_free, observations, fx }, id, site, slot| {
	var $r = routes
	while $r.len() <= id.to_u64() {
		$r = $r.append(NoRoute)
	}
	{ cmds, next, free, routes: $r.set(id.to_u64(), RowOf(site, slot)) ?? $r, work, paths, site_free, observations, fx }
}

## Allocate an each-site id (template id).
alloc_site : Tx, List(U32) -> (U32, Tx)
alloc_site = |{ cmds, next, free, routes, work, paths, site_free, observations, fx }, path| {
	match site_free.last() {
		Ok(s) => (s, { cmds, next, free, routes, work, paths: paths.set(s.to_u64(), path) ?? crash "site", site_free: site_free.drop_last(1), observations, fx })
		Err(_) => {
			s = paths.len().to_u32_wrap()
			(s, { cmds, next, free, routes, work, paths: paths.append(path), site_free, observations, fx })
		}
	}
}

free_site : Tx, U32 -> Tx
free_site = |{ cmds, next, free, routes, work, paths, site_free, observations, fx }, s| {
	{ cmds, next, free, routes, work, paths: paths.set(s.to_u64(), []) ?? paths, site_free: site_free.append(s), observations, fx }
}

## ------------------------------------------------------------------
## Layers: read signatures and exact write sets.
##
## A layer is named by its index on the path from the root: a `state`,
## `derive`, `resource` or `each` row below a layer at index `d` takes
## index `d + 1`. Indices grow without bound: nesting is limited only by
## memory.
##
## Two representations meet. A *read signature* (`Signal.mask`, a hole's
## mask, a block's reads, the mask of a `Changed` pass) is 128 bits. Its
## low 64 bits are the layers': index `i` at bit `i % 64`. It can only
## over-approximate: two layers on one path share a bit only when their
## indices differ by a multiple of 64, and a shared bit costs an evaluation
## that equality pruning then discards; a reader of a changed layer is never
## skipped. While every index on every path is below 64 the low word has
## one bit for each layer.
##
## Its high 64 bits are the root store's cells': cell `c` at bit
## `64 + c % 64` (`cell_bit`). A cell is not a layer on any path: it has no
## depth, every scope reaches it, and it never shares a bit with a layer,
## so a store of any size leaves the layers' precision as it was. Cells
## 64 apart in the store share a bit, at the cost of a pruned evaluation.
##
## A *write set* ([Layers]) names the layers and the cells an event wrote
## exactly. Every decision that must be exact reads it: which site settles
## a written layer, what a site hands up, what an orphan's write may still
## touch, which tables' turns end. A refresh pass is then driven by the
## signature of what a site settles, and costs one 128-bit test per hole.

## The read-signature bit of layer index `index`.
bit : U64 -> U128
bit = |index| (1.U128).shl_wrap(index.bitwise_and(63).to_u8_wrap())

## The bit of layer index `index` in its word of a write set ([Layers]).
wbit : U64 -> U64
wbit = |index| (1.U64).shl_wrap(index.bitwise_and(63).to_u8_wrap())

## The read-signature bit of store cell `cell` (see above).
cell_bit : U64 -> U128
cell_bit = |cell| (1.U128).shl_wrap(64 + cell.bitwise_and(63).to_u8_wrap())

## Every store cell's signature bit.
all_cells : U128
all_cells = 0xFFFF_FFFF_FFFF_FFFF_0000_0000_0000_0000

## Every layer's signature bit, and no cell's.
all_layer_bits : U128
all_layer_bits = 0xFFFF_FFFF_FFFF_FFFF

## The index of a new layer below the layer at `depth`.
layer : U64 -> U64
layer = |depth| depth + 1

## The bit of layer index `index` that a site may strip from the reads it
## reports above it, or 0. A site strips its own layer's bit because no
## pass from above carries it, but a bit is shared by every index congruent
## modulo 64: stripping it would also hide a read of an ancestor that
## shares it, and the parent would not descend when that ancestor changes.
## Below index 64 no layer above can share it; from 64 on the site keeps
## it and pays an extra visit, pruned by equality, when the other layer
## changes.
own_bit : U64 -> U128
own_bit = |index| if (index < 64) bit(index) else 0

## The signature bits of every layer strictly above index `index` on a
## path, for a site that keeps only those (an `each` site, of its rows'
## reads): exact below 64, every bit from 64 on (any bit may then belong to
## an ancestor). A store cell is above every layer.
above_bits : U64 -> U128
above_bits = |index| if (index < 64) (bit(index) - 1).bitwise_or(all_cells) else every_layer

## Every layer and every cell at once: the mask of the settle check
## (`Core.settled`). A `Changed` with it re-evaluates every hole and
## descends into every child whatever its read mask, and a site that
## settles layers of its own (the rows of an `each`) passes it inward
## whole instead of translating it. A turn's own signature can equal
## it only when one turn wrote 64 layers whose indices differ modulo 64 and
## 64 cells; the pass then does what it would do for this mask, a superset
## of the work the turn needs, pruned like any other.
every_layer : U128
every_layer = 0xFFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF

## The signature bits of every index from 0 to `depth`, both included
## (every layer bit once `depth` reaches 63).
upto : U64 -> U128
upto = |depth| if (depth >= 63) all_layer_bits else bit(depth).shl_wrap(1) - 1

## An exact set of layer indices and of store cells: what an event wrote.
## Layer index `i` is bit `i % 64` of `lo` when `i < 64`, else of
## `hi[i / 64 - 1]`; store cell `c` is bit `c % 64` of `cells` when
## `c < 64`, else of `more[c / 64 - 1]`. Neither list has a trailing zero
## word, so a set whose layers and cells are all below 64 holds two empty
## lists, and an empty set is all zero.
##
## Only the root settles cells, so every site hands them up untouched. The
## root refreshes their readers by the signature (`layers_sig`), in which
## cells 64 apart share a bit, and rearms each table's next writing turn
## by the exact cells (`end_tables`).
Layers : { lo : U64, hi : List(U64), cells : U64, more : List(U64) }

## No layer and no cell.
no_layers : Layers
no_layers = { lo: 0, hi: [], cells: 0, more: [] }

## The words of a set holding index `i` alone: its low word and the rest.
index_words : U64 -> { lo : U64, hi : List(U64) }
index_words = |i| {
	w = i.shr_zf_wrap(6)
	if w == 0 {
		{ lo: wbit(i), hi: [] }
	} else {
		{ lo: 0, hi: List.repeat(0, w - 1).append(wbit(i)) }
	}
}

## The one layer at index `i`.
one_layer : U64 -> Layers
one_layer = |i| {
	{ lo, hi } = index_words(i)
	{ lo, hi, cells: 0, more: [] }
}

## The one store cell `c`.
one_cell : U64 -> Layers
one_cell = |c| {
	{ lo, hi } = index_words(c)
	{ lo: 0, hi: [], cells: lo, more: hi }
}

## The `count` store cells from `first`: what a write of a group names.
cells_span : U64, U64 -> Layers
cells_span = |first, count| {
	var $set = no_layers
	var $k = 0.U64
	while $k < count {
		$set = layers_or($set, one_cell(first + $k))
		$k = $k + 1
	}
	$set
}

## Whether a set names no layer and no cell.
layers_empty : Layers -> Bool
layers_empty = |a| a.lo == 0 and a.cells == 0 and a.hi.is_empty() and a.more.is_empty()

## The union of the words past the first of two sets.
words_or : List(U64), List(U64) -> List(U64)
words_or = |a, b| {
	if a.is_empty() {
		b
	} else if b.is_empty() {
		a
	} else {
		n = if (a.len() > b.len()) a.len() else b.len()
		var $out = List.with_capacity(n)
		var $k = 0.U64
		while $k < n {
			$out = $out.append((a.get($k) ?? 0).bitwise_or(b.get($k) ?? 0))
			$k = $k + 1
		}
		$out
	}
}

## The union of two sets.
layers_or : Layers, Layers -> Layers
layers_or = |a, b| { lo: a.lo.bitwise_or(b.lo), hi: words_or(a.hi, b.hi), cells: a.cells.bitwise_or(b.cells), more: words_or(a.more, b.more) }

## Whether the words `lo` and `hi` of a set name index `i`.
words_have : U64, List(U64), U64 -> Bool
words_have = |lo, hi, i| {
	w = i.shr_zf_wrap(6)
	word = if (w == 0) lo else (hi.get(w - 1) ?? 0)
	word.bitwise_and(wbit(i)) != 0
}

## The store cells of a set, without its layers.
cells_of : Layers -> Layers
cells_of = |a| { lo: 0, hi: [], cells: a.cells, more: a.more }

## Whether a set names layer index `i`.
layers_has : Layers, U64 -> Bool
layers_has = |a, i| words_have(a.lo, a.hi, i)

## Whether a set names store cell `c`.
layers_has_cell : Layers, U64 -> Bool
layers_has_cell = |a, c| words_have(a.cells, a.more, c)

## `hi` without its trailing zero words.
layers_trim : List(U64) -> List(U64)
layers_trim = |hi| {
	var $hi = hi
	while ($hi.last() ?? 1) == 0 {
		$hi = $hi.drop_last(1)
	}
	$hi
}

## The indices of `a` below `i`: the layers above index `i` on its path,
## and every cell (the store is above every layer).
layers_below : Layers, U64 -> Layers
layers_below = |a, i| {
	w = i.shr_zf_wrap(6)
	low = wbit(i) - 1
	if w == 0 {
		{ lo: a.lo.bitwise_and(low), hi: [], cells: a.cells, more: a.more }
	} else if a.hi.len() < w {
		a
	} else {
		kept = a.hi.take_first(w)
		last = (kept.get(w - 1) ?? 0).bitwise_and(low)
		{ lo: a.lo, hi: layers_trim(kept.set(w - 1, last) ?? kept), cells: a.cells, more: a.more }
	}
}

## The indices of `a` at or above `i`: index `i` and the layers below it.
## No cell: a cell is never below a layer.
layers_from : Layers, U64 -> Layers
layers_from = |a, i| {
	w = i.shr_zf_wrap(6)
	high = (wbit(i) - 1).bitwise_not()
	if w == 0 {
		{ lo: a.lo.bitwise_and(high), hi: a.hi, cells: 0, more: [] }
	} else if a.hi.len() < w {
		no_layers
	} else {
		var $hi = a.hi
		var $k = 0.U64
		while $k + 1 < w {
			$hi = $hi.set($k, 0) ?? $hi
			$k = $k + 1
		}
		cut = ($hi.get(w - 1) ?? 0).bitwise_and(high)
		{ lo: 0, hi: layers_trim($hi.set(w - 1, cut) ?? $hi), cells: 0, more: [] }
	}
}

## The read signature of a write set: what a refresh pass for it tests
## holes and children against. Its cells go to the high word.
layers_sig : Layers -> U128
layers_sig = |a| a.hi.fold(a.lo, |acc, w| acc.bitwise_or(w)).to_u128().bitwise_or(a.more.fold(a.cells, |acc, w| acc.bitwise_or(w)).to_u128().shl_wrap(64))

## How many layers and cells a set names.
layers_count : Layers -> U64
layers_count = |a| a.more.fold(a.hi.fold(popcount(a.lo) + popcount(a.cells), |acc, w| acc + popcount(w)), |acc, w| acc + popcount(w))

## ------------------------------------------------------------------
## Blocks: the static content of one non-each site, flattened at mount.
empty_block : {} -> Block(ctx)
empty_block = |_| { holes: [], handlers: [], children: [], child_reads: [], child_top: [], nodes: [], tops: [], reads: 0 }

## ApplyValue can land only a value the renderer actually declared. The
## capability is retained with a reference, never a copy of the control's text.
declares_value : List(Attr(ctx)) -> Bool
declares_value = |attrs| attrs.any(
	|attribute| match attribute {
		Property(1, _) | PropertyV(1, _) => Bool.True
		_ => Bool.False
	},
)

## The first event that two of an element's attributes both handle, if any.
## The runtime keeps one listener per event and element, so a second
## handler would be silently dropped: binding it is a contract error
## instead (`check_element_attrs`).
twice_handled : List(Attr(ctx)) -> Try(Str, [Distinct])
twice_handled = |attrs| {
	var $seen = []
	for a in attrs {
		match a {
			On(ev, _) => {
				if $seen.contains(ev.event) {
					return Ok(ev.event)
				}
				$seen = $seen.append(ev.event)
			}
			_ => {}
		}
	}
	Err(Distinct)
}

## Bound a diagnostic label by UTF-8 bytes without splitting a scalar. This
## runs only after a contract has failed, never while a valid element mounts.
bounded_element_hint : Str -> Str
bounded_element_hint = |text| {
	var $bytes = text.to_utf8().take_first(64)
	while Bool.True {
		match Str.from_utf8($bytes) {
			Ok(value) => return value
			Err(_) => {
				$bytes = $bytes.drop_last(1)
			}
		}
	}
}

## Find authored static text without evaluating a signal or entering a site.
## A failed element may name its first static descendant, even below wrappers.
first_static_text : Elem(ctx) -> Str
first_static_text = |elem| match elem {
	Text(text) => text.trim()
	Element(description, _, _) if description.container == TemplateContent => ""
	Element(_, _, kids) | Fragment(kids) => {
		for kid in kids {
			text = first_static_text(kid)
			if !text.is_empty() {
				return text
			}
		}
		""
	}
	Comment(_) | TextV(_) | Site(_, _) => ""
	Placed(_, child) => first_static_text(child)
}

## Prefer explicit static addresses in a fixed order, then static text. A
## dynamic label is not observed merely to improve a contract diagnostic.
element_hint : Elem(ctx) -> Str
element_hint = |elem| {
	match elem {
		Element(_, attrs, _) => {
			for name in ["data-testid", "id", "aria-label", "name"] {
				for attr in attrs {
					match attr {
						Static(authored, value) if ordinary_attribute_is(authored, name) and !value.is_empty() => return bounded_element_hint(value)
						_ => {}
					}
				}
			}
		}
		_ => {}
	}
	bounded_element_hint(first_static_text(elem))
}

## Locate an ordinal in the static part of one block. Sites own separate
## blocks and contribute no ordinal here. Only the failure path traverses
## this tree; successful mounts carry just its root and an existing count.
static_element_path : Elem(ctx), U64 -> [Found(List(U64)), Remaining(U64)]
static_element_path = |elem, ordinal| match elem {
	Site(_, _) => Remaining(ordinal)
	Placed(_, child) => static_element_path(child, ordinal)
	Fragment(kids) => static_child_path(kids, ordinal)
	Element(_, _, kids) => if ordinal == 0 {
		Found([])
	} else {
		static_child_path(kids, ordinal - 1)
	}
	Text(_) | Comment(_) | TextV(_) => if ordinal == 0 {
		Found([])
	} else {
		Remaining(ordinal - 1)
	}
}

## Count preceding static siblings without constructing paths for them. Only
## the successful search builds the child-index path as recursion unwinds.
static_child_path : List(Elem(ctx)), U64 -> [Found(List(U64)), Remaining(U64)]
static_child_path = |kids, ordinal| {
	var $left = ordinal
	var $index = 0.U64
	for kid in kids {
		match static_element_path(kid, $left) {
			Found(path) => return Found([$index].concat(path))
			Remaining(left) => {
				$left = left
			}
		}
		$index = $index + 1
	}
	Remaining($left)
}

## Format a position and bounded authored hint only after a failed check.
## These indices describe construction, never application or row identity.
element_place : Elem(ctx), List(U64) -> Str
element_place = |elem, path| {
	position = "/${Str.join_with(path.map(|index| index.to_str()), "/")}"
	hint = element_hint(elem)
	if hint.is_empty() {
		" (element ${position})"
	} else {
		" (element ${position}, ${Str.inspect(hint)})"
	}
}

## The block's existing static-node count identifies the rejected element.
## Resolve it only on failure, avoiding a growing path allocation per node.
static_element_place : Elem(ctx), U64, Elem(ctx) -> Str
static_element_place = |root, ordinal, elem| match static_element_path(root, ordinal) {
	Found(path) => element_place(elem, path)
	Remaining(_) => crash "internal: rejected element has no static construction position"
}

## Reject element contracts before allocating its nodes: one handler per
## bare event type, no retired suffixes, and properties used only on their
## declared elements without duplicates or claimed ordinary attributes.
## Both plain blocks and row templates use this construction-site check.
check_element_attrs : List(Attr(ctx)), Web.Tag, Str, List(U32), (() -> Str) -> {}
check_element_attrs = |attrs, resolved, placed, path, describe| {
	tag = resolved.local()
	html = resolved.namespace() == Explicit(Html)
	location = || "${placed} at site ${show_path(path)}${describe()}"
	controlled = attrs.any(
		|attribute| match attribute {
			PropertyV(index, _) => index == 6 or index == 7
			_ => False
		},
	)
	if controlled {
		for attribute in attrs {
			match attribute {
				On(event, _) if event.event == "beforetoggle" => crash "contract: beforetoggle is not supported on a controlled shown element${location()}"
				Static(name, _) | Dyn(name, _) if tag == "dialog" and (ordinary_attribute_is(resolve_attribute(name, resolved), "popover") or ordinary_attribute_is(resolve_attribute(name, resolved), "closedby")) => crash "contract: popover and closedby are not supported on a controlled dialog${location()}"
				Static(name, _) | Dyn(name, _) if tag == "dialog" and ordinary_attribute_is(resolve_attribute(name, resolved), "open") => crash "contract: attribute open is owned by the controlled dialog${location()}"
				_ => {}
			}
		}
	}
	if attrs.any(
		|attribute| match attribute {
			PropertyV(7, _) => True
			_ => False
		},
	) {
		static_popovers = attrs.keep_if(
			|attribute| match attribute {
				Static(name, _) if ordinary_attribute_is(resolve_attribute(name, resolved), "popover") => True
				_ => False
			},
		).len()
		if static_popovers != 1 or attrs.any(
			|attribute| match attribute {
				Dyn(name, _) if ordinary_attribute_is(resolve_attribute(name, resolved), "popover") => True
				_ => False
			},
		) {
			crash "contract: the controlled popover owns one static popover declaration${location()}"
		}
	}
	var $properties = []
	for attribute in attrs {
		match attribute {
			On(declaration, _) => {
				if declaration.kind == 1 and (declaration.event == "keydown" or declaration.event == "keyup") {
					crash "contract: text handler on ${declaration.event}${location()}; use on_key"
				}
				if declaration.event.ends_with(":prevent") or declaration.event.ends_with(":files") {
					crash "contract: retired event suffix in \"${declaration.event}\"${location()}; use on_with for policies or on_files for files"
				}
			}
			Property(index, _) | PropertyV(index, _) => {
				row = property_row(index)
				if !row.elements.is_empty() and (!html or !row.elements.contains(tag)) {
					crash "contract: property \"${row.name}\" is not allowed on <${tag}>${location()}"
				}
				if $properties.contains(index) {
					crash "contract: property \"${row.name}\" is declared twice on <${tag}>${location()}"
				}
				$properties = $properties.append(index)
			}
			Static(name, _) | Dyn(name, _) => {
				effective = resolve_attribute(name, resolved)
				match Core.attribute_claim(resolved, effective) {
					Claimed(_) => crash "contract: attribute \"${name.text()}\" on <${tag}> is claimed by a property${location()}; use prop or prop_s"
					Unclaimed => {}
				}
			}
			_ => {}
		}
	}
	match twice_handled(attrs) {
		Ok(ev) => crash "contract: two handlers for the \"${ev}\" event on one <${tag}>${location()}: an element takes one handler per event; run both from one with Handler.also"
		Err(Distinct) => {}
	}
}

mount_elem : Block(ctx), ctx, Elem(ctx), Elem(ctx), U64, List(U32), U32, U32, Bool, Bool, Scope, Tx -> (Block(ctx), Tx)
mount_elem = |block, env, root_elem, elem, depth, path, parent, before, top, sole, scope, tx| {
	at = if (top) before else 0
	match elem {
		Element(authored, attrs, kids) => {
			tag = resolve_element(authored.name, scope.enclosing)
			container = checked_container(tag, authored.container)
			children_context = child_enclosing(scope.enclosing, { name: tag, site: path, placement: "", describe: || static_element_place(root_elem, block.nodes.len(), elem) })
			check_element_attrs(attrs, tag, "", path, || static_element_place(root_elem, block.nodes.len(), elem))
			(id, tx1) = alloc_id(tx)
			tx2 = emit_op(tx1, 8, |c| put_element_name(put_u32(put_u32(put_u32(c, id), parent), at), tag).append(container))
			var $b = add_node(block, id, top)
			var $t = tx2
			value_control = declares_value(attrs)
			for attr in attrs {
				(b2, t2) = mount_attr($b, env, attr, id, path, value_control, tag, $t)
				$b = b2
				$t = t2
			}
			kid_sole = kids.len() == 1
			for kid in kids {
				(b3, t3) = mount_elem($b, env, root_elem, kid, depth, path, id, 0, False, kid_sole, { ..scope, enclosing: children_context }, $t)
				$b = b3
				$t = t3
			}
			($b, $t)
		}
		Placed(allowed, child) => {
			check_parent(allowed, scope.enclosing, path)
			mount_elem(block, env, root_elem, child, depth, path, parent, before, top, sole, scope, tx)
		}
		Comment(value) => {
			check_construction_text(scope.enclosing.construction, { value: "", site: path, placement: " (comment)" })
			(id, tx1) = alloc_id(tx)
			tx2 = emit_op(tx1, 26, |commands| put_str(put_u32(put_u32(put_u32(commands, id), parent), at), value))
			(add_node(block, id, top), tx2)
		}
		Fragment(children) => children.fold((block, tx), |(held, acc), child| mount_elem(held, env, root_elem, child, depth, path, parent, at, top, sole and children.len() == 1, scope, acc))
		Text(s) => {
			check_construction_text(scope.enclosing.construction, { value: s, site: path, placement: "" })
			(id, tx1) = alloc_id(tx)
			tx2 = emit_op(tx1, 10, |c| put_str(put_u32(put_u32(put_u32(c, id), parent), at), s))
			(add_node(block, id, top), tx2)
		}
		TextV(v) => {
			(id, tx1) = alloc_id(tx)
			read = checked_text_read(v.read, { context: scope.enclosing.construction, site: path, placement: "" })
			s = read(env)
			tx2 = emit_op(count_evals(tx1, 1), 10, |c| put_str(put_u32(put_u32(put_u32(c, id), parent), at), s))
			b1 = add_node(block, id, top)
			(add_hole(b1, { node: id, mask: eff_mask(v), attr: NoAttribute, reference: NotReference, property: 0, read: |context| Present(read(context)), last: Present(s), dirty: False }), tx2)
		}
		Site(Mount(mount), _) => {
			k = block.children.len().to_u32_wrap()
			(inst, reads, tx1) = mount(env, { depth, path: path.append(k), parent, before: at, sole: sole and !top, cap: scope.cap, enclosing: scope.enclosing }, tx)
			(add_child(block, inst, reads, top), tx1)
		}
	}
}

mount_attr : Block(ctx), ctx, Attr(ctx), U32, List(U32), Bool, Web.Tag, Tx -> (Block(ctx), Tx)
mount_attr = |block, env, attr, id, path, value_control, element_name, tx| {
	match attr {
		KeyOn(_, _, _) | ShownOn(_, _, _, _) => crash "internal: paired declaration was not lowered by element"
		Static(authored, value) => {
			name = resolve_attribute(authored, element_name)
			(block, emit_op(tx, 9, |c| put_presence(put_attribute_name(put_u32(c, id), name), Present(value))))
		}
		Dyn(authored, v) => {
			name = resolve_attribute(authored, element_name)
			read = v.read
			value = read(env)
			tx1 = emit_op(count_evals(tx, 1), 9, |c| put_presence(put_attribute_name(put_u32(c, id), name), value))
			(add_hole(block, { node: id, mask: eff_mask(v), attr: Attribute(name), reference: NotReference, property: 0, read, last: value, dirty: False }), tx1)
		}
		Property(index, value) => (block, emit_op(count_property(tx, index), 21, |commands| put_str(put_u32(commands, id).append(index), value)))
		PropertyV(index, value) => {
			encoded = (value.read)(env)
			next = shown_fact(emit_op(count_property(count_evals(tx, 1), index), 21, |commands| put_str(put_u32(commands, id).append(index), encoded)), id, 256, index, encoded)
			(add_hole(block, { node: id, mask: eff_mask(value), attr: NoAttribute, reference: NotReference, property: index, read: |context| Present((value.read)(context)), last: Present(encoded), dirty: False }), next)
		}
		On(ev, handler) => {
			tx0 = if ev.policies.bitwise_and(16) != 0 {
				if tx.fx.document_nodes.len() >= 32 {
					crash "contract: more than 32 live document key handlers at site ${show_path(path)}"
				}
				with_fx(tx, |fx| { ..fx, document_nodes: fx.document_nodes.append(id) })
			} else tx
			h = block.handlers.len().to_u32_wrap()
			registered = if (ev.kind == 7 or ev.kind == 8) observe_node(tx0, id) else tx0
			tx1 = emit_op(registered, 11, |c| put_u32(put_str(put_u32(put_u32(c, id), h), ev.event).append(ev.kind), ev.policies))
			(add_handler(block, bind_block_echo(handler, block.holes)), set_route(tx1, id, path, h))
		}
		Ref(value) => {
			ref_path = path.append(block.holes.len().to_u32_wrap())
			name = (value.read)(env)
			(add_hole(block, { node: id, mask: eff_mask(value), attr: NoAttribute, reference: Reference(ref_path, value_control), property: 0, read: |context| Present((value.read)(context)), last: Present(name), dirty: False }), with_fx(count_evals(tx, 1), |fx| add_ref(fx, { name, node: id, path: ref_path, value_control })))
		}
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

add_handler : Block(ctx), RoutedHandler(ctx) -> Block(ctx)
add_handler = |{ holes, handlers, children, child_reads, child_top, nodes, tops, reads }, h| {
	{ holes, handlers: handlers.append(h), children, child_reads, child_top, nodes, tops, reads }
}

add_child : Block(ctx), Inst(ctx), U128, Bool -> Block(ctx)
add_child = |{ holes, handlers, children, child_reads, child_top, nodes, tops, reads }, inst, r, top| {
	{ holes, handlers, children: children.append(inst), child_reads: child_reads.append(r), child_top: child_top.append(top), nodes, tops, reads: reads.bitwise_or(r) }
}

mount_block : ctx, Elem(ctx), U64, List(U32), U32, U32, Scope, Tx -> (Block(ctx), Tx)
mount_block = |env, elem, depth, path, parent, before, scope, tx| mount_elem(empty_block({}), env, elem, elem, depth, path, parent, before, True, False, scope, tx)

noop : {} -> Inst(ctx)
noop = |_| Inst(
	|env, msg, tx| {
		match msg {
			Fire(_, _, _, _) => (noop({}), Pending(env, no_layers), tx)
			_ => (noop({}), Done, tx)
		}
	},
)

call : Inst(ctx), ctx, Msg, Tx -> (Inst(ctx), Out(ctx), Tx)
call = |Inst(f), env, msg, tx| f(env, msg, tx)

## Re-evaluate the holes that read a changed layer, then descend into the
## children whose subtrees read one. With `every_layer` it re-evaluates every
## hole and descends into every child, whatever the masks say.
refresh : Block(ctx), ctx, U128, Tx -> (Block(ctx), Tx)
refresh = |{ holes, handlers, children, child_reads, child_top, nodes, tops, reads }, env, mask, tx| {
	all = mask == every_layer
	var $holes = holes
	var $tx = tx
	var $i = 0.U64
	while $i < $holes.len() {
		hm = $holes.get($i).map_ok(|h| h.mask) ?? 0
		if all or hm.bitwise_and(mask) != 0 or ($holes.get($i).map_ok(|hole| hole.dirty) ?? False) {
			{ list, prev } = $holes.replace($i, { node: 0, mask: 0, attr: NoAttribute, reference: NotReference, property: 0, read: |_| Absent, last: Absent, dirty: False }) ?? crash "hole"
			{ node, mask: m, attr, reference, property, read, last, dirty: _ } = prev
			v = read(env)
			t1 = count_evals($tx, 1)
			if v == last {
				$holes = list.set($i, { node, mask: m, attr, reference, property, read, last, dirty: False }) ?? crash "hole"
				$tx = t1
			} else {
				$tx = if property != 0 {
					shown_fact(emit_op(count_property(t1, property), 21, |commands| put_str(put_u32(commands, node).append(property), observed_text(v))), node, 256, property, observed_text(v))
				} else match reference {
					Reference(path, value_control) => with_fx(t1, |fx| add_ref(drop_name(fx, { node, name: observed_text(last), path }), { name: observed_text(v), node, path, value_control }))
					NotReference => match attr {
						NoAttribute => emit_op(t1, 12, |c| put_str(put_u32(c, node), observed_text(v)))
						Attribute(name) => emit_op(t1, 9, |c| put_presence(put_attribute_name(put_u32(c, node), name), v))
					}
				}
				$holes = list.set($i, { node, mask: m, attr, reference, property, read, last: v, dirty: False }) ?? crash "hole"
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

## Run handler `h` of this block (the event's target is this block, the
## site at `site`). A `Settle` that reaches the block runs nothing.
fire_leaf : Block(ctx), ctx, U32, Payload, List(U32), Tx -> (Block(ctx), Out(ctx), Tx)
fire_leaf = |block, env, h, payload, site, tx| {
	if !fires(payload) {
		(b2, t2) = match payload {
			Settle(_, True) => refresh(block, env, 0, tx)
			_ => (block, tx)
		}
		return (b2, Pending(env, no_layers), t2)
	}
	match block.handlers.get(h.to_u64()) {
		Ok(handler) => {
			(block2, prepared, tx2) = match handler.echo {
				NoEcho => (block, payload, tx)
				Echo(echo) => {
					open = (open_kind.decode)(payload, site)
					value = if (open) echo.showing else if (echo.property == 6) "hidden" else "false"
					{ holes, handlers, children, child_reads, child_top, nodes, tops, reads } = block
					{ list, prev } = holes.replace(echo.hole, { node: 0, mask: 0, attr: NoAttribute, reference: NotReference, property: 0, read: |_| Absent, last: Absent, dirty: False }) ?? crash "internal: paired shown hole"
					next = { ..prev, last: Present(value), dirty: True }
					fact = shown_fact(tx, prev.node, 256, echo.property, value)
					({ holes: list.set(echo.hole, next) ?? crash "internal: paired shown hole", handlers, children, child_reads, child_top, nodes, tops, reads }, OpenState(open), { ..fact, observations: { ..fact.observations, echo: True } })
				}
			}
			(next, wrote) = (handler.run)(env, prepared, site)
			(block2, Pending(next, wrote), tx2)
		}
		Err(_) => (block, Pending(env, no_layers), tx)
	}
}

## Paired attachment makes the previous property hole the unique echo owner.
bind_block_echo : RoutedHandler(ctx), List(Hole(ctx)) -> RoutedHandler(ctx)
bind_block_echo = |handler, holes| match handler.echo {
	NoEcho => handler
	Echo(echo) => {
		hole = holes.last() ?? crash "internal: shown handler needs its property"
		if hole.property != echo.property {
			crash "internal: shown handler and property disagree"
		}
		{ ..handler, echo: Echo({ ..echo, hole: holes.len() - 1 }) }
	}
}

## Template handler metadata addresses its paired property directly, never by a scan.
bind_row_echo : RoutedHandler(ctx), List(RHole(ctx)) -> RoutedHandler(ctx)
bind_row_echo = |handler, holes| match handler.echo {
	NoEcho => handler
	Echo(echo) => {
		hole = holes.last() ?? crash "internal: shown row handler needs its property"
		if hole.property != echo.property {
			crash "internal: shown row handler and property disagree"
		}
		{ ..handler, echo: Echo({ ..echo, hole: holes.len() - 1 }) }
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
	for id in nodes {
		$tx = release_node($tx, id)
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

## Whether the written layer at index `depth` waits at its site when the
## event that wrote it unwinds through it: the event also wrote a layer
## above it on its path, or a store cell.
##
## A reader below the layer may also read the outer write, or something
## derived from either: a `derive`, a `resource`, a row's item. Refreshed
## for one write at a time, it would be evaluated with one new value beside
## one old one, a pair that never held: a text would be written twice, and
## an effect site would issue a request for it. So an event's writes are
## settled by one pass, from the outermost. The inner layer hands its write
## up and waits; the outermost written layer (or the root, for a cell)
## starts the pass; and when the pass reaches the waiting layer's site, the
## site adds its own layer to what the pass carries, for its subtree alone
## (`state_inst`). Order within the pass follows nesting, so every `derive`
## of either write is recomputed before anything below it reads it, and a
## reader of both is evaluated once.
##
## A layer is readable only below its own site, so nothing outside the
## waiting layer's subtree can need it, and no reader of a sibling layer at
## the same index is woken. A waiting layer the pass does not reach has no
## reader in common with it: nothing in its subtree reads what the pass
## carried. The `Settle` walk that follows the pass down the event's path
## refreshes each such layer at its own site.
waits_for_outer : Layers, U64 -> Bool
waits_for_outer = |mask, depth| !layers_empty(layers_below(mask, depth))

## After an event below a state site: take this layer's value back from
## the environment. A layer the event did not write hands the event's
## write set up as it is. A written layer with something written above it
## waits (`waits_for_outer`). A written layer with nothing written above it
## starts the event's pass: it refreshes its block, where the layers
## written below it join, and then sends the `Settle` walk down the event's
## path (`path`, `pos` and `h` are the event's) for those the pass did not
## reach.
state_settle : Block(In(ctx, s)), U64, Out(In(ctx, s)), List(U32), U64, U32, Tx -> (Inst(ctx), Out(ctx), Tx)
state_settle = |block, depth, out, path, pos, h, tx| {
	match out {
		Done => crash "internal: fire must hand the environment back"
		Orphaned(_) => crash "internal: fire must hand the environment back"
		Pending(next_inner, mask) => {
			{ outer: next_outer, value: s2 } = next_inner
			# The write set is exact: whether this layer was written, and
			# what is handed up, never depend on a shared signature bit.
			if !layers_has(mask, depth) {
				(state_inst(s2, block, depth, Settled), Pending(next_outer, mask), tx)
			} else if waits_for_outer(mask, depth) {
				(state_inst(s2, block, depth, Waiting), Pending(next_outer, mask), tx)
			} else {
				# Every write of the turn is in place by now, and this is the
				# outermost layer it wrote: its pass starts here.
				(b3, t3) = refresh(block, In.{ outer: next_outer, value: s2 }, bit(depth), bump(tx, w_dirty_roots, 1))
				waiting = layers_from(mask, depth + 1)
				if layers_empty(waiting) or pos >= path.len() {
					(state_inst(s2, b3, depth, Settled), Pending(next_outer, no_layers), t3)
				} else {
					# Then the walk for the written layers below it that the
					# pass did not reach: they lie on the event's path.
					(b4, settled, t4) = fire_kid(b3, In.{ outer: next_outer, value: s2 }, path, pos, h, Settle(waiting, False), t3)
					(outer, s4) = state_out(settled)
					(state_inst(s4, b4, depth, Settled), Pending(outer, no_layers), t4)
				}
			}
		}
	}
}

## A `Settle` walk at a state site. A layer that still waits was not
## reached by the pass the walk follows, so nothing in its subtree read
## what that pass carried: its readers are refreshed here, for this layer,
## and the layers written below it join as that refresh reaches them. The
## walk then goes on down the event's path while it names a layer further
## down.
state_walk : s, Block(In(ctx, s)), ctx, U64, [Settled, Waiting], [Further, Ends], List(U32), U64, U32, Payload, Tx -> (Inst(ctx), Out(ctx), Tx)
state_walk = |s, block, env, depth, waits, on, path, pos, h, payload, tx| {
	match waits {
		Waiting => {
			(b2, t2) = refresh(block, In.{ outer: env, value: s }, bit(depth), bump(tx, w_dirty_roots, 1))
			state_walk_on(s, b2, env, depth, on, path, pos, h, payload, t2)
		}
		Settled => state_walk_on(s, block, env, depth, on, path, pos, h, payload, tx)
	}
}

## The rest of a `Settle` walk at a state site whose own layer is settled:
## on to the child the event's path names, if the walk names a layer
## further down.
state_walk_on : s, Block(In(ctx, s)), ctx, U64, [Further, Ends], List(U32), U64, U32, Payload, Tx -> (Inst(ctx), Out(ctx), Tx)
state_walk_on = |s, block, env, depth, on, path, pos, h, payload, tx| {
	match (on, fire_target(block, path, pos)) {
		(Further, Kid) => {
			(b2, out, t2) = fire_kid(block, In.{ outer: env, value: s }, path, pos, h, payload, tx)
			(outer, s2) = state_out(out)
			(state_inst(s2, b2, depth, Settled), Pending(outer, no_layers), t2)
		}
		(_, Leaf) => {
			(b2, t2) = match payload {
				Settle(_, True) => refresh(block, In.{ outer: env, value: s }, 0, tx)
				_ => (block, tx)
			}
			(state_inst(s, b2, depth, Settled), Pending(env, no_layers), t2)
		}
		_ => (state_inst(s, block, depth, Settled), Pending(env, no_layers), tx)
	}
}

## What a state site's block hands back from a fire: the outer environment
## and this layer's value.
state_out : Out(In(ctx, s)) -> (ctx, s)
state_out = |out| match out {
	Pending(inner, _) => {
		{ outer, value } = inner
		(outer, value)
	}
	Done => crash "internal: fire must hand the environment back"
	Orphaned(_) => crash "internal: fire must hand the environment back"
}

## A state site: `s` is this layer's value at absolute depth `depth`.
## `waits` is `Waiting` from the moment an event that wrote this layer
## below another of its writes unwinds through the site (`waits_for_outer`)
## until its readers are refreshed, in the same turn: by the pass of the
## outer write, if that pass reaches the site, and otherwise by the
## `Settle` walk that follows it.
## TODO https://github.com/roc-lang/roc/issues/13012: boxed site captures
## remain borrowed; local state can copy even in development builds.
## TODO https://github.com/roc-lang/roc/issues/13019: optimized writes still
## copy site storage without a boxed engine value; no local workaround found.
state_inst : s, Block(In(ctx, s)), U64, [Settled, Waiting] -> Inst(ctx)
state_inst = |s0, block0, depth0, waits0| {
	held = { s: s0, block: block0, depth: depth0, waits: waits0 }
	Inst(
		|env, msg, tx| {
			{ s, block, depth, waits } = held
			match msg {
				Changed(mask) => {
					match waits {
						Waiting => {
							# The pass of a write above this layer has reached its
							# site: the layer joins it. Its bit is added here, so it
							# is carried in this subtree and nowhere else, and a
							# reader below of both writes is evaluated once.
							(b2, t2) = refresh(block, In.{ outer: env, value: s }, mask.bitwise_or(bit(depth)), bump(tx, w_dirty_roots, 1))
							(state_inst(s, b2, depth, Settled), Done, t2)
						}
						Settled => {
							(b2, t2) = refresh(block, In.{ outer: env, value: s }, mask, tx)
							(state_inst(s, b2, depth, Settled), Done, t2)
						}
					}
				}
				Fire(path, pos, h, payload) => {
					match settle_walk(payload, depth) {
						Ok(on) => state_walk(s, block, env, depth, waits, on, path, pos, h, payload, tx)
						Err(Fires) => {
							# `s` moves into the environment here and is never used again on
							# this path, so a reducer below sees it uniquely owned.
							match fire_target(block, path, pos) {
								Leaf => {
									(b2, out, t2) = fire_leaf(block, In.{ outer: env, value: s }, h, payload, path, tx)
									state_settle(b2, depth, out, path, pos, h, t2)
								}
								Kid => {
									(b2, out, t2) = fire_kid(block, In.{ outer: env, value: s }, path, pos, h, payload, tx)
									state_settle(b2, depth, out, path, pos, h, t2)
								}
								Miss => state_settle(block, depth, Pending(In.{ outer: env, value: s }, no_layers), path, pos, h, tx)
							}
						}
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
When(ctx) : { cond : Signal(ctx, Bool), yes : (() -> Elem(ctx)), no : (() -> Elem(ctx)), anchor : U32, depth : U64, path : List(U32), cap : U128, enclosing : Enclosing }

## `adopted`: orphans reparented to this site when a branch it disposed
## left admitted requests behind.
when_inst : When(ctx), Bool, List(Orphan(ctx)), Block(ctx) -> Inst(ctx)
when_inst = |w0, cur0, adopted0, block0| {
	held = { w: w0, cur: cur0, adopted: adopted0, block: block0 }
	Inst(
		|env, msg, tx| {
			{ w, cur, adopted, block } = held
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
							(b3, t3) = mount_block(env, elem, w.depth, w.path, 0, w.anchor, { cap: w.cap, enclosing: w.enclosing }, fx_adopt(t2, w.path, orph))
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
									(b2, out, t2) = fire_leaf(block, env, h, payload, path, tx)
									(when_inst(w, cur, adopted, b2), out, t2)
								}
								Kid => {
									(b2, out, t2) = fire_kid(block, env, path, pos, h, payload, tx)
									(when_inst(w, cur, adopted, b2), out, t2)
								}
								Miss => (when_inst(w, cur, adopted, block), Pending(env, no_layers), tx)
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
	held = { block: block0 }
	Inst(
		|env, msg, tx| {
			{ block } = held
			match msg {
				Changed(mask) => {
					(b2, t2) = refresh(block, env, mask, tx)
					(block_inst(b2), Done, t2)
				}
				Fire(path, pos, h, payload) => {
					match fire_target(block, path, pos) {
						Leaf => {
							(b2, out, t2) = fire_leaf(block, env, h, payload, path, tx)
							(block_inst(b2), out, t2)
						}
						Kid => {
							(b2, out, t2) = fire_kid(block, env, path, pos, h, payload, tx)
							(block_inst(b2), out, t2)
						}
						Miss => (block_inst(block), Pending(env, no_layers), tx)
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

## The root site owns its block, table bookkeeping and exact pending write set.
## The instance moves the store into each call's Root context and takes it back
## from Pending. The Changed pass rearms only written tables after refreshing
## readers; their last writing turn's record remains until the next write.
## TODO https://github.com/roc-lang/roc/issues/13019: moving the store out
## fixes development ownership, but optimized site paths can still copy it.
store_inst : Tables(st), Layers, Block(Root(st)) -> Inst(Root(st))
store_inst = |tables0, wrote0, block0| {
	held = { tables: tables0, wrote: wrote0, block: block0 }
	Inst(
		|env, msg, tx| {
			{ tables, wrote, block } = held
			match msg {
				Changed(mask) => {
					(b2, t2) = refresh(block, env, mask, tx)
					(store_inst(tables, no_layers, b2), Pending(Root.{ store: end_tables(env.store, tables, wrote) }, no_layers), t2)
				}
				Fire(path, pos, h, payload) => match fire_target(block, path, pos) {
					Leaf => {
						(b2, out, t2) = fire_leaf(block, env, h, payload, path, tx)
						store_settle(b2, tables, out, t2)
					}
					Kid => {
						(b2, out, t2) = fire_kid(block, env, path, pos, h, payload, tx)
						store_settle(b2, tables, out, t2)
					}
					Miss => store_settle(block, tables, Pending(env, no_layers), tx)
				}
				Dispose(remove) => {
					(_, t2) = dispose_block(block, env, remove, tx)
					(noop({}), Orphaned([]), t2)
				}
			}
		},
	)
}

## Mounted table identities start above value identities. Store construction
## keeps cell positions below this boundary; a Store.read snapshot cannot
## impersonate a mounted table even when its write counts happen to match.
live_ids : U64
live_ids = 0x1_0000_0000

## Reserve disjoint table identity ranges before making any cell lens. This
## bound follows the authored store description, never table rows or input.
check_store_cells : U64 -> Try({}, [TooManyCells])
check_store_cells = |count| if (count < live_ids) Ok({}) else Err(TooManyCells)

## The largest admitted store keeps every value identity below every live
## identity; the first refused count and U64's limit cannot reach addition.
expect {
	largest = live_ids - 1
	actual = {
		empty: check_store_cells(0),
		largest: check_store_cells(largest),
		boundary: check_store_cells(live_ids),
		maximum: check_store_cells(18_446_744_073_709_551_615),
		disjoint: largest < live_ids + 1,
		last_live: largest + live_ids,
	}
	actual == { empty: Ok({}), largest: Ok({}), boundary: Err(TooManyCells), maximum: Err(TooManyCells), disjoint: True, last_live: 0x1_ffff_ffff }
}

## The store's table cells, as the root site holds them: what it needs of
## each, and the signature bits of all of them.
Tables(st) : { cells : List(Core.TableCell(st)), written : U128 }

## The end of a turn for the store's tables: rearm the recording phase of
## every table the turn wrote, after its readers have refreshed, without
## changing its last writing turn's record. `wrote` names cells exactly; a table whose
## cell only shares a signature bit with a written one is left alone.
end_tables : st, Tables(st), Layers -> st
end_tables = |st, tables, wrote| {
	if layers_sig(wrote).bitwise_and(tables.written) == 0 {
		st
	} else {
		tables.cells.fold(st, |acc, t| if (layers_has_cell(wrote, t.cell)) (t.finish)(acc) else acc)
	}
}

## After an event, return its root environment intact to the instance and
## keep only the write set for end-of-turn table rearming. The turn moves that
## store into its one Changed pass before any later input can write again.
store_settle : Block(Root(st)), Tables(st), Out(Root(st)), Tx -> (Inst(Root(st)), Out(Root(st)), Tx)
store_settle = |block, tables, out, tx| match out {
	Pending(env, writes) => (store_inst(tables, writes, block), Pending(env, writes), tx)
	_ => crash "internal: fire must hand the environment back"
}

## The halves of a pair of store cells, for the generated lenses.
pair_first : (a, b) -> a
pair_first = |(a, _)| a

pair_second : (a, b) -> b
pair_second = |(_, b)| b

## Who decided a list of writes: the handler or the reaction of the site at
## a path, or a test through `Store.after`. The contract error of a
## replaced write names it.
Decider : [Handler(List(U32)), Reaction(List(U32)), After]

## Apply a decision's writes to the store the context reaches (through
## `store_over`, its [StoreReach]'s `over`), in order, and report the cells
## they name: the set an event wrote is what its handler did, known only
## now. An empty list touches nothing and reports nothing, so no reader is
## woken.
store_writes : (ctx, (st -> st) -> ctx), ctx, List(Core.Write(st)), Decider -> (ctx, Layers)
store_writes = |store_over, env, writes, by| {
	if writes.is_empty() {
		(env, no_layers)
	} else {
		cells = writes_cells(writes, by)
		(store_over(env, |st| writes.fold(st, |acc, w| (w.apply)(acc))), cells)
	}
}

## The cells a decision's writes name. A write that replaces a cell an
## earlier write of the same list wrote would discard that write, which no
## decision means: it is a contract error naming who decided, the cell's
## position in the store and the two writes. The one exception is the
## write it refines: a reset of a group, then a write of one of the
## group's cells ("start again, but with this"). A change after another
## write of its cell is applied to that write's result.
writes_cells : List(Core.Write(st)), Decider -> Layers
writes_cells = |writes, by| {
	var $cells = no_layers
	var $i = 0.U64
	for w in writes {
		if w.kind == Replace {
			var $j = 0.U64
			while $j < $i {
				earlier = writes.get($j) ?? crash "internal: a write before this one"
				meets = earlier.first < w.first + w.count and w.first < earlier.first + earlier.count
				refines = earlier.kind == Replace and earlier.count > w.count and earlier.first <= w.first and w.first + w.count <= earlier.first + earlier.count
				if meets and !refines {
					at = if (earlier.first > w.first) earlier.first else w.first
					who = match by {
						Handler(site) => "the decision of the handler at site ${show_path(site)}"
						Reaction(site) => "the decision of the reaction at site ${show_path(site)}"
						After => "the writes given to Store.after"
					}
					crash "contract: ${who} wrote cell ${at.to_str()} of the store and then replaced it (write ${($i + 1).to_str()} of the list replaces what write ${($j + 1).to_str()} wrote), which would discard the earlier write; write the cell once, or make the later write an update of what the earlier one left"
				}
				$j = $j + 1
			}
		}
		$cells = layers_or($cells, cells_span(w.first, w.count))
		$i = $i + 1
	}
	$cells
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
Buckets : { hs : List(U64), vals : List(U32), count : U64, bits : U8 }

grow : Buckets -> Buckets
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
## Template encoding: node := 1 expanded-name container:u8 nattr:u8
## (expanded-name value:str)* nchild:u8 node* | 2 text:str | 3 comment:str;
## then nholes:u8, each hole := kind:u8 depth:u8 (container:u8 index:u8)*, followed by an attribute name, an event declaration
## (handler index, bare event name, payload kind and policy bits), or a
## property index for those hole kinds.
## Hole kinds: 1 text, 2 attr, 3 event, 4 bind (placeholder for a nested
## site), 5 reference (an element addressed by a minted node id), 6 property.
## A property hole's extra byte is its property index. `col` is the value
## column for text, attribute and property holes whose value can
## change (none for row-constant holes), the handler index for events and
## the mount index for binds.
## `ctl`: the work counter a property hole's updates also count in
## (`w_set_value`, `w_set_checked`), or 0; for a reference, its index
## among reference holes, after the nested-site ids in the row's bindings.
RHole(ctx) : { is_observation : Bool, evaluated : Bool, kind : U8, mask : U128, smask : U128, skey : (ctx -> Str), read : (ctx -> [Absent, Present(Str)]), col : U64, live : Bool, ctl : U64, value_control : Bool, property : U8 }

Plan(ctx) : {
	tree : List(U8),
	htab : List(U8),
	holes : List(RHole(ctx)),
	handlers : List(RoutedHandler(ctx)),
	mounts : List(Mount(ctx)),
	ncols : U64,
	kreads : U128,
}

plan_empty : {} -> Plan(ctx)
plan_empty = |_| { tree: [], htab: [], holes: [], handlers: [], mounts: [], ncols: 0, kreads: 0 }

put_path : List(U8), U8, List({ container : U8, index : U8 }) -> List(U8)
put_path = |buf, kind, path| path.fold(buf.append(kind).append(narrow(path.len(), "nesting depth of a hole")), |out, step| out.append(step.container).append(step.index))

## A count the template encoding carries in one byte (design.md, Appendix
## B). Beyond 255 it is a resource limit, never a wrap.
narrow : U64, Str -> U8
narrow = |n, what| if (n > 255) crash "resource_limit: a row template's ${what} is ${n.to_str()}; the template encoding allows at most 255" else n.to_u8_wrap()

val_hole : Plan(ctx), { kind : U8, value : Signal(ctx, [Absent, Present(Str)]), extra : List(U8), counter : U64, evaluated : Bool } -> Plan(ctx)
val_hole = |{ tree, htab, holes, handlers, mounts, ncols, kreads }, { kind, value: v, extra, counter, evaluated }| {
	{ mask, read, sel } = v
	(smask, skey) = match sel {
		NoSel => (0, |_| "")
		Sel(m, k) => (m, k)
	}
	property = if (kind == 6) extra.last() ?? crash "internal: property row has an index" else 0
	live = mask.bitwise_or(smask) != 0 or property == 6 or property == 7
	hole = { is_observation: False, evaluated, kind, mask, smask, skey, read, col: if (live) ncols else 0, live, ctl: if (kind == 5) holes.keep_if(|prior| prior.kind == 5).len() else counter, value_control: kind == 5 and counter == 1, property }
	{ tree, htab: htab.concat(extra), holes: holes.append(hole), handlers, mounts, ncols: if (live) ncols + 1 else ncols, kreads }
}

compile_elem : Plan(ctx), Elem(ctx), List({ container : U8, index : U8 }), U64, List(U32), Str, Enclosing -> Plan(ctx)
compile_elem = |plan, elem, path, depth, site, placed, enclosing| {
	match elem {
		Element(authored, attrs, kids) => {
			tag = resolve_element(authored.name, enclosing)
			container = checked_container(tag, authored.container)
			children_context = child_enclosing(enclosing, { name: tag, site, placement: placed, describe: || element_place(elem, path.map(|step| step.index.to_u64())) })
			check_element_attrs(attrs, tag, placed, site, || element_place(elem, path.map(|step| step.index.to_u64())))
			value_control = declares_value(attrs)
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
			var $tree = put_element_name(tree.append(1), tag).append(container).append(narrow(nstatic, "static attributes on one element"))
			var $htab = htab
			var $holes = holes
			var $handlers = handlers
			var $ncols = ncols
			for a in attrs {
				match a {
					KeyOn(_, _, _) | ShownOn(_, _, _, _) => crash "internal: paired declaration was not lowered by element"
					Static(name, value) => {
						$tree = put_str(put_attribute_name($tree, resolve_attribute(name, tag)), value)
					}
					Dyn(name, v) => {
						r = val_hole({ tree: [], htab: [], holes: $holes, handlers: [], mounts: [], ncols: $ncols, kreads: 0 }, { kind: 2, value: v, extra: put_attribute_name(put_path([], 2, path), resolve_attribute(name, tag)), counter: 0, evaluated: True })
						$htab = $htab.concat(r.htab)
						$holes = r.holes
						$ncols = r.ncols
					}
					Property(index, encoded) => {
						r = val_hole({ tree: [], htab: [], holes: $holes, handlers: [], mounts: [], ncols: $ncols, kreads: 0 }, { kind: 6, value: Core.const(Present(encoded)), extra: put_path([], 6, path).append(index), counter: property_row(index).counter, evaluated: False })
						$htab = $htab.concat(r.htab)
						$holes = r.holes
						$ncols = r.ncols
					}
					PropertyV(index, value) => {
						r = val_hole({ tree: [], htab: [], holes: $holes, handlers: [], mounts: [], ncols: $ncols, kreads: 0 }, { kind: 6, value: value.map(|encoded| Present(encoded)), extra: put_path([], 6, path).append(index), counter: property_row(index).counter, evaluated: True })
						$htab = $htab.concat(r.htab)
						$holes = r.holes
						$ncols = r.ncols
					}
					On(ev, handler) => {
						bound = bind_row_echo(handler, $holes)
						$htab = put_u32(put_str(put_path($htab, 3, path).append(narrow($handlers.len(), "event handler count")), ev.event).append(ev.kind), ev.policies)
						$holes = $holes.append({ is_observation: ev.kind == 7 or ev.kind == 8, evaluated: False, kind: 3, mask: 0, smask: 0, skey: |_| "", read: |_| Absent, col: $handlers.len(), live: False, ctl: 0, value_control: False, property: 0 })
						$handlers = $handlers.append(bound)
					}
					Ref(value) => {
						r = val_hole({ tree: [], htab: [], holes: $holes, handlers: [], mounts: [], ncols: $ncols, kreads: 0 }, { kind: 5, value: value.map(|encoded| Present(encoded)), extra: put_path([], 5, path), counter: if (value_control) 1 else 0, evaluated: True })
						$htab = $htab.concat(r.htab)
						$holes = r.holes
						$ncols = r.ncols
					}
				}
			}
			$tree = $tree.append(narrow(kids.len(), "children of one element"))
			$p = { tree: $tree, htab: $htab, holes: $holes, handlers: $handlers, mounts, ncols: $ncols, kreads }
			var $i = 0.U8
			for kid in kids {
				$p = compile_elem($p, kid, path.append({ container, index: $i }), depth, site, placed, children_context)
				$i = $i + 1
			}
			$p
		}
		Placed(allowed, child) => {
			check_parent(allowed, enclosing, site)
			compile_elem(plan, child, path, depth, site, placed, enclosing)
		}
		Comment(value) => {
			check_construction_text(enclosing.construction, { value: "", site, placement: "${placed} (comment)" })
			{ ..plan, tree: put_str(plan.tree.append(3), value) }
		}
		Fragment(_) => crash "internal: a fragment is only a dynamic branch, never a row template node"
		Text(s) => {
			check_construction_text(enclosing.construction, { value: s, site, placement: placed })
			{ tree, htab, holes, handlers, mounts, ncols, kreads } = plan
			{ tree: put_str(tree.append(2), s), htab, holes, handlers, mounts, ncols, kreads }
		}
		TextV(v) => {
			check_construction_text(enclosing.construction, { value: "", site, placement: placed })
			checked = checked_text_read(v.read, { context: enclosing.construction, site, placement: placed })
			{ tree, htab, holes, handlers, mounts, ncols, kreads } = plan
			t2 = put_str(tree.append(2), "")
			val_hole({ tree: t2, htab, holes, handlers, mounts, ncols, kreads }, { kind: 1, value: { ..v.map(|encoded| Present(encoded)), read: |context| Present(checked(context)) }, extra: put_path([], 1, path), counter: 0, evaluated: True })
		}
		Site(m, rf) => {
			check_construction_text(enclosing.construction, { value: "", site, placement: "${placed} (nested site anchor)" })
			{ tree, htab, holes, handlers, mounts, ncols, kreads } = plan
			hole = { is_observation: False, evaluated: False, kind: 4, mask: 0, smask: 0, skey: |_| "", read: |_| Absent, col: mounts.len(), live: False, ctl: 0, value_control: False, property: 0 }
			{ tree: put_str(tree.append(2), ""), htab: put_path(htab, 4, path), holes: holes.append(hole), handlers, mounts: mounts.append(mount_in_context(m, enclosing)), ncols, kreads: kreads.bitwise_or(rf(depth)) }
		}
	}
}

## Compile an `each` row template for the each site at `site`.
compile : Elem(ctx), U64, List(U32), Str, Enclosing -> Plan(ctx)
compile = |elem, depth, site, kind, enclosing| {
	match elem {
		Element(_, _, _) => compile_elem(plan_empty({}), elem, [], depth, site, " in the row template of ${kind}", enclosing)
		Placed(allowed, child) => {
			check_parent(allowed, enclosing, site)
			compile(child, depth, site, kind, enclosing)
		}
		_ => crash "contract: ${kind} row template must be a single element at site ${show_path(site)}"
	}
}

template_bytes : Plan(ctx) -> List(U8)
template_bytes = |plan| plan.tree.append(narrow(plan.holes.len(), "hole count")).concat(plan.htab)

## ------------------------------------------------------------------
## The each site, and the rows it shares with the view site.

## Fixed per site that draws rows. `key` is how the site knows a row: for
## an `each` site, the function from an item to its text key, which the
## site's key index finds rows by; for a view site nothing (`{}`), since it
## finds a row by the table's own key in an index it keeps itself.
EachCfg(r, key) : {
	site : U32,
	parent : U32,
	anchor : U32,
	sole : Bool,
	depth : U64,
	path : List(U32),
	key : key,
	plan : Plan(r),
	dynamic : Bool,
	outer_mask : U128,
	sel_mask : U128,
}

## The live shown addresses of a row retain show-intent order. Exact command
## addresses are bounded integers, reused only after the old entry is removed.
ShownMap : {
	owners : Dict(U32, List(U64)),
	entries : Dict(U64, ShownEntry),
	first : U64,
	last : U64,
}

ShownEntry : { node : U32, hole : U16, property : U8, value : Str, prev : U64, next : U64 }

shown_empty : ShownMap
shown_empty = { owners: Dict.empty(), entries: Dict.empty(), first: 0, last: 0 }

shown_address : U32, U16 -> U64
shown_address = |node, hole| node.to_u64().shl_wrap(16).bitwise_or(hole.to_u64())

## Unlink one known entry without walking any other shown descendant.
shown_unlink : ShownMap, U64 -> ShownMap
shown_unlink = |shown, address| {
	entry = shown.entries.get(address) ?? return shown
	var $entries = shown.entries.remove(address)
	if entry.prev != 0 {
		previous = $entries.get(entry.prev) ?? crash "shown previous link"
		$entries = $entries.insert(entry.prev, { ..previous, next: entry.next })
	}
	if entry.next != 0 {
		following = $entries.get(entry.next) ?? crash "shown next link"
		$entries = $entries.insert(entry.next, { ..following, prev: entry.prev })
	}
	{
		..shown,
		entries: $entries,
		first: if entry.prev == 0 {
			entry.next
		} else {
			shown.first
		},
		last: if entry.next == 0 {
			entry.prev
		} else {
			shown.last
		},
	}
}

## One owner has at most the template's 255 holes, or one plain PROP.
shown_remove : ShownMap, U32, U16 -> ShownMap
shown_remove = |shown, node, hole| {
	address = shown_address(node, hole)
	keys = shown.owners.get(node) ?? return shown
	owners = shown.owners.remove(node)
	kept = keys.keep_if(|key| key != address)
	shown_unlink(
		{
			..shown,
			owners: if kept.is_empty() {
				owners
			} else {
				owners.insert(node, kept)
			},
		},
		address,
	)
}

shown_record : ShownMap, { node : U32, hole : U16, property : U8, value : Str } -> ShownMap
shown_record = |shown, fact| {
	address = shown_address(fact.node, fact.hole)
	match shown.entries.get(address) {
		Ok(entry) => { ..shown, entries: shown.entries.insert(address, { ..entry, value: fact.value }) }
		Err(_) => {
			keys = shown.owners.get(fact.node) ?? []
			owners = shown.owners.remove(fact.node).insert(fact.node, keys.append(address))
			var $entries = shown.entries
			if shown.last != 0 {
				last = $entries.get(shown.last) ?? crash "shown last link"
				$entries = $entries.insert(shown.last, { ..last, next: address })
			}
			{
				owners,
				entries: $entries.insert(address, { node: fact.node, hole: fact.hole, property: fact.property, value: fact.value, prev: shown.last, next: 0 }),
				first: if shown.first == 0 {
					address
				} else {
					shown.first
				},
				last: address,
			}
		}
	}
}

shown_observation : Tx, U32, U16, U8, [Absent, Present(Str)] -> Tx
shown_observation = |tx, node, hole, property, value| {
	if property != 6 and property != 7 {
		return tx
	}
	shown_fact(tx, node, hole, property, observed_text(value))
}

shown_fact : Tx, U32, U16, U8, Str -> Tx
shown_fact = |tx, node, hole, property, value| {
	if property != 6 and property != 7 {
		return tx
	}
	{ ..tx, observations: { ..tx.observations, shown: tx.observations.shown.append(SetShown({ node, hole, property, value })) } }
}

shown_since : ShownMap, U64, Tx -> ShownMap
shown_since = |shown, start, tx| {
	var $shown = shown
	var $i = start
	while $i < tx.observations.shown.len() {
		match tx.observations.shown.get($i) ?? crash "shown change" {
			DropShown(node) => {
				keys = $shown.owners.get(node) ?? []
				$shown = { ..$shown, owners: $shown.owners.remove(node) }
				for address in keys {
					$shown = shown_unlink($shown, address)
				}
			}
			SetShown(fact) => {
				$shown = if fact.value == "hidden" or fact.value == "false" {
					shown_remove($shown, fact.node, fact.hole)
				} else {
					shown_record($shown, fact)
				}
			}
		}
		$i = $i + 1
	}
	$shown
}

clear_row_echo : [NoEcho, Echo({ slot : U32, hole : U64 })], U32 -> [NoEcho, Echo({ slot : U32, hole : U64 })]
clear_row_echo = |pending, slot| match pending {
	Echo(e) if e.slot == slot => NoEcho
	_ => pending
}

## Record the browser fact before invoking the one typed handler. The row's
## ordinary dirty queue settles this one hole even when no layer was written.
row_echo : Cols(r, item), Plan(r), U32, RoutedHandler(r), Payload, List(U32), Tx -> (Cols(r, item), Payload, Tx)
row_echo = |cols, plan, slot, handler, payload, path, tx| match handler.echo {
	NoEcho => (cols, payload, tx)
	Echo(echo) => {
		open = (open_kind.decode)(payload, path)
		value = if open {
			echo.showing
		} else if echo.property == 6 {
			"hidden"
		} else {
			"false"
		}
		hole = plan.holes.get(echo.hole) ?? crash "paired row shown hole"
		si = slot.to_u64()
		{ items, keys, order, free, index, lasts, kids, binds, pend, dirty, sels, known, kid_mask, dropped, shown, pending_echo: _, rnodes } = cols
		{ list: columns, prev: column } = lasts.replace(hole.col, []) ?? crash "paired row shown column"
		lasts2 = columns.set(hole.col, column.set(si, Present(value)) ?? crash "paired row shown slot") ?? crash "paired row shown column"
		node = rnodes.get(si) ?? crash "paired row node"
		start = tx.observations.shown.len()
		t2 = shown_fact(tx, node, echo.hole.to_u16_wrap(), echo.property, value)
		{ list: maps, prev: row_shown } = shown.replace(si, shown_empty) ?? crash "shown column"
		shown2 = maps.set(si, shown_since(row_shown, start, t2)) ?? crash "shown column"
		dirty2 = if (pend.get(si) ?? 0) == 0 {
			dirty.append(slot)
		} else {
			dirty
		}
		({ items, keys, order, free, index, lasts: lasts2, kids, binds, pend, dirty: dirty2, sels, known, kid_mask, dropped, shown: shown2, pending_echo: Echo({ slot, hole: echo.hole }), rnodes }, OpenState(open), { ..t2, observations: { ..t2.observations, echo: True } })
	}
}

## Moving a row can remove its descendants from the browser's top layer.
## Reassert only the live shown descendants this row owns, after its MOVE.
move_row : Cols(r, item), U32, U32, Tx -> Tx
move_row = |cols, slot, before, tx| {
	node = node_of(cols, slot)
	var $tx = emit_op(tx, 4, |c| put_u32(put_u32(c, node), before))
	shown = cols.shown.get(slot.to_u64()) ?? shown_empty
	var $address = shown.first
	while $address != 0 {
		entry = shown.entries.get($address) ?? crash "shown move link"
		$tx = if entry.hole == 256 {
			emit_op($tx, 21, |c| put_str(put_u32(c, entry.node).append(entry.property), entry.value))
		} else {
			emit_op($tx, 22, |c| put_str(put_u32(c, entry.node).append(entry.hole.to_u8_wrap()), entry.value))
		}
		$address = entry.next
	}
	$tx
}

## Typed row columns, indexed by slot (except `order`, by position, and
## `sels`, by hole). An `each` site and a view site hold the same columns.
## `keys` and `index` are an `each` site's: each row's text key and the
## index that finds a row by it. A view site's rows have an empty text key
## and are never in `index`; the site finds them by the table's key in an
## index of its own (`view_inst`).
Cols(r, item) : {
	items : List(item),
	keys : List(Str),
	order : List(U32),
	free : List(U32),
	index : KeyIndex,
	lasts : List(List([Absent, Present(Str)])),
	kids : List(List(Inst(r))),
	binds : List(List(U32)),
	pend : List(U128),
	dirty : List(U32),
	sels : List(Str),
	known : Bool,
	kid_mask : U128,

	## Rows dropped since the site last took them, with the orphans their
	## nested sites left (admitted requests that outlive the row).
	dropped : List({ key : Str, item : item, orphans : List(Orphan(r)) }),

	## The host node id of each slot's row element (dense node ids,
	## shared with static nodes; routes map them back to site and slot),
	## or 0 for a slot that holds no row (`is_live`).
	shown : List(ShownMap),
	pending_echo : [NoEcho, Echo({ slot : U32, hole : U64 })],
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
	shown: [],
	pending_echo: NoEcho,
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

## Create one row of an `each` site before `before`: index its key, then
## place it. Returns the slot.
create_row : EachCfg(r, (item -> Str)), Cols(r, item), (Str, item -> r), item, U32, Tx -> (Cols(r, item), U32, Tx)
	where [item.is_eq : item, item -> Bool]
create_row = |cfg, cols, env, item, before, tx| create_row_h(cfg, cols, env, item, before, Err(Unhashed), tx)

## `create_row` given the key's hash when a lookup already computed it.
create_row_h : EachCfg(r, (item -> Str)), Cols(r, item), (Str, item -> r), item, U32, Try(U64, [Unhashed]), Tx -> (Cols(r, item), U32, Tx)
	where [item.is_eq : item, item -> Bool]
create_row_h = |cfg, cols, env, item, before, known_hash, tx| {
	key = (cfg.key)(item)
	(h, hashes) = match known_hash {
		Ok(kh) => (kh, 0)
		Err(Unhashed) => (hash_str(key), 1)
	}
	slot = next_slot(cols)
	{ items, keys, order, free, index, lasts, kids, binds, pend, dirty, sels, known, kid_mask, dropped, shown, pending_echo, rnodes } = cols
	# The index compares with the keys of the rows it holds, never with the
	# slot this row is about to take, so the key column need not hold the
	# new key yet.
	(index2, compares) = index_insert(index, keys, key, h, slot, cfg.path)
	indexed = { items, keys, order, free, index: index2, lasts, kids, binds, pend, dirty, sels, known, kid_mask, dropped, shown, pending_echo, rnodes }
	place_row(cfg, indexed, env, item, key, before, { hashes, compares }, tx)
}

## The slot the next row placed takes: the last one freed, or a new one.
next_slot : Cols(r, item) -> U32
next_slot = |cols| match cols.free.last() {
	Ok(slot) => slot
	Err(_) => cols.items.len().to_u32_wrap()
}

## Place one row at `next_slot`: fill its columns, emit INST before
## `before` and mount its nested sites. Returns the slot. It does not touch
## the key index: the site that knows how its rows are found does that, an
## `each` site by the row's text `key` (`create_row`) and a view site by the
## table's key (`view_apply`), for which `key` is empty. `keyed` is the key
## index work to count with the row.
place_row : EachCfg(r, find), Cols(r, item), (Str, item -> r), item, Str, U32, { hashes : U64, compares : U64 }, Tx -> (Cols(r, item), U32, Tx)
place_row = |cfg, cols, env, item, key, before, keyed, tx| {
	shown_start = tx.observations.shown.len()
	{ items, keys, order, free, index, lasts, kids, binds, pend, dirty, sels, known, kid_mask, dropped, shown, pending_echo, rnodes } = cols
	(slot, free2) = match free.last() {
		Ok(s) => (s, free.drop_last(1))
		Err(_) => (items.len().to_u32_wrap(), free)
	}
	si = slot.to_u64()
	keys2 = put_at(keys, si, key)
	items2 = put_at(items, si, item)
	pend2 = put_at(pend, si, 0)
	(node, tx0) = alloc_id(tx)
	rnodes2 = put_at(rnodes, si, node)
	row_env = env(key, item)
	{ cmds, next, free: idfree, routes, work, paths, site_free, observations, fx } = set_row_route(tx0, node, cfg.site, slot)
	command_at = cmds.len()
	var $c = put_u32(put_u32(put_u32(put_u32(cmds.append(1), node), cfg.parent), before), cfg.site)
	var $lasts = lasts
	var $sels = sels
	var $ev = 0.U64
	# Control properties carried by INST count as set, like PROP would.
	var $set_value = 0.U64
	var $set_checked = 0.U64
	var $t = { cmds: [], next, free: idfree, routes, work, paths, site_free, observations, fx }
	var $bound = List.repeat(0.U32, cfg.plan.mounts.len())
	var $hi = 0.U64
	for hole in cfg.plan.holes {
		if hole.kind == 1 or hole.kind == 2 or hole.kind == 6 {
			v = (hole.read)(row_env)
			$t = shown_observation($t, node, $hi.to_u16_wrap(), hole.property, v)
			$ev = $ev + if (hole.evaluated) 1 else 0
			if hole.ctl == w_set_value {
				$set_value = $set_value + 1
			} else if hole.ctl == w_set_checked {
				$set_checked = $set_checked + 1
			}
			$c = if (hole.kind == 2) put_presence($c, v) else put_str($c, observed_text(v))
			if hole.live {
				{ list, prev } = $lasts.replace(hole.col, []) ?? crash "lasts"
				$lasts = list.set(hole.col, put_at(prev, si, v)) ?? crash "lasts"
			}
			if hole.smask != 0 and !known {
				$sels = $sels.set($hi, (hole.skey)(row_env)) ?? $sels
			}
		} else if hole.kind == 5 {
			(bid, t2) = alloc_id($t)
			name = observed_text((hole.read)(row_env))
			$t = with_fx(t2, |fx2| add_ref(fx2, { name, node: bid, path: cfg.path.concat([slot, $hi.to_u32_wrap()]), value_control: hole.value_control }))
			$c = put_u32($c, bid)
			$bound = $bound.append(bid)
			$ev = $ev + if (hole.evaluated) 1 else 0
			if hole.live {
				{ list, prev } = $lasts.replace(hole.col, []) ?? crash "lasts"
				$lasts = list.set(hole.col, put_at(prev, si, Present(name))) ?? crash "lasts"
			}
			if hole.smask != 0 and !known {
				$sels = $sels.set($hi, (hole.skey)(row_env)) ?? $sels
			}
		} else if hole.is_observation {
			$t = observe_node($t, node)
		} else if hole.kind == 4 {
			(bid, t2) = alloc_id($t)
			$t = t2
			$c = put_u32($c, bid)
			$bound = $bound.set(hole.col, bid) ?? crash "internal: bind index"
		}
		$hi = $hi + 1
	}
	known2 = known or cfg.sel_mask != 0
	{ cmds: _, next: n3, free: f3, routes: r3, work: w3, paths: p3, site_free: sf3, observations: ob3, fx: fx3 } = $t
	# One INST (a row and its scope created), its hole evaluations and the
	# key index work of the site that placed it.
	w4 = add_work(add_work(add_work(add_work(add_work(add_work(add_work(w3, 1, 1), w_evals, $ev), w_scopes_created, 1), w_key_hashes, keyed.hashes), w_key_compares, keyed.compares), w_set_value, $set_value), w_set_checked, $set_checked)
	captured = with_capture(
		fx3,
		|capture| {
			if !PictureCapture.is_collecting(capture) {
				return capture
			}
			var $capture = PictureCapture.command(capture, { at: command_at, end: $c.len(), opcode: 1, address: node, slot: cfg.site })
			var $hole = 0.U32
			var $reference = cfg.plan.mounts.len()
			for hole in cfg.plan.holes {
				if hole.kind == 4 or hole.kind == 5 {
					alias_index = if (hole.kind == 4) hole.col else $reference
					address = $bound.get(alias_index) ?? crash "internal: captured INST alias is allocated"
					$capture = PictureCapture.alias($capture, { at: command_at, end: $c.len(), address, hole: $hole, kind: hole.kind })
					if hole.kind == 5 {
						$reference = $reference + 1
					}
				}
				$hole = $hole + 1
			}
			$capture
		},
	)
	var $tx = { cmds: $c, next: n3, free: f3, routes: r3, work: w4, paths: p3, site_free: sf3, observations: ob3, fx: captured }
	if cfg.dynamic {
		var $insts = []
		var $km = kid_mask
		var $j = 0.U64
		for m in cfg.plan.mounts {
			mount = match m {
				Mount(f) => f
			}
			bid = $bound.get($j) ?? crash "bind"
			(inst, reads, t4) = mount(row_env, { depth: cfg.depth, path: cfg.path.concat([slot, $j.to_u32_wrap()]), parent: 0, before: bid, sole: False, cap: cfg.plan.kreads.bitwise_or(upto(cfg.depth).bitwise_not()), enclosing: root_enclosing }, $tx)
			$insts = $insts.append(inst)
			$km = $km.bitwise_or(reads)
			$tx = t4
			$j = $j + 1
		}
		cols2 = { items: items2, keys: keys2, order, free: free2, index, lasts: $lasts, kids: put_at(kids, si, $insts), binds: put_at(binds, si, $bound), pend: pend2, dirty, sels: $sels, known: known2, kid_mask: $km, dropped, shown: put_at(shown, si, shown_since(shown_empty, shown_start, $tx)), pending_echo, rnodes: rnodes2 }
		(cols2, slot, $tx)
	} else {
		cols2 = { items: items2, keys: keys2, order, free: free2, index, lasts: $lasts, kids, binds, pend: pend2, dirty, sels: $sels, known: known2, kid_mask, dropped, shown: put_at(shown, si, shown_since(shown_empty, shown_start, $tx)), pending_echo, rnodes: rnodes2 }
		(cols2, slot, $tx)
	}
}

## Remove one row of an `each` site: take its key out of the index, then
## release the row. `remove` emits REMOVE.
drop_row : EachCfg(r, find), Cols(r, item), (Str, item -> r), U32, Bool, Tx -> (Cols(r, item), Tx)
drop_row = |cfg, cols, env, slot, remove, tx| {
	{ items, keys, order, free, index, lasts, kids, binds, pend, dirty, sels, known, kid_mask, dropped, shown, pending_echo, rnodes } = cols
	unindexed = { items, keys, order, free, index: index_remove(index, slot), lasts, kids, binds, pend, dirty, sels, known, kid_mask, dropped, shown, pending_echo, rnodes }
	remove_row(cfg, unindexed, env, slot, remove, tx)
}

## Release one row's storage and nested sites, and forget its node, which
## is what marks its slot as holding no row (`is_live`). `remove` emits
## REMOVE. Like `place_row`, it leaves the key index to the site.
remove_row : EachCfg(r, find), Cols(r, item), (Str, item -> r), U32, Bool, Tx -> (Cols(r, item), Tx)
remove_row = |cfg, cols, env, slot, remove, tx| {
	{ items, keys, order, free, index, lasts, kids, binds, pend, dirty, sels, known, kid_mask, dropped, shown, pending_echo, rnodes: nodes } = cols
	si = slot.to_u64()
	key = keys.get(si) ?? crash "key"
	pend2 = pend.set(si, 0) ?? pend
	node = nodes.get(si) ?? crash "internal: row node"
	rnodes = nodes.set(si, 0) ?? nodes
	# Child scopes and their registrations are disposed before the row's DOM.
	t1 = bump(bump(tx, w_rows_removed, 1), w_scopes_disposed, 1)
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
		$t = release_node($t, node)
		$t = if (remove) emit_op($t, 5, |commands| put_u32(commands, node)) else $t
		$t = free_id($t, node)
		dropped2 = if ($orph.is_empty()) dropped else dropped.append({ key, item, orphans: $orph })
		({ items, keys, order, free: free.append(slot), index, lasts, kids: kl, binds: bl, pend: pend2, dirty, sels, known, kid_mask, dropped: dropped2, shown: shown.set(si, shown_empty) ?? shown, pending_echo: clear_row_echo(pending_echo, slot), rnodes }, $t)
	} else {
		released = release_node(t1, node)
		removed = if (remove) emit_op(released, 5, |commands| put_u32(commands, node)) else released
		({ items, keys, order, free: free.append(slot), index, lasts, kids, binds, pend: pend2, dirty, sels, known, kid_mask, dropped, shown, pending_echo, rnodes }, free_id(removed, node))
	}
}

mark_all : Cols(r, item), U128 -> Cols(r, item)
mark_all = |cols, m| {
	(c0, order) = take_order(cols)
	var $c = c0
	for s in order {
		$c = mark($c, s, m)
	}
	set_order($c, order)
}

mark : Cols(r, item), U32, U128 -> Cols(r, item)
mark = |{ items, keys, order, free, index, lasts, kids, binds, pend, dirty, sels, known, kid_mask, dropped, shown, pending_echo, rnodes }, slot, m| {
	si = slot.to_u64()
	p = pend.get(si) ?? 0
	already_echo = match pending_echo {
		Echo(e) => e.slot == slot
		NoEcho => False
	}
	dirty2 = if (p == 0 and !already_echo) dirty.append(slot) else dirty
	{ items, keys, order, free, index, lasts, kids, binds, pend: pend.set(si, p.bitwise_or(m)) ?? pend, dirty: dirty2, sels, known, kid_mask, dropped, shown, pending_echo, rnodes }
}

## A kept row whose new item may differ: equal items are pruned here.
## Returns 1 when the item changed (the row is marked dirty).
keep_row_n : Cols(r, item), U32, item, U128 -> (Cols(r, item), U64)
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
		{ items, keys, order, free, index, lasts, kids, binds, pend, dirty, sels, known, kid_mask, dropped, shown, pending_echo, rnodes } = cols
		(mark({ items: items.set(si, item) ?? crash "item", keys, order, free, index, lasts, kids, binds, pend, dirty, sels, known, kid_mask, dropped, shown, pending_echo, rnodes }, slot, row_bit), 1)
	}
}

set_order : Cols(r, item), List(U32) -> Cols(r, item)
set_order = |{ items, keys, order: _, free, index, lasts, kids, binds, pend, dirty, sels, known, kid_mask, dropped, shown, pending_echo, rnodes }, order| {
	{ items, keys, order, free, index, lasts, kids, binds, pend, dirty, sels, known, kid_mask, dropped, shown, pending_echo, rnodes }
}

take_order : Cols(r, item) -> (Cols(r, item), List(U32))
take_order = |{ items, keys, order, free, index, lasts, kids, binds, pend, dirty, sels, known, kid_mask, dropped, shown, pending_echo, rnodes }| {
	({ items, keys, order: [], free, index, lasts, kids, binds, pend, dirty, sels, known, kid_mask, dropped, shown, pending_echo, rnodes }, order)
}

end_ref : EachCfg(r, find) -> U32
end_ref = |cfg| if (cfg.sole) 0 else cfg.anchor

## The node a row inserted at position `pos` (of `order`) goes before.
ref_at : EachCfg(r, find), Cols(r, item), U64 -> U32
ref_at = |cfg, cols, pos| match cols.order.get(pos) {
	Ok(s) => node_of(cols, s)
	Err(_) => end_ref(cfg)
}

key_of_slot : Cols(r, item), U32 -> Str
key_of_slot = |cols, slot| cols.keys.get(slot.to_u64()) ?? crash "key"

same_row : EachCfg(r, (item -> Str)), Cols(r, item), U32, item -> Bool
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
		$tx = free_id(release_node($tx, node_of(cols, slot)), node_of(cols, slot))
	}
	$tx
}

## Remove every row.
clear_rows : EachCfg(r, find), Cols(r, item), (Str, item -> r), Bool, Tx -> (Cols(r, item), Tx)
clear_rows = |cfg, cols, env, dom, tx| {
	var $tx = bump(tx, w_scopes_disposed, cols.order.len())
	var $dropped = []
	if cfg.dynamic {
		var $i = 0.U64
		while $i < cols.kids.len() {
			live = if (is_live(cols, $i)) cols.items.get($i).map_err(|_| Dead) else Err(Dead)
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
	for slot in cols.order {
		$tx = release_node($tx, node_of(cols, slot))
	}

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
	{ sels, known, kid_mask, lasts, dropped: dropped0, shown: _, pending_echo: _, items: _, keys: _, order: _, free: _, index: _, kids: _, binds: _, pend: _, dirty: _, rnodes: _ } = cols
	dropped = dropped0.concat($dropped)
	ncols = lasts.len()
	({ items: [], keys: [], order: [], free: [], index: index_empty, lasts: List.repeat([], ncols), kids: [], binds: [], pend: [], dirty: [], sels, known, kid_mask, dropped, shown: [], pending_echo: NoEcho, rnodes: [] }, $tx)
}

## Append rows new_list[from..] at the end of the site.
append_rows : EachCfg(r, (item -> Str)), Cols(r, item), (Str, item -> r), List(item), U64, Tx -> (Cols(r, item), Tx)
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
reconcile : EachCfg(r, (item -> Str)), Cols(r, item), (Str, item -> r), List(item), Tx -> (Cols(r, item), Tx)
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

reconcile_rows : EachCfg(r, (item -> Str)), Cols(r, item), (Str, item -> r), List(item), Tx -> (Cols(r, item), Tx)
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
					after = ref_at(cfg, $cols, $oe)
					$tx = move_row($cols, a, after, move_row($cols, b, na, $tx))
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
reconcile_general : EachCfg(r, (item -> Str)), Cols(r, item), (Str, item -> r), List(item), U64, U64, U64, Tx -> (Cols(r, item), Tx)
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
				$tx = move_row($cols, slot, r, $tx)
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
settle : EachCfg(r, find), Cols(r, item), (Str, item -> r), Tx -> (Cols(r, item), Tx)
settle = |cfg, cols, env, tx| {
	{ items, keys, order, free, index, lasts, kids, binds, pend, dirty, sels, known, kid_mask, dropped, shown, pending_echo, rnodes } = cols
	var $lasts = lasts
	var $pend = pend
	var $kids = kids
	var $shown = shown
	var $tx = tx
	# Hole evaluations, counted once after the loop.
	var $evals = 0.U64
	for slot in dirty {
		start = $tx.observations.shown.len()
		si = slot.to_u64()
		m = $pend.get(si) ?? 0
		$pend = $pend.set(si, 0) ?? $pend
		key = keys.get(si) ?? crash "key"
		item = items.get(si) ?? crash "item"
		row_env = env(key, item)
		node = rnodes.get(si) ?? crash "internal: row node"
		var $hi = 0.U64
		for hole in cfg.plan.holes {
			echo_dirty = match pending_echo {
				NoEcho => False
				Echo(e) => e.slot == slot and e.hole == $hi
			}
			if hole.live and (echo_dirty or hole.mask.bitwise_or(hole.smask).bitwise_and(m) != 0) {
				v = (hole.read)(row_env)
				{ list, prev } = $lasts.replace(hole.col, []) ?? crash "lasts"
				old = prev.get(si) ?? crash "internal: missing row hole observation"
				$evals = $evals + 1
				if v == old {
					$lasts = list.set(hole.col, prev) ?? crash "lasts"
				} else {
					if hole.kind == 5 {
						id = (binds.get(si) ?? []).get(cfg.plan.mounts.len() + hole.ctl) ?? crash "internal: reference binding"
						$tx = with_fx($tx, |fx| add_ref(drop_name(fx, { node: id, name: observed_text(old), path: cfg.path.concat([slot, $hi.to_u32_wrap()]) }), { name: observed_text(v), node: id, path: cfg.path.concat([slot, $hi.to_u32_wrap()]), value_control: hole.value_control }))
					} else {
						op = if (hole.kind == 1) 2 else if (hole.kind == 6) 22 else 3
						hidx = $hi.to_u8_wrap()
						$tx = shown_observation(emit_op(bump($tx, hole.ctl, 1), op, |c| if (hole.kind == 2) put_presence(put_u32(c, node).append(hidx), v) else put_str(put_u32(c, node).append(hidx), observed_text(v))), node, $hi.to_u16_wrap(), hole.property, v)
					}
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
		{ list: maps, prev: row_shown } = $shown.replace(si, shown_empty) ?? crash "shown column"
		$shown = maps.set(si, shown_since(row_shown, start, $tx)) ?? crash "shown column"
	}
	({ items, keys, order, free, index, lasts: $lasts, kids: $kids, binds, pend: $pend, dirty: dirty.clear(), sels, known, kid_mask, dropped, shown: $shown, pending_echo: NoEcho, rnodes }, count_evals($tx, $evals))
}

## Selection changed: mark only the previously and newly selected rows.
select_changed : EachCfg(r, find), Cols(r, item), (Str, item -> r), U128 -> Cols(r, item)
select_changed = |cfg, cols, env, mask| {
	first = cols.order.first()
	match first {
		Err(_) => {
			{ items, keys, order, free, index, lasts, kids, binds, pend, dirty, sels, known: _, kid_mask, dropped, shown, pending_echo, rnodes } = cols
			{ items, keys, order, free, index, lasts, kids, binds, pend, dirty, sels, known: False, kid_mask, dropped, shown, pending_echo, rnodes }
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
						{ items, keys, order, free, index, lasts, kids, binds, pend, dirty, sels, known: _, kid_mask, dropped, shown, pending_echo, rnodes } = $cols
						$cols = { items, keys, order, free, index, lasts, kids, binds, pend, dirty, sels: sels.set($hi, nk) ?? sels, known: True, kid_mask, dropped, shown, pending_echo, rnodes }
					}
				}
				$hi = $hi + 1
			}
			$cols
		}
	}
}

## Whether slot `si` holds a row: a row that was removed has no node
## (`remove_row`), and node 0 is the host's, never a row's.
is_live : Cols(r, item), U64 -> Bool
is_live = |cols, si| (cols.rnodes.get(si) ?? 0) != 0

## Route an event into nested site `path[pos + 1]` of row slot `si`.
## Takes the columns owned and hands back only the outer environment, so
## nothing that references the columns or the row item is alive when the
## site is rebuilt (roc-lang/roc#12846 class).
each_fire_kid : Cols(Row(ctx, item), item), Row(ctx, item), U64, List(U32), U64, U32, Payload, Tx -> (Cols(Row(ctx, item), item), ctx, Layers, Tx)
each_fire_kid = |cols, row_env, si, path, pos, h, payload, tx| {
	start = tx.observations.shown.len()
	j = (path.get(pos + 1) ?? 0).to_u64()
	{ items, keys, order, free, index, lasts, kids, binds, pend, dirty, sels, known, kid_mask, dropped, shown, pending_echo, rnodes } = cols
	{ list: kl, prev: row_kids } = kids.replace(si, []) ?? crash "kids"
	if j < row_kids.len() {
		{ list: rl, prev: kid } = row_kids.replace(j, noop({})) ?? crash "kid"
		(k2, out, t2) = call(kid, row_env, Fire(path, pos + 2, h, payload), tx)
		kids2 = kl.set(si, rl.set(j, k2) ?? crash "kid") ?? crash "kids"
		(outer, m) = row_out(out)
		{ list: maps, prev: row_shown } = shown.replace(si, shown_empty) ?? crash "shown column"
		shown2 = maps.set(si, shown_since(row_shown, start, t2)) ?? crash "shown column"
		({ items, keys, order, free, index, lasts, kids: kids2, binds, pend, dirty, sels, known, kid_mask, dropped, shown: shown2, pending_echo, rnodes }, outer, m, t2)
	} else {
		{ outer, key: _, item: _ } = row_env
		({ items, keys, order, free, index, lasts, kids: kl.set(si, row_kids) ?? crash "kids", binds, pend, dirty, sels, known, kid_mask, dropped, shown, pending_echo, rnodes }, outer, no_layers, tx)
	}
}

row_out : Out(Row(ctx, item)) -> (ctx, Layers)
row_out = |out| match out {
	Pending(e2, m) => {
		{ outer, key: _, item: _ } = e2
		(outer, m)
	}
	Done => crash "internal: fire must hand the environment back"
	Orphaned(_) => crash "internal: fire must hand the environment back"
}

## `adopted`: orphans reparented here from removed rows.
each_inst : EachCfg(Row(ctx, item), (item -> Str)), Signal(ctx, List(item)), List(Orphan(ctx)), Cols(Row(ctx, item), item) -> Inst(ctx)
	where [item.is_eq : item, item -> Bool]
each_inst = |cfg0, rows0, adopted0, cols0| {
	held = { cfg: cfg0, rows: rows0, adopted: adopted0, cols: cols0 }
	Inst(
		|env, msg, tx| {
			{ cfg, rows, adopted, cols } = held
			mk = |k, it| Row.{ outer: env, key: k, item: it }
			match msg {
				Changed(mask) => {
					# Mark existing rows first (outer layers, then the keyed selector),
					# then reconcile: rows created now are evaluated once, at creation;
					# rows removed now drop their marks. Rows settle their own layer
					# locally, so `every_layer` reaches into them whole.
					full = if (mask == every_layer) every_layer else mask.bitwise_and(cfg.outer_mask.bitwise_or(cols.kid_mask)).bitwise_and(above_bits(cfg.depth))
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
						# No such row any more, or a `Settle` come as far as a row's
						# handler: nothing to run.
						(each_inst(cfg, rows, adopted, cols), Pending(env, no_layers), tx)
					} else {
						key = cols.keys.get(si) ?? crash "key"
						item = cols.items.get(si) ?? crash "item"
						row_env = Row.{ outer: env, key, item }
						if pos + 1 >= path.len() and !fires(payload) {
							(c2, t2) = settle(cfg, cols, mk, tx)
							(each_inst(cfg, rows, adopted, c2), Pending(env, no_layers), t2)
						} else if pos + 1 >= path.len() {
							match cfg.plan.handlers.get(h.to_u64()) {
								Ok(handler) => {
									# Rebuild the site before running the row handler: with the
									# handler call first, --opt=speed/size treats the captured
									# columns as borrowed and every later write copies them
									# (roc-lang/roc#12846).
									(c2, prepared, t2) = row_echo(cols, cfg.plan, slot, handler, payload, cfg.path, tx)
									next = each_inst(cfg, rows, adopted, c2)
									(row, wrote) = (handler.run)(row_env, prepared, cfg.path)
									{ outer, key: _, item: _ } = row
									(next, Pending(outer, wrote), t2)
								}
								Err(_) => {
									{ outer, key: _, item: _ } = row_env
									(each_inst(cfg, rows, adopted, cols), Pending(outer, no_layers), tx)
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
## The view site (`table_view`): rows like an `each` site's, drawn from the
## window of a view the site owns instead of from a list, and found by the
## table's key instead of by a text key.

## The value a table's bookkeeping asks for: what makes this module the
## The chunk size of a view's ordered keys (see `Seq`).
view_chunk : U64
view_chunk = 1024

## Fixed per view site: the table's getter, the query and how it selects
## and orders rows, and the window.
Shows(ctx, q, k, v, s) : { get : (ctx -> Table(k, v)), query : Signal(ctx, q), plan : (q -> Core.QueryPlan(k, v, s)), window : Signal(ctx, Core.Window) }

## How a scope reads the table a view draws: through its reach of the
## store, then the table's cell.
##
## A function of its own because of a compiler defect: written as a
## lambda inside `table_view`, its closure goes into the view site, whose
## instance calls itself from several branches, and `roc check` of an app
## that reaches the site does not finish (roc-lang/roc#12869, fixed in
## compilers after the pinned nightly).
view_source : Core.Cell(st, Table(k, v)) -> (ctx -> Table(k, v))
	where [ctx.store : () -> Core.StoreReach(ctx, st)]
view_source = |source| {
	## The context's type, named so its method can be called.
	Ctx : ctx
	store_get = Ctx.store().get
	cell_get = source.get
	|e| cell_get(store_get(e))
}

## A view row's key. It is fixed for the row's lifetime, so it never
## triggers a refresh.
view_key : {} -> Signal(Row(ctx, k), k)
view_key = |_| { mask: 0, read: |e| e.item, sel: NoSel }

## A handle on a view row's value. A read is the row of the row's key in
## the table, and reads the row's layer: the site marks the rows whose
## value a turn wrote, so a write of one row re-evaluates that row's holes
## and no other row's. A write is `Table.update` of that key through the
## table's cell, so it is recorded like any other keyed write and reports
## the cell as written.
view_row : Cell(st, Table(k, v)), U64, List(U32) -> State(Row(ctx, k), v)
	where [ctx.store : () -> Core.StoreReach(ctx, st), k.is_eq : k, k -> Bool, k.to_hash : k, Hasher -> Hasher]
view_row = |source, depth, path| {
	## The enclosing scope's type, named so its method can be called.
	Ctx : ctx
	reach = Ctx.store()
	store_get = reach.get
	store_over = reach.over
	get = source.get
	modify = source.modify
	{
		mask: bit(depth),
		writes: one_cell(source.cell),
		get: |e| match get(store_get(e.outer)).get(e.item) {
			Ok(row) => row
			Err(Missing) => crash "contract: a drawn row of the table_view at site ${show_path(path)} was read after its key left the table: a handler that removes a row must not read that row afterwards in the same event"
		},
		modify: |e, f| {
			{ outer, key, item } = e
			Row.{ outer: store_over(outer, |st| modify(st, |table| table.update(item, f))), key, item }
		},
	}
}

## The slot of the mounted row of `key`, from the site's index of its rows
## by the table's key.
view_slot : Dict(k, U32), k -> U32
	where [k.is_eq : k, k -> Bool, k.to_hash : k, Hasher -> Hasher]
view_slot = |slots, key| match slots.get(key) {
	Ok(slot) => slot
	Err(_) => crash "internal: a view's window names a row that is not mounted (key ${Str.inspect(key)})"
}

## The node a row placed before `before` goes before.
view_before : EachCfg(r, {}), Cols(r, k), Dict(k, U32), [Row(k), End] -> U32
	where [k.is_eq : k, k -> Bool, k.to_hash : k, Hasher -> Hasher]
view_before = |cfg, cols, slots, before| match before {
	End => end_ref(cfg)
	Row(key) => node_of(cols, view_slot(slots, key))
}

## Place the rows of `keys`, in order, at the end of an empty view site,
## and index each by its key.
view_enter : EachCfg(r, {}), Cols(r, k), (Str, k -> r), List(k), Tx -> (Cols(r, k), Dict(k, U32), Tx)
	where [k.is_eq : k, k -> Bool, k.to_hash : k, Hasher -> Hasher]
view_enter = |cfg, cols, env, keys, tx| {
	var $cols = cols
	var $slots = Dict.with_capacity(keys.len())
	var $tx = tx
	before = end_ref(cfg)
	for key in keys {
		(c2, slot, t2) = place_row(cfg, $cols, env, key, "", before, { hashes: 0, compares: 0 }, $tx)
		(c3, order) = take_order(c2)
		$cols = set_order(c3, order.append(slot))
		$slots = $slots.insert(key, slot)
		$tx = t2
	}
	($cols, $slots, $tx)
}

## Apply a window's changes to the site's rows, in order: remove a row that
## left, create one that entered, move one that moved, and mark one whose
## value was written so its holes are re-evaluated when the rows settle.
## `view` is the view after the changes; its window gives the rows' order.
## `slots` finds each row by the table's key, and follows the rows that
## leave and enter.
view_apply : EachCfg(r, {}), Cols(r, k), Dict(k, U32), (Str, k -> r), View(k, v, s), List([Left(k), Entered({ key : k, before : [Row(k), End] }), Moved({ key : k, before : [Row(k), End] }), Changed(k)]), Tx -> (Cols(r, k), Dict(k, U32), Tx)
	where [k.is_eq : k, k -> Bool, k.to_hash : k, Hasher -> Hasher]
view_apply = |cfg, cols, slots, env, view, changes, tx| {
	if changes.is_empty() {
		(cols, slots, tx)
	} else {
		var $cols = cols
		var $slots = slots
		var $tx = tx
		var $placed = False
		var $written = 0.U64
		for change in changes {
			match change {
				Left(key) => {
					(c2, t2) = remove_row(cfg, $cols, env, view_slot($slots, key), True, $tx)
					$cols = c2
					$slots = $slots.remove(key)
					$tx = t2
					$placed = True
				}
				Entered({ key, before }) => {
					(c2, slot, t2) = place_row(cfg, $cols, env, key, "", view_before(cfg, $cols, $slots, before), { hashes: 0, compares: 0 }, $tx)
					$cols = c2
					$slots = $slots.insert(key, slot)
					$tx = t2
					$placed = True
				}
				Moved({ key, before }) => {
					slot = view_slot($slots, key)
					target = view_before(cfg, $cols, $slots, before)
					$tx = move_row($cols, slot, target, $tx)
					$placed = True
				}
				Changed(key) => {
					$cols = mark($cols, view_slot($slots, key), bit(cfg.depth))
					$written = $written + 1
				}
			}
		}
		placed = if $placed {
			(c2, _) = take_order($cols)
			found = $slots
			set_order(c2, view.shown_keys().map(|key| view_slot(found, key)))
		} else {
			$cols
		}
		(placed, $slots, bump($tx, w_rows_updated, $written))
	}
}

## One evaluation for a query or a window a pass read, none for one it
## did not.
view_read : Bool -> U64
view_read = |read| if (read) 1 else 0

## The settle check of a view site (`Core.settled`): the view as the site
## holds it must be the view a build from scratch gives now, for the query
## and the window as they read now, at the table's version, with the
## recording phase ready for the next turn, and its rows must be its window. A
## difference can only come from a turn that left the view behind; it is
## answered as what to report, or "" when there is none.
view_check : EachCfg(Row(ctx, k), {}), Shows(ctx, q, k, v, s), q, View(k, v, s), Cols(Row(ctx, k), k), Table(k, v), ctx -> Str
	where [k.is_eq : k, k -> Bool, k.to_hash : k, Hasher -> Hasher, q.is_eq : q, q -> Bool]
view_check = |cfg, shows, q, view, cols, table, env| {
	asked = (shows.query.read)(env)
	window = (shows.window.read)(env)
	fresh = View.build(table, { query: (shows.plan)(asked), window, limit: view_chunk, site: show_path(cfg.path) })
	drawn = cols.order.map(|slot| cols.items.get(slot.to_u64()) ?? crash "internal: a view row without its key")
	drift =
		if !TableCore.is_ready(table) {
			"its table was not rearmed when the last writing turn ended"
		} else if view.version() != TableCore.version(table) {
			"it is at version ${view.version().to_str()} of its table, which is at version ${TableCore.version(table).to_str()}"
		} else if asked != q {
			"it was not refreshed for a change of its query"
		} else if view.window_of() != window {
			"its window is ${Str.inspect(view.window_of())} but the window's value is ${Str.inspect(window)}"
		} else if view.keys() != fresh.keys() {
			"its ordered keys are not those of a view built from scratch: ${Str.inspect(view.keys().take_first(40))} against ${Str.inspect(fresh.keys().take_first(40))} (first 40)"
		} else if view.shown_keys() != fresh.shown_keys() {
			"its window is ${Str.inspect(view.shown_keys())} but a view built from scratch shows ${Str.inspect(fresh.shown_keys())}"
		} else if drawn != fresh.shown_keys() {
			"its rows are ${Str.inspect(drawn)} but its window is ${Str.inspect(fresh.shown_keys())}"
		} else {
			""
		}
	if (drift.is_empty()) "" else "the table_view at site ${show_path(cfg.path)} differs from its table: ${drift}"
}

## A view site. `slots` is the slot of each mounted row by the table's
## key: how the site finds the row a change of its window names. A view's
## row has no text key, so its context's `key` is empty. `adopted`: orphans
## reparented here from removed rows.
view_inst : EachCfg(Row(ctx, k), {}), Shows(ctx, q, k, v, s), q, View(k, v, s), List(Orphan(ctx)), Cols(Row(ctx, k), k), Dict(k, U32) -> Inst(ctx)
	where [k.is_eq : k, k -> Bool, k.to_hash : k, Hasher -> Hasher, q.is_eq : q, q -> Bool]
view_inst = |cfg0, shows0, q0, view0, adopted0, cols0, slots0| {
	held = { cfg: cfg0, shows: shows0, q: q0, view: view0, adopted: adopted0, cols: cols0, slots: slots0 }
	Inst(
		|env, msg, tx| {
			{ cfg, shows, q, view, adopted, cols, slots } = held
			mk = |_, key| Row.{ outer: env, key: "", item: key }
			match msg {
				Changed(mask) => {
					# Whatever the pass is for, the table first: every write of the
					# turn is in place, and when none was made it is a comparison of
					# two counts. Then the query and the window, and only then the
					# rows drawn, changed once from the window before to the window
					# after, so a row drawn before and after is one row throughout,
					# whatever the event wrote. Rows created now are evaluated once,
					# at creation; then the rows settle.
					all = mask == every_layer
					table = (shows.get)(env)
					# The settle check: a view that is not the one its table gives
					# is reported, and the pass (which is discarded) stops here for
					# this site, whose rows may name keys the table no longer has.
					drift = if (all) view_check(cfg, shows, q, view, cols, table, env) else ""
					if !drift.is_empty() {
						return (view_inst(cfg, shows, q, view, adopted, cols, slots), Done, with_fx(tx, |fx| { ..fx, focus: fx.focus.append(Drift(drift)) }))
					}
					full = if (all) every_layer else mask.bitwise_and(cfg.outer_mask.bitwise_or(cols.kid_mask)).bitwise_and(above_bits(cfg.depth))
					c1 = if (full != 0) mark_all(cols, full) else cols
					window = view.window_of()
					# `view` moves into `follow` and is not used again, so the ordered
					# keys are changed in place.
					{ view: v1, placed, reached, touched, wrote, .. } = view.follow(table)
					# The pass names what it brings of the query and the window. It
					# carries every write of the event that this site can read: a
					# layer written with the table joined the pass at its own site,
					# above this one (`waits_for_outer`). So the table, the query
					# and the window all arrive here together.
					names_query = all or eff_mask(shows.query).bitwise_and(mask) != 0
					names_window = all or eff_mask(shows.window).bitwise_and(mask) != 0
					q2 = if (names_query) (shows.query.read)(env) else q
					w2 = if (names_window) (shows.window.read)(env) else window
					draws = reached or (names_query and q2 != q) or (names_window and w2 != window)
					t1 = count_evals(tx, placed + view_read(names_query) + view_read(names_window))
					(v2, changes, t2) = if !draws {
						(v1, touched.map(|key| Changed(key)), t1)
					} else if q2 == q {
						drawn = v1.draw(table, { query: Same, window: w2, wrote })
						(drawn.view, drawn.changes, t1)
					} else {
						# A changed query places every row of the table again.
						drawn = v1.draw(table, { query: New((shows.plan)(q2)), window: w2, wrote })
						(drawn.view, drawn.changes, count_evals(t1, table.len()))
					}
					(c4, s4, t4) = view_apply(cfg, c1, slots, mk, v2, changes, t2)
					(c5, t5) = settle(cfg, c4, mk, t4)
					(c6, orph) = take_dropped(c5, cfg.depth)
					(view_inst(cfg, shows, q2, v2, adopted.concat(orph), c6, s4), Done, fx_adopt(t5, cfg.path, orph))
				}
				Fire(path, pos, h, payload) => {
					slot = path.get(pos) ?? 0
					si = slot.to_u64()
					fx = leaf_fx(path, pos, payload)
					if fx.is_ok() {
						res = fx ?? crash "fx"
						(ad2, out, t2) = adopt_deliver(adopted, env, h, res, tx)
						(view_inst(cfg, shows, q, view, ad2, cols, slots), out, t2)
					} else if !is_live(cols, si) {
						# No such row any more, or a `Settle` come as far as a row's
						# handler: nothing to run.
						(view_inst(cfg, shows, q, view, adopted, cols, slots), Pending(env, no_layers), tx)
					} else {
						key = cols.items.get(si) ?? crash "item"
						row_env = Row.{ outer: env, key: "", item: key }
						if pos + 1 >= path.len() and !fires(payload) {
							(c2, t2) = settle(cfg, cols, mk, tx)
							(view_inst(cfg, shows, q, view, adopted, c2, slots), Pending(env, no_layers), t2)
						} else if pos + 1 >= path.len() {
							match cfg.plan.handlers.get(h.to_u64()) {
								Ok(handler) => {
									# Rebuild the site before running the row handler, as
									# an each site does (roc-lang/roc#12846).
									(c2, prepared, t2) = row_echo(cols, cfg.plan, slot, handler, payload, cfg.path, tx)
									next = view_inst(cfg, shows, q, view, adopted, c2, slots)
									(row, wrote) = (handler.run)(row_env, prepared, cfg.path)
									{ outer, key: _, item: _ } = row
									(next, Pending(outer, wrote), t2)
								}
								Err(_) => {
									{ outer, key: _, item: _ } = row_env
									(view_inst(cfg, shows, q, view, adopted, cols, slots), Pending(outer, no_layers), tx)
								}
							}
						} else {
							(cols2, outer, m, t2) = each_fire_kid(cols, row_env, si, path, pos, h, payload, tx)
							(view_inst(cfg, shows, q, view, adopted, cols2, slots), Pending(outer, m), t2)
						}
					}
				}
				Dispose(remove) => {
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
elem_reads : Elem(ctx), U64 -> U128
elem_reads = |elem, depth| match elem {
	Element(_, attrs, kids) => {
		var $m = 0.U128
		for a in attrs {
			match a {
				Dyn(_, v) => {
					$m = $m.bitwise_or(eff_mask(v))
				}
				PropertyV(_, v) | Ref(v) => {
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
	Fragment(children) => children.fold(0, |mask, child| mask.bitwise_or(elem_reads(child, depth)))
	Text(_) | Comment(_) => 0
	Placed(_, child) => elem_reads(child, depth)
	TextV(v) => eff_mask(v)
	Site(_, rf) => rf(depth)
}

state_handle : U64 -> State(In(ctx, s), s)
state_handle = |depth| {
	mask: bit(depth),
	writes: one_layer(depth),
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
Switch(ctx, k) : { sel : Signal(ctx, k), cases : List(k), body : (k -> Elem(ctx)), anchor : U32, depth : U64, path : List(U32), cap : U128, enclosing : Enclosing }

switch_reads : Signal(ctx, k), List(k), (k -> Elem(ctx)), U64 -> U128
switch_reads = |sel, cases, body, d| {
	var $m = eff_mask(sel)
	for c in cases {
		$m = $m.bitwise_or(elem_reads(body(c), d))
	}
	$m
}

switch_value : Signal(ctx, k), List(k), ctx, List(U32) -> k
	where [k.is_eq : k, k -> Bool]
switch_value = |sel, cases, env, path| {
	k = (sel.read)(env)
	if (cases.contains(k)) k else crash "contract: switch value is not one of its cases at site ${show_path(path)}"
}

switch_inst : Switch(ctx, k), k, List(Orphan(ctx)), Block(ctx) -> Inst(ctx)
	where [k.is_eq : k, k -> Bool]
switch_inst = |w0, cur0, adopted0, block0| {
	held = { w: w0, cur: cur0, adopted: adopted0, block: block0 }
	Inst(
		|env, msg, tx| {
			{ w, cur, adopted, block } = held
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
							(b3, t3) = mount_block(env, (w.body)(k), w.depth, w.path, 0, w.anchor, { cap: w.cap, enclosing: w.enclosing }, fx_adopt(t2, w.path, orph))
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
									(b2, out, t2) = fire_leaf(block, env, h, payload, path, tx)
									(switch_inst(w, cur, adopted, b2), out, t2)
								}
								Kid => {
									(b2, out, t2) = fire_kid(block, env, path, pos, h, payload, tx)
									(switch_inst(w, cur, adopted, b2), out, t2)
								}
								Miss => (switch_inst(w, cur, adopted, block), Pending(env, no_layers), tx)
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

## A `remount_on` site's fixed part: its key, its body, its anchor
## and where the body mounts.
Remount(ctx, k) : { key : Signal(ctx, k), body : (() -> Elem(ctx)), anchor : U32, depth : U64, path : List(U32), cap : U128, enclosing : Enclosing }

## A `remount_on` site holding the body built for key `cur`.
## `adopted`: orphans reparented to this site when a body it disposed left
## admitted requests behind. Like `switch_inst`, every case returns a
## rebuilt site directly (roc-lang/roc#12846).
remount_inst : Remount(ctx, k), k, List(Orphan(ctx)), Block(ctx) -> Inst(ctx)
	where [k.is_eq : k, k -> Bool]
remount_inst = |w0, cur0, adopted0, block0| {
	held = { w: w0, cur: cur0, adopted: adopted0, block: block0 }
	Inst(
		|env, msg, tx| {
			{ w, cur, adopted, block } = held
			match msg {
				Changed(mask) => {
					if eff_mask(w.key).bitwise_and(mask) != 0 {
						k = (w.key.read)(env)
						t1 = count_evals(tx, 1)
						if k == cur {
							(b2, t2) = refresh(block, env, mask, t1)
							(remount_inst(w, cur, adopted, b2), Done, t2)
						} else {
							(orph, t2) = dispose_block(block, env, True, bump(bump(t1, w_scopes_disposed, 1), w_scopes_created, 1))
							(b3, t3) = mount_block(env, (w.body)(), w.depth, w.path, 0, w.anchor, { cap: w.cap, enclosing: w.enclosing }, fx_adopt(t2, w.path, orph))
							(remount_inst(w, k, adopted.concat(orph), b3), Done, t3)
						}
					} else {
						(b2, t2) = refresh(block, env, mask, tx)
						(remount_inst(w, cur, adopted, b2), Done, t2)
					}
				}
				Fire(path, pos, h, payload) => {
					match leaf_fx(path, pos, payload) {
						Ok(res) => {
							(ad2, out, t2) = adopt_deliver(adopted, env, h, res, tx)
							(remount_inst(w, cur, ad2, block), out, t2)
						}
						Err(_) => {
							match fire_target(block, path, pos) {
								Leaf => {
									(b2, out, t2) = fire_leaf(block, env, h, payload, path, tx)
									(remount_inst(w, cur, adopted, b2), out, t2)
								}
								Kid => {
									(b2, out, t2) = fire_kid(block, env, path, pos, h, payload, tx)
									(remount_inst(w, cur, adopted, b2), out, t2)
								}
								Miss => (remount_inst(w, cur, adopted, block), Pending(env, no_layers), tx)
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

derive_inst : Signal(ctx, a), a, Block(In(ctx, a)), U64 -> Inst(ctx)
	where [a.is_eq : a, a -> Bool]
derive_inst = |input0, v0, block0, depth0| {
	held = { input: input0, v: v0, block: block0, depth: depth0 }
	Inst(
		|env, msg, tx| {
			{ input, v, block, depth } = held
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
						Leaf => {
							(b2, out, t2) = fire_leaf(block, In.{ outer: env, value: v }, h, payload, path, tx)
							derive_settle(input, b2, depth, out, t2)
						}
						Kid => {
							(b2, out, t2) = fire_kid(block, In.{ outer: env, value: v }, path, pos, h, payload, tx)
							derive_settle(input, b2, depth, out, t2)
						}
						Miss => (derive_inst(input, v, block, depth), Pending(env, no_layers), tx)
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
derive_settle : Signal(ctx, a), Block(In(ctx, a)), U64, Out(In(ctx, a)), Tx -> (Inst(ctx), Out(ctx), Tx)
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

# Effects.
#
# An effect site watches a value. At mount (`watch`; `watch_changes` skips
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
# - Disposal (design.md, "Disposal and reparenting" and "Observable
#   lifetime rules"): subscriptions, intervals, timers and work are stopped
#   (CANCEL id, counted `cancelled`) and forgotten. Admitted requests (Http, StorageGet) are
#   not cancelled: they reparent to the nearest surviving ancestor site
#   (the `when`/`switch` that switched branch, or the `each` that removed
#   the row), which delivers the result by running the reaction in its
#   current environment. The disposed layers are snapshots there: writes
#   to retired states are skipped and counted (`skipped`), writes to
#   surviving states commit. A reaction writes one state, so a write is
#   skipped or committed per reaction; the snapshot of a retired layer is
#   retained until the result arrives (bounded by `max`).
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
#   bounds the follow-up turns of depth 2 or more of one host call, so a
#   loop that multiplies is stopped too (see `drain`).
#
# Command stream additions:
#  13 FX      id kind:u8 ... 1 HTTP method:str url:str n:u32 (name:str value:str)* body:str timeout_ms:u32
#                            2 STORAGE_GET key:str  3 TIMER ms:u32  4 INTERVAL ms:u32  5 POPSTATE
#                            6 ONLINE  7 VISIBILITY
#                            8 WORK task:str input:(u32 len, raw bytes) n:u32 (token start len)*n
#                                   timeout_ms:u32 cancel:u8 prepared:u8 [prep:str input_len:u32 input_files:u32]
#                            11 READ mode:u8 token:u64 start:u64 len:u64 max_bytes:u64 (a file's range)
#                            12 UPLOAD method:str url:str n:u32 (name:str value:str)* token start len timeout_ms:u32
#                            13 DIGEST algorithm:u8 token start len   14 URL token start len
#                            15 FETCH method:str url:str n:u32 (name:str value:str)* timeout_ms:u32
#             (kind 8's cancel: 1 stop, 2 finish; prepared: 0 none, 1 a
#             preparation's task with its operands)
#  14 CANCEL  id
#  15 NAV     mode:u8 (1 push, 2 replace) url:str
#  16 STORAGE   op:u8 (1 set: key:str value:str, 2 remove: key:str)
#  17 TITLE   text:str
#  18 FOCUS   op:u8 (1 focus, 2 blur, 3 select text) node   (end of turn)
#  19 PORT    port:str message (a port command; design.md, Appendix B)
#  20 SAVE    token:u64 start:u64 len:u64 name:str (save a file's range)
# Results come back as an event on node `fx_node` with handler = id and
# payload bytes: 1 status:u16 n:u32 (name:str value:str)* body (HTTP
# response with its headers), 7 (HTTP timeout), 2 message (network
# failure), 3 value (storage value), 4 (storage missing), 5 (timer
# fired), 6 url (location), 8 online:u8, 9 visible:u8, 10 n:u32 (size
# name type)* output (a job's answer, with n staged handles), 11
# class:u8 (work lost), 13 reason:u8 (file failure), 14 message (port
# answer), 15 class:u8 [text] (port failure), 21
# status:u16 headers size name type (a fetched body, one staged handle;
# design.md, Appendix B).

## A browser timer stores a signed 32-bit millisecond delay.
max_browser_timer_ms : U32
max_browser_timer_ms = 2147483647

## Largest per-request HTTP timeout or work timeout the host will arm (10
## minutes).
max_timeout_ms : U32
max_timeout_ms = 600000

## The most names one worker catalogue registers (design.md, "Boundedness").
max_tasks : U64
max_tasks = 64

## The most files a job's answer holds (design.md, "Boundedness").
max_answer_files : U64
max_answer_files = 16

## Mount `elem` with the in-flight bound `max` and the program's catalogue,
## running any follow-up turns the mount queued.
mount_in : U64, Catalogue, st, Elem(Root(st)) -> App(st)
mount_in = |max, programs, st, elem| mount_start(max, programs, { st, tables: [] }, elem)

## `mount_in` for a root whose store starts as `start`: the root
## site also takes what it needs of the store's table cells.
mount_start : U64, Catalogue, Core.Start(st), Elem(Root(st)) -> App(st)
mount_start = |max, programs, start, elem| mount_start_in(max, programs, start, elem, root_enclosing)

## The program boundary supplies measured finite root facts without giving
## them to an app's Boot reader or retaining another copy of its store.
mount_start_in : U64, Catalogue, Core.Start(st), Elem(Root(st)), Enclosing -> App(st)
mount_start_in = |max, programs, start, elem, enclosing| mount_start_captured({ max, programs, start, elem, enclosing, capture: PictureCapture.disabled })

## Picture metadata is passive and exists only for this mount's command batch.
## The store and sites have exactly the ordinary mount's ownership and turns.
mount_start_captured : { max : U64, programs : Catalogue, start : Core.Start(st), elem : Elem(Root(st)), enclosing : Enclosing, capture : PictureCapture.Capture } -> App(st)
mount_start_captured = |{ max, programs, start: { st, tables }, elem, enclosing, capture }| {
	{ cmds, next, free, routes, work, paths, site_free, observations, fx } = new_tx([])
	tx0 = { cmds, next, free, routes, work, paths, site_free, observations, fx: with_capture({ ..fx, max }, |_disabled| capture) }
	(block, tx) = mount_block(Root.{ store: st }, elem, 0, [], 0, 0, { cap: 0, enclosing }, tx0)
	written = tables.fold(0.U128, |acc, t| acc.bitwise_or(cell_bit(t.cell)))
	{ store, root, tx: mounted, programs: catalogue } = drain({ store: st, root: store_inst({ cells: tables, written }, no_layers, block), tx: flush_turn(tx, programs), programs })
	{ store, root, tx: with_fx(mounted, |effects| { ..effects, batch: { ..effects.batch, mounting: False } }), programs: catalogue }
}

## A files-kind event's record (design.md, Appendix B), `count:u32
## refused:u32 (size:u64 name:str type:str)*count`, paired in order with the
## handles the host minted for it. Anything else is a contract error: the
## runtime and the host broke the protocol, and nothing is guessed.
decode_files : List(U8), List(Blob), List(U32) -> (List(File), U64)
decode_files = |record, blobs, site| {
	context = "file record at site ${show_path(site)}"
	count = get_u32(record, 0, context).to_u64()
	refused = get_u32(record, 4, context).to_u64()
	if count != blobs.len() {
		crash "contract: a file record lists ${count.to_str()} files but the host minted ${blobs.len().to_str()} handles at site ${show_path(site)}"
	}
	var $at = 8.U64
	var $files = List.with_capacity(count)
	for blob in blobs {
		size = get_u64(record, $at, context)
		(name, a1) = get_str(record, $at + 8, context)
		(mime, a2) = get_str(record, a1, context)
		$files = $files.append({ blob, name, mime, size, start: 0, len: size, reach: OnPage })
		$at = a2
	}
	if $at != record.len() {
		crash "contract: a file record carries ${(record.len() - $at).to_str()} unexpected trailing bytes at site ${show_path(site)}"
	}
	($files, refused)
}

## The catalogue's names, or the contract error that building it is.
catalogue_names : List(Registration) -> List(Str)
catalogue_names = |registrations| match Core.catalogue(registrations) {
	Ok(names) => names
	Err(message) => crash message
}

## The contract error a builder effect answered with `status`: 2 when
## the builder was finished, 3 when the call that opened it has ended (a
## builder kept in a prepared state and used by a later job).
builder_refused : Builder, Str, U8 -> a
builder_refused = |b, what, status| {
	if status == 3 {
		crash "contract: Builder.${what} on \"${b.name}\", a builder that outlived the call that opened it; a builder never leaves its job, so keep the file it finishes instead"
	}
	crash "contract: Builder.${what} on \"${b.name}\" after it was finished"
}

## A placeholder `prepare!` for a registration that is not a preparation;
## nothing calls it, because only a preparation's name is prepared.
not_prepared : List(U8), List(File) => Prepared
not_prepared = |_, _| crash "internal: a task that is not a preparation was prepared"

## A `Work` request's `FX` (design.md, Appendix B): kind 8, `task:str
## input:(u32 len, raw bytes) n:u32 (token start len)*n timeout_ms:u32
## cancel:u8 prepared:u8`, then for a preparation's task `prep:str
## input_len:u32 input_files:u32`, so the runtime knows which preparation
## answers it, and where its input lies, without reading the input itself.
## A preparation's input that does not lie within the request's is a
## contract error naming the task.
put_work : List(U8), Str, List(U8), List(File), U32, [Stop, Finish], [Unprepared, Prepared({ name : Str, input_len : U64, input_files : U64 })] -> List(U8)
put_work = |head, task, input, files, timeout_ms, on_cancel, prepared| {
	var $b = put_u32(put_u32(put_str(head.append(8), task), input.len().to_u32_wrap()).concat(input), files.len().to_u32_wrap())
	for file in files {
		{ token, start, len } = file_ref(file)
		$b = put_u64(put_u64(put_u64($b, token), start), len)
	}
	cancel : U8
	cancel = match on_cancel {
		Stop => 1
		Finish => 2
	}
	b = put_u32($b, min_u32(timeout_ms, max_timeout_ms)).append(cancel)
	match prepared {
		Unprepared => b.append(0)
		Prepared({ name, input_len, input_files }) => {
			if input_len > input.len() or input_files > files.len() {
				crash "contract: the request for worker task \"${task}\" says its preparation's input is longer than the request's"
			}
			put_u32(put_u32(put_str(b.append(1), name), input_len.to_u32_wrap()), input_files.to_u32_wrap())
		}
	}
}

## A file's handle and range, for a request or an effect that names it.
file_ref : File -> { token : U64, start : U64, len : U64 }
file_ref = |f| { token: f.blob.token(), start: f.start, len: f.len }

## Where a file can be read: on the page, which has no effects, or in a
## worker job, whose hosted effects the file carries (design.md,
## "Workers").
Reach : [OnPage, InJob(Core.JobEffects)]

## The files a job was sent, as the handles its instance's host minted for
## them in the request's order, each carrying the job's effects. Decoding
## the job's input gives each its name, type and range (`placed_file`).
job_files : List(Box(U64)), Core.JobEffects -> List(File)
job_files = |handles, effects| handles.map(|handle| { blob: Blob.(handle), name: "", mime: "", size: 0, start: 0, len: 0, reach: InJob(effects) })

## The effects a file's method `what` calls: the job's, which the file
## carries. A file on the page has none; page code cannot call an effect,
## so reaching one with a page's file is a contract error.
job_effects : File, Str -> Core.JobEffects
job_effects = |f, what| match f.reach {
	InJob(effects) => effects
	OnPage => crash "contract: ${what} on \"${f.name}\" outside a worker job; a file's effects run only in a task's job"
}

## A file's handle and range on the wire: `token:u64 start:u64 len:u64`.
put_file : List(U8), File -> List(U8)
put_file = |buf, f| {
	{ token, start, len } = file_ref(f)
	put_u64(put_u64(put_u64(buf, token), start), len)
}

## `out` as a list of its own. The host keeps the output between calls and
## never holds a seamless slice, and a job may well answer with a slice of
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

# ------------------------------------------------------------------
# Ports (design.md, "Ports"): the catalogue's rules, the `PORT` command and
# the message layout of FX kinds 9 and 10 and result tag 14.

## The most ports one program declares (design.md, "Boundedness").
max_ports : U64
max_ports = 64

## The longest port name, in UTF-8 bytes.
max_port_name : U64
max_port_name = 128

## The largest `Every(n)` bound a subscription declares.
max_port_every : U32
max_port_every = 1024

## The declarations, or the contract error that building them is.
ports_checked : List(PortDecl) -> List(PortDecl)
ports_checked = |decls| match Core.port_catalogue(decls) {
	Ok(ok) => ok
	Err(message) => crash message
}

## Append declaration section 5, the port catalogue (design.md, Appendix B):
## `nports:u32 (name:str kind:u8 delivery:u8 bound:u32)*`.
put_port_table : List(U8), List(PortDecl) -> List(U8)
put_port_table = |keys, decls| {
	var $b = put_u32([], decls.len().to_u32_wrap())
	for d in decls {
		$b = put_u32(put_str($b, d.name).append(d.kind).append(d.delivery), d.bound)
	}
	put_section(keys, 5, $b)
}

## Media follows ports in the common section order; its query order is also
## the order of the flags read from boot section 6.
put_media_table : List(U8), List(Str) -> List(U8)
put_media_table = |bytes, queries| put_section(bytes, 6, queries.fold(put_u32([], queries.len().to_u32_wrap()), |body, query| put_str(body, query)))

## A port's shape as its declaration numbers it.
port_kind_name : U8 -> Str
port_kind_name = |kind| match kind {
	1 => "a command"
	2 => "a call"
	_ => "a subscription"
}

## `decode_res` with result tags 14 and 15 read by `port_res`, which is
## the program's own (see [Ports]): an app that declares no ports
## carries no port decoder.
decode_progress : List(U8) -> Core.Transfer
decode_progress = |bytes| {
	if bytes.len() != 19 {
		crash "contract: transfer progress needs exactly 19 bytes"
	}
	direction = match bytes.get(1) {
		Ok(1) => Sending
		Ok(2) => Receiving
		_ => crash "contract: transfer progress direction must be 1 or 2"
	}
	done = get_u64(bytes, 2, "transfer progress")
	total_bytes = get_u64(bytes, 11, "transfer progress")
	total = match bytes.get(10) {
		Ok(0) if total_bytes == 0 => Unknown
		Ok(1) => Known(total_bytes)
		_ => crash "contract: transfer progress total flag must be 0 with zero total, or 1"
	}
	{ direction, done, total }
}

decode_res_with : List(U8), (List(U8), List(Blob) -> Result) -> Result
decode_res_with = |b, port_res| {
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
		if b.len() != 9 {
			crash "contract: effect result tag 5 needs exactly eight timestamp bytes"
		}
		Fired(get_u64(b, 1, "Fired timestamp").to_i64_wrap())
	} else if tag == 6 {
		Location(text(1))
	} else if tag == 8 {
		Online(flag())
	} else if tag == 9 {
		Visible(flag())
	} else if tag == 23 {
		bare(Copied)
	} else if tag == 24 {
		match b {
			[_, 1] => ClipboardFailed(NotAllowed)
			[_, 2] => ClipboardFailed(Unavailable)
			_ => crash "contract: ClipboardFailed needs one reason byte, 1 or 2"
		}
	} else if tag == 25 {
		match b {
			[_, store, reason, ..] if (store == 1 or store == 2) and (reason == 1 or reason == 2) => StorageFailed({ store: if (store == 1) Local else Session, reason: if (reason == 1) Quota else Unavailable, key: text(3) })
			_ => crash "contract: StorageFailed needs store and reason bytes, each 1 or 2"
		}
	} else if tag == 22 {
		Matches(flag())
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
	} else if tag == 14 or tag == 15 {
		port_res(b, [])
	} else if tag == 10 or tag == 21 {
		decode_held_res(b, [])
	} else {
		crash "contract: unknown effect result tag ${tag.to_str()}"
	}
}

## Result tags 10 and 21 (design.md, Appendix B), paired in order with the
## handles the host minted for their files: a job's answer, `n:u32
## (size:u64 name:str type:str)*n output:rest`, and a response whose body
## is a file, `status:u16 n:u32 (name:str value:str)*n size:u64 name:str
## type:str` with exactly one handle. Anything else is a contract error.
decode_held_res : List(U8), List(Blob) -> Result
decode_held_res = |b, handles| {
	what = "effect result tag ${(b.first() ?? 0).to_str()}"
	files_at = |at0, count| {
		if count != handles.len() {
			crash "contract: an ${what} lists ${count.to_str()} files but the host minted ${handles.len().to_str()} handles"
		}
		var $at = at0
		var $files = List.with_capacity(count)
		for blob in handles {
			size = get_u64(b, $at, what)
			(name, a1) = get_str(b, $at + 8, what)
			(mime, a2) = get_str(b, a1, what)
			$files = $files.append({ blob, name, mime, size, start: 0, len: size, reach: OnPage })
			$at = a2
		}
		($files, $at)
	}
	match b {
		[10, ..] => {
			count = get_u32(b, 1, what).to_u64()
			(files, at) = files_at(5, count)
			Work({ output: b.drop_first(at), files })
		}
		[21, s0, s1, ..] => {
			status = s0.to_u16() + s1.to_u16().shl_wrap(8)
			n = get_u32(b, 3, what).to_u64()
			var $at = 7.U64
			var $headers = []
			while $headers.len() < n {
				(k, a1) = get_str(b, $at, what)
				(v, a2) = get_str(b, a1, what)
				$headers = $headers.append((k, v))
				$at = a2
			}
			(files, end) = files_at($at, 1)
			if end != b.len() {
				crash "contract: an ${what} carries ${(b.len() - end).to_str()} unexpected trailing bytes"
			}
			match files {
				[body] => Fetched({ status, headers: $headers, body })
				_ => crash "contract: an ${what} needs exactly one file"
			}
		}
		_ => crash "contract: an ${what} carries file handles it cannot hold"
	}
}

## The ports of a program that declares `decls`, with the real port code
## (see [Ports]). Only `with_ports` and tests reach it.
ports_of : List(PortDecl) -> Ports
ports_of = |decls| {
	decls,
	table: put_port_table,
	check: check_port,
	write: write_ports,
	decode: decode_port_res,
	ends: ends_subscription,
}

## The ports of a program that declares none (see [Ports]): an empty port
## table, and a contract error for any port request or port result. Each
## stub is small and names the rule, so the codec is never linked in.
no_ports : Ports
no_ports = {
	decls: [],
	table: |keys, _| put_section(keys, 5, put_u32([], 0)),
	check: |_, { req, path, .. }| crash "contract: port \"${port_name(req)}\" is not declared; add it to its module's record of ports (site ${show_path(path)})",
	write: |tx, _| tx,
	decode: |_, _| crash "contract: a port result (effect result tag 14 or 15) reached an app that declares no ports",
	ends: |_| Bool.False,
}

## The port a port request names.
port_name : PortRequest -> Str
port_name = |req| match req {
	Command(port, _) => port
	Call(port, _, _) => port
	Subscribe(port, _) => port
}

## A port request names a declared port of its own shape, or it is the
## contract error that names the port and the site.
check_port : List(PortDecl), PortAt -> {}
check_port = |decls, { req, path, .. }| {
	port = port_name(req)
	kind = match req {
		Command(_, _) => 1
		Call(_, _, _) => 2
		Subscribe(_, _) => 3
	}
	match decls.find_first(|d| d.name == port) {
		Ok(d) =>
			if d.kind != kind {
				crash "contract: port \"${port}\" is declared as ${port_kind_name(d.kind)} but used as ${port_kind_name(kind)} (site ${show_path(path)})"
			} else {
				{}
			}
		Err(_) => crash "contract: port \"${port}\" is not declared; add it to its module's record of ports (site ${show_path(path)})"
	}
}

## Put a turn's port requests (its `Port` entries) into its batch (see
## [PortAt]), each at the
## place in the stream where it was issued, so the batch is exactly what
## writing it in place would have given: `PORT` (opcode 19) for a command,
## `FX` kind 9 for a call and kind 10 for a subscription. A refused request
## writes nothing. Commands are counted at work-record index 40, never by
## opcode (index 19 is `set_value`).
##
## When every request was issued after the turn's last other command, the
## bytes are appended to the batch in place; otherwise the batch is rebuilt
## once around them, O(batch + messages).
write_ports : Tx, List(TurnEnd) -> Tx
write_ports = |tx, entries| {
	reqs = entries.keep_oks(
		|e| match e {
			Port({ req, slot: At(at, id), .. }) => Ok((req, at, id))
			_ => Err(NotWritten)
		},
	)
	{ cmds, next, free, routes, work, paths, site_free, observations, fx } = tx
	first = match reqs.first() {
		Ok((_, at, _)) => at
		Err(_) => cmds.len()
	}
	in_place = first == cmds.len()
	var $out = if (in_place) cmds else List.with_capacity(cmds.len() + 64).concat(cmds.sublist({ start: 0, len: first }))
	var $from = first
	var $sends = 0.U64
	var $insertions = []
	var $insertions_full = False
	collecting = PictureCapture.is_collecting(fx.batch.capture)
	insertion_limit = PictureCapture.remaining(fx.batch.capture)
	for (req, at, id) in reqs {
		if at > $from {
			$out = $out.concat(cmds.sublist({ start: $from, len: at - $from }))
			$from = at
		}
		before = $out.len()
		$out = match req {
			Command(port, message) => {
				$sends = $sends + 1
				put_port_message(put_str($out.append(19), port), message)
			}
			Call(port, message, timeout_ms) => put_u32(put_port_message(put_str(put_u32($out.append(13), id).append(9), port), message), min_u32(timeout_ms, max_timeout_ms))
			Subscribe(port, message) => put_port_message(put_str(put_u32($out.append(13), id).append(10), port), message)
		}
		if collecting and !$insertions_full {
			if $insertions.len() >= insertion_limit {
				$insertions_full = True
			} else {
				$insertions = $insertions.append({
					at,
					bytes: $out.len() - before,
					opcode: match req {
						Command(_, _) => 19
						Call(_, _, _) | Subscribe(_, _) => 13
					},
				})
			}
		}
	}
	out = if (in_place) $out else $out.concat(cmds.sublist({ start: $from, len: cmds.len() - $from }))
	{ cmds: out, next, free, routes, work: add_work(work, w_port_sends, $sends), paths, site_free, observations, fx: with_capture(fx, |capture| if ($insertions_full) PictureCapture.refuse_limit(capture) else PictureCapture.seal(capture, $insertions)) }
}

## A message as FX kinds 9 and 10 and `PORT` carry it: `json:str
## nblobs:u32 (len:u32 bytes)* nfiles:u32 (token:u64 start:u64 len:u64)*`.
put_port_message : List(U8), PortMessage -> List(U8)
put_port_message = |buf, { json, blobs, files }| {
	var $b = put_u32(put_str(buf, json), blobs.len().to_u32_wrap())
	for blob in blobs {
		$b = put_u32($b, blob.len().to_u32_wrap()).concat(blob)
	}
	$b = put_u32($b, files.len().to_u32_wrap())
	for file in files {
		{ token, start, len } = file_ref(file)
		$b = put_u64(put_u64(put_u64($b, token), start), len)
	}
	$b
}

## A port answer's message from result tag 14, `json:str nblobs:u32
## (len:u32 bytes)* nfiles:u32 (size:u64 name:str type:str)*`, its files
## paired in order with the handles the host minted for them. Anything else
## is a contract error.
decode_port_message : List(U8), List(Blob) -> PortMessage
decode_port_message = |b, handles| {
	(json, a1) = get_str(b, 1, "port answer")
	nblobs = get_u32(b, a1, "port answer").to_u64()
	var $at = a1 + 4
	var $blobs = []
	var $i = 0.U64
	while $i < nblobs {
		len = get_u32(b, $at, "port answer").to_u64()
		if $at + 4 + len > b.len() {
			crash "contract: truncated port answer"
		}
		$blobs = $blobs.append(b.sublist({ start: $at + 4, len }))
		$at = $at + 4 + len
		$i = $i + 1
	}
	nfiles = get_u32(b, $at, "port answer").to_u64()
	if nfiles != handles.len() {
		crash "contract: a port answer lists ${nfiles.to_str()} files but the host minted ${handles.len().to_str()} handles"
	}
	$at = $at + 4
	var $files = List.with_capacity(nfiles)
	for blob in handles {
		size = get_u64(b, $at, "port answer")
		(name, f1) = get_str(b, $at + 8, "port answer")
		(mime, f2) = get_str(b, f1, "port answer")
		$files = $files.append({ blob, name, mime, size, start: 0, len: size, reach: OnPage })
		$at = f2
	}
	if $at != b.len() {
		crash "contract: a port answer carries ${(b.len() - $at).to_str()} unexpected trailing bytes"
	}
	{ json, blobs: $blobs, files: $files }
}

## Result tags 14 and 15, and the file handles an answer carries (only an
## answer carries any). Anything else is a contract error.
decode_port_res : List(U8), List(Blob) -> Result
decode_port_res = |b, handles| match b {
	[14, ..] => PortAnswer(decode_port_message(b, handles))
	[15, ..] if !handles.is_empty() => crash "contract: an effect result that is not a port answer carries file handles"
	[15, 1, ..] => PortFailed(Threw(Str.from_utf8(b.drop_first(2)) ?? crash "contract: effect result text is not UTF-8"))
	[15, 2] => PortFailed(TooLarge)
	[15, 3] => PortFailed(Closed)
	[15, ..] => crash "contract: effect result tag 15 needs a failure class, 1 with text, 2 or 3"
	_ => crash "contract: an effect result that is not a port answer carries file handles"
}

## A result that ends a subscription: its JavaScript closed it or threw.
ends_subscription : Result -> Bool
ends_subscription = |res| match res {
	PortFailed(Closed) => True
	PortFailed(Threw(_)) => True
	_ => False
}

Live : { id : U32, path : List(U32), sub : Bool, progress : Bool }

Queued : { id : U32, path : List(U32), res : Result }

RefMap : Dict(Str, List({ node : U32, path : List(U32), value_control : Bool }))

RefOwned : { name : Str, path : List(U32) }

## Registration owners are node addresses, not application data or identity.
LiveObservations : { owners : Dict(U32, U64), live : U64 }

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

	## Focus names and their live nodes with construction sites, and the checks awaiting the end of the
	## turn (see [TurnEnd]).
	document_nodes : List(U32),

	## The registrations owned by each addressed node, and their live gauge.
	## A row owns every observation in its static template.
	observed : LiveObservations,
	refs : RefMap,
	focus : List(TurnEnd),

	## `ref_pos[node]`: the names the node carries, empty when it has none.
	## This reverse index makes freeing a reference node O(1).
	ref_pos : List(List(RefOwned)),

	## `on_cleanup` runs, by name, in first-run order.
	cleanups : List((Str, U64)),
	guard : { live : U64, emitted : Bool },

	## Types accumulated across every turn of one host call, never across calls.
	batch : TransitionBatch,
}

## What the end of a turn settles, in issue order: a focus command on a named
## reference (op 1 focus, 2 blur, 3 select text), resolved then so a reference
## mounted later in the turn is found; and the work requests the turn issued,
## each checked against the worker catalogue with its task and site path.
##
## The catalogue lives in [App], not in `Fx`: every site rebuilds `Fx` as it
## threads the turn, and with the pinned compiler each inline field of
## it costs code at every one of those places (a catalogue field there grew
## every app by about 3%). Checking at the end of the turn is the same
## contract error with the same message; nothing the turn did is published,
## because the crash poisons the instance before the call returns.
##
## `Drift` is never part of a turn. A view site adds it during the
## settle check (`Core.settled`) when the view it holds is not the one its
## table gives from scratch; the check reports it, and the pass it ran in
## is discarded.
TurnEnd : [CheckRef(Str), Focus(U8, Str), ScrollIntoView(Str, { block : Align, inline : Align, behavior : ScrollBehavior }), ScrollTo(Str, { top : Edge, left : Edge, behavior : ScrollBehavior }), CheckTask(Str, List(U32)), CheckMedia(Str, List(U32)), Port(PortAt), Drift(Str)]

## A port request waiting for the end of its turn (see [Ports]): the
## request, the site that issued it, and where its bytes go: at offset `at`
## of the batch with request id `id` (0 for a command), or nowhere when the
## in-flight bound refused it. Its use is checked like a work request's,
## and its bytes are written then, through the program's own port code, so
## an app that declares no ports never links the port encoder.
PortAt : { req : PortRequest, path : List(U32), slot : [At(U64, U32), Refused] }

## A port request as it waits for the end of its turn: a command, a call
## with its timeout, or a subscription, each with its port and message.
PortRequest : [Command(Str, PortMessage), Call(Str, PortMessage, U32), Subscribe(Str, PortMessage)]

TransitionBatch : { mounting : Bool, asked : Bool, types : List(Str), seen : Dict(Str, {}), capture : PictureCapture.Capture }

fx_empty : Fx
fx_empty = { next: 1, inner: fx_inner_base, live: [], queue: [], max: 32, issued: 0, delivered: 0, stale: 0, refused: 0, cancelled: 0, reparented: 0, skipped: 0, document_nodes: [], observed: { owners: Dict.empty(), live: 0 }, refs: Dict.empty(), focus: [], ref_pos: [], cleanups: [], guard: { live: 0, emitted: False }, batch: { mounting: True, asked: False, types: [], seen: Dict.empty(), capture: PictureCapture.disabled } }

## Collect a request without allocating an awaited id. Removing the batch from
## its holder before updating keeps its hash set and ordered list unique.
collect_transition : Fx, List(Str) -> Fx
collect_transition = |{ next, inner, live, queue, max, issued, delivered, stale, refused, cancelled, reparented, skipped, document_nodes, observed, refs, focus, ref_pos, cleanups, guard, batch }, names| {
	{ mounting, asked, types, seen, capture } = batch
	var $types = types
	var $seen = seen
	if !mounting {
		for name in names {
			if !$seen.contains(name) {
				$seen = $seen.insert(name, {})
				$types = $types.append(name)
			}
		}
	}
	{ next, inner, live, queue, max, issued, delivered, stale, refused, cancelled, reparented, skipped, document_nodes, observed, refs, focus, ref_pos, cleanups, guard, batch: { mounting, asked: asked or !mounting, types: $types, seen: $seen, capture } }
}

## Move the transient collector out of its holder before updating it. Keeping
## a second reference here would copy the command history on every emission.
with_capture : Fx, (PictureCapture.Capture -> PictureCapture.Capture) -> Fx
with_capture = |{ next, inner, live, queue, max, issued, delivered, stale, refused, cancelled, reparented, skipped, document_nodes, observed, refs, focus, ref_pos, cleanups, guard, batch }, update| {
	{ mounting, asked, types, seen, capture } = batch
	{ next, inner, live, queue, max, issued, delivered, stale, refused, cancelled, reparented, skipped, document_nodes, observed, refs, focus, ref_pos, cleanups, guard, batch: { mounting, asked, types, seen, capture: update(capture) } }
}

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

## The most follow-up turns of depth 2 or more one host call may run: 64
## for each in-flight slot, and at least 64 x 64. The depth bound alone
## stops every chain, but a feedback loop in which each follow-up queues two
## or more would grow exponentially before reaching it; this backstop stops
## that. The follow-ups of depth 1 are not counted (see `drain`): the
## external turn queued them itself, so their number is what that one turn
## issued, however many rows it drew, and never the work of a loop.
max_breadth : U64 -> U64
max_breadth = |inflight| max_turns * (if (inflight > max_turns) inflight else max_turns)

## A request the site owns: its id, whether it is a subscription, whether
## it is kept on disposal, its held snapshot and position in the plan. Typed
## asks keep the issued-for value and reader together in that snapshot.
Owned(a) : { id : U32, sub : Bool, keep : Bool, a : a, at : U64 }

## Every issued request keeps the value and reader chosen by its plan.
## The reader is consumed only by a final result, never a progress report.
Held(a, output, error) : { value : a, read : (Result -> Try(output, error)) }

Planned(h) : { request : Request, held : h }

hold_asks : a, List(Core.Ask(output, error)) -> List(Planned(Held(a, output, error)))
hold_asks = |value, asks| asks.map(|{ request, read }| { request, held: { value, read } })

held_reaction : Core.Reaction(ctx, a, Try(output, error)) -> Core.Reaction(ctx, Held(a, output, error), Result)
held_reaction = |reaction| {
	run = reaction.run
	{
		run: |env, held, result, site| run(env, held.value, (held.read)(result), site),
		progress: match reaction.progress {
			NoProgress => NoProgress
			Reporting(report) => Reporting({ every_ms: report.every_ms, run: |env, held, transfer, site| (report.run)(env, held.value, transfer, site) })
		},
	}
}

## Internal input for a request’s ordinary turn. A final result carries the
## liveness decision already made at ingress; progress keeps the id live.
EffectInput : [Final(Result, Bool), Progress(Core.Transfer)]

ProgressHandler(ctx, a) : [NoProgress, Reporting({ every_ms : U32, run : (ctx, a, Core.Transfer, List(U32) -> (ctx, Layers)) })]

is_progress : EffectInput -> Bool
is_progress = |input| match input {
	Progress(_) => True
	Final(_, _) => False
}

## The result ingress already decided whether the id remains live. Carry
## that fact through routing, including a terminal subscription or refusal,
## so retirement releases its reader without another in-flight lookup.
keeps_owned : EffectInput -> Bool
keeps_owned = |input| match input {
	Final(_, live) => live
	Progress(_) => True
}

progress_interval : Core.Reaction(ctx, a, result) -> U32
progress_interval = |reaction| match reaction.progress {
	NoProgress => 0
	Reporting(report) => report.every_ms
}

supports_progress : Request -> Bool
supports_progress = |request| match request {
	Http(_) | Upload(_) | Fetch(_) => True
	_ => False
}

count_delivery : Tx, EffectInput -> Tx
count_delivery = |tx, input| if (is_progress(input)) bump(tx, 47, 1) else fx_count(tx, Delivered)

run_reaction : Core.Reaction(ctx, a, Result), ctx, a, EffectInput, List(U32) -> (ctx, Layers)
run_reaction = |reaction, env, a, input, site| match input {
	Final(result, _) => (reaction.run)(env, a, result, site)
	Progress(transfer) => match reaction.progress {
		Reporting(report) => (report.run)(env, a, transfer, site)
		NoProgress => crash "contract: progress requires a reaction with_progress at site ${show_path(site)}"
	}
}

combine_progress : ProgressHandler(ctx, a), ProgressHandler(ctx, a) -> ProgressHandler(ctx, a)
combine_progress = |first, second| match (first, second) {
	(NoProgress, report) | (report, NoProgress) => report
	(Reporting(left), Reporting(right)) => Reporting({
		every_ms: min_u32(left.every_ms, right.every_ms),
		run: |env, a, transfer, site| {
			(e1, w1) = (left.run)(env, a, transfer, site)
			(e2, w2) = (right.run)(e1, a, transfer, site)
			(e2, layers_or(w1, w2))
		},
	})
}

put_http_options : List(U8), Core.Cache, Core.Credentials, U32 -> List(U8)
put_http_options = |bytes, cache, credentials, progress_ms| {
	cache_code = match cache {
		Default => 1
		NoStore => 2
		Reload => 3
		NoCache => 4
		ForceCache => 5
	}
	credentials_code = match credentials {
		SameOrigin => 1
		Include => 2
	}
	put_u32(bytes.append(cache_code).append(credentials_code), progress_ms)
}

## Fixed per effect site: `plan` gives the requests for the value at
## mount, and `step` those for a change from the value last seen to a new
## one at the site's path (`plan` of the new value, except for `on_post`,
## which checks the change).
EffectCfg(ctx, a, h) : { v : Signal(ctx, a), plan : (ctx, a -> List(Planned(h))), step : (ctx, a, a, List(U32) -> List(Planned(h))), react : Reaction(ctx, h, Result), path : List(U32), only : Delivery(ctx, h) }

## Current-step ids are metadata only. The question reads the environment
## supplied to an orphan's eventual turn, never a captured store or context.
Delivery(ctx, h) : [Every, Current({ ids : Dict(U32, {}), question : (ctx, h -> Bool) })]

accepts_result : Delivery(ctx, h), U32 -> Bool
accepts_result = |only, id| match only {
	Every => True
	Current({ ids, .. }) => ids.contains(id)
}

## Build a fresh index from just this issuing step. Reading the old length
## happens before append, so indexing cannot keep an old Owned list aliased.
issue_effect : EffectCfg(ctx, a, h), { tx : Tx, planned : List(Planned(h)), owned : List(Owned(h)) } -> (EffectCfg(ctx, a, h), Tx, List(Owned(h)))
issue_effect = |cfg, { tx, planned, owned }| {
	previous = owned.len()
	match cfg.only {
		Every => {}
		Current(_) => {
			for request in planned {
				if is_sub(request.request) {
					crash "contract: keep_current cannot issue a subscription at site ${show_path(cfg.path)}; use watch_latest to stop an older subscription"
				}
			}
		}
	}
	(next, issued) = issue_progress(tx, cfg.path, planned, owned, progress_interval(cfg.react))
	only = match cfg.only {
		Every => Every
		Current({ question, .. }) => Current({ ids: issued.drop_first(previous).fold(Dict.empty(), |ids, entry| ids.insert(entry.id, {})), question })
	}
	({ ..cfg, only }, next, issued)
}

## Move the policy out before mutating its index. Keeping the old cfg beside
## a Dict.remove would make every final result copy the current-id set.
retire_current : EffectCfg(ctx, a, h), { id : U32, input : EffectInput } -> EffectCfg(ctx, a, h)
retire_current = |{ v, plan, step, react, path, only }, { id, input }| {
	only2 = match only {
		Every => Every
		Current({ ids, question }) => Current({ ids: if (keeps_owned(input)) ids else ids.remove(id), question })
	}
	{ v, plan, step, react, path, only: only2 }
}

## The `step` of a site that issues `plan` of each new value.
replanned : (a -> List(request)) -> (a, a, List(U32) -> List(request))
replanned = |plan| |_, a, _| plan(a)

with_fx : Tx, (Fx -> Fx) -> Tx
with_fx = |{ cmds, next, free, routes, work, paths, site_free, observations, fx }, f| { cmds, next, free, routes, work, paths, site_free, observations, fx: f(fx) }

fx_count : Tx, [Delivered, Stale] -> Tx
fx_count = |tx, k| with_fx(
	tx,
	|fx| match k {
		Delivered => { ..fx, delivered: fx.delivered + 1 }
		Stale => { ..fx, stale: fx.stale + 1 }
	},
)

is_sub : Request -> Bool
is_sub = |req| match req {
	Interval(_) => True
	Popstate => True
	OnlineChanges => True
	VisibilityChanges => True
	MediaChanges(_) => True
	StorageChanges(_) => True
	StorageWriteFailures => True
	PortSubscribe(_) => True
	_ => False
}

## Every subscription kind takes the same pre-admission rejection path for
## keep_current; a one-shot zero timer remains an ordinary legal request.
expect {
	message = { json: "null", blobs: [], files: [] }
	kinds = [Interval(1), Popstate, OnlineChanges, VisibilityChanges, MediaChanges("(color)"), StorageChanges("key"), StorageWriteFailures, PortSubscribe({ port: "events", message })]
	kinds.all(is_sub) and !is_sub(Timer(0)) and !is_sub(Self)
}

expect {
	page = Core.keep_current(Core.const({}), |_| [Core.timer(0)], Core.ignore({}))
	(mounted, bytes) = Core.take_cmds(Core.mount(page), [])
	timer_bytes = put_fx([], 1, Timer(0))
	Core.fx_live(mounted) == [1] and bytes.drop_first(bytes.len() - timer_bytes.len()) == timer_bytes and Core.settled(mounted).is_ok()
}

## Requests that survive their site's disposal (design.md: an admitted
## effect reparents). Subscriptions, intervals, timers and operations on
## files on the page are scoped: disposal stops them. A job is kept or
## scoped by its task's `on_dispose`, which the caller reads from the
## request itself.
is_kept : Request -> Bool
is_kept = |req| match req {
	Http(_) => True
	Upload(_) => True
	StorageGet(_) => True
	SessionStorageGet(_) => True
	ClipboardWrite(_) => True
	PortCall(_) => True
	Fetch(_) => True
	_ => False
}

min_u32 : U32, U32 -> U32
min_u32 = |a, b| if (a < b) a else b

## Check request contracts before admission, while the issuing site's path
## is available. The encoder only writes requests that passed this boundary.
request_problem : Request -> Try({}, Str)
request_problem = |request| match request {
	Timer(ms) if ms > max_browser_timer_ms => Err("contract: Timer(${ms.to_str()}) is longer than a browser timer holds (2147483647 ms, about 24.8 days); the browser would fire it at once")
	Interval(0) => Err("contract: Interval(0) has no period; the browser would fire it as fast as it can, a turn each time")
	Interval(ms) if ms > max_browser_timer_ms => Err("contract: Interval(${ms.to_str()}) is longer than a browser timer holds (2147483647 ms, about 24.8 days); the browser would fire it as fast as it can, a turn each time")
	Upload({ method, url, body, .. }) if upload_has_no_body(method) => Err("contract: File.upload of \"${body.name}\" to ${url} uses ${method.text()}, which carries no body")
	_ => Ok({})
}

## Fetch normalizes these methods in every ASCII case. Compare at admission,
## where a file body is known, without changing the method's retained spelling.
upload_has_no_body : Web.Method -> Bool
upload_has_no_body = |method| match method.text().to_utf8() {
	[g, e, t] => (g == 'G' or g == 'g') and (e == 'E' or e == 'e') and (t == 'T' or t == 't')
	[h, e, a, d] => (h == 'H' or h == 'h') and (e == 'E' or e == 'e') and (a == 'A' or a == 'a') and (d == 'D' or d == 'd')
	_ => False
}

## File.upload shares the public request family. Every spelling Fetch would
## normalize to GET or HEAD is refused before admission, while a body-carrying
## method retains its exact spelling in the ask.
expect {
	file = Core.held_file(Box.box(1.U64))
	refused = ["GET", "get", "GeT", "HEAD", "head", "HeAd"].all(
		|method| {
			checked = Web.Method.from_str(method) ?? crash "valid method in upload contract expect"
			request = file.upload({ url: "/upload", method: checked }).sent()
			request_problem(request) == Err("contract: File.upload of \"\" to /upload uses ${method}, which carries no body")
		},
	)
	accepted = ["POST", "post", "PROPFIND", "custom"].all(
		|method| {
			checked = Web.Method.from_str(method) ?? crash "valid method in upload contract expect"
			request = file.upload({ url: "/upload", method: checked }).sent()
			request_problem(request).is_ok() and match request {
				Upload(props) => props.method.text() == method
				_ => False
			}
		},
	)
	refused and accepted
}

## Timer limits are contracts before admission; zero is legal only for the
## one-shot timer, and the browser's largest delay remains valid for both.
expect {
	request_problem(Timer(0)).is_ok() and request_problem(Interval(0)).is_err() and
		request_problem(Timer(max_browser_timer_ms)).is_ok() and request_problem(Interval(max_browser_timer_ms)).is_ok() and
			request_problem(Timer(max_browser_timer_ms + 1)).is_err() and request_problem(Interval(max_browser_timer_ms + 1)).is_err()
}

## An admitted request's `FX` command (design.md, Appendix B). A port
## request's is written at the end of its turn instead (see [PortAt]).
put_req : List(U8), U32, Request, U32 -> List(U8)
put_req = |c, id, req, progress_ms| match req {
	PortCall(_) | PortSubscribe(_) => c
	_ => put_fx_progress(c, id, req, progress_ms)
}

put_fx : List(U8), U32, Request -> List(U8)
put_fx = |c, id, req| put_fx_progress(c, id, req, 0)

put_fx_progress : List(U8), U32, Request, U32 -> List(U8)
put_fx_progress = |c, id, req, progress_ms| {
	head = put_u32(c.append(13), id)
	match req {
		Http({ method, url, headers, body, timeout_ms, cache, credentials }) => {
			var $b = put_u32(put_str(put_str(head.append(1), method.text()), url), headers.len().to_u32_wrap())
			for (k, v) in headers {
				$b = put_str(put_str($b, k), v)
			}
			put_http_options(put_u32(put_str($b, body), min_u32(timeout_ms, max_timeout_ms)), cache, credentials, progress_ms)
		}
		StorageGet(k) => put_str(head.append(2), k)
		SessionStorageGet(key) => put_str(head.append(17), key)
		StorageChanges(key) => put_str(head.append(18), key)
		StorageWriteFailures => head.append(20)
		ClipboardWrite({ text, html }) => match html {
			Plain => put_str(head.append(19), text).append(0)
			Html(markup) => put_str(put_str(head.append(19), text).append(1), markup)
		}
		Timer(ms) => put_u32(head.append(3), ms)
		Interval(ms) => put_u32(head.append(4), ms)
		Popstate => head.append(5)
		OnlineChanges => head.append(6)
		VisibilityChanges => head.append(7)
		MediaChanges(query) => put_str(head.append(16), query)
		Work({ task, input, files, timeout_ms, on_cancel, prepared, .. }) => put_work(head, task, input, files, timeout_ms, on_cancel, prepared)
		ReadBytes({ file, max_bytes }) => put_u64(put_file(head.append(11).append(1), file), max_bytes)
		ReadUtf8({ file, max_bytes }) => put_u64(put_file(head.append(11).append(2), file), max_bytes)
		Upload({ method, url, headers, body, timeout_ms, credentials }) => {
			var $b = put_u32(put_str(put_str(head.append(12), method.text()), url), headers.len().to_u32_wrap())
			for (k, v) in headers {
				$b = put_str(put_str($b, k), v)
			}
			put_http_options(put_u32(put_file($b, body), min_u32(timeout_ms, max_timeout_ms)), Default, credentials, progress_ms)
		}
		Sha256(f) => put_file(head.append(13).append(1), f)
		ObjectUrl(f) => put_file(head.append(14), f)
		Fetch({ method, url, headers, timeout_ms, cache, credentials }) => {
			var $b = put_u32(put_str(put_str(head.append(15), method.text()), url), headers.len().to_u32_wrap())
			for (k, v) in headers {
				$b = put_str(put_str($b, k), v)
			}
			put_http_options(put_u32($b, min_u32(timeout_ms, max_timeout_ms)), cache, credentials, progress_ms)
		}
		_ => crash "not an awaited request"
	}
}

## Admit an awaited request (or refuse it when the table is full).
fx_admit : Tx, List(U32), Request -> (U32, Tx)
fx_admit = |tx, path, req| fx_admit_progress(tx, path, req, 0)

fx_admit_progress : Tx, List(U32), Request, U32 -> (U32, Tx)
fx_admit_progress = |tx, path, req, progress_ms| {
	match request_problem(req) {
		Ok(_) => {}
		Err(message) => crash "${message} (site ${show_path(path)})"
	}
	# A port request's bytes are written at the end of the turn.
	{ cmds, next, free, routes, work, paths, site_free, observations, fx } = turn_end_later(tx, path, req)
	{ next: id, inner, live, queue, max, issued, delivered, stale, refused, cancelled, reparented, skipped, document_nodes, observed, refs, focus, ref_pos, cleanups, guard, batch } = fx
	if live.len() >= max {
		fx2 = { next: id + 1, inner, live, queue: queue.append({ id, path, res: Refused }), max, issued, delivered, stale, refused: refused + 1, cancelled, reparented, skipped, document_nodes, observed, refs, focus, ref_pos, cleanups, guard, batch }
		(id, { cmds, next, free, routes, work, paths, site_free, observations, fx: fx2 })
	} else {
		fx2 = { next: id + 1, inner, live: live.append({ id, path, sub: is_sub(req), progress: progress_ms > 0 and supports_progress(req) }), queue, max, issued: issued + 1, delivered, stale, refused, cancelled, reparented, skipped, document_nodes, observed, refs, focus, ref_pos, cleanups, guard, batch }
		command_at = cmds.len()
		written = put_req(cmds, id, req, progress_ms)
		(id, { cmds: written, next, free, routes, work: add_work(work, 13, 1), paths, site_free, observations, fx: if (written.len() == command_at) fx2 else capture_command(fx2, { bytes: written, at: command_at, opcode: 13 }) })
	}
}

## Queue what the end of the turn settles for a request (see [TurnEnd]) as
## it is issued: a focus or scroll command on a named reference, or a port request
## with the place its bytes go (see [PortAt]), which is nowhere when the
## in-flight bound is about to refuse it. Any other request needs nothing.
turn_end_later : Tx, List(U32), Request -> Tx
turn_end_later = |tx, path, req| {
	at = tx.cmds.len()
	slot = if (tx.fx.live.len() >= tx.fx.max) Refused else At(at, tx.fx.next)
	entry = match req {
		Focus(n) => Focus(1, n)
		Blur(n) => Focus(2, n)
		SelectText(n) => Focus(3, n)
		ApplyValue(n) => Focus(4, n)
		FocusInPlace(n) => Focus(5, n)
		ScrollIntoView(n, props) => ScrollIntoView(n, props)
		ScrollTo(n, props) => ScrollTo(n, props)
		PortCommand({ port, message }) => Port({ req: Command(port, message), path, slot: At(at, 0) })
		PortCall({ port, message, timeout_ms }) => Port({ req: Call(port, message, timeout_ms), path, slot })
		PortSubscribe({ port, message }) => Port({ req: Subscribe(port, message), path, slot })
		MediaChanges(query) => CheckMedia(query, path)
		_ => Skip
	}
	match entry {
		Skip => tx
		Focus(op, n) => with_fx(tx, |fx| { ..fx, focus: fx.focus.append(Focus(op, n)) })
		ScrollIntoView(n, props) => with_fx(tx, |fx| { ..fx, focus: fx.focus.append(ScrollIntoView(n, props)) })
		ScrollTo(n, props) => with_fx(tx, |fx| { ..fx, focus: fx.focus.append(ScrollTo(n, props)) })
		Port(p) => with_fx(tx, |fx| { ..fx, focus: fx.focus.append(Port(p)) })
		CheckMedia(query, site) => with_fx(tx, |fx| { ..fx, focus: fx.focus.append(CheckMedia(query, site)) })
	}
}

## Queue a follow-up turn for `path` with result `res`.
fx_follow : Tx, List(U32), Result -> (U32, Tx)
fx_follow = |tx, path, res| {
	id = tx.fx.inner
	(id, with_fx(tx, |fx| { ..fx, inner: id + 1, queue: fx.queue.append({ id, path, res }) }))
}

## Issue a site's requests for value `a`.
issue : Tx, List(U32), List(Planned(h)), List(Owned(h)) -> (Tx, List(Owned(h)))
issue = |tx, path, reqs, owned| issue_progress(tx, path, reqs, owned, 0)

issue_progress : Tx, List(U32), List(Planned(h)), List(Owned(h)), U32 -> (Tx, List(Owned(h)))
issue_progress = |tx, path, reqs, owned, progress_ms| {
	var $tx = tx
	var $owned = owned
	var $at = 0
	for planned in reqs {
		req = planned.request
		a = planned.held
		at = $at
		$at = $at + 1
		match req {
			ViewTransition(types) => {
				$tx = with_fx($tx, |fx| collect_transition(fx, types))
			}
			Push(url) => {
				$tx = emit_op($tx, 15, |c| put_str(c.append(1), url))
			}
			Replace(url) => {
				$tx = emit_op($tx, 15, |c| put_str(c.append(2), url))
			}
			Focus(_) | Blur(_) | SelectText(_) | ApplyValue(_) | FocusInPlace(_) | ScrollIntoView(_, _) | ScrollTo(_, _) | PortCommand(_) => {
				# Settled at the end of the turn (see [TurnEnd]).
				$tx = turn_end_later($tx, path, req)
			}
			Title(t) => {
				$tx = emit_op($tx, 17, |c| put_str(c, t))
			}
			StorageSet(k, v) => {
				$tx = emit_op($tx, 16, |c| put_str(put_str(c.append(1), k), v))
			}
			SessionStorageSet(key, value) => {
				$tx = emit_op($tx, 16, |bytes| put_str(put_str(bytes.append(3), key), value))
			}
			SessionStorageRemove(key) => {
				$tx = emit_op($tx, 16, |bytes| put_str(bytes.append(4), key))
			}
			StorageRemove(k) => {
				$tx = emit_op($tx, 16, |c| put_str(c.append(2), k))
			}
			Self => {
				(id, t1) = fx_follow($tx, path, Now)
				$tx = t1
				$owned = $owned.append({ id, sub: False, keep: False, a, at })
			}
			Work({ task, on_dispose, .. }) => {
				t0 = with_fx($tx, |fx| { ..fx, focus: fx.focus.append(CheckTask(task, path)) })
				(id, t1) = fx_admit(t0, path, req)
				$tx = t1
				$owned = $owned.append({ id, sub: False, keep: on_dispose == Keep, a, at })
			}
			Save({ file, name }) => {
				# Opcode 20 is not counted by opcode: index 20 of the work
				# record is `set_checked`.
				{ token, start, len } = file_ref(file)
				{ cmds, next, free, routes, work, paths, site_free, observations, fx } = $tx
				command_at = cmds.len()
				written = put_str(put_u64(put_u64(put_u64(cmds.append(20), token), start), len), name)
				$tx = { cmds: written, next, free, routes, work, paths, site_free, observations, fx: capture_command(fx, { bytes: written, at: command_at, opcode: 20 }) }
			}
			_ => {
				(id, t1) = fx_admit_progress($tx, path, req, progress_ms)
				$tx = t1
				$owned = $owned.append({ id, sub: is_sub(req), keep: is_kept(req), a, at })
			}
		}
	}
	($tx, $owned)
}

## A disposed site's requests (design.md, "Disposal and reparenting"):
## admitted requests (HTTP, storage read) survive and become orphans that
## reparent to the nearest surviving ancestor;
## subscriptions, intervals and timers are stopped (CANCEL) and forgotten;
## queued follow-ups it would have received are dropped and counted stale.
fx_dispose : Tx, Reaction(ctx, a, Result), List(Owned(a)), List(U32) -> (List(Orphan(ctx)), Tx)
fx_dispose = |tx, react, owned, site| {
	run = |env, a, input, path| run_reaction(react, env, a, input, path)
	fx_dispose_by(
		tx,
		{
			owned,
			orphan: |entry| {
				a = entry.a
				{
					id: entry.id,
					run: |current, input| {
						(next, wrote) = run(current, a, input, site)
						(next, wrote, 0)
					},
				}
			},
		},
	)
}

## Only orphan construction varies by delivery policy; cancellation, queued
## refusal cleanup and reparenting remain the one per-kind disposal law.
fx_dispose_by : Tx, { owned : List(Owned(a)), orphan : (Owned(a) -> Orphan(ctx)) } -> (List(Orphan(ctx)), Tx)
fx_dispose_by = |tx, { owned, orphan }| {
	var $tx = tx
	var $orph = []
	for o in owned {
		id = o.id
		if $tx.fx.live.any(|l| l.id == id) {
			if o.keep {
				$orph = $orph.append(orphan(o))
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

## Current orphans retain only their reader, issued-for value and declared
## question code. Older orphans need neither snapshot nor reader.
effect_dispose : EffectCfg(ctx, a, h), { tx : Tx, owned : List(Owned(h)) } -> (List(Orphan(ctx)), Tx)
effect_dispose = |cfg, { tx, owned }| match cfg.only {
	Every => fx_dispose(tx, cfg.react, owned, cfg.path)
	Current({ ids, question }) => {
		react = cfg.react
		path = cfg.path
		fx_dispose_by(
			tx,
			{
				owned,
				orphan: |entry| if ids.contains(entry.id) {
					asked = entry.a
					{
						id: entry.id,
						run: |current, input| if question(current, asked) {
							(next, wrote) = run_reaction(react, current, asked, input, path)
							(next, wrote, 0)
						} else (current, no_layers, 0),
					}
				} else { id: entry.id, run: |current, _input| (current, no_layers, 0) },
			},
		)
	}
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
				live: fx.live.map(|l| if (ids.contains(l.id)) { ..l, path } else l),
				reparented: fx.reparented + ids.len(),
			},
		)
	}
}

## An effect result arriving at the site path itself (not below it).
leaf_fx : List(U32), U64, Payload -> Try(EffectInput, [NotFx])
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
adopt_deliver : List(Orphan(ctx)), ctx, U32, EffectInput, Tx -> (List(Orphan(ctx)), Out(ctx), Tx)
adopt_deliver = |adopted, env, id, res, tx| {
	match adopted.find_first_index(|o| o.id == id) {
		Ok(i) => {
			o = adopted.get(i) ?? crash "adopted"
			run = o.run
			kept = if (keeps_owned(res)) adopted else adopted.drop_at(i)
			(e2, m, sk) = run(env, res)
			(kept, Pending(e2, m), with_fx(count_delivery(tx, res), |fx| { ..fx, skipped: fx.skipped + sk }))
		}
		Err(_) => (adopted, Pending(env, no_layers), fx_count(tx, Stale))
	}
}

## Lower orphans through a state or derived layer at `depth` being
## disposed with final value `v`: the layer is a discarded snapshot.
lower_in : List(Orphan(In(ctx, s))), s, U64 -> List(Orphan(ctx))
lower_in = |os, v, depth| {
	os.map(
		|o| {
			run = o.run
			{
				id: o.id,
				run: |e, r| {
					(inner, m, sk) = run(In.{ outer: e, value: v }, r)
					{ outer, value: _ } = inner
					(outer, layers_below(m, depth), if (layers_empty(layers_from(m, depth))) sk else sk + 1)
				},
			}
		},
	)
}

## Lower orphans through a removed row (key and item are snapshots).
lower_row : List(Orphan(Row(ctx, item))), Str, item, U64 -> List(Orphan(ctx))
lower_row = |os, key, item, depth| {
	os.map(
		|o| {
			run = o.run
			{
				id: o.id,
				run: |e, r| {
					(row, m, sk) = run(Row.{ outer: e, key, item }, r)
					{ outer, key: _, item: _ } = row
					(outer, layers_below(m, depth), if (layers_empty(layers_from(m, depth))) sk else sk + 1)
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
		{ items, keys, order, free, index, lasts, kids, binds, pend, dirty, sels, known, kid_mask, dropped, shown, pending_echo, rnodes } = cols
		var $o = []
		for d in dropped {
			$o = $o.concat(lower_row(d.orphans, d.key, d.item, depth))
		}
		({ items, keys, order, free, index, lasts, kids, binds, pend, dirty, sels, known, kid_mask, dropped: [], shown, pending_echo, rnodes }, $o)
	}
}

## An effect site. `initial`: also issue for the value at mount.
effect : Signal(ctx, a), Bool, (a -> List(Core.Ask(output, error))), (a, a, List(U32) -> List(Core.Ask(output, error))), Reaction(ctx, a, Try(output, error)), [Every, Current] -> Elem(ctx)
	where [a.is_eq : a, a -> Bool]
effect = |v, initial, plan, step, react, delivery| effect_reading(v, initial, |_, value| plan(value), |_, before, value, path| step(before, value, path), react, delivery)

## The plan borrows the current environment only while issuing. The site
## retains its watched value, never a reading used to construct the requests.
effect_reading : Signal(ctx, a), Bool, (ctx, a -> List(Core.Ask(output, error))), (ctx, a, a, List(U32) -> List(Core.Ask(output, error))), Reaction(ctx, a, Try(output, error)), [Every, Current] -> Elem(ctx)
	where [a.is_eq : a, a -> Bool]
effect_reading = |v, initial, plan, step, react, delivery| Site(
	Mount(
		|env, args, tx| {
			a = (v.read)(env)
			question = v.read
			cfg = {
				v,
				plan: |current, value| hold_asks(value, plan(current, value)),
				step: |current, before, value, path| hold_asks(value, step(current, before, value, path)),
				react: held_reaction(react),
				path: args.path,
				only: match delivery {
					Every => Every
					Current => Current({ ids: Dict.empty(), question: |current, held| question(current) == held.value })
				},
			}
			t1 = count_evals(tx, 1)
			if initial {
				(cfg2, t2, owned) = issue_effect(cfg, { tx: t1, planned: (cfg.plan)(env, a), owned: [] })
				(effect_inst(cfg2, a, owned), eff_mask(v), t2)
			} else {
				(effect_inst(cfg, a, []), eff_mask(v), t1)
			}
		},
	),
	|_| eff_mask(v),
)

## An `on_cleanup` site: it holds nothing while it is live, and on disposal
## issues its plan's commands with no owner, since none awaits a result.
cleanup_inst : Str, Signal(ctx, a), (a -> List(Command)) -> Inst(ctx)
cleanup_inst = |name, v, plan| Inst(
	|env, msg, tx| {
		match msg {
			Changed(_) => (cleanup_inst(name, v, plan), Done, tx)
			Fire(_, _, _, _) => (cleanup_inst(name, v, plan), Pending(env, no_layers), tx)
			Dispose(_) => {
				commands = plan((v.read)(env))
				(t1, _) = issue(bump(count_evals(tx, 1), w_cleanups, 1), [], commands.map(|command| { request: command_request(command), held: {} }), [])
				(noop({}), Orphaned([]), with_fx(t1, |fx| { ..fx, cleanups: count_name(fx.cleanups, name) }))
			}
		}
	},
)

## The request that issues a command. The match is total over [Command],
## so a command added there without an arm here does not compile.
command_request : Command -> Request
command_request = |command| match command {
	Push(url) => Push(url)
	Replace(url) => Replace(url)
	Title(text) => Title(text)
	ViewTransition(types) => ViewTransition(types)
	Focus(name) => Focus(name)
	Blur(name) => Blur(name)
	SelectText(name) => SelectText(name)
	ApplyValue(name) => ApplyValue(name)
	FocusInPlace(name) => FocusInPlace(name)
	ScrollIntoView(name, props) => ScrollIntoView(name, props)
	ScrollTo(name, props) => ScrollTo(name, props)
	StorageSet(key, value) => StorageSet(key, value)
	StorageRemove(key) => StorageRemove(key)
	SessionStorageSet(key, value) => SessionStorageSet(key, value)
	SessionStorageRemove(key) => SessionStorageRemove(key)
	PortCommand(sent) => PortCommand(sent)
	Save(saved) => Save(saved)
}

count_name : List((Str, U64)), Str -> List((Str, U64))
count_name = |runs, name| match runs.find_first_index(|(n, _)| n == name) {
	Ok(i) => {
		(_, k) = runs.get(i) ?? crash "internal: cleanup"
		runs.set(i, (name, k + 1)) ?? crash "internal: cleanup"
	}
	Err(_) => runs.append((name, 1))
}

effect_inst : EffectCfg(ctx, a, h), a, List(Owned(h)) -> Inst(ctx)
	where [a.is_eq : a, a -> Bool]
effect_inst = |cfg0, last0, owned0| {
	held = { cfg: cfg0, last: last0, owned: owned0 }
	Inst(
		|env, msg, tx| {
			{ cfg, last, owned } = held
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
							(cfg2, t2, owned2) = issue_effect(cfg, { tx: t1, planned: (cfg.step)(env, last, a, cfg.path), owned })
							(effect_inst(cfg2, a, owned2), Done, t2)
						}
					}
				}
				Fire(path, pos, h, payload) => {
					if pos < path.len() {
						(effect_inst(cfg, last, owned), Pending(env, no_layers), tx)
					} else {
						match payload {
							Fx(res) => effect_deliver(cfg, last, owned, env, h, res, tx)
							_ => (effect_inst(cfg, last, owned), Pending(env, no_layers), tx)
						}
					}
				}
				Dispose(_) => {
					(orph, t2) = effect_dispose(cfg, { tx, owned })
					(noop({}), Orphaned(orph), t2)
				}
			}
		},
	)
}

effect_deliver : EffectCfg(ctx, a, h), a, List(Owned(h)), ctx, U32, EffectInput, Tx -> (Inst(ctx), Out(ctx), Tx)
	where [a.is_eq : a, a -> Bool]
effect_deliver = |cfg, last, owned, env, id, res, tx| {
	match owned.find_first_index(|o| o.id == id) {
		Ok(i) => {
			entry = owned.get(i) ?? crash "owned"
			kept = if (keeps_owned(res)) owned else owned.drop_at(i)
			accepted = accepts_result(cfg.only, id)
			react = cfg.react
			path = cfg.path
			next = effect_inst(retire_current(cfg, { id, input: res }), last, kept)
			(env2, wrote) = if (accepted) run_reaction(react, env, entry.a, res, path) else (env, no_layers)
			(next, Pending(env2, wrote), count_delivery(tx, res))
		}
		Err(_) => (effect_inst(cfg, last, owned), Pending(env, no_layers), fx_count(tx, Stale))
	}
}

# Supersession (design.md, "Supersession and asynchronous layers").
#
# A `watch_latest` or `resource` site owns only the requests of its current
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

## A `watch_latest` site: an effect site that supersedes its requests whenever
## its watched value changes. Results and disposal are an effect site's.
latest_inst : EffectCfg(ctx, a, h), a, List(Owned(h)) -> Inst(ctx)
	where [a.is_eq : a, a -> Bool]
latest_inst = |cfg0, last0, owned0| {
	held = { cfg: cfg0, last: last0, owned: owned0 }
	Inst(
		|env, msg, tx| {
			{ cfg, last, owned } = held
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
							(t2, owned2) = issue_progress(fx_supersede(t1, owned), cfg.path, (cfg.plan)(env, a), [], progress_interval(cfg.react))
							(latest_inst(cfg, a, owned2), Done, t2)
						}
					}
				}
				Fire(path, pos, h, payload) => {
					match leaf_fx(path, pos, payload) {
						Ok(res) => latest_deliver(cfg, last, owned, env, h, res, tx)
						Err(_) => (latest_inst(cfg, last, owned), Pending(env, no_layers), tx)
					}
				}
				Dispose(_) => {
					(orph, t2) = fx_dispose(tx, cfg.react, owned, cfg.path)
					(noop({}), Orphaned(orph), t2)
				}
			}
		},
	)
}

latest_deliver : EffectCfg(ctx, a, h), a, List(Owned(h)), ctx, U32, EffectInput, Tx -> (Inst(ctx), Out(ctx), Tx)
	where [a.is_eq : a, a -> Bool]
latest_deliver = |cfg, last, owned, env, id, res, tx| {
	match owned.find_first_index(|o| o.id == id) {
		Ok(i) => {
			entry = owned.get(i) ?? crash "owned"
			kept = if (keeps_owned(res)) owned else owned.drop_at(i)
			react = cfg.react
			next = latest_inst(cfg, last, kept)
			(env2, wrote) = run_reaction(react, env, entry.a, res, cfg.path)
			(next, Pending(env2, wrote), count_delivery(tx, res))
		}
		Err(_) => (latest_inst(cfg, last, owned), Pending(env, no_layers), fx_count(tx, Stale))
	}
}

## The whole answer of a gathered question once no job is working: every
## output in input order, or the first failure in input order. While any
## job works, `all` stays as it is (`Pending`, with the previous answer).
gathered_all : Core.Remote(List(output), error), List(Core.JobState(output, error)) -> Core.Remote(List(output), error)
gathered_all = |all, jobs| {
	var $outputs = []
	var $failed = []
	for job in jobs {
		match job {
			Working => {
				return all
			}
			Answered(output) => {
				$outputs = $outputs.append(output)
			}
			Failed(error) => {
				$failed = $failed.append(error)
			}
		}
	}
	match $failed {
		[error, ..] => { request: Idle, answer: Failed(error) }
		[] => { request: Idle, answer: Answered($outputs) }
	}
}

## What `on_post` issues when its outbox changes from `last` to `box`: the
## requests for the new post. The serial moves by one for each post, so a
## jump of more than one means a handler posted again before the site saw
## the first post, which would never be sent: a contract error.
posted_step : (item -> List(request)) -> (Core.Outbox(item), Core.Outbox(item), List(U32) -> List(request))
posted_step = |plan| |last, box, path| {
	{ serial: was, posted: _ } = last
	{ serial, posted } = box
	if serial > was + 1 {
		crash "contract: on_post's outbox was posted ${(serial - was).to_str()} times in one turn, so only the last post would be sent; post a list to send several things at once (site ${show_path(path)})"
	}
	match posted {
		Posted(item) => plan(item)
		Unposted => []
	}
}

## A reaction to a post's results, given the item posted.
posted_reaction : Core.Reaction(ctx, item, result) -> Core.Reaction(ctx, Core.Outbox(item), result)
posted_reaction = |react| {
	run = react.run
	{
		progress: match react.progress {
			NoProgress => NoProgress
			Reporting(report) => Reporting({
				every_ms: report.every_ms,
				run: |env, box, transfer, site| match box.last() {
					Posted(item) => (report.run)(env, item, transfer, site)
					Unposted => (env, no_layers)
				},
			})
		},
		run: |env, box, res, site| match box.last() {
			Posted(item) => run(env, item, res, site)
			Unposted => (env, no_layers)
		},
	}
}

## A `follow` layer settled by one result.
settled_remote : Try(output, error) -> Core.Remote(output, error)
settled_remote = |outcome| match outcome {
	Ok(output) => { request: Idle, answer: Answered(output) }
	Err(error) => { request: Idle, answer: Failed(error) }
}

## Fixed per `resource` site.
ResourceCfg(ctx, a, s, h) : {
	input : Signal(ctx, a),
	pending : (s, a -> s),
	plan : (a -> List(Planned(h))),
	resolve : (s, h, U64, Result -> s),
	path : List(U32),
	depth : U64,
}

## A `resource` site: `last` is the input its requests were issued for, `s`
## the layer's value at absolute depth `rc.depth`. The layer keeps its
## previous value only while its replacement is compared with it, so
## `pending` and `resolve` receive it shared: they should build a fresh value
## rather than update a large one in place.
resource_inst : ResourceCfg(ctx, a, s, h), a, s, List(Owned(h)), Block(In(ctx, s)) -> Inst(ctx)
	where [a.is_eq : a, a -> Bool, s.is_eq : s, s -> Bool]
resource_inst = |rc0, last0, s0, owned0, block0| {
	held = { rc: rc0, last: last0, s: s0, owned: owned0, block: block0 }
	Inst(
		|env, msg, tx| {
			{ rc, last, s, owned, block } = held
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
							s2 = (rc.pending)(s, a)
							(t2, owned2) = issue(fx_supersede(t1, owned), rc.path, (rc.plan)(a), [])
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
						Ok(Final(res, live)) => resource_deliver(rc, last, s, owned, block, env, h, res, live, tx)
						Ok(Progress(_)) => crash "contract: progress delivered to a resource without a progress reaction"
						Err(_) => {
							match fire_target(block, path, pos) {
								Leaf => {
									(b2, out, t2) = fire_leaf(block, In.{ outer: env, value: s }, h, payload, path, tx)
									resource_settle(rc, last, owned, b2, out, t2)
								}
								Kid => {
									(b2, out, t2) = fire_kid(block, In.{ outer: env, value: s }, path, pos, h, payload, tx)
									resource_settle(rc, last, owned, b2, out, t2)
								}
								Miss => (resource_inst(rc, last, s, owned, block), Pending(env, no_layers), tx)
							}
						}
					}
				}
				Dispose(remove) => {
					# The site's own requests follow the per-kind rules; an admitted
					# one becomes an orphan whose resolve writes the retired layer, a
					# snapshot whose write `lower_in` skips and counts.
					resolve = rc.resolve
					depth = rc.depth
					react = {
						run: |e, (a, at), r, _| {
							{ outer, value } = e
							(In.{ outer, value: resolve(value, a, at, r) }, one_layer(depth))
						},
						progress: NoProgress,
					}
					(mine, t1) = fx_dispose(tx, react, owned.map(|o| { id: o.id, sub: o.sub, keep: o.keep, a: (o.a, o.at), at: o.at }), rc.path)
					(orph, t2) = dispose_block(block, In.{ outer: env, value: s }, remove, t1)
					(noop({}), Orphaned(lower_in(mine.concat(orph), s, rc.depth)), t2)
				}
			}
		},
	)
}

## A result for a request the site owns resolves the layer. An equal
## value changes nothing. Otherwise the site refreshes its own subtree
## now: the answer writes nothing else, so nothing above has a pass to
## run first.
resource_deliver : ResourceCfg(ctx, a, s, h), a, s, List(Owned(h)), Block(In(ctx, s)), ctx, U32, Result, Bool, Tx -> (Inst(ctx), Out(ctx), Tx)
	where [a.is_eq : a, a -> Bool, s.is_eq : s, s -> Bool]
resource_deliver = |rc, last, s, owned, block, env, id, res, live, tx| {
	match owned.find_first_index(|o| o.id == id) {
		Ok(i) => {
			entry = owned.get(i) ?? crash "owned"
			kept = if (live) owned else owned.drop_at(i)
			s2 = (rc.resolve)(s, entry.a, entry.at, res)
			t1 = fx_count(tx, Delivered)
			if s2 == s {
				(resource_inst(rc, last, s2, kept, block), Pending(env, no_layers), t1)
			} else {
				own = bit(rc.depth)
				(b2, t2) = refresh(block, In.{ outer: env, value: s2 }, own, bump(t1, w_dirty_roots, 1))
				(resource_inst(rc, last, s2, kept, b2), Pending(env, no_layers), t2)
			}
		}
		Err(_) => (resource_inst(rc, last, s, owned, block), Pending(env, no_layers), fx_count(tx, Stale))
	}
}

## An asynchronous layer has no write handle, so an event below it can only
## have changed an outer layer (which will refresh this site) or nothing.
resource_settle : ResourceCfg(ctx, a, s, h), a, List(Owned(h)), Block(In(ctx, s)), Out(In(ctx, s)), Tx -> (Inst(ctx), Out(ctx), Tx)
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

## The boot section decoders consume bounded bodies, so a malformed field
## cannot shift the following section. This table is the extension point for
## browser facts; every nonempty payload must contain each row, in order.
boot_sections : List(Str) -> List({ tag : U8, name : Str, read : Boot, List(U8) -> Try(Boot, Str) })
boot_sections = |queries| [
	{
		tag: 1,
		name: "location",
		read: |boot, body| {
			(url, at) = boot_str(body, 0)?
			boot_end(body, at)?
			Ok({ ..boot, url })
		},
	},
	{
		tag: 2,
		name: "local-storage",
		read: |boot, body| {
			available = boot_flag(body, 0)?
			count = boot_u32(body, 1)?.to_u64()
			var $at = 5.U64
			var $pairs = []
			var $index = 0.U64
			while $index < count {
				(key, next) = boot_str(body, $at)?
				(value, end) = boot_str(body, next)?
				$pairs = $pairs.append((key, value))
				$at = end
				$index = $index + 1
			}
			boot_end(body, $at)?
			if !available and !$pairs.is_empty() {
				return Err("pairs while storage is unavailable")
			}
			Ok({ ..boot, storage: $pairs, storage_available: available })
		},
	},
	{
		tag: 3,
		name: "connectivity",
		read: |boot, body| {
			online = boot_flag(body, 0)?
			boot_end(body, 1)?
			Ok({ ..boot, online })
		},
	},
	{
		tag: 4,
		name: "visibility",
		read: |boot, body| {
			visible = boot_flag(body, 0)?
			boot_end(body, 1)?
			Ok({ ..boot, visible })
		},
	},
	{
		tag: 6,
		name: "media",
		read: |boot, body| {
			if body.len() != queries.len() {
				return Err("media flag count differs from declared query count")
			}
			var $pairs = []
			var $at = 0.U64
			for query in queries {
				matches = boot_flag(body, $at)?
				$pairs = $pairs.append((query, matches))
				$at = $at + 1
			}
			Ok({ ..boot, media: $pairs })
		},
	},
	{
		tag: 7,
		name: "time",
		read: |boot, body| {
			now_ms = boot_u64(body, 0)?.to_i64_wrap()
			boot_end(body, 8)?
			Ok({ ..boot, now_ms })
		},
	},
	{
		tag: 8,
		name: "seed",
		read: |boot, body| {
			low = boot_u64(body, 0)?.to_u128()
			high = boot_u64(body, 8)?.to_u128()
			boot_end(body, 16)?
			Ok({ ..boot, seed: low + high.shl_wrap(64) })
		},
	},
	{
		tag: 9,
		name: "languages",
		read: |boot, body| {
			count = boot_u32(body, 0)?.to_u64()
			if count == 0 or count > 16 {
				return Err("expected 1 to 16 languages")
			}
			var $at = 4.U64
			var $languages = []
			while $languages.len() < count {
				(language, after) = boot_str(body, $at)?
				if language.count_utf8_bytes() > 64 {
					return Err("language exceeds 64 UTF-8 bytes")
				}
				$languages = $languages.append(language)
				$at = after
			}
			boot_end(body, $at)?
			Ok({ ..boot, languages: $languages })
		},
	},
	{
		tag: 10,
		name: "time-zone",
		read: |boot, body| {
			(name, after_name) = boot_str(body, 0)?
			from_ms = boot_u64(body, after_name)?.to_i64_wrap()
			until_ms = boot_u64(body, after_name + 8)?.to_i64_wrap()
			count = boot_u32(body, after_name + 16)?.to_u64()
			if count == 0 or count > 128 {
				return Err("expected 1 to 128 zone offsets")
			}
			var $at = after_name + 20
			var $offsets = []
			while $offsets.len() < count {
				start = boot_u64(body, $at)?.to_i64_wrap()
				minutes = boot_u32(body, $at + 8)?.to_i32_wrap()
				$offsets = $offsets.append({ from_ms: start, minutes })
				$at = $at + 12
			}
			boot_end(body, $at)?
			zone = { name, from_ms, until_ms, offsets: $offsets }
			check_zone(zone)?
			Ok({ ..boot, zone })
		},
	},
	{
		tag: 11,
		name: "session-storage",
		read: |boot, body| {
			available = boot_flag(body, 0)?
			count = boot_u32(body, 1)?.to_u64()
			var $at = 5.U64
			var $pairs = []
			var $index = 0.U64
			while $index < count {
				(key, next) = boot_str(body, $at)?
				(value, end) = boot_str(body, next)?
				$pairs = $pairs.append((key, value))
				$at = end
				$index = $index + 1
			}
			boot_end(body, $at)?
			if !available and !$pairs.is_empty() {
				return Err("pairs while storage is unavailable")
			}
			Ok({ ..boot, session: $pairs, session_available: available })
		},
	},
]

## The zone shape is checked at the boot boundary and for a hand-built
## value passed to zone_offset. No malformed table is treated as a UTC guess.
check_zone : Core.Zone -> Try({}, Str)
check_zone = |zone| {
	if zone.name.count_utf8_bytes() > 64 {
		return Err("zone name exceeds 64 UTF-8 bytes")
	}
	if zone.from_ms > zone.until_ms {
		return Err("zone span starts after it ends")
	}
	if zone.offsets.is_empty() or zone.offsets.len() > 128 {
		return Err("expected 1 to 128 zone offsets")
	}
	first = zone.offsets.first() ?? crash "internal: zone has no first offset"
	if first.from_ms != zone.from_ms {
		return Err("first zone offset must start at from_ms")
	}
	var $previous = zone.from_ms
	var $first = True
	for offset in zone.offsets {
		if offset.from_ms < zone.from_ms or offset.from_ms > zone.until_ms {
			return Err("zone offset starts outside the span")
		}
		if !$first and offset.from_ms <= $previous {
			return Err("zone offsets must start in strictly ascending order")
		}
		$first = False
		$previous = offset.from_ms
	}
	Ok({})
}

## Read the bits of signed time fields without losing their I64 endpoints.
boot_u64 : List(U8), U64 -> Try(U64, Str)
boot_u64 = |bytes, at| {
	low = boot_u32(bytes, at)?.to_u64()
	high = boot_u32(bytes, at + 4)?.to_u64()
	Ok(low + high.shl_wrap(32))
}

## Seeds cross as exactly sixteen little-endian bytes rather than a number
## converted through JavaScript's narrower integer representation.
put_u128 : List(U8), U128 -> List(U8)
put_u128 = |bytes, seed| {
	var $bytes = bytes
	var $seed = seed
	var $index = 0.U64
	while $index < 16 {
		$bytes = $bytes.append($seed.to_u8_wrap())
		$seed = $seed.shr_zf_wrap(8)
		$index = $index + 1
	}
	$bytes
}

## Read a little-endian length without trapping, including at an empty tail.
boot_u32 : List(U8), U64 -> Try(U32, Str)
boot_u32 = |bytes, at| match bytes.sublist({ start: at, len: 4 }) {
	[a, b, c, d] => Ok(a.to_u32() + b.to_u32().shl_wrap(8) + c.to_u32().shl_wrap(16) + d.to_u32().shl_wrap(24))
	_ => Err("truncated length")
}

## Text is validated within the section that owns it, never lossily repaired.
boot_str : List(U8), U64 -> Try((Str, U64), Str)
boot_str = |bytes, at| {
	count = boot_u32(bytes, at)?.to_u64()
	start = at + 4
	if count > bytes.len() - start {
		return Err("truncated text")
	}
	text = Str.from_utf8(bytes.sublist({ start, len: count })) ? |_| "text is not UTF-8"
	Ok((text, start + count))
}

## Browser flags have exactly two encodings.
boot_flag : List(U8), U64 -> Try(Bool, Str)
boot_flag = |bytes, at| match bytes.get(at) {
	Ok(0) => Ok(False)
	Ok(1) => Ok(True)
	_ => Err("expected a flag (0 or 1)")
}

## Each section consumes its body exactly, including its final field.
boot_end : List(U8), U64 -> Try({}, Str)
boot_end = |bytes, at| if (at == bytes.len()) Ok({}) else Err("unexpected trailing bytes in body")

## Length-prefix a section shared by boot and declaration encoders.
put_section : List(U8), U8, List(U8) -> List(U8)
put_section = |bytes, tag, body| put_u32(bytes.append(tag), body.len().to_u32_wrap()).concat(body)

## Reject values the runtime could not have supplied for this program. The
## structural parser has no program catalogue, so membership is checked here,
## before either the store or the view sees boot data.
check_boot_keys : Boot, List(Str) -> Try({}, Str)
check_boot_keys = |boot, keys| {
	for (key, _) in boot.storage {
		if !keys.contains(key) {
			return Err("contract: boot section 2 (local-storage) pair for undeclared key \"${key}\"")
		}
	}
	Ok({})
}

## A routed call reserves its header before running any turn. A stale call
## leaves its recycled buffer empty and allocates no header. Scratch buffers stay empty.
start_batch : Tx -> Tx
start_batch = |{ cmds, next, free, routes, work, paths, site_free, observations, fx }| {
	{ cmds: if (cmds.is_empty()) cmds.append(0) else cmds, next, free, routes, work, paths, site_free, observations, fx }
}

new_tx : List(U8) -> Tx
new_tx = |cmds| { cmds: cmds.append(0), next: 1, free: [], routes: [], work: work_zero, paths: [[]], site_free: [], observations: { echo: False, shown: [] }, fx: fx_empty }

## One turn: fire down `path`; then the root's Changed pass for the cells
## the event wrote, which the layers it wrote with them join where the
## pass reaches their sites (`waits_for_outer`); then a `Settle` walk down
## the same path for those the pass did not reach; then the turn's focus
## commands (resolved now, so a reference mounted later in the same turn
## is found; a missing one is counted stale).
turn : App(st), List(U32), U32, Payload -> App(st)
turn = |{ store, root, tx, programs }, path, h, payload| {
	(root2, out, tx2) = call(root, Root.{ store }, Fire(path, 0, h, payload), bump(tx, w_turns, 1))
	(store2, writes) = root_answer(out)
	force = tx2.observations.echo
	if layers_empty(writes) {
		if force {
			(root3, answer3, tx3) = call(root2, Root.{ store: store2 }, Fire(path, 0, h, Settle(no_layers, True)), tx2)
			{ store: root_answer(answer3).0, root: root3, tx: flush_turn(tx3, programs), programs }
		} else {
			{ store: store2, root: root2, tx: flush_turn(tx2, programs), programs }
		}
	} else {
		cells = cells_of(writes)
		waiting = layers_from(writes, 0)
		(root3, answer3, tx3) = call(root2, Root.{ store: store2 }, Changed(layers_sig(cells)), bump(tx2, w_dirty_roots, layers_count(cells)))
		(store3, _) = root_answer(answer3)
		if layers_empty(waiting) and !force {
			{ store: store3, root: root3, tx: flush_turn(tx3, programs), programs }
		} else {
			(root4, answer4, tx4) = call(root3, Root.{ store: store3 }, Fire(path, 0, h, Settle(waiting, force)), tx3)
			{ store: root_answer(answer4).0, root: root4, tx: flush_turn(tx4, programs), programs }
		}
	}
}

## The end of a turn (see [TurnEnd]): command 18 REF for each focus or
## scroll request, the catalogue check of each work and port request
## against the instance's `programs`, in issue order, and then the bytes of
## the turn's port requests, each where it was issued (see [PortAt]).
flush_turn : Tx, Catalogue -> Tx
flush_turn = |incoming, programs| {
	guard = incoming.fx.guard
	on = guard.live > 0
	tx = if (on == guard.emitted) incoming else emit_op(with_fx(incoming, |fx| { ..fx, guard: { live: guard.live, emitted: on } }), 25, |bytes| bytes.append(if (on) 1 else 0))
	if tx.fx.focus.is_empty() {
		{ ..tx, fx: with_capture(tx.fx, |capture| PictureCapture.seal(capture, [])), observations: { echo: False, shown: tx.observations.shown.clear() } }
	} else {
		reqs = tx.fx.focus
		for check in reqs {
			match check {
				CheckRef(name) => match tx.fx.refs.get(name) ?? [] {
					[first, second, ..] => crash "contract: duplicate reference \"${name}\" at sites ${show_path(first.path)} and ${show_path(second.path)}"
					_ => {}
				}
				_ => {}
			}
		}
		var $tx = with_fx(tx, |fx| { ..fx, focus: [] })
		for entry in reqs {
			match entry {
				Focus(op, name) =>
					match ($tx.fx.refs.get(name) ?? []).first() {
						Ok({ node, path, value_control }) => {
							if op == 4 and !value_control {
								crash "contract: ApplyValue reference \"${name}\" is not a value control at site ${show_path(path)}"
							}
							$tx = emit_op($tx, 18, |c| put_u32(c.append(op), node))
						}
						Err(_) => {
							$tx = with_fx($tx, |fx| { ..fx, stale: fx.stale + 1 })
						}
					}
				ScrollIntoView(name, props) => match ($tx.fx.refs.get(name) ?? []).first() {
					Ok({ node, .. }) => {
						$tx = emit_op($tx, 18, |commands| put_u32(commands.append(6), node).append(align_byte(props.block)).append(align_byte(props.inline)).append(behavior_byte(props.behavior)))
					}
					Err(_) => {
						$tx = with_fx($tx, |fx| { ..fx, stale: fx.stale + 1 })
					}
				}
				ScrollTo(name, props) => match ($tx.fx.refs.get(name) ?? []).first() {
					Ok({ node, .. }) => {
						$tx = emit_op($tx, 18, |commands| put_edge(put_edge(put_u32(commands.append(7), node), props.top), props.left).append(behavior_byte(props.behavior)))
					}
					Err(_) => {
						$tx = with_fx($tx, |fx| { ..fx, stale: fx.stale + 1 })
					}
				}
				CheckTask(task, path) =>
					if !programs.workers.contains(task) {
						crash "contract: worker task \"${task}\" is not registered; add its registration to with_workers (site ${show_path(path)})"
					}
				CheckMedia(query, path) => if !programs.media.contains(query) {
					crash "contract: media query \"${query}\" is not declared (site ${show_path(path)})"
				}
				Port(at) => (programs.ports.check)(programs.ports.decls, at)
				Drift(_) | CheckRef(_) => {}
			}
		}
		written = (programs.ports.write)($tx, reqs)
		{ ..written, fx: with_capture(written.fx, |capture| PictureCapture.seal(capture, [])), observations: { echo: False, shown: written.observations.shown.clear() } }
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
## Total work is bounded too. The turns of depth 1 are bounded by the
## external turn: it queued one follow-up for each request it issued past
## the in-flight bound and one for each `Self` it asked for, and nothing
## adds to them once it has returned, since whatever a follow-up's turn
## queues is deeper. Their number follows what the turn drew (a refusal for
## each of thousands of rows that fetch at mount), so they are not counted:
## a count that follows an app's data is not a loop. The turns of depth 2
## or more are counted, at most `max_breadth(max_inflight)` per host call:
## a loop in which each follow-up queues two or more reaches that long
## before it reaches the depth bound.
drain : App(st) -> App(st)
drain = |app0| {
	var $app = app0
	var $deep_turns = 0.U64
	var $depth = 1.U64
	var $below_next = app0.tx.fx.next
	var $below_inner = app0.tx.fx.inner
	breadth = max_breadth(app0.tx.fx.max)
	while !$app.tx.fx.queue.is_empty() {
		{ store, root, tx, programs } = $app
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
		if $depth > 1 {
			if $deep_turns >= breadth {
				crash "resource_limit: the follow-up turns that follow-ups queued in one call exceeded 64 per in-flight slot (at least 4096) at site ${show_path(q.path)}: follow-ups are multiplying (feedback loop), or a follow-up's own turn issued far more requests than the in-flight bound admits (raise max_inflight)"
			}
			$deep_turns = $deep_turns + 1
		}
		tx1 = with_fx(tx, |fx| { ..fx, queue: fx.queue.drop_first(1) })
		$app = turn({ store, root, tx: tx1, programs }, q.path, q.id, Fx(Final(q.res, False)))
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

## Every non-disposal root call returns the uniquely owned store with its writes.
root_answer : Out(Root(st)) -> (st, Layers)
root_answer = |out| match out {
	Pending(env, writes) => (env.store, writes)
	_ => crash "internal: root call must hand the store back"
}

## Hand over the command batch (taking `buf` in its place) and write the
## work record into `wbuf`.
finish : App(st), List(U8), List(U8) -> (App(st), List(U8), List(U8))
finish = |inst, buf, wbuf| {
	(a2, cmds) = Core.take_cmds(inst, buf)
	w = work_bytes(a2, wbuf)
	(a2, cmds, w)
}

## The work record (design.md, Appendix B): `count:u32 (counter:u64)*`
## in `w_` index order followed by the effect counters (`fx_counters`),
## then `n:u32 (name:str runs:u64)*` for the cleanups that have run.
## Written into `buf`, which is cleared first.
work_bytes : App(st), List(U8) -> List(U8)
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
	$b = put_u64(put_u64(put_u64($b, work_get(counters, w_port_sends)), work_get(counters, 41)), work_get(counters, 42))
	$b = put_u64(put_u64(put_u64($b, work_get(counters, 43)), fx.observed.live), work_get(counters, 45))
	$b = put_u64($b, work_get(counters, 46))
	$b = put_u64($b, work_get(counters, 47))
	$b = put_u64($b, work_get(counters, 48))
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
	drifts = b.focus.keep_oks(
		|entry| match entry {
			Drift(what) => Ok(what)
			_ => Err(NotDrift)
		},
	)
	pairs = [
		("live leave guards", a.guard.live, b.guard.live),
		("issued", a.issued, b.issued),
		("refused", a.refused, b.refused),
		("stale", a.stale, b.stale),
		("cancelled", a.cancelled, b.cancelled),
		("in flight", a.live.len(), b.live.len()),
		("queued follow-ups", a.queue.len(), b.queue.len()),
		("end-of-turn focus requests, program checks and port requests", a.focus.len(), b.focus.len() - drifts.len()),
	]
	changed = pairs.keep_if(|(_, x, y)| x != y).map(|(name, x, y)| "${name} ${x.to_str()} -> ${y.to_str()}")
	Str.join_with(drifts.concat(changed).concat(if (b.batch.asked) ["view transition requested by settle check"] else []), ", ")
}

## The worker catalogue lists its names in order, and a duplicate name or a
## 65th registration is the contract error that names the task.
expect {
	reg = |name| Core.registration(name, |b, _| b)
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
		"Err(\"contract: worker task \\\"a\\\" is registered twice in with_workers\")",
		"True",
		"Err(\"contract: with_workers registers more than 64 worker tasks (task \\\"p64\\\" is over the bound)\")",
	]
	actual == expected
}

## A file's spans cover it in order, the last one shorter, and a range's
## spans are relative to the range, as `read!` reads them.
expect {
	file = |len| match Core.placed_file(Core.held_file(Box.box(1)), { name: "log", mime: "", size: 10, start: 0, len }) {
		Ok(placed) => placed
		Err(Malformed) => crash "spans expect: the file lies within its size"
	}
	actual =
		\\ten by four: ${Str.inspect(file(10).spans(4))}
		\\ten by ten: ${Str.inspect(file(10).spans(10))}
		\\ten by twenty: ${Str.inspect(file(10).spans(20))}
		\\empty: ${Str.inspect(file(0).spans(4))}
		\\range: ${Str.inspect(file(10).slice({ start: 3, len: 5 }).spans(2))}
	expected =
		\\ten by four: [{ len: 4, start: 0 }, { len: 4, start: 4 }, { len: 2, start: 8 }]
		\\ten by ten: [{ len: 10, start: 0 }]
		\\ten by twenty: [{ len: 10, start: 0 }]
		\\empty: []
		\\range: [{ len: 2, start: 0 }, { len: 2, start: 2 }, { len: 1, start: 4 }]
	actual == expected
}

## A job's answer as the worker writes it holds no files when its output
## holds none, and the page reads it back as result tag 10.
expect {
	answer = Core.task_answer("t/echo", [7, 8], [])
	page = Core.decode_res([10].concat(answer))
	(answer, page) == ([0, 0, 0, 0, 7, 8], Work({ output: [7, 8], files: [] }))
}

## A request for a preparation's task carries its cancel policy and where
## the preparation's input lies; one for a task of its own carries neither
## operand.
expect {
	alone = put_work([], "t/a", [1, 2], [], 0, Finish, Unprepared)
	asked = put_work([], "t/b", [1, 2, 3], [], 5, Stop, Prepared({ name: "t/p", input_len: 2, input_files: 0 }))
	actual = (alone.drop_first(1 + 4 + 3 + 4 + 2 + 4 + 4), asked.drop_first(1 + 4 + 3 + 4 + 3 + 4 + 4))
	actual == ([2, 0], [1, 1, 3, 0, 0, 0, 116, 47, 112, 2, 0, 0, 0, 0, 0, 0, 0])
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
					Core.when(st.signal(), || Core.watch(Core.const({}), |_| [Work({ task: "t/echo", input: [1], files: [], timeout_ms: 0, on_dispose: Stop, on_cancel: Stop, prepared: Unprepared })].map(Core.raw), Core.ignore({})), || Core.text("")),
					Core.watch(Core.const({}), |_| [Core.again({})], st.on_result(|_, _, _| Bool.False)),
				],
			),
	)
	mounted = mount_in(32, { workers: ["t/echo"], ports: no_ports, media: [] }, {}, elem)
	s = Core.fx_stats(mounted)
	[s.issued, s.cancelled, s.live, s.reparented] == [1, 1, 0, 0]
}

## The breadth bound does not count the follow-ups an external turn queued
## itself. A mount that asks for 4200 timers with 4 slots is refused 4196
## times, more follow-up turns than the bound of 4096, and every refusal
## reaches its reaction; a follow-up each of the first 100 reactions asks for
## is depth 2, and those are well within the bound.
expect {
	elem = Core.state(
		0.U64,
		|seen| Core.element(
			"div",
			[],
			[
				Core.watch(Core.const({}), |_| List.repeat(Core.timer(1), 4200), seen.on_result(|n, _, _| n + 1)),
				Core.watch(seen.signal(), |n| if (n >= 1 and n <= 100) [Core.again({})] else [], Core.ignore({})),
			],
		),
	)
	stats = Core.fx_stats(Core.mount_with(4, elem))
	[stats.issued, stats.refused, stats.delivered, stats.live] == [4, 4196, 4296, 4]
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

## The port catalogue keeps its declarations in order and refuses a name
## declared twice, a 65th port, an empty name and an `Every` bound outside 1
## to 1024, each with the contract diagnostic that names the port.
expect {
	decl = |name| Core.port_declaration(name, Call)
	var $many = []
	var $i = 0.U64
	while $i < 65 {
		$many = $many.append(decl("p${$i.to_str()}"))
		$i = $i + 1
	}
	names = |r| r.map_ok(|ds| ds.map(|d| d.name))
	actual = [
		Str.inspect(names(Core.port_catalogue([decl("a"), Core.port_declaration("b", Subscription(Latest))]))),
		Str.inspect(names(Core.port_catalogue([decl("a"), Core.port_declaration("a", Command)]))),
		Str.inspect(Core.port_catalogue($many.take_first(64)).is_ok()),
		Str.inspect(names(Core.port_catalogue($many))),
		Str.inspect(names(Core.port_catalogue([decl("")]))),
		Str.inspect(names(Core.port_catalogue([Core.port_declaration("s", Subscription(Every(0)))]))),
		Str.inspect(names(Core.port_catalogue([Core.port_declaration("s", Subscription(Every(1024)))]))),
	]
	expected = [
		"Ok([\"a\", \"b\"])",
		"Err(\"contract: port \\\"a\\\" is declared twice\")",
		"True",
		"Err(\"contract: a program declares more than 64 ports (port \\\"p64\\\" is over the bound)\")",
		"Err(\"contract: a program declares a port named \\\"\\\"; a port name is 1 to 128 bytes\")",
		"Err(\"contract: port \\\"s\\\" delivers Every(0); a subscription keeps 1 to 1024 undelivered messages\")",
		"Ok([\"s\"])",
	]
	actual == expected
}

## A port command is `PORT` (opcode 19) with its message and is counted at
## index 40, not by opcode; a call is `FX` kind 9 and a subscription kind 10.
expect {
	msg = { json: "{\"a\":1}", blobs: [[7, 8]], files: [] }
	ports = [Core.port_declaration("t/c", Command), Core.port_declaration("t/k", Call), Core.port_declaration("t/s", Subscription(Every(4)))]
	elem = Core.watch(Core.const({}), |_| [PortCommand({ port: "t/c", message: msg }), PortCall({ port: "t/k", message: msg, timeout_ms: 700000 }), PortSubscribe({ port: "t/s", message: msg })].map(Core.raw), Core.ignore({}))
	mounted = mount_in(32, { workers: [], ports: ports_of(ports), media: [] }, {}, elem)
	(taken, cmds) = Core.take_cmds(mounted, [])
	body = put_u32(put_u32(put_u32(put_str([], "{\"a\":1}"), 1), 2).concat([7, 8]), 0)
	want = put_str([19], "t/c").concat(body).concat(put_u32(put_str(put_u32([13], 1).append(9), "t/k").concat(body), 600000)).concat(put_str(put_u32([13], 2).append(10), "t/s").concat(body))
	counters = Core.work_counters(taken)
	cmds == [0].concat(want) and counters.get(19) == Ok(0) and counters.get(40) == Ok(1) and Core.fx_stats(taken).issued == 2
}

## A cleanup's commands issue the requests of the same tags, carrying the
## same values, in the plan's order; `File.save` builds a command as well as
## a request.
expect {
	file = Core.placed_file(Core.held_file(Box.box(1)), { name: "log", mime: "", size: 10, start: 0, len: 10 }) ?? crash "command expect: the file lies within its size"
	message = { json: "1", blobs: [], files: [] }
	commands : List(Core.Command)
	commands = [Push("/a"), Replace("/b"), Title("t"), Focus("f"), Blur("g"), SelectText("h"), ApplyValue("v"), FocusInPlace("f"), Core.scroll_into_view("s", {}), ScrollTo("s", { top: End, left: Px(7), behavior: Instant }), StorageSet("k", "v"), StorageRemove("r"), PortCommand({ port: "t/c", message }), File.save(file, { name: Named("copy") })]
	requests : List(Core.Request)
	requests = [Push("/a"), Replace("/b"), Title("t"), Focus("f"), Blur("g"), SelectText("h"), ApplyValue("v"), FocusInPlace("f"), Core.scroll_into_view("s", {}), ScrollTo("s", { top: End, left: Px(7), behavior: Instant }), StorageSet("k", "v"), StorageRemove("r"), PortCommand({ port: "t/c", message }), Save({ file, name: "copy" })]
	commands.map(command_request) == requests
}

## A disposed scope's cleanup issues its commands in the disposing turn, in
## the plan's order and before the branch that replaces its scope is built,
## and counts one run under its name.
expect {
	elem = Core.state(
		Bool.True,
		|st|
			Core.element(
				"div",
				[],
				[
					Core.when(st.signal(), || Core.on_cleanup("closing", Core.const("a"), |name| [Title(name), StorageSet("last", name), StorageRemove("draft")]), || Core.text("")),
					Core.watch(Core.const({}), |_| [Core.again({})], st.on_result(|_, _, _| Bool.False)),
				],
			),
	)
	(taken, cmds) = Core.take_cmds(mount_in(32, { workers: [], ports: ports_of([]), media: [] }, {}, elem), [])
	mounted = put_str(put_str(put_u32(put_u32(put_u32([8], 1), 0), 0).append(0), ""), "div").append(0).concat(put_str(put_u32(put_u32(put_u32([10], 2), 1), 0), ""))
	cleaned = put_str([17], "a").concat(put_str(put_str([16, 1], "last"), "a")).concat(put_str([16, 2], "draft"))
	replaced = put_str(put_u32(put_u32(put_u32([10], 3), 0), 2), "")
	cmds == [0].concat(mounted).concat(cleaned).concat(replaced) and taken.tx.fx.cleanups == [("closing", 1)]
}

## A call is kept when its site is disposed (it reparents, like HTTP) and a
## subscription is cancelled; a subscription its JavaScript closes leaves the
## in-flight table, and a later message for it is stale.
expect {
	msg = { json: "null", blobs: [], files: [] }
	ports = [Core.port_declaration("t/k", Call), Core.port_declaration("t/s", Subscription(Latest))]
	elem = Core.state(
		Bool.True,
		|st|
			Core.element(
				"div",
				[],
				[
					Core.when(st.signal(), || Core.watch(Core.const({}), |_| [PortCall({ port: "t/k", message: msg, timeout_ms: 0 }), PortSubscribe({ port: "t/s", message: msg })].map(Core.raw), Core.ignore({})), || Core.text("")),
					Core.watch(Core.const({}), |_| [Core.again({})], st.on_result(|_, _, _| Bool.False)),
				],
			),
	)
	disposed = Core.fx_stats(mount_in(32, { workers: [], ports: ports_of(ports), media: [] }, {}, elem))
	open = mount_in(32, { workers: [], ports: ports_of(ports), media: [] }, {}, Core.watch(Core.const({}), |_| [PortSubscribe({ port: "t/s", message: msg })].map(Core.raw), Core.ignore({})))
	id = Core.fx_live(open).first() ?? 0
	kept = Core.fx_stats(Core.result(open, id, PortAnswer(msg)))
	closed = Core.result(open, id, PortFailed(Closed))
	late = Core.fx_stats(Core.result(closed, id, PortAnswer(msg)))
	[disposed.issued, disposed.cancelled, disposed.reparented, disposed.live] == [2, 1, 1, 1] and kept.live == 1 and Core.fx_stats(closed).live == 0 and late.stale == 1
}

## A file in a job carries the job's effects, and nothing else about it
## changes: it equals the page's file of the same range, inspects the same
## and puts the same bytes on the wire, so carried effects never reach an
## answer, a comparison or a request.
expect {
	effects : Core.JobEffects
	effects = {
		read!: |_, _, len| List.repeat(7, len),
		size!: |_| 0,
		mint!: || Box.box(0),
		open!: |_, _, _, _, _, _| 0,
		append!: |_, _| 0,
		append_file!: |_, _, _, _| 0,
		finish!: |_, _| 0,
	}
	parts = { name: "a.txt", mime: "text/plain", size: 9, start: 2, len: 5 }
	in_job = Core.placed_file(job_files([Box.box(3)], effects).first() ?? crash "one file", parts) ?? crash "in range"
	on_page = Core.placed_file(Core.held_file(Box.box(3)), parts) ?? crash "in range"
	actual = { equal: in_job == on_page, inspected: Str.inspect(in_job) == Str.inspect(on_page), wire: put_file([], in_job) == put_file([], on_page), parts: Core.file_parts(in_job) == parts }
	actual == { equal: Bool.True, inspected: Bool.True, wire: Bool.True, parts: Bool.True }
}

## A write set names layers exactly across words: index 130 is not index 66
## or index 2, though all three share signature bit 2, and the split at an
## index keeps every layer on the right side of it.
expect {
	a = layers_or(one_layer(3), one_layer(130))
	actual = {
		holds: (layers_has(a, 130), layers_has(a, 66), layers_has(a, 2)),
		below: layers_below(a, 130),
		from: (layers_from(a, 4), layers_from(a, 129), layers_from(a, 131)),
		sig: layers_sig(a),
		count: layers_count(a),
	}
	expected = {
		holds: (Bool.True, Bool.False, Bool.False),
		below: one_layer(3),
		from: (one_layer(130), one_layer(130), no_layers),
		sig: bit(3).bitwise_or(bit(130)),
		count: 2,
	}
	actual == expected
}

## A write set names cells exactly too: cell 70 is not cell 6, though they
## share a signature bit. A group's cells are named one by one, cells stay
## with the layers above an index and never with those below it.
expect {
	a = layers_or(one_layer(3), layers_or(one_cell(70), cells_span(4, 3)))
	actual = {
		holds: (layers_has_cell(a, 70), layers_has_cell(a, 6), layers_has_cell(a, 7), layers_has_cell(a, 134)),
		layer: (layers_has(a, 3), layers_has(a, 6)),
		above: layers_below(a, 3) == layers_or(one_cell(70), cells_span(4, 3)),
		below: layers_from(a, 3),
		sig: layers_sig(a),
		count: layers_count(a),
	}
	expected = {
		holds: (Bool.True, Bool.True, Bool.False, Bool.False),
		layer: (Bool.True, Bool.False),
		above: Bool.True,
		below: one_layer(3),
		sig: bit(3).bitwise_or(cell_bit(4)).bitwise_or(cell_bit(5)).bitwise_or(cell_bit(6)),
		count: 5,
	}
	actual == expected
}

## Closing a writing turn retains its changes and rearms exactly its table
## cells, leaving a table that only shares a signature bit untouched.
expect {
	changed = |table| match table.changes() {
		Keyed(record) => record.len()
		Rewritten => 0
	}
	edited = TableCore.begin_changes(Table.from_list([{ key: 1.U64, row: "a" }])).update(1, |row| "${row}!")
	tables = {
		cells: [
			{ cell: 6, clear: |(a, b)| (TableCore.clear_changes(a), b), stamp: |st| st, live: |st| st, finish: |(a, b)| (TableCore.finish_changes(a), b) },
			{ cell: 70, clear: |(a, b)| (a, TableCore.clear_changes(b)), stamp: |st| st, live: |st| st, finish: |(a, b)| (a, TableCore.finish_changes(b)) },
		],
		written: cell_bit(6),
	}
	(first, second) = end_tables((edited, edited), tables, one_cell(70))
	(untouched, _) = end_tables((edited, edited), tables, one_layer(6))
	actual = { changes: (changed(first), changed(second), changed(untouched)), ready: (TableCore.is_ready(first), TableCore.is_ready(second), TableCore.is_ready(untouched)) }
	actual == { changes: (1, 1, 1), ready: (False, True, False) }
}

## Each pure after is one turn: the decision can read the preceding inverse,
## but its first modifier sees an empty new record. Two updates keep the first
## earlier row, unrelated writes retain it, and the next writing turn replaces it.
expect {
	store = Core.store_of({}, { items: Core.table([{ key: 1.U64, row: 10.U64 }, { key: 2, row: 20 }]), note: Core.cell(0.U64) }.Core.Cells)
	cells = store.cells()
	first = store.after([cells.items.update(|table| table.put(1, 11))])
	preceding = first.read(cells.items).inverse()?
	second = first.after([
		cells.items.update(
			|table| {
				seen = match table.inverse() {
					Ok(undo) => undo.len()
					Err(Rewritten) => 999
				}
				table.put(1, seen)
			},
		),
		cells.items.update(|table| table.update(1, |row| row + 1).update(2, |row| row + 1)),
	])
	unrelated = second.after([cells.note.set(7)]).after([])
	third = unrelated.after([cells.items.update(|table| table.update(2, |row| row + 1))])
	{
		preceding,
		inside_first: second.read(cells.items).get(1)?,
		second: second.read(cells.items).changes(),
		unrelated: unrelated.read(cells.items).changes(),
		third: third.read(cells.items).changes(),
		ready: TableCore.is_ready(third.read(cells.items)),
	} == {
		preceding: [Put(1, 10)],
		inside_first: 1,
		second: Keyed(Dict.empty().insert(1, Was(11)).insert(2, Was(20))),
		unrelated: Keyed(Dict.empty().insert(1, Was(11)).insert(2, Was(20))),
		third: Keyed(Dict.empty().insert(2, Was(21))),
		ready: True,
	}
}

## A reset and its refinements are one pure turn. The rewrite remains whole
## through the refinements; a later keyed writing turn starts its own record.
expect {
	description = { items: Core.table([{ key: 1.U64, row: 10.U64 }]), count: Core.cell(0.U64) }.Core.Cells.with_reset(|cells, reset| { cells, reset })
	store = Core.store_of({}, description)
	group = store.cells()
	cells = group.cells
	changed = store.after([cells.items.update(|table| table.put(1, 11)), cells.count.set(5)])
	refined = changed.after([group.reset, cells.items.update(|table| table.update(1, |row| row + 2)), cells.items.update(|table| table.insert(2, 20)), cells.count.set(7)])
	later = refined.after([cells.items.update(|table| table.put(1, 13))])
	{
		rows: refined.read(cells.items).to_list().sort_with(|a, b| if (a.key < b.key) Before else if (a.key > b.key) After else Same),
		count: refined.read(cells.count),
		refined: refined.read(cells.items).changes(),
		later: later.read(cells.items).changes(),
		ready: TableCore.is_ready(refined.read(cells.items)),
	} == {
		rows: [{ key: 1, row: 12 }, { key: 2, row: 20 }],
		count: 7,
		refined: Rewritten,
		later: Keyed(Dict.empty().insert(1, Was(12))),
		ready: True,
	}
}

## A pure turn writing one table leaves another table's last writing record
## intact. Boot initialization still clears both records without a write.
expect {
	store = Core.store_of({}, { left: Core.table([{ key: 1.U64, row: 10.U64 }]), right: Core.table([{ key: 1.U64, row: 20.U64 }]), note: Core.cell(0.U64) }.Core.Cells)
	cells = store.cells()
	both = store.after([cells.left.update(|table| table.put(1, 11)), cells.right.update(|table| table.put(1, 21))])
	left = both.after([cells.left.update(|table| table.put(1, 12))])
	initialized = left.with_initial(cells.note, 7)
	{
		left: left.read(cells.left).changes(),
		right: left.read(cells.right).changes(),
		left_ready: TableCore.is_ready(left.read(cells.left)),
		right_ready: TableCore.is_ready(left.read(cells.right)),
		initialized: (initialized.read(cells.left).changes(), initialized.read(cells.right).changes()),
	} == {
		left: Keyed(Dict.empty().insert(1, Was(11))),
		right: Keyed(Dict.empty().insert(1, Was(20))),
		left_ready: True,
		right_ready: True,
		initialized: (Keyed(Dict.empty()), Keyed(Dict.empty())),
	}
}

## A chained pure snapshot cannot impersonate a mounted table whose next
## record starts at the same count. Loading it remains a whole rewrite.
expect {
	store = Core.store_of({}, Core.table([{ key: 1.U64, row: 10.U64 }, { key: 2, row: 20 }]))
	cell = store.cells()
	snapshot = store.after([cell.update(|table| table.put(1, 11))]).after([cell.update(|table| table.put(2, 21))]).read(cell)
	live = (cell.modify)(store.initial().st, |table| table.put(1, 111))
	ended = store.tables.fold(live, |st, descriptor| (descriptor.finish)(st))
	before = TableCore.mark((cell.get)(ended))
	loaded = (cell.get)((cell.modify)(ended, |_| snapshot))
	{
		matching_start: TableCore.mark(snapshot).start == before.version,
		disjoint: TableCore.mark(snapshot).id != before.id,
		loaded: loaded.changes(),
		row: loaded.get(1)?,
		identity: TableCore.mark(loaded).id,
	} == { matching_start: True, disjoint: True, loaded: Rewritten, row: 11, identity: before.id }
}

## A row's `item` reads the whole item and listens to the row's layer, as a
## `field` of it does.
expect {
	row : RowRef({}, { name : Str, count : U64 })
	row = RowRef.{ depth: 3 }
	whole = row.item()
	part = row.field(|it| it.count)
	env = Row.{ outer: {}, key: "k", item: { name: "a", count: 7 } }
	((whole.read)(env), (part.read)(env), whole.mask == part.mask, whole.mask == bit(3)) == ({ name: "a", count: 7 }, 7, Bool.True, Bool.True)
}

## An element may handle many events, but each one once: the second handler
## for an event is what mounting refuses, whatever lies between them.
expect {
	h : Handler({})
	h = { run: |e, _, _| (e, no_layers) }
	distinct : List(Attr({}))
	distinct = [Core.on("click", h), Core.attr("class", "x"), Core.on("input", h), Ref(Core.const("r"))]
	twice : List(Attr({}))
	twice = [Core.on("click", h), Core.on("input", h), Core.attr_presence("title", Core.const(Present("t"))), Core.on("click", h)]
	(twice_handled(distinct), twice_handled(twice)) == (Err(Distinct), Ok("click"))
}

## A site strips its own signature bits from the reads it reports only below
## index 64, where no layer above it can share them.
expect {
	actual = (own_bit(36), own_bit(100), above_bits(40), above_bits(104))
	actual == (bit(36), 0, (bit(40) - 1).bitwise_or(all_cells), every_layer)
}

## A name is a map address, while disposal removes only that node's claim.
## Replacing a row in one turn may temporarily hold two claims; the check
## after reconciliation sees just the surviving element. Empty names hold none.
expect {
	first = add_ref(fx_empty, { name: "field", node: 1, path: [0], value_control: False })
	two = add_ref(first, { name: "field", node: 2, path: [1], value_control: False })
	kept = drop_ref(two, 1)
	empty = add_ref(kept, { name: "", node: 3, path: [2], value_control: False })
	actual = {
		claims: (two.refs.get("field") ?? []).len(),
		kept: kept.refs.get("field"),
		empty: empty.refs.len(),
		retired: kept.ref_pos.get(1),
	}
	actual == {
		claims: 2,
		kept: Ok([{ node: 2, path: [1], value_control: False }]),
		empty: 1,
		retired: Ok([]),
	}
}

## A reference template hole has no extra bytes and carries its own node id
## at INST, while a handler on that element still belongs to its row root.
expect {
	row : Elem(Row(Root({}), Str))
	row = Core.element("button", [Core.ref_s(Core.const("cell"))], [])
	plan = compile(row, 1, [0], "an each", root_enclosing)
	actual = { bytes: template_bytes(plan), kind: plan.holes.first().map_ok(|hole| hole.kind), columns: plan.ncols }
	actual == {
		bytes: put_str(put_str([1, 0], ""), "button").concat([0, 0, 0, 1, 5, 0]),
		kind: Ok(5),
		columns: 0,
	}
}

## Renaming and reordering row references preserves their nodes. A name may
## transfer between rows during the pass, and disposing a row frees its
## reference id for the row that replaces it; no retired name stays reachable.
expect {
	view = Core.state(
		[{ key: "a", name: "first" }, { key: "b", name: "second" }],
		|state| Core.element(
			"div",
			[Core.on_click(state.update(|_| [{ key: "b", name: "first" }, { key: "c", name: "third" }]))],
			[
				Core.each(state.signal(), |item| item.key, |row| Core.element("button", [Core.ref_s(row.field(|item| item.name))], [])),
			],
		),
	)
	before = Core.mount(view)
	old = (before.tx.fx.refs.get("second") ?? []).first()?.node
	old_next = before.tx.next
	updated = Core.event(before, 1, 0, "")
	actual = {
		first: (updated.tx.fx.refs.get("first") ?? []).first()?.node,
		recycled: updated.tx.next == old_next,
		retired: updated.tx.fx.refs.contains("second"),
		count: updated.tx.fx.refs.len(),
		settled: Core.settled(updated).is_ok(),
	}
	actual == { first: old, recycled: Bool.True, retired: Bool.False, count: 2, settled: Bool.True }
}

## Two names on one element may swap in one turn. Each reference owns its
## own claim, so renaming the second does not remove the first's new name.
expect {
	one = add_ref(fx_empty, { node: 1, name: "a", path: [0], value_control: False })
	two = add_ref(one, { node: 1, name: "b", path: [1], value_control: False })
	first = add_ref(drop_name(two, { node: 1, name: "a", path: [0] }), { node: 1, name: "b", path: [0], value_control: False })
	second = add_ref(drop_name(first, { node: 1, name: "b", path: [1] }), { node: 1, name: "a", path: [1], value_control: False })
	actual = { a: second.refs.get("a"), b: second.refs.get("b"), after_disposal: drop_ref(second, 1).refs.len() }
	actual == { a: Ok([{ node: 1, path: [1], value_control: False }]), b: Ok([{ node: 1, path: [0], value_control: False }]), after_disposal: 0 }
}

## Typed declarations encode the bare event, payload kind and policy bits.
## Property commands use their own opcodes and count by property index,
## leaving the existing evaluation counters untouched.
expect {
	handler : Handler(Root({}))
	handler = { run: |env, _payload, _site| (env, no_layers) }
	mounted = Core.mount(
		Core.element(
			"input",
			[
				Core.prop(Core.Prop.value, "draft"),
				Core.prop(Core.Prop.checked, Bool.True),
				Core.on_with("change", { prevent: Bool.True, stop: Bool.True }, handler),
			],
			[],
		),
	)
	(_, commands) = Core.take_cmds(mounted, [])
	element = put_str(put_str(put_u32(put_u32(put_u32([8], 1), 0), 0).append(0), ""), "input").append(0)
	value = put_str(put_u32([21], 1).append(1), "draft")
	checked = put_str(put_u32([21], 1).append(2), "true")
	listen = put_u32(put_str(put_u32(put_u32([11], 1), 0), "change").append(1), 3)
	actual = { bytes: commands, value: work_get(mounted.tx.work, 19), checked: work_get(mounted.tx.work, 20), properties: work_get(mounted.tx.work, 41), evaluations: work_get(mounted.tx.work, 21) }
	actual == { bytes: [0].concat(element).concat(value).concat(checked).concat(listen), value: 1, checked: 1, properties: 2, evaluations: 0 }
}

## A row property hole declares its property index once in the template.
## Its INST value is encoded separately, so later HPROP commands need only
## the row and the hole's position.
expect {
	row : Elem(Row(Root({}), Str))
	row = Core.element("input", [Core.attr("type", "checkbox"), Core.prop_s(Core.Prop.checked, Core.const(Bool.True))], [])
	plan = compile(row, 1, [0], "an each", root_enclosing)
	element = put_str(put_str([1, 0], ""), "input").concat([0, 1])
	attribute = put_str(put_str(element.append(3), ""), "type")
	expected = put_str(attribute, "checkbox").concat([0, 1, 6, 0, 2])
	template_bytes(plan) == expected
}

## A table view names references from its typed key signal. A keyed removal
## retires just that drawn row's name and preserves the other row's address.
expect {
	store = Core.store_of({}, Core.table([{ key: 1.U64, row: "a" }, { key: 2, row: "b" }]))
	cell = store.cells()
	view = Core.element(
		"div",
		[Core.on_click(Core.store_handler(|_| [cell.update(|table| table.remove(1))]))],
		[
			Core.table_view(
				cell,
				{
					query: Core.const({}),
					plan: |_| { keep: |_, _| Bool.True, sort: |key, _| key, compare: |a, b| if (a < b) Before else if (a > b) After else Same },
					window: Core.const({ start: 0, count: 18446744073709551615 }),
				},
				|key, _row| Core.element("button", [Core.ref_s(key.map(|value| "key-${value.to_str()}"))], []),
			),
		],
	)
	before = Core.mount_store(32, store.initial(), view)
	kept = (before.tx.fx.refs.get("key-2") ?? []).first()?.node
	after = Core.event(before, 1, 0, "")
	actual = { removed: after.tx.fx.refs.contains("key-1"), kept: (after.tx.fx.refs.get("key-2") ?? []).first()?.node, settled: Core.settled(after).is_ok() }
	actual == { removed: Bool.False, kept, settled: Bool.True }
}

## Empty text and absence have distinct attribute command operands. A
## repeated observation prunes the write, while each transition evaluates
## the signal once and leaves the engine settled.
expect {
	view = Core.state(
		Absent,
		|state| Core.element(
			"div",
			[
				Core.on_click(state.set_value(|_, payload| if (payload == "remove") Absent else Present(payload))),
				Core.attr_presence("title", state.signal()),
			],
			[],
		),
	)
	(mounted, _) = Core.take_cmds(Core.mount(view), [])
	(empty, empty_commands) = Core.take_cmds(Core.event(mounted, 1, 0, ""), [])
	(same, same_commands) = Core.take_cmds(Core.event(empty, 1, 0, ""), [])
	(named, named_commands) = Core.take_cmds(Core.event(same, 1, 0, "name"), [])
	(absent, absent_commands) = Core.take_cmds(Core.event(named, 1, 0, "remove"), [])
	prefix = put_str(put_str(put_u32([0, 9], 1).append(3), ""), "title")
	actual = {
		empty: empty_commands,
		same: same_commands,
		named: named_commands,
		absent: absent_commands,
		evaluations: work_get(absent.tx.work, 21) - work_get(mounted.tx.work, 21),
		settled: Core.settled(absent).is_ok(),
	}
	actual == { empty: put_str(prefix.append(1), ""), same: [], named: put_str(prefix.append(1), "name"), absent: prefix.append(0), evaluations: 4, settled: Bool.True }
}

## Empty boot bytes and a partial Boot record share the public defaults.
expect {
	boot = Core.read_boot([])?
	partial : Boot
	partial = { url: "/a" }
	{ boot, partial } == { boot: Boot.{}, partial: Boot.{ url: "/a", online: True, visible: True, storage_available: True, storage: [] } }
}

## Every accepted nonempty payload is the exact encoding of its boot value.
expect {
	boot : Boot
	boot = { url: "/a?q#b", storage: [("theme", "")], online: False, visible: False }
	encoded = Core.write_boot(boot)
	decoded = Core.read_boot(encoded)?
	{ boot: decoded, bytes: Core.write_boot(decoded) } == { boot, bytes: encoded }
}

## Sections reject unknown, repeated, out-of-order and missing tags at the
## section that could not be read, rather than shifting the following fields.
expect {
	location = put_section([], 1, put_str([], "/"))
	local = put_section([], 2, put_u32([1], 0))
	actual = [Core.read_boot([9]), Core.read_boot(location.concat(location)), Core.read_boot(local), Core.read_boot(location)]
	actual == [
		Err("contract: boot section 1 (location) expected tag 1, got 9 (unknown, repeated or out-of-order section)"),
		Err("contract: boot section 2 (local-storage) expected tag 2, got 1 (unknown, repeated or out-of-order section)"),
		Err("contract: boot section 1 (location) expected tag 1, got 2 (unknown, repeated or out-of-order section)"),
		Err("contract: boot section 2 (local-storage) missing section"),
	]
}

## Lengths, UTF-8 and trailing bytes are checked inside their owning section.
expect {
	actual = [Core.read_boot([1]), Core.read_boot([1, 9, 0, 0, 0]), Core.read_boot(put_section([], 1, put_str([], "/").append(0))), Core.read_boot(put_section([], 1, [1, 0, 0, 0, 255]))]
	actual == [
		Err("contract: boot section 1 (location) truncated length"),
		Err("contract: boot section 1 (location) truncated body"),
		Err("contract: boot section 1 (location) unexpected trailing bytes in body"),
		Err("contract: boot section 1 (location) text is not UTF-8"),
	]
}

## Unavailable storage cannot carry pairs, and a program rejects undeclared
## keys before its start callback or view can observe the boot value.
expect {
	boot : Boot
	boot = { storage: [("secret", "value")] }
	unavailable = Core.write_boot({ ..boot, storage_available: False })
	{ unavailable: Core.read_boot(unavailable), undeclared: check_boot_keys(boot, []), declared: check_boot_keys(boot, ["secret", "secret"]) } == {
		unavailable: Err("contract: boot section 2 (local-storage) pairs while storage is unavailable"),
		undeclared: Err("contract: boot section 2 (local-storage) pair for undeclared key \"secret\""),
		declared: Ok({}),
	}
}

## Declarations contain only their mandatory direction-specific sections:
## local-storage keys, the port table, media and the zone span, each bounded.
expect {
	program = Core.driver(Core.program_boot({ storage_keys: ["theme", "theme"] }, |_| Core.text("")))
	keys = put_str(put_str(put_u32([], 2), "theme"), "theme")
	(program.keys)() == put_section(put_section(put_media_table(put_section(put_section([], 2, keys), 5, put_u32([], 0)), []), 10, [110, 1]), 11, put_u32([], 0))
}

## A storage declaration and every port shape retain their bodies inside
## their own sections; the driver adds the catalogue after storage keys.
expect {
	program = Core.driver(
		Core.program_boot({ storage_keys: ["saved"] }, |_| Core.text("")).with_ports([
			Core.port_declaration("command", Command),
			Core.port_declaration("call", Call),
			Core.port_declaration("updates", Subscription(Every(3))),
		]),
	)
	keys = put_str(put_u32([], 1), "saved")
	command = put_u32(put_str(put_u32([], 3), "command").concat([1, 0]), 0)
	call_bytes = put_u32(put_str(command, "call").concat([2, 0]), 0)
	ports = put_u32(put_str(call_bytes, "updates").concat([3, 1]), 3)
	(program.keys)() == put_section(put_section(put_media_table(put_section(put_section([], 2, keys), 5, ports), []), 10, [110, 1]), 11, put_u32([], 0))
}

## Pointer bytes retain the browser's button, modifier and zone facts without
## sharing a codec with the runtime or the independent DOM oracle.
expect {
	pointer_bytes = [120, 86, 52, 18, 1, 3, 3, 0, 15, 1, 1, 196, 9, 16, 39].concat(put_str([], "lane:a"))
	pointer = read_pointer(pointer_bytes)?
	pointer == {
		id: 0x12345678,
		kind: Pen,
		button: Secondary,
		buttons: 3,
		modifiers: { shift: Bool.True, ctrl: Bool.True, alt: Bool.True, meta: Bool.True },
		primary: Bool.True,
		at: In({ zone: "lane:a", x: 2500, y: 10000 }),
	}
}

## A pointer's no-button and outside cases have one exact encoding. Invalid
## flags, unknown kinds, bad locations, fractions and UTF-8 are rejected.
expect {
	outside = [1, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0]
	point = [1, 0, 0, 0, 0, 1, 1, 0, 0, 1, 1]
	invalid = [
		[],
		outside.drop_last(1),
		outside.append(0),
		outside.set(4, 4)?,
		outside.set(8, 16)?,
		outside.set(9, 2)?,
		outside.set(10, 2)?,
		point.concat([17, 39, 0, 0]).concat(put_str([], "z")),
		point.concat([0, 0, 0, 0]).concat(put_str([], "")),
		point.concat([0, 0, 0, 0, 1, 0, 0, 0, 255]),
	]
	decoded = read_pointer(outside)?
	{ at: decoded.at, button: decoded.button, rejected: invalid.map(|bytes| read_pointer(bytes).is_err()) } == {
		at: Outside,
		button: None,
		rejected: List.repeat(Bool.True, invalid.len()),
	}
}

## Keymaps encode ordered explicit chords before a single merged every entry.
expect {
	ctrl_k = Core.Chord.plain("k").with_ctrl()
	map = Core.Keymap.prevent([ctrl_k]).outside_text().concat(Core.Keymap.keep([ctrl_k])).concat(Core.Keymap.every.outside_text()).concat(Core.Keymap.every)
	encode_keymap(map) == "poC---1:kkaC---1:ka*"
}

## Key decoding preserves browser facts and the declared chord independently.
expect {
	payload = put_str(put_str(put_str([49], "л"), "KeyK").append(1), "k")
	key = read_key(payload)?
	(key.key, key.code, key.ctrl, key.repeat, key.composing, key.heard == Core.Chord.plain("k").with_ctrl()) == ("л", "KeyK", True, True, True, True)
}

## Unknown flags, empty browser keys, truncation and trailing bytes are refused.
expect {
	valid = put_str(put_str(put_str([0], "Escape"), "Escape").append(0), "Escape")
	bad_flags = valid.set(0, 64)?
	empty = put_str(put_str(put_str([0], ""), "Escape").append(0), "Escape")
	[read_key(bad_flags).is_err(), read_key(empty).is_err(), read_key(valid.drop_last(1)).is_err(), read_key(valid.append(0)).is_err()] == [True, True, True, True]
}

## An empty declared chord is valid data that no browser key can produce.
expect encode_keymap(Core.Keymap.prevent([Core.Chord.plain("")]).concat(Core.Keymap.every)) == "pa----0:a*"

## A heard chord cannot be empty: neither a declared empty entry nor every
## can have matched it to a valid browser key.
expect read_key(put_str(put_str(put_str([0], "Escape"), "").append(0), "")).is_err()

## Serialized work retains RELEASE at counter 43 and starts the cleanup table
## after all 49 counters, including a multibyte cleanup name and its run count.
expect {
	mounted = Core.mount(
		Core.state(
			True,
			|visible| Core.element(
				"main",
				[],
				[
					Core.element("button", [Core.on_click(visible.update(|_| False))], []),
					Core.when(visible.signal(), || Core.element("div", [Core.on_document_key({ keymap: Core.const(Core.Keymap.keep([Core.Chord.plain("Escape")])) }, visible.update(|value| value))], [Core.cleanup("doc-λ")]), || Core.text("")),
				],
			),
		),
	)
	disposed = Core.event(mounted, 2, 0, "")
	bytes = work_bytes(disposed, [255, 255])
	count = get_u32(bytes, 0, "work record").to_u64()
	counters = Core.work_counters(disposed)
	var $decoded = []
	var $i = 0.U64
	while $i < count {
		$decoded = $decoded.append(get_u64(bytes, 4 + $i * 8, "work counter"))
		$i = $i + 1
	}
	cleanup_at = 4 + count * 8
	names = get_u32(bytes, cleanup_at, "cleanup count")
	(name, after_name) = get_str(bytes, cleanup_at + 4, "cleanup name")
	runs = get_u64(bytes, after_name, "cleanup runs")
	{ count, counters_match: $decoded == counters, released: $decoded.get(43), names, name, runs, consumed: after_name + 8 == bytes.len() } == {
		count: 49,
		counters_match: True,
		released: Ok(1),
		names: 1,
		name: "doc-λ",
		runs: 1,
		consumed: True,
	}
}

## Alignments use one closed wire byte; malformed bytes are the decoder's responsibility.
align_byte : Core.Align -> U8
align_byte = |alignment| match alignment {
	Start => 0
	Center => 1
	End => 2
	Nearest => 3
}

## Preserve the browser's three distinct scroll behaviors on the wire.
behavior_byte : Core.ScrollBehavior -> U8
behavior_byte = |behavior| match behavior {
	Auto => 0
	Instant => 1
	Smooth => 2
}

## Encode an axis without reading browser layout into the engine.
put_edge : List(U8), Core.Edge -> List(U8)
put_edge = |bytes, edge| match edge {
	Keep => bytes.append(0)
	Start => bytes.append(1)
	End => bytes.append(2)
	Px(offset) => put_u32(bytes.append(3), offset)
}

## A cleanup's scroll command has the same precise request tag and defaults.
expect {
	command : Core.Command
	command = Core.scroll_into_view("problem", {})
	command_request(command) == ScrollIntoView("problem", { block: Nearest, inline: Nearest, behavior: Auto })
}

## An ignored browser close revisits a constant shown hole through the
## ordinary path settlement, without manufacturing a state write.
expect {
	handler = { run: |env, _, _| (env, no_layers) }
	mounted = Core.mount(Core.controlled_dialog({ label: "Settings", open: Core.const(True), on_close: handler, modal: Modal, attrs: [], children: [] }))
	before = Core.evals(mounted)
	(clean, _) = Core.take_cmds(mounted, [])
	closed = Core.event(clean, 1, 0, Str.from_utf8([0]) ?? crash "UTF8")
	(_, commands) = Core.take_cmds(closed, [])
	commands.drop_first(1) == put_str(put_u32([21], 1).append(6), "modal") and Core.evals(closed) == before + 1 and Core.settled(closed).is_ok()
}

## Row-constant shown properties own a cache column and use the same echo
## settlement even though their declared read signature is empty.
expect {
	handler = { run: |env, _, _| (env, no_layers) }
	mounted = Core.mount(Core.element("main", [], [Core.each(Core.const(["a"]), |key| key, |_| Core.controlled_popover({ label: "Help", open: Core.const(True), on_toggle: handler, dismiss: Manual, attrs: [], children: [] }))]))
	before = Core.evals(mounted)
	(clean, _) = Core.take_cmds(mounted, [])
	closed = Core.event(clean, 2, 0, Str.from_utf8([0]) ?? crash "UTF8")
	(_, commands) = Core.take_cmds(closed, [])
	commands.drop_first(1) == put_str(put_u32([22], 2).append(0), "true") and Core.evals(closed) == before + 1 and Core.settled(closed).is_ok()
}

## A derive equality cutoff cannot strand the echoed hole below it. Its
## input and the dirty hole are each observed once, after the handler write.
expect {
	view = Core.state(0.U64, |counter| Core.derive(counter.signal().map(|n| n % 2 == 0), |open| Core.controlled_dialog({ label: "Settings", open, on_close: counter.update(|n| n + 2).lift(), modal: Modal, attrs: [], children: [] })))
	mounted = Core.mount(view)
	before = Core.evals(mounted)
	(clean, _) = Core.take_cmds(mounted, [])
	closed = Core.event(clean, 1, 0, Str.from_utf8([0]) ?? crash "UTF8")
	(_, commands) = Core.take_cmds(closed, [])
	commands.drop_first(1) == put_str(put_u32([21], 1).append(6), "modal") and Core.evals(closed) == before + 2 and Core.settled(closed).is_ok()
}

## When a close handler accepts the browser fact, equality prunes the shown
## write while the dialog's one content scope is disposed in the same turn.
expect {
	view = Core.state(True, |open| Core.controlled_dialog({ label: "Settings", open: open.signal(), on_close: open.set_value(|_, value| value), modal: Modal, attrs: [], children: [Core.text("content")] }))
	mounted = Core.mount(view)
	before = Core.evals(mounted)
	(clean, _) = Core.take_cmds(mounted, [])
	closed = Core.event(clean, 1, 0, Str.from_utf8([0]) ?? crash "UTF8")
	(_, commands) = Core.take_cmds(closed, [])
	commands.drop_first(1) == put_u32([5], 3) and Core.evals(closed) == before + 2 and Core.settled(closed).is_ok()
}

## Moving a row reasserts the shown template descendants of that row at
## their HPROP addresses, immediately after each MOVE in stream order.
expect {
	handler = { run: |env, _, _| (env, no_layers) }
	view = Core.state(["a", "b", "c"], |rows| Core.element("main", [Core.on_click(rows.update(|_| ["c", "b", "a"]))], [Core.each(rows.signal(), |key| key, |_| Core.element("article", [Core.attr_presence("title", Core.const(Absent))], [Core.controlled_popover({ label: "Help", open: Core.const(True), on_toggle: handler, dismiss: Manual, attrs: [], children: [] })]))]))
	mounted = Core.mount(view)
	(clean, _) = Core.take_cmds(mounted, [])
	moved = Core.event(clean, 1, 0, "")
	(_, commands) = Core.take_cmds(moved, [])
	expected = put_u32(put_u32([4], 4), 2).concat(put_str(put_u32([22], 4).append(1), "true")).concat(put_u32(put_u32([4], 2), 0)).concat(put_str(put_u32([22], 2).append(1), "true"))
	commands.drop_first(1) == expected and Core.settled(moved).is_ok()
}

## Two written layers meet below a derive before the echoed property is
## observed. The browser fact is not reconciled against a half-written pair.
expect {
	view = Core.state(0.U64, |outer| Core.derive(outer.signal(), |derived| Core.state(0.U64, |inner| Core.controlled_popover({ label: "Help", open: derived.lift().map2(inner.signal(), |a, b| a == b), on_toggle: outer.update(|n| n + 1).lift().lift().also(inner.update(|n| n + 1)), dismiss: Manual, attrs: [], children: [] }))))
	mounted = Core.mount(view)
	before = Core.evals(mounted)
	(clean, _) = Core.take_cmds(mounted, [])
	closed = Core.event(clean, 1, 0, Str.from_utf8([0]) ?? crash "UTF8")
	(_, commands) = Core.take_cmds(closed, [])
	commands.drop_first(1) == put_str(put_u32([21], 1).append(7), "true") and Core.evals(closed) == before + 2 and Core.settled(closed).is_ok()
}

## Reversing the derive's direction still observes the two writes once.
expect {
	view = Core.state(0.U64, |outer| Core.state(0.U64, |inner| Core.derive(inner.signal(), |derived| Core.controlled_popover({ label: "Help", open: outer.signal().lift().lift().map2(derived, |a, b| a == b), on_toggle: outer.update(|n| n + 1).lift().lift().also(inner.update(|n| n + 1).lift()), dismiss: Manual, attrs: [], children: [] }))))
	mounted = Core.mount(view)
	before = Core.evals(mounted)
	(clean, _) = Core.take_cmds(mounted, [])
	closed = Core.event(clean, 1, 0, Str.from_utf8([0]) ?? crash "UTF8")
	(_, commands) = Core.take_cmds(closed, [])
	commands.drop_first(1) == put_str(put_u32([21], 1).append(7), "true") and Core.evals(closed) == before + 2 and Core.settled(closed).is_ok()
}

## Disposing a nested shown node removes its address from the owning row.
## Recycled ids used by the closed branch must not receive a later re-show.
expect {
	handler = { run: |env, _, _| (env, no_layers) }
	view = Core.state(
		{ phase: 0.U64, rows: ["a", "b"] },
		|st| Core.element(
			"main",
			[
				Core.on_click(
					st.update(
						|s| {
							phase: s.phase + 1,
							rows: if s.phase == 0 {
								s.rows
							} else {
								["b", "a"]
							},
						},
					),
				),
			],
			[
				Core.each(
					st.signal().map(|s| s.rows),
					|key| key,
					|_| Core.element(
						"article",
						[],
						[
							Core.when(st.signal().map(|s| s.phase == 0).lift_row(), || Core.controlled_popover({ label: "Help", open: Core.const(True), on_toggle: handler, dismiss: Manual, attrs: [], children: [] }), || Core.text("closed")),
						],
					),
				),
			],
		),
	)
	mounted = Core.mount(view)
	closed = Core.event(mounted, 1, 0, "")
	(clean, _) = Core.take_cmds(closed, [])
	moved = Core.event(clean, 1, 0, "")
	(_, commands) = Core.take_cmds(moved, [])
	commands.len() == 19 and commands.get(0) == Ok(0) and commands.get(1) == Ok(4) and commands.get(10) == Ok(4) and Core.settled(moved).is_ok()
}

## Reopened template addresses and nested plain owners share one row order.
## Grouping by owner would move the last popover ahead of the nested one.
expect {
	handler = { run: |env, _, _| (env, no_layers) }
	view = Core.state(
		{ phase: 0.U64, rows: ["a", "b"] },
		|st| Core.element(
			"main",
			[
				Core.on_click(
					st.update(
						|s| {
							phase: s.phase + 1,
							rows: if s.phase == 0 {
								s.rows
							} else {
								["b", "a"]
							},
						},
					),
				),
			],
			[
				Core.each(
					st.signal().map(|s| s.rows),
					|key| key,
					|row| Core.element(
						"article",
						[],
						[
							Core.controlled_popover({ label: "First", open: Core.const(True), on_toggle: handler, dismiss: Manual, attrs: [Core.ref_s(row.key().map(|key| "first-${key}"))], children: [] }),
							Core.state({}, |_| Core.controlled_popover({ label: "Nested", open: Core.const(True), on_toggle: handler.lift(), dismiss: Manual, attrs: [Core.ref_s(row.key().lift().map(|key| "nested-${key}"))], children: [] })),
							Core.controlled_popover({ label: "Last", open: st.signal().map(|s| s.phase != 0).lift_row(), on_toggle: handler, dismiss: Manual, attrs: [], children: [] }),
						],
					),
				),
			],
		),
	)
	opened = Core.event(Core.mount(view), 1, 0, "")
	first_nested = ((opened.tx.fx.refs.get("nested-b") ?? []).first() ?? crash "nested b").node
	second_nested = ((opened.tx.fx.refs.get("nested-a") ?? []).first() ?? crash "nested a").node
	first = ((opened.tx.fx.refs.get("first-a") ?? []).first() ?? crash "first a").node
	(c0, _) = Core.take_cmds(opened, [])
	echoed = Core.event(c0, first, 0, Str.from_utf8([1]) ?? crash "UTF8")
	(clean, echo_commands) = Core.take_cmds(echoed, [])
	moved = Core.event(clean, 1, 0, "")
	(_, commands) = Core.take_cmds(moved, [])
	var $ok = echo_commands.is_empty() and commands.len() == 103
	var $at = 1.U64
	for nested in [first_nested, second_nested] {
		row_node = get_u32(commands, $at + 1, "moved row")
		$ok = $ok and commands.get($at) == Ok(4) and commands.get($at + 9) == Ok(22) and commands.get($at + 23) == Ok(21) and commands.get($at + 37) == Ok(22) and get_u32(commands, $at + 10, "first shown") == row_node and get_u32(commands, $at + 24, "nested shown") == nested and get_u32(commands, $at + 38, "last shown") == row_node and commands.get($at + 14) == Ok(0) and commands.get($at + 42) == Ok(4)
		$at = $at + 51
	}
	$ok and Core.settled(moved).is_ok()
}

## Media boot flags retain the declared order, and empty bytes supply each
## declared query's False default before the first render.
expect {
	queries = ["(prefers-color-scheme: dark)", "(prefers-reduced-motion: reduce)"]
	boot : Core.Boot
	boot = { media: [(queries.get(0)?, True), (queries.get(1)?, False)] }
	decoded = Core.read_boot_media(Core.write_boot(boot), queries)?
	defaults = Core.read_boot_media([], queries)?
	{ values: decoded.media, defaults: defaults.media, undeclared: Core.boot_media(decoded, "absent") } == {
		values: boot.media,
		defaults: [(queries.get(0)?, False), (queries.get(1)?, False)],
		undeclared: Err(Undeclared),
	}
}

## A media body has one strict flag per declared query, with no ignored tail.
expect {
	bytes = Core.write_boot({ media: [("a", True)] })
	[Core.read_boot_media(bytes, []).is_err(), Core.read_boot_media(bytes, ["a", "b"]).is_err(), Core.read_boot_media(bytes.take_first(37).append(2).concat(bytes.drop_first(38)), ["a"]).is_err(), Core.read_boot_media(bytes.append(0), ["a"]).is_err()] == [True, True, True, True]
}

## The media catalogue's bounds follow program text, and reject a duplicate
## rather than silently making two declarations one.
expect {
	var $queries = []
	for index in 0.U64..<32 {
		$queries = $queries.append("q${index.to_str()}")
	}
	queries = $queries
	{ full: Core.media_catalogue(queries).is_ok(), excess: Core.media_catalogue(queries.append("last")).is_err(), empty: Core.media_catalogue([""]).is_err(), long: Core.media_catalogue([Str.repeat("x", 257)]).is_err(), duplicate: Core.media_catalogue(["a", "a"]).is_err() } == {
		full: True,
		excess: True,
		empty: True,
		long: True,
		duplicate: True,
	}
}

## The media request and answer use their own closed wire entries.
expect {
	request = put_fx([], 7, MediaChanges("(color)"))
	{ request, answer: Core.decode_res([22, 1]) } == { request: [13, 7, 0, 0, 0, 16, 7, 0, 0, 0, 40, 99, 111, 108, 111, 114, 41], answer: Matches(True) }
}

## Layout records consume exactly two words; offsets keep the whole U32 range.
expect {
	pair = read_layout_pair([0, 0, 0, 0, 255, 255, 255, 255])?
	{ pair, short: read_layout_pair([0]).is_err(), extra: read_layout_pair(List.repeat(0, 9)).is_err() } == { pair: { first: 0, second: 4_294_967_295 }, short: True, extra: True }
}

## Intersection accepts both endpoints and refuses unknown flags, ratios
## beyond a thousand, truncation and trailing bytes.
expect {
	low = read_seen([0, 0, 0])?
	high = read_seen([1, 232, 3])?
	{ low, high, invalid: [[2, 0, 0], [1, 233, 3], [1, 0], [0, 0, 0, 0]].map(|bytes| read_seen(bytes).is_err()) } == {
		low: { intersecting: False, ratio_permille: 0 },
		high: { intersecting: True, ratio_permille: 1000 },
		invalid: [True, True, True, True],
	}
}

## Two observation kinds on one element share one RELEASE owner, while
## their gauge counts each observation and returns to zero on disposal.
expect {
	mounted = Core.mount(
		Core.state(
			True,
			|visible| Core.element(
				"main",
				[],
				[
					Core.element("button", [Core.on_click(visible.update(|_| False))], []),
					Core.when(visible.signal(), || Core.element("div", [Core.on_size(visible.update(|value| value)), Core.on_seen({}, visible.update(|value| value))], []), || Core.text("")),
				],
			),
		),
	)
	before = Core.work_counters(mounted).get(44)?
	closed = Core.event(mounted, 2, 0, "")
	{ before, after: Core.work_counters(closed).get(44)?, releases: Core.work_counters(closed).get(43)? } == { before: 2, after: 0, releases: 1 }
}

## Mount and its follow-ups never mark; later turns merge requests from
## all effect sites, including empty type lists, into one terminal marker.
expect {
	view = Core.state(
		0.U64,
		|st| Core.element(
			"button",
			[Core.on_click(st.update(|n| n + 1))],
			[
				Core.watch(st.signal(), |_| [ViewTransition(["shelf", "books", "shelf"]), ViewTransition([])].map(Core.command), Core.ignore({})),
				Core.watch(st.signal(), |_| [ViewTransition(["books", "detail"])].map(Core.command), Core.ignore({})),
			],
		),
	)
	(mounted, first) = Core.take_cmds(Core.mount(view), [])
	(changed, commands) = Core.take_cmds(Core.event(mounted, 1, 0, ""), [])
	(idle, empty) = Core.take_cmds(changed, [])
	want = put_str(put_str(put_str(put_u32([1, 24], 3), "shelf"), "books"), "detail")
	first.get(0) == Ok(0) and commands == want and empty.is_empty() and Core.work_counters(mounted).get(45) == Ok(0) and Core.work_counters(idle).get(45) == Ok(1) and Core.fx_stats(idle).issued == 0 and Core.settled(idle).is_ok()
}

## Signed wall time, all seed bits and bounded author data survive the wire.
expect {
	boot : Core.Boot
	boot = { now_ms: -9223372036854775808, seed: 340282366920938463463374607431768211455, languages: ["", "en-AU"], zone: { name: "test", from_ms: -100, until_ms: 100, offsets: [{ from_ms: -100, minutes: -60 }, { from_ms: 0, minutes: 90 }] } }
	Core.read_boot(Core.write_boot(boot)) == Ok(boot) and Core.decode_res(put_u64([5], (-123.I64).to_u64_wrap())) == Fired(-123)
}

## Zone lookup includes both endpoints and gives each transition its new offset.
expect {
	zone = { name: "test", from_ms: -100.I64, until_ms: 100.I64, offsets: [{ from_ms: -100.I64, minutes: -60.I32 }, { from_ms: 0.I64, minutes: 90.I32 }] }
	[-101.I64, -100, -1, 0, 100, 101].map(|at| Core.zone_offset(zone, at)) == [Err(OutsideZone), Ok(-60), Ok(-60), Ok(90), Ok(90), Err(OutsideZone)] and Core.zone_offset(Core.utc, -9223372036854775808) == Ok(0) and Core.zone_offset(Core.utc, 9223372036854775807) == Ok(0)
}

## Boot rejects malformed language and zone facts instead of repairing them.
expect {
	base : Core.Boot
	base = {}
	bad = [
		{ ..base, languages: [] },
		{ ..base, languages: List.repeat("x", 17) },
		{ ..base, languages: [Str.repeat("λ", 33)] },
		{ ..base, zone: { ..Core.utc, name: Str.repeat("x", 65) } },
		{ ..base, zone: { ..Core.utc, from_ms: 1, until_ms: 0 } },
		{ ..base, zone: { ..Core.utc, offsets: [] } },
		{ ..base, zone: { ..Core.utc, offsets: [{ from_ms: 0, minutes: 0 }] } },
		{ ..base, zone: { name: "x", from_ms: 0, until_ms: 1, offsets: [{ from_ms: 0, minutes: 0 }, { from_ms: 0, minutes: 1 }] } },
		{ ..base, zone: { name: "x", from_ms: 0, until_ms: 1, offsets: [{ from_ms: 0, minutes: 0 }, { from_ms: 2, minutes: 1 }] } },
	]
	bad.all(|boot| Core.read_boot(Core.write_boot(boot)).is_err()) and Core.read_boot(Core.write_boot({ zone: { name: "", from_ms: 0, until_ms: 0, offsets: [{ from_ms: 0, minutes: -2147483648 }] } })).is_ok()
}

## One guard owns just its last Boolean, so a flip or disposal adjusts the
## instance count in constant work. Publication waits for the turn to finish.
guard_inst : Signal(ctx, Bool), Bool -> Inst(ctx)
guard_inst = |value, last| Inst(
	|env, msg, tx| match msg {
		Changed(mask) => {
			if eff_mask(value).bitwise_and(mask) == 0 {
				(guard_inst(value, last), Done, tx)
			} else {
				on = (value.read)(env)
				next = if (on == last) tx else with_fx(tx, |fx| { ..fx, guard: { ..fx.guard, live: if (on) fx.guard.live + 1 else fx.guard.live - 1 } })
				(guard_inst(value, on), Done, count_evals(next, 1))
			}
		}
		Fire(_, _, _, _) => (guard_inst(value, last), Pending(env, no_layers), tx)
		Dispose(_) => (noop({}), Orphaned([]), if (last) with_fx(tx, |fx| { ..fx, guard: { ..fx.guard, live: fx.guard.live - 1 } }) else tx)
	},
)

paste_kind : Core.Kind(Core.Paste)
paste_kind = {
	code: 9,
	decode: |payload, site| match payload {
		Ev([0, .. as bytes]) => Text(Str.from_utf8(bytes) ?? crash "contract: paste text is not UTF-8 at site ${show_path(site)}")
		Ev([1]) => TooLarge
		_ => crash "contract: malformed paste-text payload at site ${show_path(site)}"
	},
}

## A guard takes no node id or awaited slot, and only a changed aggregate emits.
expect {
	mounted = Core.mount(Core.guard_leave(Core.const(True)))
	(state, commands) = Core.take_cmds(mounted, [])
	(idle, empty) = Core.take_cmds(state, [])
	{ commands, empty, pending: Core.fx_live(idle), count: Core.work_counters(idle).get(46), settled: Core.settled(idle).is_ok() } == { commands: [0, 25, 1], empty: [], pending: [], count: Ok(1), settled: True }
}

## Replacing one true guard with another within a turn never toggles the warning.
expect {
	initial = Core.mount(Core.state(True, |selected| Core.element("main", [], [Core.element("button", [Core.on_click(selected.update(|on| !on))], []), Core.when(selected.signal(), || Core.guard_leave(Core.const(True)), || Core.guard_leave(Core.const(True)))])))
	(ready, _) = Core.take_cmds(initial, [])
	changed = Core.event(ready, 2, 0, "")
	(settled, commands) = Core.take_cmds(changed, [])
	{ guards: settled.tx.fx.guard.live, commands: Core.work_counters(settled).get(46), settled: Core.settled(settled).is_ok(), nonempty: !commands.is_empty() } == { guards: 1, commands: Ok(1), settled: True, nonempty: False }
}

## False signals and scope disposal remove exactly their own guard contribution.
expect {
	initial = Core.mount(Core.state(True, |on| Core.element("main", [], [Core.element("button", [Core.on_click(on.update(|value| !value))], []), Core.guard_leave(on.signal()), Core.when(on.signal(), || Core.guard_leave(Core.const(True)), || Core.text(""))])))
	(ready, _) = Core.take_cmds(initial, [])
	changed = Core.event(ready, 2, 0, "")
	{ guards: changed.tx.fx.guard.live, emitted: changed.tx.fx.guard.emitted, commands: Core.work_counters(changed).get(46), pending: Core.fx_live(changed), settled: Core.settled(changed).is_ok() } == { guards: 0, emitted: False, commands: Ok(2), pending: [], settled: True }
}

## Session values retain their own availability, independent of local storage.
expect {
	boot = Core.read_boot(Core.write_boot({ storage: [("saved", "old")], session: [("draft", "new λ")] }))?
	{ session: Core.boot_session(boot, "draft"), local: Core.boot_storage(boot, "saved"), missing: Core.boot_session(boot, "absent"), unavailable: Core.read_boot(Core.write_boot({ session_available: False, session: [("draft", "x")] })).is_err() } == { session: Ok("new λ"), local: Ok("old"), missing: Err(Missing), unavailable: True }
}

## A selected-row reading contributes its selection dependency even though
## its ordinary mask is zero, without being sampled while the site is built.
expect {
	selection : Signal(Root({}), Str)
	selection = { mask: 8, read: |_| "chosen", sel: NoSel }
	row : RowRef(Root({}), Str)
	row = { depth: 1 }
	reading = row.select(Core.keyed(selection, 11.U64, 22.U64))
	box : Signal(Row(Root({}), Str), Outbox(U64))
	box = { mask: 2, read: |_| Core.outbox({}), sel: NoSel }
	elem_reads(Core.on_post_by(box, reading, |_, _| [], Core.ignore({})), 1) == 10
}

## A normal reading is not evaluated at mount or for a reading-only write;
## posting samples its settled value and retains the small marker alone.
expect {
	initial = Core.mount(
		Core.state(
			{ out: Core.outbox({}), value: 0.U64 },
			|state| Core.element(
				"main",
				[],
				[
					Core.element("button", [Core.on_click(state.update(|value| { ..value, value: 1 }))], []),
					Core.element("button", [Core.on_click(state.update(|value| { ..value, value: 2, out: value.out.post(7.U64) }))], []),
					Core.on_post_by(state.signal().map(|value| value.out), state.signal().map(|value| if (value.value == 2) value.value else crash "reading sampled without a post"), |value, item| [Core.command(Title("${value.to_str()}:${item.to_str()}"))], Core.ignore({})),
				],
			),
		),
	)
	(ready, _) = Core.take_cmds(initial, [])
	(changed, empty) = Core.take_cmds(Core.event(ready, 2, 0, ""), [])
	(posted, commands) = Core.take_cmds(Core.event(changed, 3, 1, ""), [])
	{ empty, commands, settled: Core.settled(posted).is_ok() } == { empty: [], commands: put_str([0, 17], "2:7"), settled: True }
}

## Progress keeps an admitted id live after disposal, while both progress and
## final writes to a retired local state are skipped and counted separately.
expect {
	mounted = Core.mount(
		Core.state(
			True,
			|shown| Core.element(
				"main",
				[],
				[
					Core.element("button", [Core.on_click(shown.update(|_| False))], []),
					Core.when(
						shown.signal(),
						|| Core.state(
							0.U64,
							|local| Core.watch(
								Core.const({}),
								|_| [Core.http({ url: "/kept" })],
								local.on_result(|value, _, _| value + 1).with_progress({}, local.on_progress(|value, _, _| value + 1)),
							),
						),
						|| Core.text(""),
					),
				],
			),
		),
	)
	first = Core.progress(mounted, 1, { direction: Receiving, done: 1, total: Known(2) })
	hidden = Core.event(first, 2, 0, "")
	reported = Core.progress(hidden, 1, { direction: Receiving, done: 2, total: Known(2) })
	answered = Core.result(reported, 1, Timeout)
	stats = Core.fx_stats(answered)
	{ live_after_report: Core.fx_live(reported), live_after_answer: Core.fx_live(answered), progress: Core.work_counters(answered).get(47), delivered: stats.delivered, skipped: stats.skipped, reparented: stats.reparented, settled: Core.settled(answered).is_ok() } == {
		live_after_report: [1],
		live_after_answer: [],
		progress: Ok(2),
		delivered: 1,
		skipped: 2,
		reparented: 1,
		settled: True,
	}
}

## The HTTP builder preserves explicit policy choices and defaults only what
## was omitted; progress is requested by a reaction rather than request data.
expect {
	request = Core.http({ url: "/status", cache: NoStore, credentials: Include, timeout: Ms(300) }).sent()
	request == Http({ method: "GET", url: "/status", headers: [], body: "", timeout_ms: 300, cache: NoStore, credentials: Include })
}

## A posted transfer reports against its original item, without passing a
## progress payload to the final-result reaction or retaining the outbox wrapper.
expect {
	mounted = Core.mount(
		Core.state(
			{ box: Core.outbox({}), count: 0.U64 },
			|state| Core.element(
				"main",
				[],
				[
					Core.element("button", [Core.on_click(state.update(|value| { ..value, box: value.box.post(9.U64) }))], []),
					Core.text_s(state.signal().map(|value| value.count.to_str())),
					Core.on_post(state.signal().map(|value| value.box), |_| [Core.http({ url: "/post" })], Core.ignore({}).with_progress({}, state.on_progress(|value, item, transfer| { ..value, count: item + transfer.done }))),
				],
			),
		),
	)
	(clean, _) = Core.take_cmds(mounted, [])
	posted = Core.event(clean, 2, 0, "")
	(before, _) = Core.take_cmds(posted, [])
	reported = Core.progress(before, 1, { direction: Sending, done: 41, total: Unknown })
	(after, commands) = Core.take_cmds(reported, [])
	{ commands, pending: Core.fx_live(after), reports: Core.work_counters(after).get(47), final: Core.fx_stats(after).delivered } == {
		commands: [0, 12, 3, 0, 0, 0, 2, 0, 0, 0, '5', '0'],
		pending: [1],
		reports: Ok(1),
		final: 0,
	}
}

## Composed progress handlers write the same local state in operand order and
## settle their store writes together, as exactly one counted progress turn.
expect {
	store = Core.store_of({}, Core.cell(0.U64))
	cell = store.cells()
	view = Core.state(
		1.U64,
		|local| Core.element(
			"main",
			[],
			[
				Core.text_s(Core.Signal.map2(local.signal(), cell.signal(), |value, shared| "${value.to_str()}/${shared.to_str()}")),
				Core.watch(
					Core.const({}),
					|_| [Core.http({ url: "/composed" })],
					Core.ignore({}).with_progress({ every_ms: 300 }, local.on_progress(|value, _, _| value + 1))
						.also(Core.ignore({}).with_progress({ every_ms: 100 }, local.on_progress(|value, _, _| value * 2)))
						.also(Core.ignore({}).with_progress({ every_ms: 200 }, Core.store_progress(|_, transfer| [cell.set(transfer.done)]))),
				),
			],
		),
	)
	(before, mount) = Core.take_cmds(Core.mount_store(32, store.initial(), view), [])
	(after, commands) = Core.take_cmds(Core.progress(before, 1, { direction: Receiving, done: 9, total: Unknown }), [])
	{ interval: mount.drop_first(mount.len() - 4), commands, writes: Core.work_counters(after).get(27), progress: Core.work_counters(after).get(47), delivered: Core.fx_stats(after).delivered, settled: Core.settled(after).is_ok() } == {
		interval: [100, 0, 0, 0],
		commands: [0, 12, 2, 0, 0, 0, 3, 0, 0, 0, '4', '/', '9'],
		writes: Ok(2),
		progress: Ok(1),
		delivered: 0,
		settled: True,
	}
}

## Typed timeouts distinguish a positive duration from the wire's zero sentinel.
expect Core.timeout_wire(Unlimited) == 0 and Core.timeout_wire(Ms(1)) == 1 and Core.timeout_wire(Ms(4294967295)) == 4294967295

## Zero remains a legal one-shot clock sample; both timers keep the largest
## browser delay exactly, without a signed conversion or the timeout cap.
expect {
	{ zero: put_fx([], 1, Timer(0)), one: put_fx([], 1, Timer(1)), timer_max: put_fx([], 1, Timer(2147483647)), interval_one: put_fx([], 1, Interval(1)), interval_max: put_fx([], 1, Interval(2147483647)) } == {
		zero: [13, 1, 0, 0, 0, 3, 0, 0, 0, 0],
		one: [13, 1, 0, 0, 0, 3, 1, 0, 0, 0],
		timer_max: [13, 1, 0, 0, 0, 3, 255, 255, 255, 127],
		interval_one: [13, 1, 0, 0, 0, 4, 1, 0, 0, 0],
		interval_max: [13, 1, 0, 0, 0, 4, 255, 255, 255, 127],
	}
}

## Raw requests retain zero as no timeout, and positive typed durations are
## still capped by the existing ten-minute wire policy when they are issued.
expect {
	raw = Http({ method: "GET", url: "/timeout", headers: [], body: "", timeout_ms: 0, cache: Default, credentials: SameOrigin })
	wide = Core.http({ url: "/timeout", timeout: Ms(4294967295) }).sent()
	unlimited = put_fx([], 1, raw)
	capped = put_fx([], 1, wide)
	unlimited.drop_first(unlimited.len() - 10) == [0, 0, 0, 0, 1, 1, 0, 0, 0, 0] and capped.drop_first(capped.len() - 10) == [192, 39, 9, 0, 1, 1, 0, 0, 0, 0] and Core.http({ url: "/timeout" }).sent() == raw
}

read_http_response : Result -> Try(Core.Response, Core.HttpFailure)
read_http_response = |result| match result {
	Http(response) => Ok(response)
	Network(message) => Err(Network(message))
	Timeout => Err(Timeout)
	Refused => Err(Refused)
	_ => crash "contract: HTTP ask received a non-HTTP result"
}

read_fetch_response : Result -> Try(Core.Fetched, Core.FetchFailure)
read_fetch_response = |result| match result {
	Fetched(response) => Ok(response)
	Network(message) => Err(Network(message))
	Timeout => Err(Timeout)
	FileFailed(_) => Err(TooLarge)
	Refused => Err(Refused)
	_ => crash "contract: fetch ask received a non-fetch result"
}

read_fired : Result -> Try(I64, [Refused])
read_fired = |result| match result {
	Fired(at) => Ok(at)
	Refused => Err(Refused)
	_ => crash "contract: timer ask received a non-timer result"
}

read_storage : Result -> Try(Str, [Missing, Refused])
read_storage = |result| match result {
	Value(value) => Ok(value)
	Missing => Err(Missing)
	Refused => Err(Refused)
	_ => crash "contract: storage ask received a non-storage result"
}

## Mapping an ask preserves its request and transforms only its typed result.
expect {
	Core.Ask.({ request, read }) = Core.http_body({ url: "/mapped" })
		.map_ok(|body| body.count_utf8_bytes())
		.map_err(Str.inspect)
		.map(|answer| answer.map_ok(|length| length + 1))
	actual = {
		request,
		answers: [read(Http({ status: 201, headers: [], body: "abc" })), read(Http({ status: 503, headers: [], body: "ignored" })), read(Refused)],
	}
	expected = {
		request: Http({ method: "GET", url: "/mapped", headers: [], body: "", timeout_ms: 0, cache: Default, credentials: SameOrigin }),
		answers: [Ok(4), Err("Status(503)"), Err("Refused")],
	}
	actual == expected
}

## Explicit static addresses take priority over descendant text; dynamic
## labels are not sampled to make an error more descriptive.
expect {
	node : Elem({})
	node = Core.element("button", [Core.attr("id", "secondary"), Core.attr("data-testid", "primary"), Core.attr("aria-label", "spoken")], [Core.text("Save")])
	dynamic : Elem({})
	dynamic = Core.element("button", [Core.attr_s("aria-label", Core.const("dynamic"))], [Core.text("Static")])
	{ explicit: element_hint(node), dynamic: element_hint(dynamic) } == { explicit: "primary", dynamic: "Static" }
}

## Diagnostic bounds preserve whole UTF-8 scalars and never exceed 64 bytes.
expect {
	{ ascii: bounded_element_hint(Str.repeat("x", 100)), paired: bounded_element_hint(Str.repeat("é", 40)), cut: bounded_element_hint("x${Str.repeat("é", 40)}") } == {
		ascii: Str.repeat("x", 64),
		paired: Str.repeat("é", 32),
		cut: "x${Str.repeat("é", 31)}",
	}
}

## Static positions exclude nested sites, whose factories are never run by
## diagnostic lookup. Child indices remain useful without exposing engine ids.
expect {
	button : Elem({})
	button = Core.element("button", [], [Core.text("Save")])
	root : Elem({})
	root = Core.element("section", [], [Core.when(Core.const(Bool.True), || crash "diagnostics must not enter a site", || Core.text("")), Core.element("div", [], [Core.text("First"), button])])
	{ path: static_element_path(root, 3), text: first_static_text(root), place: static_element_place(root, 3, button) } == {
		path: Found([1, 1]),
		text: "First",
		place: " (element /1/1, \"Save\")",
	}
}

## Payload conversion reads the arriving environment before the target handler
## writes it, and preserves that handler's exact write set.
expect {
	handler : Core.HandlerOf({ count : U64 }, U64)
	handler = { run: |env, amount, _| ({ count: env.count + amount }, { lo: 2, hi: [], cells: 4, more: [] }) }
	reading : Core.Signal({ count : U64 }, U64)
	reading = { mask: 1, read: |env| env.count, sel: NoSel }
	mapped = handler.from_payload_by(reading, |before, text| before + (U64.from_str(text) ?? 0))
	(after, wrote) = (mapped.run)({ count: 10 }, "2", [])
	after.count == 22 and wrote.lo == 2 and wrote.cells == 4
}

## An interpolation without varying parts is the same no-read recipe as const.
expect {
	joined = Core.join_text([], "fixed")
	{ mask: joined.mask, selection: sel_mask(joined.sel), text: (joined.read)(0.U64) } == { mask: 0.U128, selection: 0.U128, text: "fixed" }
}

## One keyed selection survives beside a row key, which reads no layer but
## remains different for each row. Each part contributes its own text once.
expect {
	chosen : Core.Signal(Str, Str)
	chosen = { mask: 0, read: |key| key, sel: Sel(8, |key| key) }
	key : Core.Signal(Str, Str)
	key = { mask: 0, read: |value| "key-${value}", sel: NoSel }
	joined = Core.join_text([{ prefix: "pick ", value: chosen }, { prefix: "/", value: key }], ".")
	selected = match joined.sel {
		Sel(_, read) => read("A")
		NoSel => "no selection"
	}
	{ mask: joined.mask, selection: sel_mask(joined.sel), selected, text: (joined.read)("A") } == { mask: 0.U128, selection: 8.U128, selected: "A", text: "pick A/key-A." }
}

## A second selected part or another part's ordinary dependency folds the
## selection dependencies into the mask, matching Core.Signal.map2.
expect {
	selected : Core.Signal(U64, Str)
	selected = { mask: 0, read: |value| value.to_str(), sel: Sel(8, |value| value.to_str()) }
	other : Core.Signal(U64, Str)
	other = { mask: 2, read: |value| value.to_str(), sel: NoSel }
	two = Core.join_text([{ prefix: "", value: selected }, { prefix: "", value: selected }], "")
	mixed = Core.join_text([{ prefix: "", value: selected }, { prefix: "", value: other }], "")
	{ two_mask: two.mask, two_selection: sel_mask(two.sel), mixed_mask: mixed.mask, mixed_selection: sel_mask(mixed.sel), text: (mixed.read)(3) } == { two_mask: 8.U128, two_selection: 0.U128, mixed_mask: 10.U128, mixed_selection: 0.U128, text: "33" }
}

## Resolve raw construction once, using finite inherited facts. Explicit
## expanded names already carry their identity and are never reclassified.
resolve_element : Web.Tag, Enclosing -> Web.Tag
resolve_element = |name, enclosing| match name.namespace() {
	Explicit(_) => name
	Inherit => {
		namespace = if (name.local() == "svg") Svg else enclosing.raw_namespace
		if namespace == Html {
			local = ascii_name_lower(name.local())
			(Web.Tag.from_str(local) ?? crash "internal: folded HTML name").in_namespace({ namespace: Html }) ?? crash "internal: unprefixed HTML name"
		} else {
			parts = name.local().split_on(":")
			(prefix, local) = if parts.len() == 1 {
				(Unprefixed, name.local())
			} else {
				(Prefix(parts.first() ?? crash "internal: qualified name has a prefix"), Str.join_with(parts.drop_first(1), ":"))
			}
			local_name = Web.Tag.from_str(local) ?? crash "contract: raw foreign element has an invalid local name"
			local_name.in_namespace({ namespace, prefix }) ?? crash "contract: raw foreign element has an invalid namespace qualification"
		}
	}
}

## Descendants inherit the raw API's SVG/foreignObject rule. Actual parent
## identity stays available separately for literal placement checks.
child_enclosing : Enclosing, { name : Web.Tag, site : List(U32), placement : Str, describe : () -> Str } -> Enclosing
child_enclosing = |parent, { name, site, placement, describe }| {
	construction = match ParsedHtml.Construction.enter(
		parent.construction,
		construction_name({
			namespace: match name.namespace() {
				Explicit(value) => value
				Inherit => crash "internal: construction requires a resolved name"
			},
			prefix: name.prefix(),
			local: name.local(),
		}),
	) {
		Ok(context) => context
		Err(Repair(repair)) => crash "contract: ${construction_advice(repair)}${placement} at site ${show_path(site)}${describe()}"
	}
	namespace = match name.namespace() {
		Explicit(value) => value
		Inherit => crash "internal: child context requires a resolved element"
	}
	{ namespace, prefix: name.prefix(), local: name.local(), raw_namespace: if (namespace == Svg and name.local() != "foreignObject") Svg else Html, construction }
}

## Raw attributes follow HTML's ASCII name folding. Explicit qualification
## preserves parser-provided case, even when its namespace is None.
resolve_attribute : Web.AttrName, Web.Tag -> Web.AttrName
resolve_attribute = |name, element| {
	if name.is_qualified() {
		return name
	}
	local = if (element.namespace() == Explicit(Html)) ascii_name_lower(name.local()) else name.local()
	(Web.AttrName.from_str(local) ?? crash "internal: folded attribute name").in_namespace({ namespace: None }) ?? crash "internal: ordinary raw attribute name"
}

## Only ordinary unnamespaced attributes can claim a control's HTML names.
ordinary_attribute_is : Web.AttrName, Str -> Bool
ordinary_attribute_is = |name, expected| name.namespace() == None and name.prefix() == Unprefixed and name.local() == expected

## ASCII folding is construction work only; attribute values remain verbatim.
ascii_name_lower : Str -> Str
ascii_name_lower = |text| Str.from_utf8(text.to_utf8().map(|byte| if (byte >= 'A' and byte <= 'Z') byte + 32 else byte)) ?? crash "internal: ASCII folding preserves UTF-8"

## A compact namespace tag followed by an exact URI for extensions. URI
## identity, not a catalogue entry or prefix, identifies the namespace.
put_namespace : List(U8), Web.Namespace -> List(U8)
put_namespace = |bytes, namespace| match namespace {
	Html => bytes.append(0)
	Svg => bytes.append(1)
	MathML => bytes.append(2)
	None => bytes.append(3)
	Uri(value) => put_str(bytes.append(4), value)
}

## Element and attribute names share framing, not construction semantics.
## Empty prefix means no prefix; a local colon remains local data.
put_expanded_name : List(U8), Web.Namespace, Web.Prefix, Str -> List(U8)
put_expanded_name = |bytes, namespace, prefix, local| {
	written_prefix = match prefix {
		Unprefixed => ""
		Prefix(value) => value
	}
	put_str(put_str(put_namespace(bytes, namespace), written_prefix), local)
}

## The emitted element name is resolved before this boundary; no receiver
## chooses a namespace, prefix or case from an ancestor or tag spelling.
put_element_name : List(U8), Web.Tag -> List(U8)
put_element_name = |bytes, name| match name.namespace() {
	Explicit(namespace) => put_expanded_name(bytes, namespace, name.prefix(), name.local())
	Inherit => crash "internal: unresolved element reached the command stream"
}

## Attribute identity and exact case are likewise decided before encoding.
put_attribute_name : List(U8), Web.AttrName -> List(U8)
put_attribute_name = |bytes, name| put_expanded_name(bytes, name.namespace(), name.prefix(), name.local())

## Literal fragment requirements inspect one retained context, never a parent
## chain. A foreignObject's HTML child context does not admit SVG fragments.
check_parent : List([Svg]), Enclosing, List(U32) -> {}
check_parent = |allowed, enclosing, site| {
	if allowed.contains(Svg) and enclosing.raw_namespace == Svg {
		return {}
	}
	crash "contract: SVG markup fragment requires an SVG enclosing context at site ${show_path(site)}"
}

## A template retains each nested site's finite context once. The row mount
## supplies routing and lifetime arguments while this wrapper supplies facts.
mount_in_context : Mount(ctx), Enclosing -> Mount(ctx)
mount_in_context = |Mount(mount), enclosing| Mount(|env, args, tx| mount(env, { ..args, enclosing }, tx))

## Root identity decoding follows actual DOM facts, not factory-specific
## validate-and-extract restrictions. In particular xmlns and local colons can
## already exist without prefixes, including at an externally supplied root.
read_mount_root : List(U8) -> Try(Core.MountRoot, Str)
read_mount_root = |bytes| {
	code = bytes.first() ? |_| "missing namespace kind"
	(namespace, prefix_at) = match code {
		0 => (Html, 1)
		1 => (Svg, 1)
		2 => (MathML, 1)
		3 => (None, 1)
		4 => {
			(uri, next) = boot_str(bytes, 1)?
			if uri.is_empty() {
				return Err("explicit namespace URI is empty")
			}
			(Uri(uri), next)
		}
		_ => return Err("unknown namespace kind")
	}
	(prefix_text, local_at) = boot_str(bytes, prefix_at)?
	(local, end) = boot_str(bytes, local_at)?
	if end != bytes.len() {
		return Err("trailing root bytes")
	}
	_ = Web.Tag.from_str(local).map_err(|NotATag(message)| message)?
	prefix = if prefix_text.is_empty() {
		Unprefixed
	} else {
		if prefix_text.to_utf8().any(|unit| unit == ':' or unit == 0 or unit == '/' or unit == '>' or is_mount_space(unit)) {
			return Err("invalid namespace prefix")
		}
		if namespace == None {
			return Err("namespace prefix without namespace")
		}
		if prefix_text == "xml" and namespace_uri(namespace) != "http://www.w3.org/XML/1998/namespace" {
			return Err("xml prefix requires XML namespace")
		}
		if prefix_text == "xmlns" and namespace_uri(namespace) != "http://www.w3.org/2000/xmlns/" {
			return Err("xmlns prefix requires XMLNS namespace")
		}
		Prefix(prefix_text)
	}
	Ok({ namespace, prefix, local })
}

## ASCII whitespace is forbidden in a DOM prefix; other punctuation may occur.
is_mount_space : U8 -> Bool
is_mount_space = |unit| [9.U8, 10, 12, 13, 32].contains(unit)

## Namespace URI equality makes named and explicit URI representations aliases.
namespace_uri : Web.Namespace -> Str
namespace_uri = |namespace| match namespace {
	Html => "http://www.w3.org/1999/xhtml"
	Svg => "http://www.w3.org/2000/svg"
	MathML => "http://www.w3.org/1998/Math/MathML"
	None => ""
	Uri(value) => value
}

## Actual root identity is preserved; only raw child construction uses the
## legacy SVG/foreignObject rule. MathML does not become a raw tag inference.
enclosing_root : Core.MountRoot -> Enclosing
enclosing_root = |root| {
	namespace = match namespace_uri(root.namespace) {
		"http://www.w3.org/1999/xhtml" => Html
		"http://www.w3.org/2000/svg" => Svg
		"http://www.w3.org/1998/Math/MathML" => MathML
		"" => None
		other => Uri(other)
	}
	{ namespace, prefix: root.prefix, local: root.local, raw_namespace: if (namespace == Svg and root.local != "foreignObject") Svg else Html, construction: ParsedHtml.Construction.root({ parent: construction_name(root) }) }
}

## Root facts round-trip beside Boot without becoming an app-visible field.
expect {
	root = { namespace: Svg, prefix: Unprefixed, local: "svg" }
	decoded = Core.read_mount(Core.write_mount({ url: "/route" }, root), [])?
	decoded.root == root and decoded.boot.url == "/route" and Core.read_boot(Core.write_mount({ url: "/route" }, root)) == Ok(decoded.boot)
}

## Existing roots can contain identities which NS creation factories cannot
## reconstruct. Root decoding checks facts rather than imposing factory limits.
expect {
	roots = [{ namespace: Uri("urn:entry"), prefix: Unprefixed, local: "xmlns" }, { namespace: Svg, prefix: Unprefixed, local: "h:div" }]
	roots.all(|root| Core.read_mount(Core.write_mount({}, root), []).map_ok(|value| value.root) == Ok(root))
}

## The raw namespace rule depends on measured root context. The fixed byte
## position is the ELEM namespace operand, independently asserted here.
expect {
	program = Core.driver(Core.program(|| Core.element("path", [], [])))
	roots = [{ namespace: Svg, prefix: Unprefixed, local: "svg" }, { namespace: Svg, prefix: Unprefixed, local: "foreignObject" }, { namespace: MathML, prefix: Unprefixed, local: "math" }]
	actual = roots.map(
		|root| {
			(state, commands, _) = (program.init)(Core.write_mount({}, root))
			if Core.settled(state).is_err() {
				crash "root-context program did not settle"
			}
			commands.get(14)
		},
	)
	actual == [Ok(1), Ok(0), Ok(0)]
}

## Reserved prefixes cannot misstate their namespace, while the local name
## xmlns without a prefix remains a valid existing custom-namespace root.
expect {
	invalid = { namespace: Uri("urn:entry"), prefix: Prefix("xmlns"), local: "entry" }
	valid = { namespace: Uri("urn:entry"), prefix: Unprefixed, local: "xmlns" }
	Core.read_mount(Core.write_mount({}, invalid), []).is_err() and Core.read_mount(Core.write_mount({}, valid), []).is_ok()
}

## Container intent is checked after namespace inheritance resolves. This is
## construction policy, never inferred by the browser from an element's tag.
checked_container : Web.Tag, [Children, TemplateContent] -> U8
checked_container = |name, container| {
	if container == Children {
		return 0
	}
	if container == TemplateContent and name.namespace() == Explicit(Html) and name.local() == "template" {
		return 1
	}
	crash "contract: template content requires an HTML template element"
}

## Ordinary and parsed template descriptions differ only by the decided child
## container operand; no second scope, route or emitted fragment node is added.
expect {
	view = || Core.element("template", [], [Core.text("inert")])
	ordinary = Core.driver(Core.program(view))
	parsed = Core.driver(Core.program(|| Core.template_content(view())))
	(raw_state, raw_commands, raw_work) = (ordinary.init)([])
	(parsed_state, parsed_commands, parsed_work) = (parsed.init)([])
	var $changed = 0.U64
	var $index = 0.U64
	while $index < raw_commands.len() {
		if raw_commands.get($index) != parsed_commands.get($index) {
			$changed = $changed + 1
		}
		$index = $index + 1
	}
	$changed == 1 and raw_commands.len() == parsed_commands.len() and raw_work == parsed_work and Core.settled(raw_state).is_ok() and Core.settled(parsed_state).is_ok()
}

## Semantic control claims use the actual encoded attribute identity. Raw HTML
## names fold once; explicitly qualified and namespaced spellings remain exact.
expect {
	input = resolve_element(Web.Tag.from_str("input")?, root_enclosing)
	raw = Web.AttrName.from_str("VALUE")?
	exact = raw.in_namespace({ namespace: None })?
	namespaced = raw.in_namespace({ namespace: Uri("urn:attribute"), prefix: Prefix("a") })?
	ordinary_attribute_is(resolve_attribute(raw, input), "value") and !ordinary_attribute_is(resolve_attribute(exact, input), "value") and !ordinary_attribute_is(resolve_attribute(namespaced, input), "value")
}

## Case-preserved uppercase attributes are distinct from the lower-case names
## owned by controlled dialog state, including dynamic attribute declarations.
expect {
	open = Web.AttrName.from_str("OPEN")?.in_namespace({ namespace: None })?
	popover = Web.AttrName.from_str("PoPoVeR")?.in_namespace({ namespace: None })?
	close : HandlerOf(Root({}), Bool)
	close = { run: |env, _, _| (env, no_layers) }
	program = Core.driver(Core.program(|| Core.controlled_dialog({ label: "Exact attributes", open: Core.const(False), on_close: close, modal: Modal, attrs: [Core.attr_named(open, ""), Core.attr_named_s(popover, Core.const("manual"))], children: [] })))
	(state, _, _) = (program.init)([])
	Core.settled(state).is_ok()
}

## Literal and ordinary construction share property claims only after explicit
## resolution. Exact uppercase and namespaced attributes are separate identities.
expect {
	element = resolve_element(Web.Tag.from_str("input")?, root_enclosing)
	raw = Web.AttrName.from_str("VALUE")?
	exact = raw.in_namespace({ namespace: None })?
	foreign = raw.in_namespace({ namespace: Uri("urn:attr"), prefix: Prefix("a") })?
	Core.attribute_claim(element, resolve_attribute(raw, element)) == Claimed("value") and Core.attribute_claim(element, exact) == Unclaimed and Core.attribute_claim(element, foreign) == Unclaimed
}

## Translate expanded identity without recovering a prefix from local text.
construction_name : { namespace : Web.Namespace, prefix : Web.Prefix, local : Str } -> Markup.Name
construction_name = |name| {
	uri = namespace_uri(name.namespace)
	{
		local: name.local,
		namespace: if (uri.is_empty()) NoNamespace else Uri(uri),
		prefix: match name.prefix {
			Unprefixed => Unprefixed
			Prefix(value) => Prefix(value)
		},
	}
}

## Keep the parser's rule and the shared wording; the boundary adds its site.
construction_advice : Markup.ConstructionRepair -> Str
construction_advice = |repair| MarkupAdvice.repair(
	repair.rule,
	{
		parent: "<${repair.parent.local}>",
		child: match repair.child {
			Element(name) => "<${name.local}>"
			Text => "text"
		},
	},
)

## Only restricted table text scans the new value. No earlier value is held.
check_construction_text : ParsedHtml.Construction.Context, { value : Str, site : List(U32), placement : Str } -> {}
check_construction_text = |context, { value, site, placement }| match ParsedHtml.Construction.text(context, value) {
	Ok(_) => {}
	Err(Repair(repair)) => crash "contract: ${construction_advice(repair)}${placement} at site ${show_path(site)}"
}

## Text holes retain finite enclosing facts beside their existing reader,
## never an element description or another copy of application storage.
checked_text_read : (ctx -> Str), { context : ParsedHtml.Construction.Context, site : List(U32), placement : Str } -> (ctx -> Str)
checked_text_read = |read, facts| |environment| {
	value = read(environment)
	check_construction_text(facts.context, { value, site: facts.site, placement: facts.placement })
	value
}

## Expanded-name aliases reach the parser with one URI identity and exact
## local/prefix data. Construction never splits a colon-bearing local name.
expect {
	construction_name({ namespace: Uri("http://www.w3.org/1999/xhtml"), prefix: Prefix("h"), local: "DIV" }) == { namespace: Uri("http://www.w3.org/1999/xhtml"), prefix: Prefix("h"), local: "DIV" }
}

## Each sibling resumes the parent's bounded context. A nested paragraph
## restriction persists through a span, while a button scope ends it.
expect {
	paragraph = ParsedHtml.Construction.enter(root_enclosing.construction, construction_name({ namespace: Html, prefix: Unprefixed, local: "p" }))?
	span = ParsedHtml.Construction.enter(paragraph, construction_name({ namespace: Html, prefix: Unprefixed, local: "span" }))?
	button = ParsedHtml.Construction.enter(paragraph, construction_name({ namespace: Html, prefix: Unprefixed, local: "button" }))?
	block = construction_name({ namespace: Html, prefix: Unprefixed, local: "div" })
	{
		nested: ParsedHtml.Construction.enter(span, block).is_err(),
		outside: ParsedHtml.Construction.enter(root_enclosing.construction, block).is_ok(),
		button_scope: ParsedHtml.Construction.enter(button, block).is_ok(),
	} == { nested: True, outside: True, button_scope: True }
}

## Restricted table text accepts HTML whitespace only, including the empty
## anchor; a nonbreaking space is content which the parser would relocate.
expect {
	table = ParsedHtml.Construction.root({ parent: construction_name({ namespace: Html, prefix: Unprefixed, local: "table" }) })
	{
		empty: ParsedHtml.Construction.text(table, "").is_ok(),
		space: ParsedHtml.Construction.text(table, " \t\r\n").is_ok(),
		content: ParsedHtml.Construction.text(table, "row").is_err(),
		nbsp: ParsedHtml.Construction.text(table, "\u(00A0)").is_err(),
	} == { empty: True, space: True, content: True, nbsp: True }
}

## Real mounting accepts sibling paragraphs, parser-defined table delegation
## and unknown raw names without adding an authoring-vocabulary restriction.
expect {
	view = Core.element(
		"main",
		[],
		[
			Core.element("p", [], [Core.element("span", [], [Core.text("one")])]),
			Core.element("div", [], [Core.text("sibling")]),
			Core.element("table", [], [Core.element("tbody", [], [Core.element("tr", [], [Core.element("td", [], [Core.text("cell")])])]), Core.element("script", [], [Core.text("let answer = 42;")]), Core.template_content(Core.element("template", [], [Core.element("p", [], [Core.text("inert")])]))]),
			Core.element("raw-unknown", [], [Core.text("available")]),
		],
	)
	Core.settled(Core.mount(view)).is_ok()
}

## A kept row's restricted text reader checks its new value and remains an
## ordinary hole. Legal whitespace changes settle through the normal turn.
expect {
	view = Core.state(
		False,
		|changed| Core.element(
			"main",
			[],
			[
				Core.element("button", [Core.on_click(changed.update(|value| !value))], []),
				Core.each(changed.signal().map(|value| [if (value) "\t" else " "]), |_| "one", |row| Core.element("table", [], [Core.text_s(row.item())])),
			],
		),
	)
	(before, _) = Core.take_cmds(Core.mount(view), [])
	after = Core.event(before, 2, 0, "")
	Core.settled(after).is_ok()
}

## A deferred branch keeps the context at its site; a legal table section
## can mount after an earlier empty branch and preserve the settled guard.
expect {
	view = Core.state(
		False,
		|shown| Core.element(
			"main",
			[],
			[
				Core.element("button", [Core.on_click(shown.update(|value| !value))], []),
				Core.element("table", [], [Core.when(shown.signal(), || Core.element("tbody", [], [Core.element("tr", [], [Core.element("td", [], [Core.text("later")])])]), || Core.text(""))]),
			],
		),
	)
	(before, _) = Core.take_cmds(Core.mount(view), [])
	Core.settled(Core.event(before, 2, 0, "")).is_ok()
}

## An effect-only site emits no child node, so placing it in a void element
## does not trigger the rule for anchors or authored text children.
expect Core.settled(Core.mount(Core.element("input", [], [Core.guard_leave(Core.const(False))]))).is_ok()

## Capturing a picture uses one ordinary mount and leaves no collector in its
## returned state; later events emit the same bytes and work as ordinary init.
expect {
	program = Core.program(|| Core.state(0.U64, |counter| Core.element("button", [Core.on_click(counter.update(|value| value + 1))], [Core.text_s(counter.signal().map(U64.to_str))])))
	picture = Core.init_picture(program, [])
	(normal, normal_commands, normal_work) = (Core.driver(program).init)([])
	frames = picture.capture?
	mount_cleared = PictureCapture.finish(picture.state.tx.fx.batch.capture) == Err(NotCaptured)
	(captured_event, captured_commands, captured_work) = (Core.driver(program).event)(picture.state, [], [], 1, 0, [])
	(normal_event, event_commands, event_work) = (Core.driver(program).event)(normal, [], [], 1, 0, [])
	mount_cleared and picture.commands == normal_commands and picture.work == normal_work and captured_commands == event_commands and captured_work == event_work and frames.all(|frame| picture.commands.get(frame.at.to_u64()) == Ok(frame.opcode)) and PictureCapture.finish(captured_event.tx.fx.batch.capture) == Err(NotCaptured) and Core.settled(captured_event).is_ok() and Core.settled(normal_event).is_ok()
}

## A row birth carries both its nested-site and reference alias, with the
## INST's final byte boundary and distinct hole roles, without rereading data.
expect {
	program = Core.program(|| Core.element("main", [], [Core.each(Core.const(["row"]), |key| key, |row| Core.element("article", [Core.ref_s(row.item())], [Core.when(Core.const(True), || Core.text("inside"), || Core.text("else"))]))]))
	picture = Core.init_picture(program, [])
	frames = picture.capture?
	row = frames.find_first(|frame| frame.opcode == 1)?
	aliases = frames.keep_if(|frame| frame.opcode == 0)
	aliases.len() == 2 and aliases.map(|frame| frame.kind).sort_with(
		|left, right| if left < right {
			Before
		} else if left == right {
			Same
		} else {
			After
		},
	) == [4, 5] and aliases.all(|frame| frame.at == row.at and frame.end == row.end and frame.address != row.address and frame.address != 0) and Core.settled(picture.state).is_ok()
}

## Port messages inserted between ordinary mount commands preserve every
## captured final boundary, including a later self-result turn's replacement.
expect {
	message = { json: "\"λ\"", blobs: [[0, 255]], files: [] }
	program = Core.program(
		|| Core.state(
			True,
			|visible| Core.element(
				"main",
				[],
				[
					Core.text("before"),
					Core.watch(Core.const({}), |_| [PortCommand({ port: "test/command", message }), PortCall({ port: "test/call", message, timeout_ms: 0 }), PortSubscribe({ port: "test/subscription", message })].map(Core.raw), Core.ignore({})),
					Core.when(visible.signal(), || Core.element("span", [], [Core.text("first")]), || Core.text("replacement")),
					Core.watch(Core.const({}), |_| [Core.again({})], visible.on_result(|_, _, _| False)),
					Core.text("after"),
				],
			),
		),
	).with_ports([Core.port_declaration("test/command", Command), Core.port_declaration("test/call", Call), Core.port_declaration("test/subscription", Subscription(Latest))])
	picture = Core.init_picture(program, [])
	frames = picture.capture?
	commands = frames.keep_if(|frame| frame.opcode != 0)
	var $end = 1.U32
	var $matches = True
	for frame in commands {
		$matches = $matches and frame.at == $end and picture.commands.get(frame.at.to_u64()) == Ok(frame.opcode)
		$end = frame.end
	}
	(_, normal_commands, normal_work) = (Core.driver(program).init)([])
	$matches and $end.to_u64() == picture.commands.len() and picture.commands == normal_commands and picture.work == normal_work and commands.any(|frame| frame.opcode == 19) and commands.any(|frame| frame.opcode == 5) and Core.settled(picture.state).is_ok()
}

## A refused capture still writes every port command and keeps the ordinary
## counters. Its temporary insertion list cannot grow past the capture budget.
expect {
	message = { json: "null", blobs: [], files: [] }
	catalogue = { workers: [], ports: ports_of([Core.port_declaration("test/bounded", Command)]), media: [] }
	view = || Core.watch(Core.const({}), |_| List.repeat(PortCommand({ port: "test/bounded", message }), 3).map(Core.raw), Core.ignore({}))
	captured = mount_start_captured({ max: 32, programs: catalogue, start: { st: {}, tables: [] }, elem: view(), enclosing: root_enclosing, capture: PictureCapture.start({ max_records: 1 })? })
	refusal = PictureCapture.finish(captured.tx.fx.batch.capture)
	(captured_state, captured_commands) = Core.take_cmds(captured, [])
	(normal, commands) = Core.take_cmds(mount_in(32, catalogue, {}, view()), [])
	refusal == Err(CaptureLimit) and captured_commands == commands and Core.work_counters(captured_state) == Core.work_counters(normal) and Core.work_counters(captured_state).get(40) == Ok(3)
}
