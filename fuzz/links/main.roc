app [target] {
	fz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.6.2/3kyiehxxzwAsjM23uCQGJ3Hx7dAAdzSGtK3k9Jq7Egtu.tar.zst",
	pf: "../../platform/main-fuzz.roc",
}
import fz.Fuzz
import pf.Web

## Independent scheme model: find a colon before any non-scheme character in
## browser-preprocessed input. A refusal never changes the original text.
model : Str -> Bool
model = |authored| {
	bytes = authored.to_utf8()
	start = bytes.find_first_index(|byte| byte > 32) ?? bytes.len()
	normalized = Str.from_utf8(bytes.drop_first(start).keep_if(|byte| byte != 9 and byte != 10 and byte != 13)) ?? crash "link model: removing ASCII retains UTF-8"
	match normalized.split_on(":") {
		[prefix, _, ..] => {
			alpha = |byte| (byte >= 'a' and byte <= 'z') or (byte >= 'A' and byte <= 'Z')
			scheme = !prefix.is_empty() and alpha(prefix.to_utf8().first() ?? 0) and prefix.to_utf8().all(|byte| alpha(byte) or (byte >= '0' and byte <= '9') or byte == '+' or byte == '-' or byte == '.')
			folded = Str.from_utf8(prefix.to_utf8().map(|byte| if (byte >= 'A' and byte <= 'Z') byte + 32 else byte)) ?? crash "link model: ASCII case preserves UTF-8"
			!scheme or ["http", "https", "mailto", "tel"].contains(folded)
		}
		_ => True
	}
}

## Policy agrees with the model and both constructors; accepted text is exact.
test : List(U8) -> Fuzz.Outcome
test = |bytes| {
	text = Str.from_utf8_lossy(bytes)
	actual = Web.Link.from_str(text)
	if actual.is_ok() != model(text) or Web.Link.from_quote(text).is_ok() != actual.is_ok() {
		crash "link scheme policy disagrees with reference"
	}
	match actual {
		Ok(destination) => if destination.text() != text {
			crash "checked link changed authored text"
		}
		Err(UnsupportedScheme(_)) => {}
	}
	Fuzz.keep
}

example : Str, Str -> Fuzz.Example(List(U8))
example = |name, text| Fuzz.example({ name, revision: "1", make: || text.to_utf8() })

target = Fuzz.target_with({
	name: "links",
	generator: Fuzz.raw_bytes,
	test,
	show: Str.inspect,
	examples: [
		example("empty", ""),
		example("relative", "../guide?q=a:b#part"),
		example("https", " HTTPS://example.test/path "),
		example("mailto", "mail\nto:a@b"),
		example("tel", "TEL:+123"),
		example("authority", "//example.test"),
		example("javascript", "javascript:alert(1)"),
		example("obfuscated", "\u(0000)JaVa\tScRi\nPt:alert(1)\u(001F)"),
		example("data", "data:text/html,<b>html</b>"),
		example("blob", "blob:https://example.test/id"),
		example("invalid-scheme", "1x:relative"),
		example("embedded-space", "java script:relative"),
		example("punctuation", "a+b.c-d:refused"),
		example("unicode", "é:relative"),
	],
})
