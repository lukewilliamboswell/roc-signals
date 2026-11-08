## Document statistics derived straight from the raw source string. These are
## deliberately independent of the markdown parse: the statistics panel is its
## own branch of the graph, so it can update on every keystroke without the
## outline having to recompute.
Stats := {}.{
	Counts : { words : U64, characters : U64 }

	WordState : { words : U64, in_word : Bool, characters : U64 }

	empty : Stats.Counts
	empty = { words: 0, characters: 0 }

	## Words are runs of non-whitespace bytes. Characters are Unicode scalar
	## values, not bytes, so multi-byte punctuation counts once.
	counts : Str -> Stats.Counts
	counts = |source| {
		folded = source.to_utf8().fold({ words: 0, in_word: False, characters: 0 }, count_step)
		{ words: folded.words, characters: folded.characters }
	}

	count_step : Stats.WordState, U8 -> Stats.WordState
	count_step = |acc, byte| {
		characters = if byte < 128 or byte >= 192 {
			acc.characters + 1
		} else {
			acc.characters
		}
		if is_space(byte) {
			{ words: acc.words, in_word: False, characters }
		} else if acc.in_word {
			{ words: acc.words, in_word: True, characters }
		} else {
			{ words: acc.words + 1, in_word: True, characters }
		}
	}

	is_space : U8 -> Bool
	is_space = |byte| byte == 32 or byte == 9 or byte == 10 or byte == 13

	## Whole minutes, rounded up. An empty document reads in zero minutes.
	reading_minutes : U64, U64 -> U64
	reading_minutes = |words, words_per_minute| {
		wpm = if words_per_minute == 0 {
			200
		} else {
			words_per_minute
		}
		if words == 0 {
			0
		} else {
			(words + wpm - 1) // wpm
		}
	}

	parse_wpm : Str -> U64
	parse_wpm = |value|
		match value {
			"100" => 100
			"300" => 300
			_ => 200
		}
}

## An empty document has nothing to count.
expect Stats.counts("") == { words: 0, characters: 0 }

## Runs of whitespace, including newlines, separate words rather than making
## empty ones, and the character count includes that whitespace.
expect Stats.counts("one two  three\nfour") == { words: 4, characters: 19 }

## Counting is by character, not by byte: a multi-byte em dash counts once.
expect Stats.counts("a\u(2014)b") == { words: 1, characters: 3 }

## An empty document reads in no time at all.
expect Stats.reading_minutes(0, 200) == 0

## Any prose at all rounds up to a whole minute.
expect Stats.reading_minutes(1, 200) == 1

## An exact multiple of the speed does not round up to a spare minute.
expect Stats.reading_minutes(400, 200) == 2

## One word past the boundary claims the next whole minute.
expect Stats.reading_minutes(401, 200) == 3

## A zero speed would divide by zero, so the estimate falls back to the
## default speed instead of crashing.
expect Stats.reading_minutes(200, 0) == 1

## A speed the select offers is read back as that number.
expect Stats.parse_wpm("100") == 100

## Anything else falls back to the default speed.
expect Stats.parse_wpm("nonsense") == 200
