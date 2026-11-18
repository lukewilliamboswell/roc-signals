## Compare independent producer observations with consumer vocabulary. This
## module has no platform import, so the tooling gate runs its own expects.
ProtocolEvidence := [].{

	## Names and encoded numbers observed at the two protocol boundaries.
	Vocabulary : {
		kinds : List(Code),
		properties : List({ index : U8, name : Str, elements : List(Str) }),
		policies : List({ bit : U32, name : Str }),
		http_cache : List(Code),
		http_credentials : List(Code),
		namespaces : List(Code),
		template_nodes : List(Code),
		child_containers : List(Code),
	}

	## A named one-byte number, authored independently on each side.
	Code : { code : U8, name : Str }

	## Check the unmodified tables, then perturb each numeric row separately.
	## A driver supplies the actual producer and consumer; pure fixtures below
	## check that every mutation family is visited without importing the engine.
	mutations_rejected : Vocabulary, Vocabulary -> Bool
	mutations_rejected = |producer, facts| {
		agrees = |consumer| producer == consumer
		agrees(facts)
			and facts.kinds.all(|changed| !agrees({ ..facts, kinds: changed_code(facts.kinds, changed.name) }))
			and facts.properties.all(|changed| !agrees({ ..facts, properties: facts.properties.map(|row| if (row.name == changed.name) { ..row, index: row.index.bitwise_xor(1) } else row) }))
			and facts.policies.all(|changed| !agrees({ ..facts, policies: facts.policies.map(|row| if (row.name == changed.name) { ..row, bit: row.bit.shl_wrap(1) } else row) }))
			and facts.http_cache.all(|changed| !agrees({ ..facts, http_cache: changed_code(facts.http_cache, changed.name) }))
			and facts.http_credentials.all(|changed| !agrees({ ..facts, http_credentials: changed_code(facts.http_credentials, changed.name) }))
			and facts.namespaces.all(|changed| !agrees({ ..facts, namespaces: changed_code(facts.namespaces, changed.name) }))
			and facts.template_nodes.all(|changed| !agrees({ ..facts, template_nodes: changed_code(facts.template_nodes, changed.name) }))
			and facts.child_containers.all(|changed| !agrees({ ..facts, child_containers: changed_code(facts.child_containers, changed.name) }))
	}
}

## Change one valid row to another number while preserving all its names.
changed_code : List(ProtocolEvidence.Code), Str -> List(ProtocolEvidence.Code)
changed_code = |rows, name| rows.map(|row| if (row.name == name) { ..row, code: row.code.bitwise_xor(1) } else row)

## A zero policy bit would not change when shifted, so this independent
## fixture checks that a mutation family which failed to perturb is refused.
expect {
	facts = {
		kinds: [{ code: 1.U8, name: "kind" }],
		properties: [{ index: 1.U8, name: "property", elements: ["element"] }],
		policies: [{ bit: 1.U32, name: "policy" }],
		http_cache: [{ code: 1.U8, name: "cache" }],
		http_credentials: [{ code: 1.U8, name: "credentials" }],
		namespaces: [{ code: 0.U8, name: "namespace" }],
		template_nodes: [{ code: 1.U8, name: "node" }],
		child_containers: [{ code: 0.U8, name: "container" }],
	}
	bad = { ..facts, policies: [{ bit: 0, name: "policy" }] }
	ProtocolEvidence.mutations_rejected(facts, facts) and !ProtocolEvidence.mutations_rejected(bad, bad) and !ProtocolEvidence.mutations_rejected(facts, { ..facts, kinds: [{ code: 2, name: "kind" }] })
}
