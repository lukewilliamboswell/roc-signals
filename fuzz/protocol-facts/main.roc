app [target] {
	fz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.6.2/3kyiehxxzwAsjM23uCQGJ3Hx7dAAdzSGtK3k9Jq7Egtu.tar.zst",
	pf: "../../platform/main-fuzz.roc",
}

import fz.Fuzz
import pf.Protocol
import pf.ProtocolFacts

## Arbitrary bytes are either a typed refusal or exactly one canonical facts
## item. Accepted values retain all tables and every nested name when encoded
## and read again. The independent JS reader checks the same schema and canonical CBOR profile.
test : List(U8) -> Fuzz.Outcome
test = |bytes| {
	match ProtocolFacts.decode(bytes) {
		Err(_) => {}
		Ok(facts) => {
			encoded = ProtocolFacts.encode(facts)
			if encoded != bytes {
				crash "protocol facts accepted noncanonical bytes"
			}
			if ProtocolFacts.decode(encoded) != Ok(facts) {
				crash "protocol facts lost decoded metadata"
			}
		}
	}
	Fuzz.keep
}

## Saved independent complete facts witness: its nested events array was
## replaced by a zero-length byte string. Accepting it would violate the
## existing byte-for-byte canonical oracle and disagree with the JS schema.
nested_empty_events : List(U8)
nested_empty_events = [171, 99, 111, 112, 115, 129, 162, 100, 99, 111, 100, 101, 1, 100, 110, 97, 109, 101, 100, 73, 78, 83, 84, 101, 107, 105, 110, 100, 115, 129, 163, 100, 99, 111, 100, 101, 1, 100, 110, 97, 109, 101, 100, 84, 69, 88, 84, 102, 101, 118, 101, 110, 116, 115, 64, 104, 112, 111, 108, 105, 99, 105, 101, 115, 129, 162, 99, 98, 105, 116, 1, 100, 110, 97, 109, 101, 103, 80, 82, 69, 86, 69, 78, 84, 106, 104, 116, 116, 112, 95, 99, 97, 99, 104, 101, 129, 162, 100, 99, 111, 100, 101, 1, 100, 110, 97, 109, 101, 103, 100, 101, 102, 97, 117, 108, 116, 106, 110, 97, 109, 101, 115, 112, 97, 99, 101, 115, 129, 162, 100, 99, 111, 100, 101, 0, 100, 110, 97, 109, 101, 100, 72, 84, 77, 76, 106, 112, 114, 111, 112, 101, 114, 116, 105, 101, 115, 129, 163, 100, 110, 97, 109, 101, 101, 118, 97, 108, 117, 101, 101, 105, 110, 100, 101, 120, 1, 104, 101, 108, 101, 109, 101, 110, 116, 115, 129, 101, 105, 110, 112, 117, 116, 109, 102, 97, 117, 108, 116, 95, 99, 108, 97, 115, 115, 101, 115, 130, 100, 110, 111, 110, 101, 104, 99, 111, 110, 116, 114, 97, 99, 116, 110, 116, 101, 109, 112, 108, 97, 116, 101, 95, 110, 111, 100, 101, 115, 129, 162, 100, 99, 111, 100, 101, 1, 100, 110, 97, 109, 101, 103, 69, 76, 69, 77, 69, 78, 84, 112, 99, 104, 105, 108, 100, 95, 99, 111, 110, 116, 97, 105, 110, 101, 114, 115, 129, 162, 100, 99, 111, 100, 101, 0, 100, 110, 97, 109, 101, 104, 67, 72, 73, 76, 68, 82, 69, 78, 112, 104, 116, 116, 112, 95, 99, 114, 101, 100, 101, 110, 116, 105, 97, 108, 115, 129, 162, 100, 99, 111, 100, 101, 1, 100, 110, 97, 109, 101, 107, 115, 97, 109, 101, 45, 111, 114, 105, 103, 105, 110, 115, 116, 101, 120, 116, 95, 101, 110, 116, 114, 121, 95, 101, 120, 99, 108, 117, 100, 101, 100, 129, 102, 98, 117, 116, 116, 111, 110]

expect ProtocolFacts.decode(nested_empty_events).is_err()

target = Fuzz.target_with({
	name: "protocol-facts",
	generator: Fuzz.raw_bytes,
	test,
	show: |bytes| Str.inspect(bytes),
	examples: [
		Fuzz.saved({ name: "nested-empty-events-byte-string", revision: "1", bytes: nested_empty_events }),
		Fuzz.example({ name: "empty", revision: "4", make: || [] }),
		Fuzz.example({ name: "all-vocabularies", revision: "4", make: || ProtocolFacts.encode(Protocol.facts) }),
		Fuzz.example({ name: "truncated", revision: "4", make: || ProtocolFacts.encode(Protocol.facts).drop_last(1) }),
		Fuzz.example({ name: "trailing", revision: "4", make: || ProtocolFacts.encode(Protocol.facts).append(0) }),
		Fuzz.example({ name: "unknown-first-field", revision: "4", make: || [0xab, 0x63, 'b', 'a', 'd'].concat(ProtocolFacts.encode(Protocol.facts).drop_first(5)) }),
		Fuzz.example({ name: "repeated-field", revision: "4", make: || ProtocolFacts.encode(Protocol.facts).concat(ProtocolFacts.encode(Protocol.facts)) }),
		Fuzz.example({ name: "oversized-count", revision: "4", make: || [0xab, 0x63, 'o', 'p', 's', 0x9a, 255, 255, 255, 255] }),
		Fuzz.example({ name: "duplicate-names", revision: "4", make: || ProtocolFacts.encode({ ..Protocol.facts, namespaces: [{ code: 0, name: "HTML" }, { code: 1, name: "HTML" }] }) }),
		Fuzz.example({ name: "non-dense-opcodes", revision: "4", make: || ProtocolFacts.encode({ ..Protocol.facts, ops: [{ code: 2, name: "INST" }] }) }),
		Fuzz.example({ name: "invalid-policy-bit", revision: "4", make: || ProtocolFacts.encode({ ..Protocol.facts, policies: [{ bit: 3, name: "PREVENT" }] }) }),
		Fuzz.example({ name: "padded-map-head", revision: "1", make: || [0xb8, 11].concat(ProtocolFacts.encode(Protocol.facts).drop_first(1)) }),
		Fuzz.example({ name: "indefinite-map", revision: "1", make: || [0xbf, 0xff] }),
		Fuzz.example({ name: "tagged-facts", revision: "1", make: || [0xc0].concat(ProtocolFacts.encode(Protocol.facts)) }),
		Fuzz.example({ name: "byte-string-facts", revision: "1", make: || [0x40] }),
		Fuzz.example({ name: "overlong-name", revision: "1", make: || ProtocolFacts.encode({ ..Protocol.facts, namespaces: [{ code: 0, name: Str.repeat("x", 129) }] }) }),
		Fuzz.example({ name: "nested-name-limit", revision: "1", make: || ProtocolFacts.encode({ ..Protocol.facts, kinds: [{ code: 1, name: "TEXT", events: (0.U64..<33).iter().fold([], |out, value| out.append(value.to_str())) }] }) }),
		Fuzz.example({ name: "duplicate-map-key", revision: "1", make: || [0xa2, 0x61, 'a', 0, 0x61, 'a', 0] }),
		Fuzz.example({ name: "invalid-utf8-key", revision: "1", make: || [0xa1, 0x61, 255, 0] }),
		Fuzz.example({ name: "depth-bound", revision: "1", make: || [0x81, 0x81, 0x81, 0x81, 0x81, 0] }),
	],
})
