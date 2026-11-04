platform ""
	requires {} { main : () -> U64 }
	exposes [Erased]
	packages { roc: "nightly-2026-09-12-220fd47" }
	provides { "result": result }
	hosted { "erase": Erased.erase!, "restore": Erased.restore! }
	targets: { inputs_dir: "../../platform/targets/", wasm32: { inputs: ["host.wasm", app], exports: [] } }

import Erased

result : () -> U64
result = || main()
