## Decode validated quoted Roc segments with original source positions.
## CSS escape decoding shares the scalar helpers but owns its own grammar.
SourceText := [].{

	## Decoded bytes retain the source offset that produced them, so an escape
	## never moves a diagnostic onto a different authored line.
	Point : { byte : U8, at : U64 }

	## Decode one CSS or Roc escape digit; absence terminates the CSS hex run.
	hex : U8 -> Try(U32, [NotHex])
	hex = |b| if (b >= '0' and b <= '9') Ok((b - '0').to_u32()) else if (b >= 'a' and b <= 'f') Ok((b - 'a' + 10).to_u32()) else if (b >= 'A' and b <= 'F') Ok((b - 'A' + 10).to_u32()) else Err(NotHex)

	## Encode an already validated Unicode scalar. CSS escape decoding replaces
	## invalid scalars before calling this; the Roc parser validates quoted escapes.
	utf8 : U32 -> List(U8)
	utf8 = |v| {
		if v < 128 {
			[v.to_u8_wrap()]
		} else if v < 2048 {
			[(192 + v / 64).to_u8_wrap(), (128 + v % 64).to_u8_wrap()]
		} else if v < 65536 {
			[(224 + v / 4096).to_u8_wrap(), (128 + v / 64 % 64).to_u8_wrap(), (128 + v % 64).to_u8_wrap()]
		} else {
			[(240 + v / 262144).to_u8_wrap(), (128 + v / 4096 % 64).to_u8_wrap(), (128 + v / 64 % 64).to_u8_wrap(), (128 + v % 64).to_u8_wrap()]
		}
	}

	## Decode escapes in a validated quoted string, retaining each decoded
	## byte’s original offset. Raw multiline segments bypass this conversion.
	quoted : List(U8), U64 -> List(Point)
	quoted = |bytes, start| {
		var $at = 0
		var $out = []
		while $at < bytes.len() {
			origin = start + $at
			b = bytes.get($at) ?? 0
			$at = $at + 1
			decoded = if b != '\\' {
				[b]
			} else {
				next = bytes.get($at) ?? 0
				$at = $at + 1
				if next == 'u' {
					$at = $at + 1
					var $value = 0.U32
					while $at < bytes.len() and bytes.get($at) != Ok(')') {
						$value = $value * 16 + (SourceText.hex(bytes.get($at) ?? 0) ?? 0)
						$at = $at + 1
					}
					$at = $at + 1
					SourceText.utf8($value)
				} else {
					[
						match next {
							'n' => 10
							'r' => 13
							't' => 9
							_ => next
						},
					]
				}
			}
			$out = $out.concat(decoded.map(|byte| { byte, at: origin }))
		}
		$out
	}

}
