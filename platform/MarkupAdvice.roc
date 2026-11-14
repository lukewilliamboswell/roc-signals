import parser.Markup

## Human wording for parser-owned construction rules. Validation stays with
## the parser; the engine and a literal add their own site or source position.
MarkupAdvice := [].{

	## Describe the parser's exact-structure refusal without inventing element
	## provenance discarded by its public diagnostic. The caller adds the source site.
	repair : Markup.StructureReason -> Str
	repair = |reason| match reason {
		ImpliedElement(element) => "the HTML parser would insert <${bounded_label(element)}>; write that structure explicitly"
		MissingEndTag(element) => "close <${bounded_label(element)}> explicitly: construction keeps its written nesting"
		UnexpectedEndTag(element) => "the HTML parser would discard the closing tag </${bounded_label(element)}>"
		NonVoidSelfClosing(element) => "<${bounded_label(element)}> is not void; write its closing tag explicitly"
		ReparentedContent => "the HTML parser would move content away from its written parent"
		IgnoredMarkup => "the HTML parser would discard written markup"
		ReconstructedContent => "the HTML parser would reconstruct earlier formatting"
		ChangedAttributes => "the HTML parser would change written attributes"
	}

}

## A failed contract may name a long authored label; never split its scalar
## boundary or copy a view just to produce the bounded diagnostic suffix.
bounded_label : Str -> Str
bounded_label = |text| {
	var $bytes = text.to_utf8().take_first(64)
	while Bool.True {
		match Str.from_utf8($bytes) {
			Ok(value) => return value
			Err(_) => {
				$bytes = $bytes.drop_last(1)
			}
		}
	}
}

## Parser diagnostics retain their exact repair category in human wording.
expect MarkupAdvice.repair(MissingEndTag("p")) == "close <p> explicitly: construction keeps its written nesting"

## Abbreviating a multibyte label keeps whole scalars within the byte bound.
expect {
	bounded_label("${Str.repeat("a", 63)}λ") == Str.repeat("a", 63) and bounded_label(Str.repeat("λ", 40)).count_utf8_bytes() == 64 and
		bounded_label("").is_empty() and bounded_label("<svg>") == "<svg>"
}
