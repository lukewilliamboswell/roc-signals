import cli.Path
import Proc

## The platform's link inputs, none of them committed:
##
## - for the browser module (`platform/main.roc`, `targets/wasm32/`):
##   `host.wasm`, built from `platform/host/host.zig` with the pinned Zig;
## - for the native spec runner on Linux (`platform/main.roc`,
##   `targets/x64musl/`): `spec.o`, built from `platform/host/spec.zig` with
##   the pinned Zig, and musl's `crt1.o` and `libc.a`, Zig's `libzigc.a` and
##   `libcompiler_rt.a`, taken from the roc-fuzz 0.6.0 release bundle, the
##   release the fuzz targets name as their platform;
## - for the native spec runner on macOS and Windows (`targets/arm64mac/`,
##   `targets/x64mac/`, `targets/x64win/`): the same host as a static
##   library for each, cross-compiled with the pinned Zig, and for Windows
##   `kernel32.lib`, made by `zig dlltool` from `platform/host/kernel32.def`
##   (see `spec_hosts`).
##
## The bundle is checked against the SHA-256 recorded here; it is downloaded
## once into the build directory, and every run checks its digest before
## unpacking it.
PlatformTest := [].{
	bundle_url = "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.6.0/6uc3YKGydgEnS2nrCimSYWDNfT6drYcgU52VAwqrb6DS.tar.zst"
	bundle_sha256 = "19720c3b47a6ca37394404c8ea379bddba4d1167984a9221243d9b11226a2039"

	## The inputs `platform/main.roc` lists for x64musl, from the bundle.
	native_inputs : List(Str)
	native_inputs = ["crt1.o", "libc.a", "libzigc.a", "libcompiler_rt.a"]

	## Fetch, verify and unpack the native runner's libc inputs from the
	## roc-fuzz bundle, then build `host.wasm` and `spec.o`.
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
		native_dir = "${root}/platform/targets/x64musl"
		Path.create_all!(Path.utf8(native_dir))?
		for name in PlatformTest.native_inputs {
			Path.copy!(Path.utf8("${unpacked}/targets/x64musl/${name}"), Path.utf8("${native_dir}/${name}"))?
		}
		Path.create_all!(Path.utf8("${root}/platform/targets/wasm32"))?
		Proc.run!({ program: zig, args: ["build-obj", "host/host.zig", "-target", "wasm32-freestanding", "-O", "ReleaseSmall", "-fstrip", "-femit-bin=targets/wasm32/host.wasm"], cwd: "${root}/platform" })?
		Proc.run!({ program: zig, args: ["build-obj", "host/spec.zig", "-target", "x86_64-linux-musl", "-O", "ReleaseFast", "-fstrip", "-fPIC", "-femit-bin=targets/x64musl/spec.o"], cwd: "${root}/platform" })?
		for host in PlatformTest.spec_hosts {
			Path.create_all!(Path.utf8("${root}/platform/targets/${host.target}"))?
			Proc.run!({ program: zig, args: ["build-lib", "-static", "host/spec.zig", "-target", host.zig_target, "-O", "ReleaseFast", "-fstrip", "-fcompiler-rt", "-femit-bin=targets/${host.target}/${host.file}"], cwd: "${root}/platform" })?
		}
		Proc.run!({ program: zig, args: ["dlltool", "-m", "i386:x86-64", "-d", "host/kernel32.def", "-l", "targets/x64win/kernel32.lib"], cwd: "${root}/platform" })
	}

	## The spec runner's host for each system besides Linux x86-64, a static
	## library built from `host/spec.zig` with Zig's compiler-rt inside it
	## (`memcpy`, the stack probes). The Roc linker supplies libSystem on
	## macOS. On Windows the host links no C runtime: its only other input
	## is `kernel32.lib`, the import library `prepare!` makes from
	## `host/kernel32.def`.
	spec_hosts : List({ target : Str, zig_target : Str, file : Str })
	spec_hosts = [
		{ target: "arm64mac", zig_target: "aarch64-macos", file: "libhost.a" },
		{ target: "x64mac", zig_target: "x86_64-macos", file: "libhost.a" },
		{ target: "x64win", zig_target: "x86_64-windows-msvc", file: "host.lib" },
	]

	## The native spec runner's link inputs for every system, relative to
	## `platform/`: what the release bundle carries besides the Wasm host.
	spec_inputs : List(Str)
	spec_inputs = ["targets/x64musl/spec.o"]
		.concat(PlatformTest.native_inputs.map(|name| "targets/x64musl/${name}"))
		.concat(PlatformTest.spec_hosts.map(|h| "targets/${h.target}/${h.file}"))
		.concat(["targets/x64win/kernel32.lib"])
}
