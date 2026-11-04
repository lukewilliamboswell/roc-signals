# Development environment and tasks for Roc Signals, realised by roc-blueprint.
#
#     blueprint run minici                 # every locally reproducible CI area
#     blueprint run hosted                 # the pull-request source gate
#     blueprint run test -- zig --jobs 2   # chosen stages of scripts/test.py
#     blueprint run serve                  # build and serve the site
#     blueprint tasks                      # list every task
#     blueprint shell                      # enter the development environment
#     blueprint update                     # refresh Blueprint.lock
#
# Every pinned tool is a fetched release, so no environment starts Nix; Python,
# Git, the GitHub CLI and AFL++ are expected from the machine. The Roc
# compiler under test is not part of the environment: the web platform and its
# applications name it in their `roc` header, and scripts/minici refuses any
# other `roc` on PATH or in ROC_BIN. Blueprint reads ROC for its own
# configuration compiler, so select the compiler under test with ROC_BIN.
app [config] { pf: platform "https://github.com/lukewilliamboswell/roc-blueprint/releases/download/0.8.0/FbJymjYdCxx9vqMcau7r4tQfeAbnVGqqJoYrLGqPCqKu.tar.zst" }

import pf.Config
import pf.Recipes
import pf.System

zig_program = Fetch("zig", zig)

zola_program = Fetch("zola", zola)

node_program = Fetch("node", node)

wasm_opt_program = Fetch("wasm-opt", wasm_opt)

# The Roc nightly the Roc-owned engine is built and tested with. It is also
# the scripts' tooling compiler (`roc-stable`), so every script's `roc` header
# field names the same release. roc-overlay packages it as
# `nix#rocpkgs.nightly-2026-11-03-34bd006`; it is fetched directly here so no
# environment starts Nix.
roc_stable_program = Fetch("roc-stable", Recipes.roc_nightly("nightly-2026-11-03-34bd006"))

config = [
	Name("roc-signals"),
	Systems(["x86_64-linux", "aarch64-linux", "aarch64-darwin"]),
	# The repository scripts and their unit tests. They run on the machine's
	# Python 3.12 or later: a fetched CPython writes bytecode into its own
	# stored tree, which Blueprint then refuses as modified and unpacks again.
	Environment("scripts", [Expect(["python3", "git"])]),
	# Building and testing the engine, the hosts and the examples.
	Environment("dev", [Extend("scripts"), Programs([zig_program, node_program, wasm_opt_program])]),
	# Checking the documentation site's links and templates.
	Environment("docs", [Extend("scripts"), Programs([zola_program])]),
	# Building and serving the site, which compiles the live examples.
	Environment("site", [Extend("dev"), Programs([zola_program, Fetch("tailwindcss", tailwind)])]),
	# Building and testing the musl linker inputs, which need only `zig cc`.
	Environment("musl", [Extend("scripts"), Programs([zig_program])]),
	# A release bundles released hosts and builds none, so it has no Zig. It
	# instruments the examples' Wasm with wasm-opt, runs it under Node, and
	# talks to GitHub through the machine's `gh`.
	Environment("release", [Extend("scripts"), Programs([node_program, wasm_opt_program]), Expect(["gh"])]),
	# Fuzzing campaigns link against the machine's AFL++, which publishes no
	# relocatable release.
	Environment("fuzz", [Extend("dev"), Expect(["afl-cc", "afl-fuzz"])]),
	# The Roc-owned engine (engine/v2): native and browser spec runs, the
	# test platform's fetched inputs, and the scripts that drive them. curl,
	# tar, zstd and sha256sum fetch and verify the roc-fuzz release inputs of
	# platform-test.
	#
	# Chrome is the machine's `google-chrome` for now. Chrome for Testing ships
	# only zip archives, and blueprint 0.8.0 (and 0.9.0) unpacks a Zip download
	# with `tar -xf`, which GNU tar cannot read; the pinned recipe is ready
	# below as `chrome` and replaces this Expect once blueprint unpacks zips on
	# Linux.
	Environment("engine", [Programs([roc_stable_program, zig_program, node_program]), Expect(["curl", "tar", "zstd", "sha256sum", "google-chrome"])]),
	Shell("default", [Use("site")]),
	# The engine/v2 gate: formatting, roc test, platform-test, every ported
	# app's specs natively and in Chrome, and the mutation check.
	Task("check", [Use("engine"), Run(["scripts/check_all.roc"])]),
	# One or more apps' specs: `blueprint run spec -- --browser kanban-board`.
	Task("spec", [Use("engine"), Run(["scripts/spec.roc", "--"])]),
	Task("platform-test", [Use("engine"), Run(["scripts/build_platform_test.roc"])]),
	# The scripts/minici targets, which CI jobs and contributors share;
	# `minici` alone runs every area reproducible on this machine.
	Task("minici", [Use("site"), Run(["python3", "scripts/minici"])]),
	Task("selection", [Use("scripts"), Run(["python3", "scripts/minici", "selection"])]),
	Task("smoke", [Use("dev"), Run(["python3", "scripts/minici", "smoke"])]),
	Task("hosted", [Use("dev"), Run(["python3", "scripts/minici", "hosted"])]),
	Task("source", [Use("dev"), Run(["python3", "scripts/minici", "source"])]),
	Task("coverage", [Use("dev"), Run(["python3", "scripts/minici", "coverage"])]),
	Task("site", [Use("docs"), Run(["python3", "scripts/minici", "site"])]),
	# Script entry points; each takes its own arguments after `--`.
	Task("ci-changes", [Use("scripts"), Run(["python3", "scripts/ci_changes.py"])]),
	Task("unittest", [Use("scripts"), Run(["python3", "-m", "unittest"])]),
	Task("test", [Use("dev"), Run(["python3", "scripts/test.py"])]),
	Task("serve", [Use("site"), Run(["python3", "scripts/serve.py"])]),
	Task("fuzz", [Use("fuzz"), Run(["python3", "scripts/fuzz.py"])]),
	Task("release", [Use("release"), Run(["python3", "scripts/release.py"])]),
	Task("web-hosts", [Use("dev"), Run(["python3", "scripts/web_host_artifacts.py"])]),
	Task("build-musl", [Use("musl"), Run(["python3", "scripts/build_musl.py"])]),
	Task("test-musl", [Use("musl"), Run(["python3", "scripts/test_musl_artifact.py"])]),
]

