import cli.Path
import cli.Http
import ApiSurface
import Proc
import SpecSuite

## Build the authoring API from the platform root, and check its source
## comments, public reachability and rendered members together.
ApiDocs := [].{

	## The platform root is the authority for the app-facing module list.
	## The shared syntax parser reads its exposes clause; comments, imports
	## and strings elsewhere cannot add apparent modules.
	modules : Str -> Try(List(Str), [BadExposes])
	modules = |source| {
		names = ApiSurface.modules(source).map_err(|_| BadExposes)?
		if names.any(|name| !ApiDocs.is_module_name(name)) {
			Err(BadExposes)
		} else {
			Ok(names)
		}
	}

	## A module name is one uppercase ASCII identifier, never a path or code.
	is_module_name : Str -> Bool
	is_module_name = |name| match name.to_utf8() {
		[first, .. as rest] => first >= 'A' and first <= 'Z' and rest.all(|byte| (byte >= 'a' and byte <= 'z') or (byte >= 'A' and byte <= 'Z') or (byte >= '0' and byte <= '9') or byte == '_')
		[] => False
	}

	## Compare against the actual latest published platform bundle. Discovery
	## or extraction failures fail the gate; a self comparison is no baseline.
	bump! : SpecSuite.Options => Try(List(Str), _)
	bump! = |o| {
		published : { tag_name : Str, assets : List({ name : Str, browser_download_url : Str }) }
		published = Http.get!("https://api.github.com/repos/lukewilliamboswell/roc-signals/releases/latest", {})?
		bundle = match published.assets.keep_if(|asset| asset.name.ends_with(".tar.zst") and !asset.name.starts_with("signals-")) {
			[asset] => asset.browser_download_url
			_ => return Err(AmbiguousPublishedPlatform(published.tag_name))
		}
		result = Proc.merged!({ program: o.compiler, args: ["bump", "--old", bundle, "platform/main.roc"], cwd: o.root })?
		output = Str.from_utf8_lossy(result.stdout)
		Proc.note!(output)
		Ok(if (result.code == 0) [] else ["roc bump against ${published.tag_name} failed: ${output}"])
	}

	## Build the API docs; the site is `<build_dir>/api-docs/site`.
	build! : SpecSuite.Options, Str => Try(Str, _)
	build! = |o, version| {
		out = "${o.build_dir}/api-docs"
		# roc-docs takes its output directory relative to the workspace.
		relative = if (out.starts_with("${o.root}/")) out.drop_prefix("${o.root}/") else return Err(BuildDirOutsideWorkspace(out))
		if Path.exists!(Path.utf8(out))? {
			Path.delete_all!(Path.utf8(out))?
		}
		Proc.run!({
			program: "roc-docs",
			args: ["build", "--workspace", ".", "--docs-directory", "www/api", "--entrypoint", "index.md", "--output-directory", relative, "--api-entrypoint", "platform/main.roc", "--roc-command", o.compiler, "--pdf-filename", "roc-signals-api.pdf", "--docs-version", version, "--title", "Roc Signals API", "--site-url", "https://lukewilliamboswell.github.io/roc-signals/api/"],
			cwd: o.root,
		})?
		Ok("${out}/site")
	}

	## Inspect the actual generated pages against declarations reachable from
	## main.roc, including inherited alias members. Internal pages and missing
	## comments fail independently of whether the build command succeeded.
	rendered! : SpecSuite.Options, Str => Try(List(Str), _)
	rendered! = |o, site| {
		root = Path.read_utf8!(Path.utf8("${o.root}/platform/main.roc"))?
		public = ApiDocs.modules(root)?
		var $modules = []
		for entry in Path.list!(Path.utf8("${o.root}/platform"))? {
			file = Path.display(entry)
			if file.ends_with(".roc") {
				name = (file.split_on("/").last() ?? file).drop_suffix(".roc")
				source = Path.read_utf8!(entry)?
				$modules = $modules.append({ name, declarations: ApiSurface.declarations(name, source)? })
			}
		}
		var $problems = []
		for entry in Path.list!(Path.utf8("${site}/api"))? {
			if Path.is_dir!(entry)? {
				name = Path.display(entry).split_on("/").last() ?? ""
				if !public.contains(name) {
					$problems = $problems.append("internal module rendered as an API page: ${name}")
				}
			}
		}
		for name in public {
			html = Path.read_utf8!(Path.utf8("${site}/api/${name}/index.html"))?
			decls = ($modules.find_first(|entry| entry.name == name)?).declarations
			for decl in ApiSurface.reachable($modules, decls)? {
				if !ApiDocs.has_rendered_comment(html, decl.name) {
					$problems = $problems.append("API member missing or undocumented in generated HTML: ${decl.name}")
				}
			}
		}
		Ok($problems)
	}

	## The pinned generator's entry anchor must own a nonempty doc section.
	## Links elsewhere on the page cannot satisfy the member coverage check.
	has_rendered_comment : Str, Str -> Bool
	has_rendered_comment = |html, name| match html.split_on("id=\"${name}\"") {
		[_, after] => {
			entry = after.split_on("<article").first() ?? ""
			match entry.split_on("<div class=\"entry-doc\">") {
				[_, doc] => !((doc.split_on("</div>").first() ?? "").trim().is_empty())
				_ => False
			}
		}
		_ => False
	}

	## The public items of the module `name` that have no `##` doc comment:
	## every declaration inside the block of the module's own type, at any
	## depth, whose preceding line is not a doc comment. The block opens
	## where the type's line ends in `.{` (`Name := [].{`), or, for a type
	## written as a record (`Name(a) :: {`), at the `}.{` that closes its
	## fields. Another type at the file's top level is private and is not
	## scanned. Record fields (which end in a comma) and continuation lines
	## are not declarations.
	undocumented : Str, Str -> List(Str)
	undocumented = |name, source| {
		var $out = []
		var $at = Outside
		var $previous = ""
		for line in source.split_on("\n") {
			ending = line.trim_end()
			match $at {
				Outside => {
					own = line.starts_with("${name} ") or line.starts_with("${name}(")
					$at = if (own and ending.ends_with(".{")) Inside else if (own and ending.ends_with("{")) Fields else Outside
				}
				Fields => {
					$at = if (ending == "}.{") Inside else if (ending == "}") Outside else Fields
				}
				Inside => {
					if line == "}" {
						$at = Outside
					} else if ApiDocs.is_declaration(line) and !$previous.trim().starts_with("##") {
						$out = $out.append(line.trim())
					}
				}
			}
			$previous = line
		}
		$out
	}

	## A line that declares a value's type or a type: `name : ...` or
	## `Name(args) :` / `:=` at the start of an indented line.
	is_declaration : Str -> Bool
	is_declaration = |line| {
		trimmed = line.trim_start()
		if !line.starts_with("\t") or trimmed.ends_with(",") or trimmed.starts_with("#") {
			Bool.False
		} else {
			match trimmed.split_on(" :") {
				[head, _, ..] => !head.is_empty() and !head.contains(" ") and !head.contains(".") and !head.contains("{") and !head.contains("[")
				_ => Bool.False
			}
		}
	}

	## Problems: one per undocumented public symbol.
	check! : {} => Try(List(Str), _)
	check! = |_| {
		var $problems = []
		root = Path.read_utf8!(Path.utf8("platform/main.roc"))?
		for module_name in ApiDocs.modules(root)? {
			if !(Path.is_file!(Path.utf8("platform/${module_name}.roc"))?) {
				$problems = $problems.append("exposed module ${module_name} has no source file")
			}
		}
		for entry in Path.list!(Path.utf8("platform"))? {
			file = Path.display(entry)
			if file.ends_with(".roc") {
				source = Path.read_utf8!(Path.utf8(file))?
				name = (file.split_on("/").last() ?? file).drop_suffix(".roc")
				for item in ApiSurface.declarations(name, source)? {
					if item.doc.is_empty() {
						$problems = $problems.append("${file}: symbol without a ## doc comment: ${item.name}")
					}
				}
			}
		}
		Ok($problems)
	}
}

