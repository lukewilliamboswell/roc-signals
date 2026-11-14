import cli.Cmd
import cli.Duration
import cli.Monotonic
import cli.Path
import cli.Signal
import cli.Stdout
import cli.System
import cli.Tcp
import "dev-client.js" as dev_client : Str
import Bundle
import Compiler
import Http
import Project

## `serve [--port N]`: build the app for development, serve it on
## `127.0.0.1`, and keep it current. When a Roc module changes the app is
## rebuilt, and on success every open page reloads; when the build fails
## the pages show the compiler's report over the app and keep the last
## working build. When another file changes (the page, a script, a style)
## the pages reload without a build. "Hot reloading" here means a page
## reload: nothing of the running app is carried across a code change.
##
## One loop does everything, one step at a time: it accepts a connection
## (waiting at most 50 ms), answers it, looks for changed files every 100 ms,
## and starts or finishes a build in a child process. A connection that
## never sends its request holds the loop for at most its read timeout.
Serve :: [].{

	## Serve until interrupted (Ctrl-C).
	run! : { port : U16 } => Try({}, _)
	run! = |{ port }| {
		if !(Path.exists!(Path.utf8("main.roc"))?) {
			return Err(NoMainRoc)
		}
		if !(Path.exists!(Path.utf8("index.html"))?) {
			return Err(NoIndexHtml)
		}
		version = Compiler.version!()?
		note = Serve.platform_note(Path.read_utf8!(Path.utf8("main.roc"))?)
		if !note.is_empty() {
			Stdout.line!(note)?
		}
		{ listener, bound } = listen!(port)?
		if bound != port {
			Stdout.line!("Port ${port.to_str()} is in use, so the app is served on port ${bound.to_str()} instead.")?
		}
		Signal.catch!(
			match System.target!().os() {
				Linux(linux) => [Interrupt, Terminate(linux.unix())]
				MacOS(mac) => [Interrupt, Terminate(mac.unix())]
				Windows(_) => [Interrupt]
			},
		)?
		Path.create_all!(Path.utf8(work_dir))?
		Stdout.line!("Building the app...")?
		started = Monotonic.now!()
		first = Compiler.build!(dev_build)?
		var $failure = report!(first, { version, started, reason: "" })?
		Stdout.line!("Serving the app at http://127.0.0.1:${bound.to_str()}/ (press Ctrl-C to stop). Pages reload when you save a change, and show build errors over the app.")?

		var $clients = []
		var $stamps = Project.stamps!()?
		var $waiting = []
		var $build = Idle
		var $last_poll = Monotonic.now!()
		var $last_beat = Monotonic.now!()
		var $running = True
		while $running {
			if !Signal.poll!().is_empty() {
				$running = False
			}
			match listener.accept!({ accept_timeout: After(Duration.millis(50)), io_timeout: Duration.seconds(1) }) {
				Ok(connection) =>
					match answer!(connection, $failure) {
						Ok(Subscribed) => {
							$clients = $clients.append(connection)
						}
						_ => {}
					}
				Err(_) => {}
			}
			# A comment on every stream now and then: writing to a page that
			# has gone fails, which drops it, so the list of listening pages
			# holds only open ones.
			if Monotonic.elapsed!($last_beat).to_millis() >= 2000 {
				$last_beat = Monotonic.now!()
				$clients = broadcast!($clients, ": still here\n\n")
			}
			if Monotonic.elapsed!($last_poll).to_millis() >= 100 {
				$last_poll = Monotonic.now!()
				now = Project.stamps!() ?? $stamps
				changed = Project.changes($stamps, now)
				$stamps = now
				if changed.is_empty() and !$waiting.is_empty() and is_idle($build) {
					# The files have settled since the last change: act on it.
					waiting = $waiting
					$waiting = []
					reason = Str.join_with(waiting, ", ")
					if waiting.any(|path| path.ends_with(".roc")) {
						Stdout.line!("${reason} changed; rebuilding...")?
						child = Compiler.command!(side_build).spawn!() ? |_| RocMissing
						$build = Running({ child, started: Monotonic.now!(), reason })
					} else {
						Stdout.line!("${reason} changed; reloading the open pages.")?
						$clients = broadcast!($clients, Http.event("reload", reason))
					}
				} else {
					$waiting = $waiting.concat(changed.drop_if(|path| $waiting.contains(path)))
				}
			}
			match $build {
				Running({ child, started: build_started, reason }) =>
					match child.poll!() {
						Ok(Finished(output)) => {
							$build = Idle
							outcome = Compiler.finish!(dev_build.output, output.status, output.stdout_bytes)?
							$failure = report!(outcome, { version, started: build_started, reason })?
							$clients = match $failure {
								Clean if $waiting.is_empty() => {
									Stdout.line!("Reloading the open pages.")?
									broadcast!($clients, Http.event("reload", reason))
								}
								Clean => $clients
								Failed(text) => broadcast!($clients, Http.event("failed", text))
							}
						}
						Ok(Running) => {}
						Err(_) => {
							$build = Idle
						}
					}
				Idle => {}
			}
		}
		match $build {
			Running({ child, .. }) => child.kill!() ?? {}
			Idle => {}
		}
		Stdout.line!("Stopped serving the app.")?
		Ok({})
	}

	## A note when `main.roc` names another release's platform than this
	## tool's, whose runtime the server serves: the two must match.
	platform_note : Str -> Str
	platform_note = |source|
		match Compiler.platform_of(source) {
			Ok(url) if url != Bundle.platform_url and url.starts_with("https://") =>
				"Note: main.roc names the platform ${url}, but this signals.roc is roc-signals ${Bundle.version}, which serves the runtime of ${Bundle.platform_url}. If the page cannot mount the app, make the two the same release: change main.roc's platform, or download that release's signals.roc."
			_ => ""
		}
}

