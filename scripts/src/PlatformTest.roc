import cli.Path
import Proc

## The platform's link inputs, none of them committed:
##
## - for the browser module (`platform/main.roc`, `targets/wasm32/`):
##   `host.wasm`, built from `platform/host/host.zig` with the pinned Zig;
## - for the native spec runner (`platform/main.roc`, `targets/x64musl/`):
##   `spec.o`, built from `platform/host/spec.zig` with the pinned Zig, and
##   musl's `crt1.o` and `libc.a`, Zig's `libzigc.a` and `libcompiler_rt.a`,
##   taken from the roc-fuzz 0.6.0 release bundle;
## - for the fuzz platform (`platform/fuzz.roc`, `fuzz-targets/x64musl/`):
##   the roc-fuzz host and its linker inputs from the same bundle.
##
## The bundle is checked against the SHA-256 recorded here; it is downloaded
## once into the build directory, and every run checks its digest before
## unpacking it.
PlatformTest := [].{
	bundle_url = "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.6.0/6uc3YKGydgEnS2nrCimSYWDNfT6drYcgU52VAwqrb6DS.tar.zst"
	bundle_sha256 = "19720c3b47a6ca37394404c8ea379bddba4d1167984a9221243d9b11226a2039"

	## The linker inputs `platform/fuzz.roc` lists for x64musl, from the bundle.
	bundle_inputs : List(Str)
	bundle_inputs = ["crt1.o", "libhost.a", "libfuzzer.a", "libc++.a", "libc++abi.a", "libunwind.a", "libc.a", "libzigc.a", "libcompiler_rt.a"]

	## The inputs `platform/main.roc` lists for x64musl, from the bundle.
	native_inputs : List(Str)
	native_inputs = ["crt1.o", "libc.a", "libzigc.a", "libcompiler_rt.a"]

	## Fetch, verify and unpack the roc-fuzz inputs, then build `host.wasm` and
	## `spec.o`.
	prepare! : { root : Str, build_dir : Str, zig : Str } => Try({}, _)
	prepare! = |{ root, build_dir, zig }| {
		downloads = "${build_dir}/downloads"
		Path.create_all!(Path.utf8(downloads))?
		bundle = "${downloads}/roc-fuzz-0.6.0.tar.zst"
		if !(Path.exists!(Path.utf8(bundle))?) {
			Proc.run!({ program: "curl", args: ["-fsSL", "--retry", "3", "-o", "${bundle}.part", PlatformTest.bundle_url], cwd: root })?
			Path.rename!(Path.utf8("${bundle}.part"), Path.utf8(bundle))?
		}
		sum = Str.from_utf8_lossy(Proc.capture!({ program: "sha256sum", args: [bundle], cwd: root })?)
		if (sum.split_on(" ").first() ?? "") != PlatformTest.bundle_sha256 {
			return Err(DigestMismatch("${bundle}: expected sha256 ${PlatformTest.bundle_sha256}, got ${sum}"))
		}
		unpacked = "${build_dir}/roc-fuzz-0.6.0"
		if Path.exists!(Path.utf8(unpacked))? {
			Path.delete_all!(Path.utf8(unpacked))?
		}
		Path.create_all!(Path.utf8(unpacked))?
		Proc.run!({ program: "tar", args: ["--zstd", "-xf", bundle, "-C", unpacked, "targets/x64musl"], cwd: root })?
		fuzz_dir = "${root}/platform/fuzz-targets/x64musl"
		Path.create_all!(Path.utf8(fuzz_dir))?
		for name in PlatformTest.bundle_inputs {
			Path.copy!(Path.utf8("${unpacked}/targets/x64musl/${name}"), Path.utf8("${fuzz_dir}/${name}"))?
		}
		native_dir = "${root}/platform/targets/x64musl"
		Path.create_all!(Path.utf8(native_dir))?
		for name in PlatformTest.native_inputs {
			Path.copy!(Path.utf8("${unpacked}/targets/x64musl/${name}"), Path.utf8("${native_dir}/${name}"))?
		}
		Path.create_all!(Path.utf8("${root}/platform/targets/wasm32"))?
		Proc.run!({ program: zig, args: ["build-obj", "host/host.zig", "-target", "wasm32-freestanding", "-O", "ReleaseSmall", "-fstrip", "-femit-bin=targets/wasm32/host.wasm"], cwd: "${root}/platform" })?
		Proc.run!({ program: zig, args: ["build-obj", "host/spec.zig", "-target", "x86_64-linux-musl", "-O", "ReleaseFast", "-fstrip", "-fPIC", "-femit-bin=targets/x64musl/spec.o"], cwd: "${root}/platform" })
	}
}
