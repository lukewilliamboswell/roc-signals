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
			if ApiSurface.has_internal_dependency(source)? and !(Targets.fuzz_targets.any(|target| ApiSurface.is_platform_target(target.main) and (target.main == file or Targets.package_of(target) == file))) {
				$problems = $problems.append("${file}: main-fuzz.roc is internal; only the platform's fuzz targets may name it")
			}
		}
		Ok($problems)
	}

	## Compare against the actual latest published platform bundle, or the one
	## reviewed repair of it in `baseline_repairs`. Discovery or extraction
	## failures fail the gate; a self comparison is no baseline. A `Release`
	## must also be at least the version the API's changes require
	## (`roc bump --expect`); a `Candidate`, such as a pull request, has no
	## version to hold to that.
	##
	## The working tree's platform is compared as it is first. When `roc bump`
	## refuses it for the reason `candidate_repair` names, the comparison runs
	## again on a copy of `platform/` with that repair's edits made, and the
	## gate prints what it added; a refusal for any other reason fails the
	## gate. When the unrepaired platform extracts, the repair is stale and
	## the gate fails until it is removed. That costs one extra `roc bump` run
	## while the repair is needed (a few seconds: extraction fails before
	## anything is compared), and none once it is gone.
	bump! : SpecSuite.Options, [Candidate, Release(Str)] => Try(List(Str), _)
	bump! = |o, claim| {
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
		old = match ApiDocs.baseline_plan(published.tag_name, ApiDocs.baseline_repairs)? {
			AsPublished => ["--old", bundle]
			Repaired(repair) => {
				root = ApiDocs.repair_baseline!(o, { url: bundle, repair })?
				Proc.note!("API baseline: ${repair.version} as published (sha256 ${repair.sha256}), with one public name added for roc bump: ${repair.reason}")
				["--old", root, "--old-version", repair.version]
			}
		}
		expected = match claim {
			Candidate => []
			Release(version) => ["--expect", version]
		}
		compare! = |root| {
			result = Proc.merged!({ program: o.compiler, args: ["bump"].concat(old).concat(expected).concat([root]), cwd: o.root })?
			Ok({ code: result.code, output: Str.from_utf8_lossy(result.stdout) })
		}
		unrepaired = compare!("platform/main.roc")?
		judged = match ApiDocs.candidate_plan({ code: unrepaired.code, output: unrepaired.output }, ApiDocs.candidate_repair) {
			AsItIs => unrepaired
			StaleCandidateRepair => {
				Proc.note!(unrepaired.output)
				return Ok(["the candidate-side API repair (${ApiDocs.candidate_repair.reason}) is no longer needed: roc bump extracts the unrepaired platform, so remove ApiDocs.candidate_repair"])
			}
			Repair => {
				root = ApiDocs.repair_candidate!(o, ApiDocs.candidate_repair)?
				Proc.note!("API candidate: platform/ with one public module added for roc bump, in a copy (the real platform/main.roc is unchanged): ${ApiDocs.candidate_repair.reason}")
				compare!(root)?
			}
		}
		Proc.note!(judged.output)
		Ok(if (judged.code == 0) [] else ["roc bump against ${published.tag_name} failed: ${judged.output}"])
	}

	## The working tree's platform as `roc bump` must read it: the one public
	## module the copy adds and why, the text that shows `roc bump` refused
	## the unrepaired platform for exactly that reason, and the edits to the
	## copy's root, each of which must occur exactly once.
	CandidateRepair : { reason : Str, refusal : Str, edits : List({ before : Str, after : Str }) }

	## `Wire.Sendable`'s `where` clause names the payload format's types,
	## `WorkerCodec.Format` and the states its hooks pass, because derivation
	## cannot resolve a format's hooks through a public alias
	## (https://github.com/roc-lang/roc/issues/13022), and `WorkerCodec` is
	## not exposed, so that the format's hooks are not public API. `roc bump`
	## refuses to extract an API whose signatures name a type outside it
	## (https://github.com/roc-lang/roc/issues/13080, here on the new side),
	## although `roc check` accepts the platform. The repair exposes
	## `WorkerCodec` in a copy of `platform/`, so the comparison also lists
	## it as an added module, which ships as unexposed.
	candidate_repair : CandidateRepair
	candidate_repair = {
		reason: "WorkerCodec is exposed, since Wire.Sendable's where clause names its types (roc-lang/roc#13022) and roc bump cannot extract an API that names a type from an unexposed module (roc-lang/roc#13080)",
		refusal: "The new package's public API references the type `WorkerCodec.",
		edits: [
			{ before: "Wire, Worker]\n", after: "Wire, WorkerCodec, Worker]\n" },
			{ before: "import Wire\nimport Worker\n", after: "import Wire\nimport Worker\nimport WorkerCodec\n" },
		],
	}

	## What the unrepaired comparison says about the candidate repair: the
	## platform extracts (`AsItIs` when no repair is kept, otherwise the
	## repair is stale) or was refused for the repair's reason (`Repair`).
	## Any other refusal is judged as it is.
	candidate_plan : { code : I32, output : Str }, CandidateRepair -> [AsItIs, Repair, StaleCandidateRepair]
	candidate_plan = |{ code, output }, repair|
		if repair.edits.is_empty() {
			AsItIs
		} else if code == 0 {
			StaleCandidateRepair
		} else if output.contains(repair.refusal) {
			Repair
		} else {
			AsItIs
		}

	## Copy the working tree's platform modules into the build directory and
	## make the candidate repair's edits to the copy's root. Answers the
	## repaired root; `platform/` itself is never written.
	repair_candidate! : SpecSuite.Options, CandidateRepair => Try(Str, _)
	repair_candidate! = |o, repair| {
		dir = "${o.build_dir}/api-candidate/platform"
		SpecSuite.fresh_dir!(dir)?
		for file in SpecSuite.files_with!("${o.root}/platform", ".roc")? {
			Path.copy!(Path.utf8(file), Path.utf8("${dir}/${file.split_on("/").last() ?? file}"))?
		}
		root = "${dir}/main.roc"
		source = Path.read_utf8!(Path.utf8(root))?
		Path.write_utf8!(Path.utf8(root), ApiDocs.repaired_root(source, repair.edits)?)?
		Ok(root)
	}

	## A published release that `roc bump` cannot read as it shipped, and the
	## exact edits to its platform root that let it: each `before` must occur
	## exactly once in the published `main.roc`.
	BaselineRepair : { version : Str, sha256 : Str, reason : Str, edits : List({ before : Str, after : Str }) }

	## The reviewed repairs of published baselines; empty once the latest
	## release is one `roc bump` reads as it shipped.
	##
	## 0.6.0's `Wire.Sendable` constraint names the unexposed `WorkerCodec`
	## types, as the candidate does. The same extraction workaround adds
	## that module to a copy of the published root, without changing the
	## bundle or exposing it to apps. The digest binds the repair to the
	## exact published asset. Upstream:
	## https://github.com/roc-lang/roc/issues/13080. Once 0.6.0 is no longer
	## the latest release, `baseline_plan` fails until this entry is retired.
	baseline_repairs : List(BaselineRepair)
	baseline_repairs = [
		{
			version: "0.6.0",
			sha256: "ea59cb6c5577ed1be8322946edfc1f7b6effcd8160e369de976eeca7d63829e0",
			reason: ApiDocs.candidate_repair.reason,
			edits: ApiDocs.candidate_repair.edits,
		},
	]

	## Which baseline the latest release gives: its bundle as published, or
	## its one reviewed repair. A repair kept for any other release is an
	## error, so an expired repair cannot outlive the release it was for.
	baseline_plan : Str, List(BaselineRepair) -> Try([AsPublished, Repaired(BaselineRepair)], [StaleBaselineRepair({ latest : Str, repaired : Str }), DuplicateBaselineRepair(Str)])
	baseline_plan = |latest, repairs| {
		stale = repairs.drop_if(|repair| repair.version == latest)
		match (repairs.keep_if(|repair| repair.version == latest), stale) {
			([], []) => Ok(AsPublished)
			([repair], []) => Ok(Repaired(repair))
			(_, [repair, ..]) => Err(StaleBaselineRepair({ latest, repaired: repair.version }))
			(_, []) => Err(DuplicateBaselineRepair(latest))
		}
	}

	## The published platform root with a repair's edits made, refusing any
	## edit whose text does not occur exactly once.
	repaired_root : Str, List({ before : Str, after : Str }) -> Try(Str, [BaselineEditDoesNotApply(Str)])
	repaired_root = |source, edits|
		edits.fold_until(
			Ok(source),
			|result, edit| match result {
				Ok(text) => match text.split_on(edit.before) {
					[head, tail] => Continue(Ok("${head}${edit.after}${tail}"))
					_ => Break(Err(BaselineEditDoesNotApply(edit.before)))
				}
				Err(error) => Break(Err(error))
			},
		)

	## Download the published bundle, refuse it unless its SHA-256 is the one
	## recorded with the repair, unpack it and make the repair's edits.
	## Answers the repaired platform root, under the build directory.
	repair_baseline! : SpecSuite.Options, { url : Str, repair : BaselineRepair } => Try(Str, _)
	repair_baseline! = |o, { url, repair }| {
		dir = "${o.build_dir}/api-baseline/${repair.version}"
		SpecSuite.fresh_dir!("${dir}/package")?
		Proc.run!({ program: "curl", args: ["-fsSL", "-o", "${dir}/bundle.tar.zst", url], cwd: o.root })?
		digest = Str.from_utf8_lossy(Proc.capture!({ program: "sha256sum", args: ["${dir}/bundle.tar.zst"], cwd: o.root })?).split_on(" ").first() ?? ""
		if digest != repair.sha256 {
			return Err(BaselineBundleChanged({ version: repair.version, recorded: repair.sha256, downloaded: digest }))
		}
		Proc.run!({ program: "zstd", args: ["-q", "-d", "-f", "-o", "${dir}/bundle.tar", "${dir}/bundle.tar.zst"], cwd: o.root })?
		Proc.run!({ program: "tar", args: ["-xf", "${dir}/bundle.tar", "-C", "${dir}/package"], cwd: o.root })?
		root = "${dir}/package/main.roc"
		source = Path.read_utf8!(Path.utf8(root))?
		Path.write_utf8!(Path.utf8(root), ApiDocs.repaired_root(source, repair.edits)?)?
		Ok(root)
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

## The latest release takes its reviewed repair, a release without one is
## compared as published, and a repair kept past its release fails.
expect {
	repair = { version: "0.5.0", sha256: "00", reason: "r", edits: [] }
	actual =
		\\current: ${Str.inspect(ApiDocs.baseline_plan("0.5.0", [repair]))}
		\\none: ${Str.inspect(ApiDocs.baseline_plan("0.6.0", []))}
		\\stale: ${Str.inspect(ApiDocs.baseline_plan("0.6.0", [repair]))}
		\\twice: ${Str.inspect(ApiDocs.baseline_plan("0.5.0", [repair, repair]))}
	expected =
		\\current: Ok(Repaired({ edits: [], reason: "r", sha256: "00", version: "0.5.0" }))
		\\none: Ok(AsPublished)
		\\stale: Err(StaleBaselineRepair({ latest: "0.6.0", repaired: "0.5.0" }))
		\\twice: Err(DuplicateBaselineRepair("0.5.0"))
	actual == expected
}

## 0.6.0's repair adds exactly `WorkerCodec` to the exposed modules of its
## published root, and nothing else.
expect {
	repair = ApiDocs.baseline_repairs.find_first(|r| r.version == "0.6.0")?
	published = "platform \"\"\n\trequires {}\n\texposes [Clipboard, Engine, Files, Html, Layout, Order, Port, PortJson, Svg, Url, Web, Wire, Worker]\n\tpackages {}\n\tprovides {}\nimport Core\nimport Wire\nimport Worker\n"
	repaired = ApiDocs.repaired_root(published, repair.edits)?
	{ before: ApiDocs.modules(published)?, after: ApiDocs.modules(repaired)? } == { before: ["Clipboard", "Engine", "Files", "Html", "Layout", "Order", "Port", "PortJson", "Svg", "Url", "Web", "Wire", "Worker"], after: ["Clipboard", "Engine", "Files", "Html", "Layout", "Order", "Port", "PortJson", "Svg", "Url", "Web", "Wire", "WorkerCodec", "Worker"] }
}

## An edit whose text is missing or repeated refuses the baseline rather
## than comparing against a root the repair was not reviewed for.
expect {
	edit = { before: "import Engine\n", after: "import Engine\nimport EngineOnly\n" }
	{
		missing: ApiDocs.repaired_root("import Html\n", [edit]),
		twice: ApiDocs.repaired_root("import Engine\nimport Engine\n", [edit]),
	} == { missing: Err(BaselineEditDoesNotApply("import Engine\n")), twice: Err(BaselineEditDoesNotApply("import Engine\n")) }
}

## The candidate repair adds exactly `WorkerCodec` to the exposed modules of
## the working tree's root, and imports it, and nothing else.
expect {
	root = "platform \"\"\n\trequires {}\n\texposes [Clipboard, Engine, Files, Html, Layout, Order, Port, PortJson, Svg, Url, Web, Wire, Worker]\n\tpackages {}\n\tprovides {}\nimport Url\nimport Wire\nimport Worker\n"
	repaired = ApiDocs.repaired_root(root, ApiDocs.candidate_repair.edits)?
	added = ApiDocs.modules(repaired)?.drop_if(|name| ApiDocs.modules(root).map_ok(|names| names.contains(name)) == Ok(True))
	added == ["WorkerCodec"] and repaired.contains("import Worker\nimport WorkerCodec\n") and repaired.replace_each("WorkerCodec, ", "").replace_each("import WorkerCodec\n", "") == root
}

## The candidate repair is refused on a root it was not reviewed for, as
## the baseline repair is.
expect {
	moved = "platform \"\"\n\texposes [Engine, Worker, Wire]\nimport Worker\nimport Wire\n"
	ApiDocs.repaired_root(moved, ApiDocs.candidate_repair.edits) == Err(BaselineEditDoesNotApply("Wire, Worker]\n"))
}

## The repair runs only after roc bump refused the platform for its reason;
## a platform that extracts makes it stale, and another refusal is judged
## as it is.
expect {
	repair = ApiDocs.candidate_repair
	refused = "── ✗ cannot extract public api\n${repair.refusal}Format`, which is\nnot itself part of the exposed API.\n"
	{
		needed: ApiDocs.candidate_plan({ code: 1, output: refused }, repair),
		stale: ApiDocs.candidate_plan({ code: 0, output: "This is a MAJOR change." }, repair),
		other: ApiDocs.candidate_plan({ code: 1, output: "The new package (platform/main.roc) does not compile" }, repair),
		none: ApiDocs.candidate_plan({ code: 0, output: "" }, { ..repair, edits: [] }),
	} == { needed: Repair, stale: StaleCandidateRepair, other: AsItIs, none: AsItIs }
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
