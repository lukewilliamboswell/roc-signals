import Cells

## Clipboard text uses tabs between cells and line endings between rows.
## Fields may quote literal tabs and double a quote. Spreadsheet cells
## are single line, so an embedded line ending is refused.
RangeText := [].{

	Edit : { index : U64, source : Str }

	ExportProblem : [TooLarge, InvalidField]

	ImportProblem : [TooLarge, InvalidField, Ragged, OutsideSheet]

	## Bound the worksheet's work as well as the platform's paste transport.
	byte_limit = 65536.U64

	## Place a complete rectangle at its top-left cell.
	pasted : Str, U64 -> Try(List(Edit), ImportProblem)
	pasted = |text, first| {
		if text.count_utf8_bytes() > RangeText.byte_limit {
			return Err(TooLarge)
		}
		top = first // Cells.col_count
		left = first % Cells.col_count
		var $rest = text.to_utf8()
		var $width = 0.U64
		var $row = top
		var $col = left
		var $edits = []
		var $done = Bool.False
		while !$done {
			if $row >= Cells.row_count or $col >= Cells.col_count {
				return Err(OutsideSheet)
			}
			parsed = field($rest)?
			$edits = $edits.append({ index: $row * Cells.col_count + $col, source: parsed.text })
			match parsed.rest {
				['\t', .. as after] => {
					$col = $col + 1
					$rest = after
				}
				_ => {
					width = $col - left + 1
					if $row != top and width != $width {
						return Err(Ragged)
					}
					$width = width
					$row = $row + 1
					$col = left
					$rest = match parsed.rest {
						['\r', '\n', .. as after] | ['\n', .. as after] | ['\r', .. as after] => after
						[] => []
						_ => return Err(InvalidField)
					}
					$done = $rest.is_empty()
				}
			}
		}
		Ok($edits)
	}

	## Encode the supplied sources in sheet order, preserving blank cells.
	copied : List(Str), U64 -> Try(Str, ExportProblem)
	copied = |sources, width| {
		if sources.fold(0, |size, source| size + source.count_utf8_bytes()) > RangeText.byte_limit {
			return Err(TooLarge)
		}
		if sources.any(|source| source.contains("\n") or source.contains("\r")) {
			return Err(InvalidField)
		}
		text = Str.join_with(sources.map(encode_field).chunks_of(width).map(|row| Str.join_with(row, "\t")), "\n")
		if (text.count_utf8_bytes() <= RangeText.byte_limit) Ok(text) else Err(TooLarge)
	}
}

field : List(U8) -> Try({ text : Str, rest : List(U8) }, [InvalidField])
field = |bytes| {
	if bytes.first() == Ok('"') {
		var $rest = bytes.drop_first(1)
		var $value = []
		while !$rest.is_empty() {
			match $rest {
				['"', '"', .. as after] => {
					$value = $value.append('"')
					$rest = after
				}
				['"', .. as after] => {
					text = Str.from_utf8($value) ? |_| InvalidField
					return Ok({ text, rest: after })
				}
				['\r', ..] | ['\n', ..] => return Err(InvalidField)
				[one, .. as after] => {
					$value = $value.append(one)
					$rest = after
				}
				[] => crash "RangeText.field: a nonempty field had no leading byte"
			}
		}
		Err(InvalidField)
	} else {
		var $end = 0.U64
		while $end < bytes.len() and !['\t', '\n', '\r'].contains(bytes.get($end) ?? 0) {
			$end = $end + 1
		}
		text = Str.from_utf8(bytes.take_first($end)) ? |_| InvalidField
		Ok({ text, rest: bytes.drop_first($end) })
	}
}

encode_field : Str -> Str
encode_field = |source|
	if (source.is_empty() or source.contains("\t") or source.contains("\"")) "\"${source.replace_each("\"", "\"\"")}\"" else source

## Clipboard rows preserve Unicode, blanks, quotes and literal tabs.
expect {
	sources = ["é", "a\tb", "a\"b", ""]
	text = RangeText.copied(sources, 2)?
	edits = RangeText.pasted(text, 9)?
	edits == [{ index: 9, source: "é" }, { index: 10, source: "a\tb" }, { index: 17, source: "a\"b" }, { index: 18, source: "" }]
}

## CRLF and a final line ending produce the same rectangle as LF.
expect RangeText.pasted("1\t2\r\n3\t4\r\n", 0) == RangeText.pasted("1\t2\n3\t4", 0)

## Quoting mistakes, ragged rows and overflow have distinct refusals.
expect [
	RangeText.pasted("\"no closing quote", 0),
	RangeText.pasted("\"has\na newline\"", 0),
	RangeText.pasted("1\t2\n3", 0),
	RangeText.pasted("1\t2", 95),
	RangeText.pasted("1\n2", 95),
] == [Err(InvalidField), Err(InvalidField), Err(Ragged), Err(OutsideSheet), Err(OutsideSheet)]
