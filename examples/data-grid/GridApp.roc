import pf.Engine exposing [Elem, State, Val]
import pf.Html
import GridData
import GridStore

## Data Grid: 1200 generated rows to sort, filter, select and annotate, ten
## of them drawn at a time.
##
## The rows are a table in the app's store (`GridStore`) and the grid is a
## view of it. The listing (the filter and the sort) says which rows the
## view keeps and in what order, and its window is the page shown. Sorting,
## filtering and paging are therefore writes of three small cells: the view
## removes the rows that left the window and creates the ones that entered
## it, and no list of rows is ever built or compared. A note or a tick is a
## write of one row, through the handle the view hands that row.
##
## The summary is one pass over the table, taken again when a row or the
## filter is written and memoised by a `derive`: the tiles, the "select
## all" box and the paging buttons read its result, and a write that leaves
## it equal, such as a note, wakes none of them.
##
## Every part of the page reads the store's cells where it stands, so the
## functions below take only what is not in the store: the summary.
GridApp := [].{

	cell_class : Str
	cell_class = "text-sm text-zinc-800"

	grid_cols : Str
	grid_cols = "grid grid-cols-[2.5rem_minmax(0,1.2fr)_minmax(0,0.8fr)_minmax(0,0.6fr)_minmax(0,1.6fr)] items-center gap-3"

	## One row of the grid, drawn over the handle its view hands it: a read
	## is that row of the table, and a write changes that row and no other.
	line : Val(r, U64), State(r, GridData.Row) -> Elem(r)
	line = |id, held| {
		row = held.val()
		name = row.map(|r| r.name)
		named = |what| Engine.test_id_v(id.map(|k| "row-${what}-${k.to_str()}"))
		Html.div(
			"${GridApp.grid_cols} border-b border-zinc-100 px-3 py-2",
			[
				Html.checkbox(name.map(|n| "Select ${n}"), row.map(|r| r.selection == Selected), [Engine.class("checkbox")], held.set_value(|r, checked| GridData.marked(r, selection_of(checked)))),
				Html.p_v(name, [Engine.class("${GridApp.cell_class} font-medium numeric"), named("name")]),
				Html.p_v(row.map(|r| r.team.to_str()), [Engine.class(GridApp.cell_class), named("team")]),
				Html.p_v(row.map(|r| r.score.to_str()), [Engine.class("text-sm text-zinc-800 numeric text-right"), named("score")]),
				Html.text_input(name.map(|n| "Note for ${n}"), "text", row.map(|r| r.note), [Engine.class("input"), Engine.attr("placeholder", "e.g. needs review")], held.set_value(GridData.noted)),
			],
		)
	}

	stat_tile : Str, Val(ctx, Str), Str -> Elem(ctx)
	stat_tile = |label, figure, id| Html.div("stat", [Html.p(label, "stat-label"), Html.p_v(figure, [Engine.class("stat-value numeric"), Engine.test_id(id)])])

	sort_button : Str, GridData.SortKey -> Elem(ctx)
		where [ctx.store : () -> Engine.Reach(ctx, _)]
	sort_button = |label, key| Html.button(label, [Engine.class("button button-sm")], Engine.does(GridStore.sorted_by(key)))

	## The page shown: the page asked for, or the last page when the filter
	## matches too few rows to reach it.
	shown_page : Val(ctx, GridData.Summary) -> Val(ctx, U64)
		where [ctx.store : () -> Engine.Reach(ctx, _)]
	shown_page = |summary| GridStore.h.page.val().map2(summary, |asked, s| GridData.page_shown(asked, s.matching))

	## The filter box, the sort buttons and the caption of the current sort.
	controls : {} -> Elem(ctx)
		where [ctx.store : () -> Engine.Reach(ctx, _)]
	controls = |{}| {
		n = GridData.row_count.to_str()
		Html.section(
			"Grid controls",
			"panel grid gap-4 p-5",
			[
				Html.h2("Filter and sort", "panel-title"),
				Html.div(
					"toolbar",
					[
						Html.div(
							"field min-w-64 grow",
							[
								Html.p("Filter rows", "field-label"),
								Html.text_input(Engine.const("Filter"), "text", GridStore.h.filter.val(), [Engine.class("input"), Engine.attr("placeholder", "Node-0042 or Atlas")], Engine.handle(GridStore.filtered)),
								Html.p("Matches on name or team across all ${n} rows.", "hint"),
							],
						),
						Html.div(
							"field",
							[
								Html.p("Sort by", "field-label"),
								Html.div(
									"flex flex-wrap items-center gap-2",
									[
										GridApp.sort_button("Sort by id", ById),
										GridApp.sort_button("Sort by name", ByName),
										GridApp.sort_button("Sort by team", ByTeam),
										GridApp.sort_button("Sort by score", ByScore),
									],
								),
								Html.p_v(GridStore.h.sort.val().map(GridData.sort_caption), [Engine.class("badge badge-info w-fit"), Engine.test_id("sort-caption")]),
							],
						),
					],
				),
			],
		)
	}

	## The summary tiles.
	summary_panel : Val(ctx, GridData.Summary) -> Elem(ctx)
	summary_panel = |summary| Html.section(
		"Summary",
		"panel grid gap-4 p-5",
		[
			Html.h2("Summary", "panel-title"),
			Html.div(
				"stat-grid",
				[
					GridApp.stat_tile("Matching rows", summary.map(|s| s.matching.to_str()), "summary-matching"),
					GridApp.stat_tile("Total score", summary.map(|s| s.total.to_str()), "summary-total"),
					GridApp.stat_tile("Average score", summary.map(|s| GridData.average(s).to_str()), "summary-average"),
					GridApp.stat_tile("Highest score", summary.map(|s| s.highest.to_str()), "summary-highest"),
					GridApp.stat_tile("Lowest score", summary.map(|s| s.lowest.to_str()), "summary-lowest"),
					GridApp.stat_tile("Selected in filter", summary.map(|s| s.selected_here.to_str()), "summary-selected-here"),
					GridApp.stat_tile("Selected overall", summary.map(|s| s.selected_all.to_str()), "summary-selected-all"),
				],
			),
		],
	)

	## The rows: the "select all" box, and the page shown of the listing as
	## a view of the table.
	rows_panel : Val(ctx, GridData.Summary) -> Elem(ctx)
		where [ctx.store : () -> Engine.Reach(ctx, _)]
	rows_panel = |summary| {
		shown = GridApp.shown_page(summary)
		Html.section(
			"Rows",
			"panel",
			[
				Html.div(
					"panel-head",
					[
						Html.h2("Rows", "panel-title"),
						Html.div(
							"check-row",
							[
								Html.checkbox(
									Engine.const("Select all matching rows"),
									summary.map(|s| s.matching > 0 and s.selected_here == s.matching),
									[Engine.class("checkbox")],
									Engine.handle_by(GridStore.h.filter.val(), |filter, checked| GridStore.marked_matching(filter, selection_of(checked))),
								),
								Html.p("Select all matching rows", "text-sm text-zinc-700"),
							],
						),
						Html.p_v(shown.map2(summary, |page, s| "Showing ${GridData.rows_on(page, s.matching).to_str()} of ${s.matching.to_str()} rows"), [Engine.class("hint numeric"), Engine.test_id("rows-showing")]),
					],
				),
				Html.div(
					"panel-body",
					[
						Html.div(
							"table-scroll",
							[
								Html.div(
									"min-w-[46rem]",
									[
										Html.div(
											"${GridApp.grid_cols} border-b border-zinc-200 bg-zinc-50 px-3 py-2",
											[
												Html.p("Select", "text-xs font-semibold uppercase tracking-wide text-zinc-500"),
												Html.p("Name", "text-xs font-semibold uppercase tracking-wide text-zinc-500"),
												Html.p("Team", "text-xs font-semibold uppercase tracking-wide text-zinc-500"),
												Html.p("Score", "text-xs font-semibold uppercase tracking-wide text-zinc-500 text-right"),
												Html.p("Note", "text-xs font-semibold uppercase tracking-wide text-zinc-500"),
											],
										),
										Engine.each_view(
											GridStore.h.rows,
											{ query: GridStore.listing({}), plan: GridData.plan, window: shown.map(GridData.window_of) },
											GridApp.line,
										),
									],
								),
							],
						),
						Engine.when(
							summary.map(|s| s.matching > 0),
							|| Html.p("Notes are per row and survive sorting and paging.", "hint"),
							|| Html.div("empty-state", [Engine.element("p", [], [Engine.text("No rows match the filter")])]),
						),
					],
				),
			],
		)
	}

	## The page label and the paging buttons.
	paging : Val(ctx, GridData.Summary) -> Elem(ctx)
		where [ctx.store : () -> Engine.Reach(ctx, _)]
	paging = |summary| {
		shown = GridApp.shown_page(summary)
		last = summary.map(|s| GridData.last_page_of(s.matching))
		turn = |to| Engine.on_click(Engine.handle_by(shown, |page, _| GridStore.paged(page, to)))
		Html.section(
			"Paging",
			"panel flex flex-wrap items-center justify-between gap-3 p-4",
			[
				Html.p_v(shown.map2(last, |page, end| "Page ${(page + 1).to_str()} of ${(end + 1).to_str()}"), [Engine.class("value numeric"), Engine.test_id("page-label")]),
				Html.div(
					"flex flex-wrap items-center gap-2",
					[
						Engine.element("button", [Engine.class("button-ghost"), turn(First)], [Engine.text("First page")]),
						Engine.element("button", [Engine.class("button"), Html.disabled(shown.map(|page| page == 0)), turn(Previous)], [Engine.text("Previous page")]),
						Engine.element("button", [Engine.class("button-primary"), Html.disabled(shown.map2(last, |page, end| page >= end)), turn(Next)], [Engine.text("Next page")]),
					],
				),
			],
		)
	}

	## The whole page, under the summary it reads.
	view : {} -> Elem(Engine.StoreRoot(_))
	view = |{}| {
		n = GridData.row_count.to_str()
		Engine.derive(
			GridStore.summary({}),
			|summary| Html.div(
				"app-shell app-shell-wide",
				[
					Html.section(
						"Data Grid",
						"app-header",
						[
							Html.h1("Data Grid", "app-title"),
							Html.p("Sort, filter, select, and edit a generated ${n}-row dataset while rendering only ${GridData.page_size.to_str()} rows at a time.", "app-subtitle"),
							Html.p("Dataset rows: ${n}", "badge badge-neutral numeric w-fit"),
						],
					),
					GridApp.controls({}),
					GridApp.summary_panel(summary),
					GridApp.rows_panel(summary),
					GridApp.paging(summary),
				],
			),
		)
	}

	## The program `main.roc` binds for the browser module and the native spec
	## runner.
	program : Engine.Program
	program = Engine.program_store({ storage_keys: [], max_inflight: 32 }, |_boot| GridStore.store, |_boot| GridApp.view({}))
}

## What a checkbox's event says: `"true"` when it was ticked.
selection_of : Str -> GridData.Selection
selection_of = |checked| if (checked == "true") Selected else Unselected