work_dir = ".signals/serve"

dev_build : Compiler.Build
dev_build = { target: "wasm32", opt: "dev", output: "${work_dir}/app.wasm" }

side_build : Compiler.Build
side_build = { ..dev_build, output: Compiler.side_of(dev_build.output) }

## The first free port from `port`, trying ten.
listen! : U16 => Try({ listener : Tcp.Listener, bound : U16 }, _)
listen! = |port| {
	var $candidate = port
	while $candidate < port + 10 and $candidate != 0 {
		match Tcp.listen!("127.0.0.1", $candidate, Duration.seconds(5)) {
			Ok(listener) => return Ok({ listener, bound: $candidate })
			Err(_) => {
				$candidate = $candidate + 1
			}
		}
	}
	Err(PortsBusy({ first: port, last: port + 9 }))
}

## Print what a build did, and answer what the pages should be told.
report! : [Built(Str), Failed(Str)], { version : Str, started : Monotonic.Monotonic, reason : Str } => Try([Clean, Failed(Str)], _)
report! = |outcome, { version, started, .. }| {
	seconds = seconds_since!(started)
	match outcome {
		Built(text) => {
			shown = Compiler.report_on_success(text)
			warnings = if (shown.is_empty()) "" else "\n${shown}"
			Stdout.line!("Built in ${seconds} s.${warnings}")?
			Ok(Clean)
		}
		Failed(text) => {
			note = Compiler.mismatch_note(version)
			Stdout.line!("${text.trim()}\n\nThe build failed after ${seconds} s. Open pages show the errors above and keep the last build that worked; they reload when the app builds again.${if (note.is_empty()) "" else "\n${note}"}")?
			Ok(Failed(Str.join_with([Compiler.plain(text).trim(), note].drop_if(Str.is_empty), "\n\n")))
		}
	}
}

seconds_since! : Monotonic.Monotonic => Str
seconds_since! = |started| {
	tenths = Monotonic.elapsed!(started).to_millis() // 100
	"${(tenths // 10).to_str()}.${(tenths % 10).to_str()}"
}

## Send an event to every listening page; a page that has gone is dropped.
broadcast! : List(Tcp.Connection), Str => List(Tcp.Connection)
broadcast! = |clients, message| {
	var $alive = []
	for client in clients {
		if client.write_utf8!(message).is_ok() {
			$alive = $alive.append(client)
		}
	}
	$alive
}

is_idle : [Idle, Running(_)] -> Bool
is_idle = |build|
	match build {
		Idle => True
		Running(_) => False
	}

## Answer one request.
answer! : Tcp.Connection, [Clean, Failed(Str)] => Try([Subscribed, Answered], _)
answer! = |connection, failure| {
	line = connection.read_line!()?
	var $header = line
	while !$header.is_empty() and $header != "\r" {
		$header = connection.read_line!()?
	}
	match Http.route(line.drop_suffix("\r"), Bundle.runtime_files.map(|f| f.path)) {
		Events => {
			connection.write_utf8!(Http.stream_head)?
			match failure {
				Failed(text) => connection.write_utf8!(Http.event("failed", text))?
				Clean => {}
			}
			Ok(Subscribed)
		}
		Page => {
			page = Path.read_utf8!(Path.utf8("index.html")) ?? missing_page
			send!(connection, { status: Found, name: "index.html", body: Http.inject(page, "<script>\n${dev_client}</script>\n").to_utf8() })
		}
		Runtime(name) => {
			text = Bundle.runtime_files.find_first(|f| f.path == name).map_ok(|f| f.text) ?? ""
			send!(connection, { status: Found, name: name, body: text.to_utf8() })
		}
		Module =>
			match Path.read_bytes!(Path.utf8(dev_build.output)) {
				Ok(bytes) => send!(connection, { status: Found, name: "app.wasm", body: bytes })
				Err(_) => send!(connection, { status: Missing, name: "x.txt", body: "The app has not built yet: the terminal running `roc signals.roc serve` shows why.\n".to_utf8() })
			}
		File(path) => {
			public = "public/${path}"
			found = if (Path.is_file!(Path.utf8(public)) ?? False) public else path
			match Path.read_bytes!(Path.utf8(found)) {
				Ok(bytes) => send!(connection, { status: Found, name: found, body: bytes })
				Err(_) => send!(connection, { status: Missing, name: "x.txt", body: "There is no file ${path} in the app's directory.\n".to_utf8() })
			}
		}
		Refused => send!(connection, { status: Missing, name: "x.txt", body: "Only files inside the app's directory are served.\n".to_utf8() })
		Unsupported => send!(connection, { status: NotAllowed, name: "x.txt", body: "The development server answers only GET and HEAD.\n".to_utf8() })
	}
}

missing_page = "<!doctype html><title>No index.html</title><p>There is no <code>index.html</code> in the app's directory, so there is no page to show. Restore it, or create an app with <code>roc signals.roc init</code> to see one.</p>"

send! : Tcp.Connection, { status : [Found, Missing, NotAllowed], name : Str, body : List(U8) } => Try([Subscribed, Answered], _)
send! = |connection, { status, name, body }| {
	connection.write_bytes!(Http.response({ status, content_type: Http.content_type(name), body }))?
	Ok(Answered)
}

## A note appears only when main.roc names another released platform.
expect {
	ours = "app [main] { pf: platform \"${Bundle.platform_url}\" }"
	other = "app [main] { pf: platform \"https://github.com/x/releases/download/9.9.9/h.tar.zst\" }"
	[Serve.platform_note(ours).is_empty(), Serve.platform_note(other).starts_with("Note: main.roc names the platform https://github.com/x/")] == [True, True]
}
