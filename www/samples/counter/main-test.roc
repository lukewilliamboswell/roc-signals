app [target] {
	pf: platform "../../../platform/test.roc",
	ts: "../../../test-support/main.roc",
}

import pf.Cli
import pf.Core
import pf.Target
import ts.SpecRunner
import Counter

## The native spec runner: `main-test spec specs/*.scm`.
target = Target.cli({ name: "counter-specs", main!: |args| SpecRunner.main!(Core.driver(Counter.program), io, args) })

io : SpecRunner.Io
io = { read_file!: Cli.read_file!, stdout!: Cli.stdout!, stderr!: Cli.stderr!, now_ns!: Cli.now_ns! }
