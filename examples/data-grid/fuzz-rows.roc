app [target] {
	fz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.6.1/GDoZFRDnzMRiVk9nE8wdWn52btGsM1GhcY9VDKqy9f1Y.tar.zst",
}

import fz.Fuzz
import GridData

## The grid's rules over its rows, against a model that sorts by insertion,
## totals by folding and pages by counting. The grid hands a view of its
## rows a filter, a place for each row and an order of places, and the view
## requires that order to be total; it draws the page the reader asked for
## as a window of that order; and it summarises the rows in whatever order
## the table gives them. So the bugs to fear are two rows that tie, an
## order that is not the column's, a page that skips or repeats a row, and
## a summary that depends on the order of the rows.
##
## Each input decodes into rows by id (names, teams and scores from small
## pools, so ties are common; a later row with an id replaces an earlier
## one), a sort, a filter and a series of selection changes. Its properties:
##
## - no two rows share a place, and a row's place compared the other way
##   round gives the opposite answer;
## - the rows the listing keeps, ordered by their places, are the model's
##   stable sort by the column, then the id, in the direction asked;
## - the windows of the pages, first to last, are those rows in order,
##   every page full but the last, which is not empty unless there are no
##   rows, and a page asked for past the end is shown as the last;
## - however rows are selected and cleared, one by one or every row the
##   filter matches, the selected rows are the model's set;
## - the summary's count, total, average, highest, lowest and selected
##   rows are the model's, whichever way round the rows are counted.
Input : { rows : List(U8), sort : U8, query : U8, picks : List(U8) }

Entry : { key : U64, row : GridData.Row }

## A row from one byte: its id, name, team and score from small pools.
entry_of : U8 -> Entry
entry_of = |b| {
	n = b.to_u64()
	{ key: n % 23, row: { name: "Node-${(n % 7).to_str()}", team: GridData.team_of(n % 5), score: (n * 37) % 11, note: "", selection: Unselected } }
}

