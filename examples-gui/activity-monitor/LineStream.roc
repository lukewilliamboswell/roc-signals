## Incremental UTF-8 chunks become newline-delimited plain-text records.
## A partial final line remains explicit until its newline arrives. Overlong
## lines refuse the entire chunk so callers can retain their accepted cursor.
LineStream := [].{
	State : { partial : Str }
	Chunk : { state : State, lines : List(Str) }
	Error := [LineTooLong].{
		is_eq : _
	}

	max_line_bytes : U64
	max_line_bytes = 16384

	empty : State
	empty = { partial: "" }

	accept : State, Str -> Try(Chunk, Error)
	accept = |state, text| {
		segments = "${state.partial}${text}".split_on("\n")
		var $lines = []
		var $partial = ""
		zero : U64
		zero = 0
		var $index = zero
		for segment in segments {
			bytes = segment.to_utf8()
			terminal_cr = bytes.last() == Ok(13)
			if $index + 1 == segments.len() {
				# One extra terminal CR may still become part of a CRLF separator.
				if bytes.len() > max_line_bytes and !(terminal_cr and bytes.len() == max_line_bytes + 1) {
					return Err(LineTooLong)
				}
				$partial = segment
			} else {
				# CRLF is a line separator; other carriage returns remain text.
				content_bytes = if terminal_cr {
					bytes.len() - 1
				} else {
					bytes.len()
				}
				if content_bytes > max_line_bytes {
					return Err(LineTooLong)
				}
				line = if terminal_cr {
					Str.from_utf8(bytes.take_first(bytes.len() - 1)) ?? crash "Removing ASCII CR preserves UTF-8"
				} else {
					segment
				}
				$lines = $lines.append(line)
			}
			$index = $index + 1
		}
		Ok({ state: { partial: $partial }, lines: $lines })
	}
}

## Chunk boundaries do not split logical records or lose Unicode text.
expect {
	first = LineStream.accept(LineStream.empty, "first\ncafé")?
	second = LineStream.accept(first.state, " 🙂\nlast")?
	first.lines == ["first"] and second.lines == ["café 🙂"] and second.state.partial == "last"
}

## CRLF across chunks, blank records, and a final newline remain precise.
expect {
	first = LineStream.accept(LineStream.empty, "one\r")?
	second = LineStream.accept(first.state, "\n\n")?
	second.lines == ["one", ""] and second.state.partial == ""
}

## The line bound applies across reads and refuses the whole new chunk.
expect {
	prefix = Str.join_with(List.repeat("x", 16384), "")
	first = LineStream.accept(LineStream.empty, prefix)?
	LineStream.accept(first.state, "x\n") == Err(LineStream.Error.LineTooLong)
}

## LF and CRLF permit the same maximum logical line length, even across reads.
expect {
	line = Str.join_with(List.repeat("x", 16384), "")
	lf = LineStream.accept(LineStream.empty, "${line}\n")?
	crlf = LineStream.accept(LineStream.empty, "${line}\r\n")?
	partial = LineStream.accept(LineStream.empty, "${line}\r")?
	split = LineStream.accept(partial.state, "\n")?
	lf.lines == [line] and crlf.lines == lf.lines and split.lines == lf.lines
}

## A pending CR beyond the limit is refused if it turns out to be content.
expect {
	line = Str.join_with(List.repeat("x", 16384), "")
	partial = LineStream.accept(LineStream.empty, "${line}\r")?
	LineStream.accept(partial.state, "x\n") == Err(LineStream.Error.LineTooLong)
}
