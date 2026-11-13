import cli.OsStr
import cli.Stderr
import cli.Stdout
import Bundle
import Compiler
import Dist
import Init
import Serve
import Specs

## The `signals.roc` tool: create, serve, build and test a roc-signals app.
## A project runs it with the small `signals.roc` app each release
## publishes, from the app's directory:
##
## ```sh
## roc signals.roc init my-app   # create an app
## roc signals.roc serve         # develop it in a browser
## roc signals.roc build         # build it for deployment, into dist/
## roc signals.roc test          # run its specs
## ```
Signals :: [].{

	## Explicit routes for the build command, visible through this package
	## rather than an implementation-module type in command diagnostics.
	BuildProps := { pictures : List(Str) ?? [] }.{

		## Options compare their explicit route lists in order. Filesystem route
		## equivalence and collision checks belong to the native output planner.
		is_eq : _
	}

	## What the user asked for.
	Command : [Help, CommandHelp(Str), Init(Str), Serve({ port : U16 }), Build(BuildProps), Test]

	## Run the tool on the arguments `roc signals.roc` passed it. Every
	## failure is explained in a sentence on standard error and ends the
	## program with a non-zero exit code (2 for a misused command line).
	run! : List(OsStr.OsStr) => Try({}, [Exit(I32)])
	run! = |raw| {
		args = raw.map(OsStr.display).drop_if(|arg| arg == "--")
		outcome = match Signals.parse(args) {
			Ok(Help) => Stdout.line!(Signals.usage)
			Ok(CommandHelp(command)) => Stdout.line!(Signals.command_usage(command))
			Ok(Init(dir)) => Init.run!(dir)
			Ok(Serve(options)) => Serve.run!(options)
			Ok(Build(options)) => Dist.run!({ pictures: options.pictures })
			Ok(Test) => Specs.run!()
			Err(problem) => Err(problem)
		}
		match outcome {
			Ok({}) => Ok({})
			Err(problem) => {
				{ text, code } = Signals.explain(problem)
				if !text.is_empty() {
					Stderr.line!(text) ?? {}
				}
				Err(Exit(code))
			}
		}
	}

	## The command the arguments name.
	parse : List(Str) -> Try(Command, [UnknownCommand(Str), UnexpectedArguments({ command : Str, extra : List(Str) }), BadPort(Str)])
	parse = |args|
		match args {
			[] => Ok(Help)
			["help", ..] | ["--help", ..] | ["-h", ..] => Ok(Help)
			[command, "--help"] | [command, "-h"] if ["init", "serve", "build", "test"].contains(command) => Ok(CommandHelp(command))
			["init"] => Ok(Init("."))
			["init", dir] if !dir.starts_with("-") => Ok(Init(dir))
			["serve"] => Ok(Serve({ port: 8000 }))
			["serve", "--port", value] =>
				match U16.from_str(value) {
					Ok(port) if port > 0 => Ok(Serve({ port: port }))
					_ => Err(BadPort(value))
				}
			["build"] => Ok(Build({ pictures: [] }))
			["build", "--picture", .. as pictures] if !pictures.is_empty() and !pictures.any(|url| url.starts_with("--")) => Ok(
				Build(
					{ pictures: pictures },
				),
			)
			["test"] => Ok(Test)
			[command, .. as extra] if ["init", "serve", "build", "test"].contains(command) => Err(UnexpectedArguments({ command, extra }))
			[command, ..] => Err(UnknownCommand(command))
		}

	usage =
		\\signals.roc creates, serves, builds and tests a roc-signals app. Run it
		\\from the app's directory:
		\\
		\\  roc signals.roc init [DIR]        Create an app in DIR, or in this directory.
		\\  roc signals.roc serve [--port N]  Serve the app at http://127.0.0.1:8000/ (or
		\\                                    port N), rebuilding it and reloading the page
		\\                                    when you save a change.
		\\  roc signals.roc build             Build the app for deployment into dist/.
		\\  roc signals.roc test              Run the app's specs, specs/*.scm.
		\\
		\\This is roc-signals ${Bundle.version}, tested with Roc ${Bundle.nightly}.
		\\Documentation: https://lukewilliamboswell.github.io/roc-signals/docs/getting-started/

	## Describe one command before inspecting an app, writing files or starting
	## a build or server. Only exact help forms for known commands reach here.
	command_usage : Str -> Str
	command_usage = |command| {
		description = match command {
			"init" =>
				\\Create a counter app, its page and an example spec.
				\\
				\\Usage: roc signals.roc init [DIR]
				\\
				\\DIR defaults to the current directory. Existing files are never overwritten.
				\\Keep signals.roc in the directory you run init from; a new app gets a copy.
			"serve" =>
				\\Develop the app in a browser, rebuilding and reloading when files change.
				\\
				\\Usage: roc signals.roc serve [--port N]
				\\
				\\Run from the app's directory, containing main.roc and index.html.
				\\The server listens on 127.0.0.1, starting at port 8000 or N (1 to 65535).
				\\If that port is busy, it tries nearby ports and prints the address it uses.
				\\Stop with Ctrl-C. Reloading starts the app again with its initial state.
			"build" =>
				\\Build the app for deployment to a static web host.
				\\
				\\Usage: roc signals.roc build [--picture URL...]
				\\
				\\Run from the app's directory, containing main.roc and index.html.
				\\The output replaces dist/. Serve that directory with a static HTTP server.
				\\Normally uses --opt=size; a compiler workaround reports any change of mode.
				\\--picture takes explicit HTTP(S) or root-relative URLs. Each writes its
				\\first frame to PATH/index.html; query/hash variants of one path collide.
				\\The template must mark exactly one mount root with data-roc-picture.
			"test" =>
				\\Run the app's specs with the native spec runner.
				\\
				\\Usage: roc signals.roc test
				\\
				\\Run from the app's directory, containing main.roc and specs/*.scm.
				\\A failed spec exits with an error and reports the step that failed.
			_ => return Signals.usage
		}
		docs = if (command == "test") "testing" else "getting-started"
		"${description}\n\nThis is roc-signals ${Bundle.version}, tested with Roc ${Bundle.nightly}.\nDocumentation: https://lukewilliamboswell.github.io/roc-signals/docs/${docs}/"
	}

	## The sentence a failure is explained with, and the exit code. This is
	## the one place the tool's failures are put into words.
	explain : _ -> { text : Str, code : I32 }
	explain = |problem|
		match problem {
			UnknownCommand(command) => { code: 2, text: "There is no command \"${command}\". The commands are init, serve, build and test; `roc signals.roc help` describes them." }
			UnexpectedArguments({ command, extra }) => { code: 2, text: "${command} does not take ${Str.join_with(extra.map(|a| "\"${a}\""), " ")}. ${Signals.synopsis(command)}" }
			BadPort(value) => { code: 2, text: "--port takes a port number from 1 to 65535, and \"${value}\" is not one." }
			RocMissing => { code: 1, text: "The Roc compiler is not on your PATH as `roc`, so the app cannot be built. Install Roc ${Bundle.nightly}, the nightly roc-signals ${Bundle.version} was tested with, from https://github.com/roc-lang/nightlies/releases, and put it on your PATH as `roc`." }
			NoMainRoc => { code: 1, text: "There is no main.roc here, so there is no app to work on. Run this from your app's directory, or create an app with `roc signals.roc init my-app`." }
			NoIndexHtml => { code: 1, text: "There is no index.html here, and the app needs a page to mount it. `roc signals.roc init` writes one; Getting Started shows what it holds: https://lukewilliamboswell.github.io/roc-signals/docs/getting-started/" }
			NoSpecs => { code: 1, text: "There are no specs to run: specs/ holds no .scm files. `roc signals.roc init` writes specs/counter.scm as an example, and Testing describes the language: https://lukewilliamboswell.github.io/roc-signals/docs/testing/" }
			SpecsUnsupported(target) => { code: 1, text: "This machine runs ${Specs.system_name(target)}, and roc-signals ${Bundle.version} builds the native spec runner only for ${Str.join_with(Bundle.spec_targets.map(Specs.system_name), ", ")}, so `test` cannot run the specs here. Run them on one of those systems, for example in CI." }
			SpecsFailed => { code: 1, text: "" }
			RunnerFailed(text) => { code: 1, text: "The spec runner stopped before it reported every spec:\n${text.trim()}" }
			BuildFailed({ report, version }) => {
				note = Compiler.mismatch_note(version)
				{ code: 1, text: "${report.trim()}\n\nThe build failed: the compiler's report is above.${if (note.is_empty()) "" else "\n${note}"}" }
			}
			PictureUnsupported(target) => { code: 1, text: "Pictures require the app's native runner, which this release does not build for ${target}." }
			PictureRunnerFailed({ url, reason }) => { code: 1, text: "The native picture runner for ${url} failed: ${reason}." }
			PictureFailed({ url, report }) => { code: 1, text: "The picture for ${url} was refused:\n${report.trim()}" }
			PictureResponseInvalid(url) => { code: 1, text: "The native picture runner returned an invalid response for ${url}." }
			PictureRouteCollision({ first, second, path }) => { code: 1, text: "Picture routes ${first} and ${second} both write ${path}; query and fragment variants cannot share one output file." }
			UnsafeOutputPath(path) => { code: 1, text: "The build refused unsafe output path ${path}." }
			OutputCollision({ first, second }) => { code: 1, text: "Build outputs ${first} and ${second} overlap; dist was not changed." }
			PublicationInterrupted(path) => { code: 1, text: "A previous build backup remains at ${path}. Inspect or restore it before publishing another build." }
			PublicationCleanupFailed(path) => { code: 1, text: "The complete new dist was published, but the previous build backup could not be removed from ${path}. Inspect it before the next build." }
			PublicationRollbackFailed(path) => { code: 1, text: "The new dist could not be published or the previous directory restored. The previous build remains at ${path}." }
			BuildIoFailed(path) => { code: 1, text: "The build finished, but its output could not be moved into ${path}." }
			PortsBusy({ first, last }) => { code: 1, text: "Ports ${first.to_str()} to ${last.to_str()} are all in use. Stop the server that holds them, or choose another port with --port N." }
			InitWouldOverwrite(path) => { code: 1, text: "${path} already exists, so init changed nothing: it only creates files that are not there yet. Choose a new directory, for example `roc signals.roc init my-app`." }
			NoToolToCopy(dir) => { code: 1, text: "init copies signals.roc into the new app, but there is no signals.roc in this directory, so ${dir} was not created. Run init from the directory that holds signals.roc." }
			other => { code: 1, text: "signals.roc stopped on an error it did not expect: ${Str.inspect(other)}" }
		}

	## How a command is used, for a misused command line.
	synopsis : Str -> Str
	synopsis = |command|
		match command {
			"init" => "Use it as `roc signals.roc init [DIR]`."
			"serve" => "Use it as `roc signals.roc serve [--port N]`."
			"build" => "Use it as `roc signals.roc build [--picture URL...]`."
			_ => "Use it as `roc signals.roc ${command}`, with nothing after it."
		}
}

