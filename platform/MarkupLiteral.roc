import parser.MarkupFacts
import Engine
import Core
import Web
import MarkupAdvice
import Spelling
import parser.Html as ParsedHtml
import parser.Svg as ParsedSvg
import parser.Markup
import parser.Literal

## Compile checked markup to a small immutable constructor plan. Only this
## compile path sees parser source and syntax; bound holes keep ordinary signals.
MarkupLiteral := [].{
	Mode : [HtmlFragment, SvgFragment]

	Plan :: { nodes : List(Node), root : U64, parts : U64, svg_parent : Bool }

	## Validate fixed segments once, retaining neither source nor parser tokens
	## in the plan consumed by a mounted element or one of its signal readers.
	compile : List(Str), Mode -> Try(Plan, [BadLiteral(Str)])
	compile = |segments, mode| {
		if segments.is_empty() {
			return Err(BadLiteral("line 1, column 1: a markup interpolation needs at least one fixed segment"))
		}
		parsed = match mode {
			HtmlFragment => ParsedHtml.parse_segments(segments, { exact_structure: True, strict_foreign_spelling: True })
			SvgFragment => ParsedSvg.parse_segments(segments, { exact_structure: True, strict_foreign_spelling: True })
		}.map_err(|InvalidMarkup(error)| BadLiteral(parser_problem(error)))?
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
						if MarkupFacts.is_event_handler(name, attribute.name) {
							return Err(BadLiteral(at_offset(parsed.parsed, attribute.span.start, "a markup literal holds no handlers: listen with Engine.on or Html's controls")))
						}
						attr_name = attribute_name(attribute.name).map_err(|NotAnAttribute(note)| BadLiteral(at_offset(parsed.parsed, attribute.span.start, note)))?
						match Core.attribute_claim(tag, attr_name) {
							Unclaimed => {}
							Claimed(property) => return Err(BadLiteral(at_offset(parsed.parsed, attribute.span.start, "${sample(attribute.name.local)} on ${name_label(name)} is claimed by Engine.Prop.${property}; use Engine.prop or Engine.prop_s on a constructor, or Html's typed controls")))
						}
						hole = $attributes.get(($node_index, $attribute_index))
						boolean = MarkupFacts.is_boolean_attribute(name, attribute.name)
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
	bind = |Plan.(plan), parts| {
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
	position = Literal.position(Str.from_utf8_lossy(parsed.source.bytes), offset)
	"line ${position.line.to_str()}, column ${position.column.to_str()}: ${note}"
}

parser_problem : Markup.Error -> Str
parser_problem = |error| "line ${error.line.to_str()}, column ${error.column.to_str()}: ${problem_words(error.problem)}"

problem_words : Markup.Problem -> Str
problem_words = |problem| match problem {
	SyntaxError(note) => note
	HtmlSyntax(UnexpectedDoctype) => "a markup literal is an element UI fragment, not a document declaration"
	HtmlSyntax(code) => "invalid HTML syntax: ${Str.inspect(code)}"
	HtmlStructure({ reason, .. }) => MarkupAdvice.repair(reason)
	NonCanonicalName({ authored, expected, .. }) => "foreign name ${sample(authored)} would be adjusted to ${sample(expected)}; write the exact spelling"
	NamespaceError(reason) => "invalid namespace: ${Str.inspect(reason)}"
	WrongRoot({ expected, actual }) => "expected ${short_text(expected)}, found ${short_text(actual)}"
	UnknownElement(name) => "${sample(name)} is not an element in the pinned parser vocabulary${Spelling.suggest(name, MarkupFacts.element_names(Uri(Markup.html_namespace)).concat(MarkupFacts.element_names(Uri(Markup.svg_namespace))))}"
	UnknownAttribute({ element, attribute }) => {
		hint = if attribute.starts_with("aria-") {
			Spelling.suggest(attribute, MarkupFacts.aria_attribute_names)
		} else ""
		"<${short_text(element)}> has no attribute ${sample(attribute)}${hint}"
	}
	InvalidValue({ attribute, value, expected }) => {
		hint = match expected {
			Keyword(words) => Spelling.suggest(value, words)
			_ => ""
		}
		"${sample(value)} is not a value of ${short_text(attribute)}; expected ${grammar_words(expected)}${hint}"
	}
	InvalidChildren({ element, expected }) => "<${short_text(element)}> requires ${short_text(expected)}"
	Unsupported(note) => note
	LimitExceeded(limit) => "markup exceeds the parser's ${Str.inspect(limit)} limit"
	SourceTooLarge(maximum) => "markup source exceeds ${maximum.to_str()} bytes"
	ResourceLimit(resource) => "markup exceeds the parser's ${short_text(resource)} limit"
	Interpolation({ index, reason }) => "hole index ${index.to_str()}: ${reason}"
	BindingCount({ expected, actual }) => "markup has ${actual.to_str()} bound parts but requires ${expected.to_str()}"
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
	Language(note) => short_text(note)
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
