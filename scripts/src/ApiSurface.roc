import parser.RocSyntax
import SourceText

## Read declarations from the same Roc syntax tree used by site tooling.
## Only associated blocks publish members; function bodies are never walked.
ApiSurface := [].{

	## One named declaration, its preceding doc text, and a direct type alias.
	Decl : { name : Str, doc : Str, alias : Str }

	## A parsed module, used to follow aliases without exposing internal pages.
	Module : { name : Str, declarations : List(Decl), auxiliary : List(Decl) }

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

	## Determine whether a real dependency field names the internal root.
	## Quoted escapes are decoded after syntax validation; comments and source
	## strings elsewhere cannot accidentally trigger this repository check.
	has_internal_dependency : Str -> Try(Bool, _)
	has_internal_dependency = |source| ApiSurface.dependencies(source).map_ok(|declared_dependencies| declared_dependencies.any(|dependency| dependency.url == "main-fuzz.roc" or dependency.url.ends_with("/main-fuzz.roc")))

	## Read dependency names and decoded URLs from validated header fields.
	## Escapes and platform references use the same source parser as the audit.
	dependencies : Str -> Try(List({ name : Str, url : Str }), _)
	dependencies = |source| {
		var $found = []
		parsed = RocSyntax.validate({ source, name: "source dependency audit", lints: { placeholders: False } })?
		root = parsed.nodes.get(parsed.root)?
		for header in children(parsed, root).keep_if(|node| node.kind == Header) {
			for dependency_block in children(parsed, header).keep_if(|node| node.kind == Dependencies) {
				for field in children(parsed, dependency_block).keep_if(|node| node.kind == DependencyField) {
					value = match children(parsed, field) {
						[_, expression] => expression
						_ => return Err(BadDependency)
					}
					literal = if value.kind == PlatformReference {
						match children(parsed, value) {
							[inner] => inner
							_ => return Err(BadDependency)
						}
					} else value
					segment = match children(parsed, literal) {
						[part] if literal.kind == StringLiteral and part.kind == StringSegment => part
						_ => return Err(BadDependency)
					}
					decoded = SourceText.quoted(parsed.source.sublist({ start: segment.start, len: segment.end - segment.start }), segment.start)
					url = Str.from_utf8(decoded.map(|point| point.byte)) ?? crash "ApiSurface: validated dependency UTF-8"
					name = match children(parsed, field) {
						[key, _] => text(parsed, key)
						_ => return Err(BadDependency)
					}
					$found = $found.append({ name, url })
				}
			}
		}
		Ok($found)
	}

	## Only the platform's declared target locations may name its internal root.
	is_platform_target : Str -> Bool
	is_platform_target = |file| match file.split_on("/") {
		["fuzz", _, "main.roc"] => True
		["tests", "apps", _, name] => name.starts_with("fuzz-") and name.ends_with(".roc")
		_ => False
	}

	## Every method reachable through a public declaration, including methods
	## inherited through aliases. Cycles are refused rather than truncated.
	reachable : List(Module), List(Decl) -> Try(List(Decl), [AliasCycle(Str)])
	reachable = |sources, declared| {
		var $out = []
		for decl in declared {
			$out = $out.append(decl).concat(alias_members(sources, decl.name, decl.alias, [])?)
		}
		Ok($out)
	}

	## Direct and nested members of this file's own module type. A missing
	## module block is allowed for roots and files containing private helpers.
	declarations : Str, Str -> Try(List(Decl), _)
	declarations = |module_name, source| ApiSurface.catalogue(module_name, source).map_ok(|catalogued| catalogued.declarations)

	## Retain file-local type implementations for alias traversal, separately
	## from the module's public declarations. Internal lookup names never
	## become a public page or a member unless reached through a public alias.
	catalogue : Str, Str -> Try(Module, _)
	catalogue = |module_name, source| {
		parsed = RocSyntax.validate({ source, name: module_name, lints: { placeholders: False } })?
		root = parsed.nodes.get(parsed.root)?
		owners = children(parsed, root).keep_if(|node| node.kind == TypeDeclaration).map(
			|node| {
				header = children(parsed, node).find_first(|child| child.kind == TypeHeader) ?? crash "ApiSurface: type declaration has a header"
				{ name: (text(parsed, header).split_on("(").first() ?? "").trim(), node }
			},
		)
		local_names = owners.keep_if(|owner| owner.name != module_name).map(|owner| owner.name)
		qualify = |decl| if local_names.contains(decl.alias) {
			{ ..decl, alias: "${module_name}#${decl.alias}" }
		} else decl
		var $direct = []
		var $auxiliary = []
		for owner in owners {
			if owner.name == module_name {
				$direct = members(parsed, owner.node, module_name).map(qualify)
			} else {
				internal_name = "${module_name}#${owner.name}"
				$auxiliary = $auxiliary.append(qualify({ name: internal_name, doc: documentation(parsed, owner.node.start), alias: alias_target(parsed, owner.node) })).concat(members(parsed, owner.node, internal_name).map(qualify))
			}
		}
		Ok({ name: module_name, declarations: $direct, auxiliary: $auxiliary })
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
	var $at = start
	while $at > 0 and parsed.source.get($at - 1) != Ok('\n') {
		byte = parsed.source.get($at - 1) ?? crash "ApiSurface: declaration prefix"
		if byte != ' ' and byte != '\t' {
			return ""
		}
		$at = $at - 1
	}
	if $at == 0 {
		return ""
	}
	var $end = $at - 1
	var $doc = []
	var $done = False
	while !$done {
		var $first = $end
		while $first > 0 and parsed.source.get($first - 1) != Ok('\n') {
			$first = $first - 1
		}
		line = (Str.from_utf8(parsed.source.sublist({ start: $first, len: $end - $first })) ?? crash "ApiSurface: preceding line UTF-8").trim()
		if line.starts_with("##") {
			$doc = [line.drop_prefix("##").trim_start()].concat($doc)
		} else {
			$done = True
		}
		if $first == 0 {
			$done = True
		} else {
			$end = $first - 1
		}
	}
	Str.join_with($doc, "\n")
}

## Only a direct type alias has a target; nominal backing records and
## union representations do not publish the members of their backing type.
alias_target : RocSyntax.Parsed, RocSyntax.Node -> Str
alias_target = |parsed, node| {
	parts = children(parsed, node)
	header = parts.find_first(|child| child.kind == TypeHeader) ?? crash "ApiSurface: type declaration has a header"
	for value in parts.keep_if(|child| child.kind != TypeHeader and child.kind != AssociatedBlock and child.kind != WhereClause and child.start >= header.end) {
		operator = Str.from_utf8(parsed.source.sublist({ start: header.end, len: value.start - header.end })) ?? crash "ApiSurface: type operator UTF-8"
		if operator.trim() == ":" {
			return (text(parsed, value).split_on("(").first() ?? "").trim()
		}
	}
	""
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
				$out = $out.append({ name: qualified, doc: documentation(parsed, node.start), alias: alias_target(parsed, node) }).concat(members(parsed, node, qualified))
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
		for decl in source_module.declarations.concat(source_module.auxiliary) {
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
			auxiliary: [],
			declarations: [
				{ name: "Core.Program", doc: "Internal program.", alias: "" },
				{ name: "Core.Program.with_ports", doc: "Register ports.", alias: "" },
				{ name: "Core.driver", doc: "Internal driver.", alias: "" },
			],
		},
		{ name: "Engine", auxiliary: [], declarations: [{ name: "Engine.Program", doc: "An app.", alias: "Core.Program" }] },
	]
	ApiSurface.reachable(modules, [{ name: "Public.App", doc: "The program.", alias: "Engine.Program" }])? == [
		{ name: "Public.App", doc: "The program.", alias: "Engine.Program" },
		{ name: "Public.App.with_ports", doc: "Register ports.", alias: "" },
	]
}

