import parser.RocSyntax

## Read declarations from the same Roc syntax tree used by site tooling.
## Only associated blocks publish members; function bodies are never walked.
ApiSurface := [].{

	## One named declaration, its preceding doc text, and a direct type alias.
	Decl : { name : Str, doc : Str, alias : Str }

	## A parsed module, used to follow aliases without exposing internal pages.
	Module : { name : Str, declarations : List(Decl) }

	## The modules in the parsed platform header's exposes clause. Imports,
	## comments and string literals elsewhere cannot add apparent modules.
	modules : Str -> Try(List(Str), _)
	modules = |source| {
		parsed = RocSyntax.validate({ source, name: "platform/main.roc", lints: { placeholders: False } })?
		root = parsed.nodes.get(parsed.root)?
		header = children(parsed, root).find_first(|node| node.kind == Header)?
		names = children(parsed, header).keep_if(|node| node.kind == ExposedItem).map(|node| text(parsed, node))
		if names.is_empty() or names.fold(Dict.empty(), |seen, name| seen.insert(name, {})).len() != names.len() {
			Err(BadExposes)
		} else Ok(names)
	}

	## Every method reachable through a public declaration, including methods
	## inherited through aliases. Cycles are refused rather than truncated.
	reachable : List(Module), List(Decl) -> Try(List(Decl), [AliasCycle(Str)])
	reachable = |catalogue, declarations| {
		var $out = []
		for decl in declarations {
			$out = $out.append(decl).concat(alias_members(catalogue, decl.name, decl.alias, [])?)
		}
		Ok($out)
	}

	## Direct and nested members of this file's own module type. A missing
	## module block is allowed for roots and files containing private helpers.
	declarations : Str, Str -> Try(List(Decl), _)
	declarations = |module_name, source| {
		parsed = RocSyntax.validate({ source, name: module_name, lints: { placeholders: False } })?
		root = parsed.nodes.get(parsed.root)?
		var $found = []
		for node in children(parsed, root).keep_if(|node| node.kind == TypeDeclaration) {
			header = children(parsed, node).find_first(|child| child.kind == TypeHeader)?
			name = (text(parsed, header).split_on("(").first() ?? "").trim()
			if name == module_name {
				$found = members(parsed, node, module_name)
			}
		}
		Ok($found)
	}
}

## Exact source spelling for a syntax node; all spans came from valid UTF-8.
text : RocSyntax.Parsed, RocSyntax.Node -> Str
text = |parsed, node| Str.from_utf8(parsed.source.sublist({ start: node.start, len: node.end - node.start })) ?? crash "ApiSurface: syntax spans must preserve UTF-8"

## Resolve the parser's child indices without inventing nodes on bad spans.
children : RocSyntax.Parsed, RocSyntax.Node -> List(RocSyntax.Node)
children = |parsed, node| parsed.children.sublist({ start: node.children_start, len: node.children_len }).map(|index| parsed.nodes.get(index) ?? crash "ApiSurface: valid syntax must have valid child indices")

## The contiguous doc-comment lines immediately before a declaration.
documentation : RocSyntax.Parsed, U64 -> Str
documentation = |parsed, start| {
	prefix = Str.from_utf8(parsed.source.take_first(start)) ?? crash "ApiSurface: declaration boundary must preserve UTF-8"
	lines = prefix.split_on("\n").drop_last(1)
	var $at = lines.len()
	var $doc = []
	var $done = False
	while $at > 0 and !$done {
		$at = $at - 1
		line = (lines.get($at) ?? crash "ApiSurface: preceding line index").trim()
		if line.starts_with("##") {
			$doc = [line.drop_prefix("##").trim_start()].concat($doc)
		} else {
			$done = True
		}
	}
	Str.join_with($doc, "\n")
}

