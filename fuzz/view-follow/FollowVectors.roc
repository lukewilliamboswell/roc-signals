import "vectors.txt" as source : Str

## The view-follow vectors `oracle/tables` writes (`blueprint run oracle`),
## parsed. `oracle/README.md` states the grammar. Lean's transliteration of
## `TableCore.roc`, `View.roc` and the table view site's `Changed` wrote
## them; `FuzzViewFollowProperty` replays each against its model and
## against the real code. A line that does not fit the grammar crashes
## naming it, so a vector is never skipped.
##
## The row, operation and record grammar is the one
## `fuzz/table-changes/ChangeVectors.roc` reads; each target's package
## reads its own file.
FollowVectors := [].{

	## An operation on a table, as in `ChangeVectors.Op`.
	Op : [Insert(U64, U64), Put(U64, U64), Replace(U64, U64), Update(U64), Remove(U64), All, Undo]

	## A function handed to the cell's modifier, as in
	## `ChangeVectors.Modifier`.
	Modifier : [On(List(Op)), Saved(U64, List(Op)), Other(U64), Fresh(List((U64, U64)))]

	## What a table's changes say after a turn.
	Record : [Keyed(List({ key : U64, before : [Was(U64), Absent] })), Rewritten]

	## How the view followed its table, as `View.follow` answers.
	How : [Unchanged, Absorbed, Rebuilt([Many, Rewritten, Behind])]

	## A change of the rows drawn, as `View.draw` answers.
	Change : [Left(U64), Entered({ key : U64, before : [Row(U64), End] }), Moved({ key : U64, before : [Row(U64), End] }), Changed(U64)]

	Window : { start : U64, count : U64 }

	## What the site and the cell hold after a turn: how the view followed,
	## the table's rows, changes and counts, the view's ordered keys, the
	## keys drawn, and the changes of the rows drawn.
	Outcome : { how : How, rows : List((U64, U64)), record : Record, version : U64, start : U64, keys : List(U64), drawn : List(U64), changes : List(Change) }

	## One turn: its modifiers, the query and the window the pass brings if
	## it changes them, what it leaves, and whether a copy of the table is
	## kept for later `Saved` and `Other`.
	Turn : { modifiers : List(Modifier), query : Try(U64, [Same]), window : Try(Window, [Same]), outcome : Outcome, keep : Bool }

	## A history of one cell and one view of it: the rebuild thresholds,
	## the table's starting rows, the view's query and window, and its turns.
	Vector : { seed : U64, ratio : U64, floor : U64, rows : List((U64, U64)), query : U64, window : Window, turns : List(Turn) }

	## The vectors of `fuzz/view-follow/vectors.txt`.
	vectors : List(Vector)
	vectors = {
		empty = { seed: 0, ratio: 0, floor: 0, rows: [], query: 0, window: { start: 0, count: 0 }, turns: [] }
		var $out = []
		var $vector = empty
		var $pending = { modifiers: [], query: Err(Same), window: Err(Same) }
		var $line_number = 0.U64
		for line in source.split_on("\n") {
			$line_number = $line_number + 1
			at = "FollowVectors: line ${$line_number.to_str()}"
			match words_of(line) {
				[] => {}
				[first, ..] if first.starts_with("#") => {}
				["vector", seed] => {
					$vector = { ..empty, seed: number(seed, at) }
				}
				["covers", ..] => {}
				["cfg", ratio, floor] => {
					$vector = { ..$vector, ratio: number(ratio, at), floor: number(floor, at) }
				}
				["table", .. as rows] => {
					$vector = { ..$vector, rows: rows.map(|row| row_of(row, at)) }
				}
				["view", query, start, count] => {
					$vector = { ..$vector, query: number(query, at), window: { start: number(start, at), count: number(count, at) } }
				}
				["turn", ..] => {
					$pending = line.drop_prefix("turn ").split_on(" ; ").fold(
						{ modifiers: [], query: Err(Same), window: Err(Same) },
						|acc, part| match words_of(part) {
							["query", q] => { ..acc, query: Ok(number(q, at)) }
							["window", start, count] => { ..acc, window: Ok({ start: number(start, at), count: number(count, at) }) }
							_ => { ..acc, modifiers: acc.modifiers.append(modifier_of(part, at)) }
						},
					)
				}
				["->", ..] => {
					turn = { modifiers: $pending.modifiers, query: $pending.query, window: $pending.window, outcome: outcome_of(line.drop_prefix("  -> ").split_on(" | "), at), keep: Bool.False }
					$vector = { ..$vector, turns: $vector.turns.append(turn) }
				}
				["keep"] => {
					turns = match $vector.turns.last() {
						Ok(last) => $vector.turns.drop_last(1).append({ ..last, keep: Bool.True })
						Err(_) => crash "${at}: keep before any turn"
					}
					$vector = { ..$vector, turns }
				}
				["end"] => {
					$out = $out.append($vector)
					$vector = empty
				}
				_ => crash "${at} is not a vector line: ${line}"
			}
		}
		$out
	}
}

words_of : Str -> List(Str)
words_of = |text| text.split_on(" ").keep_if(|word| !word.is_empty())

number : Str, Str -> U64
number = |word, at| match U64.from_str(word) {
	Ok(value) => value
	Err(_) => crash "${at}: ${word} is not a number"
}

