import cli.Path
import Proc
import SpecSuite

## The documentation's code samples. Every Roc sample in `www/content` comes
## from a file under `www/samples/` through the `sample` shortcode, so the
## `check` task can compile it: each sample app is `roc check`ed and its
## top-level `expect`s run (`roc test`), and a sample directory with `specs/`
## has them run natively and in Chrome.
DocSamples := [].{
	samples_dir = "www/samples"

	## One `{{ sample(file="...", region="...") }}` use in a page.
	Use : { file : Str, region : Str }

	## The sample uses in a page's text, in order.
	uses : Str -> List(Use)
	uses = |text| {
		var $out = []
		for piece in text.split_on("{{ sample(").drop_first(1) {
			args = piece.split_on(") }}").first() ?? ""
			$out = $out.append({ file: DocSamples.arg(args, "file"), region: DocSamples.arg(args, "region") })
		}
		$out
	}

	## The value of `name="value"` in a shortcode's arguments ("" if absent).
	arg : Str, Str -> Str
	arg = |args, name|
		match args.split_on("${name}=\"") {
			[_, rest, ..] => rest.split_on("\"").first() ?? ""
			_ => ""
		}

	## The lines of `source` between `# region NAME` and `# endregion NAME`,
	## as the `sample` shortcode cuts them. Each marker is the whole end of
	## its line: `# endregion row` is followed by the end of the line or of
	## the file, so a region `row` does not end at `# endregion row-state`.
	region_of : Str, Str -> Try(Str, [NoRegion])
	region_of = |source, region|
		match "${source}\n".split_on("# region ${region}\n") {
			[_, rest, ..] =>
				match rest.split_on("# endregion ${region}\n") {
					[inside, _, ..] => Ok(inside)
					_ => Err(NoRegion)
				}
			_ => Err(NoRegion)
		}

	## Problems with a page: an inline Roc block (which nothing would
	## compile), a missing sample, or a region the sample does not mark.
	page_problems : Str, Str, (Str -> Try(Str, [Missing])) -> List(Str)
	page_problems = |page, text, read| {
		var $out = if (text.contains("```roc")) ["${page}: inline ```roc block; put Roc code in ${DocSamples.samples_dir}/ and use the sample shortcode"] else []
		for { file, region } in DocSamples.uses(text) {
			$out = match read(file) {
				Err(Missing) => $out.append("${page}: sample ${file} does not exist")
				Ok(source) =>
					if region == "" or DocSamples.region_of(source, region).is_ok() {
						$out
					} else {
						$out.append("${page}: ${file} has no region ${region}")
					}
			}
		}
		$out
	}

	## Check the docs pages and samples: every page's sample references
	## resolve, every sample app type-checks and passes its top-level
	## `expect`s (the pages show them as the tests of a decision), and every
	## sample with a `specs/` directory passes its specs. A failure is a
	## reported problem.
	check! : SpecSuite.Options => Try(List(Str), _)
	check! = |o| {
		var $problems = []
		for page in SpecSuite.files_with!("www/content/docs", ".md")? {
			text = Path.read_utf8!(Path.utf8(page))?
			var $found = []
			for { file, .. } in DocSamples.uses(text) {
				$found = match Path.read_utf8!(Path.utf8("${DocSamples.samples_dir}/${file}")) {
					Ok(source) => $found.append((file, source))
					Err(_) => $found
				}
			}
			found = $found
			read = |file| found.find_first(|(f, _)| f == file).map_ok(|(_, source)| source).map_err(|_| Missing)
			$problems = $problems.concat(DocSamples.page_problems(page, text, read))
		}
		samples = DocSamples.apps!()?
		limit = Proc.compiler_jobs!(App)?
		Proc.note!("== docs samples: roc check and roc test of ${samples.len().to_str()} sample apps, ${limit.to_str()} at a time")
		checked = Proc.parallel!(samples.map(|sample| { program: o.compiler, args: ["check", sample], cwd: "." }), limit)?
		typed = List.map2(samples, checked, |sample, r| (sample, r.code)).keep_oks(|(sample, code)| if (code == 0) Ok(sample) else Err(Untyped))
		for sample in samples.drop_if(|sample| typed.contains(sample)) {
			$problems = $problems.append("docs sample ${sample} does not type-check")
		}
		# `roc test` of an app runs the expects of every module it imports.
		tested = Proc.parallel!(typed.map(|sample| { program: o.compiler, args: ["test", sample], cwd: "." }), limit)?
		for (sample, r) in List.map2(typed, tested, |sample, r| (sample, r)) {
			if r.code != 0 {
				$problems = $problems.append("docs sample ${sample}: roc test fails (an expect of the sample does not hold)")
			}
		}
		var $with_specs = []
		dirs = DocSamples.dirs!()?
		if dirs.is_empty() {
			$problems = $problems.append("${DocSamples.samples_dir} holds no sample directory, so the docs samples stage would pass having built and run nothing")
		}
		for dir in dirs {
			if Path.exists!(Path.utf8("${dir}/specs"))? and SpecSuite.files_with!("${dir}/specs", ".scm")?.is_empty() {
				$problems = $problems.append("docs sample ${dir}/specs holds no spec, so its runs would pass having checked nothing")
			} else if Path.exists!(Path.utf8("${dir}/specs"))? {
				out = "${o.build_dir}/docs/${dir}"
				name = "docs-${dir.split_on("/").last() ?? dir}"
				Path.create_all!(Path.utf8(out))?
				Path.create_all!(Path.utf8("${o.build_dir}/wasm/${name}"))?
				$with_specs = $with_specs.append({ dir, name, runner: "${out}/runner", wasm: "${out}/app.wasm" })
			}
		}
		with_specs = $with_specs
		Proc.note!("== docs samples: native and browser builds of the ${with_specs.len().to_str()} samples with specs, ${limit.to_str()} at a time")
		builds = Proc.parallel!(
			with_specs.map(|s| [SpecSuite.build_job(o, "dev", "${s.dir}/main.roc", o.target, s.runner), SpecSuite.build_job(o, "dev", "${s.dir}/main.roc", "wasm32", s.wasm)]).join(),
			limit,
		)?
		for (sample, index) in with_specs.map_with_index(|sample, index| (sample, index)) {
			native = builds.get(2 * index) ?? { code: -1, output: "" }
			web = builds.get(2 * index + 1) ?? { code: -1, output: "" }
			if native.code != 0 or web.code != 0 {
				$problems = $problems.append("docs sample ${sample.dir} does not build")
			} else {
				specs = SpecSuite.files_with!("${sample.dir}/specs", ".scm")?
				in_native = SpecSuite.native_specs!({ example: sample.dir, runner: sample.runner, specs })?
				in_browser = SpecSuite.browser_specs!(o, { example: sample.name, runner: sample.runner, wasm: sample.wasm, specs, skip: [] })?
				for t in [(Native, in_native), (Browser, in_browser)] {
					(runner_kind, tally) = t
					Proc.note!(SpecSuite.summary(sample.dir, runner_kind, tally))
					$problems = $problems.concat(tally.problems)
				}
			}
		}
		Ok($problems)
	}

	## Publish maintained sample sources beside the site for download. The site
	## supplies its Roc-only publication transform so display and downloads use
	## the same package URL placeholder without adding parser dependencies here.
	## Other file types are copied byte for byte; checked source is never edited.
	copy! : { root : Str, dist : Str, publish_roc : Str -> Str } => Try({}, _)
	copy! = |{ root, dist, publish_roc }| {
		source = "${root}/${DocSamples.samples_dir}"
		for file in SpecSuite.files_under!(source, "")? {
			name = file.drop_prefix("${source}/")
			if is_source_download(name) {
				target = "${dist}/samples/${name}"
				parent = Str.join_with(target.split_on("/").drop_last(1), "/")
				Path.create_all!(Path.utf8(parent))?
				if name.ends_with(".roc") {
					Path.write_utf8!(Path.utf8(target), publish_roc(Path.read_utf8!(Path.utf8(file))?))?
				} else {
					Path.copy!(Path.utf8(file), Path.utf8(target))?
				}
			}
		}
		Ok({})
	}

	## The sample directories: one app each.
	dirs! : () => Try(List(Str), _)
	dirs! = || {
		var $out = []
		for entry in Path.list!(Path.utf8(DocSamples.samples_dir))? {
			if Path.is_dir!(entry)? {
				$out = $out.append(Path.display(entry))
			}
		}
		Ok($out.sort_with(SpecSuite.compare_str))
	}

	## Every sample application: single-file samples and each directory's
	## `main.roc`.
	apps! : () => Try(List(Str), _)
	apps! = || {
		var $out = SpecSuite.roc_files!(DocSamples.samples_dir)?
		for dir in DocSamples.dirs!()? {
			$out = $out.concat(SpecSuite.roc_files!(dir)?.keep_if(|f| f.ends_with("/main.roc")))
		}
		Ok($out)
	}
}

