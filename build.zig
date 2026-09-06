//! Build graph for Signals hosts, checks, tests, and generated platform artifacts.

const std = @import("std");

const OptimizeMode = std.builtin.OptimizeMode;
const ResolvedTarget = std.Build.ResolvedTarget;
const Step = std.Build.Step;

const RocTarget = enum {
    x64mac,
    x64musl,
    arm64mac,
    arm64musl,

    fn toZigTarget(self: RocTarget) std.Target.Query {
        return switch (self) {
            .x64mac => .{ .cpu_arch = .x86_64, .os_tag = .macos },
            .x64musl => .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .musl },
            .arm64mac => .{ .cpu_arch = .aarch64, .os_tag = .macos },
            .arm64musl => .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .musl },
        };
    }

    fn targetDir(self: RocTarget) []const u8 {
        return switch (self) {
            .x64mac => "x64mac",
            .x64musl => "x64musl",
            .arm64mac => "arm64mac",
            .arm64musl => "arm64musl",
        };
    }
};

const native_targets = [_]RocTarget{
    .x64mac,
    .x64musl,
    .arm64mac,
    .arm64musl,
};

/// Defines the repository build, check, test, and artifact steps.
pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const native_target = b.standardTargetOptions(.{});
    const metrics = b.option(bool, "metrics", "Enable runtime telemetry counters") orelse true;
    const profile = b.option(bool, "profile", "Preserve native host symbols for profiling") orelse false;
    const test_filters = b.option([]const []const u8, "test-filter", "Skip Zig unit tests that do not match any filter") orelse &.{};
    const fuzz = b.option(bool, "fuzz", "Build AFL++ fuzz executables alongside the repro executables") orelse false;
    const use_system_afl = b.option(bool, "system-afl", "Link fuzz executables with the system AFL++ instead of the vendored one") orelse true;

    const build_options = b.addOptions();
    build_options.addOption(bool, "metrics", metrics);
    build_options.addOption(bool, "fuzz_fixtures", false);
    build_options.addOption(bool, "wasm_benchmark", false);
    build_options.addOption(bool, "wasm_allocation_ledger", optimize == .Debug or optimize == .ReleaseSafe);
    const build_options_module = build_options.createModule();
    // Fuzz targets drive the native host through its test fixture surface and
    // assert on runtime metrics, so they get their own options module.
    const fuzz_build_options = b.addOptions();
    fuzz_build_options.addOption(bool, "metrics", true);
    fuzz_build_options.addOption(bool, "fuzz_fixtures", true);
    fuzz_build_options.addOption(bool, "wasm_benchmark", false);
    fuzz_build_options.addOption(bool, "wasm_allocation_ledger", true);
    const fuzz_build_options_module = fuzz_build_options.createModule();

    const build_hosts_step = b.step("build-test-hosts", "Build platform host artifacts");
    const build_wasm_host_step = b.step("build-wasm-host", "Build the wasm32 browser host artifact");
    const build_wasm_benchmark_host_step = b.step("build-wasm-benchmark-host", "Build the instrumented ReleaseFast wasm32 benchmark host artifact");
    const run_check_zig_format_step = b.step("run-check-zig-format", "Check Zig formatting");
    const run_check_zig_lints_step = b.step("run-check-zig-lints", "Run Zig lints");
    const run_check_tidy_step = b.step("run-check-tidy", "Run tidiness checks");
    const run_check_git_lints_step = b.step("run-check-git-lints", "Run Git-backed tidiness checks");
    const run_check_test_wiring_step = b.step("run-check-test-wiring", "Check Zig test wiring");
    const run_fmt_zig_step = b.step("run-fmt-zig", "Format Zig code");
    const run_test_zig_step = b.step("run-test-zig", "Run Zig unit tests");
    const run_test_browser_step = b.step("run-test-browser", "Run browser JavaScript contract tests");
    const build_coverage_tests_step = b.step("build-coverage-tests", "Build native host coverage test binaries");
    const run_coverage_native_host_step = b.step("run-coverage-native-host", "Run native host and signals tests with kcov coverage");
    const test_step = b.step("test", "Run Zig-only checks and tests");
    const build_fuzz_step = b.step("build-fuzz", "Build every fuzz target and its repro executable");

    const install_step = b.getInstallStep();
    install_step.dependOn(build_hosts_step);

    for (native_targets) |roc_target| {
        const target = b.resolveTargetQuery(roc_target.toZigTarget());
        const copy_step = buildAndCopyNativeHostLib(b, target, optimize, build_options_module, roc_target, profile);
        build_hosts_step.dependOn(copy_step);
    }

    const wasm_target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding, .abi = .none });
    const wasm_host_step = buildAndCopyWasmHostObject(b, wasm_target, optimize, build_options_module);
    build_hosts_step.dependOn(wasm_host_step);
    build_wasm_host_step.dependOn(wasm_host_step);

    const wasm_benchmark_options = b.addOptions();
    wasm_benchmark_options.addOption(bool, "metrics", true);
    wasm_benchmark_options.addOption(bool, "fuzz_fixtures", false);
    wasm_benchmark_options.addOption(bool, "wasm_benchmark", true);
    wasm_benchmark_options.addOption(bool, "wasm_allocation_ledger", true);
    const wasm_benchmark_host = buildWasmHostObject(b, wasm_target, .ReleaseFast, wasm_benchmark_options.createModule());
    const wasm_production_benchmark_host = buildWasmHostObject(b, wasm_target, .ReleaseFast, build_options_module);
    const install_wasm_production_benchmark_host = b.addInstallFileWithDir(
        wasm_production_benchmark_host.getEmittedBin(),
        .prefix,
        "wasm-benchmark/production-host.o",
    );
    const install_wasm_benchmark_host = b.addInstallFileWithDir(
        wasm_benchmark_host.getEmittedBin(),
        .prefix,
        "wasm-benchmark/host.o",
    );
    build_wasm_benchmark_host_step.dependOn(&install_wasm_benchmark_host.step);
    build_wasm_benchmark_host_step.dependOn(&install_wasm_production_benchmark_host.step);

    const shared_test = b.addTest(.{
        .name = "signals_shared",
        .root_module = createSignalsModule(b, native_target, optimize, build_options_module),
        .filters = test_filters,
    });
    const run_shared_test = b.addRunArtifact(shared_test);
    if (b.args) |args| run_shared_test.addArgs(args);

    const host_test = b.addTest(.{
        .name = "signals_host",
        .root_module = createNativeHostModule(b, native_target, optimize, build_options_module),
        .filters = test_filters,
    });
    const run_host_test = b.addRunArtifact(host_test);
    if (b.args) |args| run_host_test.addArgs(args);

    run_test_zig_step.dependOn(&run_shared_test.step);
    run_test_zig_step.dependOn(&run_host_test.step);

    const browser_tests = b.addSystemCommand(&.{
        "node",
        "--test",
        "scripts/browser/command_buffer_snapshot.test.mjs",
        "scripts/browser/conduit_backend.test.mjs",
        "scripts/browser/dom_double.test.mjs",
        "scripts/browser/validate_wasm.test.mjs",
        "scripts/browser/http_task_router.test.mjs",
        "scripts/browser/runtime_contract.test.mjs",
        "scripts/browser/run_wasm_benchmarks.test.mjs",
        "scripts/browser/service_ops_charts.test.mjs",
        "scripts/browser/wasm_host_call_batch.test.mjs",
        "scripts/browser/wasm_benchmark_host.test.mjs",
        "scripts/browser/wasm_benchmark_metrics.test.mjs",
        "scripts/browser/wasm_benchmark_runtime.test.mjs",
        "scripts/browser/wasm_memory_views.test.mjs",
        "scripts/browser/wasm_panic_fixture.test.mjs",
    });
    const wasm_integration_options = b.addOptions();
    wasm_integration_options.addOption(bool, "metrics", metrics);
    wasm_integration_options.addOption(bool, "fuzz_fixtures", false);
    wasm_integration_options.addOption(bool, "wasm_benchmark", false);
    wasm_integration_options.addOption(bool, "wasm_allocation_ledger", true);
    const wasm_integration_host = buildWasmHostObject(b, wasm_target, optimize, wasm_integration_options.createModule());
    const mkdir_wasm_fixture = b.addSystemCommand(&.{ "mkdir", "-p", ".test-out/oom" });
    const copy_wasm_fixture = b.addSystemCommand(&.{"cp"});
    copy_wasm_fixture.addFileArg(wasm_integration_host.getEmittedBin());
    copy_wasm_fixture.addArg(".test-out/oom/host.o");
    copy_wasm_fixture.step.dependOn(&mkdir_wasm_fixture.step);
    const link_wasm_fixture = b.addSystemCommand(&.{
        "zig",       "build-exe",                ".test-out/oom/host.o",
        "-target",   "wasm32-freestanding-none", "-fno-entry",
        "-rdynamic", "-fallow-shlib-undefined",  "-femit-bin=.test-out/oom/host-fixture.wasm",
    });
    link_wasm_fixture.step.dependOn(&copy_wasm_fixture.step);
    const link_bounded_wasm_fixture = b.addSystemCommand(&.{
        "zig",                                                "build-exe",
        ".test-out/oom/host.o",                               "-target",
        "wasm32-freestanding-none",                           "-fno-entry",
        "-rdynamic",                                          "-fallow-shlib-undefined",
        // The linked fixture's static image currently requires 1,189,156
        // bytes. Wasm memory is page-granular, so 19 pages is the narrowest
        // fixed initial/max budget that still leaves memory.grow unavailable.
        "--initial-memory=1245184",                           "--max-memory=1245184",
        "-femit-bin=.test-out/oom/host-fixture-bounded.wasm",
    });
    link_bounded_wasm_fixture.step.dependOn(&copy_wasm_fixture.step);
    const mkdir_wasm_benchmark_fixture = b.addSystemCommand(&.{ "mkdir", "-p", ".test-out/wasm-benchmark" });
    const copy_wasm_benchmark_fixture = b.addSystemCommand(&.{ "cp", "zig-out/wasm-benchmark/host.o", ".test-out/wasm-benchmark/host.o" });
    copy_wasm_benchmark_fixture.step.dependOn(&mkdir_wasm_benchmark_fixture.step);
    copy_wasm_benchmark_fixture.step.dependOn(&install_wasm_benchmark_host.step);
    const link_wasm_benchmark_fixture = b.addSystemCommand(&.{
        "zig",       "build-exe",                ".test-out/wasm-benchmark/host.o",
        "-target",   "wasm32-freestanding-none", "-fno-entry",
        "-rdynamic", "-fallow-shlib-undefined",  "-femit-bin=.test-out/wasm-benchmark/host-fixture.wasm",
    });
    link_wasm_benchmark_fixture.step.dependOn(&copy_wasm_benchmark_fixture.step);
    browser_tests.step.dependOn(&link_wasm_fixture.step);
    browser_tests.step.dependOn(&link_bounded_wasm_fixture.step);
    browser_tests.step.dependOn(&link_wasm_benchmark_fixture.step);
    run_test_browser_step.dependOn(&browser_tests.step);

    const fmt_paths = [_][]const u8{ "build.zig", "src", "scripts", "test" };
    const fmt = b.addFmt(.{ .paths = &fmt_paths });
    run_fmt_zig_step.dependOn(&fmt.step);

    const check_fmt = b.addFmt(.{ .paths = &fmt_paths, .check = true });
    run_check_zig_format_step.dependOn(&check_fmt.step);

    const zig_lints = b.addExecutable(.{
        .name = "zig_lints",
        .root_module = b.createModule(.{
            .root_source_file = b.path("scripts/checks/zig_lints.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    const tidy = b.addExecutable(.{
        .name = "tidy",
        .root_module = b.createModule(.{
            .root_source_file = b.path("scripts/checks/tidy.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    const test_wiring = b.addExecutable(.{
        .name = "check_test_wiring",
        .root_module = b.createModule(.{
            .root_source_file = b.path("scripts/checks/check_test_wiring.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });

    const run_zig_lints = b.addRunArtifact(zig_lints);
    run_check_zig_lints_step.dependOn(&run_zig_lints.step);

    const run_tidy = b.addRunArtifact(tidy);
    run_check_tidy_step.dependOn(&run_tidy.step);

    const run_git_lints = b.addRunArtifact(tidy);
    run_git_lints.addArg("--git-lints");
    run_check_git_lints_step.dependOn(&run_git_lints.step);

    const run_test_wiring = b.addRunArtifact(test_wiring);
    run_check_test_wiring_step.dependOn(&run_test_wiring.step);

    test_step.dependOn(run_check_zig_format_step);
    test_step.dependOn(run_check_zig_lints_step);
    test_step.dependOn(run_check_tidy_step);
    test_step.dependOn(run_check_git_lints_step);
    test_step.dependOn(run_check_test_wiring_step);
    test_step.dependOn(run_test_zig_step);

    for (fuzz_targets) |name| {
        addFuzzTarget(b, .{
            .name = name,
            .target = native_target,
            .optimize = optimize,
            .build_options = fuzz_build_options_module,
            .fuzz = fuzz,
            .use_system_afl = use_system_afl,
            .build_fuzz_step = build_fuzz_step,
        });
    }

    const is_linux_x86_64 = native_target.result.os.tag == .linux and native_target.result.cpu.arch == .x86_64;
    const is_coverage_supported = (native_target.result.os.tag == .linux or native_target.result.os.tag == .macos) and !is_linux_x86_64;
    if (is_coverage_supported) {
        if (b.lazyDependency("kcov", .{})) |kcov_dep| {
            const shared_coverage_test = b.addTest(.{
                .name = "signals_shared_coverage",
                .root_module = createSignalsModule(b, native_target, .Debug, build_options_module),
            });
            const host_coverage_test = b.addTest(.{
                .name = "signals_host_coverage",
                .root_module = createNativeHostModule(b, native_target, .Debug, build_options_module),
            });

            const install_shared_coverage = b.addInstallArtifact(shared_coverage_test, .{});
            const install_host_coverage = b.addInstallArtifact(host_coverage_test, .{});

            const kcov_exe = kcov_dep.artifact("kcov");
            const install_kcov = b.addInstallArtifact(kcov_exe, .{});

            build_coverage_tests_step.dependOn(&install_shared_coverage.step);
            build_coverage_tests_step.dependOn(&install_host_coverage.step);
            build_coverage_tests_step.dependOn(&install_kcov.step);

            const mkdir_step = b.addSystemCommand(&.{ "mkdir", "-p", "kcov-output/native-host" });
            mkdir_step.setCwd(b.path("."));
            mkdir_step.step.dependOn(build_coverage_tests_step);

            if (native_target.result.os.tag == .macos) {
                const codesign = b.addSystemCommand(&.{"codesign"});
                codesign.setCwd(b.path("."));
                codesign.addArgs(&.{ "-s", "-", "--entitlements" });
                codesign.addFileArg(kcov_dep.path("osx-entitlements.xml"));
                codesign.addArgs(&.{ "-f", "zig-out/bin/kcov" });
                codesign.step.dependOn(&install_kcov.step);
                mkdir_step.step.dependOn(&codesign.step);
            }

            const run_shared_coverage = b.addSystemCommand(&.{"zig-out/bin/kcov"});
            run_shared_coverage.addArg("--include-pattern=/src/");
            run_shared_coverage.addArgs(&.{
                "kcov-output/native-host",
                "zig-out/bin/signals_shared_coverage",
            });
            run_shared_coverage.setCwd(b.path("."));
            run_shared_coverage.step.dependOn(&mkdir_step.step);
            run_shared_coverage.step.dependOn(&install_shared_coverage.step);
            run_shared_coverage.step.dependOn(&install_kcov.step);

            const run_host_coverage = b.addSystemCommand(&.{"zig-out/bin/kcov"});
            run_host_coverage.addArg("--include-pattern=/src/");
            run_host_coverage.addArgs(&.{
                "kcov-output/native-host",
                "zig-out/bin/signals_host_coverage",
            });
            run_host_coverage.setCwd(b.path("."));
            run_host_coverage.step.dependOn(&run_shared_coverage.step);
            run_host_coverage.step.dependOn(&install_host_coverage.step);
            run_host_coverage.step.dependOn(&install_kcov.step);

            run_coverage_native_host_step.dependOn(build_coverage_tests_step);
            run_coverage_native_host_step.dependOn(&run_host_coverage.step);
        }
    } else {
        const unsupported = CoverageUnsupportedStep.create(b);
        run_coverage_native_host_step.dependOn(&unsupported.step);
    }
}

/// Fuzz targets, one per `test/fuzzing/fuzz-<name>.zig`.
///
/// The first five drive the engine as a state machine: they decode fuzzer bytes
/// into a valid program and check it against a slow reference model. `boundary`
/// is a conventional byte-oriented parser target.
const fuzz_targets = [_][]const u8{
    "propagation",
    "keyed-scopes",
    "rows-transitions",
    "structural",
    "ownership",
    "boundary",
};

const FuzzTargetOptions = struct {
    name: []const u8,
    target: ResolvedTarget,
    optimize: OptimizeMode,
    build_options: *std.Build.Module,
    fuzz: bool,
    use_system_afl: bool,
    build_fuzz_step: *Step,
};

/// Wires one fuzz target into the build graph.
///
/// Each target produces two artifacts from a single object file. `repro-<name>`
/// is always built: it is a plain executable that replays one input from a file,
/// argument, or stdin, so it needs no AFL++ and works on every platform. The
/// AFL++ persistent-mode executable `fuzz-<name>` is built only under `-Dfuzz`,
/// because it needs `afl-cc` to link the instrumented object against AFL's
/// runtime. Sharing the object keeps the two in lockstep: a crash found by the
/// fuzzer replays through exactly the code that produced it.
fn addFuzzTarget(b: *std.Build, options: FuzzTargetOptions) void {
    // The native host module must see the same `signals` module instance as
    // the target, or the engine types it hands back would not unify.
    const signals_module = createSignalsModule(b, options.target, .ReleaseSafe, options.build_options);
    const fuzz_obj = b.addObject(.{
        .name = b.fmt("fuzz_{s}_obj", .{options.name}),
        .root_module = b.createModule(.{
            .root_source_file = b.path(b.fmt("test/fuzzing/fuzz-{s}.zig", .{options.name})),
            .target = options.target,
            .optimize = .ReleaseSafe,
            .link_libc = true,
            .imports = &.{
                .{ .name = "signals", .module = signals_module },
                .{ .name = "native_host", .module = createNativeHostModuleWith(b, options.target, .ReleaseSafe, options.build_options, signals_module) },
            },
        }),
    });
    // AFL++ traps stack-probe faults itself, and the guards would otherwise be
    // attributed to the target as spurious crashes.
    fuzz_obj.root_module.stack_check = false;

    const build_afl = options.fuzz and canBuildAfl(options.target);
    if (build_afl) {
        fuzz_obj.sanitize_coverage_trace_pc_guard = true;
    }

    const repro_exe = b.addExecutable(.{
        .name = b.fmt("repro-{s}", .{options.name}),
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/fuzzing/fuzz-repro.zig"),
            .target = options.target,
            .optimize = options.optimize,
            .link_libc = true,
        }),
    });
    repro_exe.root_module.addImport("fuzz_test", fuzz_obj.root_module);

    const install_repro = b.addInstallArtifact(repro_exe, .{});
    options.build_fuzz_step.dependOn(&install_repro.step);

    const run_repro = b.addRunArtifact(repro_exe);
    if (b.args) |args| run_repro.addArgs(args);
    const run_repro_step = b.step(
        b.fmt("run-repro-{s}", .{options.name}),
        b.fmt("Replay one fuzz input through the {s} target", .{options.name}),
    );
    run_repro_step.dependOn(&run_repro.step);

    if (!build_afl) return;

    if (addAflFuzzExe(b, options, fuzz_obj)) |fuzz_exe| {
        const install_fuzz = b.addInstallBinFile(fuzz_exe, b.fmt("fuzz-{s}", .{options.name}));
        options.build_fuzz_step.dependOn(&install_fuzz.step);
    }
}

/// Reports whether AFL++ fuzz executables can be linked for `target`.
///
/// AFL++ persistent mode needs to inject its own runtime and fork server, which
/// rules out cross compilation and Windows entirely. On unsupported hosts the
/// build still produces the repro executables, which is what makes a saved crash
/// file portable between a fuzzing machine and a developer's.
fn canBuildAfl(target: ResolvedTarget) bool {
    if (target.result.os.tag == .windows) return false;
    return target.query.isNative();
}

fn addAflFuzzExe(b: *std.Build, options: FuzzTargetOptions, fuzz_obj: *Step.Compile) ?std.Build.LazyPath {
    const afl_kit = b.lazyDependency("afl_kit", .{}) orelse return null;

    const afl_cc = if (options.use_system_afl)
        b.findProgram(&.{"afl-cc"}, &.{}) catch {
            std.log.warn("-Dfuzz needs 'afl-cc' on PATH (install AFL++, or pass -Dsystem-afl=false); building repro executables only", .{});
            return null;
        }
    else blk: {
        const afl = afl_kit.builder.lazyDependency("AFLplusplus", .{
            .target = options.target,
            .optimize = options.optimize,
            .@"llvm-config-path" = &[_][]const u8{},
        }) orelse return null;
        break :blk b.pathJoin(&.{ afl.builder.exe_dir, "afl-cc" });
    };

    const run_afl_cc = b.addSystemCommand(&.{ afl_cc, "-O3" });

    // Requesting the object output makes Zig materialize the LLVM bitcode that
    // afl-cc consumes below; without it the bitcode path is never produced.
    _ = fuzz_obj.getEmittedBin();

    run_afl_cc.addArg("-o");
    const fuzz_exe = run_afl_cc.addOutputFileArg(fuzz_obj.name);
    run_afl_cc.addFileArg(afl_kit.path("afl.c"));
    run_afl_cc.addFileArg(fuzz_obj.getEmittedLlvmBc());
    // ELF linkers resolve left to right, so math libraries must follow the bitcode.
    run_afl_cc.addArg("-lm");

    return fuzz_exe;
}

fn createSignalsModule(
    b: *std.Build,
    target: ResolvedTarget,
    optimize: OptimizeMode,
    build_options: *std.Build.Module,
) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path("src/signals/mod.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "build_options", .module = build_options },
        },
    });
}

fn createNativeHostModule(
    b: *std.Build,
    target: ResolvedTarget,
    optimize: OptimizeMode,
    build_options: *std.Build.Module,
) *std.Build.Module {
    return createNativeHostModuleWith(b, target, optimize, build_options, createSignalsModule(b, target, optimize, build_options));
}

fn createNativeHostModuleWith(
    b: *std.Build,
    target: ResolvedTarget,
    optimize: OptimizeMode,
    build_options: *std.Build.Module,
    signals_module: *std.Build.Module,
) *std.Build.Module {
    const is_musl = target.result.os.tag == .linux and target.result.abi == .musl;
    return b.createModule(.{
        .root_source_file = b.path("src/native_host.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = !is_musl,
        .imports = &.{
            .{ .name = "signals", .module = signals_module },
            .{ .name = "build_options", .module = build_options },
        },
    });
}

fn buildNativeHostLib(
    b: *std.Build,
    target: ResolvedTarget,
    optimize: OptimizeMode,
    build_options: *std.Build.Module,
    profile: bool,
) *Step.Compile {
    const host_lib = b.addLibrary(.{
        .name = "host",
        .linkage = .static,
        .root_module = createNativeHostModule(b, target, optimize, build_options),
    });
    host_lib.root_module.strip = optimize != .Debug and !profile;
    host_lib.root_module.pic = true;
    host_lib.bundle_compiler_rt = true;
    host_lib.link_function_sections = true;
    host_lib.link_data_sections = true;
    return host_lib;
}

fn buildAndCopyNativeHostLib(
    b: *std.Build,
    target: ResolvedTarget,
    optimize: OptimizeMode,
    build_options: *std.Build.Module,
    roc_target: RocTarget,
    profile: bool,
) *Step {
    const host_lib = buildNativeHostLib(b, target, optimize, build_options, profile);
    const copy = b.addUpdateSourceFiles();
    copy.addCopyFileToSource(
        host_lib.getEmittedBin(),
        b.pathJoin(&.{ "platform", "targets", roc_target.targetDir(), "libhost.a" }),
    );
    return &copy.step;
}

fn buildAndCopyWasmHostObject(
    b: *std.Build,
    target: ResolvedTarget,
    optimize: OptimizeMode,
    build_options: *std.Build.Module,
) *Step {
    const obj = buildWasmHostObject(b, target, optimize, build_options);

    const copy = b.addUpdateSourceFiles();
    copy.addCopyFileToSource(obj.getEmittedBin(), "platform/targets/wasm32/host.wasm");
    return &copy.step;
}

fn buildWasmHostObject(
    b: *std.Build,
    target: ResolvedTarget,
    optimize: OptimizeMode,
    build_options: *std.Build.Module,
) *Step.Compile {
    const obj = b.addObject(.{
        .name = "signals_host",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/wasm_host.zig"),
            .target = target,
            .optimize = optimize,
            .strip = optimize != .Debug,
            .pic = true,
            .imports = &.{
                .{ .name = "signals", .module = createSignalsModule(b, target, optimize, build_options) },
                .{ .name = "build_options", .module = build_options },
            },
        }),
    });
    obj.link_function_sections = true;
    obj.link_data_sections = true;

    return obj;
}

const CoverageUnsupportedStep = struct {
    step: Step,

    fn create(b: *std.Build) *CoverageUnsupportedStep {
        const self = b.allocator.create(CoverageUnsupportedStep) catch @panic("OOM");
        self.* = .{
            .step = Step.init(.{
                .id = .custom,
                .name = "coverage-unsupported",
                .owner = b,
                .makeFn = make,
            }),
        };
        return self;
    }

    fn make(step: *Step, _: Step.MakeOptions) !void {
        std.debug.print("\n", .{});
        std.debug.print("Native host coverage is supported on macOS and Linux arm64.\n", .{});
        std.debug.print("Linux x86_64 is currently disabled because kcov cannot reliably read Zig DWARF there.\n\n", .{});
        return step.fail("native host coverage is not supported on this platform", .{});
    }
};
