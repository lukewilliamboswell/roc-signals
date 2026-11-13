import Dom
import Scm
import Url
import parser.Html as ParsedHtml
import parser.Markup

## Native picture preparation uses the public parser's authored boundaries.
## It never finds tags with a second scanner or recovers a repaired host tree.
PicturePage := [].{

	## A checked host-page root and the exact source span it owns. Only parse
	## creates this value; page replacement cannot select another source range.
	Template :: { source : Markup.Source, span : Markup.Span, root_name : Dom.ExpandedName, attributes : List((Dom.ExpandedName, Str)), parent : [Document, Element(Dom.ExpandedName)] }.{

		## Root facts are engine-only mount input, independent of app Boot.
		root : Template -> Scm.MountRoot
		root = |template| template.root_name

		## The actual enclosing element supplies fragment parsing context. No
		## omitted ancestor is guessed from a tag or deployment URL.
		parent : Template -> [Document, Element(Dom.ExpandedName)]
		parent = |template| template.parent

		## Overlay the host root's ordered attributes on the cold oracle model.
		## inert and the explicit picture marker stay outside owned app children.
		overlay : Template, Dom.Model -> Dom.Model
		overlay = |template, model| {
			name = template.root_name
			attrs = template.attributes.keep_if(|(attribute, _)| !(attribute.namespace.is_empty() and attribute.prefix.is_empty() and (attribute.local == "inert" or attribute.local == "data-roc-picture")))
			Dom.modify(model, model.root, |node| { ..node, namespace: name.namespace, prefix: name.prefix, tag: name.local, svg: name.namespace == Dom.svg_namespace, attrs: attrs.concat([({ namespace: "", prefix: "", local: "inert" }, ""), ({ namespace: "", prefix: "", local: "data-roc-picture" }, "")]) })
		}

		## Substitute only the parser-identified root range. The supplied markup
		## must come from Dom.render's configured whole-root walk, not a serializer
		## assembled here. All other host-page bytes remain exactly authored.
		page : Template, { markup : Str, max_bytes : U64 } -> Try(Str, [PageLimit({ maximum : U64, required : U64 })])
		page = |template, { markup: rendered_root, max_bytes }| {
			retained = template.source.bytes.len() - template.span.end + template.span.start
			required = retained + rendered_root.count_utf8_bytes()
			if required > max_bytes {
				return Err(PageLimit({ maximum: max_bytes, required }))
			}
			before = Str.from_utf8(template.source.bytes.take_first(template.span.start)) ?? crash "PicturePage.page: parser span begins on a UTF-8 boundary"
			after = Str.from_utf8(template.source.bytes.drop_first(template.span.end)) ?? crash "PicturePage.page: parser span ends on a UTF-8 boundary"
			Ok("${before}${rendered_root}${after}")
		}
	}

	## Inspect one complete authored host page, permitting unknown vocabulary
	## while refusing structural repair. Exactly one explicit opt-in is required.
	parse : Str -> Try(Template, [InvalidTemplate(Str)])
	parse = |page| {
		parsed = ParsedHtml.parse_source(page, { authored_structure: Exact }, False) ? |InvalidMarkup(problem)| InvalidTemplate("${problem.line.to_str()}:${problem.column.to_str()}: ${Str.inspect(problem.problem)}")
		marked = parsed.tree.nodes.map_with_index(|node, index| { node, index }).keep_if(|candidate| candidate.node.attributes.any(|attribute| attribute.name.namespace == NoNamespace and attribute.name.prefix == Unprefixed and attribute.name.local == "data-roc-picture"))
		selected = match marked {
			[one] => one
			_ => return Err(InvalidTemplate("the template must contain exactly one authored data-roc-picture mount root"))
		}
		name = match selected.node.kind {
			Element(value) => expanded(value)
			_ => return Err(InvalidTemplate("the picture mount root must be an element"))
		}
		span = match selected.node.origin {
			Authored(value) => value
			_ => return Err(InvalidTemplate("the picture mount root must have one authored source range"))
		}
		opening = parsed.source.tokens.find_first(|token| token.kind == Tag and token.span.start == span.start) ? |_| InvalidTemplate("the mount root has no authored opening-tag token")
		if opening.span.end != span.end {
			_ = parsed.source.tokens.find_first(|token| token.kind == Tag and token.span.end == span.end and token.span.start >= opening.span.end) ? |_| InvalidTemplate("the mount root has no authored closing-tag token")
		}
		parent = parsed.tree.nodes.find_first(|node| node.children.contains(selected.index)).map_ok(|node| node.kind)
		context = match parent {
			Ok(Element(value)) => Element(expanded(value))
			_ => Document
		}
		Ok(Template.{ source: parsed.source, span, root_name: name, attributes: selected.node.attributes.map(|attribute| (expanded(attribute.name), attribute.value)), parent: context })
	}

	## Project only the explicit URL's decoded path to a static directory.
	## Query/hash remain boot input; variants collide at the publication layer.
	route : Str -> Try(Str, [InvalidRoute(Str)])
	route = |input| PicturePage.resolve(input).map_ok(|resolved| resolved.path)

	## Match browser Boot location facts without inventing an origin: the public
	## URL parser canonicalizes the path, query and fragment before init.
	resolve : Str -> Try({ path : Str, boot_url : Str }, [InvalidRoute(Str)])
	resolve = |input| {
		url = Url.parse(input) ? |problem| InvalidRoute("${input}: ${Str.inspect(problem)}")
		segments = url.path_segments()
		parts = if (segments.last() == Ok("")) segments.drop_last(1) else segments
		for part in parts {
			if part.is_empty() or part == "." or part == ".." or part.ends_with(".") or part.ends_with(" ") or part.to_utf8().any(|byte| byte < 32 or byte == 127 or ['/', '\\', ':', '<', '>', '"', '|', '?', '*'].contains(byte)) {
				return Err(InvalidRoute("${input}: path cannot name a static output directory"))
			}
			# Win32 reserves these device names in every directory, also before
			# extensions: https://learn.microsoft.com/en-us/windows/win32/fileio/naming-a-file
			stem = part.split_on(".").first() ?? crash "PicturePage.route: nonempty path component"
			folded = Str.from_utf8(stem.to_utf8().map(|byte| if (byte >= 'A' and byte <= 'Z') byte + 32 else byte)) ?? crash "PicturePage.route: ASCII folding preserves UTF-8"
			if ["con", "prn", "aux", "nul", "com1", "com2", "com3", "com4", "com5", "com6", "com7", "com8", "com9", "lpt1", "lpt2", "lpt3", "lpt4", "lpt5", "lpt6", "lpt7", "lpt8", "lpt9", "com¹", "com²", "com³", "lpt¹", "lpt²", "lpt³"].contains(folded) {
				return Err(InvalidRoute("${input}: path names a reserved filesystem device"))
			}
		}
		fragment = match url.fragment() {
			None => ""
			Some(value) => "#${value}"
		}
		Ok({ path: Str.join_with(parts.append("index.html"), "/"), boot_url: "${url.request_target()}${fragment}" })
	}
}

