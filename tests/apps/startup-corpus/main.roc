app [main] { pf: platform "../../../platform/main.roc" }

import pf.Engine
import pf.Html
import pf.Web

Store : {}

entries = Engine.entries({}, [{ path: "/", route: "first" }, { path: "/second/", route: "second" }])

## Both declared pages use the same pure typed construction. Browser facts
## arrive only through the ordinary snapshot request after the cold barrier.
main : Engine.Program
main = Engine.program_startup({ storage_keys: ["corpus"], zone_days: 0 }, entries, view)

## The default cold frame is checked independently of later snapshot delivery.
mounted : U64
mounted = Engine.mounts(main)

## Explicit namespace aliases exercise URI identity without relying on an
## HTML parser to invent a namespace for an unknown qualified name.
tag : Str, Web.Namespace -> Web.Tag
tag = |local, element_namespace| {
	name = Web.Tag.from_str(local) ?? crash "invalid corpus element local"
	name.in_namespace({ namespace: element_namespace }) ?? crash "invalid corpus element namespace"
}

## The one qualified attribute keeps XLink's URI and prefix distinct from
## ordinary no-namespace attributes.
xlink : Web.AttrName
xlink = (Web.AttrName.from_str("href") ?? crash "invalid corpus attribute").in_namespace({ namespace: Uri("http://www.w3.org/1999/xlink"), prefix: Prefix("xlink") }) ?? crash "invalid corpus XLink name"

## The initial Self changes a text hole only after binding. A snapshot issued
## before the cold storage write observes the later acknowledgement's write.
view : Str -> Engine.Elem(Engine.Root)
view = |route| Engine.state(
	{ count: 0.I64, environment: "waiting" },
	|state| {
		inert_template : Html.Markup(_)
		inert_template = "<template data-testid='template'><span data-testid='content-span'>inert content</span><!--authored roc:node=1--></template>"
		Html.div(
			"",
			[
				Engine.element("p", [Engine.test_id("route")], [Engine.text(route)]),
				Engine.element("p", [Engine.test_id("selection")], [Engine.text("alpha"), Engine.text(""), Engine.text("beta")]),
				Engine.element("p", [Engine.test_id("counter")], [Engine.text_s(state.signal().map(|value| value.count.to_str()))]),
				Engine.element("p", [Engine.test_id("environment")], [Engine.text_s(state.signal().map(|value| value.environment))]),
				Html.button("Increment", [Engine.test_id("increment")], state.update(|value| { ..value, count: value.count + 1 })),
				Engine.watch(Engine.const({}), |_| [Engine.again({})], state.on_result(|value, _, _| { ..value, count: value.count + 1 })),
				Engine.watch(
					Engine.const({}),
					|_| [Engine.environment({})],
					state.on_result(
						|value, _, answer| match answer {
							Ok(boot) => { ..value, environment: "snapshot|${boot.url}|${Engine.boot_storage(boot, "corpus") ?? "missing"}" }
							Err(Refused) => { ..value, environment: "refused" }
						},
					),
				),
				Engine.watch(Engine.const({}), |_| [Engine.command(StorageSet("corpus", "cold"))], Engine.ignore({})),
				Engine.watch_changes(state.signal().map(|value| value.count), |_| [Engine.command(StorageSet("corpus", "ack")), Engine.command(Replace("/snapshot-ready?query#fragment"))], Engine.ignore({})),
				Engine.element("textarea", [Engine.test_id("textarea"), Engine.prop(Engine.Prop.value, "live text")], [Engine.text("authored text")]),
				Engine.element(
					"select",
					[Engine.test_id("no-match"), Engine.prop(Engine.Prop.value, "missing")],
					[
						Engine.element("option", [Engine.test_id("option-first"), Engine.prop(Engine.Prop.value, "first"), Engine.attr("selected", "")], [Engine.text("First")]),
						Engine.element("option", [Engine.test_id("option-second"), Engine.prop(Engine.Prop.value, "second")], [Engine.text("Second")]),
					],
				),
				Engine.element("input", [Engine.test_id("authored-inert"), Engine.attr("type", "checkbox"), Engine.prop(Engine.Prop.checked, True), Engine.attr("inert", "author-inert")], []),
				inert_template.to_elem(),
				Engine.element(
					tag("svg", Uri("http://www.w3.org/2000/svg")),
					[Engine.test_id("svg"), Engine.attr("viewBox", "0 0 40 40"), Engine.attr("width", "40"), Engine.attr("height", "40")],
					[
						Engine.element("a", [Engine.test_id("svg-link"), Engine.attr(xlink, "#native")], [Engine.element("text", [], [Engine.text("SVG")])]),
						Engine.element("foreignObject", [Engine.attr("width", "40"), Engine.attr("height", "40")], [Engine.element("div", [Engine.test_id("foreign-html")], [Engine.text("HTML")])]),
					],
				),
				Engine.element(tag("math", Uri("http://www.w3.org/1998/Math/MathML")), [Engine.test_id("math")], [Engine.element(tag("mi", MathML), [], [Engine.text("x")]), Engine.element(tag("mo", MathML), [], [Engine.text("+")]), Engine.element(tag("mn", MathML), [], [Engine.text("1")])]),
				Engine.each(
					Engine.const(["a", "b"]),
					|key| key,
					|row| Engine.element(
						"article",
						[Engine.test_id_s(row.key().map(|key| "row-${key}"))],
						[
							Engine.when(Engine.const(True), || Engine.element("em", [], [Engine.text("nested")]), || Engine.text("")),
							Engine.element("span", [Engine.test_id_s(row.key().map(|key| "tail-${key}")), Engine.ref_s(row.key().map(|key| "ref-${key}"))], [Engine.text_s(row.item())]),
						],
					),
				),
				Html.placeholder({}, "<p data-testid='waiting'>Static waiting</p>", || Engine.element("p", [Engine.test_id("active")], [Engine.text("Live active")])),
			],
		)
	},
)
