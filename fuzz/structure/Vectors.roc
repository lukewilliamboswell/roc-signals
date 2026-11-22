import "vectors.trace" as good_source : Str
import "vectors-bad.trace" as bad_source : Str
import Reference

## The structure vectors `oracle/turns` writes (`blueprint run oracle`),
## parsed, and replayed against the value model alone. `oracle/README.md`
## states the grammar. Lean decides what a turn means; these vectors are how
## the Roc value model (`Reference`) is held to it, and the target runs the
## same programs through the engine (`FuzzStructureProperty`, mode 6).
##
## The comparison is the value model's: the page's texts in document order,
## button labels included, and the number of buttons. A vector's evaluation
## counts are parsed and kept, but nothing here compares them: a known-bad
## trace that only a count rejects is accepted by the page, and is listed as
## such (`seen_by`).
Vectors := [].{

	## How a known-bad trace is rejected: by the page, by the evaluation count,
	## or by a click on a button the reference does not draw.
	Observation : [Page, Count, Button]

	## A trace's label: written by the reference, or observed by a known-bad
	## algorithm and rejected by the reference at a step (0 is the mount).
	Label : [Reference, KnownBad({ algorithm : Str, observation : Observation, step : U64 })]

	## One click: the button clicked (the k-th in document order), the page's
	## texts after it, and the evaluations the turn makes by the reference.
	Step : { button : U64, page : List(Str), evaluations : [Counted(U64), Uncounted] }

	## A trace: a generated tree, its page at mount and its clicks.
	Trace : { name : Str, label : Label, tree : List(Reference.Node), page : List(Str), steps : List(Step) }

	## What the value model says of a trace: every page agrees, or the first
	## step at which the page differs or the click names no button.
	Verdict : [Accepted, Rejected({ observation : [Page, Button], step : U64 })]

	## The traces of `fuzz/structure/vectors.trace`.
	good : List(Trace)
	good = parse(good_source)

	## The traces of `fuzz/structure/vectors-bad.trace`.
	bad : List(Trace)
	bad = parse(bad_source)

	## Replay a trace against the value model alone, with no engine.
	replay : Trace -> Verdict
	replay = |trace| {
		if !agrees(trace.tree, [], trace.page) {
			return Rejected({ observation: Page, step: 0 })
		}
		var $held = []
		var $n = 0.U64
		for step in trace.steps {
			$n = $n + 1
			if step.button >= Reference.buttons(Reference.page(trace.tree, $held)) {
				return Rejected({ observation: Button, step: $n })
			}
			$held = Reference.clicked(trace.tree, $held, step.button)
			if !agrees(trace.tree, $held, step.page) {
				return Rejected({ observation: Page, step: $n })
			}
		}
		Accepted
	}

	## The trace's clicks as the target's valued session reads its event
	## bytes: every second byte chooses the button.
	clicks : Trace -> List(U8)
	clicks = |trace| trace.steps.fold([], |out, step| out.append(0).append(step.button.to_u8_wrap()))

	## The known-bad algorithms of `vectors-bad.trace`, each with the
	## observations the value model rejects its traces by: `[Count]` when the
	## page agrees on every one of them, so only a count model sees it.
	seen_by : List(Trace) -> List({ algorithm : Str, observations : List(Observation) })
	seen_by = |traces| traces.fold(
		[],
		|acc, trace| match trace.label {
			Reference => acc
			KnownBad({ algorithm, .. }) => {
				seen = match replay(trace) {
					Rejected({ observation: Page, .. }) => Page
					Rejected({ observation: Button, .. }) => Button
					Accepted => Count
				}
				match acc.find_first_index(|entry| entry.algorithm == algorithm) {
					Ok(at) =>
						acc.update(
							at,
							|entry| if (entry.observations.contains(seen)) entry else { ..entry, observations: entry.observations.append(seen) },
						) ?? crash "Vectors.seen_by: an index find_first_index gave is out of bounds"
					Err(_) => acc.append({ algorithm, observations: [seen] })
				}
			}
		},
	)
}

