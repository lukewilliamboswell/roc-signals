## The grid's rows and the rules over them: what a row holds, which rows a
## listing keeps and in what order, the page a reader sees, and the summary
## of the rows a filter matches. Nothing here knows the engine, so every
## rule is a plain function that an `expect` or `fuzz-rows.roc` can check.
GridData :: [].{

	# ---------------------------------------------------------------------------
	# Dataset
	#
	# 1200 rows generated deterministically in Roc. There are no fixtures: the
	# whole grid is a pure function of `row_count`.
	# ---------------------------------------------------------------------------

	row_count : U64
	row_count = 1200

	page_size : U64
	page_size = 10

	## Which of the four teams a row belongs to. `to_str` is the only place a
	## team name is spelled.
	Team := [Atlas, Borealis, Cobalt, Delta].{
		is_eq : _

		## The rendered cell text, and what the filter box matches against.
		to_str : Team -> Str
		to_str = |team|
			match team {
				Atlas => "Atlas"
				Borealis => "Borealis"
				Cobalt => "Cobalt"
				Delta => "Delta"
			}

		## Sort position. The declaration order is alphabetical, so ordering by
		## rank is ordering by name without building a `Str` to compare.
		rank : Team -> U64
		rank = |team|
			match team {
				Atlas => 0
				Borealis => 1
				Cobalt => 2
				Delta => 3
			}
	}

	## The teams in rank order, so the generator can pick one by hash slot
	## instead of branching on the slot number.
	teams : List(Team)
	teams = [Atlas, Borealis, Cobalt, Delta]

	## Whether the reader has ticked a row.
	Selection : [Selected, Unselected]

	## One row of the grid. Its id is its key in the table, not a field. The
	## name, team and score are generated; the note and the selection are
	## the reader's, so they live in the row and go wherever it is listed.
	Row : { name : Str, team : Team, score : U64, note : Str, selection : Selection }

	team_of : U64 -> Team
	team_of = |id| teams.get((id * 7 + 3) % 4) ?? Atlas

	pad4 : U64 -> Str
	pad4 = |value| {
		text = value.to_str()
		if value < 10 {
			"000${text}"
		} else if value < 100 {
			"00${text}"
		} else if value < 1000 {
			"0${text}"
		} else {
			text
		}
	}

	score_of : U64 -> U64
	score_of = |id| (id * 37 + (id * id) % 101) % 1000

	## The row the dataset holds under `id`, with no note and unselected.
	row_of : U64 -> Row
	row_of = |id| { name: "Node-${pad4(id)}", team: team_of(id), score: score_of(id), note: "", selection: Unselected }

	## The first `count` rows of the dataset, each under its id.
	generate_rows : U64 -> List({ key : U64, row : Row })
	generate_rows = |count| {
		var $out = List.with_capacity(count)
		for id in 0..<count {
			$out = $out.append({ key: id, row: row_of(id) })
		}
		$out
	}

	all_rows : List({ key : U64, row : Row })
	all_rows = generate_rows(row_count)

	# ---------------------------------------------------------------------------
	# The listing: which rows, in what order
	# ---------------------------------------------------------------------------

	## Which column the grid is ordered by. `to_str` is the one place the
	## caption's wording comes from.
	SortKey := [ById, ByName, ByTeam, ByScore].{
		is_eq : _

		## The column name as it appears in the sort caption.
		to_str : SortKey -> Str
		to_str = |key|
			match key {
				ById => "id"
				ByName => "name"
				ByTeam => "team"
				ByScore => "score"
			}
	}

	Sort : { key : SortKey, desc : Bool }

	## The order the grid opens in.
	first_sort : Sort
	first_sort = { key: ById, desc: False }

	## What the grid lists: the rows the filter box's text matches, in the
	## order the sort buttons chose. It is plain data, so a view of the rows
	## can tell a changed listing from the same one.
	Listing : { filter : Str, sort : Sort }

	## Where a row stands in a listing's order: the sorted column's value (a
	## name's bytes, or a team's rank or a score as a number), then the
	## row's id, so that no two rows tie. Whichever of `name` and `number`
	## the sort does not use is left empty or zero for every row.
	Place := { name : List(U8), number : U64, id : U64, desc : Bool }.{
		is_eq : _

		## Column ties follow id, with descending reversing that tie too.
		order_relative_to : Place, Place -> [Before, Same, After]
		order_relative_to = |left, right| {
			if left.desc != right.desc {
				return if (left.desc) After else Before
			}
			ascending = match GridData.bytes_compare(left.name, right.name) {
				Same => match left.number.order_relative_to(right.number) {
					Same => left.id.order_relative_to(right.id)
					other => other
				}
				other => other
			}
			if left.desc {
				match ascending {
					Before => After
					Same => Same
					After => Before
				}
			} else {
				ascending
			}
		}
	}

	matches : Row, Str -> Bool
	matches = |row, filter|
		if filter.is_empty() {
			True
		} else {
			row.name.contains(filter) or row.team.to_str().contains(filter)
		}

	## A row's place when the grid is ordered by `key`.
	place : U64, Row, SortKey -> Place
	place = |id, row, key|
		match key {
			ById => { name: [], number: 0, id, desc: False }
			ByName => { name: row.name.to_utf8(), number: 0, id, desc: False }
			ByTeam => { name: [], number: row.team.rank(), id, desc: False }
			ByScore => { name: [], number: row.score, id, desc: False }
		}

	## Lexicographic byte order. There is no `Str.compare` in this build, so
	## the grid supplies the one comparator it needs.
	bytes_compare : List(U8), List(U8) -> [Before, Same, After]
	bytes_compare = |left, right|
		match (left.first(), right.first()) {
			(Ok(x), Ok(y)) =>
				if x == y {
					bytes_compare(left.drop_first(1), right.drop_first(1))
				} else if x < y {
					Before
				} else {
					After
				}
			(Err(_), Ok(_)) => Before
			(Ok(_), Err(_)) => After
			_ => Same
		}

	## How a listing selects and orders rows: what a view of the rows asks.
	## A descending sort is the ascending order with its sides exchanged, so
	## rows that tie on the column are reversed too.
	plan : Listing -> { keep : U64, Row -> Bool, sort : U64, Row -> Place }
	plan = |{ filter, sort: { key, desc } }| {
		keep: |_id, row| matches(row, filter),
		sort: |id, row| { ..place(id, row, key), desc },
	}

	sort_caption : Sort -> Str
	sort_caption = |sort| {
		direction =
			if sort.desc {
				"descending"
			} else {
				"ascending"
			}
		"Sorted by ${sort.key.to_str()} ${direction}"
	}

	## Clicking the column you are already sorted by reverses it; clicking any
	## other column starts that column ascending.
	apply_sort_click : Sort, SortKey -> Sort
	apply_sort_click = |sort, key|
		if sort.key.is_eq(key) {
			{ key, desc: !sort.desc }
		} else {
			{ key, desc: False }
		}

	# ---------------------------------------------------------------------------
	# Pages
	# ---------------------------------------------------------------------------

	## The last page of `count` listed rows, counting pages from 0.
	last_page_of : U64 -> U64
	last_page_of = |count|
		if count == 0 {
			0
		} else {
			(count - 1) // page_size
		}

	## The page the grid shows when the reader asked for page `asked` and
	## `count` rows are listed: the page asked for, or the last page when a
	## filter left fewer. The page asked for is kept, so widening the filter
	## shows it again.
	page_shown : U64, U64 -> U64
	page_shown = |asked, count| {
		last = last_page_of(count)
		if (asked > last) last else asked
	}

	## The part of the listing that page `page` draws.
	window_of : U64 -> { start : U64, count : U64 }
	window_of = |page| { start: page * page_size, count: page_size }

	## How many of `count` listed rows page `page` holds.
	rows_on : U64, U64 -> U64
	rows_on = |page, count| {
		start = page * page_size
		if start >= count {
			0
		} else if count - start < page_size {
			count - start
		} else {
			page_size
		}
	}

	## The page a paging button turns to from page `shown`.
	turned : U64, [First, Previous, Next] -> U64
	turned = |shown, turn|
		match turn {
			First => 0
			Previous => if (shown == 0) 0 else shown - 1
			Next => shown + 1
		}

	# ---------------------------------------------------------------------------
	# What the reader edits
	# ---------------------------------------------------------------------------

	noted : Row, Str -> Row
	noted = |row, note| { ..row, note }

	marked : Row, Selection -> Row
	marked = |row, selection| { ..row, selection }

	# ---------------------------------------------------------------------------
	# Summary
	# ---------------------------------------------------------------------------

	## What the summary tiles show: the rows the filter matches, their
	## scores, and how many rows are selected among them and in all.
	Summary : { matching : U64, total : U64, highest : U64, lowest : U64, selected_here : U64, selected_all : U64 }

	## The summary of no rows, where a fold over the rows starts.
	no_rows : Summary
	no_rows = { matching: 0, total: 0, highest: 0, lowest: 0, selected_here: 0, selected_all: 0 }

	## `so_far` with one more row counted. The rows can come in any order.
	counted : Summary, Row, Str -> Summary
	counted = |so_far, row, filter| {
		selected = if (row.selection == Selected) 1 else 0
		if matches(row, filter) {
			first = so_far.matching == 0
			{
				matching: so_far.matching + 1,
				total: so_far.total + row.score,
				highest: if (first or row.score > so_far.highest) row.score else so_far.highest,
				lowest: if (first or row.score < so_far.lowest) row.score else so_far.lowest,
				selected_here: so_far.selected_here + selected,
				selected_all: so_far.selected_all + selected,
			}
		} else {
			{ ..so_far, selected_all: so_far.selected_all + selected }
		}
	}

	## The mean score of the matching rows, rounded down; 0 when none match.
	average : Summary -> U64
	average = |summary| if (summary.matching == 0) 0 else summary.total // summary.matching
}

