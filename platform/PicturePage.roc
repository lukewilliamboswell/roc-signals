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
	Template :: { source : Markup.Source, span : Markup.Span, root_name : Dom.ExpandedName, attributes : List((Dom.ExpandedName, Str)), parent : [Document, Element(Dom.ExpandedName)], owner : [RootOwner, ParentOwner([AuthoredInert, AddInert(U64)])] }.{

		## Root facts are engine-only mount input, independent of app Boot.
		root : Template -> Scm.MountRoot
		root = |template| template.root_name

		## The actual enclosing element supplies fragment parsing context. No
		## omitted ancestor is guessed from a tag or deployment URL.
		parent : Template -> [Document, Element(Dom.ExpandedName)]
		parent = |template| template.parent

		## Overlay only the actual mount root. An explicit external owner keeps
		## its own attributes in the host source; it never becomes the app root.
		overlay : Template, Dom.Model -> Dom.Model
		overlay = |template, model| {
			name = template.root_name
			attrs = template.attributes.keep_if(|(attribute, _)| !(attribute.namespace.is_empty() and attribute.prefix.is_empty() and attribute.local == "data-roc-picture"))
			authored_inert = attrs.any(|(attribute, _)| attribute.namespace.is_empty() and attribute.prefix.is_empty() and attribute.local == "inert")
			added = if (template.owner == RootOwner and !authored_inert) [({ namespace: "", prefix: "", local: "inert" }, ""), ({ namespace: "", prefix: "", local: "data-roc-picture-inert" }, "added")] else []
			Dom.modify(model, model.root, |node| { ..node, namespace: name.namespace, prefix: name.prefix, tag: name.local, svg: name.namespace == Dom.svg_namespace, attrs: attrs.concat(added).append(({ namespace: "", prefix: "", local: "data-roc-picture" }, "")) })
		}

		## Apply the checked root replacement and, when needed, one insertion
		## at its declared parent's opening-token boundary. All other authored
		## bytes remain untouched. The complete size is checked before joining.
		page : Template, { markup : Str, max_bytes : U64 } -> Try(Str, [PageLimit({ maximum : U64, required : U128 })])
		page = |template, { markup: rendered_root, max_bytes }| {
			addition = match template.owner {
				ParentOwner(AddInert(_)) => " inert data-roc-picture-inert=\"added\""
				_ => ""
			}
			retained = template.source.bytes.len() - template.span.end + template.span.start
			required = retained.to_u128() + rendered_root.count_utf8_bytes().to_u128() + addition.count_utf8_bytes().to_u128()
			if required > max_bytes.to_u128() {
				return Err(PageLimit({ maximum: max_bytes, required }))
			}
			after = source_text(template.source, { start: template.span.end, end: template.source.bytes.len() })
			pieces = match template.owner {
				ParentOwner(AddInert(at)) => [source_text(template.source, { start: 0, end: at }), addition, source_text(template.source, { start: at, end: template.span.start }), rendered_root, after]
				_ => [source_text(template.source, { start: 0, end: template.span.start }), rendered_root, after]
			}
			Ok(Str.join_with(pieces, ""))
		}

	}

	## Inspect one complete authored host page, permitting unknown vocabulary
	## while refusing structural repair. Exactly one explicit opt-in is required.
	parse : Str -> Try(Template, [InvalidTemplate(Str)])
	parse = |page| {
		parsed = ParsedHtml.parse_source(page, { exact_structure: True, strict_foreign_spelling: True }, False) ? |InvalidMarkup(problem)| InvalidTemplate("${problem.line.to_str()}:${problem.column.to_str()}: ${Str.inspect(problem.problem)}")
		marked = parsed.tree.nodes.map_with_index(|node, index| { node, index }).keep_if(|candidate| candidate.node.attributes.any(|attribute| attribute.name.namespace == NoNamespace and attribute.name.prefix == Unprefixed and attribute.name.local == "data-roc-picture"))
		selected = match marked {
			[one] => one
			_ => return Err(InvalidTemplate("the template must contain exactly one authored data-roc-picture mount root"))
		}
		name = match selected.node.kind {
			Element(value) => expanded(value)
			_ => return Err(InvalidTemplate("the picture mount root must be an element"))
		}
		span = authored_span(selected.node, "the picture mount root")?
		opening = opening_token(parsed.source, span)?
		if opening.end != span.end {
			_ = parsed.source.tokens.find_first(|token| token.kind == Tag and token.span.end == span.end and token.span.start >= opening.end) ? |_| InvalidTemplate("the mount root has no authored closing-tag token")
		}
		parent = parent_of(parsed.tree, selected.index)
		context = match parent {
			Document => Document
			Parent(index) => match (parsed.tree.nodes.get(index) ?? crash "PicturePage.parse: parent index").kind {
				Element(value) => Element(expanded(value))
				_ => crash "PicturePage.parse: a parent with children must be an element"
			}
		}
		owner = inert_owner(parsed, { root: selected.index, parent, root_span: span })?
		Ok(Template.{ source: parsed.source, span, root_name: name, attributes: selected.node.attributes.map(|attribute| (expanded(attribute.name), attribute.value)), parent: context, owner })
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
	template = PicturePage.parse("<!doctype html><html><head><title>host</title></head><body><div data-roc-picture><i></i></div><script>const close = '</div>';</script></body></html>")?
	template.page({ markup: "replacement", max_bytes: 16777216 })? == "<!doctype html><html><head><title>host</title></head><body>replacement<script>const close = '</div>';</script></body></html>"
}