## Shortcode uses are found with their file and region.
expect {
	text = "a\n{{ sample(file=\"counter/Counter.roc\", region=\"view\") }}\nb {{ sample(file=\"x.roc\") }}"
	DocSamples.uses(text) == [{ file: "counter/Counter.roc", region: "view" }, { file: "x.roc", region: "" }]
}

## Inline Roc, missing files and missing regions are each reported.
expect {
	read = |file| if (file == "a.roc") Ok("# region r\nx\n# endregion r\n") else Err(Missing)
	ok = DocSamples.page_problems("p", "{{ sample(file=\"a.roc\", region=\"r\") }}", read)
	bad = DocSamples.page_problems("p", "```roc\nx\n```\n{{ sample(file=\"b.roc\") }}{{ sample(file=\"a.roc\", region=\"q\") }}", read)
	ok == [] and bad.len() == 3
}

## A region ends at its own end marker, whole: not at the marker of a region
## whose name it begins, and at the end of the file as at the end of a line.
expect {
	source = "a\n# region row\nb\n# region row-state\nc\n# endregion row-state\nd\n# endregion row\ne\n# region last\nf\n# endregion last"
	outer = DocSamples.region_of(source, "row")
	inner = DocSamples.region_of(source, "row-state")
	last = DocSamples.region_of(source, "last")
	missing = DocSamples.region_of(source, "ro")
	(outer, inner, last, missing) == (Ok("b\n# region row-state\nc\n# endregion row-state\nd\n"), Ok("c\n"), Ok("f\n"), Err(NoRegion))
}

## A region whose end marker is only the start of another's is not marked.
expect {
	read = |_| Ok("# region row\nx\n# endregion row-state\n")
	DocSamples.page_problems("p", "{{ sample(file=\"a.roc\", region=\"row\") }}", read) == ["p: a.roc has no region row"]
}

## Source downloads exclude executables and the tool's generated directories.
is_source_download : Str -> Bool
is_source_download = |name|
	!name.split_on("/").any(|part| part.starts_with(".") or part == "dist")
		and [".roc", ".scm", ".html", ".mjs"].any(|suffix| name.ends_with(suffix))

## The published sample tree contains maintained source, not local build output.
expect ["todos/Todos.roc", "todos/specs/add.scm", "counter/index.html", "ports/notes-ports.mjs", "todos/main", "todos/main.wasm", "todos/.signals/run.mjs", "todos/dist/index.html"].map(is_source_download) == [True, True, True, True, False, False, False, False]