## Expanded names preserve URI/prefix/local data without guessing from text.
expanded : Markup.Name -> Dom.ExpandedName
expanded = |name| {
	namespace = match name.namespace {
		NoNamespace => ""
		Uri(value) => value
	}
	prefix = match name.prefix {
		Unprefixed => ""
		Prefix(value) => value
	}
	{ namespace, prefix, local: name.local }
}

## Distinct query/hash inputs share a route file and must collide upstream.
expect PicturePage.route("https://example.test/tasks/?filter=open#list") == Ok("tasks/index.html")

## The root-relative URL has no fabricated origin and writes the root page.
expect PicturePage.route("/?filter=open#list") == Ok("index.html")

## Encoded separators cannot escape their decoded path component.
expect PicturePage.route("/safe%2Foutside").is_err()

## Interior empty path components cannot be silently collapsed by a filesystem.
expect PicturePage.route("/a//b").is_err()

## Source tokens and the authored full span protect tag-like script text and
## every host byte outside the selected root's replacement range.
expect {
	template = PicturePage.parse("<!doctype html><html><head><title>host</title></head><body><svg data-roc-picture><g/></svg><script>const close = '</svg>';</script></body></html>")?
	template.page({ markup: "replacement", max_bytes: 16777216 })? == "<!doctype html><html><head><title>host</title></head><body>replacement<script>const close = '</svg>';</script></body></html>"
}

## A self-closed foreign root has one authored token range; the renderer can
## replace that whole range without inventing an HTML closing-tag scanner.
expect {
	template = PicturePage.parse("<!doctype html><html><head></head><body><svg data-roc-picture/></body></html>")?
	{ root: template.root(), page: template.page({ markup: "replacement", max_bytes: 16777216 })? } == {
		root: { namespace: Dom.svg_namespace, prefix: "", local: "svg" },
		page: "<!doctype html><html><head></head><body>replacement</body></html>",
	}
}

## No opt-in and multiple explicit opt-ins are refused before app init.
expect {
	[
		"<!doctype html><html><head></head><body><div></div></body></html>",
		"<!doctype html><html><head></head><body><div data-roc-picture></div><div data-roc-picture></div></body></html>",
	].all(|page| PicturePage.parse(page).is_err())
}

## A repaired authored tree is never a template selection compatibility path.
expect PicturePage.parse("<!doctype html><html><head></head><body><p data-roc-picture><div></div></p></body></html>").is_err()

## Static routes cannot name reserved Win32 devices, including superscript
## digit aliases, or acquire trailing-dot/space aliases on another filesystem.
expect ["/CON.txt", "/COM%C2%B9.log", "/entry.", "/entry%20"].all(|input| PicturePage.route(input).is_err())

## Aggregate refusal counts retained host bytes before allocating a full page.
expect {
	template = PicturePage.parse("<!doctype html><html><head></head><body><div data-roc-picture></div></body></html>")?
	match template.page({ markup: "replacement", max_bytes: 1 }) {
		Err(PageLimit({ maximum: 1, required })) => required > 1
		_ => False
	}
}

## Absolute URLs supply only browser location components to app Boot, while
## normalization and explicit query/hash data come from the public Url parser.
expect {
	resolved = PicturePage.resolve("https://example.test/a/../tasks?open=1#list")?
	resolved == { path: "tasks/index.html", boot_url: "/tasks?open=1#list" }
}
