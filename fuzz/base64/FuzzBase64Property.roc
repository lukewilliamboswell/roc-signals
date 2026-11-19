import fz.Fuzz
import pf.Base64

alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".to_utf8()

## Independent streaming bit accumulator: the platform codec works in groups
## of three bytes and four symbols. The alphabet alone comes from RFC 4648.
encode_model : List(U8) -> Str
encode_model = |bytes| {
	var $bits = 0.U32
	var $width = 0.U32
	var $out = []
	for byte in bytes {
		$bits = $bits * 256 + byte.to_u32()
		$width = $width + 8
		while $width >= 6 {
			$width = $width - 6
			divisor = power_of_two($width)
			$out = $out.append(alphabet.get(($bits // divisor).to_u64()) ?? crash "base64 model: sextet outside alphabet")
			$bits = $bits % divisor
		}
	}
	if $width > 0 {
		$out = $out.append(alphabet.get(($bits * power_of_two(6 - $width)).to_u64()) ?? crash "base64 model: final sextet outside alphabet")
	}
	while $out.len() % 4 != 0 {
		$out = $out.append('=')
	}
	Str.from_utf8($out) ?? crash "base64 model: alphabet must be ASCII"
}

power_of_two : U32 -> U32
power_of_two = |exponent| if (exponent == 0) 1 else 2 * power_of_two(exponent - 1)

## Read symbols one at a time, accumulating bits until an octet is available.
## Padding count and zero trailing bits are checked after the entire input.
decode_model : Str -> Try(List(U8), [NotBase64])
decode_model = |text| {
	if text.count_utf8_bytes() % 4 != 0 {
		return Err(NotBase64)
	}
	var $padding = 0.U64
	var $symbols = 0.U64
	var $bits = 0.U32
	var $width = 0.U32
	var $out = []
	for byte in text.to_utf8() {
		if byte == '=' {
			$padding = $padding + 1
		} else {
			if $padding != 0 {
				return Err(NotBase64)
			}
			sextet = alphabet.find_first_index(|candidate| candidate == byte) ? |_| NotBase64
			$symbols = $symbols + 1
			$bits = $bits * 64 + sextet.to_u32_wrap()
			$width = $width + 6
			if $width >= 8 {
				$width = $width - 8
				divisor = power_of_two($width)
				$out = $out.append(($bits // divisor).to_u8_wrap())
				$bits = $bits % divisor
			}
		}
	}
	needed = match $symbols % 4 {
		0 => 0
		2 => 2
		3 => 1
		_ => return Err(NotBase64)
	}
	if ($padding == needed and $bits == 0) Ok($out) else Err(NotBase64)
}

## Arbitrary bytes encode exactly as the reference and round trip. Arbitrary
## Unicode text and alphabet-biased text are accepted exactly when the strict
## reference accepts them; an accepted text is already the canonical encoding.
test : List(U8) -> Fuzz.Outcome
test = |bytes| {
	encoded = Base64.encode(bytes)
	if encoded != encode_model(bytes) {
		crash "Base64.encode disagrees with the streaming model"
	}
	if Base64.decode(encoded) != Ok(bytes) {
		crash "Base64.decode lost encoded bytes"
	}
	biased = bytes.map(|byte| if (byte % 65 == 64) '=' else alphabet.get((byte % 65).to_u64()) ?? crash "base64 fuzz: alphabet index outside 0 through 63")
	for text in [Str.from_utf8_lossy(bytes), Str.from_utf8(biased) ?? crash "base64 fuzz: biased alphabet must be ASCII"] {
		actual = Base64.decode(text)
		if actual != decode_model(text) {
			crash "Base64.decode disagrees with the strict streaming model for ${Str.inspect(text)}"
		}
		match actual {
			Err(NotBase64) => {}
			Ok(decoded) => if Base64.encode(decoded) != text {
				crash "Base64.decode accepted noncanonical text"
			}
		}
	}
	Fuzz.keep
}

example : Str, Str -> Fuzz.Example(List(U8))
example = |name, text| Fuzz.example({ name, revision: "1", make: || text.to_utf8() })

fuzz_target = Fuzz.target_with({
	name: "base64",
	generator: Fuzz.raw_bytes,
	test,
	show: Str.inspect,
	examples: [
		example("empty", ""),
		example("one-byte", "f"),
		example("two-bytes", "fo"),
		example("three-bytes", "foo"),
		example("one-pad", "Zm8="),
		example("two-pads", "Zg=="),
		example("no-pad", "Zm9v"),
		example("missing-pad", "Zg"),
		example("excess-pad", "Zg==="),
		example("internal-pad", "Zg==Zg=="),
		example("all-pad", "===="),
		example("nonzero-four-bits", "Zh=="),
		example("nonzero-two-bits", "Zm9="),
		example("whitespace", "Zg==\n"),
		example("url-alphabet", "_w=="),
		example("unicode", "café λ 🦋"),
		Fuzz.example({ name: "binary", revision: "1", make: || [0, 255, 128, 192, 1, 254, 127] }),
		Fuzz.example({
			name: "every-byte",
			revision: "1",
			make: || {
				var $all = []
				for value in 0.U64..<256 {
					$all = $all.append(value.to_u8_wrap())
				}
				$all
			},
		}),
	],
})

## The same property, model and saved inputs used by the standalone app and suite.
FuzzBase64Property := [].{
	target = fuzz_target
}
