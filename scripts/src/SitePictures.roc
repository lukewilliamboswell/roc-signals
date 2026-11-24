import cli.Path
import Proc
import SpecSuite

## Produce the site's annotated example pages from the same program that
## supplies the shipping browser module. The native runner owns rendering
## and route projection. The site supplies only the outer HTML and URLs.
SitePictures := [].{
	Catalogue : { protocol : Str, entries : List(Str), root : List(U8), fallback : U32 }
	Route : { protocol : Str, url : Str, path : Str }
	Picture : { protocol : Str, url : Str, path : Str, page : Str, metadata : List(U8) }

	## Put the site loader and its platform dependencies together under a
	## name derived from their bytes so existing pages can name their build.
	copy_loader! : SpecSuite.Options, Str => Try(Str, _)
	copy_loader! = |o, dist| {
		files = ["www/static/site.mjs"].concat(SpecSuite.runtime_files.map(|name| "platform/${name}"))
		sums = Proc.capture!({ program: "sha256sum", args: files, cwd: o.root })?
		manifest = "${o.build_dir}/site-loader.sha256"
		Path.write_bytes!(Path.utf8(manifest), sums)?
		hash = SitePictures.digest!(o, manifest)?
		relative = "assets/${hash}"
		dir = "${dist}/${relative}"
		Path.create_all!(Path.utf8(dir))?
		SpecSuite.copy_runtime!(o.root, dir)?
		Path.copy!(Path.utf8("${o.root}/www/static/site.mjs"), Path.utf8("${dir}/site.mjs"))?
		Ok(relative)
	}

	## Publish each declared entry under the example's site directory.
	render! : SpecSuite.Options, { example : Str, dist : Str, loader : Str } => Try({}, _)
	render! = |o, { example, dist, loader }| {
		program = SpecSuite.runner_of(o, example)
		directory = "${dist}/examples/${example}"
		source = Path.read_utf8!(Path.utf8("${directory}/index.html"))?
		module_file = SpecSuite.size_wasm_of(o, example)
		token = SitePictures.digest!(o, module_file)?
		asset = "assets/${token}"
		Path.create_all!(Path.utf8("${directory}/${asset}"))?
		Path.copy!(Path.utf8(module_file), Path.utf8("${directory}/${asset}/app.wasm"))?
		raw_catalogue = Proc.capture!({ program, args: ["--startup-catalogue"], cwd: o.root })?
		catalogue : Catalogue
		catalogue = Json.parse(Str.from_utf8(raw_catalogue) ? |_| InvalidSiteCatalogue(example)) ? |_| InvalidSiteCatalogue(example)
		if catalogue.protocol != "roc-signals/startup-catalogue/v1" or !catalogue.entries.contains("/") {
			return Err(InvalidSiteCatalogue(example))
		}
		template = "${o.build_dir}/site-picture-template.html"
		var $paths = []
		for url in catalogue.entries {
			raw_route = Proc.capture!({ program, args: ["--picture-path", url], cwd: o.root })?
			route : Route
			route = Json.parse(Str.from_utf8(raw_route) ? |_| InvalidSiteRoute({ example, url })) ? |_| InvalidSiteRoute({ example, url })
			if route.protocol != "roc-signals/picture-path/v1" or route.url != url or $paths.contains(route.path) or route.path.starts_with("assets/") {
				return Err(InvalidSiteRoute({ example, url }))
			}
			$paths = $paths.append(route.path)
			depth = route.path.split_on("/").len() - 1
			prefix = Str.repeat("../", depth)
			wasm = "${prefix}${asset}/app.wasm?roc-build=${token}"
			loader_url = "${prefix}../../${loader}/site.mjs"
			page = SitePictures.project(source, { wasm, loader: loader_url }) ? |_| InvalidSiteTemplate(example)
			Path.write_utf8!(Path.utf8(template), page)?
			raw_picture = Proc.capture!({ program, args: ["--prerender", url, "--template", template, "--build-token", token], cwd: o.root })?
			picture : Picture
			picture = Json.parse(Str.from_utf8(raw_picture) ? |_| InvalidSitePicture({ example, url })) ? |_| InvalidSitePicture({ example, url })
			if picture.protocol != "roc-signals/prerender/v1" or picture.url != url or picture.path != route.path or picture.page.is_empty() or !picture.metadata.is_empty() {
				return Err(InvalidSitePicture({ example, url }))
			}
			parent = Str.join_with(route.path.split_on("/").drop_last(1), "/")
			Path.create_all!(Path.utf8("${directory}/${parent}"))?
			Path.write_utf8!(Path.utf8("${directory}/${route.path}"), picture.page)?
		}
		Ok({})
	}

	## Replace the two authored host attributes before the native renderer
	## can add app-owned markup or startup annotations.
	project : Str, { wasm : Str, loader : Str } -> Try(Str, [MissingHostAssets])
	project = |page, { wasm, loader }| {
		module_slot = "data-signals-wasm=\"__ROC_EXAMPLE_MODULE__\""
		loader_slot = "src=\"__ROC_EXAMPLE_LOADER__\""
		if page.split_on(module_slot).len() != 2 or page.split_on(loader_slot).len() != 2 {
			return Err(MissingHostAssets)
		}
		Ok(page.replace_each(module_slot, "data-signals-wasm=\"${wasm}\"").replace_each(loader_slot, "src=\"${loader}\""))
	}

	digest! : SpecSuite.Options, Str => Try(Str, _)
	digest! = |o, file| {
		result = Proc.capture!({ program: "sha256sum", args: [file], cwd: o.root })?
		digest = (Str.from_utf8(result) ? |_| InvalidSiteDigest(file)).split_on(" ").first() ? |_| InvalidSiteDigest(file)
		if digest.count_utf8_bytes() != 64 or !digest.to_utf8().all(|byte| (byte >= '0' and byte <= '9') or (byte >= 'a' and byte <= 'f')) {
			return Err(InvalidSiteDigest(file))
		}
		Ok(digest)
	}
}

## Host projection requires exactly one module receipt and one site loader.
expect {
	page = "<div data-signals-wasm=\"__ROC_EXAMPLE_MODULE__\"></div><script src=\"__ROC_EXAMPLE_LOADER__\"></script>"
	urls = { wasm: "assets/hash/app.wasm?roc-build=hash", loader: "../../assets/runtime/site.mjs" }
	SitePictures.project(page, urls) == Ok("<div data-signals-wasm=\"assets/hash/app.wasm?roc-build=hash\"></div><script src=\"../../assets/runtime/site.mjs\"></script>")
		and SitePictures.project(page.concat(page), urls) == Err(MissingHostAssets)
}
