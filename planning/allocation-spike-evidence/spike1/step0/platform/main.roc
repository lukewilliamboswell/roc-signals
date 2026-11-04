platform ""
	requires {
		main! : () => {}
	}
	exposes [Cell]
	packages {
		roc: "nightly-2026-11-01-48d3369",
	}
	provides { "roc_run": run! }
	hosted {
		"roc_cell_alias": Cell.alias!,
		"roc_cell_check": Cell.check!,
		"roc_cell_live": Cell.live!,
		"roc_cell_rc": Cell.rc!,
		"roc_cell_same": Cell.same!,
		"roc_cell_seed": Cell.seed!,
		"roc_cell_share": Cell.share!,
		"roc_cell_store": Cell.store!,
		"roc_cell_take": Cell.take!,
	}
	targets: {
		inputs_dir: "targets/",
		wasm32: {
			inputs: ["host.wasm", app],
			output: Shared,
			exports: ["roc_run", "step0_checks", "step0_failures", "step0_last_failure", "step0_allocs", "step0_frees", "step0_live"],
		},
		x64musl: { inputs: ["crt1.o", "libhost.a", app, "libc.a"] },
	}

import Cell

run! : () => {}
run! = || main!()