## `how <how> | rows ... | <record> | <version> <start> | keys ... |
## drawn ... | <change> ...`, split on ` | `.
outcome_of : List(Str), Str -> FollowVectors.Outcome
outcome_of = |parts, at| match parts {
	[how, rows, record, counts, keys, drawn, changes] => {
		(version, start) = match words_of(counts) {
			[v, s] => (number(v, at), number(s, at))
			_ => crash "${at}: a write count and a start: ${counts}"
		}
		{
			how: how_of(how, at),
			rows: words_of(rows.drop_prefix("rows")).map(|row| row_of(row, at)),
			record: record_of(record, at),
			version,
			start,
			keys: words_of(keys.drop_prefix("keys")).map(|key| number(key, at)),
			drawn: words_of(drawn.drop_prefix("drawn")).map(|key| number(key, at)),
			changes: words_of(changes).map(|change| change_of(change, at)),
		}
	}
	_ => crash "${at}: an outcome has seven parts"
}

how_of : Str, Str -> FollowVectors.How
how_of = |text, at| match words_of(text) {
	["how", "unchanged"] => Unchanged
	["how", "absorbed"] => Absorbed
	["how", "rebuilt-many"] => Rebuilt(Many)
	["how", "rebuilt-rewritten"] => Rebuilt(Rewritten)
	["how", "rebuilt-behind"] => Rebuilt(Behind)
	_ => crash "${at}: ${text} is not how a view follows"
}

## `left:k`, `entered:k@anchor`, `moved:k@anchor` or `changed:k`, where the
## anchor is the key the row goes before, or `end`.
change_of : Str, Str -> FollowVectors.Change
change_of = |text, at| {
	placed = |rest| match rest.split_on("@") {
		[key, "end"] => { key: number(key, at), before: End }
		[key, anchor] => { key: number(key, at), before: Row(number(anchor, at)) }
		_ => crash "${at}: ${text} names no place"
	}
	match text.split_on(":") {
		["left", key] => Left(number(key, at))
		["entered", rest] => Entered(placed(rest))
		["moved", rest] => Moved(placed(rest))
		["changed", key] => Changed(number(key, at))
		_ => crash "${at}: ${text} is not a change"
	}
}

## `rewritten`, or `keyed` and each `<key>=was:<row>` or `<key>=absent`.
record_of : Str, Str -> FollowVectors.Record
record_of = |text, at| match words_of(text) {
	["rewritten"] => Rewritten
	["keyed", .. as entries] =>
		Keyed(
			entries.map(
				|entry| match entry.split_on("=") {
					[key, "absent"] => { key: number(key, at), before: Absent }
					[key, was] if was.starts_with("was:") => { key: number(key, at), before: Was(number(was.drop_prefix("was:"), at)) }
					_ => crash "${at}: ${entry} is not a recorded key"
				},
			),
		)
	_ => crash "${at}: ${text} is not a record"
}

## `<key>:<row>`.
row_of : Str, Str -> (U64, U64)
row_of = |text, at| match text.split_on(":") {
	[key, row] => (number(key, at), number(row, at))
	_ => crash "${at}: ${text} is not a row"
}

## `on <op> ...`, `saved <i> <op> ...`, `other <i>` or `fresh <key>:<row> ...`.
modifier_of : Str, Str -> FollowVectors.Modifier
modifier_of = |text, at| match words_of(text) {
	["on", .. as ops] => On(ops.map(|op| op_of(op, at)))
	["saved", i, .. as ops] => Saved(number(i, at), ops.map(|op| op_of(op, at)))
	["other", i] => Other(number(i, at))
	["fresh", .. as rows] => Fresh(rows.map(|row| row_of(row, at)))
	_ => crash "${at}: ${text} is not a modifier"
}

## An operation: `insert(k,v)`, `put(k,v)`, `replace(k,v)`, `update(k)`,
## `remove(k)`, `update_all` or `undo`.
op_of : Str, Str -> FollowVectors.Op
op_of = |text, at| {
	args = |name| text.drop_prefix("${name}(").drop_suffix(")").split_on(",").map(|arg| number(arg, at))
	pair = |name| match args(name) {
		[k, v] => (k, v)
		_ => crash "${at}: ${text} takes a key and a row"
	}
	single = |name| match args(name) {
		[k] => k
		_ => crash "${at}: ${text} takes a key"
	}
	if text == "update_all" {
		All
	} else if text == "undo" {
		Undo
	} else if text.starts_with("insert(") {
		(k, v) = pair("insert")
		Insert(k, v)
	} else if text.starts_with("put(") {
		(k, v) = pair("put")
		Put(k, v)
	} else if text.starts_with("replace(") {
		(k, v) = pair("replace")
		Replace(k, v)
	} else if text.starts_with("update(") {
		Update(single("update"))
	} else if text.starts_with("remove(") {
		Remove(single("remove"))
	} else {
		crash "${at}: ${text} is not an operation"
	}
}

## The file holds vectors, and the parser reads an outcome with every kind
## of change.
expect {
	actual = Str.inspect({
		read: !FollowVectors.vectors.is_empty(),
		outcome: outcome_of("how rebuilt-rewritten | rows 0:2 | rewritten | 4 2 | keys 2 0 | drawn 2 | left:1 entered:2@end moved:0@2 changed:2".split_on(" | "), "test"),
	})
	expected = "{ outcome: { changes: [Left(1), Entered({ before: End, key: 2 }), Moved({ before: Row(2), key: 0 }), Changed(2)], drawn: [2], how: Rebuilt(Rewritten), keys: [2, 0], record: Rewritten, rows: [(0, 2)], start: 2, version: 4 }, read: True }"
	actual == expected
}
