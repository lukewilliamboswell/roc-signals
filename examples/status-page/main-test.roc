app [target] {
	pf: platform "../../platform/test.roc",
	plume: "https://github.com/lukewilliamboswell/plume/releases/download/0.5.0/UstpTQVssohnU8U6Q5WpwfGxKuYZF8uWzjddwKMbTcp.tar.zst",
	ts: "../../test-support/main.roc",
}

import pf.Core
import pf.Cli
import pf.Target
import ts.SpecRunner
import StatusApp

## Status Page, native spec runner: `main-test spec [--filter GLOB]
## [--emit-steps] specs/*.scm`.
target = Target.cli({ name: "status-page-specs", main!: |args| SpecRunner.main!(Core.driver(StatusApp.program), io, args) })

io : SpecRunner.Io
io = { read_file!: Cli.read_file!, stdout!: Cli.stdout!, stderr!: Cli.stderr!, now_ns!: Cli.now_ns! }
