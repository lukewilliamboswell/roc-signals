import cli.Path
import Proc
import SpecSuite

## The documentation's code samples. Every Roc sample in `www/content` comes
## from a file under `www/samples/` through the `sample` shortcode, so the
## `check` task can compile it: each sample app is `roc check`ed, and a sample
## directory with a `main-test.roc` has its `specs/*.scm` run natively.
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

	## Problems with a page: an inline Roc block (which nothing would
	## compile), a missing sample, or a region the sample does not mark.
	page_problems : Str, Str, (Str -> Try(Str, [Missing])) -> List(Str)
	page_problems = |page, text, read| {
		var $out = if (text.contains("```roc")) ["${page}: inline ```roc block; put Roc code in ${DocSamples.samples_dir}/ and use the sample shortcode"] else []
		for { file, region } in DocSamples.uses(text) {
			$out = match read(file) {
				Err(Missing) => $out.append("${page}: sample ${file} does not exist")
				Ok(source) =>
					if region == "" or (source.contains("# region ${region}\n") and source.contains("# endregion ${region}")) {
						$out
					} else {
						$out.append("${page}: ${file} has no region ${region}")
					}
			}
		}
		$out
	}

	## Check the docs pages and samples: every page's sample references
	## resolve, every sample app type-checks, and every sample with a
	## `main-test.roc` passes its specs. A failure is a reported problem.
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
		for sample in DocSamples.apps!()? {
			{ code, .. } = Proc.output!({ program: o.compiler, args: ["check", sample], cwd: "." })?
			if code != 0 {
				$problems = $problems.append("docs sample ${sample} does not type-check")
			}
		}
		for dir in DocSamples.dirs!()? {
			if Path.exists!(Path.utf8("${dir}/main-test.roc"))? {
				out = "${o.build_dir}/docs/${dir}"
				runner = "${out}/runner"
				wasm = "${out}/app.wasm"
				name = "docs-${dir.split_on("/").last() ?? dir}"
				Path.create_all!(Path.utf8(out))?
				Path.create_all!(Path.utf8("${o.build_dir}/wasm/${name}"))?
				native = Proc.output!(SpecSuite.build_job(o, "dev", "${dir}/main-test.roc", "", runner))?
				web = Proc.output!(SpecSuite.build_job(o, "dev", "${dir}/main-web.roc", "wasm32", wasm))?
				if native.code != 0 or web.code != 0 {
					$problems = $problems.append("docs sample ${dir} does not build")
				} else {
					specs = SpecSuite.files_with!("${dir}/specs", ".scm")?
					in_native = SpecSuite.tally(SpecSuite.empty_tally, dir, Native, SpecSuite.run_native!(o, runner, specs)?)
					in_browser = SpecSuite.tally(SpecSuite.empty_tally, dir, Browser, SpecSuite.run_browser!(o, name, runner, wasm, specs)?)
					for t in [(Native, in_native), (Browser, in_browser)] {
						(runner_kind, tally) = t
						Proc.note!(SpecSuite.summary(dir, runner_kind, tally))
						$problems = $problems.concat(tally.problems).concat(if (tally.passed == specs.len()) [] else ["docs sample ${dir} (${Str.inspect(runner_kind)}): ${tally.passed.to_str()} of ${specs.len().to_str()} specs passed"])
					}
				}
			}
		}
		Ok($problems)
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
	## `main-*.roc`.
	apps! : () => Try(List(Str), _)
	apps! = || {
		var $out = SpecSuite.roc_files!(DocSamples.samples_dir)?
		for dir in DocSamples.dirs!()? {
			$out = $out.concat(SpecSuite.roc_files!(dir)?.keep_if(|f| f.contains("/main-")))
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
