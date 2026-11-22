import "vectors.txt" as source : Str

## The table-changes vectors `oracle/tables` writes (`blueprint run oracle`),
## parsed. `oracle/README.md` states the grammar. Lean's transliteration of
## `TableCore.roc` and the table cell's generated modifier wrote them;
## `FuzzTableChangesProperty` replays each against its model and against
## the real code. A line that does not fit the grammar crashes naming it, so
## a vector is never skipped.
ChangeVectors := [].{

	## An operation on a table: `update` and `update_all` add 1 to a row
	## modulo the target's row space; `Undo` applies the table's own
	## `inverse`.
	Op : [Insert(U64, U64), Put(U64, U64), Replace(U64, U64), Update(U64), Remove(U64), All, Undo]

	## A function handed to the cell's modifier: operations on the table it
	## is given; operations on the i-th kept copy instead; the i-th kept copy
	## under another cell's identity; or a new table of these rows.
	Modifier : [On(List(Op)), Saved(U64, List(Op)), Other(U64), Fresh(List((U64, U64)))]

	## What a table's changes say after a turn: each key the turn wrote and
	## its row when the turn began, or a whole rewrite.
	Record : [Keyed(List({ key : U64, before : [Was(U64), Absent] })), Rewritten]

	## A cell's table after a turn: its rows by key, its changes, its write
	## count and the count its changes began at.
	Outcome : { rows : List((U64, U64)), record : Record, version : U64, start : U64 }

	## One turn: its modifiers, in order, what the cell holds after it, and
	## whether a copy of that is kept for later `Saved` and `Other`.
	Turn : { modifiers : List(Modifier), outcome : Outcome, keep : Bool }

	## A history of one cell from its starting rows.
	Vector : { seed : U64, start : List((U64, U64)), turns : List(Turn) }

	## The vectors of `fuzz/table-changes/vectors.txt`.
	vectors : List(Vector)
	vectors = {
		empty = { seed: 0, start: [], turns: [] }
		var $out = []
		var $vector = empty
		var $pending = []
		var $line_number = 0.U64
		for line in source.split_on("\n") {
			$line_number = $line_number + 1
			at = "ChangeVectors: line ${$line_number.to_str()}"
			words = line.split_on(" ").keep_if(|word| !word.is_empty())
			match words {
				[] => {}
				[first, ..] if first.starts_with("#") => {}
				["vector", seed] => {
					$vector = { ..empty, seed: ChangeVectors.number(seed, at) }
				}
				["covers", ..] => {}
				["start", .. as rows] => {
					$vector = { ..$vector, start: rows.map(|row| ChangeVectors.row_of(row, at)) }
				}
				["turn", ..] => {
					$pending = line.drop_prefix("turn ").split_on(" ; ").map(|text| modifier_of(text, at))
				}
				["->", ..] => {
					turn = { modifiers: $pending, outcome: ChangeVectors.outcome_of(line.drop_prefix("  -> ").split_on(" | "), at), keep: Bool.False }
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

	## `rows ... | <record> | <version> <start>`, split on ` | `.
	outcome_of : List(Str), Str -> Outcome
	outcome_of = |parts, at| match parts {
		[rows, record, counts] => {
			(version, start) = match counts.split_on(" ") {
				[v, s] => (ChangeVectors.number(v, at), ChangeVectors.number(s, at))
				_ => crash "${at}: a write count and a start: ${counts}"
			}
			{ rows: words_of(rows.drop_prefix("rows")).map(|row| ChangeVectors.row_of(row, at)), record: ChangeVectors.record_of(record, at), version, start }
		}
		_ => crash "${at}: an outcome has three parts"
	}

	## `rewritten`, or `keyed` and each `<key>=was:<row>` or `<key>=absent`.
	record_of : Str, Str -> Record
	record_of = |text, at| match words_of(text) {
		["rewritten"] => Rewritten
		["keyed", .. as entries] =>
			Keyed(
				entries.map(
					|entry| match entry.split_on("=") {
						[key, "absent"] => { key: ChangeVectors.number(key, at), before: Absent }
						[key, was] if was.starts_with("was:") => { key: ChangeVectors.number(key, at), before: Was(ChangeVectors.number(was.drop_prefix("was:"), at)) }
						_ => crash "${at}: ${entry} is not a recorded key"
					},
				),
			)
		_ => crash "${at}: ${text} is not a record"
	}

	## `<key>:<row>`.
	row_of : Str, Str -> (U64, U64)
	row_of = |text, at| match text.split_on(":") {
		[key, row] => (ChangeVectors.number(key, at), ChangeVectors.number(row, at))
		_ => crash "${at}: ${text} is not a row"
	}

	## An operation: `insert(k,v)`, `put(k,v)`, `replace(k,v)`, `update(k)`,
	## `remove(k)`, `update_all` or `undo`.
	op_of : Str, Str -> Op
	op_of = |text, at| {
		args = |name| text.drop_prefix("${name}(").drop_suffix(")").split_on(",").map(|arg| ChangeVectors.number(arg, at))
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

	number : Str, Str -> U64
	number = |word, at| match U64.from_str(word) {
		Ok(value) => value
		Err(_) => crash "${at}: ${word} is not a number"
	}
}

words_of : Str -> List(Str)
words_of = |text| text.split_on(" ").keep_if(|word| !word.is_empty())

## `on <op> ...`, `saved <i> <op> ...`, `other <i>` or `fresh <key>:<row> ...`.
modifier_of : Str, Str -> ChangeVectors.Modifier
modifier_of = |text, at| match words_of(text) {
	["on", .. as ops] => On(ops.map(|op| ChangeVectors.op_of(op, at)))
	["saved", i, .. as ops] => Saved(ChangeVectors.number(i, at), ops.map(|op| ChangeVectors.op_of(op, at)))
	["other", i] => Other(ChangeVectors.number(i, at))
	["fresh", .. as rows] => Fresh(rows.map(|row| ChangeVectors.row_of(row, at)))
	_ => crash "${at}: ${text} is not a modifier"
}

## The file holds vectors, and the parser reads one of each kind of
## modifier and record.
expect {
	actual = Str.inspect({
		read: !ChangeVectors.vectors.is_empty(),
		modifiers: ["on put(1,2) update_all undo", "saved 1 remove(0)", "other 0", "fresh 0:1 2:0", "fresh "].map(|text| modifier_of(text, "test")),
		record: ChangeVectors.record_of("keyed 1=was:0 2=absent", "test"),
	})
	expected = "{ modifiers: [On([Put(1, 2), All, Undo]), Saved(1, [Remove(0)]), Other(0), Fresh([(0, 1), (2, 0)]), Fresh([])], read: True, record: Keyed([{ before: Was(0), key: 1 }, { before: Absent, key: 2 }]) }"
	actual == expected
}
