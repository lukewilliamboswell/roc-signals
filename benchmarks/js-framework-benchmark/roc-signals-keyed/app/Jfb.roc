import pf.Engine exposing [Elem, Handler, In, Keyed, Root, Row, RowRef, State]

## The js-framework-benchmark keyed table: two states (rows model, selected
## key), one keyed `each` whose template is described once per site.
Jfb := [].{
	Item : { id : U64, label : Str }

	Model : { rows : List(Item), next_id : U64, seed : U64 }

	Ctx : In(In(Root, Model), Str)

	initial : Model
	initial = { rows: [], next_id: 1, seed: 42 }

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

	add_rows : Model, U64 -> Model
	add_rows = |model, n| {
		{ rows, next_id, seed } = model
		var $rows = rows
		var $id = next_id
		var $seed = seed
		var $i = 0.U64
		while $i < n {
			g = Jfb.gen_label($seed)
			$seed = g.seed
			$rows = $rows.append({ id: $id, label: g.label })
			$id = $id + 1
			$i = $i + 1
		}
		{ rows: $rows, next_id: $id, seed: $seed }
	}

	run : Model, U64 -> Model
	run = |model, n| {
		{ rows, next_id, seed } = model
		Jfb.add_rows({ rows: rows.clear(), next_id, seed }, n)
	}

	update_every_10 : Model -> Model
	update_every_10 = |model| {
		{ rows, next_id, seed } = model
		var $rows = rows
		var $i = 0.U64
		while $i < $rows.len() {
			{ list, prev } = $rows.replace($i, { id: 0, label: "" }) ?? crash "row"
			{ id, label } = prev
			$rows = list.set($i, { id, label: "${label} !!!" }) ?? crash "row"
			$i = $i + 10
		}
		{ rows: $rows, next_id, seed }
	}

	swap_rows : Model -> Model
	swap_rows = |model| {
		{ rows, next_id, seed } = model
		swapped = if (rows.len() > 998) rows.swap(1, 998) ?? rows else rows
		{ rows: swapped, next_id, seed }
	}

	remove : Model, U64 -> Model
	remove = |model, id| {
		{ rows, next_id, seed } = model
		kept = match rows.find_first_index(|r| r.id == id) {
			Ok(i) => rows.drop_at(i)
			Err(_) => rows
		}
		{ rows: kept, next_id, seed }
	}

	clear : Model -> Model
	clear = |model| {
		{ rows, next_id, seed } = model
		{ rows: rows.clear(), next_id, seed }
	}

	button : Str, Str, Handler(Ctx) -> Elem(Ctx)
	button = |id, label, h| Engine.element(
		"div",
		[Engine.class("col-sm-6 smallpad")],
		[Engine.element("button", [Engine.attr("type", "button"), Engine.class("btn btn-primary btn-block"), Engine.attr("id", id), Engine.on_click(h)], [Engine.text(label)])],
	)

	row_view : RowRef(Ctx, Item), Keyed(Ctx, Str), State(Ctx, Model), State(Ctx, Str) -> Elem(Row(Ctx, Item))
	row_view = |row, sel, model, selected| {
		key = row.key()
		Engine.element(
			"tr",
			[Engine.class_v(row.select(sel))],
			[
				Engine.element("td", [Engine.class("col-md-1")], [Engine.text_v(key)]),
				Engine.element("td", [Engine.class("col-md-4")], [Engine.element("a", [Engine.on_click(selected.lift_row().update_by(key, |_, k| k))], [Engine.text_v(row.field(|r| r.label))])]),
				Engine.element(
					"td",
					[Engine.class("col-md-1")],
					[Engine.element("a", [Engine.on_click(model.lift_row().update_by(row.field(|r| r.id), Jfb.remove))], [Engine.element("span", [Engine.class("glyphicon glyphicon-remove"), Engine.attr("aria-hidden", "true")], [])])],
				),
				Engine.element("td", [Engine.class("col-md-6")], []),
			],
		)
	}

	view : {} -> Elem(Root)
	view = |_| Jfb.view_with(1000, 10000)

	## `small` rows for run/add, `lots` for runlots.
	view_with : U64, U64 -> Elem(Root)
	view_with = |small, lots| Engine.state(
		Jfb.initial,
		|outer| Engine.state(
			"",
			|selected| {
				model = outer.lift()
				rows = model.val().map(|v| v.rows)
				sel = Engine.keyed(selected.val(), "danger", "")
				Engine.element(
					"div",
					[Engine.class("container")],
					[
						Engine.element(
							"div",
							[Engine.class("jumbotron")],
							[
								Engine.element(
									"div",
									[Engine.class("row")],
									[
										Engine.element("div", [Engine.class("col-md-6")], [Engine.element("h1", [], [Engine.text("Roc Signals keyed")])]),
										Engine.element(
											"div",
											[Engine.class("col-md-6")],
											[
												Engine.element(
													"div",
													[Engine.class("row")],
													[
														Jfb.button("run", "Create 1,000 rows", model.update(|v| Jfb.run(v, small))),
														Jfb.button("runlots", "Create 10,000 rows", model.update(|v| Jfb.run(v, lots))),
														Jfb.button("add", "Append 1,000 rows", model.update(|v| Jfb.add_rows(v, small))),
														Jfb.button("update", "Update every 10th row", model.update(Jfb.update_every_10)),
														Jfb.button("clear", "Clear", model.update(Jfb.clear)),
														Jfb.button("swaprows", "Swap Rows", model.update(Jfb.swap_rows)),
													],
												),
											],
										),
									],
								),
							],
						),
						Engine.element(
							"table",
							[Engine.class("table table-hover table-striped test-data")],
							[Engine.element("tbody", [Engine.attr("id", "tbody")], [Engine.each(rows, |r| r.id.to_str(), |row| Jfb.row_view(row, sel, model, selected))])],
						),
						Engine.element("span", [Engine.class("preloadicon glyphicon glyphicon-remove"), Engine.attr("aria-hidden", "true")], []),
					],
				)
			},
		),
	)
}
