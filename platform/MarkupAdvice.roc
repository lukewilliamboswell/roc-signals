import parser.Markup

## Human wording for parser-owned construction rules. Validation stays with
## the parser; the engine and a literal add their own site or source position.
MarkupAdvice := [].{

	## Describe one repair using supplied element/text labels. Each label is
	## bounded to 64 UTF-8 bytes here, without evaluating a view or keeping a
	## tree. The caller supplies classification and its construction/source site.
	repair : Markup.RepairRule, { parent : Str, child : Str } -> Str
	repair = |rule, labels| {
		parent = bounded_label(labels.parent)
		child = bounded_label(labels.child)
		match rule {
			CloseParagraph => "${child} inside ${parent}: the HTML parser would close the paragraph first"
			InsertTableSection => "${child} inside ${parent}: the HTML parser would insert a table section first"
			InvalidTableChild => "${child} inside ${parent}: the HTML parser would move it outside the table"
			TablePartOutsideTable => "${child} under ${parent}: a table part needs its table context"
			NestedAnchor => "${child} inside ${parent}: the HTML parser would close the earlier anchor first"
			NestedForm => "${child} inside ${parent}: the HTML parser would ignore the nested form"
			NestedButton => "${child} inside ${parent}: the HTML parser would close the earlier button first"
			CloseListItem => "${child} inside ${parent}: the HTML parser would close the earlier list item first"
			CloseDescriptionItem => "${child} inside ${parent}: the HTML parser would close the earlier description item first"
			CloseOption => "${child} inside ${parent}: the HTML parser would close the earlier option first"
			CloseHeading => "${child} inside ${parent}: the HTML parser would close the earlier heading first"
			ChildOfVoid => "${child} inside ${parent}: a void element cannot hold children"
			ElementInTextContent => "${child} inside ${parent}: the HTML parser reads this content as text"
			FosterTableText => "${child} inside ${parent}: the HTML parser would move the text outside the table"
		}
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

## Constructor and literal callers receive the same rule words.
expect {
	MarkupAdvice.repair(CloseParagraph, { parent: "<p>", child: "<div>" }) == "<div> inside <p>: the HTML parser would close the paragraph first" and
		MarkupAdvice.repair(FosterTableText, { parent: "<table>", child: "text" }) == "text inside <table>: the HTML parser would move the text outside the table"
}

## Abbreviating a multibyte label keeps whole scalars within the byte bound.
expect {
	bounded_label("${Str.repeat("a", 63)}λ") == Str.repeat("a", 63) and bounded_label(Str.repeat("λ", 40)).count_utf8_bytes() == 64 and
		bounded_label("").is_empty() and bounded_label("<svg>") == "<svg>"
}
