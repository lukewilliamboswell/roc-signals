import cli.Path
import Proc
import SpecSuite

## The platform's generated API documentation, built by roc-docs from
## `platform/main.roc` with `www/api/index.md` as its front page, and the
## check that every public symbol of `Engine`, `Clipboard`, `Table`, `Files`, `Html`, `Layout`, `Worker`, `Wire`, `Port` and
## `PortJson` is documented.
ApiDocs := [].{

	## The modules the web platform exposes.
	modules : List(Str)
	modules = ["platform/Engine.roc", "platform/Clipboard.roc", "platform/Table.roc", "platform/Files.roc", "platform/Html.roc", "platform/Layout.roc", "platform/Worker.roc", "platform/Wire.roc", "platform/Port.roc", "platform/PortJson.roc"]

	## Build the API docs; the site is `<build_dir>/api-docs/site`.
	build! : SpecSuite.Options, Str => Try(Str, _)
	build! = |o, version| {
		out = "${o.build_dir}/api-docs"
		# roc-docs takes its output directory relative to the workspace.
		relative = if (out.starts_with("${o.root}/")) out.drop_prefix("${o.root}/") else return Err(BuildDirOutsideWorkspace(out))
		if Path.exists!(Path.utf8(out))? {
			Path.delete_all!(Path.utf8(out))?
		}
		Proc.run!({
			program: "roc-docs",
			args: ["build", "--workspace", ".", "--docs-directory", "www/api", "--entrypoint", "index.md", "--output-directory", relative, "--api-entrypoint", "platform/main.roc", "--roc-command", o.compiler, "--pdf-filename", "roc-signals-api.pdf", "--docs-version", version, "--title", "Roc Signals API", "--site-url", "https://lukewilliamboswell.github.io/roc-signals/api/"],
			cwd: o.root,
		})?
		Ok("${out}/site")
	}

	## The public items of the module `name` that have no `##` doc comment:
	## every declaration inside the block of the module's own type, at any
	## depth, whose preceding line is not a doc comment. The block opens
	## where the type's line ends in `.{` (`Name := [].{`), or, for a type
	## written as a record (`Name(a) :: {`), at the `}.{` that closes its
	## fields. Another type at the file's top level is private and is not
	## scanned. Record fields (which end in a comma) and continuation lines
	## are not declarations.
	undocumented : Str, Str -> List(Str)
	undocumented = |name, source| {
		var $out = []
		var $at = Outside
		var $previous = ""
		for line in source.split_on("\n") {
			ending = line.trim_end()
			match $at {
				Outside => {
					own = line.starts_with("${name} ") or line.starts_with("${name}(")
					$at = if (own and ending.ends_with(".{")) Inside else if (own and ending.ends_with("{")) Fields else Outside
				}
				Fields => {
					$at = if (ending == "}.{") Inside else if (ending == "}") Outside else Fields
				}
				Inside => {
					if line == "}" {
						$at = Outside
					} else if ApiDocs.is_declaration(line) and !$previous.trim().starts_with("##") {
						$out = $out.append(line.trim())
					}
				}
			}
			$previous = line
		}
		$out
	}

	## A line that declares a value's type or a type: `name : ...` or
	## `Name(args) :` / `:=` at the start of an indented line.
	is_declaration : Str -> Bool
	is_declaration = |line| {
		trimmed = line.trim_start()
		if !line.starts_with("\t") or trimmed.ends_with(",") or trimmed.starts_with("#") {
			Bool.False
		} else {
			match trimmed.split_on(" :") {
				[head, _, ..] => !head.is_empty() and !head.contains(" ") and !head.contains(".") and !head.contains("{") and !head.contains("[")
				_ => Bool.False
			}
		}
	}

	## Problems: one per undocumented public symbol.
	check! : {} => Try(List(Str), _)
	check! = |_| {
		var $problems = []
		for file in ApiDocs.modules {
			source = Path.read_utf8!(Path.utf8(file))?
			name = (file.split_on("/").last() ?? file).drop_suffix(".roc")
			for item in ApiDocs.undocumented(name, source) {
				$problems = $problems.append("${file}: public symbol without a ## doc comment: ${item}")
			}
		}
		Ok($problems)
	}
}

## Documented items pass; an undocumented one, at any depth, is reported.
expect {
	source =
		\\import Engine
		\\
		\\Html := [].{
		\\	## A box.
		\\	div : Str -> Elem(ctx)
		\\	div = |c| x
		\\
		\\	span : Str -> Elem(ctx)
		\\	span = |c| x
		\\
		\\	## A record type.
		\\	Rec : {
		\\		field : Str,
		\\	}
		\\
		\\	Signal(a) := { read : a }.{
		\\		map : Signal(a) -> Signal(a)
		\\		map = |v| v
		\\	}
		\\}
		\\
		\\private : Str
		\\private = ""
	ApiDocs.undocumented("Html", source) == ["span : Str -> Elem(ctx)", "Signal(a) := { read : a }.{", "map : Signal(a) -> Signal(a)"]
}

## A type written as a record with its methods after it is scanned from the
## `}.{` that opens them: its fields are not symbols, its methods are. A
## private type below it is not the module's and is not scanned.
expect {
	source =
		\\## A table.
		\\Table(k, v) :: {
		\\	rows : Dict(k, v),
		\\	version : U64,
		\\}.{
		\\
		\\	## The number of rows.
		\\	len : Table(k, v) -> U64
		\\	len = |table| table.rows.len()
		\\
		\\	get : Table(k, v), k -> Try(v, [Missing])
		\\		where [k.is_eq : k, k -> Bool]
		\\	get = |table, key| table.rows.get(key)
		\\}
		\\
		\\rows_of : List(k) -> Dict(k, v)
		\\rows_of = |entries| x
		\\
		\\Sample := { n : U64 }.{
		\\	is_eq : _
		\\}
	ApiDocs.undocumented("Table", source) == ["get : Table(k, v), k -> Try(v, [Missing])"]
}
