app [target] {
	pf: platform "../../platform/test.roc",
	ts: "../../test-support/main.roc",
}

import pf.Cli
import pf.Target
import ts.SpecRunner
import ConduitApp

## Conduit, native spec runner: `main-test spec [--filter GLOB]
## [--emit-steps] specs/*.scm`.
target = Target.cli({ name: "conduit-specs", main!: |args| SpecRunner.main!(ConduitApp.program, io, args) })

io : SpecRunner.Io
io = { read_file!: Cli.read_file!, stdout!: Cli.stdout!, stderr!: Cli.stderr!, now_ns!: Cli.now_ns! }
