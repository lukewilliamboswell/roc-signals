import Engine

## Copy of the jfb app (benchmarks/js-framework-benchmark/roc-engine-keyed/app/main.roc) as a module, for native allocation counts.
Jfb := [].{


	## The js-framework-benchmark keyed table on the pure Roc engine (Phase 1 spike).

	Item : { id : U64, label : Str }

	Msg : [Run(U64), Add(U64), UpdateEvery10, Clear, SwapRows, Select(U64), Remove(U64)]

	Model : { next_id : U64, seed : U64 }

	Site : Engine.EachSite(Item, Msg)

	Sites : Site

	Tx : Engine.Tx(Model, Sites)

	tbody_node : U32
	tbody_node = 100

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
		s1 = Jfb.next_seed(seed)
		s2 = Jfb.next_seed(s1)
		s3 = Jfb.next_seed(s2)
		{ label: "${Jfb.pick(Jfb.adjectives, s1)} ${Jfb.pick(Jfb.colours, s2)} ${Jfb.pick(Jfb.nouns, s3)}", seed: s3 }
	}

	row_template : List(U8)
	row_template = Engine.template(
		Engine.tel(
			"tr",
			[],
			[
				Engine.tel("td", [("class", "col-md-1")], [Engine.ttxt("")]),
				Engine.tel("td", [("class", "col-md-4")], [Engine.tel("a", [], [Engine.ttxt("")])]),
				Engine.tel("td", [("class", "col-md-1")], [Engine.tel("a", [], [Engine.tel("span", [("class", "glyphicon glyphicon-remove"), ("aria-hidden", "true")], [])])]),
				Engine.tel("td", [("class", "col-md-6")], []),
			],
		),
		[HText([0, 0]), HText([1, 0, 0]), HClass([], ["", "danger"]), HClick([1, 0], 1), HClick([2, 0], 2)],
	)

	row_desc : Engine.RowDesc(Item, Msg)
	row_desc = {
		key: |item| item.id,
		write_static: |buf, item| Engine.put_str(buf, item.id.to_str()),
		template: Jfb.row_template,
		label_hole: 1,
		class_hole: 2,
		count_node: 0,
		label: |item| item.label,
		class: |_item, selected| if selected 1 else 0,
		on_select: |key| Select(key),
		on_remove: |key| Remove(key),
	}

	button : Str, Str, Msg -> Engine.View(Msg)
	button = |id, text, msg| Engine.el("div", [("class", "col-sm-6 smallpad")], [Engine.button([("type", "button"), ("class", "btn btn-primary btn-block"), ("id", id)], text, msg)])

	view : Engine.View(Msg)
	view = Engine.el(
		"div",
		[("class", "container")],
		[
			Engine.el(
				"div",
				[("class", "jumbotron")],
				[
					Engine.el(
						"div",
						[("class", "row")],
						[
							Engine.el("div", [("class", "col-md-6")], [Engine.el("h1", [], [Engine.txt("Roc Engine-keyed")])]),
							Engine.el(
								"div",
								[("class", "col-md-6")],
								[
									Engine.el(
										"div",
										[("class", "row")],
										[
											Jfb.button("run", "Create 1,000 rows", Run(1000)),
											Jfb.button("runlots", "Create 10,000 rows", Run(10000)),
											Jfb.button("add", "Append 1,000 rows", Add(1000)),
											Jfb.button("update", "Update every 10th row", UpdateEvery10),
											Jfb.button("clear", "Clear", Clear),
											Jfb.button("swaprows", "Swap Rows", SwapRows),
										],
									),
								],
							),
						],
					),
				],
			),
			Engine.el("table", [("class", "table table-hover table-striped test-data")], [Engine.el_id(Jfb.tbody_node, "tbody", [("id", "tbody")], [])]),
			Engine.el("span", [("class", "preloadicon glyphicon glyphicon-remove"), ("aria-hidden", "true")], []),
		],
	)

	Out : { site : Site, model : Model, ctx : Engine.Ctx }

	add_rows : Site, Model, Engine.Ctx, U64 -> Out
	add_rows = |site, model, ctx, n| {
		var $site = site
		var $ctx = ctx
		var $id = model.next_id
		var $seed = model.seed
		var $i = 0.U64
		while $i < n {
			g = Jfb.gen_label($seed)
			$seed = g.seed
			(next_site, next_ctx) = $site.push({ id: $id, label: g.label }, $ctx)
			$site = next_site
			$ctx = next_ctx
			$id = $id + 1
			$i = $i + 1
		}
		{ site: $site, model: { next_id: $id, seed: $seed }, ctx: $ctx }
	}

	## Run `f` on the site with the transaction consumed and rebuilt. Each message
	## branch calls exactly one of these, so the site is uniquely owned inside `f`.
	on_site : Tx, (Site, Model, Engine.Ctx -> Out) -> Tx
	on_site = |tx, f| {
		{ model, sites, ctx } = tx
		r = f(sites, model, ctx)
		{ model: r.model, sites: r.site, ctx: r.ctx }
	}

	done : (s, Engine.Ctx), Model -> { site : s, model : Model, ctx : Engine.Ctx }
	done = |(site, ctx), model| { site, model, ctx }

	update_every_10 : Site, Model, Engine.Ctx -> Out
	update_every_10 = |site, model, ctx| {
		var $site = site
		var $ctx = ctx
		var $pos = 0.U64
		while $pos < $site.len() {
			key = $site.key_at($pos) ?? crash "position"
			item = $site.get(key) ?? crash "key"
			(s, c) = $site.set(key, { id: item.id, label: "${item.label} !!!" }, $ctx)
			$site = s
			$ctx = c
			$pos = $pos + 10
		}
		{ site: $site, model, ctx: $ctx }
	}

	run_rows : Site, Model, Engine.Ctx, U64 -> Out
	run_rows = |site, model, ctx, n| {
		(cleared, c1) = if site.len() > 0 site.clear(ctx) else (site, ctx)
		Jfb.add_rows(cleared, model, c1, n)
	}

	update : Tx, Msg -> Tx
	update = |tx, msg| match msg {
		Run(n) => Jfb.on_site(tx, |s, m, c| Jfb.run_rows(s, m, c, n))
		Add(n) => Jfb.on_site(tx, |s, m, c| Jfb.add_rows(s, m, c, n))
		UpdateEvery10 => Jfb.on_site(tx, |s, m, c| Jfb.update_every_10(s, m, c))
		Select(key) => Jfb.on_site(tx, |s, m, c| Jfb.done(s.select(Ok(key), c), m))
		# swap_positions ignores out-of-range positions; do not branch on `s` here
		# (Phase 0a hazard 4: a closure that may return its site unchanged made every
		# Jfb.on_site closure borrow).
		SwapRows => Jfb.on_site(tx, |s, m, c| Jfb.done(s.swap_positions(1, 998, c), m))
		Remove(key) => Jfb.on_site(tx, |s, m, c| Jfb.done(s.remove(key, c), m))
		Clear => Jfb.on_site(tx, |s, m, c| Jfb.done(s.clear(c), m))
	}


	init : {} -> Engine.State(Model, Sites, Msg)
	init = |_| Engine.State.init({ next_id: 1, seed: 42 }, Engine.EachSite.new(1, Jfb.tbody_node, Jfb.row_desc), Jfb.view, 0, False)
}
