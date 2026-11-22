import cli.Path
import PlatformTest
import Proc
import SpecSuite
import ToolRelease
import Targets

## What a release publishes, built the same way for a dry run (in `check`)
## and for the release workflow:
##
## - the platform bundle, `<hash>.tar.zst`: one platform for both targets,
##   `platform/main.roc` with every module it uses, the Wasm host, the native
##   spec runner's link inputs for every system it builds for (Linux
##   x86-64, macOS on Apple silicon and Intel, Windows x86-64),
##   `runtime.mjs`, its fact readers `environment.mjs`, startup binder
##   `startup.mjs` and `worker.mjs`;
## - `runtime.mjs`, `environment.mjs`, `startup.mjs` and `worker.mjs` on their own, for pages that load an app
##   (the runtime loads the worker script from beside itself);
## - the `signals.roc` tool: its package, `signals-<hash>.tar.zst` (`cli/`
##   with the runtime files, the scaffold and a generated `Bundle.roc`
##   naming this release), and `signals.roc`, the small app an app's author
##   downloads to run it;
## - the examples archive, `roc-signals-examples-<version>.zip`, which the
##   shared nightly-compatibility runner builds with the latest Roc nightly:
##   each example's `main.roc` naming the bundle's release URL, with its
##   modules, its specs and its own files beside them (the JavaScript its
##   author wrote, a page that mounts it, data it downloads), the JavaScript
##   several examples share in `examples/shared/`, a `spec.json`
##   and the `runtime/check.mjs` helper that mounts each app;
## - `release-notes.md`, the draft release's body.
Release := [].{
	repo_url = "https://github.com/lukewilliamboswell/roc-signals"

	## The platform files a bundle carries, relative to `platform/`.
	bundle_files : List(Str)
	bundle_files = ["main.roc", "Base64.roc", "Engine.roc", "Web.roc", "Spelling.roc", "MarkupAdvice.roc", "MarkupLiteral.roc", "Clipboard.roc", "WebCrypto.roc", "Html.roc", "Svg.roc", "Layout.roc", "Order.roc", "Url.roc", "Worker.roc", "Wire.roc", "WorkerCodec.roc", "Port.roc", "PortJson.roc", "PortRegistry.roc", "Protocol.roc", "ProtocolFacts.roc", "Core.roc", "ReadyIndex.roc", "EntryRoutes.roc", "SignalCore.roc", "TableCore.roc", "View.roc", "Seq.roc", "Sig.roc", "FxCore.roc", "Effects.roc", "Files.roc", "Hosted.roc", "Cli.roc", "SpecRunner.roc", "PicturePage.roc", "Scm.roc", "Dom.roc", "JsonOut.roc", "host/crypto.zig", "host/crypto_result.zig", "host/crypto_abi.zig", "targets/wasm32/host.wasm"].concat(PlatformTest.spec_inputs).concat(SpecSuite.runtime_files)

	archive_name : Str -> Str
	archive_name = |version| "roc-signals-examples-${version}"

	## The examples archive omits an example's fuzz targets of its own logic
	## (`fuzz-<subject>.roc`), which depend on a roc-fuzz release rather than
	## on the released platform.
	is_archived : Str -> Bool
	is_archived = |file| {
		name = file.split_on("/").last() ?? file
		!(name.starts_with("fuzz-") and name.ends_with(".roc")) and !Targets.fuzz_targets.any(|member| member.property == file)
	}

	## An example's own files beside its Roc modules, directly in `dir`: the
	## JavaScript its author wrote (port handlers, a custom element), a page
	## that mounts the app with them, data the app downloads. They are the
	## app's, not the platform's, so they travel with the example.
	own_files! : Str => Try(List(Str), _)
	own_files! = |dir| {
		var $out = []
		for entry in Path.list!(Path.utf8(dir))? {
			name = Path.display(entry)
			if !Path.is_dir!(entry)? and !name.ends_with(".roc") {
				$out = $out.append(name)
			}
		}
		Ok($out.sort_with(|a, b| SpecSuite.compare_str(a, b)))
	}

	## An example's entry point with the working-tree platform path
	## replaced by the released bundle.
	released_main : Str, Str -> Try(Str, [NoPlatformPath])
	released_main = |source, bundle_url| {
		local = "platform \"../../platform/main.roc\""
		if (source.contains(local)) Ok(source.replace_each(local, "platform \"${bundle_url}\"")) else Err(NoPlatformPath)
	}

	## A JSON string literal.
	json_str : Str -> Str
	json_str = |s| {
		escaped = s.replace_each("\\", "\\\\").replace_each("\"", "\\\"").replace_each("\n", "\\n").replace_each("\t", "\\t")
		"\"${escaped}\""
	}

	## The suite contract the shared runner reads: one wasm32 case per app,
	## run by the archive's own `check.mjs`.
	spec_json : Str, Str, List({ example : Str, stdout : Str }) -> Str
	spec_json = |version, bundle_url, apps| {
		entries = apps.map(
			|{ example, stdout }|
				"    {\"path\": ${Release.json_str("examples/${example}/main.roc")}, \"target\": \"wasm32\", \"run\": [\"node\", \"{suite}/runtime/check.mjs\", \"{executable}\"], \"cases\": [{\"name\": \"mount\", \"args\": [], \"stdin\": \"\", \"stdout\": ${Release.json_str(stdout)}, \"stderr\": \"\", \"exit_code\": 0}]}",
		)
		"{\n  \"schema_version\": 1,\n  \"release\": ${Release.json_str(version)},\n  \"dependencies\": [${Release.json_str(bundle_url)}],\n  \"apps\": [\n${Str.join_with(entries, ",\n")}\n  ]\n}\n"
	}

	## Build every release asset into `out` (emptied first) for `version`.
	## The examples' browser builds must already exist (`SpecSuite.build!`),
	## so the caller prepares the platform inputs before building them.
	## Returns problems found while testing the assets.
	build! : SpecSuite.Options, Str, Str => Try(List(Str), _)
	build! = |o, version, out| {
		SpecSuite.fresh_dir!(out)?
		SpecSuite.build_web_platform!(o)?
		PlatformTest.prepare!({ root: o.root, build_dir: o.build_dir, zig: o.zig })?
		Proc.run!({ program: o.compiler, args: ["bundle"].concat(Release.bundle_files).concat(["--output-dir", out]), cwd: "${o.root}/platform" })?
		bundle = match SpecSuite.files_with!(out, ".tar.zst")? {
			[one] => one.split_on("/").last() ?? one
			found => return Err(BundleNotFound(Str.inspect(found)))
		}
		SpecSuite.copy_runtime!(o.root, out)?
		bundle_url = "${Release.repo_url}/releases/download/${version}/${bundle}"
		compiler = Str.from_utf8_lossy(Proc.capture!({ program: o.compiler, args: ["version"], cwd: o.root })?).trim()
		ToolRelease.build!(o, { version, download_url: "${Release.repo_url}/releases/download/${version}", platform_url: bundle_url, bundle_files: Release.bundle_files, nightly: compiler.split_on(" ").last() ?? compiler }, out)?

		# The examples archive.
		name = Release.archive_name(version)
		stage = "${o.build_dir}/release-stage"
		root = "${stage}/${name}"
		SpecSuite.fresh_dir!(stage)?
		Path.create_all!(Path.utf8("${root}/runtime"))?
		SpecSuite.copy_runtime!(o.root, "${root}/runtime")?
		Path.copy!(Path.utf8("${o.root}/tests/release/check.mjs"), Path.utf8("${root}/runtime/check.mjs"))?
		var $problems = []
		var $cases = []
		for example in SpecSuite.apps {
			dir = "${root}/examples/${example}"
			Path.create_all!(Path.utf8(dir))?
			for file in SpecSuite.roc_files!("examples/${example}")?.keep_if(Release.is_archived) {
				target = "${dir}/${file.split_on("/").last() ?? file}"
				if file.ends_with("/main.roc") {
					source = Path.read_utf8!(Path.utf8(file))?
					released = Release.released_main(source, bundle_url) ? |_| NoPlatformPath(file)
					Path.write_utf8!(Path.utf8(target), released)?
				} else {
					Path.copy!(Path.utf8(file), Path.utf8(target))?
				}
			}
			for file in Release.own_files!("examples/${example}")? {
				Path.copy!(Path.utf8(file), Path.utf8("${dir}/${file.split_on("/").last() ?? file}"))?
			}
			Path.create_all!(Path.utf8("${dir}/specs"))?
			for spec in SpecSuite.files_with!("examples/${example}/specs", ".scm")? {
				Path.copy!(Path.utf8(spec), Path.utf8("${dir}/specs/${spec.split_on("/").last() ?? spec}"))?
			}
			{ code, stdout } = Proc.output!({ program: o.node, args: ["tests/release/check.mjs", SpecSuite.wasm_of(o, example), SpecSuite.runtime], cwd: o.root })?
			if code != 0 {
				$problems = $problems.append("release: ${example} does not mount: ${Str.from_utf8_lossy(stdout)}")
			}
			$cases = $cases.append({ example, stdout: Str.from_utf8_lossy(stdout) })
		}
		# JavaScript several examples load (a custom element), kept once.
		Path.create_all!(Path.utf8("${root}/examples/shared"))?
		for file in Release.own_files!("examples/shared")? {
			Path.copy!(Path.utf8(file), Path.utf8("${root}/examples/shared/${file.split_on("/").last() ?? file}"))?
		}
		Path.write_utf8!(Path.utf8("${root}/spec.json"), Release.spec_json(version, bundle_url, $cases))?
		Path.write_utf8!(Path.utf8("${root}/README.md"), Release.archive_readme(version))?
		Proc.run!({ program: "zip", args: ["-q", "-r", "-X", "${out}/${name}.zip", name], cwd: stage })?

		tooling = Str.from_utf8_lossy(Proc.capture!({ program: o.tooling, args: ["version"], cwd: o.root })?).trim()
		Path.write_utf8!(Path.utf8("${out}/release-notes.md"), Release.notes(version, bundle_url, { compiler, tooling }))?
		Proc.note!("release ${version}: ${out}")
		Ok($problems)
	}

	archive_readme : Str -> Str
	archive_readme = |version|
		\\# Roc Signals ${version} examples
		\\
		\\The examples of Roc Signals ${version}, each naming that release's platform
		\\bundle. Build one for the browser with
		\\`roc build --target=wasm32 examples/<app>/main.roc`, or its native spec
		\\runner with `roc build --target=x64musl examples/<app>/main.roc` (or
		\\`arm64mac`, `x64mac`, `x64win`) and run it on `examples/<app>/specs/*.scm`.
		\\An example's other files are its own: JavaScript its author wrote (port
		\\handlers, a simulated service), a page that mounts it, data it downloads.
		\\JavaScript several examples load (custom elements) is in `examples/shared/`.
		\\The platform's `runtime.mjs`, `environment.mjs`, `startup.mjs` and `worker.mjs` are separate release assets.
		\\`spec.json` and `runtime/check.mjs` are the compatibility suite the
		\\nightly workflow runs against the latest Roc nightly.

	## The draft release body. The maintainer writes the narrative on GitHub
	## before publishing; both compilers and the platform URL are filled in here.
	notes : Str, Str, { compiler : Str, tooling : Str } -> Str
	notes = |version, bundle_url, { compiler, tooling }|
		\\# Roc Signals ${version}
		\\
		\\<!-- What changed, for app authors. Write this on GitHub before publishing. -->
		\\
		\\## Deterministic startup and deferred content
		\\
		\\`Engine.entries` supplies one finite typed route catalogue. New sites use `Engine.program_startup` or `Engine.program_startup_store`; `signals.roc build` prerenders every declared entry by default. Serve matching generated HTML and module assets together. `--no-prerender` builds a plain page; existing Boot-dependent initializers must migrate before using annotated startup.
		\\
		\\Ordinary initial content survives startup. `Html.placeholder` combines checked `Html.Static` content with a deferred live body; readiness and browser-task opportunities activate it through ordinary scoped turns. Use `Engine.environment` for live browser facts after startup. Protocol 23 requires rebuilding modules and deploying their matching runtime files together.
		\\
		\\The compiler infers the store's type from `main`; a separate app-level `Store` declaration is no longer required. This needs a Roc compiler containing roc-lang/roc#13142.
		\\
		\\Port JSON refuses repeated decoded dictionary property names, including names written with different JSON escapes. Handwritten port codecs pass decoder cursors returned by the format's hooks; applications cannot construct a cursor themselves.
		\\
		\\## Compiler compatibility and contributor checks
		\\
		\\On `nightly-2026-11-18-a520eed` and `nightly-2026-11-19-54c51c9`, `signals.roc` builds requested development Wasm with `--opt=size` to avoid unwanted native imports in browser workers ([roc#13195](https://github.com/roc-lang/roc/issues/13195)). It prints the skipped profile and the actual profile; all behavior checks still run. Rebuilds take longer while this workaround is active. Other compiler versions retry the requested profile.
		\\
		\\Checked markup uses published roc-parser 6.0.0-rc.5. Contributor fuzz checks use roc-fuzz 0.7.0 suites, sharing builds while retaining each property's examples, corpus and strict leak checks. Compiler workarounds carry upstream TODOs and remain separate from application semantics.
		\\
		\\## Breaking: checked links and typed clicks
		\\
		\\`Html.link` now requires `Web.Link`. Literal destinations are checked during compilation; computed destinations use `Web.Link.from_str` and explicitly handle `UnsupportedScheme`. `Html.href` and `Html.href_s` support custom layouts and explicit absence. Raw attributes keep their semantics.
		\\
		\\`Engine.on_click` and button helpers receive `Engine.Click`, carrying modifiers and nearest-link authored href, target and download presence. Use `on_click_with` for synchronous policies. Generic `on("click", ...)` retains its text payload. Rebuild modules with this release's protocol 23 runtime, startup helper and worker.
		\\
		\\`Html.unsafe_html` imports HTML into a stable wrapper without escaping, validation or sanitization. Imported descendants are opaque to specs and receive no engine lifecycle. Pictures containing the wrapper are refused, including empty initial content.
		\\
		\\## Debug output
		\\
		\\A deployed app containing `dbg` now prints its values on the browser console. Remove each `dbg` before deploying; optimized builds retain it and warn. Mount with `dbg: "off"` to silence values and keep them off faults, but formatting still costs work.
		\\
		\\## Upgrading specs
		\\
		\\A step that passes because the thing it names is absent, or counts zero of it, now needs evidence that the name is spelt right. A spec without it fails to parse at that step, in both runners and `--emit-steps`, even if it passed before. The evidence is another step of the same spec, before or after, or a marker saying the story never has the thing. A marker requires positive evidence in another spec of the app's suite, and is refused when its own story already has that evidence.
		\\
		\\- `(expect-absent LOC)` needs a step that requires `LOC` to match, such as `expect-visible` or `click`. Add one where the story draws the element, or write `(expect-absent LOC :never-drawn)`.
		\\- `(expect-no-attr LOC NAME)` needs an `expect-attr` or `expect-has-attr` of `NAME`, on any locator. Add `(expect-has-attr LOC NAME)` where the story writes the attribute with a value the spec cannot state, or write `(expect-no-attr LOC NAME :never-written)`.
		\\- `(expect-cleanup NAME 0)` needs an `expect-cleanup` count of at least one for `NAME`, or write `(expect-cleanup NAME 0 :never-runs)`.
		\\- `(expect-interval MS 0)` and `(tick-interval-if-active MS)` need a `tick-interval MS` or an `expect-interval MS` count of at least one, or end with `:never-started`.
		\\
		\\A port, worker task or media query that a step names must be one the program declares, of the kind the step uses, and a key in `expect-no-local-storage` or `expect-no-session-storage` one the program declares or the spec seeds or shows. These fail the same way, at the step, before anything runs; correct the name.
		\\
		\\## Upgrading worker payloads
		\\
		\\`Wire.encode`, `Wire.try_encode` and `Wire.decode` are removed, with `Wire`'s format types. Worker tasks keep deriving their codecs through `Wire.Sendable` and need no change. An app that wrote CBOR bytes of its own with them depends on roc-cbor instead and chooses its own schema and persistence contract.
		\\
		\\## Use this release
		\\
		\\```roc
		\\app [main] { pf: platform "${bundle_url}" }
		\\```
		\\
		\\Load apps with this release's `runtime.mjs`, served beside `environment.mjs`, `startup.mjs` and `worker.mjs`.
		\\
		\\## Start an app
		\\
		\\```sh
		\\curl -LO ${Release.repo_url}/releases/download/${version}/signals.roc
		\\roc signals.roc init my-app
		\\```
		\\
		\\`signals.roc` creates, serves, builds and tests an app on this release.
		\\
		\\## Compilers
		\\
		\\- Built and tested with `${compiler}`, the latest Roc nightly when the release
		\\  was built.
		\\- Release tooling ran on `${tooling}` (`roc-stable`).
		\\${Release.store_ownership}

	## What the platform cannot yet promise about in-place writes, under every
	## compiler a release can be built with: the compiler limitations that
	## `design.md` lists for roc-lang/roc#12957 and #13012. It is in every
	## release's notes while those limitations are, and is removed, with its
	## `expect`, in the commit that removes their rows from `design.md`.
	store_ownership : Str
	store_ownership =
		\\
		\\## Store ownership
		\\
		\\The instance holds its store as plain data beside its sites and moves it through each turn. A check compares the bytes a sparse write requests at two sizes, in a development and a shipping (`--opt=size`) build: a write of one element of a list in a store cell, and a small write, are in place in both. In a shipping build a keyed write of a table still copies the table's rows ([roc-lang/roc#12957](https://github.com/roc-lang/roc/issues/12957)), and in both builds a write of a local state's value copies it, because a site's boxed closure captures it ([roc-lang/roc#13012](https://github.com/roc-lang/roc/issues/13012)). These are compiler limitations, not different reactive semantics.
}

## Examples name the released bundle instead of the working tree.
expect {
	source = "app [main] { pf: platform \"../../platform/main.roc\" }\n"
	Release.released_main(source, "https://x/1.0.0/h.tar.zst") == Ok("app [main] { pf: platform \"https://x/1.0.0/h.tar.zst\" }\n")
}

## An entry point that does not name the working-tree platform is refused.
expect Release.released_main("app [main] { pf: platform \"https://y\" }", "u") == Err(NoPlatformPath)

## Recorded output is escaped as JSON.
expect Release.json_str("a\"b\nc") == "\"a\\\"b\\nc\""

## Every release's notes disclose the open store-ownership limitations,
## whatever compiler built it; this goes with `Release.store_ownership`.
expect {
	text = Release.notes("1.0.0", "https://x/1.0.0/h.tar.zst", { compiler: "roc nightly-x", tooling: "roc nightly-y" })
	text.contains("\n## Store ownership\n") and text.contains("roc-lang/roc#12957") and text.contains("roc-lang/roc#13012")
}

## The notes tell a spec's author each evidence rule that now refuses a
## previously passing spec, with the step or marker that satisfies it.
expect {
	text = Release.notes("1.0.0", "https://x/1.0.0/h.tar.zst", { compiler: "roc nightly-x", tooling: "roc nightly-y" })
	steps = ["(expect-absent LOC)", "(expect-no-attr LOC NAME)", "(expect-has-attr LOC NAME)", "(expect-cleanup NAME 0)", "(expect-interval MS 0)", "(tick-interval-if-active MS)"]
	markers = [":never-drawn)", ":never-written)", ":never-runs)", ":never-started`"]
	text.contains("\n## Upgrading specs\n") and steps.all(|step| text.contains("`${step}`")) and markers.all(|marker| text.contains(marker))
}

## The entry point and its modules are archived; a fuzz target is not.
expect [Release.is_archived("e/main.roc"), Release.is_archived("e/fuzz-csv.roc"), Release.is_archived("e/Api.roc"), Release.is_archived("e/Fuzzy.roc")] == [True, False, True, True]

## Shared fuzz properties depend on roc-fuzz, so they do not ship as app modules.
expect !Release.is_archived("examples/csv-converter/FuzzCsvConverterProperty.roc") and !Release.is_archived("examples/csv-converter/fuzz-package.roc") and Release.is_archived("examples/csv-converter/Csv.roc")

## A domain module with a similar name is preserved unless explicitly registered.
expect Release.is_archived("examples/csv-converter/FuzzHelperProperty.roc")