## A cyclic alias cannot make the documentation walk recurse forever.
expect ApiSurface.reachable([{ name: "Cycle", auxiliary: [], declarations: [{ name: "Cycle.Type", doc: "Cycle.", alias: "Cycle.Type" }] }], [{ name: "Public.Type", doc: "Alias.", alias: "Cycle.Type" }]).is_err()

## An internal dependency is detected or rejected as unsupported syntax,
## including escaped spellings. Prose mentioning it is not a dependency.
expect {
	{
		named: ApiSurface.has_internal_dependency("app [main] { cli: platform \"cli.roc\", pf: \"../platform/main-fuzz.roc\" }\nmain = 0")?,
		escaped: match ApiSurface.has_internal_dependency("app [main] { cli: platform \"cli.roc\", pf: \"../platform/main\\u(002d)fuzz.roc\" }\nmain = 0") {
			Ok(False) => False
			_ => True
		},
		prose: ApiSurface.has_internal_dependency("# main-fuzz.roc\nvalue = \"main-fuzz.roc\"")?,
	} == { named: True, escaped: True, prose: False }
}

## Applications, examples' pure fuzzers and ordinary test entry points cannot
## borrow the engine package merely by having a filename resembling a target.
expect {
	["fuzz/table-view/main.roc", "tests/apps/controls/fuzz-controls.roc"].all(ApiSurface.is_platform_target) and ["examples/todos/fuzz-todos.roc", "examples/todos/main.roc", "tests/apps/controls/main.roc", "cli/main.roc"].all(|file| !ApiSurface.is_platform_target(file))
}

## Public aliases inherit file-local methods and their own comments, while
## unrelated private types and helper members stay out of the public surface.
expect {
	source =
		\\Demo := [].{
		\\    ## A public cell.
		\\    Cell(a) : LocalCell(a)
		\\}
		\\LocalCell(a) :: a.{
		\\    ## Read the current value.
		\\    state : LocalCell(a) -> a
		\\    state = |LocalCell.(value)| value
		\\}
		\\Hidden := [].{
		\\    ## An unrelated helper.
		\\    secret = 0
		\\}
	catalogued = ApiSurface.catalogue("Demo", source)?
	ApiSurface.reachable([catalogued], catalogued.declarations)? == [
		{ name: "Demo.Cell", doc: "A public cell.", alias: "Demo#LocalCell" },
		{ name: "Demo.Cell.state", doc: "Read the current value.", alias: "" },
	]
}

## File-local names are scoped to their source file, even when two modules
## use the same implementation name. A private alias chain stays transitive.
expect {
	first = ApiSurface.catalogue("First", "First := [].{ Public : Alias }\nAlias : Shared\nShared :: U64.{ get : Shared -> U64\n get = |Shared.(value)| value }")?
	second = ApiSurface.catalogue("Second", "Second := [].{ Public : Shared }\nShared :: Str.{ text : Shared -> Str\n text = |Shared.(value)| value }")?
	ApiSurface.reachable([first, second], first.declarations)?.map(|decl| decl.name) == ["First.Public", "First.Public.get"] and
		ApiSurface.reachable([first, second], second.declarations)?.map(|decl| decl.name) == ["Second.Public", "Second.Public.text"]
}

## A file-private alias cycle is refused just like a public cycle; it
## cannot silently erase methods from the reachable public catalogue.
expect {
	catalogued = ApiSurface.catalogue("Demo", "Demo := [].{ Public : First }\nFirst : Second\nSecond : First")?
	ApiSurface.reachable([catalogued], catalogued.declarations).is_err()
}
