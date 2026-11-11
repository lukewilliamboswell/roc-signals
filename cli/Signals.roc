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

	## What the user asked for.
	Command : [Help, Init(Str), Serve({ port : U16 }), Build, Test]

	## Run the tool on the arguments `roc signals.roc` passed it. Every
	## failure is explained in a sentence on standard error and ends the
	## program with a non-zero exit code (2 for a misused command line).
	run! : List(OsStr.OsStr) => Try({}, [Exit(I32)])
	run! = |raw| {
		args = raw.map(OsStr.display).drop_if(|arg| arg == "--")
		outcome = match Signals.parse(args) {
			Ok(Help) => Stdout.line!(Signals.usage)
			Ok(Init(dir)) => Init.run!(dir)
			Ok(Serve(options)) => Serve.run!(options)
			Ok(Build) => Dist.run!()
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
			["init"] => Ok(Init("."))
			["init", dir] if !dir.starts_with("-") => Ok(Init(dir))
			["serve"] => Ok(Serve({ port: 8000 }))
			["serve", "--port", value] =>
				match U16.from_str(value) {
					Ok(port) if port > 0 => Ok(Serve({ port: port }))
					_ => Err(BadPort(value))
				}
			["build"] => Ok(Build)
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
			_ => "Use it as `roc signals.roc ${command}`, with nothing after it."
		}
}

## Each command line names its command, with the defaults filled in.
expect {
	actual = [["init"], ["init", "my-app"], ["serve"], ["serve", "--port", "9000"], ["build"], ["test"], [], ["help"]].map(Signals.parse)
	expected = [Ok(Init(".")), Ok(Init("my-app")), Ok(Serve({ port: 8000 })), Ok(Serve({ port: 9000 })), Ok(Build), Ok(Test), Ok(Help), Ok(Help)]
	actual == expected
}

## A misused command line is refused with what was wrong.
expect {
	actual = [["srve"], ["serve", "--port", "http"], ["serve", "--port", "0"], ["build", "--watch"], ["init", "--blueprint"]].map(Signals.parse)
	expected = [Err(UnknownCommand("srve")), Err(BadPort("http")), Err(BadPort("0")), Err(UnexpectedArguments({ command: "build", extra: ["--watch"] })), Err(UnexpectedArguments({ command: "init", extra: ["--blueprint"] }))]
	actual == expected
}
