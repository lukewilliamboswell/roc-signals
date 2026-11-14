#!/usr/bin/env roc-stable
app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.27.0/9yjxqdGTP4xSpSEmDazwTmRsehfRZzA19pwEKkR6fj1g.tar.zst",
	parser: "https://github.com/lukewilliamboswell/roc-parser/releases/download/6.0.0-rc.2/2H2hePe5iYTZaGdG9MbMqhS29yg4Zxxr7dPEbZJ96fME.tar.zst",
	pf: "../platform/main-fuzz.roc",
	roc: "nightly-2026-11-13-03dce41",
}

import cli.Path
import pf.Protocol
import src/ApiSurface
import src/Proc

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
	Proc.note!("Protocol authority rows and package roots agree")
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
