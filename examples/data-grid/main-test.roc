app [target] {
	pf: platform "../../platform/test.roc",
	ts: "../../test-support/main.roc",
}

import pf.Cli
import pf.Target
import ts.SpecRunner
import GridApp

## Data Grid, native spec runner: `main-test spec [--filter GLOB]
## [--emit-steps] specs/*.scm`.
target = Target.cli({ name: "data-grid-specs", main!: |args| SpecRunner.main!(GridApp.program, io, args) })

io : SpecRunner.Io
io = { read_file!: Cli.read_file!, stdout!: Cli.stdout!, stderr!: Cli.stderr!, now_ns!: Cli.now_ns! }
