## The native test platform for roc-signals: the second root of `platform/`.
##
## It shares `Engine.roc` and `Html.roc` with the web platform (`main.roc`), so
## an app's modules (`import pf.Engine`) compile unchanged under both: its
## `main-web.roc` names `main.roc` and its `main-test.roc` and `main-fuzz.roc`
## name this file. Everything else here is the roc-fuzz 0.5.0 platform (https://github.com/lukewilliamboswell/roc-fuzz,
## MIT, see LICENSE-roc-fuzz) with one addition: an executable whose target was
## built with `Target.cli` also runs as a command-line program, which is how
## the native `.scm` spec runner (`test-support/SpecRunner.roc`) reads spec
## files and reports results. Fuzz targets built with `roc build --fuzz` are
## unchanged: `Fuzz.target*` targets behave exactly as on roc-fuzz.
##
## The roc-fuzz host (`test-targets/*/libhost.a`) and its linker inputs come
## from the roc-fuzz 0.5.0 release bundle; `host/cli.zig` is this repository's
## own object, which supplies `main` and the `Cli` services. Neither is
## committed: `scripts/build_platform_test.roc` fetches and verifies the release
## inputs and builds `cli.o` with the pinned Zig.
platform "roc-signals-test"
	requires {
		target : Target
	}
	exposes [Arbitrary, Cli, Engine, Fuzz, Html, Target]
	packages {}
	provides {
		"roc_fuzz_example": example_for_host,
		"roc_fuzz_example_count": example_count_for_host,
		"roc_fuzz_name": name_for_host,
		"roc_fuzz_run": run_for_host!,
		"roc_fuzz_show": show_for_host,
		"roc_test_cli": cli_for_host!,
	}
	hosted {
		"roc_fuzz_alloc_count": Fuzz.alloc_count!,
		"roc_fuzz_before": Fuzz.before!,
		"roc_fuzz_count": Fuzz.count!,
		"roc_fuzz_dealloc_count": Fuzz.dealloc_count!,
		"roc_fuzz_forbidden": Fuzz.forbidden!,
		"roc_fuzz_live_alloc_count": Fuzz.live_alloc_count!,
		"roc_fuzz_mark": Fuzz.mark!,
		"roc_fuzz_prepare_return_box": Fuzz.prepare_return_box!,
		"roc_fuzz_realloc_count": Fuzz.realloc_count!,
		"roc_fuzz_requested_bytes": Fuzz.requested_bytes!,
		"roc_fuzz_scope_finish": Fuzz.scope_finish!,
		"roc_fuzz_scope_finish_return": Fuzz.scope_finish_return!,
		"roc_fuzz_scope_start": Fuzz.scope_start!,
		"roc_test_file_exists": Cli.file_exists!,
		"roc_test_now_ns": Cli.now_ns!,
		"roc_test_read_file": Cli.read_file!,
		"roc_test_stderr": Cli.stderr!,
		"roc_test_stdout": Cli.stdout!,
	}
	targets: {
		inputs_dir: "test-targets/",
		x64musl: { inputs: ["crt1.o", "cli.o", "libhost.a", app, "libfuzzer.a", "libc++.a", "libc++abi.a", "libunwind.a", "libc.a", "libzigc.a", "libcompiler_rt.a", "libc.a", "libzigc.a", "libcompiler_rt.a"] },
	}

import Arbitrary
import Cli
import Engine
import Fuzz
import Html
import Target

name_for_host : () -> Str
name_for_host = || target.name()

example_count_for_host : () -> U64
example_count_for_host = || target.example_count()

example_for_host : U64 -> { name : Str, revision : Str, bytes : List(U8) }
example_for_host = |index| target.example(index)

run_for_host! : List(U8) => U8
run_for_host! = |input| target.run!(input)

show_for_host : List(U8) -> Str
show_for_host = |input| target.show(input)

cli_for_host! : List(Str) => I32
cli_for_host! = |args| target.cli!(args)
