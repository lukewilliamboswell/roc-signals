app [target] {
	fz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.6.1/GDoZFRDnzMRiVk9nE8wdWn52btGsM1GhcY9VDKqy9f1Y.tar.zst",
	pf: "../../platform/main-fuzz.roc",
}

import fz.Fuzz
import pf.Core

## Boot decoding is total over arbitrary bytes. Every accepted nonempty
## input must be the exact encoding of the value it describes: tags, section
## lengths, flags, UTF-8 and storage availability admit no alternative forms.
## Empty bytes are the one stated shorthand for the default environment.
## Storage-key membership belongs to the program mount, which has the
## declaration catalogue; it is not a structural property of these bytes.
test : List(U8) -> Fuzz.Outcome
test = |bytes| {
	var $many = []
	for index in 0.U64..<32 {
		$many = $many.append("q${index.to_str()}")
	}
	queries = [[], ["(prefers-color-scheme: dark)"], ["a", "b"], $many]
	for catalogue in queries {
		match Core.read_boot_media(bytes, catalogue) {
			Err(_) => {}
			Ok(boot) => {
				if !bytes.is_empty() and Core.write_boot(boot) != bytes {
					crash "boot decoder accepted a noncanonical encoding"
				}
				if (!boot.storage_available and !boot.storage.is_empty()) or (!boot.session_available and !boot.session.is_empty()) {
					crash "unavailable storage carried pairs"
				}
				if boot.media.map(|(query, _)| query) != catalogue {
					crash "media flags lost declaration order"
				}
			}
		}
	}
	Fuzz.keep
}

target = Fuzz.target_with({
	examples: [
		Fuzz.example({ name: "empty-defaults", revision: "1", make: || [] }),
		Fuzz.example({ name: "sections-defaults", revision: "1", make: || Core.write_boot({}) }),
		Fuzz.example({ name: "all-facts", revision: "2", make: || Core.write_boot({ url: "/a?b#c", storage: [("a", ""), ("a", "two")], session: [("draft", "λ")], online: False, visible: False, now_ms: -123, seed: 340282366920938463463374607431768211455, languages: ["", "en-AU"], zone: { name: "test", from_ms: -500, until_ms: 500, offsets: [{ from_ms: -500, minutes: -60 }, { from_ms: 0, minutes: 90 }] } }) }),
		Fuzz.example({ name: "storage-unavailable", revision: "1", make: || Core.write_boot({ storage_available: False }) }),
		Fuzz.example({ name: "invalid-unavailable-pairs", revision: "1", make: || Core.write_boot({ storage_available: False, storage: [("a", "b")] }) }),
		Fuzz.example({ name: "session-unavailable", revision: "1", make: || Core.write_boot({ session_available: False }) }),
		Fuzz.example({ name: "invalid-unavailable-session-pairs", revision: "1", make: || Core.write_boot({ session_available: False, session: [("draft", "lost")] }) }),
		Fuzz.example({ name: "media-first-paint", revision: "1", make: || Core.write_boot({ media: [("(prefers-color-scheme: dark)", True)] }) }),
		Fuzz.example({ name: "media-order", revision: "1", make: || Core.write_boot({ media: [("a", False), ("b", True)] }) }),
		Fuzz.example({ name: "invalid-media-flag", revision: "1", make: || Core.write_boot({ media: [("a", False), ("b", True)] }).take_first(37).append(2).concat(Core.write_boot({ media: [("a", False), ("b", True)] }).drop_first(38)) }),
		Fuzz.example({ name: "truncated", revision: "1", make: || Core.write_boot({}).drop_last(1) }),
		Fuzz.example({ name: "extra-tag", revision: "1", make: || Core.write_boot({}).concat([5, 0, 0, 0, 0]) }),
	],
	name: "boot",
	generator: Fuzz.raw_bytes,
	test,
	show: |bytes| Str.inspect(bytes),
})
