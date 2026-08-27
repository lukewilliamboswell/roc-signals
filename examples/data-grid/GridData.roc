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

	## Which of the four teams a row belongs to.
	##
	## The dataset generator picks a team from a hash of the row id. That used to
	## be an `if slot == 0 { "Atlas" } else if slot == 1 { … }` ladder over a bare
	## integer; the tags carry the meaning the integers only hinted at, and the
	## single `to_str` is the only place a team name is spelled.
	Team := [Atlas, Borealis, Cobalt, Delta].{
		is_eq : Team, Team -> Bool
		is_eq = |left, right|
			match left {
				Atlas => match right {
					Atlas => True
					_ => False
				}
				Borealis => match right {
					Borealis => True
					_ => False
				}
				Cobalt => match right {
					Cobalt => True
					_ => False
				}
				Delta => match right {
					Delta => True
					_ => False
				}
			}

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

	Row : { id : U64, name : Str, team : Team, score : U64 }

	team_of : U64 -> Team
	team_of = |id| teams.get((id * 7 + 3) % 4).ok_or(Atlas)

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

	## Lexicographic byte order over two strings. There is no `Str.compare` in
	## this build, so the grid supplies the one comparator it needs; the walk is
	## recursive rather than a `var $state = 2` integer state machine.
	str_compare : Str, Str -> [LT, EQ, GT]
	str_compare = |left, right| bytes_compare(left.to_utf8(), right.to_utf8())

	bytes_compare : List(U8), List(U8) -> [LT, EQ, GT]
	bytes_compare = |left, right|
		match (left.first(), right.first()) {
			(Ok(x), Ok(y)) =>
				if x == y {
					bytes_compare(left.drop_first(1), right.drop_first(1))
				} else if x < y {
					LT
				} else {
					GT
				}
			(Err(_), Ok(_)) => LT
			(Ok(_), Err(_)) => GT
			_ => EQ
		}

	generate_rows : U64 -> List(Row)
	generate_rows = |count| {
		var $out = []
		var $id = 0
		while $id < count {
			$out = $out.append(
				{
					id: $id,
					name: "Node-${pad4($id)}",
					team: team_of($id),
					score: score_of($id),
				},
			)
			$id = $id + 1
		}
		$out
	}

	all_rows : List(Row)
	all_rows = generate_rows(row_count)

	# ---------------------------------------------------------------------------
	# Pure grid logic
	# ---------------------------------------------------------------------------

	## Which column the grid is ordered by.
	##
	## The sort buttons used to pass the column name as a `Str` and three separate
	## functions re-tested it with `==`. As a tag the compiler checks every branch
	## is covered, and `to_str` is the one place the caption's wording comes from.
	SortKey := [ById, ByName, ByTeam, ByScore].{
		is_eq : SortKey, SortKey -> Bool
		is_eq = |left, right|
			match left {
				ById => match right {
					ById => True
					_ => False
				}
				ByName => match right {
					ByName => True
					_ => False
				}
				ByTeam => match right {
					ByTeam => True
					_ => False
				}
				ByScore => match right {
					ByScore => True
					_ => False
				}
			}

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

	Note : { id : U64, note : Str }

	ViewRow : { id : U64, name : Str, team : Str, score : U64, note : Str, selected : Bool }

	Summary : { matching : U64, total : U64, average : U64, highest : U64, lowest : U64, selected_here : U64, selected_all : U64 }

	matches : Row, Str -> Bool
	matches = |row, query|
		if query.is_empty() {
			True
		} else {
			row.name.contains(query) or row.team.to_str().contains(query)
		}

	filter_rows : Str -> List(Row)
	filter_rows = |query|
		if query.is_empty() {
			all_rows
		} else {
			all_rows.keep_if(|row| matches(row, query))
		}

	## The reverse of an ordering, used to turn the ascending comparator into the
	## descending one.
	flip : [LT, EQ, GT] -> [LT, EQ, GT]
	flip = |order|
		match order {
			LT => GT
			GT => LT
			EQ => EQ
		}

	## Ascending order for one column, with the row id as the tiebreak so the
	## comparator is a strict total order and the sort is deterministic.
	row_order : Row, Row, SortKey -> [LT, EQ, GT]
	row_order = |a, b, key| {
		by_id = U64.compare(a.id, b.id)
		match key {
			ById => by_id
			ByName =>
				match str_compare(a.name, b.name) {
					EQ => by_id
					other => other
				}
			ByTeam =>
				match U64.compare(a.team.rank(), b.team.rank()) {
					EQ => by_id
					other => other
				}
			ByScore =>
				match U64.compare(a.score, b.score) {
					EQ => by_id
					other => other
				}
		}
	}

	## Ordering for the whole sort, honouring the descending flag.
	sort_order : Row, Row, Sort -> [LT, EQ, GT]
	sort_order = |a, b, sort| {
		order = row_order(a, b, sort.key)
		if sort.desc {
			flip(order)
		} else {
			order
		}
	}

	merge_rows : List(Row), List(Row), Sort -> List(Row)
	merge_rows = |left, right, sort| {
		var $l = left
		var $r = right
		var $out = []
		while !$l.is_empty() and !$r.is_empty() {
			match ($l.first(), $r.first()) {
				(Ok(a), Ok(b)) => {
					match sort_order(a, b, sort) {
						GT => {
							$out = $out.append(b)
							$r = $r.drop_first(1)
						}
						_ => {
							$out = $out.append(a)
							$l = $l.drop_first(1)
						}
					}
				}
				_ => {
					$l = []
					$r = []
				}
			}
		}
		$out.concat($l).concat($r)
	}

	## A merge sort, deliberately, rather than `List.sort_with`. That builtin is
	## a quicksort that takes the first element as its pivot and partitions with
	## two `keep_if` passes, so it degrades to O(n^2) on input that is already
	## ordered -- which is exactly this grid, whose 1200 rows are generated in id
	## order and default to sorting by id. Going through `sort_with` here took
	## over a minute per spec. See UPSTREAM_COMPILER_BUGS.md #8.
	sort_rows : List(Row), Sort -> List(Row)
	sort_rows = |rows, sort| {
		len = rows.len()
		if len <= 1 {
			rows
		} else {
			half = len // 2
			merge_rows(
				sort_rows(rows.take_first(half), sort),
				sort_rows(rows.drop_first(half), sort),
				sort,
			)
		}
	}

	last_page_of : U64 -> U64
	last_page_of = |count|
		if count == 0 {
			0
		} else {
			(count - 1) // page_size
		}

	window_of : List(Row), U64 -> List(Row)
	window_of = |rows, page| rows.drop_first(page * page_size).take_first(page_size)

	note_for : List(Note), U64 -> Str
	note_for = |notes, id|
		notes.find_first(|entry| entry.id == id).map_ok(|entry| entry.note).ok_or("")

	set_note : List(Note), U64, Str -> List(Note)
	set_note = |notes, id, note| notes.keep_if(|entry| entry.id != id).append({ id, note })

	is_selected : List(U64), U64 -> Bool
	is_selected = |selected, id| selected.contains(id)

	toggle_selected : List(U64), U64, Bool -> List(U64)
	toggle_selected = |selected, id, on| {
		without = selected.keep_if(|value| value != id)
		if on {
			without.append(id)
		} else {
			without
		}
	}

	set_all_matching : List(U64), Str, Bool -> List(U64)
	set_all_matching = |selected, query, on| {
		matching_ids = filter_rows(query).map(|row| row.id)
		kept = selected.keep_if(|id| !matching_ids.contains(id))
		if on {
			kept.concat(matching_ids)
		} else {
			kept
		}
	}

	## The edge where the internal `Team` tag becomes the text a cell renders.
	decorate : List(Row), { selected : List(U64), notes : List(Note) } -> List(ViewRow)
	decorate = |rows, ctx|
		rows.map(
			|row| {
				id: row.id,
				name: row.name,
				team: row.team.to_str(),
				score: row.score,
				note: note_for(ctx.notes, row.id),
				selected: is_selected(ctx.selected, row.id),
			},
		)

	summarize : List(Row), List(U64) -> Summary
	summarize = |rows, selected| {
		first_score =
			match rows.first() {
				Ok(row) => row.score
				Err(_) => 0
			}
		var $total = 0
		var $highest = first_score
		var $lowest = first_score
		var $selected_here = 0
		for row in rows {
			$total = $total + row.score
			if row.score > $highest {
				$highest = row.score
			} else {}
			if row.score < $lowest {
				$lowest = row.score
			} else {}
			if is_selected(selected, row.id) {
				$selected_here = $selected_here + 1
			} else {}
		}
		matching = rows.len()
		average =
			if matching == 0 {
				0
			} else {
				$total // matching
			}
		{
			matching,
			total: $total,
			average,
			highest: $highest,
			lowest: $lowest,
			selected_here: $selected_here,
			selected_all: selected.len(),
		}
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

}
