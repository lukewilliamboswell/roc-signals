import parser.Markup
import parser.DomConstruction

## Human wording for parser-owned construction rules. Validation stays with
## the parser; the engine and a literal add their own site or source position.
MarkupAdvice := [].{

	## Describe the parser's exact-structure refusal without inventing element
	## provenance discarded by its public diagnostic. The caller adds the source site.
	repair : Markup.StructureReason -> Str
	repair = |reason| match reason {
		ImpliedElement(element) => "the HTML parser would insert <${bounded_label(element)}>; write that structure explicitly"
		MissingEndTag("p") => "the HTML parser would close the paragraph first; close <p> explicitly"
		MissingEndTag(element) => "close <${bounded_label(element)}> explicitly: construction keeps its written nesting"
		UnexpectedEndTag(element) => "the HTML parser would discard the closing tag </${bounded_label(element)}>"
		NonVoidSelfClosing(element) => "<${bounded_label(element)}> is not void; write its closing tag explicitly"
		ReparentedContent => "the HTML parser would move content away from its written parent"
		IgnoredMarkup => "the HTML parser would discard written markup"
		ReconstructedContent => "the HTML parser would reconstruct earlier formatting"
		ChangedAttributes => "the HTML parser would change written attributes"
	}

	## Keep the finite constructor's exact repair category and supplied labels.
	## This is independent of the literal/renderer StructureReason wording;
	## each caller adds its own construction site or authored source position.
	construction : DomConstruction.RepairRule, { parent : Str, child : Str } -> Str
	construction = |rule, labels| {
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

	## The name-only checker cannot choose the hidden-input table exception.
	## Do not describe missing evidence as proof of invalid HTML or repair.
	unsupported_table_input : { parent : Str, child : Str } -> Str
	unsupported_table_input = |labels| "${bounded_label(labels.child)} inside ${bounded_label(labels.parent)}: attribute-dependent table input is outside the name-only construction check"

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
expect MarkupAdvice.repair(MissingEndTag("p")) == "the HTML parser would close the paragraph first; close <p> explicitly"

## Abbreviating a multibyte label keeps whole scalars within the byte bound.
expect {
	bounded_label("${Str.repeat("a", 63)}λ") == Str.repeat("a", 63) and bounded_label(Str.repeat("λ", 40)).count_utf8_bytes() == 64 and
		bounded_label("").is_empty() and bounded_label("<svg>") == "<svg>"
}

## Constructor wording stays exact beside the separate full-parser wording.
expect {
	{
		paragraph: MarkupAdvice.construction(CloseParagraph, { parent: "<p>", child: "<div>" }),
		table_text: MarkupAdvice.construction(FosterTableText, { parent: "<table>", child: "text" }),
		unsupported: MarkupAdvice.unsupported_table_input({ parent: "<table>", child: "<input>" }),
	} == {
		paragraph: "<div> inside <p>: the HTML parser would close the paragraph first",
		table_text: "text inside <table>: the HTML parser would move the text outside the table",
		unsupported: "<input> inside <table>: attribute-dependent table input is outside the name-only construction check",
	}
}
