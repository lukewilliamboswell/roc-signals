app [main] { pf: platform "../../platform/main.roc" }

import pf.Engine exposing [Elem, In, Root, State]
import pf.Html

Model : { settings : Bool, help : Bool }

Ctx : In(Root, Model)

main : Engine.Program
main = Engine.program(|| Engine.state({ settings: False, help: False }, page))

# region dialog
## Accept the browser's close echo so Escape and the close button agree
## with the same signal. The helper owns the dialog's content scope.
settings : State(Ctx, Model) -> Elem(Ctx)
settings = |model| Html.dialog(
	"Settings",
	{ open: model.signal().map(|m| m.settings), on_close: model.set_value(|m, open| { ..m, settings: open }) },
	[],
	[
		Html.h2("Settings", ""),
		Html.button("Close settings", [], model.update(|m| { ..m, settings: False })),
	],
)

# endregion dialog

# region popover
## An automatic popover accepts browser-driven hiding, including Escape
## and opening another unrelated automatic popover.
help : State(Ctx, Model) -> Elem(Ctx)
help = |model| Html.popover(
	"Help",
	{ open: model.signal().map(|m| m.help), on_toggle: model.set_value(|m, open| { ..m, help: open }) },
	[],
	[Engine.text("Choose settings to change your preferences.")],
)

# endregion popover

page : State(Ctx, Model) -> Elem(Ctx)
page = |model| Html.div(
	"",
	[
		Html.button("Open settings", [], model.update(|m| { ..m, settings: True })),
		Html.button("Show help", [], model.update(|m| { ..m, help: True })),
		settings(model),
		help(model),
	],
)

## The instance holds this store beside its site tree.
Store : {}
