import Engine exposing [Elem, Val, State, In, Root, RowRef, Row]
import H
import GridData

## Data Grid on the p4 engine: a port of examples-web/data-grid.
##
## Five sources as in the original (sort, page, notes, filter query,
## selection), each its own state layer, then a chain of four memoised
## derivations: filtered (query), sorted (filtered x sort), summary (filtered x
## selection) and the visible page (sorted x page x selection x notes). Only
## the page's rows are rendered. The dataset is a parameter so the same view
## runs at two sizes.
GridApp := [].{
	Sort : GridData.Sort
	Note : GridData.Note
	View : { rows : List(GridData.ViewRow), current : U64, last : U64 }

	## The five state handles, lifted together through each derived layer.
	Hs(ctx) : { sort : State(ctx, Sort), page : State(ctx, U64), notes : State(ctx, List(Note)), query : State(ctx, Str), selected : State(ctx, List(U64)) }

	lift_hs : Hs(ctx) -> Hs(In(ctx, a))
	lift_hs = |{ sort, page, notes, query, selected }| { sort: sort.lift(), page: page.lift(), notes: notes.lift(), query: query.lift(), selected: selected.lift() }

	filter_in : List(GridData.Row), Str -> List(GridData.Row)
	filter_in = |data, query| if query.is_empty() data else data.keep_if(|row| GridData.matches(row, query))

	set_all_in : List(GridData.Row), List(U64), Str, Bool -> List(U64)
	set_all_in = |data, selected, query, on| {
		matching_ids = GridApp.filter_in(data, query).map(|row| row.id)
		kept = selected.keep_if(|id| !matching_ids.contains(id))
		if on kept.concat(matching_ids) else kept
	}

	view_of : List(GridData.Row), U64, List(U64), List(Note) -> View
	view_of = |sorted, requested, selected, notes| {
		last = GridData.last_page_of(sorted.len())
		current = if requested > last last else requested
		{ rows: GridData.decorate(GridData.window_of(sorted, current), { selected, notes }), current, last }
	}

	cell : Str
	cell = "text-sm text-zinc-800"

	grid_cols : Str
	grid_cols = "grid grid-cols-[2.5rem_minmax(0,1.2fr)_minmax(0,0.8fr)_minmax(0,0.6fr)_minmax(0,1.6fr)] items-center gap-3"

	render_row : Hs(ctx), RowRef(ctx, GridData.ViewRow) -> Elem(Row(ctx, GridData.ViewRow))
	render_row = |hs, row| {
		key = row.key()
		id = row.field(|r| r.id)
		name = row.field(|r| r.name)
		sel = hs.selected.lift_row()
		notes = hs.notes.lift_row()
		H.div(
			"${GridApp.grid_cols} border-b border-zinc-100 px-3 py-2",
			[
				H.checkbox(name.map(|n| "Select ${n}"), row.field(|r| r.selected), [Engine.class("checkbox")], sel.set_value_by(id, |cur, rid, v| GridData.toggle_selected(cur, rid, v == "true"))),
				H.p_v(name, [Engine.class("${GridApp.cell} font-medium numeric"), Engine.test_id_v(key.map(|k| "row-name-${k}"))]),
				H.p_v(row.field(|r| r.team), [Engine.class(GridApp.cell), Engine.test_id_v(key.map(|k| "row-team-${k}"))]),
				H.p_v(row.field(|r| r.score.to_str()), [Engine.class("text-sm text-zinc-800 numeric text-right"), Engine.test_id_v(key.map(|k| "row-score-${k}"))]),
				H.text_input(name.map(|n| "Note for ${n}"), "text", row.field(|r| r.note), [Engine.class("input"), Engine.attr("placeholder", "e.g. needs review")], notes.set_value_by(id, |cur, rid, v| GridData.set_note(cur, rid, v))),
			],
		)
	}

	stat_tile : Str, Val(ctx, Str), Str -> Elem(ctx)
	stat_tile = |label, figure, id| H.div("stat", [H.p(label, "stat-label"), H.p_v(figure, [Engine.class("stat-value numeric"), Engine.test_id(id)])])

	sort_button : State(ctx, Sort), Str, GridData.SortKey -> Elem(ctx)
	sort_button = |sort, label, key| H.button(label, [Engine.class("button button-sm")], sort.update(|cur| GridData.apply_sort_click(cur, key)))

	page_view : List(GridData.Row), Hs(ctx), Val(ctx, GridData.Summary), Val(ctx, View) -> Elem(ctx)
	page_view = |data, hs, summary, view| {
		n = data.len().to_str()
		current = view.map(|v| v.current)
		H.div(
			"app-shell app-shell-wide",
			[
				H.section(
					"Data Grid",
					"app-header",
					[
						H.h1("Data Grid", "app-title"),
						H.p("Sort, filter, select, and edit a generated ${n}-row dataset while rendering only ${GridData.page_size.to_str()} rows at a time.", "app-subtitle"),
						H.p("Dataset rows: ${n}", "badge badge-neutral numeric w-fit"),
					],
				),
				H.section(
					"Grid controls",
					"panel grid gap-4 p-5",
					[
						H.h2("Filter and sort", "panel-title"),
						H.div(
							"toolbar",
							[
								H.div(
									"field min-w-64 grow",
									[
										H.p("Filter rows", "field-label"),
										H.text_input(Engine.const("Filter"), "text", hs.query.val(), [Engine.class("input"), Engine.attr("placeholder", "Node-0042 or Atlas")], hs.query.set_value(|_, v| v)),
										H.p("Matches on name or team across all ${n} rows.", "hint"),
									],
								),
								H.div(
									"field",
									[
										H.p("Sort by", "field-label"),
										H.div(
											"flex flex-wrap items-center gap-2",
											[
												GridApp.sort_button(hs.sort, "Sort by id", ById),
												GridApp.sort_button(hs.sort, "Sort by name", ByName),
												GridApp.sort_button(hs.sort, "Sort by team", ByTeam),
												GridApp.sort_button(hs.sort, "Sort by score", ByScore),
											],
										),
										H.p_v(hs.sort.val().map(GridData.sort_caption), [Engine.class("badge badge-info w-fit"), Engine.test_id("sort-caption")]),
									],
								),
							],
						),
					],
				),
				H.section(
					"Summary",
					"panel grid gap-4 p-5",
					[
						H.h2("Summary", "panel-title"),
						H.div(
							"stat-grid",
							[
								GridApp.stat_tile("Matching rows", summary.map(|s| s.matching.to_str()), "summary-matching"),
								GridApp.stat_tile("Total score", summary.map(|s| s.total.to_str()), "summary-total"),
								GridApp.stat_tile("Average score", summary.map(|s| s.average.to_str()), "summary-average"),
								GridApp.stat_tile("Highest score", summary.map(|s| s.highest.to_str()), "summary-highest"),
								GridApp.stat_tile("Lowest score", summary.map(|s| s.lowest.to_str()), "summary-lowest"),
								GridApp.stat_tile("Selected in filter", summary.map(|s| s.selected_here.to_str()), "summary-selected-here"),
								GridApp.stat_tile("Selected overall", summary.map(|s| s.selected_all.to_str()), "summary-selected-all"),
							],
						),
					],
				),
				H.section(
					"Rows",
					"panel",
					[
						H.div(
							"panel-head",
							[
								H.h2("Rows", "panel-title"),
								H.div(
									"check-row",
									[
										H.checkbox(Engine.const("Select all matching rows"), summary.map(|s| s.matching > 0 and s.selected_here == s.matching), [Engine.class("checkbox")], hs.selected.set_value_by(hs.query.val(), |cur, q, v| GridApp.set_all_in(data, cur, q, v == "true"))),
										H.p("Select all matching rows", "text-sm text-zinc-700"),
									],
								),
								H.p_v(view.map2(summary, |v, s| "Showing ${v.rows.len().to_str()} of ${s.matching.to_str()} rows"), [Engine.class("hint numeric"), Engine.test_id("rows-showing")]),
							],
						),
						H.div(
							"panel-body",
							[
								H.div(
									"table-scroll",
									[
										H.div(
											"min-w-[46rem]",
											[
												H.div(
													"${GridApp.grid_cols} border-b border-zinc-200 bg-zinc-50 px-3 py-2",
													[
														H.p("Select", "text-xs font-semibold uppercase tracking-wide text-zinc-500"),
														H.p("Name", "text-xs font-semibold uppercase tracking-wide text-zinc-500"),
														H.p("Team", "text-xs font-semibold uppercase tracking-wide text-zinc-500"),
														H.p("Score", "text-xs font-semibold uppercase tracking-wide text-zinc-500 text-right"),
														H.p("Note", "text-xs font-semibold uppercase tracking-wide text-zinc-500"),
													],
												),
												Engine.each(view.map(|v| v.rows), |r| r.id.to_str(), |row| GridApp.render_row(hs, row)),
											],
										),
									],
								),
								Engine.when(
									summary.map(|s| s.matching > 0),
									|| H.p("Notes are per row and survive sorting and paging.", "hint"),
									|| H.div("empty-state", [Engine.element("p", [], [Engine.text("No rows match the filter")])]),
								),
							],
						),
					],
				),
				H.section(
					"Paging",
					"panel flex flex-wrap items-center justify-between gap-3 p-4",
					[
						H.p_v(view.map(|v| "Page ${(v.current + 1).to_str()} of ${(v.last + 1).to_str()}"), [Engine.class("value numeric"), Engine.test_id("page-label")]),
						H.div(
							"flex flex-wrap items-center gap-2",
							[
								H.button("First page", [Engine.class("button-ghost")], hs.page.update(|_| 0)),
								Engine.element("button", [Engine.class("button"), H.flag("disabled", current.map(|c| c == 0)), Engine.on_click(hs.page.update(|c| if c == 0 0 else c - 1))], [Engine.text("Previous page")]),
								Engine.element("button", [Engine.class("button-primary"), H.flag("disabled", view.map(|v| v.current >= v.last)), Engine.on_click(hs.page.update(|c| c + 1))], [Engine.text("Next page")]),
							],
						),
					],
				),
			],
		)
	}

	main : {} -> Elem(Root)
	main = |_| GridApp.main_with(GridData.all_rows)

	main_with : List(GridData.Row) -> Elem(Root)
	main_with = |data| Engine.state(
		{ key: ById, desc: False },
		|sort| Engine.state(
			0,
			|page| Engine.state(
				[],
				|notes| Engine.state(
					"",
					|query| Engine.state(
						[],
						|selected| {
							hs5 = { sort: sort.lift().lift().lift().lift(), page: page.lift().lift().lift(), notes: notes.lift().lift(), query: query.lift(), selected }
							Engine.derive(
								hs5.query.val().map(|q| GridApp.filter_in(data, q)),
								|filtered| {
									hs6 = GridApp.lift_hs(hs5)
									Engine.derive(
										filtered.map2(hs6.sort.val(), GridData.sort_rows),
										|sorted| {
											hs7 = GridApp.lift_hs(hs6)
											f7 = filtered.lift()
											Engine.derive(
												f7.map2(hs7.selected.val(), GridData.summarize),
												|summary| {
													hs8 = GridApp.lift_hs(hs7)
													s8 = sorted.lift()
													ctx8 = hs8.selected.val().map2(hs8.notes.val(), |sl, nt| (sl, nt))
													view = s8.map2(hs8.page.val().map2(ctx8, |p, c| (p, c)), |rows, (p, (sl, nt))| GridApp.view_of(rows, p, sl, nt))
													Engine.derive(view, |v| GridApp.page_view(data, GridApp.lift_hs(hs8), summary.lift(), v))
												},
											)
										},
									)
								},
							)
						},
					),
				),
			),
		),
	)
}
