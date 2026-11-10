## The roc-signals fuzz platform: the repository's second platform root, for
## each app's `main-fuzz.roc` built with `roc build --fuzz`. It is not part of
## the release bundle and apps never name it.
##
## A fuzz target needs roc-fuzz's `requires { target : Target }` and its
## libFuzzer host, so it cannot share the authoring platform (`main.roc`),
## whose one entry builds the browser module and the native spec runner. This
## root shares that platform's modules instead, and exposes what the fuzz
## targets drive: the engine's internal `Core`, the spec runner, the `Dom`
## oracle, the `.scm` parser, the soak walk and the worker wire format.
##
## Everything else here is a vendored copy of the roc-fuzz 0.5.0 platform
## (https://github.com/lukewilliamboswell/roc-fuzz, MIT, see
## LICENSE-roc-fuzz), unchanged; its host and linker inputs come from the
## roc-fuzz 0.5.0 release bundle, fetched and verified by
## `scripts/src/PlatformTest.roc` into `fuzz-targets/`. The copy stays until
## roc-fuzz can be embedded instead of vendored:
## https://github.com/lukewilliamboswell/roc-fuzz/issues/98.
platform "roc-signals-fuzz"
	requires {
		target : Target
	}
	exposes [Arbitrary, Core, Dom, Engine, Fuzz, Html, JsonOut, Scm, Soak, SpecRunner, Target, Wire]
	packages {}
	provides {
		"roc_fuzz_example": example_for_host,
		"roc_fuzz_example_count": example_count_for_host,
		"roc_fuzz_name": name_for_host,
		"roc_fuzz_run": run_for_host!,
		"roc_fuzz_show": show_for_host,
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
	}
	targets: {
		inputs_dir: "fuzz-targets/",
		x64musl: { inputs: ["crt1.o", "libhost.a", app, "libfuzzer.a", "libc++.a", "libc++abi.a", "libunwind.a", "libc.a", "libzigc.a", "libcompiler_rt.a", "libc.a", "libzigc.a", "libcompiler_rt.a"] },
	}

import Arbitrary
import Core
import Dom
import Engine
import Fuzz
import Html
import JsonOut
import Scm
import Soak
import SpecRunner
import Target
import Wire

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
