import Engine
import Core
import Web
import MarkupAdvice
import Spelling
import parser.Html as ParsedHtml
import parser.Svg as ParsedSvg
import parser.Markup

## Compile checked markup to a small immutable constructor plan. Only this
## compile path sees parser source and syntax; bound holes keep ordinary signals.
MarkupLiteral := [].{

	## Select the fragment syntax of the literal's fixed segments. HTML and SVG
	## use their own parser entrypoints before lowering to the same view plan.
	Mode : [HtmlFragment, SvgFragment]

	## A validated constructor plan owns only the lowered nodes and hole layout.
	## It retains neither parser source nor tokens when a view uses the literal.
	Plan :: { nodes : List(Node), root : U64, parts : U64, svg_parent : Bool }

	## Validate fixed segments once, retaining neither source nor parser tokens
	## in the plan consumed by a mounted element or one of its signal readers.
	compile : List(Str), Mode -> Try(Plan, [BadLiteral(Str)])
	compile = |segments, mode| {
		if segments.is_empty() {
			return Err(BadLiteral("line 1, column 1: a markup interpolation needs at least one fixed segment"))
		}
		validated = match mode {
			HtmlFragment => html_segments(segments)
			SvgFragment => ParsedSvg.parse_segments(segments, { exact_structure: True, strict_foreign_spelling: True })
		}.map_err(|InvalidMarkup(error)| BadLiteral(parser_problem(error)))?
		parsed = validated.metadata()
		var $texts = Dict.empty()
		var $attributes = Dict.empty()
		for slot in parsed.slots {
			match slot.target {
				TextSlot({ node }) => {
					$texts = $texts.insert(node, slot.index)
				}
				AttributeSlot({ node, attribute }) => {
					$attributes = $attributes.insert((node, attribute), slot.index)
				}
			}
		}
		var $nodes = []
		var $node_index = 0.U64
		for node in parsed.parsed.tree.nodes {
			converted = match node.kind {
				Element(name) => {
					tag = element_name(name).map_err(|NotATag(note)| BadLiteral(at_node(parsed.parsed, node, note)))?
					var $attrs = []
					var $attribute_index = 0.U64
					for attribute in node.attributes {
						if Markup.Name.is_event_handler(name, { attribute: attribute.name }) {
							return Err(BadLiteral(at_offset(parsed.parsed, attribute.span.start, "a markup literal holds no handlers: listen with Engine.on or Html's controls")))
						}
						attr_name = attribute_name(attribute.name).map_err(|NotAnAttribute(note)| BadLiteral(at_offset(parsed.parsed, attribute.span.start, note)))?
						if Core.attribute_reserved(attr_name) {
							return Err(BadLiteral(at_offset(parsed.parsed, attribute.span.start, "this no-namespace data-roc attribute is reserved for startup transport")))
						}
						match Core.attribute_claim(tag, attr_name) {
							Unclaimed => {}
							Claimed(property) => return Err(BadLiteral(at_offset(parsed.parsed, attribute.span.start, "${sample(attribute.name.local)} on ${name_label(name)} is claimed by Engine.Prop.${property}; use Engine.prop or Engine.prop_s on a constructor, or Html's typed controls")))
						}
						hole = $attributes.get(($node_index, $attribute_index))
						boolean = Markup.Name.is_boolean_attribute(name, { attribute: attribute.name })
						if boolean and hole.is_ok() {
							return Err(BadLiteral(at_offset(parsed.parsed, attribute.span.start, "a Boolean attribute cannot have a text hole: use Html.boolean or a typed control on a constructor")))
						}
						value = match hole {
							Ok(index) => Part(index)
							Err(_) => Fixed(if (boolean) "" else attribute.value)
						}
						$attrs = $attrs.append({ name: attr_name, value })
						$attribute_index = $attribute_index + 1
					}
					Element(
						tag,
						$attrs,
						node.children,
						if name.namespace == Uri(Markup.html_namespace) and name.local == "template" {
							Content
						} else Children,
					)
				}
				Text(text) => match $texts.get($node_index) {
					Ok(index) => TextPart(index)
					Err(_) => if (indentation(text)) Skipped else Text(text)
				}
				Comment(text) => Comment(text)
				Doctype(_) => return Err(BadLiteral(at_node(parsed.parsed, node, "a markup literal is an element UI fragment, not a document declaration")))
				ProcessingInstruction(_) => return Err(BadLiteral(at_node(parsed.parsed, node, "a markup literal is an element UI fragment and holds no processing instruction")))
			}
			$nodes = $nodes.append(converted)
			$node_index = $node_index + 1
		}
		roots = parsed.parsed.tree.roots.keep_if(|index| $nodes.get(index) != Ok(Skipped))
		root = match roots {
			[index] => index
			_ => return Err(BadLiteral("line 1, column 1: a markup literal requires exactly one element root; comments or text beside it need a constructor"))
		}
		tag = match $nodes.get(root) {
			Ok(Element(name, _, _, _)) => name
			_ => return Err(BadLiteral("line 1, column 1: a markup literal requires one element root, not root text or a comment"))
		}
		if mode == SvgFragment and tag.namespace() != Explicit(Svg) {
			return Err(BadLiteral("line 1, column 1: Svg.Markup requires an SVG element root; use Html.Markup for HTML with embedded SVG"))
		}
		Ok(Plan.({ nodes: $nodes, root, parts: segments.len() - 1, svg_parent: mode == SvgFragment and tag.local() != "svg" }))
	}

	## Capture each homogeneous part once. The compiler supplies exact arity;
	## manual calls have the same named contract boundary as signal assemblers.
	bind : Plan, Iter(Engine.Signal(ctx, Str)) -> List(Engine.Signal(ctx, Str))
	bind = |plan, parts| bind_parts(plan, parts)

	## A static placeholder retains text bindings, without a signal reader or
	## live context. Its arity follows the same checked plan as ordinary markup.
	bind_static : Plan, Iter(Str) -> List(Str)
	bind_static = |plan, parts| bind_parts(plan, parts)

	## Build ordinary engine elements. Parts retain their read signatures and
	## constant mark; no parser, source text or special reactive site is retained.
	render : Plan, List(Engine.Signal(ctx, Str)) -> Engine.Elem(ctx)
	render = |Plan.(plan), parts| {
		element = render_node(plan.nodes, plan.root, parts)
		if plan.svg_parent {
			Core.require_parent(element, [Svg])
		} else element
	}
}

