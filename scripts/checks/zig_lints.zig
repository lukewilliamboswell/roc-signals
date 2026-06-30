//! Lightweight Zig source lints for the standalone Signals platform.

const std = @import("std");

const Allocator = std.mem.Allocator;
const PathList = std.ArrayList([]u8);

const max_file_bytes: usize = 16 * 1024 * 1024;

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

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_state = std.Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_state.interface;

    var zig_files: PathList = .empty;
    defer freePathList(&zig_files, gpa);

    try walkTree(gpa, io, "src", &zig_files);
    try walkTree(gpa, io, "scripts", &zig_files);
    try zig_files.append(gpa, try gpa.dupe(u8, "build.zig"));

    var found_errors = false;
    for (zig_files.items) |file_path| {
        const errors = try checkSeparatorComments(gpa, io, file_path);
        defer gpa.free(errors);
        if (errors.len != 0) {
            try stdout.print("{s}", .{errors});
            found_errors = true;
        }
    }

    if (found_errors) {
        try stdout.print("\n{s}[FAIL]{s} Zig lint violations found\n", .{ TermColor.red, TermColor.reset });
        try stdout.flush();
        std.process.exit(1);
    }

    try stdout.print("{s}[OK]{s} All Zig lints passed\n", .{ TermColor.green, TermColor.reset });
    try stdout.flush();
}

fn walkTree(allocator: Allocator, io: std.Io, dir_path: []const u8, zig_files: *PathList) !void {
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer dir.close(io);

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind == .sym_link) continue;

        const next_path = try std.fs.path.join(allocator, &.{ dir_path, entry.name });
        switch (entry.kind) {
            .directory => {
                if (std.mem.eql(u8, entry.name, ".zig-cache") or std.mem.eql(u8, entry.name, "zig-out")) {
                    allocator.free(next_path);
                    continue;
                }
                defer allocator.free(next_path);
                try walkTree(allocator, io, next_path, zig_files);
            },
            .file => {
                if (std.mem.endsWith(u8, entry.name, ".zig")) {
                    try zig_files.append(allocator, next_path);
                } else {
                    allocator.free(next_path);
                }
            },
            else => allocator.free(next_path),
        }
    }
}

fn checkSeparatorComments(allocator: Allocator, io: std.Io, file_path: []const u8) ![]u8 {
    if (std.mem.endsWith(u8, file_path, "src/signals/roc_platform_abi.zig")) {
        return try allocator.dupe(u8, "");
    }

    const source = try readSourceFile(allocator, io, file_path);
    defer allocator.free(source);

    var errors: std.ArrayList(u8) = .empty;
    errdefer errors.deinit(allocator);

    var line_num: usize = 1;
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        defer line_num += 1;
        const trimmed = std.mem.trimStart(u8, line, " \t");
        if (!std.mem.startsWith(u8, trimmed, "//")) continue;

        const after_slashes = std.mem.trim(u8, trimmed[2..], " \t");
        if (after_slashes.len < 4) continue;
        if (isRepeated(after_slashes, '=') or isRepeated(after_slashes, '-')) {
            const msg = try std.fmt.allocPrint(
                allocator,
                "{s}:{d}: horizontal separator comment is not allowed\n",
                .{ file_path, line_num },
            );
            defer allocator.free(msg);
            try errors.appendSlice(allocator, msg);
        }
    }

    return errors.toOwnedSlice(allocator);
}

fn isRepeated(text: []const u8, byte: u8) bool {
    var count: usize = 0;
    for (text) |ch| {
        if (ch == byte) {
            count += 1;
            if (count >= 4) return true;
        } else if (ch != ' ') {
            return false;
        }
    }
    return false;
}

fn readSourceFile(allocator: Allocator, io: std.Io, path: []const u8) ![:0]u8 {
    return try std.Io.Dir.cwd().readFileAllocOptions(
        io,
        path,
        allocator,
        .limited(max_file_bytes),
        std.mem.Alignment.of(u8),
        0,
    );
}

fn freePathList(paths: *PathList, allocator: Allocator) void {
    for (paths.items) |path| allocator.free(path);
    paths.deinit(allocator);
}
