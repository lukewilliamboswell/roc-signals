//! Checks that Zig files containing tests are reachable from the configured test roots.

const std = @import("std");

const Allocator = std.mem.Allocator;
const PathList = std.ArrayList([]u8);

const max_file_bytes: usize = 16 * 1024 * 1024;

const TermColor = struct {
    const red = "\x1b[0;31m";
    const green = "\x1b[0;32m";
    const yellow = "\x1b[1;33m";
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

    var test_files: PathList = .empty;
    defer freePathList(&test_files, gpa);
    try walkTree(gpa, io, "src", &test_files);

    const signals_mod = try readSourceFile(gpa, io, "src/signals/mod.zig");
    defer gpa.free(signals_mod);
    const native_host = try readSourceFile(gpa, io, "src/native_host.zig");
    defer gpa.free(native_host);

    var missing: PathList = .empty;
    defer freePathList(&missing, gpa);

    for (test_files.items) |path| {
        if (isExplicitRoot(path)) continue;

        const wired = if (std.mem.startsWith(u8, path, "src/signals/"))
            rootImportsPath("src/signals/mod.zig", signals_mod, path)
        else
            rootImportsPath("src/native_host.zig", native_host, path);

        if (!wired) {
            try missing.append(gpa, try gpa.dupe(u8, path));
        }
    }

    if (missing.items.len != 0) {
        try stdout.print(
            "{s}[ERR]{s} Found {d} Zig test file(s) not wired through a test root:\n\n",
            .{ TermColor.red, TermColor.reset, missing.items.len },
        );
        for (missing.items) |path| {
            const root = if (std.mem.startsWith(u8, path, "src/signals/"))
                "src/signals/mod.zig"
            else
                "src/native_host.zig";
            const root_dir = std.fs.path.dirname(root) orelse ".";
            const relative = try std.fs.path.relativePosix(gpa, ".", root_dir, path);
            defer gpa.free(relative);
            try stdout.print("  {s}[MISSING]{s} {s}\n", .{ TermColor.red, TermColor.reset, path });
            try stdout.print("    {s}[HINT]{s} Add @import(\"{s}\") to {s}\n", .{
                TermColor.yellow,
                TermColor.reset,
                relative,
                root,
            });
        }
        try stdout.flush();
        std.process.exit(1);
    }

    try stdout.print("{s}[OK]{s} All Zig tests are wired\n", .{ TermColor.green, TermColor.reset });
    try stdout.flush();
}

fn walkTree(allocator: Allocator, io: std.Io, dir_path: []const u8, test_files: *PathList) !void {
    var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind == .sym_link) continue;

        const next_path = try std.fs.path.join(allocator, &.{ dir_path, entry.name });
        switch (entry.kind) {
            .directory => {
                defer allocator.free(next_path);
                try walkTree(allocator, io, next_path, test_files);
            },
            .file => {
                if (std.mem.endsWith(u8, entry.name, ".zig") and try fileHasTestDecl(allocator, io, next_path)) {
                    try test_files.append(allocator, next_path);
                } else {
                    allocator.free(next_path);
                }
            },
            else => allocator.free(next_path),
        }
    }
}

fn fileHasTestDecl(allocator: Allocator, io: std.Io, path: []const u8) !bool {
    const source = try readSourceFile(allocator, io, path);
    defer allocator.free(source);
    return std.mem.startsWith(u8, source, "test ") or
        std.mem.indexOf(u8, source, "\ntest ") != null;
}

fn isExplicitRoot(path: []const u8) bool {
    return std.mem.eql(u8, path, "src/signals/mod.zig") or
        std.mem.eql(u8, path, "src/native_host.zig") or
        std.mem.eql(u8, path, "src/wasm_host.zig");
}

fn rootImportsPath(root_path: []const u8, root_source: []const u8, path: []const u8) bool {
    const root_dir = std.fs.path.dirname(root_path) orelse ".";
    const prefix_len = if (std.mem.eql(u8, root_dir, ".")) 0 else root_dir.len + 1;
    if (path.len <= prefix_len) return false;
    const relative = path[prefix_len..];

    var pattern_buf: [256]u8 = undefined;
    const pattern = std.fmt.bufPrint(&pattern_buf, "@import(\"{s}\")", .{relative}) catch return false;
    return std.mem.indexOf(u8, root_source, pattern) != null;
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