## One arity boundary for every homogeneous kind of checked markup binding.
## The returned list owns each part; no iterator or live environment is kept.
bind_parts : MarkupLiteral.Plan, Iter(part) -> List(part)
bind_parts = |MarkupLiteral.Plan.(plan), parts| {
	var $bound = []
	for part in parts {
		if $bound.len() == plan.parts {
			crash "contract: markup interpolation has more parts than its fixed segments"
		}
		$bound = $bound.append(part)
	}
	if $bound.len() != plan.parts {
		crash "contract: markup interpolation has fewer parts than its fixed segments"
	}
	$bound
}

Attribute : { name : Web.AttrName, value : [Fixed(Str), Part(U64)] }

Node : [Element(Web.Tag, List(Attribute), List(U64), [Children, Content]), Text(Str), TextPart(U64), Comment(Str), Skipped]

## Expanded parser names are facts, never inferred by splitting a raw colon.
element_name : Markup.Name -> Try(Web.Tag, [NotATag(Str)])
element_name = |name| Web.Tag.from_str(name.local)?.in_namespace({ namespace: namespace(name), prefix: prefix(name) })

attribute_name : Markup.Name -> Try(Web.AttrName, [NotAnAttribute(Str)])
attribute_name = |name| Web.AttrName.from_str(name.local)?.in_namespace({ namespace: namespace(name), prefix: prefix(name) })