## Whether the page drawn for `held` shows `texts` and as many buttons.
agrees : List(Reference.Node), Reference.Held, List(Str) -> Bool
agrees = |tree, held, texts| {
	drawn = Reference.page(tree, held)
	Reference.texts(drawn) == texts and Reference.buttons(drawn) == texts.keep_if(is_button).len()
}

## A button's label is one `+` per write its click makes.
is_button : Str -> Bool
is_button = |text| !text.is_empty() and text.to_utf8().all(|byte| byte == '+')

# ------------------------------------------------------------------ parsing

## The traces of a vector file. A line that does not fit the grammar
## crashes naming it: a vector the replay cannot read is never skipped.
parse : Str -> List(Trace)
parse = |source| {
	empty = { name: "", label: Reference, tree: [], page: [], steps: [] }
	var $out = []
	var $trace = empty
	var $line_number = 0.U64
	for line in source.split_on("\n") {
		$line_number = $line_number + 1
		at = "Vectors: line ${$line_number.to_str()}"
		words = line.split_on(" ").keep_if(|word| !word.is_empty())
		match words {
			[] => {}
			[first, ..] if first.starts_with("#") => {}
			["trace", .. as rest] => {
				$trace = { ..empty, name: Str.join_with(rest, " ") }
			}
			["variant", algorithm, observation, step] => {
				label = KnownBad({ algorithm, observation: observation_of(observation, at), step: number(step, at) })
				$trace = { ..$trace, label }
			}
			["prog", .. as rest] => {
				$trace = { ..$trace, tree: tree_of(Str.join_with(rest, " "), at) }
			}
			["page", .. as rest] => {
				$trace = { ..$trace, page: rest.map(text_of) }
			}
			["step", ..] => {
				$trace = { ..$trace, steps: $trace.steps.append(step_of(line, at)) }
			}
			["end"] => {
				$out = $out.append($trace)
				$trace = empty
			}
			_ => crash "${at} is not a vector line: ${line}"
		}
	}
	$out
}

observation_of : Str, Str -> Observation
observation_of = |word, at| match word {
	"page" => Page
	"count" => Count
	"button" => Button
	_ => crash "${at}: ${word} is not an observation"
}

number : Str, Str -> U64
number = |word, at| match U64.from_str(word) {
	Ok(value) => value
	Err(_) => crash "${at}: ${word} is not a number"
}

## A leaf as the page shows it: a `Pair`'s `x~d~y` is the text
## `pair x~d~y`; every other leaf is its own text.
text_of : Str -> Str
text_of = |leaf| if (leaf.contains("~")) "pair ${leaf}" else leaf

## `step <k> | <leaf> ... | <n>`, with `-` for no count recorded.
step_of : Str, Str -> Step
step_of = |line, at| match line.drop_prefix("step").split_on("|") {
	[button, page, count] => {
		evaluations = match count.trim() {
			"-" => Uncounted
			counted => Counted(number(counted, at))
		}
		{ button: number(button.trim(), at), page: page.split_on(" ").keep_if(|word| !word.is_empty()).map(text_of), evaluations }
	}
	_ => crash "${at}: a step has three parts: ${line}"
}

## A tree in the Roc tag names, as `prog` writes it.
tree_of : Str, Str -> List(Reference.Node)
tree_of = |text, at| {
	tokens = tokens_of(text)
	var $nodes = []
	var $pos = 0.U64
	while $pos < tokens.len() {
		(node, next) = node_at(tokens, $pos, at)
		$nodes = $nodes.append(node)
		$pos = next
	}
	$nodes
}

