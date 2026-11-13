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
# Every pinned tool is a fetched release, so no environment starts Nix. Two
# Roc compilers have two jobs (roc-automation's model): `roc-stable`, pinned
# below, runs the scripts; `roc`, the latest Roc nightly, checks, builds and
# tests the platform, the examples and the tests. `roc` is never pinned: CI
# installs it with roc-lang/setup-roc, and a contributor installs the current
# nightly as `roc`, so the environments expect it on PATH.
app [config] { pf: platform "https://github.com/lukewilliamboswell/roc-blueprint/releases/download/0.13.0/DBtzmMfrSgt6nCGVAcZYCVPxWbhpqw3MXpm6sdQzMn4v.tar.zst" }

import pf.Config
import pf.Recipes
import pf.System

zig_program = Fetch("zig", zig)

zola_program = Fetch("zola", zola)

node_program = Fetch("node", node)

# The roc-automation documentation renderer, which generates the API docs.
roc_docs_program = Fetch("roc-docs", Recipes.file("https://github.com/lukewilliamboswell/roc-automation/releases/download/tools-0.10.0/roc-docs-{system}"))

# The scripts' tooling compiler (`roc-stable`): every script's `roc` header
# field names this release, and `check` fails until they match. Nothing else
# is pinned to it. roc-overlay packages each nightly as
# `nix#rocpkgs.<tag>`; it is fetched directly here so no environment starts
# Nix.
roc_stable_program = Fetch("roc-stable", Recipes.roc_nightly("nightly-2026-11-10-f7d1f19"))

config = [
	Name("roc-signals"),
	Systems(["x86_64-linux", "aarch64-linux", "aarch64-darwin"]),
	# Source setup needs only Git and the tooling compiler.
	Environment("source", [Programs([roc_stable_program]), Expect(["git"])]),
	# The engine's environment: native and browser spec runs, the platform's
	# native inputs, and the scripts that drive them. The pinned Zig builds
	# matching PIC startup and runtime libraries for the native runner.
	#
	# Chrome is the machine's `google-chrome` for now. Chrome for Testing ships
	# only zip archives, and blueprint lists and unpacks a `Zip` download with
	# `tar`, which GNU tar cannot read; the pinned recipe is ready
	# below as `chrome` and replaces this Expect once blueprint unpacks zips on
	# Linux.
	Environment("engine", [Programs([roc_stable_program, zig_program, node_program]), Expect(["roc", "curl", "tar", "zstd", "sha256sum", "getconf", "google-chrome", "zip"])]),
	# Building the documentation site, its API docs and its live examples.
	Environment("site", [Programs([roc_stable_program, zig_program, zola_program, roc_docs_program, node_program, Fetch("tailwindcss", tailwind)]), Expect(["roc", "google-chrome"])]),
	# Building the release assets, API docs included.
	Environment("release", [Programs([roc_stable_program, zig_program, node_program, roc_docs_program]), Expect(["roc", "zip"])]),
	Shell("default", [Use("engine")]),
	# Run once before compiling source that imports the sibling parser.
	Task("setup-parser", [Use("source"), Run(["scripts/setup_parser.roc", "--"])]),
	# The per-pull-request gate: formatting, roc test, the docs samples, every
	# app's specs natively and in Chrome, the broken-spec self-check, the
	# runtime contract tests, the jfb check and the release dry run.
	Task("check", [Use("engine"), Run(["scripts/check_all.roc"])]),
	# Too slow for every pull request: every fuzz target's examples and the
	# leak-checked soaks, natively and in Chrome.
	Task("check-slow", [Use("engine"), Run(["scripts/check_slow.roc"])]),
	# One or more apps' specs: `blueprint run spec -- --browser kanban-board`.
	Task("spec", [Use("engine"), Run(["scripts/spec.roc", "--"])]),
	# Build the platform's native inputs (the spec runner's host and
	# libc), for building an app's native spec runner by hand.
	Task("platform", [Use("engine"), Run(["scripts/build_platform.roc"])]),
	# Build the js-framework-benchmark app and check it in Chrome.
	Task("jfb", [Use("engine"), Run(["scripts/jfb.roc"])]),
	# Measure how worker jobs scale in Chrome, on both candidate shipping
	# builds of the Worker Lab; prints tables for a pull request.
	Task("workers-scaling", [Use("engine"), Run(["scripts/workers_scaling.roc"])]),
	# A fuzz campaign: `blueprint run fuzz -- --time 600 [TARGET...]`.
	Task("fuzz", [Use("engine"), Run(["scripts/fuzz.roc", "--"])]),
	# The release assets: `blueprint run release -- --version 0.3.0`.
	Task("release", [Use("release"), Run(["scripts/release.roc", "--"])]),
	# Build the site into dist/: `-- --base-url http://127.0.0.1:8000/roc-signals` for serve.
	Task("site", [Use("site"), Run(["scripts/site.roc", "--"])]),
	# API documentation and coverage alone, without shipping app builds.
	Task("api", [Use("release"), Run(["scripts/api.roc"])]),
	# Serve dist/ at 127.0.0.1:8000/roc-signals/, or `-- DIR` at the root (`--port N`).
	Task("serve", [Use("engine"), Run(["node", "www/serve.mjs", "--"])]),
]

zig : System -> Config.Download
zig = |system| {
	base = "https://ziglang.org/download/0.17.1"
	match system {
		"x86_64-linux" => Archive("${base}/zig-x86_64-linux-0.17.1.tar.xz", TarXz, "zig-x86_64-linux-0.17.1/zig")
		"aarch64-linux" => Archive("${base}/zig-aarch64-linux-0.17.1.tar.xz", TarXz, "zig-aarch64-linux-0.17.1/zig")
		"aarch64-darwin" => Archive("${base}/zig-aarch64-macos-0.17.1.tar.xz", TarXz, "zig-aarch64-macos-0.17.1/zig")
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
