## Bytes in text places, using the standard padded RFC 4648 alphabet.
##
## Use this pure codec for a binary envelope kept in browser storage or sent
## through a text format. It provides no encryption or authentication. Both
## operations take linear time and allocate output proportional to the input.
Base64 := [].{

	## Encode arbitrary bytes as canonical base64, with `=` padding and no lines.
	encode : List(U8) -> Str
	encode = |bytes| {
		var $remaining = bytes
		var $out = []
		while !$remaining.is_empty() {
			match $remaining {
				[first, second, third, .. as rest] => {
					$out = $out.append(symbol(first // 4)).append(symbol((first % 4) * 16 + second // 16)).append(symbol((second % 16) * 4 + third // 64)).append(symbol(third % 64))
					$remaining = rest
				}
				[first, second] => {
					$out = $out.append(symbol(first // 4)).append(symbol((first % 4) * 16 + second // 16)).append(symbol((second % 16) * 4)).append('=')
					$remaining = []
				}
				[first] => {
					$out = $out.append(symbol(first // 4)).append(symbol((first % 4) * 16)).append('=').append('=')
					$remaining = []
				}
				[] => {}
			}
		}
		Str.from_utf8($out) ?? crash "Base64.encode: alphabet must be ASCII"
	}

	## Decode canonical padded base64, or answer `NotBase64` without repairing it.
	##
	## Empty text is empty bytes. Whitespace, the URL alphabet, missing or extra
	## padding, padding before the end and nonzero unused bits are rejected.
	decode : Str -> Try(List(U8), [NotBase64])
	decode = |text| {
		if text.is_empty() {
			return Ok([])
		}
		if text.count_utf8_bytes() % 4 != 0 {
			return Err(NotBase64)
		}
		var $remaining = text.to_utf8()
		var $out = []
		while !$remaining.is_empty() {
			match $remaining {
				[first, second, '=', '='] => {
					a = sextet(first)?
					b = sextet(second)?
					if b % 16 != 0 {
						return Err(NotBase64)
					}
					return Ok($out.append(a * 4 + b // 16))
				}
				[first, second, third, '='] => {
					a = sextet(first)?
					b = sextet(second)?
					c = sextet(third)?
					if c % 4 != 0 {
						return Err(NotBase64)
					}
					return Ok($out.append(a * 4 + b // 16).append((b % 16) * 16 + c // 4))
				}
				[first, second, third, fourth, .. as rest] => {
					a = sextet(first)?
					b = sextet(second)?
					c = sextet(third)?
					d = sextet(fourth)?
					$out = $out.append(a * 4 + b // 16).append((b % 16) * 16 + c // 4).append((c % 4) * 64 + d)
					$remaining = rest
				}
				_ => return Err(NotBase64)
			}
		}
		Ok($out)
	}

}

symbol : U8 -> U8
symbol = |value| if value < 26 {
	'A' + value
} else if value < 52 {
	'a' + (value - 26)
} else if value < 62 {
	'0' + (value - 52)
} else if value == 62 {
	'+'
} else {
	'/'
}

sextet : U8 -> Try(U8, [NotBase64])
sextet = |byte| if byte >= 'A' and byte <= 'Z' {
	Ok(byte - 'A')
} else if byte >= 'a' and byte <= 'z' {
	Ok(byte - 'a' + 26)
} else if byte >= '0' and byte <= '9' {
	Ok(byte - '0' + 52)
} else if byte == '+' {
	Ok(62)
} else if byte == '/' {
	Ok(63)
} else {
	Err(NotBase64)
}

## RFC 4648 section 10 vectors cover every padding position and the empty input.
expect ["", "f", "fo", "foo", "foob", "fooba", "foobar"].map(|text| Base64.encode(text.to_utf8())) == ["", "Zg==", "Zm8=", "Zm9v", "Zm9vYg==", "Zm9vYmE=", "Zm9vYmFy"]

## The decoder recovers every RFC 4648 vector, including the empty byte list.
expect {
	var $decoded = []
	for encoded in ["", "Zg==", "Zm8=", "Zm9v", "Zm9vYg==", "Zm9vYmE=", "Zm9vYmFy"] {
		$decoded = $decoded.append(Base64.decode(encoded)?)
	}
	$decoded == ["", "f", "fo", "foo", "foob", "fooba", "foobar"].map(Str.to_utf8)
}

## The standard alphabet preserves all byte values rather than treating them as text.
expect {
	bytes = [0, 1, 127, 128, 254, 255]
	encoded = Base64.encode(bytes)
	decoded = Base64.decode(encoded)?
	{ encoded, decoded } == { encoded: "AAF/gP7/", decoded: bytes }
}

## Whitespace, URL symbols, malformed padding and noncanonical trailing bits fail.
expect ["=", "====", "Zg", "Zg=", "Zg===", "Zg==\n", " Zg==", "Zg==Zg==", "Z=g=", "=g==", "Zm=8", "Zh==", "Zm9=", "_w==", "-w==", "é==", "Zm9v\u(0000)"].map(Base64.decode) == List.repeat(Err(NotBase64), 17)