## A filter matches a row's name or its team's name, and no filter matches every row.
expect {
	row = GridData.row_of(7)
	actual =
		\\row: ${row.name} ${row.team.to_str()}
		\\by name: ${Str.inspect(GridData.matches(row, "Node-0007"))}
		\\by team: ${Str.inspect(GridData.matches(row, "Atlas"))}
		\\other: ${Str.inspect(GridData.matches(row, "Delta"))}
		\\none: ${Str.inspect(GridData.matches(row, ""))}
	expected =
		\\row: Node-0007 Atlas
		\\by name: True
		\\by team: True
		\\other: False
		\\none: True
	actual == expected
}

## Rows that tie on the sorted column are ordered by id, and a descending sort reverses them too.
expect {
	ordered = |sort| {
		asked = GridData.plan({ filter: "", sort })
		[3, 1, 2]
			.map(|id| (asked.sort)(id, { ..GridData.row_of(id), score: 5 }))
			.sort()
			.map(|at| at.id)
	}
	(ordered({ key: ByScore, desc: False }), ordered({ key: ByScore, desc: True })) == ([1, 2, 3], [3, 2, 1])
}

## A page past the end is shown as the last page, and the last page holds what is left.
expect {
	actual =
		\\last of 0, 10, 11: ${GridData.last_page_of(0).to_str()} ${GridData.last_page_of(10).to_str()} ${GridData.last_page_of(11).to_str()}
		\\asked 3 of 25 rows: ${GridData.page_shown(3, 25).to_str()}
		\\asked 1 of 25 rows: ${GridData.page_shown(1, 25).to_str()}
		\\rows on pages 0, 2, 3 of 25: ${GridData.rows_on(0, 25).to_str()} ${GridData.rows_on(2, 25).to_str()} ${GridData.rows_on(3, 25).to_str()}
		\\window of page 2: ${Str.inspect(GridData.window_of(2))}
	expected =
		\\last of 0, 10, 11: 0 0 1
		\\asked 3 of 25 rows: 2
		\\asked 1 of 25 rows: 1
		\\rows on pages 0, 2, 3 of 25: 10 5 0
		\\window of page 2: { count: 10, start: 20 }
	actual == expected
}

## The previous page of the first page is the first page.
expect [First, Previous, Next].map(|turn| GridData.turned(0, turn)) == [0, 0, 1]

## A note and a tick each change their own field of a row and leave the rest of it alone.
expect {
	row = GridData.row_of(3)
	edited = GridData.marked(GridData.noted(row, "needs review"), Selected)
	edited == { ..row, note: "needs review", selection: Selected }
}

## A summary counts the selected rows the filter matches apart from all the selected rows.
expect {
	rows = [3, 7, 11].map(|id| GridData.marked(GridData.row_of(id), Selected))
	summary = rows.fold(GridData.no_rows, |so_far, row| GridData.counted(so_far, row, "Node-0007"))
	(summary.matching, summary.selected_here, summary.selected_all, GridData.average(summary)) == (1, 1, 3, 308)
}
