platform ""
	requires {
		main : {} -> Elem
	}
	exposes [Elem, Signal, Html, Ui, Http]
	packages {
		http: "https://github.com/roc-lang/http/releases/download/0.1/6LcdNq2r7xTBwj972ecYWUkMWobJr94yL2NyJpHRAXap.tar.zst",
	}
	provides { "roc_ui_init": ui_init }
	hosted {
		"roc_host_value_clone": HostValue.clone,
		"roc_host_value_get_with_capability": HostValue.get_with_capability,
		"roc_host_value_get_with_split": HostValue.get_with_split,
		"roc_host_value_store_with_capability": HostValue.store_with_capability,
		"roc_host_value_store_with_existing_capability": HostValue.store_with_existing_capability,
		"roc_host_value_take_with_capability": HostValue.take_with_capability,
		"roc_host_value_take_with_split": HostValue.take_with_split,
	}
	targets: {
		inputs_dir: "targets/",
		wasm32: { inputs: ["host.wasm", app], output: Shared },
		x64mac: { inputs: ["libhost.a", app] },
		arm64mac: { inputs: ["libhost.a", app] },
	}

import Elem exposing [Elem]
import HostValue
import Signal
import Html
import Ui
import Http

ui_init : {} -> Box(Elem)
ui_init = |_| {
	Box.box(main({}))
}
