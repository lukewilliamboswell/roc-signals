import pf.Engine exposing [Elem, Root]
import pf.Html
import pf.Web

## Ordinary constructors retain expanded identities across propagation and
## disposal. No literal parser or browser object supplies this app's names.
NamespacesApp := [].{

	## Every authored fixed name passes the same public checked boundary as a
	## computed name. A failure here identifies an invalid test construction.
	tag : Str, Web.Namespace, Web.Prefix -> Web.Tag
	tag = |local, namespace, prefix| {
		name = Web.Tag.from_str(local) ?? crash "invalid namespace fixture element local"
		name.in_namespace(namespace, prefix) ?? crash "invalid namespace fixture element"
	}

	## Attribute text never guesses a namespace: the explicit qualifier carries
	## the URI and prefix independently of its local spelling.
	attribute : Str, Web.Namespace, Web.Prefix -> Web.AttrName
	attribute = |local, namespace, prefix| {
		name = Web.AttrName.from_str(local) ?? crash "invalid namespace fixture attribute local"
		name.in_namespace(namespace, prefix) ?? crash "invalid namespace fixture attribute"
	}

	view : {} -> Elem(Root)
	view = |_| Engine.state(
		{ changed: False, drawn: True },
		|st| {
			changed = st.signal().map(|state| state.changed)
			Engine.element(
				Web.Tag.from_str("DIV") ?? crash "invalid raw fixture name",
				[Engine.test_id("context-root")],
				[
					Engine.element(
						NamespacesApp.tag("section", Html, Unprefixed),
						[],
						[
							Html.button("Change namespaced attribute", [], st.update(|state| { ..state, changed: !state.changed })),
							Html.button("Toggle namespace subtree", [], st.update(|state| { ..state, drawn: !state.drawn })),
							Engine.element(NamespacesApp.tag("DIV", Html, Unprefixed), [Engine.test_id("exact-html")], [Engine.text("exact HTML")]),
							Engine.element(NamespacesApp.tag("h:div", Html, Unprefixed), [Engine.test_id("colon-local")], [Engine.text("local colon")]),
							Engine.element(NamespacesApp.tag("div", Html, Prefix("h")), [Engine.test_id("prefixed-html")], [Engine.text("prefixed HTML")]),
							Engine.element(NamespacesApp.tag("entry", Uri("urn:entry"), Prefix("e")), [Engine.test_id("extension")], [Engine.text("extension")]),
							Engine.element(NamespacesApp.tag("entry", None, Unprefixed), [Engine.test_id("no-namespace")], [Engine.text("no namespace")]),
							Engine.element(NamespacesApp.tag("math", MathML, Unprefixed), [Engine.test_id("math")], [Engine.element(NamespacesApp.tag("mi", MathML, Unprefixed), [Engine.test_id("math-symbol")], [Engine.text("x")])]),
							Engine.element(
								NamespacesApp.tag("svg", Svg, Unprefixed),
								[Engine.test_id("svg")],
								[
									Engine.when(
										st.signal().map(|state| state.drawn),
										|| Engine.element(
											NamespacesApp.tag("g", Svg, Unprefixed),
											[Engine.test_id("svg-group"), Engine.attr_s(NamespacesApp.attribute("href", Uri("http://www.w3.org/1999/xlink"), Prefix("xlink")), changed.map(|value| if (value) "#after" else "#before")), Engine.attr("xlink:href", "raw")],
											[Engine.element("linearGradient", [Engine.test_id("gradient")], []), Engine.element("foreignObject", [], [Engine.element("DIV", [Engine.test_id("foreign-html")], [Engine.text("foreign HTML")])])],
										),
										|| Engine.text(""),
									),
								],
							),
						],
					),
				],
			)
		},
	)

	## The actual wrapper context is engine-only input; this app requests none.
	program : Engine.Program({})
	program = Engine.program(|| NamespacesApp.view({}))
}