## A self-closed foreign root retains its exact identity and source range.
## Only the explicitly marked HTML parent's opening token receives inertness.
expect {
	template = PicturePage.parse("<!doctype html><html><head></head><body><div title='>' data-roc-picture-inert-parent><!--before--><svg data-roc-picture/><!--after--></div></body></html>")?
	{ root: template.root(), page: template.page({ markup: "replacement", max_bytes: 16777216 })? } == {
		root: { namespace: Dom.svg_namespace, prefix: "", local: "svg" },
		page: "<!doctype html><html><head></head><body><div title='>' data-roc-picture-inert-parent inert data-roc-picture-inert=\"added\"><!--before-->replacement<!--after--></div></body></html>",
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

## The producer marks only the inertness it adds. Authored inert text stays
## exact, and descendants with the same attribute spelling remain ordinary data.
expect {
	make = |attrs| PicturePage.parse("<!doctype html><html><head></head><body><div data-roc-picture${attrs}><i data-roc-picture-inert=\"child data\"></i></div></body></html>")
	fresh_template = make("")?
	authored_template = make(" inert=\"false\"")?
	fresh = fresh_template.overlay(Dom.new({}))
	authored = authored_template.overlay(Dom.new({}))
	Dom.attr_of(Dom.node(fresh, fresh.root), "data-roc-picture-inert") == "added" and Dom.attr_of(Dom.node(fresh, fresh.root), "inert") == "" and Dom.has_attr(Dom.node(fresh, fresh.root), "inert") and Dom.attr_of(Dom.node(authored, authored.root), "inert") == "false" and !Dom.has_attr(Dom.node(authored, authored.root), "data-roc-picture-inert")
}

## A selected host root cannot forge the builder's restoration ownership fact.
expect PicturePage.parse("<!doctype html><html><head></head><body><div data-roc-picture data-roc-picture-inert=\"added\"></div></body></html>").is_err()

## Source slices use public parser ranges. No tag, quote or attribute scanner
## is introduced by the producer's two-edit publication plan.
source_text : Markup.Source, Markup.Span -> Str
source_text = |source, span| Str.from_utf8(source.slice(span)) ?? crash "PicturePage: parser source boundary is not UTF-8"

authored_span : Markup.Node, Str -> Try(Markup.Span, [InvalidTemplate(Str)])
authored_span = |node, label| match node.origin {
	Authored(span) => Ok(span)
	_ => Err(InvalidTemplate("${label} must have one authored source range"))
}

opening_token : Markup.Source, Markup.Span -> Try(Markup.Span, [InvalidTemplate(Str)])
opening_token = |source, span| source.tokens.find_first(|token| token.kind == Tag and token.span.start == span.start).map_ok(|token| token.span).map_err(|_| InvalidTemplate("the selected element has no authored opening-tag token"))

parent_of : Markup.Tree, U64 -> [Document, Parent(U64)]
parent_of = |tree, child| {
	var $at = 0.U64
	for node in tree.nodes {
		if node.children.contains(child) {
			return Parent($at)
		}
		$at = $at + 1
	}
	Document
}

## Bootstrap attributes are exact no-namespace identities. A QName in another
## namespace, or a raw local name containing a colon, cannot supply the fact.
plain_attribute : Markup.Node, Str -> Try(Str, [Absent])
plain_attribute = |node, local| node.attributes.find_first(|attribute| attribute.name.namespace == NoNamespace and attribute.name.prefix == Unprefixed and attribute.name.local == local).map_ok(|attribute| attribute.value).map_err(|_| Absent)

json_descriptor : Markup.Node -> Bool
json_descriptor = |node| match node.kind {
	Element(name) => name.namespace == Uri(Markup.html_namespace) and name.local == "script" and plain_attribute(node, "type") == Ok("application/json") and plain_attribute(node, "data-roc-picture-envelope") == Ok("1")
	_ => False
}

## HTML roots own their inertness. A foreign root must explicitly name its
## immediate ordinary HTML parent; this validates one finite edge, never finds
## an ancestor or wraps the app. Element siblings match the browser contract.
inert_owner : Markup.Parsed, { root : U64, parent : [Document, Parent(U64)], root_span : Markup.Span } -> Try([RootOwner, ParentOwner([AuthoredInert, AddInert(U64)])], [InvalidTemplate(Str)])
inert_owner = |parsed, { root, parent, root_span }| {
	root_node = parsed.tree.nodes.get(root) ?? crash "PicturePage: root index"
	root_name = match root_node.kind {
		Element(name) => name
		_ => crash "PicturePage: selected root kind"
	}
	if root_name.namespace == Uri(Markup.html_namespace) {
		if plain_attribute(root_node, "data-roc-picture-inert").is_ok() {
			return Err(InvalidTemplate("data-roc-picture-inert is reserved on the inert owner for the builder's restoration fact"))
		}
		return Ok(RootOwner)
	}
	index = match parent {
		Parent(parent_index) => parent_index
		Document => return Err(InvalidTemplate("a non-HTML picture root requires its explicitly marked immediate HTML parent"))
	}
	owner = parsed.tree.nodes.get(index) ?? crash "PicturePage: owner index"
	valid_parent = match owner.kind {
		Element(name) => name.namespace == Uri(Markup.html_namespace) and name.local != "template"
		_ => False
	}
	if !valid_parent or plain_attribute(owner, "data-roc-picture-inert-parent") != Ok("") {
		return Err(InvalidTemplate("a non-HTML picture root requires its explicitly marked immediate ordinary HTML parent"))
	}
	children = owner.children.keep_if(
		|child| match (parsed.tree.nodes.get(child) ?? crash "PicturePage: sibling index").kind {
			Element(_) => True
			_ => False
		},
	)
	valid_children = match children {
		[one] => one == root
		[one, descriptor] => one == root and json_descriptor(parsed.tree.nodes.get(descriptor) ?? crash "PicturePage: descriptor index")
		_ => False
	}
	if !valid_children {
		return Err(InvalidTemplate("the inert parent must contain only its root and optional associated HTML JSON descriptor as element children"))
	}
	if plain_attribute(owner, "data-roc-picture-inert").is_ok() {
		return Err(InvalidTemplate("data-roc-picture-inert is reserved on the inert owner for the builder's restoration fact"))
	}
	owner_span = authored_span(owner, "the explicit inert parent")?
	opening = opening_token(parsed.source, owner_span)?
	if opening.end <= opening.start or opening.end > root_span.start or parsed.source.bytes.get(opening.end - 1) != Ok('>') {
		return Err(InvalidTemplate("the explicit inert parent requires an ordinary authored opening-tag boundary before its root"))
	}
	if plain_attribute(owner, "inert").is_ok() {
		Ok(ParentOwner(AuthoredInert))
	} else {
		Ok(ParentOwner(AddInert(opening.end - 1)))
	}
}

## An authored owner's inert value remains exact. Foreign-root attributes are
## not mistaken for owner facts, and an exact JSON descriptor may follow it.
expect {
	source = "<!doctype html><html><head></head><body><div data-roc-picture-inert-parent inert='false'> text<!--a--><math data-roc-picture inert='root data' data-roc-picture-inert='root data'></math><!--b--><script type='application/json' data-roc-picture-envelope='1'>[]</script></div></body></html>"
	template = PicturePage.parse(source)?
	model = template.overlay(Dom.new({}))
	node = Dom.node(model, model.root)
	template.root().namespace == "http://www.w3.org/1998/Math/MathML" and Dom.attr_of(node, "inert") == "root data" and Dom.attr_of(node, "data-roc-picture-inert") == "root data" and template.page({ markup: "replacement", max_bytes: 16777216 })? == "<!doctype html><html><head></head><body><div data-roc-picture-inert-parent inert='false'> text<!--a-->replacement<!--b--><script type='application/json' data-roc-picture-envelope='1'>[]</script></div></body></html>"
}

## The ownership edge is immediate, ordinary, exact and explicit. A different
## descriptor spelling never widens the owner's allowed element children.
expect {
	pages = [
		"<div><svg data-roc-picture></svg></div>",
		"<div data-roc-picture-inert-parent='false'><svg data-roc-picture></svg></div>",
		"<div data-roc-picture-inert-parent><section><svg data-roc-picture></svg></section></div>",
		"<svg><g data-roc-picture-inert-parent><svg data-roc-picture></svg></g></svg>",
		"<div data-roc-picture-inert-parent><i></i><svg data-roc-picture></svg></div>",
		"<div data-roc-picture-inert-parent><svg data-roc-picture></svg><i></i></div>",
		"<div data-roc-picture-inert-parent><svg data-roc-picture></svg><script type='application/ld+json' data-roc-picture-envelope='1'>[]</script></div>",
		"<div data-roc-picture-inert-parent><svg data-roc-picture></svg><script type='application/json' data-roc-picture-envelope='2'>[]</script></div>",
		"<div data-roc-picture-inert-parent><svg data-roc-picture></svg><span type='application/json' data-roc-picture-envelope='1'></span></div>",
		"<div data-roc-picture-inert-parent><script type='application/json' data-roc-picture-envelope='1'>[]</script><svg data-roc-picture></svg></div>",
		"<div data-roc-picture-inert-parent><svg data-roc-picture></svg><script type='application/json' data-roc-picture-envelope='1'>[]</script><i></i></div>",
		"<template data-roc-picture-inert-parent><svg data-roc-picture></svg></template>",
		"<div data-roc-picture-inert-parent data-roc-picture-inert='added'><svg data-roc-picture></svg></div>",
	]
	pages.all(|body| PicturePage.parse("<!doctype html><html><head></head><body>${body}</body></html>").is_err())
}

## HTML roots own themselves even when an unrelated parent has the marker.
## No parent attributes or siblings are rewritten in that case.
expect {
	source = "<!doctype html><html><head></head><body><section data-roc-picture-inert-parent data-roc-picture-inert='parent data'><div data-roc-picture></div><p>outside</p></section></body></html>"
	template = PicturePage.parse(source)?
	model = template.overlay(Dom.new({}))
	Dom.attr_of(Dom.node(model, model.root), "data-roc-picture-inert") == "added" and template.page({ markup: "replacement", max_bytes: 16777216 })? == "<!doctype html><html><head></head><body><section data-roc-picture-inert-parent data-roc-picture-inert='parent data'>replacement<p>outside</p></section></body></html>"
}

## The parent insertion contributes to the aggregate page bound before any
## joined output is allocated, including when its opening tag contains a quoted greater-than sign.
expect {
	template = PicturePage.parse("<!doctype html><html><head></head><body><div title='>' data-roc-picture-inert-parent><svg data-roc-picture></svg></div></body></html>")?
	page = template.page({ markup: "replacement", max_bytes: 16777216 })?
	fits = template.page({ markup: "replacement", max_bytes: page.count_utf8_bytes() })
	small = template.page({ markup: "replacement", max_bytes: page.count_utf8_bytes() - 1 })
	fits == Ok(page) and match small {
		Err(PageLimit({ maximum, required })) => required == page.count_utf8_bytes().to_u128() and maximum.to_u128() + 1 == required
		_ => False
	}
}
