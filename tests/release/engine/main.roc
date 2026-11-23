app [main] { engine: "https://example.invalid/0.8.0-rc1/ENGINE.tar.zst", pf: platform "./platform.roc" }

import engine.Engine
import engine.EngineHost
import Fixture

main : Engine.Program({})
main = Fixture.program

expect {
	driver = EngineHost.driver(main)
	(state, commands, work) = (driver.init)([])
	(store, sites) = EngineHost.split(state)
	(next, changed, next_work) = (driver.event)(EngineHost.join(store, sites), commands, work, 1, 0, "typed".to_utf8())
	file = [1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 120, 0, 0, 0, 0]
	(_, received, _) = (driver.files)(next, changed, next_work, 1, 1, file, [Box.box(7.U64)])
	driver.version == 23 and Str.from_utf8_lossy((driver.keys)()).contains("notice") and Str.from_utf8_lossy(changed).contains("typed") and received.len() > 4
}
