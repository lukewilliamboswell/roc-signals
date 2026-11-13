app [target] {
	fz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.6.1/GDoZFRDnzMRiVk9nE8wdWn52btGsM1GhcY9VDKqy9f1Y.tar.zst",
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

## Any accepted text has a canonical stable serialization and total exact readers.
## Byte input also builds decoded names and pairs, including arbitrary Unicode and
## reserved text, which survive both ordinary and independently encoded fragments.
test : List(U8) -> Fuzz.Outcome
test = |bytes| {
	match Str.from_utf8(bytes) {
		Err(_) => {}
		Ok(text) => match Url.parse(text) {
			Err(_) => {}
			Ok(url) => {
				if Url.parse(url.to_str()) != Ok(url) {
					crash "accepted URL is not canonically stable"
				}
				_ = url.path_segments()
				_ = url.query_pairs()
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
		Fuzz.example({ name: "arbitrary-invalid-bytes", revision: "1", make: || [255, 192, 0, 128] }),
	],
})
