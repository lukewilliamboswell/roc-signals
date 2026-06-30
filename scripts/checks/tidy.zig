//! Repository tidiness checks for the standalone Signals platform.

const std = @import("std");

const Allocator = std.mem.Allocator;
const PathList = std.ArrayList([]u8);

const max_file_bytes: usize = 8 * 1024 * 1024;

const TermColor = struct {
    const red = "\x1b[0;31m";
    const green = "\x1b[0;32m";
    const reset = "\x1b[0m";
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();

    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len == 2 and std.mem.eql(u8, args[1], "--git-lints")) {
        try runGitLints(gpa, io);
        return;
    }
    if (args.len != 1) {
        std.debug.print("usage: tidy [--git-lints]\n", .{});
        std.process.exit(2);
    }

    try runTidy(gpa, io);
}

fn runTidy(allocator: Allocator, io: std.Io) !void {
    var paths: PathList = .empty;
    defer freePathList(&paths, allocator);
    try walkTree(allocator, io, ".", &paths);

    var errors: usize = 0;
    for (paths.items) |path| {
        errors += try checkFile(allocator, io, path);
    }

    if (errors != 0) {
        std.debug.print("\n{s}[FAIL]{s} Found {d} tidy violation(s)\n", .{ TermColor.red, TermColor.reset, errors });
        std.process.exit(1);
    }

    std.debug.print("{s}[OK]{s} All tidy checks passed\n", .{ TermColor.green, TermColor.reset });
}

fn runGitLints(allocator: Allocator, io: std.Io) !void {
    const result = try std.process.run(allocator, io, .{
        .argv = &.{ "git", "ls-files", "-z", "--", "*.mdtodo", ":(glob)**/plan.md" },
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.term != .exited or result.term.exited != 0) {
        std.debug.print("{s}", .{result.stderr});
        return error.GitFailed;
    }

    var count: usize = 0;
    var entries = std.mem.splitScalar(u8, result.stdout, 0);
    while (entries.next()) |entry| {
        if (entry.len == 0) continue;
        count += 1;
        std.debug.print("{s}: scratch planning files must not be committed\n", .{entry});
    }

    if (count != 0) {
        std.debug.print("\n{s}[FAIL]{s} Found {d} Git lint violation(s)\n", .{ TermColor.red, TermColor.reset, count });
        std.process.exit(1);
    }

    std.debug.print("{s}[OK]{s} All Git lints passed\n", .{ TermColor.green, TermColor.reset });
}

fn walkTree(allocator: Allocator, io: std.Io, dir_path: []const u8, paths: *PathList) !void {
    var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind == .sym_link) continue;
        if (shouldSkipName(entry.name)) continue;

        const next_path = try std.fs.path.join(allocator, &.{ dir_path, entry.name });
        switch (entry.kind) {
            .directory => {
                if (shouldSkipDir(next_path)) {
                    allocator.free(next_path);
                    continue;
                }
                defer allocator.free(next_path);
                try walkTree(allocator, io, next_path, paths);
            },
            .file => {
                if (shouldCheckFile(next_path)) {
                    try paths.append(allocator, next_path);
                } else {
                    allocator.free(next_path);
                }
            },
            else => allocator.free(next_path),
        }
    }
}

fn shouldSkipName(name: []const u8) bool {
    return std.mem.eql(u8, name, ".git") or
        std.mem.eql(u8, name, ".zig-cache") or
        std.mem.eql(u8, name, "zig-out") or
        std.mem.eql(u8, name, "zig-pkg") or
        std.mem.eql(u8, name, "kcov-output") or
        std.mem.eql(u8, name, ".bundle-url-test") or
        std.mem.eql(u8, name, "__pycache__") or
        std.mem.eql(u8, name, ".DS_Store");
}

fn shouldSkipDir(path: []const u8) bool {
    return std.mem.eql(u8, repoRelativePath(path), "platform/targets");
}

fn shouldCheckFile(path: []const u8) bool {
    const repo_path = repoRelativePath(path);
    if (std.mem.startsWith(u8, repo_path, "platform/targets/")) return false;

    const skipped_extensions = [_][]const u8{
        ".a",       ".lib", ".o",   ".obj", ".wasm", ".png", ".jpg", ".jpeg", ".gif", ".webp",
        ".tar.zst", ".gz",  ".zip", ".pyc",
    };
    for (skipped_extensions) |ext| {
        if (std.mem.endsWith(u8, repo_path, ext)) return false;
    }
    return true;
}

fn repoRelativePath(path: []const u8) []const u8 {
    if (std.mem.startsWith(u8, path, "./")) return path[2..];
    return path;
}

fn checkFile(allocator: Allocator, io: std.Io, path: []const u8) !usize {
    const bytes = std.Io.Dir.cwd().readFileAllocOptions(
        io,
        path,
        allocator,
        .limited(max_file_bytes),
        std.mem.Alignment.of(u8),
        0,
    ) catch |err| switch (err) {
        error.FileNotFound => return 0,
        error.StreamTooLong => return 0,
        else => return err,
    };
    defer allocator.free(bytes);

    if (std.mem.indexOfScalar(u8, bytes, 0) != null) return 0;

    var errors: usize = 0;
    if (bytes.len != 0 and bytes[bytes.len - 1] != '\n') {
        std.debug.print("{s}: missing trailing newline\n", .{path});
        errors += 1;
    }

    for (bytes, 0..) |byte, index| {
        if (byte < 0x20 and byte != '\n' and byte != '\r' and byte != '\t') {
            std.debug.print("{s}:{d}: control character 0x{x} is not allowed\n", .{ path, lineNumber(bytes, index), byte });
            errors += 1;
        }
    }

    return errors;
}

fn lineNumber(bytes: []const u8, offset: usize) usize {
    var line: usize = 1;
    for (bytes[0..offset]) |byte| {
        if (byte == '\n') line += 1;
    }
    return line;
}

fn freePathList(paths: *PathList, allocator: Allocator) void {
    for (paths.items) |path| allocator.free(path);
    paths.deinit(allocator);
}
