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

	Row : { id : U64, name : Str, team : Str, score : U64 }

	team_of : U64 -> Str
	team_of = |id| {
		slot = (id * 7 + 3) % 4
		if slot == 0 {
			"Atlas"
		} else if slot == 1 {
			"Borealis"
		} else if slot == 2 {
			"Cobalt"
		} else {
			"Delta"
		}
	}

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

	str_lt : Str, Str -> Bool
	str_lt = |left, right| {
		var $a = left.to_utf8()
		var $b = right.to_utf8()
		# 2 = equal so far, 1 = left is smaller, 0 = left is not smaller
		var $state = 2.U8
		while $state == 2 {
			match ($a.first(), $b.first()) {
				(Ok(x), Ok(y)) => {
					if x == y {
						$a = $a.drop_first(1)
						$b = $b.drop_first(1)
					} else if x < y {
						$state = 1
					} else {
						$state = 0
					}
				}
				(Err(_), Ok(_)) => {
					$state = 1
				}
				_ => {
					$state = 0
				}
			}
		}
		$state == 1
	}

	parse_u64 : Str -> U64
	parse_u64 = |text| {
		var $value = 0
		for byte in text.to_utf8() {
			if byte >= 48 and byte <= 57 {
				$value = $value * 10 + U8.to_u64(byte) - 48
			} else {}
		}
		$value
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

	Sort : { key : Str, desc : Bool }

	Note : { id : U64, note : Str }

	ViewRow : { id : U64, name : Str, team : Str, score : U64, note : Str, selected : Bool }

	Summary : { matching : U64, total : U64, average : U64, highest : U64, lowest : U64, selected_here : U64, selected_all : U64 }

	matches : Row, Str -> Bool
	matches = |row, query|
		if query.is_empty() {
			True
		} else {
			row.name.contains(query) or row.team.contains(query)
		}

	filter_rows : Str -> List(Row)
	filter_rows = |query|
		if query.is_empty() {
			all_rows
		} else {
			all_rows.keep_if(|row| matches(row, query))
		}

	before : Row, Row, Sort -> Bool
	before = |a, b, sort| {
		ascending =
			if sort.key == "name" {
				if a.name == b.name {
					a.id <= b.id
				} else {
					str_lt(a.name, b.name)
				}
			} else if sort.key == "team" {
				if a.team == b.team {
					a.id <= b.id
				} else {
					str_lt(a.team, b.team)
				}
			} else if sort.key == "score" {
				if a.score == b.score {
					a.id <= b.id
				} else {
					a.score < b.score
				}
			} else {
				a.id <= b.id
			}
		if sort.desc {
			!ascending
		} else {
			ascending
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
					if before(a, b, sort) {
						$out = $out.append(a)
						$l = $l.drop_first(1)
					} else {
						$out = $out.append(b)
						$r = $r.drop_first(1)
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
		match notes.keep_if(|entry| entry.id == id).first() {
			Ok(entry) => entry.note
			Err(_) => ""
		}

	set_note : List(Note), U64, Str -> List(Note)
	set_note = |notes, id, note| notes.keep_if(|entry| entry.id != id).append({ id, note })

	is_selected : List(U64), U64 -> Bool
	is_selected = |selected, id| !selected.keep_if(|value| value == id).is_empty()

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
		kept = selected.keep_if(|id| !is_selected(matching_ids, id))
		if on {
			kept.concat(matching_ids)
		} else {
			kept
		}
	}

	decorate : List(Row), { selected : List(U64), notes : List(Note) } -> List(ViewRow)
	decorate = |rows, ctx|
		rows.map(
			|row| {
				id: row.id,
				name: row.name,
				team: row.team,
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
		"Sorted by ${sort.key} ${direction}"
	}

	apply_sort_click : Sort, Str -> Sort
	apply_sort_click = |sort, key|
		if sort.key == key {
			{ key, desc: !sort.desc }
		} else {
			{ key, desc: False }
		}

}
