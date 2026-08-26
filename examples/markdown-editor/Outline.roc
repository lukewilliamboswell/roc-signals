## Table-of-contents derivation. `headings` reduces parsed markdown blocks to
## the heading spine; `rows` turns that spine into display rows. Splitting the
## two is what lets the outline stay quiet while the preview and the statistics
## keep updating: a paragraph edit changes the blocks but produces an identical
## heading list, so the equality cutoff stops propagation before `rows` runs.
import Markdown

Outline := {}.{
	Heading : { level : U64, text : Str, slug : Str }

	Row : {
		key : Str,
		slug : Str,
		href : Str,
		level : U64,
		level_text : Str,
		label : Str,
		indent : Str,
	}

	SlugState : { out : List(U8), pending_dash : Bool }

	CollectState : { headings : List(Outline.Heading), used : List(Str) }

	RowState : { out : List(Outline.Row), ordinal : U64 }

	## Heading spine of a parsed document, in document order, with a unique
	## anchor slug per heading. Duplicate titles get a "-2", "-3", ... suffix so
	## keyed rows keep a stable identity.
	headings : List(Markdown.Block) -> List(Outline.Heading)
	headings = |blocks|
		blocks.fold({ headings: [], used: [] }, collect_heading).headings

	collect_heading : Outline.CollectState, Markdown.Block -> Outline.CollectState
	collect_heading = |state, block|
		if block.kind == "heading" {
			text = Markdown.plain_text(block.text)
			base = slugify(text)
			seen = state.used.keep_if(|value| value == base).len()
			slug = if seen == 0 {
				base
			} else {
				"${base}-${(seen + 1).to_str()}"
			}
			{
				headings: state.headings.append({ level: block.level, text, slug }),
				used: state.used.append(base),
			}
		} else {
			state
		}

	## Lowercase ASCII slug: letters and digits survive, every other run of
	## bytes collapses to a single "-", and leading/trailing dashes never
	## appear. A heading made only of punctuation slugs to "section".
	slugify : Str -> Str
	slugify = |text| {
		folded = text.to_utf8().fold({ out: [], pending_dash: False }, slug_step)
		if folded.out.is_empty() {
			"section"
		} else {
			Str.from_utf8_lossy(folded.out)
		}
	}

	slug_step : Outline.SlugState, U8 -> Outline.SlugState
	slug_step = |acc, byte|
		if (byte >= 97 and byte <= 122) or (byte >= 48 and byte <= 57) {
			{ out: push_byte(acc, byte), pending_dash: False }
		} else if byte >= 65 and byte <= 90 {
			{ out: push_byte(acc, byte + 32), pending_dash: False }
		} else {
			{ ..acc, pending_dash: True }
		}

	push_byte : Outline.SlugState, U8 -> List(U8)
	push_byte = |acc, byte|
		if acc.pending_dash and !acc.out.is_empty() {
			acc.out.append(45).append(byte)
		} else {
			acc.out.append(byte)
		}

	## Display rows for the outline. `numbered` prefixes each row with its
	## document-order ordinal; indentation always reflects the heading level,
	## including levels that skip (a level 3 followed by a level 5).
	rows : List(Outline.Heading), Bool -> List(Outline.Row)
	rows = |items, numbered| {
		start : Outline.RowState
		start = { out: [], ordinal: 0 }
		items.fold(
			start,
			|acc, heading| {
				ordinal = acc.ordinal + 1
				label = if numbered {
					"${ordinal.to_str()}. ${heading.text}"
				} else {
					heading.text
				}
				{
					out: acc.out.append(
						{
							key: "toc:${heading.slug}",
							slug: heading.slug,
							href: "#${heading.slug}",
							level: heading.level,
							level_text: heading.level.to_str(),
							label,
							indent: indent_class(heading.level),
						},
					),
					ordinal,
				}
			},
		).out
	}

	indent_class : U64 -> Str
	indent_class = |level|
		match level {
			1 => "pl-0"
			2 => "pl-3"
			3 => "pl-6"
			4 => "pl-9"
			5 => "pl-12"
			_ => "pl-16"
		}
}
