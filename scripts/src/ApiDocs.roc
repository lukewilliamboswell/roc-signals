import cli.Path
import cli.Http
import cli.Env
import http.Request
import http.Response
import ApiSurface
import Proc
import SpecSuite
import Targets

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

	## Audit tracked and nonignored Roc files, including newly added sources.
	## Generated build trees are outside Git's source list. Only dependencies
	## in parsed headers count; the platform and tooling own their internal use.
	internal_roots! : SpecSuite.Options => Try(List(Str), _)
	internal_roots! = |o| {
		bytes = Proc.capture!({ program: "git", args: ["ls-files", "-z", "--cached", "--others", "--exclude-standard", "--", "*.roc"], cwd: o.root })?
		files = (Str.from_utf8(bytes)?).split_on("\u(0000)").keep_if(|file| !file.is_empty() and !file.starts_with("platform/") and !file.starts_with("scripts/"))
		var $problems = []
		for file in files {
			source = Path.read_utf8!(Path.utf8("${o.root}/${file}"))?
			if ApiSurface.has_internal_dependency(source)? and !(ApiSurface.is_platform_target(file) and Targets.fuzz_targets.any(|target| target.main == file)) {
				$problems = $problems.append("${file}: main-fuzz.roc is internal; only the platform's fuzz targets may name it")
			}
		}
		Ok($problems)
	}

	## Compare against the actual latest published platform bundle. Discovery
	## or extraction failures fail the gate; a self comparison is no baseline.
	bump! : SpecSuite.Options => Try(List(Str), _)
	bump! = |o| {
		request = Request.from_method(GET)
			.with_uri("https://api.github.com/repos/lukewilliamboswell/roc-signals/releases/latest")
			.add_header("Accept", "application/vnd.github+json")
			.add_header("X-GitHub-Api-Version", "2022-11-28")
		with_token = match Env.var_str!("GH_TOKEN") {
			Ok(token) if !token.is_empty() => request.add_header("Authorization", "Bearer ${token}")
			Ok(_) | Err(VarNotFound(_)) => request
			Err(error) => return Err(error)
		}
		response : Response
		response = Http.send!(with_token, {})?
		published = ApiDocs.published_release({ status: response.status(), body: response.body() })?
		bundle = match published.assets.keep_if(|asset| asset.name.ends_with(".tar.zst") and !asset.name.starts_with("signals-")) {
			[asset] => asset.browser_download_url
			_ => return Err(AmbiguousPublishedPlatform(published.tag_name))
		}
		result = Proc.merged!({ program: o.compiler, args: ["bump", "--old", bundle, "platform/main.roc"], cwd: o.root })?
		output = Str.from_utf8_lossy(result.stdout)
		Proc.note!(output)
		Ok(if (result.code == 0) [] else ["roc bump against ${published.tag_name} failed: ${output}"])
	}

	## Refuse an HTTP error before interpreting its body as release metadata.
	## Retain a bounded response excerpt so discovery failures identify the
	## service response instead of reporting an unrelated missing JSON field.
	published_release : { status : U16, body : List(U8) } -> Try({ tag_name : Str, assets : List({ name : Str, browser_download_url : Str }) }, _)
	published_release = |{ status, body }| {
		if status != 200 {
			return Err(PublishedReleaseHttpFailure({ status, body: Str.from_utf8_lossy(body.take_first(2048)) }))
		}
		text = Str.from_utf8(body) ? |_| InvalidPublishedReleaseUtf8
		published = Json.parse(text) ? InvalidPublishedReleaseJson
		Ok(published)
	}

	## Parse module declarations once, retaining the source comments used for
	## both API coverage and inherited-member documentation.
	catalogue! : Str => Try(List(ApiSurface.Module), _)
	catalogue! = |root| {
		var $out = []
		for entry in Path.list!(Path.utf8("${root}/platform"))? {
			file = Path.display(entry)
			if file.ends_with(".roc") {
				name = (file.split_on("/").last() ?? file).drop_suffix(".roc")
				source = Path.read_utf8!(entry)?
				$out = $out.append(ApiSurface.catalogue(name, source)?)
			}
		}
		Ok($out)
	}

	## Document the members an alias publishes, using their original comments.
	## Direct declarations stay on the compiler's module pages. This companion
	## is generated, never a second hand-maintained list of app-facing methods.
	inherited : List(ApiSurface.Module), List(Str) -> Try(Str, _)
	inherited = |catalogue, public| {
		var $sections = []
		for name in public {
			decls = (catalogue.find_first(|entry| entry.name == name)?).declarations
			for decl in ApiSurface.reachable(catalogue, decls)? {
				if !decls.any(|direct| direct.name == decl.name) {
					if decl.doc.is_empty() {
						return Err(MissingInheritedComment(decl.name))
					}
					$sections = $sections.append("### ${decl.name}\n\n${decl.doc}\n")
				}
			}
		}
		Ok(if ($sections.is_empty()) "" else "\n## Methods on aliased types\n\nThese methods are available through the public types named below.\n\n${Str.join_with($sections, "\n")}")
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
		# TODO(roc-lang/roc#13018): the compiler omits alias members.
		# https://github.com/roc-lang/roc/issues/13018
		# Render their source comments through roc-docs' Markdown renderer in
		# the reference's front page and PDF until the compiler includes them.
		root = Path.read_utf8!(Path.utf8("${o.root}/platform/main.roc"))?
		public = ApiDocs.modules(root)?
		catalogue = ApiDocs.catalogue!(o.root)?
		intro = Path.read_utf8!(Path.utf8("${o.root}/www/api/index.md"))?
		input = "${o.build_dir}/api-docs-source"
		SpecSuite.fresh_dir!(input)?
		Path.write_utf8!(Path.utf8("${input}/index.md"), "${intro}${ApiDocs.inherited(catalogue, public)?}")?
		Proc.run!({
			program: "roc-docs",
			args: ["build", "--workspace", ".", "--docs-directory", input.drop_prefix("${o.root}/"), "--entrypoint", "index.md", "--output-directory", relative, "--api-entrypoint", "platform/main.roc", "--roc-command", o.compiler, "--pdf-filename", "roc-signals-api.pdf", "--docs-version", version, "--title", "Roc Signals API", "--site-url", "https://lukewilliamboswell.github.io/roc-signals/api/"],
			cwd: o.root,
		})?
		problems = ApiDocs.rendered!(o, "${out}/site")?
		if problems.is_empty() {
			Ok("${out}/site")
		} else {
			Err(IncompleteGeneratedApi(problems))
		}
	}

	## Inspect the actual generated pages against declarations reachable from
	## main.roc, including inherited alias members. Internal pages and missing
	## comments fail independently of whether the build command succeeded.
	rendered! : SpecSuite.Options, Str => Try(List(Str), _)
	rendered! = |o, site| {
		root = Path.read_utf8!(Path.utf8("${o.root}/platform/main.roc"))?
		public = ApiDocs.modules(root)?
		all_modules = ApiDocs.catalogue!(o.root)?
		manual = Path.read_utf8!(Path.utf8("${site}/index.html"))?
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
			decls = (all_modules.find_first(|entry| entry.name == name)?).declarations
			for decl in ApiSurface.reachable(all_modules, decls)? {
				is_inherited = !decls.any(|direct| direct.name == decl.name)
				if !ApiDocs.has_rendered_comment(html, decl.name) and !(is_inherited and ApiDocs.has_inherited_comment(manual, decl.name)) {
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

	## The generated companion's own heading must have prose before the next
	## heading. A table-of-contents link or a neighbouring comment is not proof.
	has_inherited_comment : Str, Str -> Bool
	has_inherited_comment = |html, name| match html.split_on(">${name}<a class=\"anchor\"") {
		[_, after] => match after.split_on("</h3>") {
			[_, body, ..] => !(body.split_on("<h").first() ?? "").trim().is_empty()
			_ => False
		}
		_ => False
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

## A successful release response preserves the actual asset URLs for the baseline.
expect {
	published = ApiDocs.published_release({ status: 200, body: "{\"tag_name\":\"0.5.0\",\"assets\":[{\"name\":\"platform.tar.zst\",\"browser_download_url\":\"https://example.com/platform.tar.zst\"}]}".to_utf8() })?
	published == { tag_name: "0.5.0", assets: [{ name: "platform.tar.zst", browser_download_url: "https://example.com/platform.tar.zst" }] }
}

## GitHub error responses report their HTTP failure before release JSON decoding.
expect {
	body = "{\"message\":\"API rate limit exceeded\"}"
	ApiDocs.published_release({ status: 403, body: body.to_utf8() }) == Err(PublishedReleaseHttpFailure({ status: 403, body }))
}

## Even release-shaped JSON cannot turn an unsuccessful HTTP response into a baseline.
expect ApiDocs.published_release({ status: 503, body: "{\"tag_name\":\"0.5.0\",\"assets\":[]}".to_utf8() }).is_err()

## A malformed successful response still fails discovery rather than inventing assets.
expect ApiDocs.published_release({ status: 200, body: "{\"message\":\"unexpected response\"}".to_utf8() }).is_err()

## Error diagnostics keep at most two KiB of a service response.
expect {
	match ApiDocs.published_release({ status: 502, body: List.repeat('x', 4096) }) {
		Err(PublishedReleaseHttpFailure(failure)) => failure.status == 502 and failure.body.count_utf8_bytes() == 2048
		_ => False
	}
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

## A companion entry needs its own heading and body; a table-of-contents
## link or the next member's comment cannot conceal missing documentation.
expect {
	good = "<h3 id=\"x\">Engine.Program.with_ports<a class=\"anchor\" href=\"#x\">§</a></h3><p>Declare ports.</p>"
	{ present: ApiDocs.has_inherited_comment(good, "Engine.Program.with_ports"), followed: ApiDocs.has_inherited_comment("${good}${good.replace_each("with_ports", "with_workers")}", "Engine.Program.with_ports"), missing: ApiDocs.has_inherited_comment(good, "Engine.Program.with_workers"), neighbour: ApiDocs.has_inherited_comment("<h3 id=\"x\">Engine.Program.with_ports<a class=\"anchor\" href=\"#x\">§</a></h3>\n".concat(good.replace_each("with_ports", "with_workers")), "Engine.Program.with_ports") } == { present: True, followed: True, missing: False, neighbour: False }
}
