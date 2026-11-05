# Development environment and tasks for Roc Signals, realised by roc-blueprint.
#
#     blueprint run check                  # the pull-request gate
#     blueprint run spec -- --browser kanban-board
#     blueprint run site                   # build the site into dist/
#     blueprint run serve                  # serve dist/ on localhost
#     blueprint run fuzz -- --time 600     # a fuzz campaign
#     blueprint tasks                      # list every task
#     blueprint update                     # refresh Blueprint.lock
#
# Every pinned tool is a fetched release, so no environment starts Nix. The
# one Roc compiler is `roc-stable`: it builds the scripts, the platform, the
# examples and the tests alike.
app [config] { pf: platform "https://github.com/lukewilliamboswell/roc-blueprint/releases/download/0.8.0/FbJymjYdCxx9vqMcau7r4tQfeAbnVGqqJoYrLGqPCqKu.tar.zst" }

import pf.Config
import pf.Recipes
import pf.System

zig_program = Fetch("zig", zig)

zola_program = Fetch("zola", zola)

node_program = Fetch("node", node)

# The roc-automation documentation renderer, which generates the API docs.
roc_docs_program = Fetch("roc-docs", Recipes.file("https://github.com/lukewilliamboswell/roc-automation/releases/download/tools-0.10.0/roc-docs-{system}"))

# The Roc nightly the Roc-owned engine is built and tested with. It is also
# the scripts' tooling compiler (`roc-stable`), so every script's `roc` header
# field names the same release. roc-overlay packages it as
# `nix#rocpkgs.nightly-2026-11-03-34bd006`; it is fetched directly here so no
# environment starts Nix.
roc_stable_program = Fetch("roc-stable", Recipes.roc_nightly("nightly-2026-11-03-34bd006"))

config = [
	Name("roc-signals"),
	Systems(["x86_64-linux", "aarch64-linux", "aarch64-darwin"]),
	# The Roc-owned engine: native and browser spec runs, the test platform's
	# fetched inputs, and the scripts that drive them. curl, tar, zstd and
	# sha256sum fetch and verify the roc-fuzz release inputs of
	# platform-test.
	#
	# Chrome is the machine's `google-chrome` for now. Chrome for Testing ships
	# only zip archives, and blueprint 0.8.0 (and 0.9.0) unpacks a Zip download
	# with `tar -xf`, which GNU tar cannot read; the pinned recipe is ready
	# below as `chrome` and replaces this Expect once blueprint unpacks zips on
	# Linux.
	Environment("engine", [Programs([roc_stable_program, zig_program, node_program]), Expect(["curl", "tar", "zstd", "sha256sum", "getconf", "google-chrome", "zip"])]),
	# Building the documentation site, its API docs and its live examples.
	Environment("site", [Programs([roc_stable_program, zig_program, zola_program, roc_docs_program, Fetch("tailwindcss", tailwind)])]),
	# Building the release assets, API docs included.
	Environment("release", [Programs([roc_stable_program, zig_program, node_program, roc_docs_program]), Expect(["zip"])]),
	Shell("default", [Use("engine")]),
	# The per-pull-request gate: formatting, roc test, the docs samples, every
	# app's specs natively and in Chrome, the broken-spec self-check, the
	# runtime contract tests, the jfb check and the release dry run.
	Task("check", [Use("engine"), Run(["scripts/check_all.roc"])]),
	# Too slow for every pull request: every fuzz target's examples and the
	# leak-checked soaks, natively and in Chrome.
	Task("check-slow", [Use("engine"), Run(["scripts/check_slow.roc"])]),
	# One or more apps' specs: `blueprint run spec -- --browser kanban-board`.
	Task("spec", [Use("engine"), Run(["scripts/spec.roc", "--"])]),
	# Fetch and build the test platform's host, for building a main-test.roc
	# by hand.
	Task("platform-test", [Use("engine"), Run(["scripts/build_platform_test.roc"])]),
	# Build the js-framework-benchmark app and check it in Chrome.
	Task("jfb", [Use("engine"), Run(["scripts/jfb.roc"])]),
	# A fuzz campaign: `blueprint run fuzz -- --time 600 [TARGET...]`.
	Task("fuzz", [Use("engine"), Run(["scripts/fuzz.roc", "--"])]),
	# The release assets: `blueprint run release -- --version 0.3.0`.
	Task("release", [Use("release"), Run(["scripts/release.roc", "--"])]),
	# Build the site into dist/: `-- --base-url http://127.0.0.1:8000/roc-signals` for serve.
	Task("site", [Use("site"), Run(["scripts/site.roc", "--"])]),
	# Serve dist/ at 127.0.0.1:8000/roc-signals/, or `-- DIR` at the root (`--port N`).
	Task("serve", [Use("engine"), Run(["node", "www/serve.mjs", "--"])]),
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