namespace : Markup.Name -> Web.Namespace
namespace = |name| match name.namespace {
	NoNamespace => None
	Uri(uri) if uri == Markup.html_namespace => Html
	Uri(uri) if uri == Markup.svg_namespace => Svg
	Uri(uri) if uri == Markup.mathml_namespace => MathML
	Uri(uri) => Uri(uri)
}

prefix : Markup.Name -> Web.Prefix
prefix = |name| match name.prefix {
	Unprefixed => Unprefixed
	Prefix(text) => Prefix(text)
}

render_node : List(Node), U64, List(Engine.Signal(ctx, Str)) -> Engine.Elem(ctx)
render_node = |nodes, index, parts| match nodes.get(index) ?? crash "internal: markup plan child is missing" {
	Element(tag, attributes, children, container) => {
		element = Engine.element(tag, attributes.map(|attribute| render_attribute(attribute, parts)), children.keep_if(|child| nodes.get(child) != Ok(Skipped)).map(|child| render_node(nodes, child, parts)))
		match container {
			Children => element
			Content => Core.template_content(element)
		}
	}
	Text(text) => Engine.text(text)
	TextPart(part) => Engine.text_s(parts.get(part) ?? crash "internal: markup plan text binding is missing")
	Comment(text) => Core.comment(text)
	Skipped => crash "internal: markup indentation reached rendering"
}

render_attribute : Attribute, List(Engine.Signal(ctx, Str)) -> Engine.Attr(ctx)
render_attribute = |{ name, value }, parts| match value {
	Fixed(text) => if name.namespace() == None and name.prefix() == Unprefixed and name.local() == "class" {
		Engine.class(text)
	} else if name.namespace() == None and name.prefix() == Unprefixed and name.local() == "data-testid" {
		Engine.test_id(text)
	} else Engine.attr(name, text)
	Part(index) => {
		part = parts.get(index) ?? crash "internal: markup plan attribute binding is missing"
		if name.namespace() == None and name.prefix() == Unprefixed and name.local() == "class" {
			Engine.class_s(part)
		} else if name.namespace() == None and name.prefix() == Unprefixed and name.local() == "data-testid" {
			Engine.test_id_s(part)
		} else Engine.attr_s(name, part)
	}
}

## This is an explicit literal indentation policy, not HTML recovery. NBSP,
## one-line spaces, and whitespace mixed with visible data remain exact text.
indentation : Str -> Bool
indentation = |text| text.to_utf8().any(|byte| byte == 10 or byte == 13) and text.to_utf8().all(|byte| [9.U8, 10, 12, 13, 32].contains(byte))

at_node : Markup.Parsed, Markup.Node, Str -> Str
at_node = |parsed, node, note| at_offset(
	parsed,
	match node.origin {
		Authored(span) => span.start
		Implied(offset) => offset
		Cloned({ source, .. }) => source.start
	},
	note,
)

at_offset : Markup.Parsed, U64, Str -> Str
at_offset = |parsed, offset, note| {
	position = (parsed.source).position(offset)
	"line ${position.line.to_str()}, column ${position.column.to_str()}: ${note}"
}

# HTML parses in a body context. A table part (tr, td, th, tbody, thead,
# tfoot, caption, colgroup, col) is never valid there, so a literal whose
# body parse fails is parsed again in a template's content context, where
# HTML's parser lets the root choose its insertion mode, and is accepted
# only when that parse is exact and its root is a table part. Every other
# literal keeps the body parse and its diagnostic. Where a table-part root
# may be placed is the construction check's: a <tr> in a <div> is refused.
html_segments : List(Str) -> Try(Markup.Template.Plan, [InvalidMarkup(Markup.Error)])
html_segments = |segments|
	match ParsedHtml.parse_segments(segments, { exact_structure: True, strict_foreign_spelling: True }) {
		Ok(plan) => Ok(plan)
		Err(body_error) =>
			match ParsedHtml.parse_segments(segments, { exact_structure: True, strict_foreign_spelling: True, context_element: "template" }) {
				Ok(plan) if table_part_root(plan) => Ok(plan)
				_ => Err(body_error)
			}
	}

