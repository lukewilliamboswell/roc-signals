import pf.Worker

## Text analysis, as worker tasks. This module only declares them; the app
## that uses them registers them and asks for jobs.
Words := [].{

	# region tasks
	## The words of a text that differ, and the one used most.
	Summary : { distinct : U64, top : Str }

	## How often a word is used.
	Frequency : { word : Str, count : U64 }

	## A task that cannot fail: its error is `Worker.Never`, and `run!` is a
	## plain calculation that always answers `Ok`.
	summary : Worker.Task(Str, Summary, Worker.Never)
	summary = Worker.task({ name: "example.org/words/summary", run!: |text| Ok(Words.summarise(text)) })

	## The numbers of the lines, from 1, that contain `word`.
	find : Worker.Task({ text : Str, word : Str }, List(U64), Worker.Never)
	find = Worker.task({
		name: "example.org/words/find",
		run!: |{ text, word }| Ok(Words.lines_with(text, word)),
	})
	# endregion tasks

	# region timeout
	## The three most used words. A job that has not answered five seconds
	## after it was asked for is stopped and answers `Timeout`.
	frequencies : Worker.Task(Str, List(Frequency), Worker.Never)
	frequencies = Worker.task({
		name: "example.org/words/frequencies",
		run!: |text| Ok(Words.most_used(text, 3)),
		timeout: Ms(5000),
	})
	# endregion timeout

	# region failing
	## The sum of the numbers in a text, or the first word that is not one:
	## a task's own error, which reaches the page as `Failed(NotANumber(word))`.
	total : Worker.Task(Str, U64, [NotANumber(Str)])
	total = Worker.task({ name: "example.org/words/total", run!: |text| Words.add_up(text) })

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
	# endregion failing

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
