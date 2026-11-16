#!/usr/bin/env roc-stable
app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.28.1/7brgwR8YUqfeGrkdfF1V4GPPN7DnP7ftqub9KcrTEZtr.tar.zst",
	parser: "https://github.com/lukewilliamboswell/roc-parser/releases/download/6.0.0-rc.3/FTL1xt1rA9nXzoYkhFAW9yF75Kn52bS3cpBr7wZNfPq2.tar.zst",
	pf: "../platform/main-fuzz.roc",
	roc: "nightly-2026-11-14-a87808d",
}

import cli.Path
import pf.Protocol
import src/ApiSurface
import src/Proc
import src/UnionShape

## Check authored protocol rows without generating architectural authority.
## Both package roots must declare identical, published internal dependencies.
main! = |_args| {
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
