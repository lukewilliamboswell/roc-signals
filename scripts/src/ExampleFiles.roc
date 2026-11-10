import cli.Path

## The files an example's page loads at run time besides its `app.wasm`, as
## `www/data/examples.toml` names them: the scripts its page loads
## (`[[examples.scripts]]` with a relative `src`), its port handlers
## (`ports`), its simulated service (`backend`) and the data it downloads
## (`data`). The site build copies each beside the app, so the catalogue is
## the one place an example declares them.
##
## The catalogue is read line by line, not as general TOML: a table header,
## a comment, a blank line or `key = value`. The keys above must hold a
## plain string, `true`/`false`, or a one-line list of plain strings, and
## name a file directly in the example's directory; anything else they hold
## is refused with its line, rather than guessed at.
ExampleFiles := [].{
	catalog = "www/data/examples.toml"

	## One file to copy: `from` relative to the repository root, `to`
	## relative to the built site.
	Copy : { from : Str, to : Str }

	## The copies the catalogue's text names, in catalogue order.
	copies : Str -> Try(List(Copy), [Unreadable(Str)])
	copies = |text| {
		var $out = []
		var $slug = ""
		var $table = ""
		for raw in text.split_on("\n") {
			line = raw.trim()
			if line.starts_with("[") {
				$table = line
				if line == "[[examples]]" {
					$slug = ""
				}
			} else if line != "" and !line.starts_with("#") {
				parts = line.split_on(" = ")
				key = (parts.first() ?? "").trim()
				value = Str.join_with(parts.drop_first(1), " = ").trim()
				names_a_file = key == "ports" or key == "backend" or key == "data" or ($table == "[[examples.scripts]]" and key == "src")
				if names_a_file and $slug == "" {
					return Err(Unreadable(raw))
				}
				if $table == "[[examples]]" and key == "slug" {
					$slug = ExampleFiles.string(value) ? |_| Unreadable(raw)
				} else if $table == "[[examples]]" and (key == "ports" or key == "backend") {
					name = ExampleFiles.file_name(value) ? |_| Unreadable(raw)
					$out = $out.append(ExampleFiles.own($slug, name))
				} else if $table == "[[examples]]" and key == "data" {
					names = ExampleFiles.file_names(value) ? |_| Unreadable(raw)
					for name in names {
						$out = $out.append(ExampleFiles.own($slug, name))
					}
				} else if $table == "[[examples.scripts]]" and key == "src" {
					src = ExampleFiles.string(value) ? |_| Unreadable(raw)
					if !src.starts_with("https://") {
						name = ExampleFiles.file_name(value) ? |_| Unreadable(raw)
						$out = $out.append(ExampleFiles.own($slug, name))
					}
				}
			}
		}
		Ok($out)
	}

	## A file in the example's own directory, served beside its app.
	own : Str, Str -> Copy
	own = |slug, name| { from: "examples/${slug}/${name}", to: "examples/${slug}/${name}" }

	## A plain string value: `"text"`, with no quote or backslash inside.
	string : Str -> Try(Str, [NotAString])
	string = |value|
		match value.split_on("\"") {
			[before, inner, after] => if (before == "" and after == "" and !inner.contains("\\")) Ok(inner) else Err(NotAString)
			_ => Err(NotAString)
		}

	## A string value naming a file directly in a directory: not empty, no
	## `/`, and not `.` or `..`.
	file_name : Str -> Try(Str, [NotAFileName])
	file_name = |value| {
		name = ExampleFiles.string(value) ? |_| NotAFileName
		if (name == "" or name == "." or name == ".." or name.contains("/")) Err(NotAFileName) else Ok(name)
	}

	## A one-line list of file names: `["a.csv", "b.json"]`, or `[]`.
	file_names : Str -> Try(List(Str), [NotAFileList])
	file_names = |value| {
		if !value.starts_with("[") or !value.ends_with("]") {
			return Err(NotAFileList)
		}
		inner = value.drop_prefix("[").drop_suffix("]").trim()
		if inner == "" {
			return Ok([])
		}
		var $names = []
		for item in inner.split_on(",") {
			name = ExampleFiles.file_name(item.trim()) ? |_| NotAFileList
			$names = $names.append(name)
		}
		Ok($names)
	}

	## Copy every file the catalogue names from `root` into `dist`, each
	## directory created as needed. A file that does not exist fails the
	## copy, so a page never refers to a file the site lacks.
	copy_all! : Str, Str => Try({}, _)
	copy_all! = |root, dist| {
		text = Path.read_utf8!(Path.utf8("${root}/${ExampleFiles.catalog}"))?
		for { from, to } in ExampleFiles.copies(text)? {
			dir = to.split_on("/").drop_last(1)
			Path.create_all!(Path.utf8("${dist}/${Str.join_with(dir, "/")}"))?
			Path.copy!(Path.utf8("${root}/${from}"), Path.utf8("${dist}/${to}"))?
		}
		Ok({})
	}

	## The `check` task's look at the catalogue: every line that names a file
	## is readable, and every file it names exists, so a broken name fails a
	## pull request rather than the next site build.
	check! : Str => Try(List(Str), _)
	check! = |root| {
		text = Path.read_utf8!(Path.utf8("${root}/${ExampleFiles.catalog}"))?
		match ExampleFiles.copies(text) {
			Err(Unreadable(line)) => Ok(["${ExampleFiles.catalog}: cannot read the file this line names: ${line.trim()}"])
			Ok(named) => {
				var $out = []
				for { from, .. } in named {
					if !Path.exists!(Path.utf8("${root}/${from}"))? {
						$out = $out.append("${ExampleFiles.catalog} names ${from}, which does not exist")
					}
				}
				Ok($out)
			}
		}
	}
}

## Each kind of file an example names is copied from its directory to the
## same place in the site; a script from a CDN is not copied.
expect {
	text =
		\\# The catalogue.
		\\[[examples]]
		\\slug = "a"
		\\description = "Uses = signs and # marks"
		\\ports = "ports.mjs"
		\\backend = "backend.mjs"
		\\data = ["one.csv", "two.json"]
		\\
		\\[[examples.scripts]]
		\\src = "https://cdn.example/x.js"
		\\
		\\[[examples.scripts]]
		\\src = "chart.mjs"
		\\module = true
		\\
		\\[[examples]]
		\\slug = "b"
		\\data = []
	ExampleFiles.copies(text)
		== Ok([
			{ from: "examples/a/ports.mjs", to: "examples/a/ports.mjs" },
			{ from: "examples/a/backend.mjs", to: "examples/a/backend.mjs" },
			{ from: "examples/a/one.csv", to: "examples/a/one.csv" },
			{ from: "examples/a/two.json", to: "examples/a/two.json" },
			{ from: "examples/a/chart.mjs", to: "examples/a/chart.mjs" },
		])
}

## A value the reader cannot be sure of is refused with its line.
expect {
	bad = ["backend = \"../x.mjs\"", "ports = 'p.mjs'", "data = [\"a.csv\", 3]", "backend = \"b.mjs\" # trailing"]
	bad.all(|line| ExampleFiles.copies("[[examples]]\nslug = \"a\"\n${line}\n") == Err(Unreadable(line)))
}