## The rows the bytes name, by id: a later row replaces an earlier one
## with its id.
entries_of : List(U8) -> List(Entry)
entries_of = |bytes| bytes.fold([], |held, b| held.drop_if(|e| e.key == entry_of(b).key).append(entry_of(b)))

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
key_of : Entry, GridData.Sort -> (List(U8), U64)
key_of = |{ key: id, row }, sort| {
	column = match sort.key {
		ById => []
		ByName => row.name.to_utf8()
		ByTeam => row.team.to_str().to_utf8()
		ByScore => [(row.score // 256).to_u8_wrap(), row.score.to_u8_wrap()]
	}
	(column, id)
}

## Whether `a` comes strictly before `b` in the model's order.
before : Entry, Entry, GridData.Sort -> Bool
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
model_sort : List(Entry), GridData.Sort -> List(Entry)
model_sort = |entries, sort|
	entries.fold(
		[],
		|sorted, entry| {
			at = match sorted.find_last_index(|e| !before(entry, e, sort)) {
				Ok(index) => index + 1
				Err(_) => 0
			}
			sorted.take_first(at).append(entry).concat(sorted.drop_first(at))
		},
	)

## The opposite of an order's answer.
opposite : [Before, Same, After] -> [Before, Same, After]
opposite = |order| match order {
	Before => After
	Same => Same
	After => Before
}

## The ids of the selected rows.
selected_ids : List(Entry) -> List(U64)
selected_ids = |entries| entries.keep_if(|e| e.row.selection == Selected).map(|e| e.key)

## The pages of `listed`, each the window the grid would draw.
pages_of : List(U64) -> List(List(U64))
pages_of = |listed| {
	last = GridData.last_page_of(listed.len())
	List.repeat(0, last + 1).map_with_index(
		|_, page| {
			window = GridData.window_of(page)
			listed.drop_first(window.start).take_first(window.count)
		},
	)
}

## Every property, or the first that fails.
check : Input -> Try({}, Str)
check = |{ rows: bytes, sort: s, query: q, picks }| {
	entries = entries_of(bytes)
	sort = sort_of(s)
	filter = ["", "Node-", "Atlas", "1", "Delta", "x"].get(q.to_u64() % 6) ?? ""
	asked = GridData.plan({ filter, sort })
	places = entries.map(|e| (asked.sort)(e.key, e.row))
	for a in places {
		for b in places {
			order = (asked.compare)(a, b)
			if (order == Same) != (a.id == b.id) or (asked.compare)(b, a) != opposite(order) {
				return Err("sorted by ${GridData.sort_caption(sort)}, rows ${a.id.to_str()} and ${b.id.to_str()} compare ${Str.inspect(order)} and, the other way round, ${Str.inspect((asked.compare)(b, a))}")
			}
		}
	}
	kept = entries.keep_if(|e| (asked.keep)(e.key, e.row))
	listed = kept.map(|e| (asked.sort)(e.key, e.row)).sort_with(asked.compare).map(|at| at.id)
	matching = entries.keep_if(|e| filter.is_empty() or e.row.name.contains(filter) or e.row.team.to_str().contains(filter))
	want = model_sort(matching, sort).map(|e| e.key)
	if listed != want {
		return Err("filtered by ${Str.inspect(filter)} and sorted by ${GridData.sort_caption(sort)}: ${Str.inspect(listed)}, the model ${Str.inspect(want)}")
	}
	pages = pages_of(listed)
	sizes = pages.map_with_index(|_, page| GridData.rows_on(page, listed.len()))
	if pages.join() != listed or pages.map(|p| p.len()) != sizes or pages.drop_last(1).any(|p| p.len() != GridData.page_size) or (listed.len() > 0 and (pages.last() ?? []).is_empty()) {
		return Err("${listed.len().to_str()} rows paged as ${Str.inspect(pages.map(|p| p.len()))}, counted as ${Str.inspect(sizes)}")
	}
	far = pages.len() + q.to_u64()
	if GridData.page_shown(far, listed.len()) != pages.len() - 1 or GridData.page_shown(0, listed.len()) != 0 {
		return Err("page ${far.to_str()} of ${listed.len().to_str()} rows is shown as page ${GridData.page_shown(far, listed.len()).to_str()}")
	}
	var $entries = entries
	var $model = Set.empty()
	for p in picks {
		id = p.to_u64() % 23
		selection = if (p % 2 == 0) Selected else Unselected
		touched = if (p % 5 == 0) matching.map(|e| e.key) else if (entries.any(|e| e.key == id)) [id] else []
		$entries = $entries.map(|e| if ((p % 5 == 0 and GridData.matches(e.row, filter)) or (p % 5 != 0 and e.key == id)) { key: e.key, row: GridData.marked(e.row, selection) } else e)
		$model = if (selection == Selected) $model.union(Set.from_list(touched)) else $model.difference(Set.from_list(touched))
		if Set.from_list(selected_ids($entries)) != $model {
			return Err("the selection is ${Str.inspect(selected_ids($entries))}, the model ${Str.inspect($model.to_list())}")
		}
	}
	scores = matching.map(|e| e.row.score)
	total = scores.sum()
	model = {
		matching: matching.len(),
		total,
		highest: scores.max() ?? 0,
		lowest: scores.min() ?? 0,
		selected_here: matching.count_if(|e| $model.contains(e.key)),
		selected_all: $model.len(),
	}
	count = |listing| listing.fold(GridData.no_rows, |so_far, e| GridData.counted(so_far, e.row, filter))
	for summary in [count($entries), count($entries.rev())] {
		if summary != model or GridData.average(summary) != (if (matching.is_empty()) 0 else total // matching.len()) {
			return Err("the summary ${Str.inspect(summary)} averaging ${GridData.average(summary).to_str()}, the model ${Str.inspect(model)}")
		}
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
		ex("by-score-filtered", { rows: List.repeat(37, 60).map_with_index(|b, i| b.times_wrap(i.to_u8_wrap()).plus_wrap(11)), sort: 3, query: 3, picks: [5, 10, 1, 3, 7, 9, 12, 20] }),
		ex("by-team-descending-none-match", { rows: List.repeat(13, 40).map_with_index(|b, i| b.times_wrap(i.to_u8_wrap())), sort: 130, query: 5, picks: [0, 5, 11] }),
		ex("all-selected-then-cleared", { rows: List.repeat(3, 50).map_with_index(|b, i| b.times_wrap(i.to_u8_wrap())), sort: 0, query: 0, picks: [10, 4, 6, 15, 8] }),
		ex("empty", { rows: [], sort: 2, query: 0, picks: [] }),
	],
	generator: { rows: Fuzz.list(Fuzz.u8, 60), sort: Fuzz.u8, query: Fuzz.u8, picks: Fuzz.list(Fuzz.u8, 20) }.Fuzz,
	test!,
	show: Str.inspect,
})
