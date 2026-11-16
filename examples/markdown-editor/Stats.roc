import pf.Engine exposing [Cell, Elem, Signal]
import pf.Html

## Document statistics, and the panel that shows them.
##
## The counts come straight from the source text, not from the markdown
## parse: the panel derives them itself from the document's cell, so it
## updates on every keystroke without the outline having to recompute. The
## reading speed is the panel's own state: only its estimate reads it, so
## it lives in the panel and needs no cell in the app's store.
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

	## A foreign selection leaves the reading speed unchanged.
	speed_picked : U64, [Chose(U64), NotOffered] -> U64
	speed_picked = |current, picked| match picked {
		Chose(speed) => speed
		NotOffered => current
	}

	## What the panel is drawn over, in a store whose type is `st`: the
	## document's source text, which it only reads.
	Props(st) : { source : Cell(st, Str) }

	## The panel over the document's cell. `heading_count` comes from the
	## page, which derives the heading spine once for the table of contents
	## and for this number.
	##
	## The counts are one `derive` of the source, read by every tile and by
	## the summary, and the reading estimate is a fan-in of the word count
	## and the speed: a change of speed re-evaluates the estimate and the
	## summary, and nothing outside the panel.
	view : Props(st), Signal(ctx, U64) -> Elem(ctx)
		where [ctx.store : () -> Engine.Reach(ctx, st)]
	view = |props, heading_count| Engine.derive(
		props.source.signal().map(Stats.counts),
		|tally| Engine.state(
			200.U64,
			|speed| {
				found = tally.lift()
				headed = heading_count.lift().lift()
				minutes = found.map2(speed.signal(), |c, wpm| Stats.reading_minutes(c.words, wpm))
				summary = { count: found, headings: headed, minutes }.Signal.map(|r| "${r.count.words.to_str()} words | ${r.count.characters.to_str()} characters | ${r.headings.to_str()} headings | ${r.minutes.to_str()} min")
				Engine.element(
					"section",
					[Engine.attr("aria-label", "Statistics"), Engine.attr("data-panel", "statistics"), Engine.class("panel")],
					[
						Html.div("panel-head", [Html.h2("Statistics", "panel-title"), Html.p_s(summary, [Engine.test_id("stat-summary"), Engine.class("hint numeric")])]),
						Html.div(
							"panel-body",
							[
								Html.div(
									"stat-grid",
									[
										tile({ caption: "Words", id: "stat-words", value: found.map(|c| c.words.to_str()) }),
										tile({ caption: "Characters", id: "stat-characters", value: found.map(|c| c.characters.to_str()) }),
										tile({ caption: "Headings", id: "stat-headings", value: headed.map(|n| n.to_str()) }),
										tile({ caption: "Reading time", id: "stat-reading", value: minutes.map(|m| "${m.to_str()} min") }),
									],
								),
								Html.div(
									"field sm:max-w-xs",
									[
										Html.p("Reading speed", "field-label"),
										Html.select(
											Engine.const("Reading speed"),
											speed.signal(),
											Engine.const([100, 200, 300]),
											{
												key: |wpm| wpm.to_str(),
												label: |wpm| match wpm {
													100 => "Careful (100 wpm)"
													300 => "Fast (300 wpm)"
													_ => "Average (200 wpm)"
												},
											},
											[Engine.class("input")],
											speed.set_value(Stats.speed_picked),
										),
										Html.p("The estimate is a fan-in of the word count and this speed; it never touches the preview or the outline.", "hint"),
									],
								),
							],
						),
					],
				)
			},
		),
	)
}

## One tile: a caption over a number.
tile : { caption : Str, id : Str, value : Signal(ctx, Str) } -> Elem(ctx)
tile = |{ caption, id, value }| Html.div("stat", [Html.p(caption, "stat-label"), Html.p_s(value, [Engine.test_id(id), Engine.class("stat-value numeric")])])

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

## A current choice changes the speed; a foreign choice preserves it.
expect Stats.speed_picked(200, Chose(100)) == 100
expect Stats.speed_picked(300, NotOffered) == 300
