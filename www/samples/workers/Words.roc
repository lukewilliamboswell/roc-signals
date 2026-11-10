import pf.Worker

## Text analysis, as worker programs. This module only declares them; the app
## that uses them registers them and asks for runs.
Words := [].{

	# region programs
	## The words of a text that differ, and the one used most.
	Summary : { distinct : U64, top : Str }

	## How often a word is used.
	Frequency : { word : Str, count : U64 }

	summary : Worker.Program(Str, Summary)
	summary = Worker.program({ name: "example.org/words/summary", run: Words.summarise })

	## The numbers of the lines, from 1, that contain `word`.
	find : Worker.Program({ text : Str, word : Str }, List(U64))
	find = Worker.program({
		name: "example.org/words/find",
		run: |{ text, word }| Words.lines_with(text, word),
	})
	# endregion programs

	# region deadline
	## The three most used words. A job that has not answered five seconds
	## after it was asked for is stopped and answers `Timeout`.
	frequencies : Worker.Program(Str, List(Frequency))
	frequencies = Worker.program({
		name: "example.org/words/frequencies",
		run: |text| Words.most_used(text, 3),
		deadline: Ms(5000),
	})
	# endregion deadline

	# region fallible
	## The sum of the numbers in a text, or the first word that is not one.
	total : Worker.Program(Str, Try(U64, [NotANumber(Str)]))
	total = Worker.fallible({ name: "example.org/words/total", run: Words.add_up })

	add_up : Str -> Try(U64, [NotANumber(Str)])
	add_up = |text|
		Words.split(text).fold_try(
			0,
			|sum, word|
				match U64.from_str(word) {
					Ok(n) => Ok(sum + n)
					Err(_) => Err(NotANumber(word))
				},
		)
	# endregion fallible

	## The words of a text: the pieces between spaces and line breaks.
	split : Str -> List(Str)
	split = |text| text.split_on("\n").join_map(|line| line.split_on(" ")).keep_if(|word| !word.is_empty())

	## Each word once, in the order the text first uses it.
	distinct : List(Str) -> List(Str)
	distinct = |words| words.fold([], |seen, word| if (seen.contains(word)) seen else seen.append(word))

	## How often each distinct word is used, in the order the text first uses
	## it.
	counted : List(Str) -> List(Frequency)
	counted = |words| Words.distinct(words).map(|word| { word, count: words.count_if(|w| w == word) })

	summarise : Str -> Summary
	summarise = |text| {
		counts = Words.counted(Words.split(text))
		top = counts.fold({ word: "", count: 0 }, |best, f| if (f.count > best.count) f else best)
		{ distinct: counts.len(), top: top.word }
	}

	## The `n` most used words, most used first.
	most_used : Str, U64 -> List(Frequency)
	most_used = |text, n|
		Words.counted(Words.split(text))
			.sort_with(|a, b| if (a.count > b.count) Before else if (a.count < b.count) After else Same)
			.take_first(n)

	lines_with : Str, Str -> List(U64)
	lines_with = |text, word| {
		var $found = []
		var $number = 1
		for line in text.split_on("\n") {
			if Words.split(line).contains(word) {
				$found = $found.append($number)
			}
			$number = $number + 1
		}
		$found
	}
}

## A summary counts each word once and names the most used.
expect Words.summarise("the cat saw the hat") == { distinct: 4, top: "the" }

## A word that is not a number is the total's error.
expect Words.add_up("1 2 3") == Ok(6) and Words.add_up("1 two 3") == Err(NotANumber("two"))
