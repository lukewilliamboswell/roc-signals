app [main!] { pf: platform "../wpf/main.roc" }

import pf.FallibleHost
import Engine
import Gate
import Decode

## Wasm size probe: mount, one sparse update and a route swap, so every engine
## path is reachable from the entry point.
main! = || {
	first = FallibleHost.json_input!({}).count_utf8_bytes().to_u32_wrap()
	a0 = Engine.mount(Gate.view({}), first)
	(a1, mount_cmds) = Engine.take_cmds(a0)
	sparse = Decode.scan(mount_cmds, Gate.sparse_target).found
	route = Decode.scan(mount_cmds, "route").found
	(a2, c2) = Engine.take_cmds(Engine.click(a1, sparse))
	(a3, c3) = Engine.take_cmds(Engine.click(a2, route))
	"${mount_cmds.len().to_str()} ${c2.len().to_str()} ${c3.len().to_str()} ${Engine.evals(a3).to_str()}"
}
