app [target] {
	pf: platform "../../platform/test.roc",
	ts: "../../test-support/main.roc",
}

import pf.Cli
import pf.Target
import ts.SpecRunner
import KanbanApp

## Kanban Board, native spec runner: `main-test spec [--filter GLOB]
## [--emit-steps] [--pending-phase3] specs/*.scm`.
target = Target.cli({ name: "kanban-board-specs", main!: |args| SpecRunner.main!(KanbanApp.program, io, args) })

io : SpecRunner.Io
io = { read_file!: Cli.read_file!, stdout!: Cli.stdout!, stderr!: Cli.stderr!, now_ns!: Cli.now_ns! }