## Parentheses and words.
tokens_of : Str -> List(Str)
tokens_of = |text| {
	var $out = []
	var $word = []
	for byte in text.to_utf8() {
		if byte == '(' or byte == ')' or byte == ' ' {
			if !$word.is_empty() {
				$out = $out.append(Str.from_utf8($word) ?? crash "Vectors: a tree is not UTF-8")
				$word = []
			}
			if byte != ' ' {
				$out = $out.append(if (byte == '(') "(" else ")")
			}
		} else {
			$word = $word.append(byte)
		}
	}
	if ($word.is_empty()) $out else $out.append(Str.from_utf8($word) ?? crash "Vectors: a tree is not UTF-8")
}

token : List(Str), U64, Str -> Str
token = |tokens, pos, at| tokens.get(pos) ?? crash "${at}: a tree ends early"

expect_token : List(Str), U64, Str, Str -> U64
expect_token = |tokens, pos, want, at| {
	got = token(tokens, pos, at)
	if got != want {
		crash "${at}: expected ${want} at token ${pos.to_str()}, found ${got}"
	}
	pos + 1
}

number_at : List(Str), U64, Str -> (U64, U64)
number_at = |tokens, pos, at| (number(token(tokens, pos, at), at), pos + 1)

## `(One i)` or `(Two i j)`.
sel_at : List(Str), U64, Str -> (Reference.Sel, U64)
sel_at = |tokens, pos, at| {
	p1 = expect_token(tokens, pos, "(", at)
	match token(tokens, p1, at) {
		"One" => {
			(i, p2) = number_at(tokens, p1 + 1, at)
			(One(i), expect_token(tokens, p2, ")", at))
		}
		"Two" => {
			(i, p2) = number_at(tokens, p1 + 1, at)
			(j, p3) = number_at(tokens, p2, at)
			(Two(i, j), expect_token(tokens, p3, ")", at))
		}
		other => crash "${at}: ${other} is not a selector"
	}
}

## A `List(Node)`: its nodes in parentheses.
list_at : List(Str), U64, Str -> (List(Reference.Node), U64)
list_at = |tokens, pos, at| {
	var $pos = expect_token(tokens, pos, "(", at)
	var $nodes = []
	while token(tokens, $pos, at) != ")" {
		(node, next) = node_at(tokens, $pos, at)
		$nodes = $nodes.append(node)
		$pos = next
	}
	($nodes, $pos + 1)
}

node_at : List(Str), U64, Str -> (Reference.Node, U64)
node_at = |tokens, pos, at| {
	p1 = expect_token(tokens, pos, "(", at)
	tag = token(tokens, p1, at)
	p2 = p1 + 1
	(node, p_end) = match tag {
		"Show" | "Guard" | "Control" | "Bump" => {
			(i, p3) = number_at(tokens, p2, at)
			one = match tag {
				"Show" => Show(i)
				"Guard" => Guard(i)
				"Control" => Control(i)
				_ => Bump(i)
			}
			(one, p3)
		}
		"Bump2" | "Pair" | "Watch" => {
			(i, p3) = number_at(tokens, p2, at)
			(j, p4) = number_at(tokens, p3, at)
			two = match tag {
				"Bump2" => Bump2(i, j)
				"Pair" => Pair(i, j)
				_ => Watch(i, j)
			}
			(two, p4)
		}
		"When" => {
			(sel, p3) = sel_at(tokens, p2, at)
			(yes, p4) = list_at(tokens, p3, at)
			(no, p5) = list_at(tokens, p4, at)
			(When(sel, yes, no), p5)
		}
		"Switch" => {
			(sel, p3) = sel_at(tokens, p2, at)
			(a, p4) = list_at(tokens, p3, at)
			(b, p5) = list_at(tokens, p4, at)
			(c, p6) = list_at(tokens, p5, at)
			(Switch(sel, a, b, c), p6)
		}
		"Layer" => {
			(kind, p3) = number_at(tokens, p2, at)
			(i, p4) = number_at(tokens, p3, at)
			(body, p5) = list_at(tokens, p4, at)
			(Layer(kind, i, body), p5)
		}
		"Each" => {
			(sel, p3) = sel_at(tokens, p2, at)
			(body, p4) = list_at(tokens, p3, at)
			(Each(sel, body), p4)
		}
		_ => crash "${at}: ${tag} is not a node"
	}
	(node, expect_token(tokens, p_end, ")", at))
}

