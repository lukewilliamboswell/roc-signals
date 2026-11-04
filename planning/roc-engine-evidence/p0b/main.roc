platform ""
	requires {
		main : () -> Elem(Ui.Root)
	}
	exposes [Elem, Action, Signal, Val, Html, Ui, Rows]
	packages {
		roc: "nightly-2026-11-01-48d3369",
	}
	provides { "roc_ui_init": ui_init }
	targets: {
		inputs_dir: "targets/",
		x64musl: { inputs: ["crt1.o", "libhost.a", app, "libc.a"] },
	}

import Elem
import Node
import Action
import Signal
import Val
import Html
import Ui
import Rows

## Sketch entry point. The Roc-owned engine would be `Engine.apply : State,
## Input -> (State, Output)`; here we only hand the root description over.
ui_init : () -> Box(Elem(Ui.Root))
ui_init = || Box.box(main())
