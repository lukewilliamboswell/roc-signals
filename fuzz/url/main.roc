app [target] {
	fz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.6.2/3kyiehxxzwAsjM23uCQGJ3Hx7dAAdzSGtK3k9Jq7Egtu.tar.zst",
	pf: "../../platform/main-fuzz.roc",
}

import fz.Fuzz
import pf.Url

## The browser's fragment percent-encode set, independent of Url's builders.
## https://url.spec.whatwg.org/#fragment-percent-encode-set
fragment_encoding : Str -> Str
fragment_encoding = |text| {
	hex = "0123456789ABCDEF".to_utf8()
	bytes = text.to_utf8().fold(
		[],
		|out, byte|
			if byte <= 32 or byte >= 127 or byte == 34 or byte == 60 or byte == 62 or byte == 96 {
				out.append(37).append(hex.get((byte // 16).to_u64()) ?? crash "fragment model hex index must be within 0 through 15").append(hex.get((byte % 16).to_u64()) ?? crash "fragment model hex index must be within 0 through 15")
			} else {
				out.append(byte)
			},
	)
	Str.from_utf8(bytes) ?? crash "fragment model only writes ASCII"
}

## A browser's reading of a host, written from WHATWG's host parser and sharing
## no code with Url: when the last label (ignoring one trailing dot) is a
## number, the host is an IPv4 address in the browser's own forms (octal after
## a leading zero, hexadecimal after `0x`, fewer than four parts), serialized
## as four decimal octets. Any other host is not an address.
## https://url.spec.whatwg.org/#concept-host-parser
browser_ipv4 : Str -> [NotAnAddress, Address(Str), Refused]
browser_ipv4 = |host| {
	all_parts = Str.split_on(host, ".")
	parts =
		if all_parts.len() > 1 and all_parts.get(all_parts.len() - 1) == Ok("") {
			all_parts.drop_last(1)
		} else {
			all_parts
		}
	last = parts.get(parts.len() - 1) ?? ""
	if ipv4_number(last) == Err(NotANumber) {
		NotAnAddress
	} else if parts.len() > 4 {
		Refused
	} else {
		numbers = parts.map(ipv4_number)
		if numbers.any(|n| n == Err(NotANumber)) {
			Refused
		} else {
			values = numbers.map(|n| n ?? 0)
			leading = values.drop_last(1)
			final = values.get(values.len() - 1) ?? 0
			limit = power_of_256(5 - values.len())
			if leading.any(|v| v > 255) or final >= limit {
				Refused
			} else {
				# The i-th leading part is the octet 3 - i places from the right.
				address = leading.fold(
					{ sum: final, place: 3 },
					|acc, v| { sum: acc.sum + v * power_of_256(acc.place), place: acc.place - 1 },
				).sum
				octets = [address // 16777216, (address // 65536) % 256, (address // 256) % 256, address % 256]
				Address(Str.join_with(octets.map(U64.to_str), "."))
			}
		}
	}
}

power_of_256 : U64 -> U64
power_of_256 = |n| if n == 0 {
	1
} else {
	256 * power_of_256(n - 1)
}

## WHATWG's IPv4 number parser. Values saturate above 2^36, which every caller
## refuses, so arbitrarily long input cannot overflow.
ipv4_number : Str -> Try(U64, [NotANumber])
ipv4_number = |text| {
	bytes = text.to_utf8()
	{ radix, digits } =
		match bytes {
			[48, x, .. as rest] if x == 120 or x == 88 => { radix: 16, digits: rest }
			[48, _, ..] => { radix: 8, digits: bytes.drop_first(1) }
			_ => { radix: 10, digits: bytes }
		}
	if bytes.is_empty() {
		Err(NotANumber)
	} else {
		digits.fold(
			Ok(0),
			|acc, byte|
				match acc {
					Err(e) => Err(e)
					Ok(value) => {
						d = digit_value(byte)
						if d >= radix {
							Err(NotANumber)
						} else if value > 68719476736 {
							Ok(value)
						} else {
							Ok(value * radix + d)
						}
					}
				},
		)
	}
}

## A byte's value as a digit of any radix up to 16; 99 for anything else.
digit_value : U8 -> U64
digit_value = |byte|
	if byte >= 48 and byte <= 57 {
		(byte - 48).to_u64()
	} else if byte >= 97 and byte <= 102 {
		(byte - 87).to_u64()
	} else if byte >= 65 and byte <= 70 {
		(byte - 55).to_u64()
	} else {
		99
	}

## Host text drawn from the characters that decide a numeric reading: a byte
## already in that alphabet is kept, so named examples read as written.
host_text : List(U8) -> Str
host_text = |bytes| {
	alphabet = "0123456789abcdefoxX.-".to_utf8()
	chosen = bytes.map(
		|byte|
			if alphabet.contains(byte) {
				byte
			} else {
				alphabet.get((byte % 21).to_u64()) ?? 46
			},
	)
	Str.from_utf8(chosen) ?? crash "host alphabet is ASCII"
}

## A host the browser reads as an IPv4 address is never accepted as anything
## else: Url either refuses it or reports exactly the address the browser
## contacts, and a host Url keeps as a name is not one the browser reads as an
## address.
check_host : List(U8) -> {}
check_host = |bytes| {
	host = host_text(bytes)
	match Url.parse("http://${host}/") {
		Err(_) => {}
		Ok(url) => match url.origin() {
			Absolute({ host: read, .. }) => {
				expected = browser_ipv4(host)
				match expected {
					Address(address) => if read != address {
						crash "host ${host} reads as ${read}, but the browser contacts ${address}"
					}
					Refused => crash "host ${host} is accepted, but the browser refuses it as an IPv4 address"
					NotAnAddress => if browser_ipv4(read) != NotAnAddress {
						crash "host ${host} is a name, but its serialization ${read} is an address to the browser"
					}
				}
			}
			Relative => crash "an http URL parsed as relative"
		}
	}
}

## Any accepted text has a canonical stable serialization and total exact readers.
## Byte input also builds decoded names and pairs, including arbitrary Unicode and
## reserved text, which survive both ordinary and independently encoded fragments.
test : List(U8) -> Fuzz.Outcome
test = |bytes| {
	check_host(bytes)
	match Str.from_utf8(bytes) {
		Err(_) => {}
		Ok(text) => match Url.parse(text) {
			Err(_) => {}
			Ok(url) => {
				again = Url.parse(url.to_str()) ?? crash "accepted URL serialization was refused"
				if again != url {
					crash "accepted URL is not canonically stable"
				}
				if again.path_segments() != url.path_segments() or again.query_pairs() != url.query_pairs() {
					crash "canonical URL lost decoded reader values"
				}
			}
		}
	}
	root : Url
	root = "/"
	text = Str.from_utf8_lossy(bytes)
	# Prefixes make valid authored segments without excluding any text inside them.
	names = ["name${text}", "second/${text}"]
	pairs = [(text, text), (text, " +%&#?${text}")]
	path = root.append_path_segments(names) ?? crash "generated nonempty nondot names were refused"
	built = pairs.fold(path, |url, (name, value)| url.append_query_param(name, value))
	if built.path_segments() != names or built.query_pairs() != pairs {
		crash "builder lost decoded names or pairs"
	}
	encoded_fragment = fragment_encoding(built.to_str())
	location = Url.parse("/demo/#${encoded_fragment}") ?? crash "browser location was refused"
	if location.fragment() != Some(encoded_fragment) {
		crash "outer fragment reader decoded URL text prematurely"
	}
	hash = match location.fragment() {
		Some(value) => value
		None => crash "browser fragment was lost"
	}
	match Url.parse(hash) {
		Err(error) => crash "browser-encoded fragment was refused: ${Str.inspect(error)}"
		Ok(read) => if read.path_segments() != names or read.query_pairs() != pairs {
			crash "browser fragment lost names or pairs"
		}
	}
	if root.append_path_segments(["."]) != Err(DotSegment(".")) or root.append_path_segments([".."]) != Err(DotSegment("..")) or root.append_path_segments([""]) != Err(EmptySegment) {
		crash "unsafe authored segment was accepted"
	}
	Fuzz.keep
}

## Named byte examples retain malformed boundaries and the bug's reserved text.
example : Str, Str -> Fuzz.Example(List(U8))
example = |name, text| Fuzz.example({ name, revision: "1", make: || text.to_utf8() })

target = Fuzz.target_with({
	name: "url",
	generator: Fuzz.raw_bytes,
	test,
	show: Str.inspect,
	examples: [
		example("empty", ""),
		example("reserved", "a/b?c#d&e%41+ a\"<>`"),
		example("unicode", "café au lait λ 🦋"),
		example("invalid-percent", "/?tag=100%"),
		example("invalid-utf8", "/?tag=%FF"),
		example("split-utf8", "/%C3/%A9"),
		example("encoded-dots", "/a/%2e/%2E%2e/b"),
		example("empty-segments", "/a//b/"),
		example("empty-query-fields", "/?a=1&&b=2&"),
		example("relative", "/demo/#/?tag=caf%C3%A9+au+lait"),
		example("absolute", "https://example.com/a%2Fb?tag=c%26c#route"),
		example("octal-host", "017.0.0.1"),
		example("hex-host", "0x7f.0.0.1"),
		example("numeric-last-label", "foo.123"),
		example("hex-last-label", "1.2.3.0x4"),
		example("numeric-trailing-dot", "foo.123."),
		Fuzz.example({ name: "arbitrary-invalid-bytes", revision: "1", make: || [255, 192, 0, 128] }),
	],
})
