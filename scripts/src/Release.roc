import cli.Path
import PlatformTest
import Proc
import SpecSuite
import ToolRelease

## What a release publishes, built the same way for a dry run (in `check`)
## and for the release workflow:
##
## - the platform bundle, `<hash>.tar.zst`: one platform for both targets,
##   `platform/main.roc` with every module it uses, the Wasm host, the native
##   spec runner's link inputs for every system it builds for (Linux
##   x86-64, macOS on Apple silicon and Intel, Windows x86-64),
##   `runtime.mjs`, its fact readers `environment.mjs` and `worker.mjs`;
## - `runtime.mjs`, `environment.mjs` and `worker.mjs` on their own, for pages that load an app
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
	bundle_files = ["main.roc", "Engine.roc", "Web.roc", "Spelling.roc", "MarkupAdvice.roc", "MarkupLiteral.roc", "Clipboard.roc", "Html.roc", "Svg.roc", "Layout.roc", "Order.roc", "Url.roc", "Worker.roc", "Wire.roc", "Port.roc", "PortJson.roc", "PortRegistry.roc", "Protocol.roc", "ProtocolFacts.roc", "Core.roc", "PictureCapture.roc", "TableCore.roc", "View.roc", "Seq.roc", "Effects.roc", "Files.roc", "Hosted.roc", "Cli.roc", "SpecRunner.roc", "PicturePage.roc", "Scm.roc", "Dom.roc", "JsonOut.roc", "targets/wasm32/host.wasm"].concat(PlatformTest.spec_inputs).concat(SpecSuite.runtime_files)

	archive_name : Str -> Str
	archive_name = |version| "roc-signals-examples-${version}"

	## The examples archive omits an example's fuzz targets of its own logic
	## (`fuzz-<subject>.roc`), which depend on a roc-fuzz release rather than
	## on the released platform.
	is_archived : Str -> Bool
	is_archived = |file| {
		name = file.split_on("/").last() ?? file
		!(name.starts_with("fuzz-") and name.ends_with(".roc"))
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
		limitations = if SpecSuite.has_broken_optimizer(o.nightly) {
			"\n## Compiler limitations\n\nThis nightly crashes when optimizing the store apps ([roc-lang/roc#12976](https://github.com/roc-lang/roc/issues/12976)). The site examples use `--opt=dev`; every example's native and browser specs still run. `signals.roc build` automatically uses `--opt=dev` with an explicit warning; direct builds need `roc build --opt=dev --target=wasm32` on this nightly. Optimized walks, shipping browser soaks and worker scaling are explicitly skipped, so this release has no shipping performance or allocation validation on this compiler. Fuzz examples and campaigns always attempt their requested targets; compiler, linker and runtime failures fail the task. Windows CI always attempts the current CLI init and prints its retained log. A failed init may quarantine the remaining CLI journey on this nightly only if its diagnostics form a nonempty subset of the three exact captured basic-cli 0.28 Locale/Path failures ([basic-cli#555](https://github.com/roc-lang/basic-cli/issues/555)). Each may appear once, and every error, cause and summary must agree; other failures remain fatal and successful init continues every CLI check. CI has reproduced Locale failures with basic-cli 0.27 and 0.28; the underlying cause remains unproven. Native specs remain enabled; remove this quarantine when basic-cli#555 is resolved. Each skip expires on the next nightly, which retries the original check.\n"
		} else {
			""
		}
		ownership = if o.nightly == "nightly-2026-11-12-ce942d6" {
			"\n## Store ownership\n\nThe instance holds its store as plain data beside its sites. A bounded development-Wasm check compares sparse-write requested bytes at two table sizes and verifies teardown. This does not establish flat shipping allocations: optimized site writes remain affected by [roc-lang/roc#13019](https://github.com/roc-lang/roc/issues/13019), and boxed local-state captures by [roc-lang/roc#13012](https://github.com/roc-lang/roc/issues/13012). These are compiler limitations, not different reactive semantics. Actual roc-fuzz fixed-example checks remain required.\n"
		} else ""
		Path.write_utf8!(Path.utf8("${out}/release-notes.md"), "${Release.notes(version, bundle_url, { compiler, tooling })}${limitations}${ownership}")?
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
		\\The platform's `runtime.mjs`, `environment.mjs` and `worker.mjs` are separate release assets.
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
		\\## Upgrading specs
		\\
		\\An `expect-absent` needs the same locator in another step that requires it to match. Previously passing unanchored guards fail to parse at that step. Add an assertion where the existing story draws the element, or use `:never-drawn` for a branch the story never draws; the marker leaves its spelling unchecked.
		\\
		\\## Use this release
		\\
		\\```roc
		\\app [main] { pf: platform "${bundle_url}" }
		\\```
		\\
		\\Load apps with this release's `runtime.mjs`, served beside `environment.mjs` and `worker.mjs`.
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

## The entry point and its modules are archived; a fuzz target is not.
expect [Release.is_archived("e/main.roc"), Release.is_archived("e/fuzz-csv.roc"), Release.is_archived("e/Api.roc"), Release.is_archived("e/Fuzzy.roc")] == [True, False, True, True]
