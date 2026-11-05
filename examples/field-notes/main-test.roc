app [target] {
	pf: platform "../../platform/test.roc",
	ts: "../../test-support/main.roc",
}

import pf.Cli
import pf.Target
import ts.SpecRunner
import NotesApp

## Field Notes, native spec runner: `main-test spec [--filter GLOB]
## [--emit-steps] specs/*.scm`.
target = Target.cli({ name: "field-notes-specs", main!: |args| SpecRunner.main!(NotesApp.program, io, args) })

io : SpecRunner.Io
io = { read_file!: Cli.read_file!, stdout!: Cli.stdout!, stderr!: Cli.stderr!, now_ns!: Cli.now_ns! }
