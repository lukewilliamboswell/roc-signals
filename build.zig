const std = @import("std");

const OptimizeMode = std.builtin.OptimizeMode;
const ResolvedTarget = std.Build.ResolvedTarget;
const Step = std.Build.Step;

const RocTarget = enum {
    x64mac,
    arm64mac,

    fn toZigTarget(self: RocTarget) std.Target.Query {
        return switch (self) {
            .x64mac => .{ .cpu_arch = .x86_64, .os_tag = .macos },
            .arm64mac => .{ .cpu_arch = .aarch64, .os_tag = .macos },
        };
    }

    fn targetDir(self: RocTarget) []const u8 {
        return switch (self) {
            .x64mac => "x64mac",
            .arm64mac => "arm64mac",
        };
    }
};

const native_targets = [_]RocTarget{
    .x64mac,
    .arm64mac,
};

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const native_target = b.standardTargetOptions(.{});
    const metrics = b.option(bool, "metrics", "Enable runtime telemetry counters") orelse true;

    const build_options = b.addOptions();
    build_options.addOption(bool, "metrics", metrics);
    const build_options_module = build_options.createModule();

    const build_hosts_step = b.step("build-test-hosts", "Build platform host artifacts");
    const build_wasm_host_step = b.step("build-wasm-host", "Build the wasm32 browser host artifact");
    const run_check_zig_format_step = b.step("run-check-zig-format", "Check Zig formatting");
    const run_check_zig_lints_step = b.step("run-check-zig-lints", "Run Zig lints");
    const run_check_tidy_step = b.step("run-check-tidy", "Run tidiness checks");
    const run_check_git_lints_step = b.step("run-check-git-lints", "Run Git-backed tidiness checks");
    const run_check_test_wiring_step = b.step("run-check-test-wiring", "Check Zig test wiring");
    const run_fmt_zig_step = b.step("run-fmt-zig", "Format Zig code");
    const run_test_zig_step = b.step("run-test-zig", "Run Zig unit tests");
    const run_test_browser_step = b.step("run-test-browser", "Run browser JavaScript contract tests");
    const test_step = b.step("test", "Run Zig-only checks and tests");

    const install_step = b.getInstallStep();
    install_step.dependOn(build_hosts_step);

    for (native_targets) |roc_target| {
        const target = b.resolveTargetQuery(roc_target.toZigTarget());
        const copy_step = buildAndCopyNativeHostLib(b, target, optimize, build_options_module, roc_target);
        build_hosts_step.dependOn(copy_step);
    }

    const wasm_target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding, .abi = .none });
    const wasm_host_step = buildAndCopyWasmHostObject(b, wasm_target, optimize, build_options_module);
    build_hosts_step.dependOn(wasm_host_step);
    build_wasm_host_step.dependOn(wasm_host_step);

    const shared_test = b.addTest(.{
        .name = "signals_shared",
        .root_module = createSignalsModule(b, native_target, optimize, build_options_module),
    });
    const run_shared_test = b.addRunArtifact(shared_test);
    if (b.args) |args| run_shared_test.addArgs(args);

    const host_test = b.addTest(.{
        .name = "signals_host",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/native_host.zig"),
            .target = native_target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "signals", .module = createSignalsModule(b, native_target, optimize, build_options_module) },
                .{ .name = "base", .module = createBaseModule(b, native_target, optimize) },
                .{ .name = "build_options", .module = build_options_module },
            },
        }),
    });
    const run_host_test = b.addRunArtifact(host_test);
    if (b.args) |args| run_host_test.addArgs(args);

    run_test_zig_step.dependOn(&run_shared_test.step);
    run_test_zig_step.dependOn(&run_host_test.step);

    const browser_tests = b.addSystemCommand(&.{
        "node",
        "--test",
        "scripts/browser/runtime_contract.test.mjs",
        "scripts/browser/wasm_memory_views.test.mjs",
    });
    run_test_browser_step.dependOn(&browser_tests.step);

    const fmt_paths = [_][]const u8{ "build.zig", "src", "scripts" };
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
}

fn createBaseModule(
    b: *std.Build,
    target: ResolvedTarget,
    optimize: OptimizeMode,
) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path("src/base/mod.zig"),
        .target = target,
        .optimize = optimize,
    });
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

fn buildNativeHostLib(
    b: *std.Build,
    target: ResolvedTarget,
    optimize: OptimizeMode,
    build_options: *std.Build.Module,
) *Step.Compile {
    const host_lib = b.addLibrary(.{
        .name = "host",
        .linkage = .static,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/native_host.zig"),
            .target = target,
            .optimize = optimize,
            .strip = optimize != .Debug,
            .pic = true,
            .link_libc = true,
            .imports = &.{
                .{ .name = "signals", .module = createSignalsModule(b, target, optimize, build_options) },
                .{ .name = "base", .module = createBaseModule(b, target, optimize) },
                .{ .name = "build_options", .module = build_options },
            },
        }),
    });
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
) *Step {
    const host_lib = buildNativeHostLib(b, target, optimize, build_options);
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
            },
        }),
    });
    obj.link_function_sections = true;
    obj.link_data_sections = true;

    const copy = b.addUpdateSourceFiles();
    copy.addCopyFileToSource(obj.getEmittedBin(), "platform/targets/wasm32/host.wasm");
    return &copy.step;
}
