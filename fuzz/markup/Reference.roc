import parser.Markup
import parser.MarkupTemplate
import parser.Html as ParsedHtml
import parser.Svg as ParsedSvg

## A direct model of an already-parsed UI tree and its indexed bindings. This
## module imports no engine or literal-lowering code and performs no source parse.
Reference := [].{
	Name : { namespace : Str, local : Str, prefix : Str }
	Attribute : { name : Name, value : Str }
	Node := [Element({ name : Name, attributes : List(Attribute), children : List(Node), content : List(Node) }), Text(Str), Comment(Str)].{

		## Compare every namespace/name/value/child and comment in model order.
		is_eq : _
	}

	## Substitute values by the parser's original slot index, including every
	## projected clone target. Only the declared indentation policy drops text.
	render : MarkupTemplate.Plan, List(Str) -> List(Node)
	render = |plan, values| plan.parsed.tree.roots.map(|root| draw(plan, root, values)).join()

	## Comment data never contributes to the DOM's textContent reading.
	text : List(Node) -> Str
	text = |nodes| Str.join_with(
		nodes.map(
			|node| match node {
				Text(value) => value
				Comment(_) => ""
				Element(element) => Reference.text(element.children)
			},
		),
		"",
	)
}

name_of : Markup.Name -> Reference.Name
name_of = |name| {
	namespace: match name.namespace {
		NoNamespace => ""
		Uri(uri) => uri
	},
	local: name.local,
	prefix: match name.prefix {
		Unprefixed => ""
		Prefix(value) => value
	},
}

draw : MarkupTemplate.Plan, U64, List(Str) -> List(Reference.Node)
draw = |plan, index, values| {
	node = plan.parsed.tree.nodes.get(index) ?? crash "reference: parser child index is missing"
	match node.kind {
		Element(name) => {
			var $attributes = []
			var $position = 0.U64
			for attribute in node.attributes {
				value = match plan.slots.find_first(|slot| slot.target == AttributeSlot({ node: index, attribute: $position })) {
					Ok(slot) => values.get(slot.index) ?? crash "reference: attribute part is missing"
					Err(_) => if name.namespace == Uri(Markup.html_namespace) and attribute.name.namespace == NoNamespace and ParsedHtml.boolean_attributes.contains(attribute.name.local) {
						""
					} else attribute.value
				}
				$attributes = $attributes.append({ name: name_of(attribute.name), value })
				$position = $position + 1
			}
			descendants = node.children.map(|child| draw(plan, child, values)).join()
			is_template = name.namespace == Uri(Markup.html_namespace) and name.local == "template"
			[Element({ name: name_of(name), attributes: $attributes, children: if (is_template) [] else descendants, content: if (is_template) descendants else [] })]
		}
		Text(value) => match plan.slots.find_first(|slot| slot.target == TextSlot({ node: index })) {
			Ok(slot) => [Text(values.get(slot.index) ?? crash "reference: text part is missing")]
			Err(_) => if (omitted_indentation(value)) [] else [Text(value)]
		}
		Comment(value) => [Comment(value)]
		_ => crash "reference: generated UI fragment contains a declaration"
	}
}

omitted_indentation : Str -> Bool
omitted_indentation = |value| {
	bytes = value.to_utf8()
	!bytes.any(|byte| !" \t\r\n\u(000C)".to_utf8().contains(byte)) and (bytes.contains(10) or bytes.contains(13))
}

## Indexed substitution keeps arbitrary data out of source syntax. Comment data
## and inline space survive, while the root's newline indentation is omitted.
expect {
	plan = ParsedHtml.parse_segments(["\n<div><span>", "</span><!--roc:node=9--> <b>fixed</b></div>\n"], { authored_structure: Exact })?
	actual = Reference.render(plan, ["<>&\u(FEFF)"])
	actual == [
		Element({
			name: { namespace: Markup.html_namespace, local: "div", prefix: "" },
			attributes: [],
			children: [Element({ name: { namespace: Markup.html_namespace, local: "span", prefix: "" }, attributes: [], children: [Text("<>&\u(FEFF)")], content: [] }), Comment("roc:node=9"), Text(" "), Element({ name: { namespace: Markup.html_namespace, local: "b", prefix: "" }, attributes: [], children: [Text("fixed")], content: [] })],
			content: [],
		}),
	] and Reference.text(actual) == "<>&\u(FEFF) fixed"
}

## The same source binding fans out to the option and its selectedcontent clone.
expect {
	plan = ParsedHtml.parse_segments(["<select><button><selectedcontent></selectedcontent></button><option selected>", "</option></select>"], { authored_structure: Exact })?
	Reference.text(Reference.render(plan, ["chosen"])) == "chosenchosen" and plan.slots.len() == 2
}

## One-line spaces, NBSP and mixed pre content remain literal text.
expect {
	!omitted_indentation(" ") and !omitted_indentation("\u(00A0)\n") and !omitted_indentation("x\n ") and omitted_indentation("\n \t")
}

## Parsed HTML template descendants belong to its inert content fragment.
## They do not appear in childNodes, textContent or ordinary page locators.
expect {
	plan = ParsedHtml.parse_segments(["<template><span>", "</span><!--roc:node=9--></template>"], { authored_structure: Exact })?
	actual = Reference.render(plan, ["inert data"])
	actual == [
		Element({
			name: { namespace: Markup.html_namespace, local: "template", prefix: "" },
			attributes: [],
			children: [],
			content: [Element({ name: { namespace: Markup.html_namespace, local: "span", prefix: "" }, attributes: [], children: [Text("inert data")], content: [] }), Comment("roc:node=9")],
		}),
	] and Reference.text(actual) == ""
}

## XML-parsed XHTML templates also place descendants in inert content. The
## direct raw constructor remains a separate ordinary-child operation.
expect {
	plan = ParsedSvg.parse_segments(["<svg xmlns='http://www.w3.org/2000/svg'><foreignObject><h:template xmlns:h='http://www.w3.org/1999/xhtml'><h:span>", "</h:span><!--xml comment--></h:template></foreignObject></svg>"], { authored_structure: Exact })?
	actual = Reference.render(plan, ["xml child"])
	Reference.text(actual) == "" and match actual {
		[Element(svg)] => match svg.children {
			[Element(foreign)] => match foreign.children {
				[Element(template)] => template.children.is_empty() and template.content.len() == 2
				_ => False
			}
			_ => False
		}
		_ => False
	}
}
