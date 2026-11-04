import cli.Path
import Proc

## The inputs `platform-test` links against, none of them committed:
##
## - the roc-fuzz host and its linker inputs, taken from the roc-fuzz 0.5.0
##   release bundle and checked against the SHA-256 recorded here;
## - `cli.o`, built from `platform-test/host/cli.zig` with the pinned Zig.
##
## The bundle is downloaded once into the build directory; every run checks
## its digest before unpacking it.
PlatformTest := [].{
	bundle_url = "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.5.0/9WT86CuwM7ZJBSs8iTd1jLyrUFTTiGp5hcJE63TwswGE.tar.zst"
	bundle_sha256 = "aed4032105af1cc910604949f43636b7bff6aec4a82184631213153b8e2dd23f"

	## The linker inputs `platform-test/main.roc` lists for x64musl, from the bundle.
	bundle_inputs : List(Str)
	bundle_inputs = ["crt1.o", "libhost.a", "libfuzzer.a", "libc++.a", "libc++abi.a", "libunwind.a", "libc.a", "libzigc.a", "libcompiler_rt.a"]

	## Fetch, verify and unpack the roc-fuzz inputs, then build `cli.o`.
	prepare! : { root : Str, build_dir : Str, zig : Str } => Try({}, _)
	prepare! = |{ root, build_dir, zig }| {
		downloads = "${build_dir}/downloads"
		Path.create_all!(Path.utf8(downloads))?
		bundle = "${downloads}/roc-fuzz-0.5.0.tar.zst"
		if !(Path.exists!(Path.utf8(bundle))?) {
			Proc.run!({ program: "curl", args: ["-fsSL", "--retry", "3", "-o", "${bundle}.part", PlatformTest.bundle_url], cwd: root })?
			Path.rename!(Path.utf8("${bundle}.part"), Path.utf8(bundle))?
		}
		sum = Str.from_utf8_lossy(Proc.capture!({ program: "sha256sum", args: [bundle], cwd: root })?)
		if (sum.split_on(" ").first() ?? "") != PlatformTest.bundle_sha256 {
			return Err(DigestMismatch("${bundle}: expected sha256 ${PlatformTest.bundle_sha256}, got ${sum}"))
		}
		unpacked = "${build_dir}/roc-fuzz-0.5.0"
		if Path.exists!(Path.utf8(unpacked))? {
			Path.delete_all!(Path.utf8(unpacked))?
		}
		Path.create_all!(Path.utf8(unpacked))?
		Proc.run!({ program: "tar", args: ["--zstd", "-xf", bundle, "-C", unpacked, "targets/x64musl"], cwd: root })?
		target_dir = "${root}/platform-test/targets/x64musl"
		Path.create_all!(Path.utf8(target_dir))?
		for name in PlatformTest.bundle_inputs {
			Path.copy!(Path.utf8("${unpacked}/targets/x64musl/${name}"), Path.utf8("${target_dir}/${name}"))?
		}
		Proc.run!({ program: zig, args: ["build-obj", "host/cli.zig", "-target", "x86_64-linux-musl", "-O", "ReleaseFast", "-fstrip", "-fPIC", "-femit-bin=targets/x64musl/cli.o"], cwd: "${root}/platform-test" })
	}
}
