# Native GUI vocabulary lowered into the shared engine descriptors.
# Layout and styling are supplied by the GPUI host; this is not a CSS API.
import Elem exposing [Elem]
import Html
import Node
import Signal exposing [Signal]

Gui := [].{
	column : List(Elem) -> Elem
	column = |children| Html.div([], children)

	heading : Str -> Elem
	heading = |label| Html.heading(label)

	text : Str -> Elem
	text = |label| Html.text(label)

	text_s : Signal(Str) -> Elem
	text_s = |label| Html.text_s(label)

	button : Str, Node.Msg -> Elem
	button = |label, message| Html.button(label, message)

	text_input : Str, Signal(Str), Node.Msg -> Elem
	text_input = |label, value, message| Html.text_input(label, value, message)

	# Fixed-height retained card used by the keyed-row spike.
	card : Str, List(Elem) -> Elem
	card = |key, children| Html.div([Html.test_id(key), Html.class_attr("gpui-row")], children)
}