## Documented items pass; an undocumented one, at any depth, is reported.
expect {
	source =
		\\import Engine
		\\
		\\Html := [].{
		\\	## A box.
		\\	div : Str -> Elem(ctx)
		\\	div = |c| x
		\\
		\\	span : Str -> Elem(ctx)
		\\	span = |c| x
		\\
		\\	## A record type.
		\\	Rec : {
		\\		field : Str,
		\\	}
		\\
		\\	Signal(a) := { read : a }.{
		\\		map : Signal(a) -> Signal(a)
		\\		map = |v| v
		\\	}
		\\}
		\\
		\\private : Str
		\\private = ""
	ApiDocs.undocumented("Html", source) == ["span : Str -> Elem(ctx)", "Signal(a) := { read : a }.{", "map : Signal(a) -> Signal(a)"]
}

## A type written as a record with its methods after it is scanned from the
## `}.{` that opens them: its fields are not symbols, its methods are. A
## private type below it is not the module's and is not scanned.
expect {
	source =
		\\## A table.
		\\Table(k, v) :: {
		\\	rows : Dict(k, v),
		\\	version : U64,
		\\}.{
		\\
		\\	## The number of rows.
		\\	len : Table(k, v) -> U64
		\\	len = |table| table.rows.len()
		\\
		\\	get : Table(k, v), k -> Try(v, [Missing])
		\\		where [k.is_eq : k, k -> Bool]
		\\	get = |table, key| table.rows.get(key)
		\\}
		\\
		\\rows_of : List(k) -> Dict(k, v)
		\\rows_of = |entries| x
		\\
		\\Sample := { n : U64 }.{
		\\	is_eq : _
		\\}
	ApiDocs.undocumented("Table", source) == ["get : Table(k, v), k -> Try(v, [Missing])"]
}

## The root list can span lines and carry comments; names are not duplicated
## by a manually maintained tooling catalogue.
expect {
	source = "platform \"\"\n requires { main : U64 }\n exposes [Engine, # prose\n Html, Worker]\n packages {}\n provides {}"
	ApiDocs.modules(source)? == ["Engine", "Html", "Worker"]
}

## Missing clauses, duplicate names and path-like entries cannot quietly
## change which modules the documentation checker treats as public.
expect {
	["platform \"\"", "exposes []", "exposes [Engine, Engine]", "exposes [../Core]", "exposes [engine]", "exposes [Engine] exposes [Core]"].all(|source| ApiDocs.modules(source).is_err())
}

## A sidebar link, absent prose, and another entry's comment do not prove a
## member is documented. Its own anchor and doc section are both required.
expect {
	good = "<article id=\"Engine.Table.put\"><div class=\"entry-doc\"><p>Replace a row.</p></div></article>"
	{ present: ApiDocs.has_rendered_comment(good, "Engine.Table.put"), missing: ApiDocs.has_rendered_comment(good, "Engine.Table.remove"), empty: ApiDocs.has_rendered_comment("<article id=\"Engine.Table.put\"><div class=\"entry-doc\"> \n </div></article>", "Engine.Table.put"), borrowed: ApiDocs.has_rendered_comment("<article id=\"Engine.Table.put\"></article>".concat(good.replace_each("Engine.Table.put", "Engine.Table.remove")), "Engine.Table.put") } == { present: True, missing: False, empty: False, borrowed: False }
}
