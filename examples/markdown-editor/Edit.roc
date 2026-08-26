## Source-text editing commands for the toolbar. Each one is a pure
## `Str -> Str` transform used as a `state.on_unit` reducer, so the whole app
## still has exactly one piece of document state.
##
## A "section" is a heading line plus everything up to the next heading line.
## Anything before the first heading is the preamble.
import Markdown

Edit := {}.{
	Sections : List(List(Str))

	Doc : { preamble : List(Str), sections : Edit.Sections }

	SplitState : {
		preamble : List(Str),
		done : Edit.Sections,
		current : List(Str),
		started : Bool,
	}

	IndexState : { out : List(Str), index : U64 }

	SwapState : { out : Edit.Sections, index : U64 }

	split : Str -> Edit.Doc
	split = |source| {
		folded = source.split_on("\n").fold(
			{ preamble: [], done: [], current: [], started: False },
			split_step,
		)
		sections = if folded.started {
			folded.done.append(folded.current)
		} else {
			folded.done
		}
		{ preamble: folded.preamble, sections }
	}

	split_step : Edit.SplitState, Str -> Edit.SplitState
	split_step = |state, line|
		if Markdown.heading_level(line) > 0 {
			done = if state.started {
				state.done.append(state.current)
			} else {
				state.done
			}
			{ ..state, done, current: [line], started: True }
		} else if state.started {
			{ ..state, current: state.current.append(line) }
		} else {
			{ ..state, preamble: state.preamble.append(line) }
		}

	join : Edit.Doc -> Str
	join = |doc| {
		body = doc.sections.fold(doc.preamble, |acc, section| acc.concat(section))
		Str.join_with(body, "\n")
	}

	## The section at `wanted`, or an empty section when the index is past the
	## end. Callers have already checked the count, so out of range is not an
	## error worth propagating.
	at : Edit.Sections, U64 -> List(Str)
	at = |sections, wanted| Try.ok_or(sections.get(wanted), [])

	append_word : Str -> Str
	append_word = |source|
		if source.is_empty() {
			"extra"
		} else {
			"${source} extra"
		}

	append_section : Str -> Str
	append_section = |source|
		if source.is_empty() {
			"## New Section"
		} else {
			"${source}\n\n## New Section"
		}

	## Drop the final section, heading and body together.
	remove_last_section : Str -> Str
	remove_last_section = |source| {
		doc = split(source)
		count = doc.sections.len()
		if count == 0 {
			source
		} else {
			kept : Edit.SwapState
			kept = doc.sections.fold(
				{ out: [], index: 0 },
				|acc, section|
					if acc.index + 1 == count {
						{ out: acc.out, index: acc.index + 1 }
					} else {
						{ out: acc.out.append(section), index: acc.index + 1 }
					},
			)
			join({ ..doc, sections: kept.out })
		}
	}

	## Swap the last two sections. Row identity in the outline is the heading
	## slug, so this moves rows rather than remounting them.
	move_last_section_up : Str -> Str
	move_last_section_up = |source| {
		doc = split(source)
		count = doc.sections.len()
		if count < 2 {
			source
		} else {
			previous = at(doc.sections, count - 2)
			last = at(doc.sections, count - 1)
			swapped : Edit.SwapState
			swapped = doc.sections.fold(
				{ out: [], index: 0 },
				|acc, section| {
					next = if acc.index + 2 == count {
						last
					} else if acc.index + 1 == count {
						previous
					} else {
						section
					}
					{ out: acc.out.append(next), index: acc.index + 1 }
				},
			)
			join({ ..doc, sections: swapped.out })
		}
	}

	## Push the final heading one level deeper, up to level six. The heading
	## text is unchanged, so its outline row keeps its key and is patched in
	## place instead of being recreated.
	demote_last_heading : Str -> Str
	demote_last_heading = |source| {
		doc = split(source)
		count = doc.sections.len()
		if count == 0 {
			source
		} else {
			updated : Edit.SwapState
			updated = doc.sections.fold(
				{ out: [], index: 0 },
				|acc, section| {
					next = if acc.index + 1 == count {
						demote_first_line(section)
					} else {
						section
					}
					{ out: acc.out.append(next), index: acc.index + 1 }
				},
			)
			join({ ..doc, sections: updated.out })
		}
	}

	demote_first_line : List(Str) -> List(Str)
	demote_first_line = |lines| {
		start : Edit.IndexState
		start = { out: [], index: 0 }
		lines.fold(
			start,
			|acc, line| {
				next = if acc.index == 0 and Markdown.heading_level(line) < 6 {
					"#${line}"
				} else {
					line
				}
				{ out: acc.out.append(next), index: acc.index + 1 }
			},
		).out
	}
}

expect Edit.append_word("") == "extra"
expect Edit.append_word("hello") == "hello extra"
expect Edit.append_section("") == "## New Section"
expect Edit.demote_last_heading("# Alpha\n\n## Beta") == "# Alpha\n\n### Beta"
# Level six is the floor; a further demotion is a no-op.
expect Edit.demote_last_heading("###### Beta") == "###### Beta"
expect Edit.remove_last_section("# Alpha\n\nbody\n\n## Beta") == "# Alpha\n\nbody\n"
# Sections carry their own trailing blank line, so the swap moves it too.
expect Edit.move_last_section_up("# Alpha\n\n## Beta") == "## Beta\n# Alpha\n"
