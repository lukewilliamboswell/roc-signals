app [target] {
	fz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.6.1/GDoZFRDnzMRiVk9nE8wdWn52btGsM1GhcY9VDKqy9f1Y.tar.zst",
	pf: "../../platform/main-fuzz.roc",
}

import fz.Fuzz
import pf.Protocol
import pf.ProtocolFacts

## Arbitrary bytes are either a typed refusal or exactly one canonical facts
## item. Accepted values retain all tables and every nested name when encoded
## and read again. The independent JS reader tests the same framing separately.
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

target = Fuzz.target_with({
	name: "protocol-facts",
	generator: Fuzz.raw_bytes,
	test,
	show: |bytes| Str.inspect(bytes),
	examples: [
		Fuzz.example({ name: "empty", revision: "1", make: || [] }),
		Fuzz.example({ name: "all-vocabularies", revision: "1", make: || ProtocolFacts.encode(Protocol.facts) }),
		Fuzz.example({ name: "truncated", revision: "1", make: || ProtocolFacts.encode(Protocol.facts).drop_last(1) }),
		Fuzz.example({ name: "trailing", revision: "1", make: || ProtocolFacts.encode(Protocol.facts).append(0) }),
		Fuzz.example({ name: "unknown-first-field", revision: "1", make: || [10].concat(ProtocolFacts.encode(Protocol.facts).drop_first(1)) }),
		Fuzz.example({ name: "repeated-field", revision: "1", make: || ProtocolFacts.encode(Protocol.facts).concat(ProtocolFacts.encode(Protocol.facts)) }),
		Fuzz.example({ name: "oversized-count", revision: "1", make: || [1, 4, 0, 0, 0, 255, 255, 255, 255] }),
		Fuzz.example({ name: "duplicate-names", revision: "1", make: || ProtocolFacts.encode({ ..Protocol.facts, bool_attrs: ["open", "open"] }) }),
		Fuzz.example({ name: "non-dense-opcodes", revision: "1", make: || ProtocolFacts.encode({ ..Protocol.facts, ops: [{ code: 2, name: "INST" }] }) }),
		Fuzz.example({ name: "invalid-policy-bit", revision: "1", make: || ProtocolFacts.encode({ ..Protocol.facts, policies: [{ bit: 3, name: "PREVENT" }] }) }),
	],
})
