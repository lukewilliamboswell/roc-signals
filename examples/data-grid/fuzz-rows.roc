app [target] {
	fz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.6.0/6uc3YKGydgEnS2nrCimSYWDNfT6drYcgU52VAwqrb6DS.tar.zst",
}

import fz.Fuzz
import GridData

## The grid's rows, against a model that sorts by insertion, totals by
## folding and pages by counting. The grid sorts with its own merge sort and
## comparator, pages a window at a time and keeps the selection as a list,
## so the bugs to fear are a row lost or doubled by a merge, an order that
## depends on where rows started, a page that skips or repeats a row, and a
## selection that holds an id twice.
##
## Each input decodes into rows (ids, names, teams and scores from small
## pools, so ties are common, and an id may repeat), a sort, a filter and a
## series of selection changes. Its properties:
##
## - sorting gives the model's stable sort by the column, then the id, in
##   the direction asked;
## - the pages, first to last, are the sorted rows in order, every page
##   full but the last, which is not empty unless there are no rows;
## - the summary's count, total, average, highest, lowest and selected
##   rows are the model's;
## - however rows are selected and cleared, one by one or every row the
##   filter matches, no id is selected twice, and the selection is the
##   model's set.
Input : { rows : List(U8), sort : U8, query : U8, picks : List(U8) }

## A row from one byte: its id, name, team and score from small pools.
row_of : U8 -> GridData.Row
row_of = |b| {
	n = b.to_u64()
	{ id: n % 23, name: "Node-${(n % 7).to_str()}", team: GridData.team_of(n % 5), score: (n * 37) % 11 }
}

## The sort a byte picks.
sort_of : U8 -> GridData.Sort
sort_of = |b| {
	key = match b % 4 {
		0 => ById
		1 => ByName
		2 => ByTeam
		_ => ByScore
	}
	{ key, desc: b >= 128 }
}

## The model's order: the column's value (a team by its name), then the id.
key_of : GridData.Row, GridData.Sort -> (List(U8), U64)
key_of = |row, sort| {
	column = match sort.key {
		ById => []
		ByName => row.name.to_utf8()
		ByTeam => row.team.to_str().to_utf8()
		ByScore => [(row.score // 256).to_u8_wrap(), row.score.to_u8_wrap()]
	}
	(column, row.id)
}

## Whether `a` comes strictly before `b` in the model's order.
before : GridData.Row, GridData.Row, GridData.Sort -> Bool
before = |a, b, sort| {
	(ka, ia) = key_of(a, sort)
	(kb, ib) = key_of(b, sort)
	less = |x, y| {
		var $i = 0
		while $i < x.len() and $i < y.len() {
			if x.get($i) != y.get($i) {
				return (x.get($i) ?? 0) < (y.get($i) ?? 0)
			}
			$i = $i + 1
		}
		x.len() < y.len()
	}
	ascending = less(ka, kb) or (ka == kb and ia < ib)
	descending = less(kb, ka) or (ka == kb and ib < ia)
	if (sort.desc) descending else ascending
}

## The model's stable sort: each row goes after every row not after it.
model_sort : List(GridData.Row), GridData.Sort -> List(GridData.Row)
model_sort = |rows, sort|
	rows.fold(
		[],
		|sorted, row| {
			place = match sorted.find_last_index(|r| !before(row, r, sort)) {
				Ok(at) => at + 1
				Err(_) => 0
			}
			sorted.take_first(place).append(row).concat(sorted.drop_first(place))
		},
	)

## Every property, or the first that fails.
check : Input -> Try({}, Str)
check = |{ rows: bytes, sort: s, query: q, picks }| {
	rows = bytes.map(row_of)
	sort = sort_of(s)
	sorted = GridData.sort_rows(rows, sort)
	want = model_sort(rows, sort)
	if sorted != want {
		return Err("sorted by ${GridData.sort_caption(sort)}: ${Str.inspect(sorted.map(|r| r.id))}, the model ${Str.inspect(want.map(|r| r.id))}")
	}
	last = GridData.last_page_of(sorted.len())
	pages = List.repeat(0, last + 1).map_with_index(|_, p| GridData.window_of(sorted, p))
	if pages.join() != sorted or pages.drop_last(1).any(|p| p.len() != GridData.page_size) or (sorted.len() > 0 and (pages.last() ?? []).is_empty()) {
		return Err("${sorted.len().to_str()} rows paged as ${Str.inspect(pages.map(|p| p.len()))}")
	}
	query = ["", "Node-000", "Atlas", "1", "Delta", "x"].get(q.to_u64() % 6) ?? ""
	var $selected = []
	var $model = Set.empty()
	for p in picks {
		id = p.to_u64() % GridData.row_count
		on = p % 2 == 0
		if p % 5 == 0 {
			$selected = GridData.set_all_matching($selected, query, on)
			matching = GridData.filter_rows(query).map(|r| r.id)
			$model = if (on) $model.union(Set.from_list(matching)) else $model.difference(Set.from_list(matching))
		} else {
			$selected = GridData.toggle_selected($selected, id, on)
			$model = if (on) $model.insert(id) else $model.remove(id)
		}
		if Set.from_list($selected).len() != $selected.len() or Set.from_list($selected) != $model {
			return Err("the selection is ${Str.inspect($selected)}, the model ${Str.inspect($model.to_list())}")
		}
	}
	summary = GridData.summarize(rows, $selected)
	scores = rows.map(|r| r.score)
	total = scores.sum()
	model = {
		matching: rows.len(),
		total,
		average: if (rows.is_empty()) 0 else total // rows.len(),
		highest: scores.max() ?? 0,
		lowest: scores.min() ?? 0,
		selected_here: rows.count_if(|r| $model.contains(r.id)),
		selected_all: $model.len(),
	}
	if summary != model {
		return Err("the summary ${Str.inspect(summary)}, the model ${Str.inspect(model)}")
	}
	Ok({})
}

test! : Input => Fuzz.Outcome
test! = |input| match check(input) {
	Ok({}) => Fuzz.keep
	Err(problem) => crash problem
}

ex : Str, Input -> Fuzz.Example(Input)
ex = |name, input| Fuzz.example({ name, revision: "1", make: || input })

target = Fuzz.target_with!({
	name: "data-grid",
	examples: [
		ex("ties-descending", { rows: [3, 26, 49, 3, 72, 95, 118, 0, 255], sort: 131, query: 2, picks: [2, 4, 5, 2, 10] }),
		ex("by-name", { rows: List.repeat(7, 30).map_with_index(|b, i| b.times_wrap(i.to_u8_wrap())), sort: 1, query: 1, picks: [0, 3, 15] }),
		ex("empty", { rows: [], sort: 2, query: 0, picks: [] }),
	],
	generator: { rows: Fuzz.list(Fuzz.u8, 60), sort: Fuzz.u8, query: Fuzz.u8, picks: Fuzz.list(Fuzz.u8, 20) }.Fuzz,
	test!,
	show: Str.inspect,
})
