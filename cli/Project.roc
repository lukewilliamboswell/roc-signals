import cli.Path

## The files of an app's directory, and what each one is to the tool. The
## tool always runs in the app's directory, so every path here is relative to
## it, with `/` between its parts.
Project :: [].{

	## What a file is to the tool:
	##
	## - `Source`: a Roc module, which the compiler reads;
	## - `Page`: `index.html`, which mounts the app;
	## - `Asset`: anything else the page may load (its scripts, styles,
	##   images), which `build` puts beside the app's module in a hashed
	##   directory;
	## - `Public`: a file under `public/`, which `build` copies to the top of
	##   `dist/` under its own name, for something named by a fixed URL;
	## - `Spec`: a file under `specs/`;
	## - `Ignored`: build output (`dist/`, `.signals/`) and dotfiles.
	Role : [Source, Page, Asset, Public, Spec, Ignored]

	## A file of the app and its role.
	Member : { path : Str, role : Role }

	role : Str -> Role
	role = |path| {
		parts = path.split_on("/")
		top = parts.first() ?? path
		if parts.any(|part| part.starts_with(".")) {
			Ignored
		} else if top == "dist" and parts.len() > 1 {
			Ignored
		} else if top == "specs" and parts.len() > 1 {
			Spec
		} else if top == "public" and parts.len() > 1 {
			Public
		} else if path == "index.html" {
			Page
		} else if path.ends_with(".roc") {
			Source
		} else {
			Asset
		}
	}

	## Every file of the app with its role, sorted by path. Ignored
	## directories are not entered.
	members! : () => Try(List(Member), _)
	members! = || {
		paths = walk!(".")?
		Ok(paths.map(|path| { path, role: Project.role(path) }).sort_with(|a, b| compare(a.path, b.path)))
	}

	## A file's modification time, to notice that it changed.
	Stamp : { path : Str, modified : I128 }

	## The modification times of the app's files that matter to `serve`:
	## everything but specs and ignored files.
	stamps! : () => Try(List(Stamp), _)
	stamps! = || {
		var $out = []
		for member in Project.members!()? {
			if member.role != Spec and member.role != Ignored {
				modified = Path.time_modified!(Path.utf8(member.path))?
				$out = $out.append({ path: member.path, modified: modified.to_nanos_since_epoch() })
			}
		}
		Ok($out)
	}

	## The paths that were added, removed or modified between two sets of
	## stamps, sorted.
	changes : List(Stamp), List(Stamp) -> List(Str)
	changes = |before, after| {
		var $out = []
		for stamp in after {
			if !before.contains(stamp) {
				$out = $out.append(stamp.path)
			}
		}
		for stamp in before {
			if !after.any(|a| a.path == stamp.path) {
				$out = $out.append(stamp.path)
			}
		}
		$out.sort_with(compare)
	}

	## Order two paths by their bytes.
	compare : Str, Str -> [Before, Same, After]
	compare = |a, b| compare_bytes(a.to_utf8(), b.to_utf8())
}

## The relative paths of the files under `dir`, not entering ignored
## directories.
walk! : Str => Try(List(Str), _)
walk! = |dir| {
	var $out = []
	for entry in Path.list!(Path.utf8(dir))? {
		full = Path.display(entry)
		relative = if (full.starts_with("./")) full.drop_prefix("./") else full
		if Project.role(relative) == Ignored or relative == "dist" {
			{}
		} else if Path.is_dir!(entry)? {
			$out = $out.concat(walk!(full)?)
		} else {
			$out = $out.append(relative)
		}
	}
	Ok($out)
}

compare_bytes : List(U8), List(U8) -> [Before, Same, After]
compare_bytes = |a, b|
	match (a, b) {
		([], []) => Same
		([], _) => Before
		(_, []) => After
		([x, .. as xs], [y, .. as ys]) => if (x < y) Before else if (x > y) After else compare_bytes(xs, ys)
	}

## Each kind of file has its role.
expect {
	paths = ["main.roc", "Counter.roc", "index.html", "ports.mjs", "img/logo.svg", "public/data.csv", "specs/counter.scm", "dist/index.html", ".signals/serve/app.wasm", ".gitignore", "signals.roc"]
	actual = paths.map(Project.role)
	actual == [Source, Source, Page, Asset, Asset, Public, Spec, Ignored, Ignored, Ignored, Source]
}

## A changed, an added and a removed file are all changes; an unchanged one
## is not.
expect {
	before = [{ path: "a.roc", modified: 1 }, { path: "b.roc", modified: 1 }, { path: "c.roc", modified: 1 }]
	after = [{ path: "a.roc", modified: 1 }, { path: "b.roc", modified: 2 }, { path: "d.roc", modified: 1 }]
	Project.changes(before, after) == ["b.roc", "c.roc", "d.roc"]
}
