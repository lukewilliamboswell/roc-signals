import "corpus.tsv" as source : Str
import NameModel

## Input and expected grammar facts shared with the real browser contract.
## Names use UTF-8 hex so tabs, newlines and NUL remain ordinary corpus data.
NameCorpus := [].{
	Case : { name : Str, text : Str, expected : NameModel.Flags }

	cases : List(Case)
	cases = source.split_on("\n").keep_if(|line| !line.is_empty()).map(
		|line| {
			{ name, flags, hex } = match line.split_on("\t") {
				[case_name, expected_bits, encoded] => { name: case_name, flags: expected_bits, hex: encoded }
				_ => crash "NameCorpus: a row must have three tab-separated fields"
			}
			bits = flags.to_utf8()
			expected = match bits {
				[tag, attribute, method] => { tag: tag == '1', attribute: attribute == '1', method: method == '1' }
				_ => crash "NameCorpus: a row must have three expected flags"
			}
			if !bits.all(|byte| byte == '0' or byte == '1') or hex.count_utf8_bytes() % 2 != 0 {
				crash "NameCorpus: malformed flags or UTF-8 hex"
			}

			{ name, text: NameCorpus.decode_hex(hex), expected }
		},
	)

	## Decode test-owned UTF-8 hex without treating a BOM as a file signature.
	## Corpus parsing is strict so malformed facts cannot weaken an oracle.
	decode_hex : Str -> Str
	decode_hex = |hex| {
		if hex.count_utf8_bytes() % 2 != 0 {
			crash "NameCorpus: odd UTF-8 hex length"
		}
		var $bytes = []
		var $high = 0.U8
		var $second = False
		for byte in hex.to_utf8() {
			digit = if byte >= '0' and byte <= '9' {
				byte - '0'
			} else if byte >= 'a' and byte <= 'f' {
				byte - 'a' + 10
			} else {
				crash "NameCorpus: a hex digit is outside 0-9/a-f"
			}
			if $second {
				$bytes = $bytes.append($high * 16 + digit)
			} else {
				$high = digit
			}
			$second = !$second
		}
		Str.from_utf8($bytes) ?? crash "NameCorpus: invalid UTF-8"
	}

}
