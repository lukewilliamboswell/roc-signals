import cli.Path
import cli.Stdout
import Bundle
import Compiler
import Project

## `build`: the app ready to deploy, in `dist/`. The page goes to
## `dist/index.html`; the app's module (normally built with `--opt=size`), the
## platform's runtime and the app's other files go together into
## `dist/assets/<hash>/`, a directory named by a hash of everything in it;
## files under `public/` go to the top of `dist/` under their own names.
##
## Only the page's URLs are rewritten: a quoted relative URL in
## `index.html` that names one of the hashed files is pointed into the
## hashed directory. Those files keep their places relative to each other,
## so `runtime.mjs` still finds `worker.mjs` beside it and a script still
## imports its neighbours. A file the app's Roc code downloads by URL
## belongs in `public/`.
Dist :: [].{

	## A file of `dist/`, by its path relative to the hashed directory or to
	## `dist/`, and its bytes.
	Asset : { path : Str, bytes : List(U8) }

	## Build `dist/`, replacing what was there.
	run! : () => Try({}, _)
	run! = || {
		if !(Path.exists!(Path.utf8("main.roc"))?) {
			return Err(NoMainRoc)
		}
		if !(Path.exists!(Path.utf8("index.html"))?) {
			return Err(NoIndexHtml)
		}
		version = Compiler.version!()?
		opt = if (Compiler.has_broken_optimizer(version)) "dev" else "size"
		Path.create_all!(Path.utf8(".signals/build"))?
		if opt == "dev" {
			Stdout.line!("SKIP optimized build (${Compiler.optimizer_issue}): Roc ${version} crashes in its optimizer. Building with --opt=dev; this output is larger and slower. The next nightly retries --opt=size.")?
		} else {
			Stdout.line!("Building the app with `roc build --opt=size`, which takes longer than a development build...")?
		}
		wasm = ".signals/build/app.wasm"
		match Compiler.build!({ target: "wasm32", opt, output: wasm })? {
			Built(_) => {}
			Failed(report) => return Err(BuildFailed({ report, version }))
		}
		members = Project.members!()?
		var $assets = [{ path: "app.wasm", bytes: Path.read_bytes!(Path.utf8(wasm))? }]
		for file in Bundle.runtime_files {
			$assets = $assets.append({ path: file.path, bytes: file.text.to_utf8() })
		}
		var $public = []
		for member in members {
			match member.role {
				Asset => {
					$assets = $assets.append({ path: member.path, bytes: Path.read_bytes!(Path.utf8(member.path))? })
				}
				Public => {
					$public = $public.append({ path: member.path.drop_prefix("public/"), bytes: Path.read_bytes!(Path.utf8(member.path))? })
				}
				_ => {}
			}
		}
		assets = $assets
		directory = "assets/${Dist.hash(assets)}"
		page = Dist.rewrite(Path.read_utf8!(Path.utf8("index.html"))?, { names: assets.map(|a| a.path), directory })
		if Path.exists!(Path.utf8("dist"))? {
			Path.delete_all!(Path.utf8("dist"))?
		}
		written = [{ path: "index.html", bytes: page.to_utf8() }]
			.concat(assets.map(|a| { ..a, path: "${directory}/${a.path}" }))
			.concat($public)
		for file in written {
			target = "dist/${file.path}"
			Path.create_all!(Path.utf8(Str.join_with(target.split_on("/").drop_last(1), "/")))?
			Path.write_bytes!(Path.utf8(target), file.bytes)?
		}
		Stdout.line!(Dist.summary(written))?
		Ok({})
	}

	## The name of the hashed directory: 64-bit FNV-1a over every file's
	## path and bytes, in order, as 16 hexadecimal digits. It changes
	## whenever any file in it changes, so a browser may cache the directory
	## for ever; it is a name, not a security measure.
	hash : List(Asset) -> Str
	hash = |assets| {
		var $state = 14695981039346656037
		for asset in assets {
			for byte in asset.path.to_utf8().append(0).concat(asset.bytes).append(0) {
				$state = U64.times_wrap(U64.bitwise_xor($state, byte.to_u64()), 1099511628211)
			}
		}
		hex($state)
	}

	## The page with each quoted relative URL that names one of `names`
	## (written plainly or starting `./`) pointed into `directory`. Nothing
	## else changes.
	rewrite : Str, { names : List(Str), directory : Str } -> Str
	rewrite = |page, { names, directory }| {
		var $out = page
		for name in names {
			for quote in ["\"", "'"] {
				for prefix in ["", "./"] {
					$out = $out.replace_each("${quote}${prefix}${name}${quote}", "${quote}${prefix}${directory}/${name}${quote}")
				}
			}
		}
		$out
	}

	## What `build` prints: every file it wrote, with its size, and how to
	## serve them.
	summary : List(Asset) -> Str
	summary = |files| {
		width = files.map(|f| f.path.count_utf8_bytes()).fold(0, |a, b| if (a > b) a else b)
		rows = files.map(|f| "  dist/${f.path}${Str.repeat(" ", width - f.path.count_utf8_bytes())}  ${size(f.bytes.len())}")
		"Built the app into dist/:\n\n${Str.join_with(rows, "\n")}\n\nServe dist/ from any static file server: .mjs files as text/javascript and app.wasm as application/wasm. The files under assets/ never change under their names, so they may be cached for ever; index.html should not be cached."
	}
}

