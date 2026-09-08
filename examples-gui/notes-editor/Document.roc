## Pure document values and statistics, independent of the rendering surface.
Document := [].{
	Snapshot : { title : Str, body : Str }

	Counts : { words : U64, characters : U64 }

	CountState : { words : U64, characters : U64, in_word : Bool }

	blank : Snapshot
	blank = { title: "Untitled note", body: "" }

	## Compare the complete draft with its last accepted document snapshot.
	## Returning to the original text also clears the unsaved-change indicator.
	is_dirty : { draft : Snapshot, baseline : Snapshot } -> Bool
	is_dirty = |{ draft, baseline }| draft != baseline

	## Count Unicode scalar values and runs separated by ASCII whitespace.
	## This includes line breaks and tabs without treating UTF-8 bytes as letters.
	counts : Str -> Counts
	counts = |body| {
		result = body.to_utf8().fold({ words: 0, characters: 0, in_word: False }, count_byte)
		{ words: result.words, characters: result.characters }
	}

	count_byte : CountState, U8 -> CountState
	count_byte = |state, byte| {
		characters = if byte < 128 or byte >= 192 {
			state.characters + 1
		} else {
			state.characters
		}
		space = byte == 32 or (byte >= 9 and byte <= 13)
		{
			words: if !space and !state.in_word {
				state.words + 1
			} else {
				state.words
			},
			characters,
			in_word: !space,
		}
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
expect Document.counts("Hello  café\nworld\t🙂") == { words: 4, characters: 19 }

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
