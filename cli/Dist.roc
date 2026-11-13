import cli.Path
import cli.Cmd
import cli.Env
import cli.OsStr
import cli.System
import Specs
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

	## Explicit first-page routes; an ordinary build emits no pictures.
	Options := { pictures : List(Str) ?? [] }

	## The native runner owns markup inspection and URL-to-output projection.
	## JSON decoding is strict UTF-8 and uses Roc's built-in typed parser.
	Picture : { protocol : Str, url : Str, path : Str, page : Str, metadata : List(U8) }

	## Stage the complete output before publishing it. Replacing an existing
	## directory uses backup/rename with rollback, rather than an atomic exchange.
	run! : Options => Try({}, _)
	run! = |options| {
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
		template = Path.read_utf8!(Path.utf8("index.html"))?
		staging = ".signals/build/dist-next"
		previous = ".signals/build/dist-previous"
		if Path.exists!(Path.utf8(previous))? {
			return Err(PublicationInterrupted(previous))
		}
		if Path.exists!(Path.utf8(staging))? {
			Path.delete_all!(Path.utf8(staging))?
		}
		Path.create_all!(Path.utf8(staging))?
		resources = assets.map(|a| { ..a, path: "${directory}/${a.path}" }).concat($public)
		Dist.validate_outputs(resources)?
		for file in resources {
			Dist.stage_file!(file, { staging })?
		}
		written = resources.map(|file| { path: file.path, bytes: file.bytes.len() })
		pages = if options.pictures.is_empty() {
			page = { path: "index.html", bytes: Dist.rewrite(template, { names: assets.map(|a| a.path), directory }).to_utf8() }
			Dist.validate_outputs([{ ..page, bytes: [] }].concat(resources))?
			Dist.stage_file!(page, { staging })?
			[{ path: page.path, bytes: page.bytes.len() }]
		} else {
			Dist.stage_pictures!(options.pictures, { staging, names: assets.map(|a| a.path), directory, reserved: resources.map(|file| file.path), template })?
		}
		all_outputs = pages.concat(written)
		had_previous = Path.exists!(Path.utf8("dist"))?
		if had_previous {
			Path.rename!(Path.utf8("dist"), Path.utf8(previous))?
		}
		match Path.rename!(Path.utf8(staging), Path.utf8("dist")) {
			Ok(_) => {}
			Err(problem) => {
				if had_previous {
					Path.rename!(Path.utf8(previous), Path.utf8("dist")) ? |_| PublicationRollbackFailed(previous)
				}
				return Err(problem)
			}
		}
		if had_previous {
			Path.delete_all!(Path.utf8(previous)) ? |_| PublicationCleanupFailed(previous)
		}
		Stdout.line!(Dist.summary(all_outputs))?
		Ok({})
	}

	## Run one real native app mount for each explicit route. All responses
	## are captured and validated before the existing dist directory is touched.
	stage_pictures! : List(Str), { staging : Str, names : List(Str), directory : Str, reserved : List(Str), template : Str } => Try(List({ path : Str, bytes : U64 }), _)
	stage_pictures! = |urls, { staging, names, directory, reserved, template }| {
		target = Specs.target_of(System.target!())
		if !Bundle.spec_targets.contains(target) {
			return Err(PictureUnsupported(target))
		}
		runner = ".signals/build/picture-runner${if target.ends_with("win") ".exe" else ""}"
		version = Compiler.version!()?
		match Compiler.build!({ target, opt: "dev", output: runner })? {
			Built(_) => {}
			Failed(report) => return Err(BuildFailed({ report, version }))
		}
		program = "${Project.with_slashes(Path.display(Env.cwd!()?))}/${runner}"
		var $routes = []
		var $outputs = reserved.map(|path| { path, bytes: [] })
		var $written = []
		for url in urls {
			output = Cmd.new(OsStr.from_str(program)).args(["--picture-path", url].map(OsStr.from_str)).stdout(Capture).stderr(Capture).output_limit(MaxBytes(1048576)).run!() ? |problem| PictureRunnerFailed({ url, reason: match problem {
				CmdErr(error) => error.to_str()
				Interrupted => "command interrupted"
			} })
			if output.status != Exited(0) {
				return Err(PictureFailed({ url, report: Str.from_utf8_lossy(output.stderr_bytes) }))
			}
			text = Str.from_utf8(output.stdout_bytes) ? |_| PictureResponseInvalid(url)
			route : { protocol : Str, url : Str, path : Str }
			route = Json.parse(text) ? |_| PictureResponseInvalid(url)
			if route.protocol != "roc-signals/picture-path/v1" or route.url != url {
				return Err(PictureResponseInvalid(url))
			}
			Dist.validate_output_path(route.path)?
			if $routes.any(|prior| Dist.output_key(prior.path) == Dist.output_key(route.path)) {
				return Err(PictureRouteCollision({ first: $routes.find_first(|prior| Dist.output_key(prior.path) == Dist.output_key(route.path)).map_ok(|prior| prior.url) ?? crash "Dist.stage_pictures!: prior route exists", second: url, path: route.path }))
			}
			$routes = $routes.append({ path: route.path, url })
			$outputs = $outputs.append({ path: route.path, bytes: [] })
		}
		Dist.validate_outputs($outputs)?
		projected = ".signals/build/picture-template.html"
		for route in $routes {
			url = route.url
			depth = route.path.split_on("/").len() - 1
			prefix = Str.repeat("../", depth)
			# Rewrite only the original host template. A rendered app attribute
			# or text which resembles an asset name must remain untouched.
			Path.write_utf8!(Path.utf8(projected), Dist.rewrite(template, { names, directory: "${prefix}${directory}" }))?
			output = Cmd.new(OsStr.from_str(program)).args(["--prerender", url, "--template", projected].map(OsStr.from_str)).stdout(Capture).stderr(Capture).output_limit(MaxBytes(134217728)).run!() ? |problem| PictureRunnerFailed({ url, reason: match problem {
				CmdErr(error) => error.to_str()
				Interrupted => "command interrupted"
			} })
			if output.status != Exited(0) {
				return Err(PictureFailed({ url, report: Str.from_utf8_lossy(output.stderr_bytes) }))
			}
			text = Str.from_utf8(output.stdout_bytes) ? |_| PictureResponseInvalid(url)
			picture : Picture
			picture = Json.parse(text) ? |_| PictureResponseInvalid(url)
			if picture.protocol != "roc-signals/prerender/v1" or picture.url != url or picture.path != route.path or picture.page.is_empty() or picture.page.count_utf8_bytes() > 16777216 or !picture.metadata.is_empty() {
				return Err(PictureResponseInvalid(url))
			}
			# Stage 1 emits no envelope; no fake adoption metadata is accepted.
			page = { path: picture.path, bytes: picture.page.to_utf8() }
			Dist.stage_file!(page, { staging })?
			$written = $written.append({ path: page.path, bytes: page.bytes.len() })
		}
		Path.delete!(Path.utf8(projected))?

		Ok($written)
	}

	## Write only inside the unpublished tree. An existing target here is a
	## filesystem alias collision, even if its Unicode/case spelling differs.
	stage_file! : Asset, { staging : Str } => Try({}, _)
	stage_file! = |file, { staging }| {
		target = "${staging}/${file.path}"
		if Path.exists!(Path.utf8(target))? {
			return Err(OutputCollision({ first: "already staged filesystem target", second: file.path }))
		}
		Path.create_all!(Path.utf8(Str.join_with(target.split_on("/").drop_last(1), "/")))?
		Path.write_bytes!(Path.utf8(target), file.bytes)?
		Ok({})
	}

	## Refuse path traversal, separators hidden inside an authored component,
	## drive syntax and filesystem-reserved spellings before writing a file.
	validate_output_path : Str -> Try({}, [UnsafeOutputPath(Str)])
	validate_output_path = |path| {
		parts = path.split_on("/")
		if parts.is_empty() or parts.any(|part| part.is_empty() or part == "." or part == ".." or part.ends_with(".") or part.ends_with(" ") or part.to_utf8().any(|byte| byte < 32 or byte == 127 or [':', '\\', '<', '>', '"', '|', '?', '*'].contains(byte))) {
			return Err(UnsafeOutputPath(path))
		}
		for part in parts {
			stem = Dist.output_key(part.split_on(".").first() ?? crash "Dist.validate_output_path: nonempty component")
			if ["con", "prn", "aux", "nul", "com1", "com2", "com3", "com4", "com5", "com6", "com7", "com8", "com9", "lpt1", "lpt2", "lpt3", "lpt4", "lpt5", "lpt6", "lpt7", "lpt8", "lpt9", "com¹", "com²", "com³", "lpt¹", "lpt²", "lpt³"].contains(stem) {
				return Err(UnsafeOutputPath(path))
			}
		}
		Ok({})
	}

	## Compare output locations conservatively across supported filesystems.
	## This is path collision detection, never application or row identity.
	output_key : Str -> Str
	output_key = |path| Str.from_utf8(path.to_utf8().map(|byte| if byte >= 'A' and byte <= 'Z' byte + 32 else byte)) ?? crash "Dist.output_key: ASCII folding preserves UTF-8"

	## Files cannot overwrite one another or be both a file and a directory.
	## Check pages, hashed assets and public files as one publication plan.
	validate_outputs : List(Asset) -> Try({}, [UnsafeOutputPath(Str), OutputCollision({ first : Str, second : Str })])
	validate_outputs = |files| {
		var $known = Dict.empty()
		for file in files {
			Dist.validate_output_path(file.path)?
			key = Dist.output_key(file.path)
			match $known.get(key) {
				Ok(first) => return Err(OutputCollision({ first, second: file.path }))
				Err(_) => {}
			}
			$known = $known.insert(key, file.path)
		}
		for file in files {
			var $prefix = ""
			for part in Dist.output_key(file.path).split_on("/").drop_last(1) {
				$prefix = if $prefix.is_empty() part else "${$prefix}/${part}"
				match $known.get($prefix) {
					Ok(first) => return Err(OutputCollision({ first, second: file.path }))
					Err(_) => {}
				}
			}
		}
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
	summary : List({ path : Str, bytes : U64 }) -> Str
	summary = |files| {
		width = files.map(|f| f.path.count_utf8_bytes()).fold(0, |a, b| if (a > b) a else b)
		rows = files.map(|f| "  dist/${f.path}${Str.repeat(" ", width - f.path.count_utf8_bytes())}  ${size(f.bytes)}")
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

## Route pages, assets and public files share one namespace, including file
## versus directory prefixes and case aliases on supported deployment hosts.
expect {
    Dist.validate_outputs([{ path: "a/index.html", bytes: [] }, { path: "a", bytes: [] }]).is_err() and
    Dist.validate_outputs([{ path: "Assets/A", bytes: [] }, { path: "assets/a", bytes: [] }]).is_err()
}

## Root traversal, Windows drive syntax and reserved names cannot become output.
expect ["../index.html", "/index.html", "a//index.html", "C:/index.html", "a/CON.txt", "a/COM¹.log", "a./index.html", "a\\b/index.html"].all(|path| Dist.validate_output_path(path).is_err())

## Adjacent sibling pages do not overlap their common directory.
expect Dist.validate_outputs([{ path: "a/one/index.html", bytes: [] }, { path: "a/two/index.html", bytes: [] }]).is_ok()


## A lexical neighbour cannot hide an earlier file/directory prefix conflict.
expect Dist.validate_outputs([{ path: "a", bytes: [] }, { path: "a-file", bytes: [] }, { path: "a/b/index.html", bytes: [] }]).is_err()
