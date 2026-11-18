app [main] { pf: platform "../../../platform/main.roc" }
import pf.Engine
import pf.Html

Store : {}

# region entries
entries = Engine.entries({}, [{ path: "/", route: "home" }, { path: "/about/", route: "about" }])

main : Engine.Program
main = Engine.program_startup({}, entries, |route| page(route))

# endregion entries

page : Str -> Engine.Elem(Engine.Root)
page = |route| Html.div("", [Html.h1(route, ""), controls({}), current_location({})])

# region placeholder
controls : {} -> Engine.Elem(ctx)
controls = |_| Engine.state(
	0.I64,
	|count| Html.div(
		"",
		[
			Html.button("Increment", [], count.update(|n| n + 1)),
			Html.placeholder(
				{},
				"<p>Preparing the controls</p>",
				|| Html.p_s(count.signal().to_text_signal(), []),
			),
		],
	),
)

# endregion placeholder

# region environment
current_location : {} -> Engine.Elem(ctx)
current_location = |_| Engine.resource(
	Engine.const({}),
	{
		init: "Reading the current location",
		pending: |last, _| last,
		plan: |_| [Engine.environment({})],
		resolve: |_, _, result| match result {
			Ok(facts) => facts.url
			Err(Refused) => "The request was refused"
		},
	},
	|location| Html.p_s(location, []),
)

# endregion environment

mounted : U64
mounted = Engine.mounts(main)
