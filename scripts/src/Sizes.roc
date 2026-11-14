import cli.Path
import ExampleFiles
import Proc
import SpecSuite

## Measure shipped bytes with Node's zlib. Only the platform JavaScript has
## recorded figures: example modules also follow the floating compiler, and
## development-only scripts do not add bytes to a production page.
Sizes := [].{
	data_file = "scripts/src/runtime-sizes.tsv"
	tolerance = 16.U64

	## Scripts loaded only by development tooling, reported without a gate.
	debug_files : List(Str)
	debug_files = ["cli/dev-client.js"]

	Measurement : { path : Str, raw : U64, gzip : U64, brotli : U64 }
	Figure : { path : Str, gzip : U64 }

	## Parse the deliberately small line format, refusing malformed or duplicate
	## figures rather than leaving a runtime file unchecked.
	figures : Str -> Try(List(Figure), [BadSizeFigure(Str)])
	figures = |text| {
		var $out = []
		for line in text.split_on("\n").map(Str.trim).drop_if(|line| line.is_empty() or line.starts_with("#")) {
			figure = match line.split_on("\t") {
				[path, size] if path != "" => { path, gzip: U64.from_str(size) ? |_| BadSizeFigure(line) }
				_ => return Err(BadSizeFigure(line))
			}
			if $out.any(|previous| previous.path == figure.path) {
				return Err(BadSizeFigure("duplicate ${figure.path}"))
			}
			$out = $out.append(figure)
		}
		Ok($out)
	}

	## The gate is symmetric: both growth and savings require an explicit
	## recorded change. A new runtime file must have its own figure.
	problems : List(Figure), List(Measurement) -> List(Str)
	problems = |recorded, measured| {
		var $out = []
		for measurement in measured {
			match recorded.find_first(|figure| figure.path == measurement.path) {
				Err(_) => {
					$out = $out.append("${measurement.path}: no recorded gzip size in ${Sizes.data_file} (measured ${measurement.gzip.to_str()} bytes)")
				}
				Ok(figure) => {
					difference = measurement.gzip.max(figure.gzip) - measurement.gzip.min(figure.gzip)
					if difference > Sizes.tolerance {
						$out = $out.append("${measurement.path}: gzip ${measurement.gzip.to_str()} bytes, recorded ${figure.gzip.to_str()}, tolerance +/-${Sizes.tolerance.to_str()}; update ${Sizes.data_file} and explain the change in the PR")
					}
				}
			}
		}
		for figure in recorded {
			if !measured.any(|measurement| measurement.path == figure.path) {
				$out = $out.append("${figure.path}: recorded gzip figure is absent from SpecSuite.runtime_files")
			}
		}
		$out
	}

	## Compression is delegated only to the pinned Node tool. Its exact output
	## is checked against the requested paths before any figure is trusted.
	measure! : { root : Str, node : Str }, List(Str) => Try(List(Measurement), _)
	measure! = |o, paths| {
		bytes = Proc.capture!({ program: o.node, args: ["scripts/compress-sizes.mjs"].concat(paths), cwd: o.root })?
		text = Str.from_utf8(bytes) ? |_| BadCompressionOutput
		var $out = []
		for line in text.split_on("\n").drop_if(Str.is_empty) {
			measurement = match line.split_on("\t") {
				[path, raw, gzip, brotli] => {
					path,
					raw: U64.from_str(raw) ? |_| BadCompressionOutput,
					gzip: U64.from_str(gzip) ? |_| BadCompressionOutput,
					brotli: U64.from_str(brotli) ? |_| BadCompressionOutput,
				}
				_ => return Err(BadCompressionOutput)
			}
			$out = $out.append(measurement)
		}
		if $out.map(|measurement| measurement.path) != paths {
			return Err(BadCompressionOutput)
		}
		Ok($out)
	}

	## Check every runtime file in the release's authoritative inventory. The
	## helper prints the actual figures too, so a source change is reviewable.
	check_runtime! : { root : Str, node : Str } => Try(List(Str), _)
	check_runtime! = |o| {
		recorded = Sizes.figures(Path.read_utf8!(Path.utf8("${o.root}/${Sizes.data_file}"))?)?
		measured = Sizes.measure!(o, SpecSuite.runtime_files.map(|name| "platform/${name}"))?
		for measurement in measured {
			Sizes.print!("runtime", measurement)
		}
		Ok(Sizes.problems(recorded, measured))
	}

	## Catalogue order is the report order. Read only the example table's
	## slug, using the same restricted plain-string rule as ExampleFiles.
	examples : Str -> Try(List(Str), [BadExampleSlug(Str)])
	examples = |text| {
		var $table = ""
		var $slugs = []
		var $awaiting_slug = False
		for line in text.split_on("\n").map(Str.trim) {
			if line.starts_with("[") {
				if line == "[[examples]]" {
					if $awaiting_slug {
						return Err(BadExampleSlug("example has no slug"))
					}
					$awaiting_slug = True
				}
				$table = line
			} else if $table == "[[examples]]" and line.starts_with("slug = ") {
				slug = ExampleFiles.file_name(line.drop_prefix("slug = ")) ? |_| BadExampleSlug(line)
				if !$awaiting_slug or $slugs.contains(slug) {
					return Err(BadExampleSlug(line))
				}
				$awaiting_slug = False
				$slugs = $slugs.append(slug)
			}
		}
		if $awaiting_slug {
			return Err(BadExampleSlug("example has no slug"))
		}
		Ok($slugs)
	}

	## Build every catalogue example at the shipping optimisation level in a
	## separate directory; a development module can never stand in for it.
	## Sizes are observations, without thresholds. An unavailable build is a
	## failed check, because it cannot supply the required size report.
	report! : SpecSuite.Options => Try(List(Str), _)
	report! = |o| {
		options = { root: o.root, node: o.node }
		for measurement in Sizes.measure!(options, Sizes.debug_files)? {
			Sizes.print!("debug (reported)", measurement)
		}
		slugs = Sizes.examples(Path.read_utf8!(Path.utf8("${o.root}/${ExampleFiles.catalog}"))?)?
		var $jobs = []
		for slug in slugs {
			dir = "${o.build_dir}/sizes/${slug}"
			Path.create_all!(Path.utf8(dir))?
			$jobs = $jobs.append(SpecSuite.build_job(o, "size", "examples/${slug}/main.roc", "wasm32", "${dir}/app.wasm"))
		}
		results = Proc.parallel!($jobs, Proc.compiler_jobs!()?)?
		var $failures = []
		for (slug, result) in List.map2(slugs, results, |slug, result| (slug, result)) {
			if result.code != 0 {
				$failures = $failures.append("${slug}: --opt=size module unavailable (build exit ${result.code.to_str()})")
			} else {
				for measurement in Sizes.measure!(options, ["${o.build_dir}/sizes/${slug}/app.wasm"])? {
					Sizes.print!("example ${slug} (reported)", measurement)
				}
			}
		}
		Ok($failures)
	}

	print! : Str, Measurement => {}
	print! = |kind, measurement| Proc.note!("size ${kind} ${measurement.path}: raw ${measurement.raw.to_str()}, gzip ${measurement.gzip.to_str()}, brotli ${measurement.brotli.to_str()} bytes")
}

