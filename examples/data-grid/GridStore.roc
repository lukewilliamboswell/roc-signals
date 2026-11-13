import pf.Engine exposing [Signal, Table]
import GridData

## The grid's store: the state the controls, the summary, the rows and the
## paging buttons share, held at the root and reached from any of them with
## no `lift`.
##
## - `rows` is a table: the dataset by row id. A row holds its own note and
##   selection, so a row's edits are writes of that one row and go with it
##   wherever a listing puts it.
## - `filter` is the text in the filter box and `sort` the order the sort
##   buttons chose. Together they are the listing the rows are drawn in
##   (`listing`); apart, a change of order wakes no reader of the filter.
## - `page` is the page the reader asked for. The page shown is worked out
##   from it and from how many rows the filter matches (`GridData.page_shown`),
##   so a filter that leaves fewer pages does not lose the reader's place.
##   A paging button steps from the page shown, which then is the page
##   asked for.
##
## Every change to them from outside a row is one of the transitions below:
## a pure function from what the event carries to the writes it makes. A
## row's own note and selection are written through the handle its view
## hands it.
GridStore := [Grid].{

	store = Engine.store(
		GridStore.Grid,
		{
			rows: Engine.table(GridData.all_rows),
			filter: Engine.cell(""),
			sort: Engine.cell(GridData.first_sort),
			page: Engine.cell(0.U64),
		}.Engine.Cells,
	)

	## The store's cells.
	cells = GridStore.store.cells()

	## The listing the rows are drawn in: the query of the grid's view.
	listing : {} -> Signal(ctx, GridData.Listing)
		where [ctx.store : () -> Engine.Reach(ctx, _)]
	listing = |{}| { filter: GridStore.cells.filter.signal(), sort: GridStore.cells.sort.signal() }.Signal

	## The summary of the rows the filter matches: a pass over the table,
	## taken again whenever a row or the filter is written.
	summary : {} -> Signal(ctx, GridData.Summary)
		where [ctx.store : () -> Engine.Reach(ctx, _)]
	summary = |{}| GridStore.cells.rows.signal().map2(GridStore.cells.filter.signal(), GridStore.summary_of)

	summary_of : Table(U64, GridData.Row), Str -> GridData.Summary
	summary_of = |table, filter| table.fold(GridData.no_rows, |so_far, _id, row| GridData.counted(so_far, row, filter))

	## Typing in the filter box.
	filtered : Str -> List(Engine.Write(_))
	filtered = |text| [GridStore.cells.filter.set(text)]

	## A click on a sort button.
	sorted_by : GridData.SortKey -> List(Engine.Write(_))
	sorted_by = |key| [GridStore.cells.sort.update(|sort| GridData.apply_sort_click(sort, key))]

	## A click on a paging button while the grid shows page `shown`: the
	## page asked for is the one the button turns to from there. The page
	## shown is what the reader sees, and it is not the page asked for
	## while a filter leaves fewer pages.
	paged : U64, [First, Previous, Next] -> List(Engine.Write(_))
	paged = |shown, turn| [GridStore.cells.page.set(GridData.turned(shown, turn))]

	## Ticking or clearing "Select all matching rows" while the filter box
	## holds `filter`.
	marked_matching : Str, GridData.Selection -> List(Engine.Write(_))
	marked_matching = |filter, selection| [GridStore.cells.rows.update(|table| GridStore.with_matching(table, filter, selection))]

	## `table` with every row `filter` matches given `selection`. Only the
	## rows it changes are written, each by its key, so a view of the table
	## hears of those rows and no others. The writes are a fold over the
	## keys rather than a `while` loop over a `var` holding the table,
	## which copies the table on every iteration in optimised builds
	## (roc-lang/roc#12971).
	with_matching : Table(U64, GridData.Row), Str, GridData.Selection -> Table(U64, GridData.Row)
	with_matching = |table, filter, selection| {
		ids = table.fold([], |found, id, row| if (row.selection != selection and GridData.matches(row, filter)) found.append(id) else found)
		ids.fold(table, |written, id| written.update(id, |row| GridData.marked(row, selection)))
	}
}

## The store opens on every row, in id order, at the first page, with nothing selected.
expect {
	opened = GridStore.store
	summary = GridStore.summary_of(opened.read(GridStore.cells.rows), opened.read(GridStore.cells.filter))
	actual =
		\\rows: ${opened.read(GridStore.cells.rows).len().to_str()}
		\\sort: ${GridData.sort_caption(opened.read(GridStore.cells.sort))}
		\\page: ${opened.read(GridStore.cells.page).to_str()}
		\\matching: ${summary.matching.to_str()}
		\\selected: ${summary.selected_all.to_str()}
	expected =
		\\rows: 1200
		\\sort: Sorted by id ascending
		\\page: 0
		\\matching: 1200
		\\selected: 0
	actual == expected
}

## A second click on the same sort button reverses the order, and a click on another starts it ascending.
expect {
	captions = [[ByScore], [ByScore, ByScore], [ByScore, ByScore, ByName]].map(
		|clicks| GridData.sort_caption(GridStore.store.after(clicks.map(GridStore.sorted_by).join()).read(GridStore.cells.sort)),
	)
	captions == ["Sorted by score ascending", "Sorted by score descending", "Sorted by name ascending"]
}

## Typing a filter leaves the page asked for as it was, so clearing the filter shows that page again.
expect {
	narrowed = GridStore.store.after(GridStore.paged(0, Next)).after(GridStore.paged(1, Next)).after(GridStore.filtered("Node-119"))
	(narrowed.read(GridStore.cells.filter), narrowed.read(GridStore.cells.page)) == ("Node-119", 2)
}

## A paging button steps from the page shown: with the fourth page asked for and a filter that leaves two, "Previous page" asks for the first.
expect {
	narrowed = GridStore.store.after([GridStore.cells.page.set(3)]).after(GridStore.filtered("119"))
	matching = GridStore.summary_of(narrowed.read(GridStore.cells.rows), narrowed.read(GridStore.cells.filter)).matching
	shown = GridData.page_shown(narrowed.read(GridStore.cells.page), matching)
	back = narrowed.after(GridStore.paged(shown, Previous))
	(matching, shown, back.read(GridStore.cells.page)) == (12, 1, 0)
}

## Selecting every matching row selects the rows the filter matches and no others, and clearing them leaves a row selected outside the filter as it was.
expect {
	rows = GridStore.cells.rows
	one = GridStore.store.after([rows.update(|table| table.update(3, |row| GridData.marked(row, Selected)))])
	all = one.after(GridStore.marked_matching("Node-119", Selected))
	cleared = all.after(GridStore.marked_matching("Node-119", Unselected))
	show = |held| {
		here = GridStore.summary_of(held.read(rows), "Node-119")
		"${here.selected_here.to_str()} of ${here.matching.to_str()} matching, ${here.selected_all.to_str()} in all"
	}
	actual =
		\\one: ${show(one)}
		\\all: ${show(all)}
		\\cleared: ${show(cleared)}
	expected =
		\\one: 0 of 10 matching, 1 in all
		\\all: 10 of 10 matching, 11 in all
		\\cleared: 0 of 10 matching, 1 in all
	actual == expected
}

## Selecting every matching row writes only the rows it changes: of ten matching rows with one selected already, nine.
expect {
	entries = GridData.generate_rows(20).map(|entry| if (entry.key == 3) { key: 3, row: GridData.marked(entry.row, Selected) } else entry)
	selected = GridStore.with_matching(Table.from_list(entries), "Node-000", Selected)
	selected.inverse().map_ok(|undo| undo.len()) == Ok(9)
}