zig : System -> Config.Download
zig = |system| {
	base = "https://ziglang.org/download/0.16.0"
	match system {
		"x86_64-linux" => Archive("${base}/zig-x86_64-linux-0.16.0.tar.xz", TarXz, "zig-x86_64-linux-0.16.0/zig")
		"aarch64-linux" => Archive("${base}/zig-aarch64-linux-0.16.0.tar.xz", TarXz, "zig-aarch64-linux-0.16.0/zig")
		"aarch64-darwin" => Archive("${base}/zig-aarch64-macos-0.16.0.tar.xz", TarXz, "zig-aarch64-macos-0.16.0/zig")
		_ => Unavailable
	}
}

node : System -> Config.Download
node = |system| {
	base = "https://nodejs.org/dist/v23.9.0"
	match system {
		"x86_64-linux" => Archive("${base}/node-v23.9.0-linux-x64.tar.xz", TarXz, "node-v23.9.0-linux-x64/bin/node")
		"aarch64-linux" => Archive("${base}/node-v23.9.0-linux-arm64.tar.xz", TarXz, "node-v23.9.0-linux-arm64/bin/node")
		"aarch64-darwin" => Archive("${base}/node-v23.9.0-darwin-arm64.tar.xz", TarXz, "node-v23.9.0-darwin-arm64/bin/node")
		_ => Unavailable
	}
}

# Binaryen's wasm-opt instruments Wasm with stack checks for the browser tests.
# Version 130 stopped finding these modules' stack pointer: `--stack-check`
# then succeeds without instrumenting or exporting `__set_stack_limits`.
wasm_opt : System -> Config.Download
wasm_opt = |system| {
	base = "https://github.com/WebAssembly/binaryen/releases/download/version_129"
	match system {
		"x86_64-linux" => Archive("${base}/binaryen-version_129-x86_64-linux.tar.gz", TarGz, "binaryen-version_129/bin/wasm-opt")
		"aarch64-linux" => Archive("${base}/binaryen-version_129-aarch64-linux.tar.gz", TarGz, "binaryen-version_129/bin/wasm-opt")
		"aarch64-darwin" => Archive("${base}/binaryen-version_129-arm64-macos.tar.gz", TarGz, "binaryen-version_129/bin/wasm-opt")
		_ => Unavailable
	}
}

zola : System -> Config.Download
zola = |system| {
	base = "https://github.com/getzola/zola/releases/download/v0.22.1"
	match system {
		"x86_64-linux" => Archive("${base}/zola-v0.22.1-x86_64-unknown-linux-gnu.tar.gz", TarGz, "zola")
		"aarch64-linux" => Archive("${base}/zola-v0.22.1-aarch64-unknown-linux-gnu.tar.gz", TarGz, "zola")
		"aarch64-darwin" => Archive("${base}/zola-v0.22.1-aarch64-apple-darwin.tar.gz", TarGz, "zola")
		_ => Unavailable
	}
}

# The standalone Tailwind CSS CLI, which needs no npm install.
tailwind : System -> Config.Download
tailwind = |system| {
	base = "https://github.com/tailwindlabs/tailwindcss/releases/download/v3.4.17"
	match system {
		"x86_64-linux" => File("${base}/tailwindcss-linux-x64")
		"aarch64-linux" => File("${base}/tailwindcss-linux-arm64")
		"aarch64-darwin" => File("${base}/tailwindcss-macos-arm64")
		_ => Unavailable
	}
}

# Chrome for Testing, for the browser spec runner (tests/browser/replay.mjs).
# No build exists for aarch64 Linux. Not yet used: see the `engine`
# environment.
chrome : System -> Config.Download
chrome = |system| {
	base = "https://storage.googleapis.com/chrome-for-testing-public/157.0.8103.38"
	match system {
		"x86_64-linux" => Archive("${base}/linux64/chrome-linux64.zip", Zip, "chrome-linux64/chrome")
		"aarch64-darwin" => Archive("${base}/mac-arm64/chrome-mac-arm64.zip", Zip, "chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing")
		_ => Unavailable
	}
}
