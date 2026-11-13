app [target] {
	fz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.6.1/GDoZFRDnzMRiVk9nE8wdWn52btGsM1GhcY9VDKqy9f1Y.tar.zst",
}

import fz.Fuzz
import Edit
import Markdown

## The editor's toolbar commands, which cut the document into sections (a
## heading line and everything up to the next) and put it back together.
## The bugs to fear are text lost or moved where it should not be when a
## document is cut and rejoined, and a command that touches more than its
## section.
##
## Each input decodes into a document of lines (headings of every level,
## indented headings, `#` without a space, text, blank lines, a code
## fence) and a command. Its properties:
##
## - cutting a document into sections and joining them gives it back;
## - moving the last section up twice gives the document back, and once
##   keeps every line, the preamble and every other section where it was;
## - removing the last section leaves exactly the lines before it;
## - demoting the last heading changes only that line, which becomes a
##   heading one level deeper (no deeper than six);
## - appending a word or a section keeps the document as its start.
Input : List(U8)

## The lines a document is made of; an input byte picks one.
lines : List(Str)
lines = ["# Alpha", "## Beta", "### Gamma", "###### Six", "  ## Indented", "#nospace", "text", "", "- item", "```", "# in a fence?", "####### Seven"]

## The document an input describes.
document : List(U8) -> Str
document = |picks| Str.join_with(picks.map(|b| lines.get(b.to_u64() % lines.len()) ?? ""), "\n")

## The model's sections: the lines before the first heading, then each
## heading line with the lines up to the next.
sections : Str -> { preamble : List(Str), sections : List(List(Str)) }
sections = |source| {
	var $preamble = []
	var $sections = []
	for line in source.split_on("\n") {
		if Markdown.heading_level(line) > 0 {
			$sections = $sections.append([line])
		} else if $sections.is_empty() {
			$preamble = $preamble.append(line)
		} else {
			$sections = $sections.update($sections.len() - 1, |s| s.append(line)) ?? $sections
		}
	}
	{ preamble: $preamble, sections: $sections }
}

## Every property, or the first that fails.
check : Input -> Try({}, Str)
check = |picks| {
	source = document(picks)
	doc = Edit.split(source)
	if Edit.join(doc) != source {
		return Err("${Str.inspect(source)} cut and joined is ${Str.inspect(Edit.join(doc))}")
	}
	model = sections(source)
	if doc != model {
		return Err("${Str.inspect(source)} cuts into ${Str.inspect(doc)}, the model ${Str.inspect(model)}")
	}
	count = model.sections.len()
	moved = Edit.move_last_section_up(source)
	if Edit.move_last_section_up(moved) != source {
		return Err("moving the last section of ${Str.inspect(source)} up twice gives ${Str.inspect(Edit.move_last_section_up(moved))}")
	}
	if count >= 2 {
		want = model.preamble.concat(model.sections.take_first(count - 2).join()).concat(model.sections.get(count - 1) ?? []).concat(model.sections.get(count - 2) ?? [])
		if moved != Str.join_with(want, "\n") {
			return Err("moving the last section of ${Str.inspect(source)} up gives ${Str.inspect(moved)}")
		}
	}
	removed = Edit.remove_last_section(source)
	if count > 0 and removed != Str.join_with(model.preamble.concat(model.sections.drop_last(1).join()), "\n") {
		return Err("removing the last section of ${Str.inspect(source)} gives ${Str.inspect(removed)}")
	}
	demoted = Edit.demote_last_heading(source)
	if count > 0 {
		before = source.split_on("\n")
		after = demoted.split_on("\n")
		at = model.preamble.len() + model.sections.drop_last(1).join().len()
		heading = before.get(at) ?? ""
		level = Markdown.heading_level(heading)
		want_level = if (level < 6) level + 1 else level
		changed = List.map2(before, after, |x, y| x != y).map_with_index(|differs, i| (differs, i)).keep_if(|(differs, _)| differs).map(|(_, i)| i)
		if after.len() != before.len() or changed.any(|i| i != at) or Markdown.heading_level(after.get(at) ?? "") != want_level {
			return Err("demoting the last heading ${Str.inspect(heading)} of ${Str.inspect(source)} gives ${Str.inspect(after.get(at) ?? "")}, at level ${Markdown.heading_level(after.get(at) ?? "").to_str()}")
		}
	}
	if !Edit.append_word(source).starts_with(source) or !Edit.append_section(source).starts_with(source) {
		return Err("appending to ${Str.inspect(source)} changed its start")
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
	name: "markdown-editor",
	examples: [
		# A preamble, then three sections with bodies and blank lines.
		ex("three-sections", [6, 7, 0, 6, 7, 1, 8, 7, 2, 6]),
		ex("level-six", [6, 3, 6]),
		ex("indented-heading", [0, 7, 4, 6]),
		ex("no-heading", [6, 7, 5, 11]),
		ex("empty", []),
	],
	generator: Fuzz.list(Fuzz.u8, 40),
	test!,
	show: Str.inspect,
})
