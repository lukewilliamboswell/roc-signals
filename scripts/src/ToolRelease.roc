import cli.Path
import Proc
import SpecSuite

## The release's `signals.roc` tool: its package, staged from `cli/` with
## the runtime files, the scaffold (the documentation's counter) and a
## generated `Bundle.roc` naming the release, then bundled; and
## `signals.roc`, the app an author downloads to run it.
ToolRelease := [].{

	## Where the tool's package is staged before it is bundled. The tool's
	## end-to-end check runs this staged package in place of the bundle.
	stage_of : SpecSuite.Options -> Str
	stage_of = |o| "${o.build_dir}/release-tool"

	## The documentation's counter, which the tool's `init` writes.
	scaffold_dir = "www/samples/counter"

	## The targets a platform bundle builds a native spec runner for: those
	## whose spec runner is among its files.
	spec_targets : List(Str) -> List(Str)
	spec_targets = |bundle_files|
		bundle_files.keep_oks(
			|file|
				match file.split_on("/") {
					["targets", target, "spec.o"] => Ok(target)
					_ => Err(NotASpecRunner)
				},
		)

	## What a release tells the tool: its version and the URL its assets
	## are downloaded from, its platform bundle's URL and files, and the
	## nightly it was built with.
	Release : { version : Str, download_url : Str, platform_url : Str, bundle_files : List(Str), nightly : Str }

	## Build the `signals.roc` tool into `out`: stage `cli/` with the
	## runtime files, the scaffold and a `Bundle.roc` naming the release;
	## bundle it as `signals-<hash>.tar.zst`; and write `signals.roc`, the
	## app that runs it.
	build! : SpecSuite.Options, Release, Str => Try({}, _)
	build! = |o, release, out| {
		stage = ToolRelease.stage_of(o)
		SpecSuite.fresh_dir!(stage)?
		var $files = []
		for entry in Path.list!(Path.utf8("cli"))? {
			name = Path.display(entry).split_on("/").last() ?? ""
			if !Path.is_dir!(entry)? and name != "Bundle.roc" {
				Path.copy!(entry, Path.utf8("${stage}/${name}"))?
				$files = $files.append(name)
			}
		}
		SpecSuite.copy_runtime!(o.root, stage)?
		scaffold = ToolRelease.scaffold_files!()?
		for file in scaffold {
			target = "${stage}/templates/${file}"
			Path.create_all!(Path.utf8(Str.join_with(target.split_on("/").drop_last(1), "/")))?
			Path.copy!(Path.utf8("${ToolRelease.scaffold_dir}/${file}"), Path.utf8(target))?
		}
		bundle_module = ToolRelease.bundle_module({
			version: release.version,
			platform_url: release.platform_url,
			nightly: release.nightly,
			spec_targets: ToolRelease.spec_targets(release.bundle_files),
			runtime_dir: "",
			scaffold_dir: "templates/",
			scaffold,
		})
		Path.write_utf8!(Path.utf8("${stage}/Bundle.roc"), bundle_module)?
		# `main.roc`, the package's root, goes first.
		files = ["main.roc"]
			.concat($files.drop_if(|f| f == "main.roc").sort_with(|a, b| SpecSuite.compare_str(a, b)))
			.concat(["Bundle.roc"])
			.concat(SpecSuite.runtime_files)
			.concat(scaffold.map(|f| "templates/${f}"))
		packed = "${stage}-bundle"
		SpecSuite.fresh_dir!(packed)?
		Proc.run!({ program: o.compiler, args: ["bundle"].concat(files).concat(["--output-dir", packed]), cwd: stage })?
		archive = match SpecSuite.files_with!(packed, ".tar.zst")? {
			[one] => one.split_on("/").last() ?? one
			found => return Err(BundleNotFound(Str.inspect(found)))
		}
		Path.rename!(Path.utf8("${packed}/${archive}"), Path.utf8("${out}/signals-${archive}"))?
		basic_cli = ToolRelease.platform_of(Path.read_utf8!(Path.utf8("cli/main.roc"))?) ? |_| NoBasicCliPlatform
		package_url = "${release.download_url}/signals-${archive}"
		Path.write_utf8!(Path.utf8("${out}/signals.roc"), ToolRelease.shim({ version: release.version, basic_cli, package_url }))?
		Ok({})
	}

	## The scaffold's files, relative to `scaffold_dir`, sorted.
	scaffold_files! : () => Try(List(Str), _)
	scaffold_files! = || {
		prefix = "${ToolRelease.scaffold_dir}/"
		found = SpecSuite.files_under!(ToolRelease.scaffold_dir, "")?
		Ok(found.map(|f| f.drop_prefix(prefix)).sort_with(|a, b| SpecSuite.compare_str(a, b)))
	}

	## The platform a package's or an app's header names.
	platform_of : Str -> Try(Str, [NoPlatform])
	platform_of = |source|
		match source.split_on("platform \"") {
			[_, rest, ..] => rest.split_on("\"").first().map_err(|_| NoPlatform)
			_ => Err(NoPlatform)
		}

	## What the tool's `Bundle.roc` names: the release, its platform and
	## compiler, and where the runtime files and the scaffold are, relative
	## to the module.
	ToolBundle : { version : Str, platform_url : Str, nightly : Str, spec_targets : List(Str), runtime_dir : Str, scaffold_dir : Str, scaffold : List(Str) }

	## The development copy of the tool's `Bundle.roc`, checked in as
	## `cli/Bundle.roc`: it reads the runtime and the scaffold from the
	## checkout.
	development_module : { scaffold : List(Str), bundle_files : List(Str) } -> Str
	development_module = |{ scaffold, bundle_files }|
		ToolRelease.bundle_module({
			version: "development",
			platform_url: "../platform/main.roc",
			nightly: "development",
			spec_targets: ToolRelease.spec_targets(bundle_files),
			runtime_dir: "../platform/",
			scaffold_dir: "../${ToolRelease.scaffold_dir}/",
			scaffold,
		})

	## The tool's `Bundle.roc`, exactly as `roc fmt` writes it.
	bundle_module : ToolBundle -> Str
	bundle_module = |b| {
		import_lines = SpecSuite.runtime_files
			.map(|f| "import \"${b.runtime_dir}${f}\" as ${ToolRelease.alias(f)} : Str")
			.concat(b.scaffold.map(|f| "import \"${b.scaffold_dir}${f}\" as scaffold_${ToolRelease.alias(f)} : Str"))
		runtime = SpecSuite.runtime_files.map(|f| "\t\t{ path: \"${f}\", text: ${ToolRelease.alias(f)} },")
		scaffold = b.scaffold.map(|f| "\t\t{ path: \"${f}\", text: scaffold_${ToolRelease.alias(f)} },")
		target_list = Str.join_with(b.spec_targets.map(|t| "\"${t}\""), ", ")
		header =
			\\# Generated by scripts/src/ToolRelease.roc: for each release, bundled beside
			\\# copies of the files it imports, and as cli/Bundle.roc for a checkout, where
			\\# it imports them from the working tree. `check` fails when cli/Bundle.roc
			\\# differs from what the script generates for a checkout.
		body =
			\\## What this copy of the tool ships with: the release it belongs to, that
			\\## release's platform and compiler, the runtime it serves beside an app, and
			\\## the files `init` writes.
			\\Bundle := [].{
			\\
			\\	## A file the tool writes or serves, by its path relative to the app.
			\\	File : { path : Str, text : Str }
			\\
			\\	## The roc-signals release this copy of the tool belongs to.
			\\	version = "${b.version}"
			\\
			\\	## The release's platform bundle, which `init` names in `main.roc`.
			\\	platform_url = "${b.platform_url}"
			\\
			\\	## The Roc nightly the release was built and tested with.
			\\	nightly = "${b.nightly}"
			\\
			\\	## The targets the release's platform builds a native spec runner for.
			\\	spec_targets = [${target_list}]
			\\
			\\	## The platform's browser runtime, served beside the app's module.
			\\	runtime_files : List(File)
			\\	runtime_files = [
		middle =
			\\	]
			\\
			\\	## The files `init` writes: the counter of the documentation's Getting
			\\	## Started page.
			\\	scaffold : List(File)
			\\	scaffold = [
		Str.join_with([header].concat(import_lines).concat(["", body]).concat(runtime).concat([middle]).concat(scaffold).concat(["\t]", "}", ""]), "\n")
	}

	## A Roc name for a file: its path in lower case, with `_` for anything
	## but a letter or a digit.
	alias : Str -> Str
	alias = |path| Str.from_utf8_lossy(path.to_utf8().map(|c| if ((c >= 'a' and c <= 'z') or (c >= '0' and c <= '9')) c else if (c >= 'A' and c <= 'Z') c + 32 else '_'))

	## `signals.roc`, the app an app's author downloads to run the tool: it
	## names basic-cli and this release's tool package, and pins no
	## compiler.
	shim : { version : Str, basic_cli : Str, package_url : Str } -> Str
	shim = |{ version, basic_cli, package_url }|
		\\# signals.roc, from roc-signals ${version}: create, serve, build and test a
		\\# roc-signals app. Keep it beside the app's main.roc and run it with Roc:
		\\#
		\\#     roc signals.roc init my-app    create an app in my-app/
		\\#     roc signals.roc serve          serve it, reloading the page on a change
		\\#     roc signals.roc build          build it for deployment, into dist/
		\\#     roc signals.roc test           run its specs
		\\#
		\\# To move to another release, download that release's signals.roc over
		\\# this one and change the platform in main.roc to match.
		\\app [main!] {
		\\	cli: platform "${basic_cli}",
		\\	signals: "${package_url}",
		\\}
		\\
		\\import signals.Signals
		\\
		\\main! = |args| Signals.run!(args)
		\\
}

## The tool's spec targets are the spec runners a bundle carries.
expect ToolRelease.spec_targets(["main.roc", "targets/wasm32/host.wasm", "targets/x64musl/spec.o", "targets/arm64mac/spec.o"]) == ["x64musl", "arm64mac"]

## The tool's app names basic-cli and the tool's package, and pins no
## compiler.
expect {
	text = ToolRelease.shim({ version: "1.0.0", basic_cli: "https://b/c.tar.zst", package_url: "https://x/signals-h.tar.zst" })
	actual = [text.contains("cli: platform \"https://b/c.tar.zst\""), text.contains("signals: \"https://x/signals-h.tar.zst\""), text.contains("roc:")]
	actual == [True, True, False]
}

## A file's Roc name keeps letters and digits, in lower case.
expect [ToolRelease.alias("runtime.mjs"), ToolRelease.alias("specs/Counter.scm")] == ["runtime_mjs", "specs_counter_scm"]
