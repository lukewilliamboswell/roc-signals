import cli.Path
import Proc

## The platform's uncommitted link inputs. The pinned Zig builds every
## native input: a static PIE probe selects matching musl startup and libc
## libraries for Linux, and the same spec host is compiled with PIC for
## Linux, macOS and Windows. Nothing depends on a fetched platform's
## non-relocatable native libraries.
PlatformTest := [].{

	## The Linux runner's startup and libraries, selected by Zig's own link.
	native_inputs : List(Str)
	native_inputs = ["rcrt1.o", "libc.a", "libzigc.a", "libcompiler_rt.a"]

	## Build all native link inputs with the pinned Zig and the browser host.
	## The probe is never shipped: its verbose link lists the exact matching
	## startup and runtime libraries the platform must carry. Missing inputs
	## fail preparation rather than mixing toolchains or substituting crt1.
	prepare! : { root : Str, build_dir : Str, zig : Str } => Try({}, _)
	prepare! = |{ root, build_dir, zig }| {
		work = "${build_dir}/native-runtime"
		Path.create_all!(Path.utf8(work))?
		probe = "${work}/probe.c"
		Path.write_utf8!(Path.utf8(probe), "int main(void) { return 0; }\n")?
		{ code, stdout } = Proc.merged!({ program: zig, args: ["build-exe", probe, "-target", "x86_64-linux-musl", "-lc", "-O", "ReleaseFast", "-fstrip", "-fPIC", "-fPIE", "-static", "--verbose-link", "-femit-bin=${work}/probe"], cwd: root })?
		if code != 0 {
			return Err(NativeRuntimeBuildFailed(Str.from_utf8_lossy(stdout)))
		}
		native_dir = "${root}/platform/targets/x64musl"
		Path.create_all!(Path.utf8(native_dir))?
		var $found = []
		for token in Str.from_utf8_lossy(stdout).split_on(" ") {
			path = token.trim()
			match PlatformTest.native_inputs.find_first(|name| path.ends_with("/${name}")) {
				Ok(name) if !$found.contains(name) => {
					Path.copy!(Path.utf8(path), Path.utf8("${native_dir}/${name}"))?
					$found = $found.append(name)
				}
				_ => {}
			}
		}
		missing = PlatformTest.native_inputs.drop_if(|name| $found.contains(name))
		if !missing.is_empty() {
			return Err(MissingNativeRuntimeInputs(missing))
		}
		Path.create_all!(Path.utf8("${root}/platform/targets/wasm32"))?
		Proc.run!({ program: zig, args: ["build-obj", "host/host.zig", "-target", "wasm32-freestanding", "-O", "ReleaseSmall", "-fstrip", "-femit-bin=targets/wasm32/host.wasm"], cwd: "${root}/platform" })?
		Proc.run!({ program: zig, args: ["build-obj", "host/spec.zig", "-target", "x86_64-linux-musl", "-O", "ReleaseFast", "-fstrip", "-fPIC", "-femit-bin=targets/x64musl/spec.o"], cwd: "${root}/platform" })?
		for host in PlatformTest.spec_hosts {
			Path.create_all!(Path.utf8("${root}/platform/targets/${host.target}"))?
			Proc.run!({ program: zig, args: ["build-lib", "-static", "host/spec.zig", "-target", host.zig_target, "-O", "ReleaseFast", "-fstrip", "-fPIC", "-fcompiler-rt", "-femit-bin=targets/${host.target}/${host.file}"], cwd: "${root}/platform" })?
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
