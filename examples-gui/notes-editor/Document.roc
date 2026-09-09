import unicode.ByteRange
import unicode.GeneralCategory
import unicode.Grapheme
import unicode.Scalar
import unicode.Word

## Pure document values and statistics, independent of the rendering surface.
Document := [].{
	Snapshot : { title : Str, body : Str }

	Counts : { words : U64, characters : U64 }

	blank : Snapshot
	blank = { title: "Untitled note", body: "" }

	## Compare the complete draft with its last accepted document snapshot.
	## Returning to the original text also clears the unsaved-change indicator.
	is_dirty : { draft : Snapshot, baseline : Snapshot } -> Bool
	is_dirty = |{ draft, baseline }| draft != baseline

	## Count extended grapheme clusters, including whitespace. A word is a
	## default Unicode word segment containing at least one letter or number.
	## Ranges and scalar iterators avoid materializing per-character lists.
	counts : Str -> Counts
	counts = |body| {
		var $characters = 0.U64
		for _ in Grapheme.iter_ranges(body) {
			$characters = $characters + 1
		}
		words = Word.fold_ranges(
			body,
			0.U64,
			|count, range| {
				segment = ByteRange.slice(range, body) ?? crash "Unicode word range must belong to its source"
				if contains_word_scalar(segment) {
					count + 1
				} else {
					count
				}
			},
		)
		{ words, characters: $characters }
	}

	contains_word_scalar : Str -> Bool
	contains_word_scalar = |segment| {
		for item in Scalar.iter(segment) {
			match GeneralCategory.of_scalar(item.scalar) {
				Lu | Ll | Lt | Lm | Lo | Nd | Nl | No => return True
				_ => {}
			}
		}
		False
	}

	## Keep the summary wording shared between the view and document tests.
	counts_text : Counts -> Str
	counts_text = |{ words, characters }| {
		word_label = if words == 1 {
			"word"
		} else {
			"words"
		}
		character_label = if characters == 1 {
			"character"
		} else {
			"characters"
		}
		"${words.to_str()} ${word_label} · ${characters.to_str()} ${character_label}"
	}
}

## Empty and whitespace-only documents do not contain words.
expect {
	actual =
		\\empty: ${Str.inspect(Document.counts(""))}
		\\spaces: ${Str.inspect(Document.counts(" \t\n\r "))}
	actual ==
		\\empty: { characters: 0, words: 0 }
		\\spaces: { characters: 5, words: 0 }
}

## Tabs, repeated spaces, and line breaks separate words; Unicode stays intact.
expect Document.counts("Hello  café\nworld\t🙂") == { words: 3, characters: 19 }

## Changing either title or body is observable, even when the other is unchanged.
expect {
	baseline = { title: "Ideas", body: "Keep this" }
	actual =
		\\same: ${Str.inspect(Document.is_dirty({ draft: baseline, baseline }))}
		\\title: ${Str.inspect(Document.is_dirty({ draft: { title: "Plans", body: "Keep this" }, baseline }))}
		\\body: ${Str.inspect(Document.is_dirty({ draft: { title: "Ideas", body: "Keep that" }, baseline }))}
	actual ==
		\\same: False
		\\title: True
		\\body: True
}

## Combining marks, flags, and joined emoji count as complete grapheme clusters.
expect Document.counts("é 🇦🇺 👨‍👩‍👧‍👦") == { words: 1, characters: 5 }

## Unicode whitespace and punctuation separate words without becoming words.
expect Document.counts("café 世界—42!") == { words: 4, characters: 11 }

## Apostrophes within words stay together; emoji and punctuation alone are not words.
expect Document.counts("can't... 🙂 !!!").words == 1

## CRLF is one grapheme cluster, and scalar spelling never normalizes the document.
expect Document.counts("é\r\né") == { words: 2, characters: 3 }