# Whether a parse has an HTML table-part root; compile still requires
# exactly one element root.
table_part_root : Markup.Template.Plan -> Bool
table_part_root = |plan|
	(plan.metadata().parsed.tree.roots).any(
		|index|
			match plan.metadata().parsed.tree.nodes.get(index) {
				Ok(node) =>
					match node.kind {
						Element(name) => name.namespace == Uri(Markup.html_namespace) and ["tr", "td", "th", "tbody", "thead", "tfoot", "caption", "colgroup", "col"].contains(name.local)
						_ => False
					}
				Err(_) => False
			},
	)

parser_problem : Markup.Error -> Str
parser_problem = |error| "${MarkupAdvice.location(error.location)}: ${problem_words(error.problem)}"

problem_words : Markup.Problem -> Str
problem_words = |problem| match problem {
	SyntaxError(note) => "invalid XML syntax: ${Str.inspect(note)}"
	HtmlSyntax(UnexpectedDoctype) => "a markup literal is an element UI fragment, not a document declaration"
	HtmlSyntax(code) => "invalid HTML syntax: ${Str.inspect(code)}"
	HtmlStructure({ reason, .. }) => MarkupAdvice.repair(reason)
	NonCanonicalName({ authored, expected, .. }) => "foreign name ${sample(authored)} would be adjusted to ${sample(expected)}; write the exact spelling"
	NamespaceError(reason) => "invalid namespace: ${Str.inspect(reason)}"
	WrongRoot({ expected, actual }) => "expected <${short_text(expected.local)}> in ${Str.inspect(expected.namespace)}, found ${Str.inspect(actual)}"
	UnknownElement(name) => "${sample(name)} is not an element in the pinned parser vocabulary${Spelling.suggest(name, Markup.element_names(Uri(Markup.html_namespace)).concat(Markup.element_names(Uri(Markup.svg_namespace))))}"
	UnknownAttribute({ element, attribute }) => {
		hint = if attribute.starts_with("aria-") {
			Spelling.suggest(attribute, Markup.aria_attribute_names)
		} else ""
		"<${short_text(element)}> has no attribute ${sample(attribute)}${hint}"
	}
	InvalidValue({ attribute, value: excerpt, expected }) => {
		value = Str.from_utf8_lossy(excerpt.bytes)
		hint = match expected {
			Keyword(words) => Spelling.suggest(value, words)
			_ => ""
		}
		"${sample(value)} is not a value of ${short_text(attribute)}; expected ${grammar_words(expected)}${hint}"
	}
	InvalidChildren({ element, expected }) => "<${short_text(element)}> requires ${children_words(expected)}"
	Unsupported(note) => "unsupported markup: ${Str.inspect(note)}"
	LimitExceeded(limit) => "markup exceeds the parser's ${Str.inspect(limit)} limit"
	Interpolation({ index, reason }) => "hole index ${index.to_str()}: ${interpolation_words(reason)}"
	BindingCount({ expected, actual }) => "markup has ${actual.to_str()} bound parts but requires ${expected.to_str()}"
}

interpolation_words : Markup.InterpolationProblem -> Str
interpolation_words = |reason| match reason {
	RawTextHole => "holes are not allowed in raw script/style content"
	MissingStaticSegment => "an interpolation requires at least one static segment"
	TextHoleForbidden(element) => "text holes are not allowed inside <${short_text(element)}>"
	RecoveryRequired => "a template requires exact authored structure without parser repairs"
	SplitCharacterReference => "a hole cannot split a character reference"
	InvalidHolePosition => "expected character data or an entire quoted attribute value"
	MultipleAttributeHoles => "an attribute value requires one whole-value hole"
	MarkupDelimiterHole => "holes are not allowed in comments, declarations or markup delimiters"
	IncompleteHoleMarkup => "a hole cannot complete unfinished markup"
	LostAttributeHole => "the parser did not retain the attribute hole"
	CdataHoleNamespace => "a CDATA hole requires a foreign namespace"
}