## Each command line names its command, with the defaults filled in.
expect {
	actual = [["init"], ["init", "my-app"], ["serve"], ["serve", "--port", "9000"], ["build"], ["test"], [], ["help"]].map(Signals.parse)
	expected = [Ok(Init(".")), Ok(Init("my-app")), Ok(Serve({ port: 8000 })), Ok(Serve({ port: 9000 })), Ok(Build({ pictures: [] })), Ok(Test), Ok(Help), Ok(Help)]
	actual == expected
}

## A misused command line is refused with what was wrong.
expect {
	actual = [["srve"], ["serve", "--port", "http"], ["serve", "--port", "0"], ["build", "--watch"], ["init", "--blueprint"]].map(Signals.parse)
	expected = [Err(UnknownCommand("srve")), Err(BadPort("http")), Err(BadPort("0")), Err(UnexpectedArguments({ command: "build", extra: ["--watch"] })), Err(UnexpectedArguments({ command: "init", extra: ["--blueprint"] }))]
	actual == expected
}

## Help belongs to an exact known command, with no effects or app required.
expect {
	["init", "serve", "build", "test"].all(
		|command| ["--help", "-h"].all(|flag| Signals.parse([command, flag]) == Ok(CommandHelp(command))),
	)
}

## Help flags never turn unknown commands, extra options or bad ports into help.
expect {
	actual = [["unknown", "--help"], ["init", "new-app", "--help"], ["init", "--help", "--unknown"], ["build", "--watch", "-h"], ["test", "--unknown", "--help"], ["serve", "--port", "--help"], ["serve", "--port", "http", "--help"]].map(Signals.parse)
	expected = [Err(UnknownCommand("unknown")), Err(UnexpectedArguments({ command: "init", extra: ["new-app", "--help"] })), Err(UnexpectedArguments({ command: "init", extra: ["--help", "--unknown"] })), Err(UnexpectedArguments({ command: "build", extra: ["--watch", "-h"] })), Err(UnexpectedArguments({ command: "test", extra: ["--unknown", "--help"] })), Err(BadPort("--help")), Err(UnexpectedArguments({ command: "serve", extra: ["--port", "http", "--help"] }))]
	actual == expected
}

## Each help page carries its own usage and the release/compiler/docs context.
expect {
	["init", "serve", "build", "test"].all(
		|command| {
			text = Signals.command_usage(command)
			text.contains("Usage: roc signals.roc ${command}") and text.contains("roc-signals ${Bundle.version}") and text.contains("tested with Roc ${Bundle.nightly}") and text.contains("Documentation: https://lukewilliamboswell.github.io/roc-signals/docs/")
		},
	)
}

## Picture URLs are explicit arguments; query and hash remain the runner's input.
expect Signals.parse(["build", "--picture", "/", "/tasks?open=1#list"]) == Ok(Build({ pictures: ["/", "/tasks?open=1#list"] }))

## A picture switch needs at least one URL and cannot swallow another option.
expect Signals.parse(["build", "--picture"]).is_err() and Signals.parse(["build", "--picture", "/", "--watch"]).is_err()
