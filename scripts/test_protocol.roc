#!/usr/bin/env roc-stable
app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.28.1/7brgwR8YUqfeGrkdfF1V4GPPN7DnP7ftqub9KcrTEZtr.tar.zst",
	parser: "https://github.com/lukewilliamboswell/roc-parser/releases/download/6.0.0-rc.3/FTL1xt1rA9nXzoYkhFAW9yF75Kn52bS3cpBr7wZNfPq2.tar.zst",
	pf: "../platform/main-fuzz.roc",
	roc: "nightly-2026-11-14-a87808d",
}

import cli.Path
import pf.Core
import pf.Protocol
import src/ApiSurface
import src/Proc
import src/UnionShape

## Check authored protocol rows without generating architectural authority.
## Both package roots must declare identical, published internal dependencies.
main! = |_args| {
	producer = Core.protocol_evidence()
	consumer = { ..consumer_vocabulary, kinds: Protocol.kinds.map(|row| { code: row.code, name: row.name }) }
	if !vocabulary_agrees(consumer) {
		return Err(ProducerVocabularyMismatch({ producer, consumer }))
	}
	design = Path.read_utf8!(Path.utf8("design.md"))?
	appendix = design.split_on("## Appendix B: Wire Protocol").last() ?? return Err(MissingAppendix)
	rows = appendix.split_on("\n").map(|line| line.trim())
	for opcode in Protocol.ops {
		prefix = "| ${opcode.code.to_str()} | `${opcode.name}` |"
		if rows.keep_if(|line| line.starts_with(prefix)).len() != 1 {
			return Err(MissingOrDuplicateOpcode(opcode))
		}
	}
	for kind in Protocol.kinds {
		heading = "${kind.code.to_str()}${canonical(kind.name)}"
		matches = rows.keep_if(
			|line| {
				first = line.split_on("|").get(1) ?? ""
				canonical(first) == heading
			},
		)
		if matches.len() != 1 {
			return Err(MissingOrDuplicateKind(kind))
		}
	}
	for property in Protocol.properties {
		prefix = "| ${property.index.to_str()} | `${property.name}` |"
		if rows.keep_if(|line| line.starts_with(prefix)).len() != 1 {
			return Err(MissingOrDuplicateProperty(property))
		}
	}
	for policy in Protocol.policies {
		marker = "(`${policy.bit.to_str()}`) | `${canonical(policy.name)}` |"
		if rows.keep_if(|line| line.contains(marker)).len() != 1 {
			return Err(MissingOrDuplicatePolicy(policy))
		}
	}
	if !appendix.contains("protocol version **${Protocol.version.to_str()}**") {
		return Err(VersionMismatch)
	}
	# Appendix A's request, command and result unions are the engine's.
	engine = Path.read_utf8!(Path.utf8("platform/Engine.roc"))?
	surface = design.split_on("## Appendix A: API Surface").get(1) ?? return Err(MissingAppendix)
	surface_a = surface.split_on("## Appendix B: Wire Protocol").first() ?? surface
	for union in ["Request", "Command", "Result"] {
		documented = UnionShape.variants(surface_a, union)?
		declared = UnionShape.variants(engine, union)?
		differences = UnionShape.differences(documented, declared)
		if !differences.is_empty() {
			return Err(AppendixADiffers({ union, differences }))
		}
	}
	page_dependencies = ApiSurface.dependencies(Path.read_utf8!(Path.utf8("platform/main.roc"))?)?
	fuzz_dependencies = ApiSurface.dependencies(Path.read_utf8!(Path.utf8("platform/main-fuzz.roc"))?)?
	if page_dependencies.fold(Dict.empty(), |out, item| out.insert(item.name, item.url)) != fuzz_dependencies.fold(Dict.empty(), |out, item| out.insert(item.name, item.url)) {
		return Err(PackageRootsDiffer(page_dependencies, fuzz_dependencies))
	}
	for dependency in page_dependencies {
		if !(dependency.url.starts_with("https://") and dependency.url.contains("/releases/download/") and dependency.url.ends_with(".tar.zst")) {
			return Err(UnpinnedDependency(dependency))
		}
	}
	Proc.note!("Protocol authority rows, Appendix A's request, command and result unions and package roots agree")
	Ok({})
}

## Compare independently authored consumer rows with the actual producer paths.
## This module may know both sides; the engine and oracle may not share code.
vocabulary_agrees : { kinds : List(Protocol.Code), properties : List(Protocol.Property), policies : List(Protocol.Policy), http_cache : List(Protocol.Code), http_credentials : List(Protocol.Code), namespaces : List(Protocol.Code), template_nodes : List(Protocol.Code), child_containers : List(Protocol.Code) } -> Bool
vocabulary_agrees = |consumer| Core.protocol_evidence() == consumer

## These names are consumer authority. Core's observations come from its actual
## attach functions, property constructors and encoding paths, never these rows.
consumer_vocabulary = {
	kinds: Protocol.kinds.map(|row| { code: row.code, name: row.name }),
	properties: Protocol.properties,
	policies: Protocol.policies,
	http_cache: Protocol.http_cache,
	http_credentials: Protocol.http_credentials,
	namespaces: Protocol.namespaces,
	template_nodes: Protocol.template_nodes,
	child_containers: Protocol.child_containers,
}

## Every swapped kind, property, policy and encoding number is rejected;
## identical consumer tables cannot conceal drift from the producer's codecs.
expect {
	facts = consumer_vocabulary
	vocabulary_agrees(facts) and facts.kinds.all(|changed| !vocabulary_agrees({ ..facts, kinds: changed_code(facts.kinds, changed.name) })) and facts.properties.all(|changed| !vocabulary_agrees({ ..facts, properties: facts.properties.map(|row| if (row.name == changed.name) { ..row, index: row.index.bitwise_xor(1) } else row) })) and facts.policies.all(|changed| !vocabulary_agrees({ ..facts, policies: facts.policies.map(|row| if (row.name == changed.name) { ..row, bit: row.bit.shl_wrap(1) } else row) })) and facts.http_cache.all(|changed| !vocabulary_agrees({ ..facts, http_cache: changed_code(facts.http_cache, changed.name) })) and facts.http_credentials.all(|changed| !vocabulary_agrees({ ..facts, http_credentials: changed_code(facts.http_credentials, changed.name) })) and facts.namespaces.all(|changed| !vocabulary_agrees({ ..facts, namespaces: changed_code(facts.namespaces, changed.name) })) and facts.template_nodes.all(|changed| !vocabulary_agrees({ ..facts, template_nodes: changed_code(facts.template_nodes, changed.name) })) and facts.child_containers.all(|changed| !vocabulary_agrees({ ..facts, child_containers: changed_code(facts.child_containers, changed.name) }))
}

## Change one valid row to another number while preserving all its names.
changed_code : List(Protocol.Code), Str -> List(Protocol.Code)
changed_code = |rows, name| rows.map(|row| if (row.name == name) { ..row, code: row.code.bitwise_xor(1) } else row)

## Ignore authored spacing and name capitalization, retaining every actual
## character so an obsolete payload label cannot match another name.
canonical : Str -> Str
canonical = |text| Str.from_utf8(
	text.to_utf8().keep_if(|byte| byte != ' ' and byte != '_' and byte != '`').map(
		|byte| if byte >= 'A' and byte <= 'Z' {
			byte + 32
		} else {
			byte
		},
	),
) ?? crash "ASCII folding preserves UTF-8"