children_words : Markup.ChildGrammar -> Str
children_words = |grammar| match grammar {
	AllowedParent(name) => "a <${short_text(name)}> parent"
	ImageAlternative => "an alt attribute on an image"
	ImageInputAttributes => "src and alt attributes on an image input"
	NoNestedAnchor => "content without nested links"
	NoInteractiveContent => "content without interactive descendants"
	OptionContent => "valid option content"
	SelectButtonDescendant => "a button inside a select"
	NoChildren => "no children"
	ElementsOnly => "element children"
	NamedElements(names) => Str.join_with(names.map(|name| "<${short_text(name)}>"), ", ")
	TextOnly => "text content"
	MathElements => "MathML children"
	SvgElements => "SVG children"
	ChildCount(count) => "${count.to_str()} children"
	BaseAndScriptPairs => "a base followed by script pairs"
	ScriptsAndPrescripts => "scripts and prescripts"
	ScriptPairs => "script pairs"
	ExpressionAndAnnotations => "an expression followed by annotations"
	SvgContentModel => "the SVG content model"
}

grammar_words : Markup.ValueGrammar -> Str
grammar_words = |grammar| match grammar {
	Number => "a number"
	NonnegativeNumber => "a nonnegative number"
	Length => "a length"
	NonnegativeLength => "a nonnegative length"
	NumberList(count) => "${count.to_str()} numbers"
	LengthList => "a list of lengths"
	PathData => "valid SVG path data"
	TransformList => "valid SVG transforms"
	Keyword(words) => Str.join_with(words.map(sample), ", ")
	TokenList => "a list of tokens"
	Color => "a color"
	Paint => "an SVG paint value"
	AspectRatio => "an aspect-ratio value"
	Language(note) => Str.inspect(note)
}

name_label : Markup.Name -> Str
name_label = |name| match name.prefix {
	Unprefixed => "<${short_text(name.local)}>"
	Prefix(value) => "<${short_text(value)}:${short_text(name.local)}>"
}

sample : Str -> Str
sample = |text| {
	short = short_text(text)
	if text.count_utf8_bytes() > short.count_utf8_bytes() {
		"${Str.inspect(short)}…"
	} else Str.inspect(short)
}

short_text : Str -> Str
short_text = |text| {
	var $bytes = text.to_utf8().take_first(64)
	while Bool.True {
		match Str.from_utf8($bytes) {
			Ok(value) => return value
			Err(_) => {
				$bytes = $bytes.drop_last(1)
			}
		}
	}
}

## A static literal emits exactly its ordinary constructors, including a real
## authored comment and explicit empty Boolean presence. Indentation adds no node.
expect {
	plan = MarkupLiteral.compile(["\n<div class='card' data-testid='card'><input disabled><!--roc:node=9--><p>fixed &amp; safe</p></div>\n"], HtmlFragment)?
	literal = MarkupLiteral.render(plan, [])
	ordinary = Engine.element(
		"div",
		[Engine.class("card"), Engine.test_id("card")],
		[
			Engine.element("input", [Engine.attr("disabled", "")], []),
			Core.comment("roc:node=9"),
			Engine.element("p", [], [Engine.text("fixed & safe")]),
		],
	)
	Core.take_cmds(Core.mount(literal), []).1 == Core.take_cmds(Core.mount(ordinary), []).1
}

## A constant part draws once through the same constant signal path used by
## constructors. It is never treated as markup, even when it resembles tags.
expect {
	plan = MarkupLiteral.compile(["<p class='", "'>", "</p>"], HtmlFragment)?
	literal = MarkupLiteral.render(plan, [Engine.const("hint"), Engine.const("<>&")])
	ordinary = Engine.element("p", [Engine.class_s(Engine.const("hint"))], [Engine.text_s(Engine.const("<>&"))])
	(a, literal_bytes) = Core.take_cmds(Core.mount(literal), [])
	(b, ordinary_bytes) = Core.take_cmds(Core.mount(ordinary), [])
	literal_bytes == ordinary_bytes and Core.evals(a) == 0 and Core.evals(b) == 0
}

