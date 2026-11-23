platform ""
	requires {
		[Store : st] for main : Engine.Program(st)
	}
	exposes []
	packages { engine: "https://example.invalid/0.8.0-rc1/ENGINE.tar.zst" }
	provides { "roc_engine_version": version }
	targets: {}

import engine.Engine
import engine.EngineHost

version : () -> U32
version = || EngineHost.driver(main).version
