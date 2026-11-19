## Internal text boundaries used by the scaffold and native spec report.
Text :: [].{

	## Split at an ASCII separator without retaining slices of the source.
	## Each part owns its UTF-8 buffer, including empty and final empty parts.
	## A non-ASCII separator is an internal contract error: splitting at a UTF-8
	## continuation byte could produce invalid text.
	## TODO https://github.com/roc-lang/roc/issues/13221: ordinary string
	## splitting corrupts retained lines in x64mac development builds. Remove
	## this owned-byte workaround once the compiler preserves those slices.
	split : Str, U8 -> List(Str)
	split = |source, separator| {
		if separator >= 128 {
			crash "Text.split: separator must be ASCII"
		}
		var $line = []
		var $lines = []
		for byte in source.to_utf8() {
			if byte == separator {
				$lines = $lines.append((Str.from_utf8($line) ?? crash "Text.split: splitting valid UTF-8 at an ASCII separator produced invalid UTF-8"))
				$line = []
			} else {
				$line = $line.append(byte)
			}
		}
		$lines.append((Str.from_utf8($line) ?? crash "Text.split: splitting valid UTF-8 at an ASCII separator produced invalid UTF-8"))
	}

	## Lines own their bytes and preserve the final empty line of a final newline.
	lines : Str -> List(Str)
	lines = |source| Text.split(source, '\n')
}

## Empty lines, a final newline, Unicode and long lines retain every byte.
expect {
	cases = ["", "\n", "\n\n", "last line", "last line\n", "import pf.Engine exposing [Elem, In, Root, State]\nñ = \"héllo\"\n"]
	cases.all(|source| Str.join_with(Text.lines(source), "\n") == source)
		and Text.lines("\none\n\ntwo\n") == ["", "one", "", "two", ""]
}

## Other ASCII boundaries preserve empty, long and Unicode components exactly.
expect {
	Text.split("/long-directory-abcdefghijklmnopqrstuvwxyz/λ//", '/') == ["", "long-directory-abcdefghijklmnopqrstuvwxyz", "λ", "", ""]
		and Text.split("GET /long-directory-abcdefghijklmnopqrstuvwxyz/file.txt HTTP/1.1", ' ') == ["GET", "/long-directory-abcdefghijklmnopqrstuvwxyz/file.txt", "HTTP/1.1"]
}
