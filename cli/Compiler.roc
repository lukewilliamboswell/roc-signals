import cli.Cmd
import cli.Env
import cli.OsStr
import cli.Path
import Bundle

## Running the Roc compiler on the app: every build the tool makes goes
## through here, so each one names the same entry point, reports failures the
## same way, and knows which compiler the release was tested with.
Compiler :: [].{

	## A build of the app's `main.roc`, from the app's directory: for which
	## target, at which optimisation level, into which file.
	Build : { target : Str, opt : Str, output : Str }

	## The compiler's version, from `roc version` (for example
	## `nightly-2026-11-10-f7d1f19`). Fails with `RocMissing` when no `roc`
	## is on the PATH, which is the first thing every command that builds
	## checks.
	version! : () => Try(Str, [RocMissing])
	version! = || {
		output = Cmd.new("roc").args(["version"]).run!() ? |_| RocMissing
		Ok(Compiler.version_of(Str.from_utf8_lossy(output.stdout_bytes)))
	}

	## The version word of `roc version`'s output.
	version_of : Str -> Str
	version_of = |text| text.trim().split_on(" ").last() ?? text.trim()

	## A sentence to add to a failed build's report when the compiler is not
	## the one the release was tested with, since a compiler change can
	## break an app that has no error of its own. Empty when they agree.
	mismatch_note : Str -> Str
	mismatch_note = |version|
		if version == Bundle.nightly {
			""
		} else {
			"This release of roc-signals (${Bundle.version}) was built and tested with Roc ${Bundle.nightly}, and `roc version` says ${version}. If the errors are not in your code, install ${Bundle.nightly} from https://github.com/roc-lang/nightlies/releases and put it first on your PATH."
		}

	## The command for a build. `ROC_SIGNALS_PLATFORM`, when set, names a
	## platform `main.roc` to use in place of the release's bundle: it is
	## how roc-signals' own tests run the tool against a working tree.
	command! : Build => Cmd.Command
	command! = |{ target, opt, output }| {
		replace = match Env.var_str!("ROC_SIGNALS_PLATFORM") {
			Ok(path) if !path.is_empty() => ["--replace-dep", Bundle.platform_url, path]
			_ => []
		}
		args = ["build", "--target=${target}", "--opt=${opt}"].concat(replace).concat(["main.roc", "--output=${output}"])
		Cmd.new("roc").args(args.map(OsStr.from_str)).stdout(Capture).stderr(MergeWithStdout)
	}

	## Build and wait. Answers `Built(report)` when the compiler finished
	## without errors (warnings are allowed), with what it printed, or
	## `Failed(report)`. The output file is written only on success: the
	## compiler writes its output even when the app has errors, so the build
	## goes to a side file that replaces `output` only when it succeeds.
	build! : Build => Try([Built(Str), Failed(Str)], [RocMissing, BuildIoFailed(Str)])
	build! = |build| {
		side = "${build.output}.next"
		result = Compiler.command!({ ..build, output: side }).run!() ? |_| RocMissing
		Compiler.finish!(build.output, result.status, result.stdout_bytes)
	}

	## Judge a finished build: on success move the side file over `output`.
	finish! : Str, Cmd.ExitStatus, List(U8) => Try([Built(Str), Failed(Str)], [BuildIoFailed(Str)])
	finish! = |output, status, bytes| {
		report = Compiler.tidy(Str.from_utf8_lossy(bytes))
		match Compiler.verdict(status) {
			Succeeded => {
				Path.rename!(Path.utf8("${output}.next"), Path.utf8(output)) ? |_| BuildIoFailed(output)
				Ok(Built(report))
			}
			Failed => Ok(Failed(report))
		}
	}

	## The compiler's report without its closing "while successfully
	## building" and the path of the side file, which would read as a
	## success and name a file the author never sees.
	tidy : Str -> Str
	tidy = |report|
		match report.split_on(" while successfully building:") {
			[before, _, ..] => "${before}."
			_ => report
		}

	## The compiler exits 0 for a clean build, 2 when there are only
	## warnings, and 1 when there are errors.
	verdict : Cmd.ExitStatus -> [Succeeded, Failed]
	verdict = |status|
		match status {
			Exited(0) => Succeeded
			Exited(2) => Succeeded
			_ => Failed
		}

	## The compiler's report as plain text: its colour codes removed, for the
	## page's overlay.
	plain : Str -> Str
	plain = |report| {
		var $out = []
		var $state = Text
		for byte in report.to_utf8() {
			(next, kept) = match $state {
				Text => if (byte == 27) (Escape, Dropped) else (Text, Kept)
				Escape => if (byte == '[') (Sequence, Dropped) else (Text, Dropped)
				Sequence => if (byte >= 64 and byte <= 126) (Text, Dropped) else (Sequence, Dropped)
			}
			$state = next
			if kept == Kept {
				$out = $out.append(byte)
			}
		}
		Str.from_utf8_lossy($out)
	}

	## The platform `main.roc` names, read from its header: a URL or a path.
	platform_of : Str -> Try(Str, [NoPlatform])
	platform_of = |source|
		match source.split_on("platform \"") {
			[_, rest, ..] => rest.split_on("\"").first().map_err(|_| NoPlatform)
			_ => Err(NoPlatform)
		}
}

## The version is the last word of `roc version`.
expect Compiler.version_of("Roc compiler version nightly-2026-11-10-f7d1f19\n") == "nightly-2026-11-10-f7d1f19"

## Warnings alone are a successful build; errors and signals are not.
expect [Compiler.verdict(Exited(0)), Compiler.verdict(Exited(2)), Compiler.verdict(Exited(1)), Compiler.verdict(Signaled(9))] == [Succeeded, Succeeded, Failed, Failed]

## The report's closing line keeps its count and drops the side file.
expect Compiler.tidy("x\n1 error and 0 warnings found in 9ms while successfully building:\n\n    a.wasm.next\n") == "x\n1 error and 0 warnings found in 9ms."

## Colour codes are removed from a report.
expect Compiler.plain("\u(1b)[31mError\u(1b)[0m: [x]") == "Error: [x]"

## The header's platform is found.
expect Compiler.platform_of("app [main] { pf: platform \"https://x/y.tar.zst\" }\n") == Ok("https://x/y.tar.zst")

## A module with no platform says so.
expect Compiler.platform_of("Counter := [].{}") == Err(NoPlatform)