## A parsed HTML template selects its content fragment explicitly. Raw element
## construction retains ordinary childNodes and therefore has a different wire.
expect {
	plan = MarkupLiteral.compile(["<template><span>inert</span><!--template comment--></template>"], HtmlFragment)?
	literal = MarkupLiteral.render(plan, [])
	children = || [Engine.element("span", [], [Engine.text("inert")]), Core.comment("template comment")]
	ordinary = Core.template_content(Engine.element("template", [], children()))
	raw = Engine.element("template", [], children())
	literal_bytes = Core.take_cmds(Core.mount(literal), []).1
	literal_bytes == Core.take_cmds(Core.mount(ordinary), []).1 and literal_bytes != Core.take_cmds(Core.mount(raw), []).1
}

## The shared claim query uses resolved DOM identity. Exact uppercase and
## namespaced attributes remain distinct from an HTML input's value property.
expect {
	tag = Web.Tag.from_str("input")?.in_namespace({ namespace: Html })?
	ordinary = Web.AttrName.from_str("value")?.in_namespace({ namespace: None })?
	uppercase = Web.AttrName.from_str("VALUE")?.in_namespace({ namespace: None })?
	qualified = Web.AttrName.from_str("value")?.in_namespace({ namespace: Uri("urn:fields"), prefix: Prefix("x") })?
	Core.attribute_claim(tag, ordinary) == Claimed("value") and
		Core.attribute_claim(tag, uppercase) == Unclaimed and
			Core.attribute_claim(tag, qualified) == Unclaimed
}

## A table part is a literal root of its own, as a row or cell a constructor
## places in its table; nesting inside it still keeps the repair rule.
expect {
	roots = ["<tr><td>x</td></tr>", "<td>x</td>", "<th>x</th>", "<tbody><tr><td>x</td></tr></tbody>", "<thead><tr><th>x</th></tr></thead>", "<caption>x</caption>", "<colgroup><col></colgroup>", "<col>"]
	repaired = ["<tr><div>x</div></tr>", "<td>x</td><tr><td>y</td></tr>", "<p><div>x</div></p>"]
	roots.all(|source| MarkupLiteral.compile([source], HtmlFragment).is_ok()) and repaired.all(|source| MarkupLiteral.compile([source], HtmlFragment).is_err())
}

## The parser must keep a sole text hole inside every authored parent. The
## reference is written with constructors, independently of the parsed tree:
## comparing two consumers of the parser would accept the same ancestry bug.
expect {
	plan = MarkupLiteral.compile(["<section><div><p>", "</p></div><aside>fixed</aside></section>"], HtmlFragment)?
	literal = MarkupLiteral.render(plan, [Engine.const("live")])
	ordinary = Engine.element("section", [], [Engine.element("div", [], [Engine.element("p", [], [Engine.text_s(Engine.const("live"))])]), Engine.element("aside", [], [Engine.text("fixed")])])
	Core.take_cmds(Core.mount(literal), []).1 == Core.take_cmds(Core.mount(ordinary), []).1
}

## Template content has its own container; a sole text binding remains the
## span's child inside that content, rather than a sibling of the template.
expect {
	plan = MarkupLiteral.compile(["<template><div><span>", "</span></div></template>"], HtmlFragment)?
	literal = MarkupLiteral.render(plan, [Engine.const("inert")])
	ordinary = Core.template_content(Engine.element("template", [], [Engine.element("div", [], [Engine.element("span", [], [Engine.text_s(Engine.const("inert"))])])]))
	Core.take_cmds(Core.mount(literal), []).1 == Core.take_cmds(Core.mount(ordinary), []).1
}

## Static placeholder text is retained exactly; escaping belongs to ordinary
## element lowering and rendering, not to the binding's ownership boundary.
expect {
	plan = MarkupLiteral.compile(["<p>", "</p>"], HtmlFragment)?
	MarkupLiteral.bind_static(plan, ["<>&"].iter()) == ["<>&"]
}
