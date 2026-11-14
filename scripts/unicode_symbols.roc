app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.28.1/7brgwR8YUqfeGrkdfF1V4GPPN7DnP7ftqub9KcrTEZtr.tar.zst",
	pf: "../platform/main-fuzz.roc",
	unicode: "https://github.com/roc-lang/unicode/releases/download/4.3.2/3gvgiWm6BShjHKbNV2zRH6fhC5ZvScZgWF7AnVDWHSdd.tar.zst",
}

import cli.Stdout
import pf.Dom
import unicode.Scalar

## Export one bit per code point from the actual native oracle. Surrogate bits
## stay zero; each valid scalar is encoded as a Str before Dom classifies it,
## retaining the oracle's own one-scalar and UTF-8 checks. The Chrome contract
## independently compares every bit with its browser's Unicode categories.
main! = |_args| {
	var $bytes = List.with_capacity(139_264)
	var $packed = 0.U8
	var $bit = 0.U8
	for point in 0.U32..=0x10FFFF {
		is_symbol = match Scalar.from_u32(point) {
			Err(_) => False
			Ok(scalar) => Dom.key_symbol(Scalar.to_str(scalar) ?? crash "Unicode scalar could not be encoded")
		}
		if is_symbol {
			$packed = $packed.bitwise_or((1.U8).shl_wrap($bit))
		}
		$bit = $bit + 1
		if $bit == 8 {
			$bytes = $bytes.append($packed)
			$packed = 0
			$bit = 0
		}
	}
	Stdout.write_bytes!($bytes)
}
