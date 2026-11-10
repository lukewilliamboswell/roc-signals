import cli.Path
import PlatformTest
import Proc
import SpecSuite

## What a release publishes, built the same way for a dry run (in `check`)
## and for the release workflow:
##
## - the platform bundle, `<hash>.tar.zst`: one platform for both targets,
##   `platform/main.roc` with every module it uses, the Wasm host, the native
##   spec runner's link inputs for x64musl, `runtime.mjs` and its worker
##   script `worker.mjs`;
## - `runtime.mjs` and `worker.mjs` on their own, for pages that load an app
##   (the runtime loads the worker script from beside itself);
## - the examples archive, `roc-signals-examples-<version>.zip`, which the
##   shared nightly-compatibility runner builds with the latest Roc nightly:
##   each example's `main.roc` naming the bundle's release URL, with its
##   specs, a `spec.json` and the `runtime/check.mjs` helper that mounts each
##   app;
## - `release-notes.md`, the draft release's body.
Release := [].{
	repo_url = "https://github.com/lukewilliamboswell/roc-signals"

	## The platform files a bundle carries, relative to `platform/`.
	bundle_files : List(Str)
	bundle_files = ["main.roc", "Engine.roc", "Html.roc", "Worker.roc", "Wire.roc", "Port.roc", "PortJson.roc", "Core.roc", "Cli.roc", "SpecRunner.roc", "Scm.roc", "Dom.roc", "JsonOut.roc", "targets/wasm32/host.wasm", "targets/x64musl/spec.o", "targets/x64musl/crt1.o", "targets/x64musl/libc.a", "targets/x64musl/libzigc.a", "targets/x64musl/libcompiler_rt.a"].concat(SpecSuite.runtime_files)

	archive_name : Str -> Str
	archive_name = |version| "roc-signals-examples-${version}"

	## The examples archive omits the fuzz entry points, which need the
	## repository's fuzz platform.
	is_archived : Str -> Bool
	is_archived = |file| !file.ends_with("/main-fuzz.roc")

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

		# The examples archive.
		name = Release.archive_name(version)
		stage = "${o.build_dir}/release-stage"
		root = "${stage}/${name}"
		SpecSuite.fresh_dir!(stage)?
		Path.create_all!(Path.utf8("${root}/runtime"))?
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
			Path.create_all!(Path.utf8("${dir}/specs"))?
			for spec in SpecSuite.files_with!("examples/${example}/specs", ".scm")? {
				Path.copy!(Path.utf8(spec), Path.utf8("${dir}/specs/${spec.split_on("/").last() ?? spec}"))?
			}
			{ code, stdout } = Proc.output!({ program: o.node, args: ["tests/release/check.mjs", SpecSuite.wasm_of(o, example)], cwd: o.root })?
			if code != 0 {
				$problems = $problems.append("release: ${example} does not mount: ${Str.from_utf8_lossy(stdout)}")
			}
			$cases = $cases.append({ example, stdout: Str.from_utf8_lossy(stdout) })
		}
		Path.write_utf8!(Path.utf8("${root}/spec.json"), Release.spec_json(version, bundle_url, $cases))?
		Path.write_utf8!(Path.utf8("${root}/README.md"), Release.archive_readme(version))?
		Proc.run!({ program: "zip", args: ["-q", "-r", "-X", "${out}/${name}.zip", name], cwd: stage })?

		compiler = Str.from_utf8_lossy(Proc.capture!({ program: o.compiler, args: ["version"], cwd: o.root })?).trim()
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
		\\runner with `roc build --target=x64musl examples/<app>/main.roc` and run
		\\it on `examples/<app>/specs/*.scm`.
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
		\\## Use this release
		\\
		\\```roc
		\\app [main] { pf: platform "${bundle_url}" }
		\\```
		\\
		\\Load apps with this release's `runtime.mjs`, served beside its `worker.mjs`.
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

## The entry point and its modules are archived; the fuzz entry is not.
expect [Release.is_archived("e/main.roc"), Release.is_archived("e/main-fuzz.roc"), Release.is_archived("e/Api.roc")] == [True, False, True]
