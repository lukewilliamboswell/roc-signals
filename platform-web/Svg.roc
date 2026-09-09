import Elem exposing [Elem]
import Html
import Node
import Signal exposing [Signal]

## SVG constructors share ordinary attributes, events, signals, and scopes.
## Every element selects SVG explicitly, including children of dynamic branches.
Svg := [].{

	## Construct any SVG element using its case-sensitive local name.
	element : Str, List(Node.Attr), List(Elem) -> Elem
	element = |tag, attrs, children| Elem.Element({ namespace: Svg, tag, attrs, children })

	## Create an SVG viewport. Supply `viewBox`, width, and height as attributes.
	svg : List(Node.Attr), List(Elem) -> Elem
	svg = |attrs, children| element("svg", attrs, children)

	## Group related shapes, labels, or transforms without adding a viewport.
	group : List(Node.Attr), List(Elem) -> Elem
	group = |attrs, children| element("g", attrs, children)

	## Render a path described by its `d` attribute.
	path : List(Node.Attr) -> Elem
	path = |attrs| element("path", attrs, [])

	## Render a rectangle from its position, size, and optional corner radii.
	rect : List(Node.Attr) -> Elem
	rect = |attrs| element("rect", attrs, [])

	## Render a line between `x1,y1` and `x2,y2`.
	line : List(Node.Attr) -> Elem
	line = |attrs| element("line", attrs, [])

	## Render connected straight segments from the `points` attribute.
	polyline : List(Node.Attr) -> Elem
	polyline = |attrs| element("polyline", attrs, [])

	## Render a label as a text node inside a genuine SVG text element.
	text : List(Node.Attr), Str -> Elem
	text = |attrs, label| element("text", attrs, [Elem.Text(label)])

	## Update a label through the shared equality-pruned signal graph.
	text_s : List(Node.Attr), Signal(Str) -> Elem
	text_s = |attrs, label| element("text", attrs, [Html.text_s(label)])
}
