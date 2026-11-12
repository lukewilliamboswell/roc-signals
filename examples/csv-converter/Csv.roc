## The pure half of the converter: reading CSV records and writing them as
## TSV or JSON lines. The task streams a file through these a chunk at a
## time, so everything here works on one line or one chunk.
Csv := [].{

	## What a CSV file is converted to.
	Format : [Tsv, JsonLines]

	## The fields of one CSV line. A field may be quoted, and a quoted field
	## may hold commas and doubled quotes (`""`). A line break inside quotes
	## is not supported: each line is one record.
	fields : Str -> List(Str)
	fields = |line| {
		var $out = []
		var $field = []
		var $quoted = Bool.False
		var $after_quote = Bool.False
		for b in line.to_utf8() {
			if $quoted {
				if b == '"' {
					$quoted = Bool.False
					$after_quote = Bool.True
				} else {
					$field = $field.append(b)
				}
			} else if b == '"' {
				# A quote right after a closing quote is an escaped quote.
				if $after_quote {
					$field = $field.append('"')
				}
				$quoted = Bool.True
				$after_quote = Bool.False
			} else if b == ',' {
				$out = $out.append(Str.from_utf8_lossy($field))
				$field = []
				$after_quote = Bool.False
			} else {
				$field = $field.append(b)
				$after_quote = Bool.False
			}
		}
		$out.append(Str.from_utf8_lossy($field))
	}

	## One record as a line of the output format, newline included: TSV
	## (a tab or line break inside a field becomes a space), or a JSON
	## object keyed by the header's names.
	record : Format, List(Str), List(Str) -> Str
	record = |format, header, values| match format {
		Tsv => "${Str.join_with(values.map(|v| v.replace_each("\t", " ").replace_each("\r", " ")), "\t")}\n"
		JsonLines => {
			pairs = header.map_with_index(|name, i| "${Csv.json_text(name)}:${Csv.json_text(values.get(i) ?? "")}")
			"{${Str.join_with(pairs, ",")}}\n"
		}
	}

	## The header itself in the output format: a TSV header line, or nothing
	## for JSON lines, whose objects carry the names.
	header_line : Format, List(Str) -> Str
	header_line = |format, header| match format {
		Tsv => Csv.record(Tsv, header, header)
		JsonLines => ""
	}

	## A string as JSON text.
	json_text : Str -> Str
	json_text = |s| {
		escaped = s
			.replace_each("\\", "\\\\")
			.replace_each("\"", "\\\"")
			.replace_each("\n", "\\n")
			.replace_each("\r", "\\r")
			.replace_each("\t", "\\t")
		"\"${escaped}\""
	}

	## Split `bytes` into the complete lines it holds (without their line
	## breaks or a trailing `\r`) and the bytes after the last line break,
	## which the next chunk continues.
	lines : List(U8) -> { complete : List(List(U8)), rest : List(U8) }
	lines = |bytes| {
		var $complete = []
		var $start = 0
		var $i = 0
		for b in bytes {
			if b == '\n' {
				line = bytes.sublist({ start: $start, len: $i - $start })
				$complete = $complete.append(if (line.last() == Ok('\r')) line.drop_last(1) else line)
				$start = $i + 1
			}
			$i = $i + 1
		}
		{ complete: $complete, rest: bytes.drop_first($start) }
	}
}

## Quoted fields keep their commas and doubled quotes; unquoted ones are
## taken as they are.
expect Csv.fields("a,b,c") == ["a", "b", "c"]

## A quoted field keeps its commas and turns a doubled quote into one.
expect Csv.fields("\"x, y\",\"say \"\"hi\"\"\",z") == ["x, y", "say \"hi\"", "z"]

## Empty fields are fields.
expect Csv.fields(",,") == ["", "", ""]

## A TSV record turns a tab inside a field into a space.
expect Csv.record(Tsv, ["a", "b"], ["1", "x\ty"]) == "1\tx y\n"

## A JSON record is an object keyed by the header, its text escaped.
expect Csv.record(JsonLines, ["name", "note"], ["Ada", "said \"hi\""]) == "{\"name\":\"Ada\",\"note\":\"said \\\"hi\\\"\"}\n"

## A short record's missing fields are empty strings.
expect Csv.record(JsonLines, ["a", "b"], ["1"]) == "{\"a\":\"1\",\"b\":\"\"}\n"

## A chunk splits into its complete lines and the rest the next chunk
## continues; a line's `\r` goes with its break.
expect {
	{ complete, rest } = Csv.lines("a,b\r\n1,2\n3,".to_utf8())
	actual = "${Str.inspect(complete.map(Str.from_utf8_lossy))} ${Str.inspect(Str.from_utf8_lossy(rest))}"
	actual == "[\"a,b\", \"1,2\"] \"3,\""
}
