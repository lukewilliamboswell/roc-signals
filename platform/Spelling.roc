import parser.Html as MarkupHtml

## Deterministic authoring suggestions over a caller's canonical vocabulary.
## The vocabulary and acceptance rules stay with the type that asks for advice.
Spelling := [].{

	## Suggest at most two edits away, preferring the same initial letter and
	## then lexical spelling. An empty answer means no sufficiently close name.
	suggest : Str, List(Str) -> Str
	suggest = format_suggestion

	## Compare folded UTF-8 spellings with insertion, deletion, substitution
	## and adjacent-transposition edits. Values above two need not be exact.
	distance : List(U8), List(U8) -> U64
	distance = edit_distance
}

## Equal edit distances among the caller's canonical names prefer the
## same initial letter, then lexical order, independent of catalogue ordering.
format_suggestion : Str, List(Str) -> Str
format_suggestion = |text, names| {
	folded = MarkupHtml.ascii_lower(text)
	first = folded.to_utf8().first()
	best = names.fold(
		{ distance: 3.U64, initial: False, name: "" },
		|kept, name| {
			candidate = MarkupHtml.ascii_lower(name)
			distance = edit_distance(folded.to_utf8(), candidate.to_utf8())
			initial = candidate.to_utf8().first() == first
			prefer = distance < kept.distance or (distance == kept.distance and (initial and !kept.initial or (initial == kept.initial and lexical_before(name, kept.name))))
			if distance <= 2 and prefer {
				{ distance, initial, name }
			} else kept
		},
	)
	if best.distance <= 2 {
		" did you mean ${Str.inspect(best.name)}?"
	} else ""
}

## An optimal-string-alignment distance over folded UTF-8: an
## adjacent transposition counts as one edit, as do insertion, deletion and
## substitution. The length bound skips names outside the two-edit limit.
edit_distance : List(U8), List(U8) -> U64
edit_distance = |left, right| {
	if left.len() > right.len() {
		if left.len() - right.len() > 2 {
			return 3
		}
	} else if right.len() - left.len() > 2 {
		return 3
	}
	var $previous = [0.U64]
	var $initial_column = 0.U64
	for _ in right {
		$initial_column = $initial_column + 1
		$previous = $previous.append($initial_column)
	}
	var $before_previous = [0.U64]
	var $row = 0.U64
	for a in left {
		$row = $row + 1
		var $current = [$row]
		var $column = 0.U64
		for b in right {
			$column = $column + 1
			above = $previous.get($column) ?? crash "Spelling.distance: previous row has every column"
			beside = $current.get($column - 1) ?? crash "Spelling.distance: current row has preceding column"
			diagonal = $previous.get($column - 1) ?? crash "Spelling.distance: previous row has preceding column"
			replace = diagonal + (if (a == b) 0 else 1)
			var $distance = minimum(replace, minimum(above + 1, beside + 1))
			if $row > 1 and $column > 1 {
				prior_a = left.get($row - 2) ?? crash "Spelling.distance: prior left byte is in range"
				prior_b = right.get($column - 2) ?? crash "Spelling.distance: prior right byte is in range"
				if a == prior_b and b == prior_a {
					before = $before_previous.get($column - 2) ?? crash "Spelling.distance: prior diagonal is in range"
					$distance = minimum($distance, before + 1)
				}
			}
			$current = $current.append($distance)
		}
		$before_previous = $previous
		$previous = $current
	}
	$previous.last() ?? crash "Spelling.distance: even an empty name has column zero"
}

minimum : U64, U64 -> U64
minimum = |left, right| if (left < right) left else right

lexical_before : Str, Str -> Bool
lexical_before = |left, right| {
	a = left.to_utf8()
	b = right.to_utf8()
	var $index = 0.U64
	for byte in a {
		other = b.get($index) ?? return False
		if byte != other {
			return byte < other
		}
		$index = $index + 1
	}
	a.len() < b.len()
}
