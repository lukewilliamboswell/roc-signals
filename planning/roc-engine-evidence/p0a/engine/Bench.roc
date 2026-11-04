## The js-framework-benchmark application on the Phase 0a engine core, plus a
## second site with a different row type (todos) in the same State.
import Engine

Bench := [].{
	Item : { id : U64, label : Str, clicks : U64 }

	Todo : { id : U64, title : Str, done : Bool }

	Msg : [
		Run(U64),
		Add(U64),
		UpdateEvery10,
		UpdateOne(U64),
		UpdateTwice(U64),
		UpdateAndAdd(U64),
		Select(U64),
		Deselect,
		SwapRows,
		Swap(U64, U64),
		Remove(U64),
		Clear,
		Touch(U64),
		Relabel(U64, Str),
		AddTodo(Str),
		ToggleTodo(U64),
		RemoveTodo(U64),
		RenameTodo(U64, Str),
		ClearAll,
	]

	Model : { next_id : U64, seed : U64, next_todo : U64 }

	Sites : Engine.Both(Engine.EachSite(Item, Msg), Engine.EachSite(Todo, Msg))

	App : Engine.State(Model, Sites, Msg)

	Tx : Engine.Tx(Model, Sites)

	adjectives : List(Str)
	adjectives = ["pretty", "large", "big", "small", "tall", "short", "long", "handsome", "plain", "quaint", "clean", "elegant", "easy", "angry", "crazy", "helpful", "mushy", "odd", "unsightly", "adorable", "important", "inexpensive", "cheap", "expensive", "fancy"]

	colours : List(Str)
	colours = ["red", "yellow", "blue", "green", "pink", "brown", "purple", "brown", "white", "black", "orange"]

	nouns : List(Str)
	nouns = ["table", "chair", "house", "bbq", "desk", "car", "pony", "cookie", "sandwich", "burger", "pizza", "mouse", "keyboard"]

	next_seed : U64 -> U64
	next_seed = |s| s.times_wrap(6364136223846793005).plus_wrap(1442695040888963407)

	pick : List(Str), U64 -> Str
	pick = |words, s| words.get(s.shr_zf_wrap(33) % words.len()) ?? ""

	## The benchmark's random "adjective colour noun" label.
	gen_label : U64 -> { label : Str, seed : U64 }
	gen_label = |seed| {
		s1 = Bench.next_seed(seed)
		s2 = Bench.next_seed(s1)
		s3 = Bench.next_seed(s2)
		{ label: "${Bench.pick(Bench.adjectives, s1)} ${Bench.pick(Bench.colours, s2)} ${Bench.pick(Bench.nouns, s3)}", seed: s3 }
	}

	bench_desc : Engine.RowDesc(Item, Msg)
	bench_desc = {
		key: |item| item.id,
		label: |item| item.label,
		class: |_item, selected| if selected 1 else 0,
		on_select: |key| Select(key),
		on_remove: |key| Remove(key),
	}

	todo_desc : Engine.RowDesc(Todo, Msg)
	todo_desc = {
		key: |t| t.id,
		label: |t| t.title,
		class: |t, _selected| if t.done 2 else 0,
		on_select: |key| ToggleTodo(key),
		on_remove: |key| RemoveTodo(key),
	}

	init : Bool -> App
	init = |tracing| {
		sites = Engine.Both.new(Engine.EachSite.new(1, 1, Bench.bench_desc), Engine.EachSite.new(2, 2, Bench.todo_desc))
		Engine.State.init({ next_id: 1, seed: 42, next_todo: 1 }, sites, tracing)
	}

	add_rows : Engine.EachSite(Item, Msg), Model, Engine.Ctx, U64 -> { site : Engine.EachSite(Item, Msg), model : Model, ctx : Engine.Ctx }
	add_rows = |site, model, ctx, n| {
		var $site = site
		var $ctx = ctx
		var $id = model.next_id
		var $seed = model.seed
		var $i = 0.U64
		while $i < n {
			g = Bench.gen_label($seed)
			$seed = g.seed
			(next_site, next_ctx) = $site.push({ id: $id, label: g.label, clicks: 0 }, $ctx)
			$site = next_site
			$ctx = next_ctx
			$id = $id + 1
			$i = $i + 1
		}
		{ site: $site, model: { next_id: $id, seed: $seed, next_todo: model.next_todo }, ctx: $ctx }
	}

	BSite : Engine.EachSite(Item, Msg)

	TSite : Engine.EachSite(Todo, Msg)

	## Run `f` on the bench site with the transaction consumed and rebuilt. Each
	## message branch calls exactly one of these, so the site is uniquely owned
	## inside `f` (a site referenced across several match branches was copied).
	on_left : Tx, (BSite, Model, Engine.Ctx -> { site : BSite, model : Model, ctx : Engine.Ctx }) -> Tx
	on_left = |tx, f| {
		{ model, sites, ctx } = tx
		{ left, right } = sites
		r = f(left, model, ctx)
		{ model: r.model, sites: Engine.Both.new(r.site, right), ctx: r.ctx }
	}

	on_right : Tx, (TSite, Model, Engine.Ctx -> { site : TSite, model : Model, ctx : Engine.Ctx }) -> Tx
	on_right = |tx, f| {
		{ model, sites, ctx } = tx
		{ left, right } = sites
		r = f(right, model, ctx)
		{ model: r.model, sites: Engine.Both.new(left, r.site), ctx: r.ctx }
	}

	done : (s, Engine.Ctx), Model -> { site : s, model : Model, ctx : Engine.Ctx }
	done = |(site, ctx), model| { site, model, ctx }

	set_label : BSite, Model, Engine.Ctx, U64, (Item -> Item) -> { site : BSite, model : Model, ctx : Engine.Ctx }
	set_label = |site, model, ctx, key, change| {
		item = site.get(key) ?? crash "key"
		Bench.done(site.set(key, change(item), ctx), model)
	}

	update_every_10 : BSite, Model, Engine.Ctx -> { site : BSite, model : Model, ctx : Engine.Ctx }
	update_every_10 = |site, model, ctx| {
		var $site = site
		var $ctx = ctx
		var $pos = 0.U64
		while $pos < $site.len() {
			key = $site.key_at($pos) ?? crash "position"
			item = $site.get(key) ?? crash "key"
			(s, c) = $site.set(key, { id: item.id, label: "${item.label} !!!", clicks: item.clicks }, $ctx)
			$site = s
			$ctx = c
			$pos = $pos + 10
		}
		{ site: $site, model, ctx: $ctx }
	}

	run_rows : BSite, Model, Engine.Ctx, U64 -> { site : BSite, model : Model, ctx : Engine.Ctx }
	run_rows = |site, model, ctx, n| {
		(cleared, c1) = if site.len() > 0 site.clear(ctx) else (site, ctx)
		Bench.add_rows(cleared, model, c1, n)
	}

	update : Tx, Msg -> Tx
	update = |tx, msg| match msg {
		Run(n) => Bench.on_left(tx, |s, m, c| Bench.run_rows(s, m, c, n))
		Add(n) => Bench.on_left(tx, |s, m, c| Bench.add_rows(s, m, c, n))
		UpdateEvery10 => Bench.on_left(tx, |s, m, c| Bench.update_every_10(s, m, c))
		UpdateOne(key) => Bench.on_left(tx, |s, m, c| Bench.set_label(s, m, c, key, |i| { id: i.id, label: "${i.label} !!!", clicks: i.clicks }))
		UpdateTwice(key) => Bench.on_left(tx, |s, m, c| {
			{ site: s2, model: m2, ctx: c2 } = Bench.set_label(s, m, c, key, |i| { id: i.id, label: "${i.label} !!!", clicks: i.clicks })
			Bench.set_label(s2, m2, c2, key, |i| { id: i.id, label: "${i.label} !!!", clicks: i.clicks })
		})
		UpdateAndAdd(key) => Bench.on_left(tx, |s, m, c| {
			{ site: s2, model: m2, ctx: c2 } = Bench.set_label(s, m, c, key, |i| { id: i.id, label: "${i.label} !!!", clicks: i.clicks })
			Bench.add_rows(s2, m2, c2, 1)
		})
		Touch(key) => Bench.on_left(tx, |s, m, c| Bench.set_label(s, m, c, key, |i| { id: i.id, label: i.label, clicks: i.clicks + 1 }))
		Relabel(key, label) => Bench.on_left(tx, |s, m, c| Bench.set_label(s, m, c, key, |i| { id: i.id, label, clicks: i.clicks }))
		Select(key) => Bench.on_left(tx, |s, m, c| Bench.done(s.select(Ok(key), c), m))
		Deselect => Bench.on_left(tx, |s, m, c| Bench.done(s.select(Err(None), c), m))
		# swap_positions ignores out-of-range positions. Do not branch on `s` here:
		# a closure that may return its site unchanged made every on_left closure
		# borrow, so all row writes copied the column (see report).
		SwapRows => Bench.on_left(tx, |s, m, c| Bench.done(s.swap_positions(1, 998, c), m))
		Swap(i, j) => Bench.on_left(tx, |s, m, c| Bench.done(s.swap_positions(i, j, c), m))
		Remove(key) => Bench.on_left(tx, |s, m, c| Bench.done(s.remove(key, c), m))
		Clear => Bench.on_left(tx, |s, m, c| Bench.done(s.clear(c), m))
		AddTodo(title) => Bench.on_right(tx, |s, m, c| Bench.done(s.push({ id: m.next_todo, title, done: False }, c), { next_id: m.next_id, seed: m.seed, next_todo: m.next_todo + 1 }))
		ToggleTodo(key) => Bench.on_right(tx, |s, m, c| {
			t = s.get(key) ?? crash "todo"
			Bench.done(s.set(key, { id: t.id, title: t.title, done: !t.done }, c), m)
		})
		RenameTodo(key, title) => Bench.on_right(tx, |s, m, c| {
			t = s.get(key) ?? crash "todo"
			Bench.done(s.set(key, { id: t.id, title, done: t.done }, c), m)
		})
		RemoveTodo(key) => Bench.on_right(tx, |s, m, c| Bench.done(s.remove(key, c), m))
		ClearAll => {
			{ model, sites, ctx } = tx
			{ left, right } = sites
			(l, c1) = left.clear(ctx)
			(r, c2) = right.clear(c1)
			{ model, sites: Engine.Both.new(l, r), ctx: c2 }
		}
	}
}
