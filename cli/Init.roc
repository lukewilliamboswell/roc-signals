import cli.Env
import cli.Path
import cli.Stdout
import Bundle
import Project

## `init [DIR]`: create an app, the counter of the documentation's Getting
## Started page, in `DIR` (by default, this directory). It writes only files
## that are not there yet, and copies this directory's `signals.roc` into a
## new directory so the app can run the tool from its own.
Init :: [].{

	## What `init` writes: a file's path in the app, and its text or the
	## file it is copied from.
	Step : { path : Str, contents : [Text(Str), CopyOf(Str)] }

	## Every file `init` writes into `dir`. The scaffold's `main.roc` names
	## the release's platform; its modules lose the region markers the
	## documentation uses to quote them.
	plan : Str -> List(Step)
	plan = |dir| {
		files = Bundle.scaffold.map(
			|{ path, text }| {
				path,
				contents: Text(if (path == "main.roc") Init.with_platform(text, Bundle.platform_url) else Init.without_regions(text)),
			},
		)
		shim = if (dir == ".") [] else [{ path: "signals.roc", contents: CopyOf("signals.roc") }]
		shim.concat(files).append({ path: ".gitignore", contents: Text(gitignore) })
	}

	## Create the app, after checking that no file it writes already exists
	## and, for a new directory, that there is a `signals.roc` here to copy.
	run! : Str => Try({}, _)
	run! = |dir| {
		steps = Init.plan(dir)
		for step in steps {
			target = Init.place(dir, step.path)
			if Path.exists!(Path.utf8(target))? {
				return Err(InitWouldOverwrite(target))
			}
		}
		if dir != "." and !(Path.exists!(Path.utf8("signals.roc"))?) {
			return Err(NoToolToCopy(dir))
		}
		for step in steps {
			target = Init.place(dir, step.path)
			parent = target.split_on("/").drop_last(1)
			if !parent.is_empty() {
				Path.create_all!(Path.utf8(Str.join_with(parent, "/")))?
			}
			match step.contents {
				Text(text) => Path.write_utf8!(Path.utf8(target), text)?
				CopyOf(source) => Path.copy!(Path.utf8(source), Path.utf8(target))?
			}
		}
		name = if (dir == ".") (Project.with_slashes(Path.display(Env.cwd!()?)).split_on("/").last() ?? ".") else dir
		Stdout.line!(Init.summary({ dir, name, paths: steps.map(|step| step.path) }))?
		Ok({})
	}

	## Where a file of the app goes when the app is created in `dir`.
	place : Str, Str -> Str
	place = |dir, path| if (dir == ".") path else "${dir.drop_suffix("/")}/${path}"

	## A `main.roc` naming `url` as its platform in place of whatever its
	## header named.
	with_platform : Str, Str -> Str
	with_platform = |source, url|
		match source.split_on("platform \"") {
			[before, rest, ..] => {
				after = rest.split_on("\"").drop_first(1)
				"${before}platform \"${url}\"${Str.join_with(after, "\"")}"
			}
			_ => source
		}

	## A module without the `# region` and `# endregion` lines the
	## documentation quotes it by.
	without_regions : Str -> Str
	without_regions = |source| {
		lines = source.split_on("\n").drop_if(|line| line.trim().starts_with("# region ") or line.trim().starts_with("# endregion "))
		Str.join_with(lines, "\n")
	}

	## What `init` prints: what it made, and what to do next.
	summary : { dir : Str, name : Str, paths : List(Str) } -> Str
	summary = |{ dir, name, paths }| {
		width = paths.map(|path| path.count_utf8_bytes()).fold(0, |a, b| if (a > b) a else b)
		rows = paths.map(|path| "  ${pad(path, width)}  ${describe(path)}")
		next = if (dir == ".") "  roc signals.roc serve" else "  cd ${dir}\n  roc signals.roc serve"
		"Created the app ${name}, a counter on roc-signals ${Bundle.version}:\n\n${Str.join_with(rows, "\n")}\n\nNext, serve it and open the address it prints:\n\n${next}\n\nThe page reloads when you save a change. Getting Started walks through each file:\nhttps://lukewilliamboswell.github.io/roc-signals/docs/getting-started/"
	}
}

gitignore =
	\\# Written by `roc signals.roc`: development builds and the spec runner
	\\# (.signals/), and the production build (dist/).
	\\/.signals/
	\\/dist/
	\\

## What a file of the scaffold is for.
describe : Str -> Str
describe = |path|
	if path == "signals.roc" {
		"the roc-signals tool, which runs these commands"
	} else if path == "main.roc" {
		"the entry point, which names the platform"
	} else if path.ends_with(".roc") {
		"the app: its state, view and program"
	} else if path == "index.html" {
		"the page that mounts the app"
	} else if path.starts_with("specs/") {
		"a spec, which `roc signals.roc test` runs"
	} else if path == ".gitignore" {
		"keeps build output out of version control"
	} else {
		""
	}

pad : Str, U64 -> Str
pad = |text, width| {
	missing = width - text.count_utf8_bytes()
	"${text}${Str.repeat(" ", missing)}"
}

## The scaffold's entry point names the release's platform, not a path.
expect {
	source = "app [main] { pf: platform \"../../../platform/main.roc\" }\n\nimport pf.Engine\n"
	Init.with_platform(source, "https://x/1.0.0/h.tar.zst") == "app [main] { pf: platform \"https://x/1.0.0/h.tar.zst\" }\n\nimport pf.Engine\n"
}

## Region markers are left out of what `init` writes.
expect Init.without_regions("# region view\nview = 1\n\t# endregion view\nx = 2\n") == "view = 1\nx = 2\n"

## A new directory gets a copy of the tool; this directory already has it.
expect {
	actual = [Init.plan("my-app").map(|step| step.path).first(), Init.plan(".").map(|step| step.path).first()]
	actual == [Ok("signals.roc"), Ok("Counter.roc")]
}

## Every file goes inside the new directory.
expect [Init.place("my-app/", "specs/counter.scm"), Init.place(".", "main.roc")] == ["my-app/specs/counter.scm", "main.roc"]