# -------------------------------------------------------------------- checks

## The traces whose verdict is not the one their label asks for, one line
## each naming the trace and the step: a trace of the reference must be
## accepted; a known-bad trace must be rejected by the observation and at
## the step its label names, or, for a count, accepted by the page.
misjudged : List(Vectors.Trace) -> List(Str)
misjudged = |traces| traces.fold(
	[],
	|out, trace| {
		verdict = Vectors.replay(trace)
		wanted = match trace.label {
			Reference => Accepted
			KnownBad({ observation: Count, .. }) => Accepted
			KnownBad({ observation: Page, step, .. }) => Rejected({ observation: Page, step })
			KnownBad({ observation: Button, step, .. }) => Rejected({ observation: Button, step })
		}
		if verdict == wanted {
			out
		} else {
			out.append("trace ${trace.name}: the value model says ${verdict_text(verdict)}, the vector ${verdict_text(wanted)}")
		}
	},
)

verdict_text : Vectors.Verdict -> Str
verdict_text = |verdict| match verdict {
	Accepted => "every page agrees"
	Rejected({ observation: Page, step }) => "the page differs at step ${step.to_str()}"
	Rejected({ observation: Button, step }) => "step ${step.to_str()} clicks a button not drawn"
}

## Crash naming every misjudged trace, so the failure says which and where.
held_to : List(Vectors.Trace), Str -> Bool
held_to = |traces, file| {
	wrong = misjudged(traces)
	if !wrong.is_empty() {
		crash "${file}:\n${Str.join_with(wrong, "\n")}"
	}
	!traces.is_empty()
}

## The value model draws every page of every reference vector: the Roc
## reference agrees with Lean on the trees the generator builds.
expect held_to(Vectors.good, "fuzz/structure/vectors.trace")

## The value model rejects every known-bad trace by the page at the step
## Lean names, and accepts by the page every trace only a count rejects.
expect held_to(Vectors.bad, "fuzz/structure/vectors-bad.trace")

## Which known-bad algorithm the value model sees, and by what. Those seen
## only by `Count` need a count model; the page comparison cannot see them.
## Removing an algorithm's traces, or every rejection the page makes of
## one, changes this report.
expect {
	actual = Str.join_with(Vectors.seen_by(Vectors.bad).map(|entry| "${entry.algorithm}: ${Str.inspect(entry.observations)}"), "\n")
	expected =
		\\twoPassInner: [Count, Page]
		\\twoPassOuter: [Count]
		\\noJoinKeep: [Count]
		\\noJoinClear: [Page]
		\\perWrite: [Page]
		\\rowReset: [Page]
		\\rowResurrect: [Page]
		\\noWalk: [Page]
		\\underSig: [Count, Page]
		\\pruneWakes: [Count]
	if actual != expected {
		crash "vectors-bad.trace: the value model sees the known-bad algorithms as\n${actual}"
	}
	True
}

## A tree's text splits into parentheses and words.
expect tokens_of("(When (Two 1 128) ((Layer 0 0 ())) ())") == ["(", "When", "(", "Two", "1", "128", ")", "(", "(", "Layer", "0", "0", "(", ")", ")", ")", "(", ")", ")"]

## A tree's text reads back as the nodes it names.
expect {
	want : List(Reference.Node)
	want = [Each(One(0), [Layer(0, 0, [])]), Pair(2, 1)]
	Str.inspect(tree_of("(Each (One 0) ((Layer 0 0 ()))) (Pair 2 1)", "test")) == Str.inspect(want)
}
