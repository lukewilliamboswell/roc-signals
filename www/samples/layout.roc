app [main] { pf: platform "../../platform/main.roc" }

import pf.Engine exposing [Elem]
import pf.Html
import pf.Layout

# region media
color_query = "(prefers-color-scheme: dark)"

## Media is declared before mount so the first paint uses its boot value.
## The subscription follows later changes through the ordinary result turn.
main : Engine.Program
main = Engine.program_boot(
	{ media: [color_query] },
	|boot| {
		initial = match Engine.boot_media(boot, color_query) {
			Ok(matches) => matches
			Err(Undeclared) => crash "the color query must be declared"
		}
		Engine.state(
			initial,
			|dark| Html.div(
				"",
				[
					Html.p_s(dark.signal().map(|matches| if (matches) "Dark colors" else "Light colors"), []),
					Engine.watch(
						Engine.const({}),
						|_| [Engine.media_changes(color_query)],
						dark.on_result(
							|before, _issued, result| match result {
								Ok(matches) => matches
								_ => before
							},
						),
					),
					observations({}),
				],
			),
		)
	},
)

# endregion media

# region observations
## The box takes its size from CSS, independently of what its handler writes.
## Visibility and size registrations belong to this element's scope.
observations : {} -> Elem(ctx)
observations = |_args| Engine.state(
	{ size: { width: 0.U32, height: 0.U32 }, seen: { intersecting: False, ratio_permille: 0.U16 } },
	|facts| Engine.element(
		"section",
		[
			Html.aria_label("Observed box"),
			Engine.attr("style", "width:300px;height:150px;overflow:hidden"),
			Html.on_size(facts.set_value(|before, size| { ..before, size })),
			Html.on_seen({ ahead: True }, facts.set_value(|before, seen| { ..before, seen })),
		],
		[Html.p_s(facts.signal().map(|current| "${current.size.width.to_str()} × ${current.size.height.to_str()}, visible ${Str.inspect(current.seen.intersecting)}"), [])],
	),
)
# endregion observations

## The payloads are plain records; the application can test decisions over
## them without an engine or a browser.
expect {
	size : Layout.Size
	size = { width: 300, height: 150 }
	size.height // 20 == 7
}

## The instance holds this store beside its site tree.
Store : {}

## Check that the default first page mounts while this app compiles.
mounted : U64
mounted = Engine.mounts(main)