## The tolerance includes its two endpoints and fails both directions beyond it.
expect {
	recorded = [{ path: "runtime.mjs", gzip: 1000 }]
	[984, 1000, 1016].all(|gzip| Sizes.problems(recorded, [{ path: "runtime.mjs", raw: 2000, gzip, brotli: 900 }]).is_empty())
}

## Both growth and savings beyond the tolerance require a recorded update.
expect {
	recorded = [{ path: "runtime.mjs", gzip: 1000 }]
	[983, 1017].all(|gzip| Sizes.problems(recorded, [{ path: "runtime.mjs", raw: 2000, gzip, brotli: 900 }]).len() == 1)
}

## A newly shipped runtime file cannot pass without a figure.
expect Sizes.problems([], [{ path: "new.mjs", raw: 50, gzip: 30, brotli: 25 }]).len() == 1

## Removing a runtime file also removes its obsolete recorded figure.
expect Sizes.problems([{ path: "old.mjs", gzip: 100 }], []).len() == 1

## Duplicate or malformed figures never turn off the gate.
expect {
	["x\t2\nx\t3", "x\tnan", "x\t2\t3"].all(
		|text| match Sizes.figures(text) {
			Err(_) => True
			Ok(_) => False
		},
	)
}

## Example sizes follow the catalogue, including future additions, without reading script tables as examples.
expect {
	text = "[[examples]]\nslug = \"one\"\n[[examples.scripts]]\nslug = \"ignored\"\n[[examples]]\nslug = \"two\"\n"
	Sizes.examples(text)? == ["one", "two"]
}

## An example with no slug or two slug fields cannot disappear from the report.
expect {
	["[[examples]]\n", "[[examples]]\n[[examples]]\nslug = \"two\"", "[[examples]]\nslug = \"one\"\nslug = \"two\""].all(
		|text| match Sizes.examples(text) {
			Err(_) => True
			Ok(_) => False
		},
	)
}
