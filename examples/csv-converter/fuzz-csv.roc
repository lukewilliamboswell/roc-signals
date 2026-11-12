app [target] {
	fz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.6.0/6uc3YKGydgEnS2nrCimSYWDNfT6drYcgU52VAwqrb6DS.tar.zst",
}

import fz.Fuzz
import Csv

## The converter's reading and writing, against what a CSV writer would
## produce. The task reads a file a chunk at a time, so the bugs to fear are
## a quote or a comma inside a field and a line split between two chunks.
##
## Each input decodes into a table of fields made of awkward pieces (commas,
## quotes, tabs, `\r`, multibyte text), a chunk size, and line breaks. Its
## properties:
##
## - a record written as CSV, every field quoted with its quotes doubled,
##   reads back as exactly its fields;
## - a field that needs no quoting reads back the same written bare;
## - the text's lines, read in chunks of any size with each chunk's rest
##   carried into the next, are the lines read all at once, and those are
##   the records written, without their breaks or a `\r` before them;
## - a record written as TSV is one line holding one tab fewer than it has
##   fields, and as a JSON line one object with a key for each name.
Input : { cells : List(U8), width : U8, chunk : U8, breaks : U8 }

## The pieces a field is made of; an input byte picks one.
pieces : List(Str)
pieces = ["a", "Ada", " ", "", ",", "\"", "\"\"", "\t", "\r", "é", "1.5", "x,y", "\\"]

## The table an input describes: its cells in rows of `width` fields.
table : { cells : List(U8), width : U8 } -> List(List(Str))
table = |{ cells, width }| {
	w = width.to_u64() % 5 + 1
	var $rows = []
	var $row = []
	for b in cells {
		# Two pieces to a field, so pieces meet inside one.
		$row = $row.append(pieces.get((b.to_u64() / 16) % pieces.len()) ?? "")
		if $row.len() == w {
			$rows = $rows.append($row)
			$row = []
		}
	}
	$rows.map(|row| row.map_with_index(|text, i| "${text}${pieces.get(i % pieces.len()) ?? ""}"))
}

## A field as a CSV writer quotes it.
quoted : Str -> Str
quoted = |field| "\"${field.replace_each("\"", "\"\"")}\""

## Whether a field reads back the same written bare: it holds no comma and
## no quote.
plain : Str -> Bool
plain = |field| !field.contains(",") and !field.contains("\"")

## A record's fields without the `\r` a CSV line cannot end in or hold
## (`lines` takes a line's last `\r` as part of its break).
csv_safe : List(Str) -> List(Str)
csv_safe = |row| row.map(|f| f.replace_each("\r", ""))

## The lines of `text` read in chunks of `size` bytes, each chunk's rest
## carried into the next, and the last rest as a final line when it is not
## empty.
chunked : List(U8), U64 -> List(Str)
chunked = |text, size| {
	var $out = []
	var $carry = []
	var $at = 0
	while $at < text.len() {
		{ complete, rest } = Csv.lines($carry.concat(text.sublist({ start: $at, len: size })))
		$out = $out.concat(complete.map(Str.from_utf8_lossy))
		$carry = rest
		$at = $at + size
	}
	if ($carry.is_empty()) $out else $out.append(Str.from_utf8_lossy($carry))
}

## Every property, or the first that fails.
check : Input -> Try({}, Str)
check = |input| {
	rows = table({ cells: input.cells, width: input.width }).map(csv_safe)
	for row in rows {
		line = Str.join_with(row.map(quoted), ",")
		read = Csv.fields(line)
		if read != row {
			return Err("${Str.inspect(line)} reads as ${Str.inspect(read)}, written from ${Str.inspect(row)}")
		}
		if row.all(plain) {
			bare = Str.join_with(row, ",")
			if Csv.fields(bare) != row {
				return Err("${Str.inspect(bare)} reads as ${Str.inspect(Csv.fields(bare))}")
			}
		}
		tsv = Csv.record(Tsv, row, row)
		tabs = tsv.to_utf8().count_if(|b| b == '\t')
		if !tsv.ends_with("\n") or tsv.drop_suffix("\n").contains("\n") or tabs != row.len() - 1 {
			return Err("the TSV record ${Str.inspect(tsv)} of ${Str.inspect(row)} is not one line of ${row.len().to_str()} fields")
		}
		json = Csv.record(JsonLines, row, row)
		if !json.starts_with("{") or !json.ends_with("}\n") or json.drop_suffix("\n").contains("\n") {
			return Err("the JSON line ${Str.inspect(json)} of ${Str.inspect(row)} is not one object on one line")
		}
	}
	lines = rows.map(|row| Str.join_with(row.map(quoted), ","))
	text = lines
		.map_with_index(|line, i| "${line}${if (input.breaks.shr_zf_wrap((i % 8).to_u8_wrap()).bitwise_and(1) == 1) "\r\n" else "\n"}")
		.join_map(|x| x.to_utf8())
	size = input.chunk.to_u64() + 1
	at_once = chunked(text, text.len() + 1)
	if at_once != lines {
		return Err("the text reads as the lines ${Str.inspect(at_once)}, written as ${Str.inspect(lines)}")
	}
	in_chunks = chunked(text, size)
	if in_chunks != at_once {
		return Err("in chunks of ${size.to_str()} bytes the text reads as ${Str.inspect(in_chunks)}, at once as ${Str.inspect(at_once)}")
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
	name: "csv-converter",
	examples: [
		ex("every-piece", { cells: List.repeat(0, 13).map_with_index(|_, i| (16 * i).to_u8_wrap()), width: 2, chunk: 0, breaks: 0b1010_0101 }),
		ex("crlf-split", { cells: [64, 80, 128, 144], width: 1, chunk: 6, breaks: 0xFF }),
		ex("one-field", { cells: [16], width: 0, chunk: 200, breaks: 0 }),
		ex("empty", { cells: [], width: 3, chunk: 9, breaks: 0 }),
	],
	generator: { cells: Fuzz.list(Fuzz.u8, 120), width: Fuzz.u8, chunk: Fuzz.u8, breaks: Fuzz.u8 }.Fuzz,
	test!,
	show: Str.inspect,
})