## Traverse only associated blocks. An annotation and its definition name
## one member; the annotation owns its documentation and alias information.
members : RocSyntax.Parsed, RocSyntax.Node, Str -> List(ApiSurface.Decl)
members = |parsed, owner, prefix| {
	var $out = []
	for block in children(parsed, owner).keep_if(|node| node.kind == AssociatedBlock) {
		for node in children(parsed, block) {
			parts = children(parsed, node)
			if node.kind == TypeDeclaration {
				header = parts.find_first(|child| child.kind == TypeHeader) ?? crash "ApiSurface: type declaration has a header"
				name = (text(parsed, header).split_on("(").first() ?? "").trim()
				qualified = "${prefix}.${name}"
				var $alias = ""
				for value in parts.keep_if(|child| child.kind != TypeHeader and child.kind != AssociatedBlock and child.kind != WhereClause and child.start >= header.end) {
					operator = Str.from_utf8(parsed.source.sublist({ start: header.end, len: value.start - header.end })) ?? crash "ApiSurface: type operator UTF-8"
					if operator.trim() == ":" {
						$alias = (text(parsed, value).split_on("(").first() ?? "").trim()
					}
				}
				$out = $out.append({ name: qualified, doc: documentation(parsed, node.start), alias: $alias }).concat(members(parsed, node, qualified))
			} else if node.kind == TypeAnnotation or node.kind == Declaration {
				match parts.first() {
					Ok(first) if first.kind == Identifier or first.kind == IdentifierPattern => {
						name = "${prefix}.${text(parsed, first)}"
						if !$out.any(|decl| decl.name == name) {
							$out = $out.append({ name, doc: documentation(parsed, node.start), alias: "" })
						}
					}
					_ => {}
				}
			}
		}
	}
	$out
}

## Nested members are public; locals and unrelated top-level helpers are not.
expect {
	source =
		\\Demo := [].{
		\\    ## A record wrapper.
		\\    Box(a) :: { value : a }.{
		\\        ## Read its value.
		\\        get : Box(a) -> a
		\\        get = |box| {
		\\            hidden : U64
		\\            hidden = 1
		\\            box.value
		\\        }
		\\    }
		\\    ## The public alias.
		\\    Public : Core.Root({})
		\\}
		\\private = 0
	ApiSurface.declarations("Demo", source)? == [
		{ name: "Demo.Box", doc: "A record wrapper.", alias: "" },
		{ name: "Demo.Box.get", doc: "Read its value.", alias: "" },
		{ name: "Demo.Public", doc: "The public alias.", alias: "Core.Root" },
	]
}

## Follow one alias in its declaring module. Only its member prefix is
## copied; the internal type and every unrelated symbol stay private.
alias_members : List(ApiSurface.Module), Str, Str, List(Str) -> Try(List(ApiSurface.Decl), [AliasCycle(Str)])
alias_members = |modules, public_name, target, seen| {
	if target.is_empty() {
		return Ok([])
	}
	if seen.contains(target) {
		return Err(AliasCycle(target))
	}
	var $out = []
	for source_module in modules {
		for decl in source_module.declarations {
			if decl.name == target {
				$out = $out.concat(alias_members(modules, public_name, decl.alias, seen.append(target))?)
			} else if decl.name.starts_with("${target}.") {
				name = "${public_name}${decl.name.drop_prefix(target)}"
				$out = $out.append({ ..decl, name }).concat(alias_members(modules, name, decl.alias, seen.append(target))?)
			}
		}
	}
	Ok($out)
}

## A public alias inherits its target's methods, while private neighbours
## remain private. Chained aliases retain the method's own documentation.
expect {
	modules = [
		{
			name: "Core",
			declarations: [
				{ name: "Core.Program", doc: "Internal program.", alias: "" },
				{ name: "Core.Program.with_ports", doc: "Register ports.", alias: "" },
				{ name: "Core.driver", doc: "Internal driver.", alias: "" },
			],
		},
		{ name: "Engine", declarations: [{ name: "Engine.Program", doc: "An app.", alias: "Core.Program" }] },
	]
	ApiSurface.reachable(modules, [{ name: "Public.App", doc: "The program.", alias: "Engine.Program" }])? == [
		{ name: "Public.App", doc: "The program.", alias: "Engine.Program" },
		{ name: "Public.App.with_ports", doc: "Register ports.", alias: "" },
	]
}

## A cyclic alias cannot make the documentation walk recurse forever.
expect ApiSurface.reachable([{ name: "Cycle", declarations: [{ name: "Cycle.Type", doc: "Cycle.", alias: "Cycle.Type" }] }], [{ name: "Public.Type", doc: "Alias.", alias: "Cycle.Type" }]).is_err()