size : U64 -> Str
size = |bytes|
	if bytes < 10 * 1024 {
		"${bytes.to_str()} B"
	} else {
		"${(bytes // 1024).to_str()} KB"
	}

hex : U64 -> Str
hex = |value| {
	digits = "0123456789abcdef".to_utf8()
	shifts : List(U8)
	shifts = [60, 56, 52, 48, 44, 40, 36, 32, 28, 24, 20, 16, 12, 8, 4, 0]
	Str.from_utf8_lossy(shifts.map(|shift| digits.get(value.shr_wrap(shift).bitwise_and(15)) ?? '0'))
}

## Only the page's quoted URLs that name a hashed file are rewritten, in
## either quote and with or without `./`.
expect {
	page =
		\\<link href="style.css"><script type="module">
		\\import { mountRocEngineApp } from "./runtime.mjs";
		\\await mountRocEngineApp({ wasmUrl: 'app.wasm', root: x });
		\\fetch("public-data.csv"); // not hashed
		\\</script><a href="/app.wasm">app.wasm</a>
	actual = Dist.rewrite(page, { names: ["app.wasm", "runtime.mjs", "style.css"], directory: "assets/h" })
	expected =
		\\<link href="assets/h/style.css"><script type="module">
		\\import { mountRocEngineApp } from "./assets/h/runtime.mjs";
		\\await mountRocEngineApp({ wasmUrl: 'assets/h/app.wasm', root: x });
		\\fetch("public-data.csv"); // not hashed
		\\</script><a href="/app.wasm">app.wasm</a>
	actual == expected
}

## A file in a subdirectory is not rewritten again by a shorter name.
expect Dist.rewrite("\"js/app.mjs\" \"app.mjs\"", { names: ["js/app.mjs", "app.mjs"], directory: "a/h" }) == "\"a/h/js/app.mjs\" \"a/h/app.mjs\""

## The hash is FNV-1a, and any change to a name or a byte changes it.
expect {
	one = Dist.hash([{ path: "a", bytes: [1, 2] }])
	actual =
		\\empty: ${Dist.hash([])}
		\\byte changed: ${Str.inspect(one == Dist.hash([{ path: "a", bytes: [1, 3] }]))}
		\\name changed: ${Str.inspect(one == Dist.hash([{ path: "b", bytes: [1, 2] }]))}
	expected =
		\\empty: cbf29ce484222325
		\\byte changed: False
		\\name changed: False
	actual == expected
}
