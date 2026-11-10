import cli.Path
import Proc
import SpecSuite

## The platform's generated API documentation, built by roc-docs from
## `platform/main.roc` with `www/api/index.md` as its front page, and the
## check that every public symbol of `Engine`, `Html`, `Worker` and `Wire` is
## documented.
ApiDocs := [].{

	## The modules the web platform exposes.
	modules : List(Str)
	modules = ["platform/Engine.roc", "platform/Html.roc", "platform/Worker.roc", "platform/Wire.roc"]

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

	## The public items of a module that have no `##` doc comment: every
	## declaration inside the module's nominal type block (`Name := [].{`),
	## at any depth, whose preceding line is not a doc comment. Record fields
	## (which end in a comma) and continuation lines are not declarations.
	undocumented : Str -> List(Str)
	undocumented = |source| {
		var $out = []
		var $inside = Bool.False
		var $previous = ""
		for line in source.split_on("\n") {
			if !$inside {
				$inside = line.contains(" := [].{")
			} else if line == "}" {
				$inside = Bool.False
			} else if ApiDocs.is_declaration(line) and !$previous.trim().starts_with("##") {
				$out = $out.append(line.trim())
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
			for item in ApiDocs.undocumented(source) {
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
		\\	Val(a) := { read : a }.{
		\\		map : Val(a) -> Val(a)
		\\		map = |v| v
		\\	}
		\\}
		\\
		\\private : Str
		\\private = ""
	ApiDocs.undocumented(source) == ["span : Str -> Elem(ctx)", "Val(a) := { read : a }.{", "map : Val(a) -> Val(a)"]
}
