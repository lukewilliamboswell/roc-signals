import cli.Path

## The files an example's page loads at run time besides its `app.wasm`, as
## `www/data/examples.toml` names them: its scripts (`[[examples.scripts]]`
## with `src`, `shared` or `vendor`), its port handlers
## (`ports`), its simulated service (`backend`) and the data it downloads
## (`data`). The site build copies each beside the app, so the catalogue is
## the one place an example declares them. A script several examples load
## (`shared` in place of `src`) lives in `examples/shared/` and is copied
## there once. Zola publishes `vendor` scripts from `www/static/vendor/`.
##
## The catalogue is read line by line, not as general TOML: a table header,
## a comment, a blank line or `key = value`. The keys above must hold a
## plain string or a one-line list of plain strings. Each name identifies a
## file directly in the directory selected by its key. Invalid names are
## refused with their line.
ExampleFiles := [].{
	catalog = "www/data/examples.toml"

	## A catalogue asset and how it reaches the built site. The source is
	## relative to the repository root and a copy's destination to the site.
	Asset : { from : Str, publish : [CopyTo(Str), Zola] }

	## The assets the catalogue names, in catalogue order.
	assets : Str -> Try(List(Asset), [Unreadable(Str)])
	assets = |text| {
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
				names_a_file = key == "ports" or key == "backend" or key == "data" or ($table == "[[examples.scripts]]" and (key == "src" or key == "shared" or key == "vendor"))
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
					name = ExampleFiles.file_name(value) ? |_| Unreadable(raw)
					$out = $out.append(ExampleFiles.own($slug, name))
				} else if $table == "[[examples.scripts]]" and key == "shared" {
					name = ExampleFiles.file_name(value) ? |_| Unreadable(raw)
					asset = ExampleFiles.shared(name)
					if !$out.contains(asset) {
						$out = $out.append(asset)
					}
				} else if $table == "[[examples.scripts]]" and key == "vendor" {
					name = ExampleFiles.file_name(value) ? |_| Unreadable(raw)
					asset = { from: "www/static/vendor/${name}", publish: Zola }
					if !$out.contains(asset) {
						$out = $out.append(asset)
					}
				}
			}
		}
		Ok($out)
	}

	## A file in the example's own directory, served beside its app.
	own : Str, Str -> Asset
	own = |slug, name| {
		path = "examples/${slug}/${name}"
		{ from: path, publish: CopyTo(path) }
	}

	## A script several examples load (`shared` in a script's table): a file
	## in `examples/shared/`, served once at `examples/shared/` in the site.
	shared : Str -> Asset
	shared = |name| {
		path = "examples/shared/${name}"
		{ from: path, publish: CopyTo(path) }
	}

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

	## Publish the example files from `root` into `dist`, each directory
	## created as needed. Zola has already published the vendored scripts.
	copy_all! : Str, Str => Try({}, _)
	copy_all! = |root, dist| {
		text = Path.read_utf8!(Path.utf8("${root}/${ExampleFiles.catalog}"))?
		for { from, publish } in ExampleFiles.assets(text)? {
			match publish {
				CopyTo(to) => {
					dir = to.split_on("/").drop_last(1)
					Path.create_all!(Path.utf8("${dist}/${Str.join_with(dir, "/")}"))?
					Path.copy!(Path.utf8("${root}/${from}"), Path.utf8("${dist}/${to}"))?
				}
				Zola => {
					if !Path.exists!(Path.utf8("${root}/${from}"))? {
						return Err(MissingVendorScript(from))
					}
				}
			}
		}
		Ok({})
	}

	## The examples whose `section` names no `[[sections]]` id, or that have
	## none: the examples index would leave them out without a word.
	unsectioned : Str -> List(Str)
	unsectioned = |text| {
		var $ids = []
		var $examples = []
		var $table = ""
		var $slug = ""
		var $section = ""
		for raw in text.split_on("\n").append("[[end]]") {
			line = raw.trim()
			if line.starts_with("[") {
				if $table == "[[examples]]" {
					$examples = $examples.append(($slug, $section))
				}
				if line != "[[examples.scripts]]" {
					$table = line
					$slug = ""
					$section = ""
				}
			} else {
				parts = line.split_on(" = ")
				key = (parts.first() ?? "").trim()
				value = ExampleFiles.string(Str.join_with(parts.drop_first(1), " = ").trim()) ?? ""
				if $table == "[[sections]]" and key == "id" {
					$ids = $ids.append(value)
				} else if $table == "[[examples]]" and key == "slug" {
					$slug = value
				} else if $table == "[[examples]]" and key == "section" {
					$section = value
				}
			}
		}
		ids = $ids
		$examples.keep_if(|(_, section)| !ids.contains(section)).map(|(slug, _)| slug)
	}

	## The `check` task's look at the catalogue: every line that names a file
	## is readable, every file it names exists, and every example is in a
	## section of the index, so a broken name fails a pull request rather than
	## the next site build.
	check! : Str => Try(List(Str), _)
	check! = |root| {
		text = Path.read_utf8!(Path.utf8("${root}/${ExampleFiles.catalog}"))?
		sections = ExampleFiles.unsectioned(text).map(|slug| "${ExampleFiles.catalog}: example ${slug} names no section of the index")
		match ExampleFiles.assets(text) {
			Err(Unreadable(line)) => Ok(sections.append("${ExampleFiles.catalog}: cannot read the file this line names: ${line.trim()}"))
			Ok(named) => {
				var $out = sections
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

## An example is in the index only when its section exists.
expect {
	text =
		\\[[sections]]
		\\id = "basics"
		\\
		\\[[examples]]
		\\slug = "a"
		\\section = "basics"
		\\
		\\[[examples.scripts]]
		\\shared = "x.mjs"
		\\
		\\[[examples]]
		\\slug = "b"
		\\section = "advanced"
		\\
		\\[[examples]]
		\\slug = "c"
	ExampleFiles.unsectioned(text) == ["b", "c"]
}

## Example files keep their paths, and Zola publishes each vendored script.
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
		\\src = "chart.mjs"
		\\module = true
		\\
		\\[[examples.scripts]]
		\\shared = "panel.mjs"
		\\
		\\[[examples.scripts]]
		\\vendor = "plotly.js"
		\\
		\\[[examples]]
		\\slug = "b"
		\\data = []
		\\
		\\[[examples.scripts]]
		\\module = true
		\\shared = "panel.mjs"
	ExampleFiles.assets(text)
		== Ok([
			{ from: "examples/a/ports.mjs", publish: CopyTo("examples/a/ports.mjs") },
			{ from: "examples/a/backend.mjs", publish: CopyTo("examples/a/backend.mjs") },
			{ from: "examples/a/one.csv", publish: CopyTo("examples/a/one.csv") },
			{ from: "examples/a/two.json", publish: CopyTo("examples/a/two.json") },
			{ from: "examples/a/chart.mjs", publish: CopyTo("examples/a/chart.mjs") },
			{ from: "examples/shared/panel.mjs", publish: CopyTo("examples/shared/panel.mjs") },
			{ from: "www/static/vendor/plotly.js", publish: Zola },
		])
}

## The catalogue refuses remote example scripts.
expect {
	line = "src = \"https://cdn.example/x.js\""
	ExampleFiles.assets("[[examples]]\nslug = \"a\"\n[[examples.scripts]]\n${line}\n") == Err(Unreadable(line))
}

## A value the reader cannot be sure of is refused with its line.
expect {
	bad = ["backend = \"../x.mjs\"", "ports = 'p.mjs'", "data = [\"a.csv\", 3]", "backend = \"b.mjs\" # trailing"]
	bad.all(|line| ExampleFiles.assets("[[examples]]\nslug = \"a\"\n${line}\n") == Err(Unreadable(line)))
}
