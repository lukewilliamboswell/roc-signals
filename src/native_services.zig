//! The typed native services behind the hosted `Files` and `Http` functions.
//! Each operation builds its Roc result directly from plain slices: the Rust
//! host returns C structs for the work that needs its filesystem, dialog, or
//! TLS code, and the spec host answers from declared stubs. Nothing crosses
//! either boundary as an encoded packet.
const std = @import("std");
const signals = @import("signals");
const abi = signals.abi;
const file_fixtures = @import("spec/file_fixtures.zig");
const http_fixtures = @import("spec/http_fixtures.zig");

pub const FileStubs = std.ArrayListUnmanaged(file_fixtures.Stub);
pub const HttpStubs = std.ArrayListUnmanaged(http_fixtures.Stub);

// The C ABI shared with the Rust host. Every buffer the host hands back is
// released through the matching `signals_*_release` once it has been copied
// into a Roc value.

pub const Bytes = extern struct {
    ptr: ?[*]u8 = null,
    len: usize = 0,
    cap: usize = 0,

    fn slice(self: Bytes) []const u8 {
        return if (self.ptr) |ptr| ptr[0..self.len] else "";
    }
};
pub const FilesErrorOut = extern struct { kind: u32 = 0, detail: Bytes = .{} };
pub const FileEntryOut = extern struct { path: Bytes, bytes: u64, kind: u32 };
pub const FileEntriesOut = extern struct { ptr: ?[*]FileEntryOut = null, len: usize = 0, cap: usize = 0 };
pub const AssetEntryIn = extern struct { name_ptr: [*]const u8, name_len: usize, sha_ptr: [*]const u8, sha_len: usize };
pub const AssetResultOut = extern struct { name: Bytes, status: u32 };
pub const AssetResultsOut = extern struct { ptr: ?[*]AssetResultOut = null, len: usize = 0, cap: usize = 0 };
pub const LogCursorOut = extern struct { device: u64 = 0, inode: u64 = 0, offset: u64 = 0 };
pub const HeaderIn = extern struct { name_ptr: [*]const u8, name_len: usize, value_ptr: [*]const u8, value_len: usize };
pub const HeaderOut = extern struct { name: Bytes, value: Bytes };
pub const HeadersOut = extern struct { ptr: ?[*]HeaderOut = null, len: usize = 0, cap: usize = 0 };
pub const HttpErrorOut = extern struct { kind: u32 = 0, detail: Bytes = .{} };

extern fn signals_bytes_release(bytes: Bytes) callconv(.c) void;
extern fn signals_file_entries_release(entries: FileEntriesOut) callconv(.c) void;
extern fn signals_asset_results_release(results: AssetResultsOut) callconv(.c) void;
extern fn signals_headers_release(headers: HeadersOut) callconv(.c) void;
extern fn signals_files_read_text(path: [*]const u8, path_len: usize, out_path: *Bytes, out_text: *Bytes, err: *FilesErrorOut) callconv(.c) u32;
extern fn signals_files_write_text(path: [*]const u8, path_len: usize, text: [*]const u8, text_len: usize, out_path: *Bytes, out_bytes: *u64, err: *FilesErrorOut) callconv(.c) u32;
extern fn signals_files_scan(root: [*]const u8, root_len: usize, out_root: *Bytes, out_entries: *FileEntriesOut, err: *FilesErrorOut) callconv(.c) u32;
extern fn signals_files_list_directory(path: [*]const u8, path_len: usize, out_path: *Bytes, out_entries: *FileEntriesOut, err: *FilesErrorOut) callconv(.c) u32;
extern fn signals_files_open_path(path: [*]const u8, path_len: usize, out_path: *Bytes, err: *FilesErrorOut) callconv(.c) u32;
extern fn signals_files_read_preview(path: [*]const u8, path_len: usize, out_path: *Bytes, out_text: *Bytes, out_truncated: *u32, err: *FilesErrorOut) callconv(.c) u32;
extern fn signals_files_read_log(path: [*]const u8, path_len: usize, position: u32, device: u64, inode: u64, offset: u64, out_path: *Bytes, out_text: *Bytes, out_cursor: *LogCursorOut, out_change: *u32, out_state: *u32, err: *FilesErrorOut) callconv(.c) u32;
extern fn signals_files_verify_assets(entries: [*]const AssetEntryIn, count: usize, out: *AssetResultsOut, err: *FilesErrorOut) callconv(.c) u32;
extern fn signals_files_choose(kind: u32, directory: [*]const u8, directory_len: usize, home: u32, name: [*]const u8, name_len: usize, out_path: *Bytes, out_canceled: *u32, err: *FilesErrorOut) callconv(.c) u32;
extern fn signals_http_send(method: [*]const u8, method_len: usize, uri: [*]const u8, uri_len: usize, timeout_ms: u64, headers: [*]const HeaderIn, header_count: usize, body: [*]const u8, body_len: usize, out_status: *u16, out_headers: *HeadersOut, out_body: *Bytes, err: *HttpErrorOut) callconv(.c) u32;

// Building the glue's result values.

const EntryList = @FieldType(abi.FilesScanOk, "entries");
const EntryElem = abi.FilesScanOkEntries;
const AssetList = @FieldType(abi.FilesVerify_assetsResultPayload, "ok");
const AssetElem = abi.FilesVerify_assetsOk;
const HeaderList = @FieldType(abi.Response, "headers");
const HeaderElem = @typeInfo(@typeInfo(@FieldType(HeaderList, "elements_ptr")).optional.child).pointer.child;

/// Every payload of a glue tag union starts at the union's first byte, on
/// both the 64-bit union and the 32-bit byte-array layout.
fn payloadPtr(comptime T: type, holder: anytype) *T {
    return @ptrCast(@alignCast(&holder.payload));
}

fn tryOk(comptime R: type, value: anytype) R {
    var result: R = .{ .payload = undefined, .tag = .Ok };
    payloadPtr(@TypeOf(value), &result).* = value;
    return result;
}

fn tryErr(comptime R: type, err: anytype) R {
    var result: R = .{ .payload = undefined, .tag = .Err };
    payloadPtr(@TypeOf(err), &result).* = err;
    return result;
}

fn str(roc_host: *abi.RocHost, text: []const u8) abi.RocStr {
    return abi.RocStr.fromSlice(text, roc_host);
}

fn filesError(roc_host: *abi.RocHost, tag: abi.FilesErrorTag, detail: []const u8) abi.FilesError {
    var err: abi.FilesError = .{ .payload = undefined, .tag = tag };
    if (tag != .Canceled) payloadPtr(abi.RocStr, &err).* = str(roc_host, detail);
    return err;
}

fn filesErrorFromHost(roc_host: *abi.RocHost, err: FilesErrorOut) abi.FilesError {
    defer signals_bytes_release(err.detail);
    const tag: abi.FilesErrorTag = switch (err.kind) {
        0 => .Canceled,
        1 => .NotFound,
        2 => .PermissionDenied,
        3 => .InvalidUtf8,
        4 => .InvalidPath,
        5 => .ResourceLimit,
        6 => .Io,
        else => .Unavailable,
    };
    return filesError(roc_host, tag, err.detail.slice());
}

fn filesErrorFromStub(roc_host: *abi.RocHost, kind: file_fixtures.ErrorKind, detail: []const u8) abi.FilesError {
    const tag: abi.FilesErrorTag = switch (kind) {
        .canceled => .Canceled,
        .not_found => .NotFound,
        .permission_denied => .PermissionDenied,
        .invalid_utf8 => .InvalidUtf8,
        .invalid_path => .InvalidPath,
        .resource_limit => .ResourceLimit,
        .io => .Io,
        .unavailable => .Unavailable,
    };
    return filesError(roc_host, tag, detail);
}

fn entryKindFromHost(kind: u32) abi.FilesKind {
    return switch (kind) {
        0 => .file,
        1 => .directory,
        2 => .symbolic_link,
        else => .other,
    };
}

fn entryKindFromStub(kind: file_fixtures.Kind) abi.FilesKind {
    return switch (kind) {
        .file => .file,
        .directory => .directory,
        .symbolic_link => .symbolic_link,
        .other => .other,
    };
}

fn entriesFromHost(roc_host: *abi.RocHost, allocator: std.mem.Allocator, entries: FileEntriesOut) EntryList {
    const items = if (entries.ptr) |ptr| ptr[0..entries.len] else &[_]FileEntryOut{};
    const built = allocator.alloc(EntryElem, items.len) catch @panic("out of memory");
    defer allocator.free(built);
    for (items, 0..) |item, index| {
        built[index] = .{ .path = str(roc_host, item.path.slice()), .bytes = item.bytes, .kind = entryKindFromHost(item.kind) };
    }
    return EntryList.fromSlice(built, roc_host);
}

fn entriesFromStub(roc_host: *abi.RocHost, allocator: std.mem.Allocator, entries: []const file_fixtures.Entry) EntryList {
    const built = allocator.alloc(EntryElem, entries.len) catch @panic("out of memory");
    defer allocator.free(built);
    for (entries, 0..) |entry, index| {
        built[index] = .{ .path = str(roc_host, entry.path), .bytes = entry.bytes, .kind = entryKindFromStub(entry.kind) };
    }
    return EntryList.fromSlice(built, roc_host);
}

// Live operations: the Rust host does the work and hands back C structs.

pub const ChooserKind = enum(u32) { file = 0, directory = 1, save_path = 2 };

/// Shows a native chooser through the Rust host and waits for the user's answer.
pub fn choose(roc_host: *abi.RocHost, kind: ChooserKind, directory: []const u8, home: bool, suggested_name: []const u8) abi.FilesChoose_fileResult {
    var out_path: Bytes = .{};
    var canceled: u32 = 0;
    var err: FilesErrorOut = .{};
    if (signals_files_choose(@intFromEnum(kind), directory.ptr, directory.len, @intFromBool(home), suggested_name.ptr, suggested_name.len, &out_path, &canceled, &err) != 0) {
        return tryErr(abi.FilesChoose_fileResult, filesErrorFromHost(roc_host, err));
    }
    defer signals_bytes_release(out_path);
    return tryOk(abi.FilesChoose_fileResult, choice(roc_host, if (canceled != 0) null else out_path.slice()));
}

fn choice(roc_host: *abi.RocHost, path: ?[]const u8) abi.FilesChoice {
    var value: abi.FilesChoice = .{ .payload = undefined, .tag = .Canceled };
    if (path) |chosen| {
        value.tag = .Chosen;
        payloadPtr(abi.RocStr, &value).* = str(roc_host, chosen);
    }
    return value;
}

/// Reads a complete UTF-8 file through the Rust host.
pub fn readText(roc_host: *abi.RocHost, path: []const u8) abi.FilesRead_textResult {
    var out_path: Bytes = .{};
    var out_text: Bytes = .{};
    var err: FilesErrorOut = .{};
    if (signals_files_read_text(path.ptr, path.len, &out_path, &out_text, &err) != 0) return tryErr(abi.FilesRead_textResult, filesErrorFromHost(roc_host, err));
    defer signals_bytes_release(out_path);
    defer signals_bytes_release(out_text);
    return tryOk(abi.FilesRead_textResult, abi.FilesRead_textOk{ .path = str(roc_host, out_path.slice()), .text = str(roc_host, out_text.slice()) });
}

/// Writes text atomically through the Rust host.
pub fn writeText(roc_host: *abi.RocHost, path: []const u8, text: []const u8) abi.FilesWrite_textResult {
    var out_path: Bytes = .{};
    var bytes: u64 = 0;
    var err: FilesErrorOut = .{};
    if (signals_files_write_text(path.ptr, path.len, text.ptr, text.len, &out_path, &bytes, &err) != 0) return tryErr(abi.FilesWrite_textResult, filesErrorFromHost(roc_host, err));
    defer signals_bytes_release(out_path);
    return tryOk(abi.FilesWrite_textResult, abi.FilesWrite_textOk{ .path = str(roc_host, out_path.slice()), .bytes = bytes });
}

/// Scans a folder recursively through the Rust host.
pub fn scan(roc_host: *abi.RocHost, allocator: std.mem.Allocator, root: []const u8) abi.FilesScanResult {
    var out_root: Bytes = .{};
    var entries: FileEntriesOut = .{};
    var err: FilesErrorOut = .{};
    if (signals_files_scan(root.ptr, root.len, &out_root, &entries, &err) != 0) return tryErr(abi.FilesScanResult, filesErrorFromHost(roc_host, err));
    defer signals_bytes_release(out_root);
    defer signals_file_entries_release(entries);
    return tryOk(abi.FilesScanResult, abi.FilesScanOk{ .root = str(roc_host, out_root.slice()), .entries = entriesFromHost(roc_host, allocator, entries) });
}

/// Lists a folder's direct children through the Rust host.
pub fn listDirectory(roc_host: *abi.RocHost, allocator: std.mem.Allocator, path: []const u8) abi.FilesList_directoryResult {
    var out_path: Bytes = .{};
    var entries: FileEntriesOut = .{};
    var err: FilesErrorOut = .{};
    if (signals_files_list_directory(path.ptr, path.len, &out_path, &entries, &err) != 0) return tryErr(abi.FilesList_directoryResult, filesErrorFromHost(roc_host, err));
    defer signals_bytes_release(out_path);
    defer signals_file_entries_release(entries);
    return tryOk(abi.FilesList_directoryResult, abi.FilesList_directoryOk{ .path = str(roc_host, out_path.slice()), .entries = entriesFromHost(roc_host, allocator, entries) });
}

/// Hands a file to its associated application through the Rust host.
pub fn openPath(roc_host: *abi.RocHost, path: []const u8) abi.FilesOpen_pathResult {
    var out_path: Bytes = .{};
    var err: FilesErrorOut = .{};
    if (signals_files_open_path(path.ptr, path.len, &out_path, &err) != 0) return tryErr(abi.FilesOpen_pathResult, filesErrorFromHost(roc_host, err));
    defer signals_bytes_release(out_path);
    return tryOk(abi.FilesOpen_pathResult, abi.FilesOpen_pathOk{ .path = str(roc_host, out_path.slice()) });
}

/// Reads a bounded text preview through the Rust host.
pub fn readPreview(roc_host: *abi.RocHost, path: []const u8) abi.FilesRead_previewResult {
    var out_path: Bytes = .{};
    var out_text: Bytes = .{};
    var truncated: u32 = 0;
    var err: FilesErrorOut = .{};
    if (signals_files_read_preview(path.ptr, path.len, &out_path, &out_text, &truncated, &err) != 0) return tryErr(abi.FilesRead_previewResult, filesErrorFromHost(roc_host, err));
    defer signals_bytes_release(out_path);
    defer signals_bytes_release(out_text);
    return tryOk(abi.FilesRead_previewResult, abi.FilesRead_previewOk{ .path = str(roc_host, out_path.slice()), .text = str(roc_host, out_text.slice()), .truncated = truncated != 0 });
}

/// Reads the next log chunk from a position through the Rust host.
pub fn readLog(roc_host: *abi.RocHost, path: []const u8, position: abi.FilesLogPosition) abi.FilesRead_logResult {
    var position_kind: u32 = 0;
    var cursor: abi.FilesRead_logOkCursor = .{ .device = 0, .inode = 0, .offset = 0 };
    switch (position.tag) {
        .Start => position_kind = 0,
        .End => position_kind = 1,
        .After => {
            position_kind = 2;
            var holder = position;
            cursor = payloadPtr(abi.FilesRead_logOkCursor, &holder).*;
        },
    }
    var out_path: Bytes = .{};
    var out_text: Bytes = .{};
    var out_cursor: LogCursorOut = .{};
    var change: u32 = 0;
    var state: u32 = 0;
    var err: FilesErrorOut = .{};
    if (signals_files_read_log(path.ptr, path.len, position_kind, cursor.device, cursor.inode, cursor.offset, &out_path, &out_text, &out_cursor, &change, &state, &err) != 0) {
        return tryErr(abi.FilesRead_logResult, filesErrorFromHost(roc_host, err));
    }
    defer signals_bytes_release(out_path);
    defer signals_bytes_release(out_text);
    return tryOk(abi.FilesRead_logResult, abi.FilesRead_logOk{
        .path = str(roc_host, out_path.slice()),
        .text = str(roc_host, out_text.slice()),
        .cursor = .{ .device = out_cursor.device, .inode = out_cursor.inode, .offset = out_cursor.offset },
        .change = switch (change) {
            0 => .initial,
            1 => .continued,
            2 => .rotated,
            else => .truncated,
        },
        .state = switch (state) {
            0 => .more,
            1 => .at_end,
            else => .partial_utf8,
        },
    });
}

pub const AssetEntry = struct { name: []const u8, sha256: []const u8 };

/// Verifies an asset manifest against the assets root through the Rust host.
pub fn verifyAssets(roc_host: *abi.RocHost, allocator: std.mem.Allocator, entries: []const AssetEntry) abi.FilesVerify_assetsResult {
    const inputs = allocator.alloc(AssetEntryIn, entries.len) catch @panic("out of memory");
    defer allocator.free(inputs);
    for (entries, 0..) |entry, index| {
        inputs[index] = .{ .name_ptr = entry.name.ptr, .name_len = entry.name.len, .sha_ptr = entry.sha256.ptr, .sha_len = entry.sha256.len };
    }
    var results: AssetResultsOut = .{};
    var err: FilesErrorOut = .{};
    if (signals_files_verify_assets(inputs.ptr, inputs.len, &results, &err) != 0) return tryErr(abi.FilesVerify_assetsResult, filesErrorFromHost(roc_host, err));
    defer signals_asset_results_release(results);
    const items = if (results.ptr) |ptr| ptr[0..results.len] else &[_]AssetResultOut{};
    const built = allocator.alloc(AssetElem, items.len) catch @panic("out of memory");
    defer allocator.free(built);
    for (items, 0..) |item, index| {
        built[index] = .{ .name = str(roc_host, item.name.slice()), .status = switch (item.status) {
            0 => .ok,
            1 => .missing,
            else => .mismatch,
        } };
    }
    return tryOk(abi.FilesVerify_assetsResult, AssetList.fromSlice(built, roc_host));
}

pub const HttpRequest = struct {
    method: []const u8,
    uri: []const u8,
    /// `null` waits as long as the server does.
    timeout_ms: ?u64,
    headers: []const HeaderIn,
    body: []const u8,
};

/// Performs one HTTP request through the Rust host.
pub fn httpSend(roc_host: *abi.RocHost, allocator: std.mem.Allocator, request: HttpRequest) abi.HttpSendResult {
    var status: u16 = 0;
    var headers: HeadersOut = .{};
    var body: Bytes = .{};
    var err: HttpErrorOut = .{};
    const timeout = request.timeout_ms orelse std.math.maxInt(u64);
    if (signals_http_send(request.method.ptr, request.method.len, request.uri.ptr, request.uri.len, timeout, request.headers.ptr, request.headers.len, request.body.ptr, request.body.len, &status, &headers, &body, &err) != 0) {
        defer signals_bytes_release(err.detail);
        const tag: abi.HttpErrorTag = switch (err.kind) {
            0 => .InvalidRequest,
            1 => .Network,
            2 => .Timeout,
            3 => .TooLarge,
            else => .Unavailable,
        };
        return tryErr(abi.HttpSendResult, httpError(roc_host, tag, err.detail.slice()));
    }
    defer signals_headers_release(headers);
    defer signals_bytes_release(body);
    const items = if (headers.ptr) |ptr| ptr[0..headers.len] else &[_]HeaderOut{};
    const built = allocator.alloc(HeaderElem, items.len) catch @panic("out of memory");
    defer allocator.free(built);
    for (items, 0..) |item, index| {
        built[index] = .{ ._0 = str(roc_host, item.name.slice()), ._1 = str(roc_host, item.value.slice()) };
    }
    return tryOk(abi.HttpSendResult, abi.Response{
        .status = status,
        .headers = HeaderList.fromSlice(built, roc_host),
        .body = @FieldType(abi.Response, "body").fromSlice(body.slice(), roc_host),
    });
}

fn httpError(roc_host: *abi.RocHost, tag: abi.HttpErrorTag, detail: []const u8) abi.HttpError {
    var err: abi.HttpError = .{ .payload = undefined, .tag = tag };
    switch (tag) {
        .InvalidRequest, .Network, .TooLarge, .Unavailable => payloadPtr(abi.RocStr, &err).* = str(roc_host, detail),
        .Status => payloadPtr(u16, &err).* = 0,
        .Timeout, .InvalidUtf8 => {},
    }
    return err;
}

// Spec answers: the display-free host consumes declared stubs instead of
// touching the filesystem or the network.

const StubTag = std.meta.Tag(file_fixtures.Stub);

/// Removes the first stub of the wanted operation whose key matches, or the
/// first reject stub, which answers any operation.
fn takeFileStub(stubs: *FileStubs, want: StubTag, key: ?[]const u8) ?file_fixtures.Stub {
    for (stubs.items, 0..) |stub, index| {
        const tag = std.meta.activeTag(stub);
        const matches = if (tag == .reject) true else if (tag != want) false else if (key) |wanted| (if (stub.key()) |own| std.mem.eql(u8, own, wanted) else true) else true;
        if (matches) return stubs.orderedRemove(index);
    }
    return null;
}

fn missingFileStub(comptime R: type, roc_host: *abi.RocHost, allocator: std.mem.Allocator, operation: []const u8, key: []const u8) R {
    const message = std.fmt.allocPrint(allocator, "no spec stub for {s} {s}", .{ operation, key }) catch @panic("out of memory");
    defer allocator.free(message);
    return tryErr(R, filesError(roc_host, .Unavailable, message));
}

/// Answers a chooser from the declared stubs.
pub fn stubChoose(allocator: std.mem.Allocator, stubs: *FileStubs, roc_host: *abi.RocHost, operation: []const u8) abi.FilesChoose_fileResult {
    const stub = takeFileStub(stubs, .choice, null) orelse return missingFileStub(abi.FilesChoose_fileResult, roc_host, allocator, operation, "");
    defer stub.deinit(allocator);
    return switch (stub) {
        .choice => |path| tryOk(abi.FilesChoose_fileResult, choice(roc_host, path)),
        .reject => |reject| tryErr(abi.FilesChoose_fileResult, filesErrorFromStub(roc_host, reject.kind, reject.detail)),
        else => unreachable,
    };
}

/// Answers a text read from the declared stubs.
pub fn stubReadText(allocator: std.mem.Allocator, stubs: *FileStubs, roc_host: *abi.RocHost, path: []const u8) abi.FilesRead_textResult {
    const stub = takeFileStub(stubs, .read, path) orelse return missingFileStub(abi.FilesRead_textResult, roc_host, allocator, "read_text", path);
    defer stub.deinit(allocator);
    return switch (stub) {
        .read => |read| tryOk(abi.FilesRead_textResult, abi.FilesRead_textOk{ .path = str(roc_host, read.path), .text = str(roc_host, read.text) }),
        .reject => |reject| tryErr(abi.FilesRead_textResult, filesErrorFromStub(roc_host, reject.kind, reject.detail)),
        else => unreachable,
    };
}

/// Answers a text write from the declared stubs.
pub fn stubWriteText(allocator: std.mem.Allocator, stubs: *FileStubs, roc_host: *abi.RocHost, path: []const u8) abi.FilesWrite_textResult {
    const stub = takeFileStub(stubs, .write, path) orelse return missingFileStub(abi.FilesWrite_textResult, roc_host, allocator, "write_text", path);
    defer stub.deinit(allocator);
    return switch (stub) {
        .write => |write| tryOk(abi.FilesWrite_textResult, abi.FilesWrite_textOk{ .path = str(roc_host, write.path), .bytes = write.bytes }),
        .reject => |reject| tryErr(abi.FilesWrite_textResult, filesErrorFromStub(roc_host, reject.kind, reject.detail)),
        else => unreachable,
    };
}

/// Answers a recursive scan from the declared stubs; only a reject can answer it.
pub fn stubScan(allocator: std.mem.Allocator, stubs: *FileStubs, roc_host: *abi.RocHost, root: []const u8) abi.FilesScanResult {
    // Directory stubs describe direct children; a recursive scan is never stubbed.
    const stub = takeFileStub(stubs, .reject, root) orelse return missingFileStub(abi.FilesScanResult, roc_host, allocator, "scan_directory", root);
    defer stub.deinit(allocator);
    return switch (stub) {
        .reject => |reject| tryErr(abi.FilesScanResult, filesErrorFromStub(roc_host, reject.kind, reject.detail)),
        else => unreachable,
    };
}

/// Answers a directory listing from the declared stubs.
pub fn stubListDirectory(allocator: std.mem.Allocator, stubs: *FileStubs, roc_host: *abi.RocHost, path: []const u8) abi.FilesList_directoryResult {
    const stub = takeFileStub(stubs, .directory, path) orelse return missingFileStub(abi.FilesList_directoryResult, roc_host, allocator, "list_directory", path);
    defer stub.deinit(allocator);
    return switch (stub) {
        .directory => |directory| tryOk(abi.FilesList_directoryResult, abi.FilesList_directoryOk{ .path = str(roc_host, directory.path), .entries = entriesFromStub(roc_host, allocator, directory.entries) }),
        .reject => |reject| tryErr(abi.FilesList_directoryResult, filesErrorFromStub(roc_host, reject.kind, reject.detail)),
        else => unreachable,
    };
}

/// Answers an associated-application launch from the declared stubs.
pub fn stubOpenPath(allocator: std.mem.Allocator, stubs: *FileStubs, roc_host: *abi.RocHost, path: []const u8) abi.FilesOpen_pathResult {
    const stub = takeFileStub(stubs, .open, path) orelse return missingFileStub(abi.FilesOpen_pathResult, roc_host, allocator, "open_path", path);
    defer stub.deinit(allocator);
    return switch (stub) {
        .open => |opened| tryOk(abi.FilesOpen_pathResult, abi.FilesOpen_pathOk{ .path = str(roc_host, opened) }),
        .reject => |reject| tryErr(abi.FilesOpen_pathResult, filesErrorFromStub(roc_host, reject.kind, reject.detail)),
        else => unreachable,
    };
}

/// Answers a preview read from the declared stubs.
pub fn stubReadPreview(allocator: std.mem.Allocator, stubs: *FileStubs, roc_host: *abi.RocHost, path: []const u8) abi.FilesRead_previewResult {
    const stub = takeFileStub(stubs, .preview, path) orelse return missingFileStub(abi.FilesRead_previewResult, roc_host, allocator, "read_preview", path);
    defer stub.deinit(allocator);
    return switch (stub) {
        .preview => |preview| tryOk(abi.FilesRead_previewResult, abi.FilesRead_previewOk{ .path = str(roc_host, preview.path), .text = str(roc_host, preview.text), .truncated = preview.truncated }),
        .reject => |reject| tryErr(abi.FilesRead_previewResult, filesErrorFromStub(roc_host, reject.kind, reject.detail)),
        else => unreachable,
    };
}

/// Answers a log read from the declared stubs.
pub fn stubReadLog(allocator: std.mem.Allocator, stubs: *FileStubs, roc_host: *abi.RocHost, path: []const u8) abi.FilesRead_logResult {
    const stub = takeFileStub(stubs, .log, path) orelse return missingFileStub(abi.FilesRead_logResult, roc_host, allocator, "read_log", path);
    defer stub.deinit(allocator);
    return switch (stub) {
        .log => |log| tryOk(abi.FilesRead_logResult, abi.FilesRead_logOk{
            .path = str(roc_host, log.path),
            .text = str(roc_host, log.text),
            .cursor = .{ .device = log.device, .inode = log.inode, .offset = log.offset },
            .change = switch (log.change) {
                .initial => .initial,
                .continued => .continued,
                .rotated => .rotated,
                .truncated => .truncated,
            },
            .state = switch (log.state) {
                .more => .more,
                .at_end => .at_end,
                .partial_utf8 => .partial_utf8,
            },
        }),
        .reject => |reject| tryErr(abi.FilesRead_logResult, filesErrorFromStub(roc_host, reject.kind, reject.detail)),
        else => unreachable,
    };
}

/// Answers an asset verification from the declared stubs.
pub fn stubVerifyAssets(allocator: std.mem.Allocator, stubs: *FileStubs, roc_host: *abi.RocHost) abi.FilesVerify_assetsResult {
    const stub = takeFileStub(stubs, .assets, null) orelse return missingFileStub(abi.FilesVerify_assetsResult, roc_host, allocator, "verify_assets", "");
    defer stub.deinit(allocator);
    switch (stub) {
        .assets => |checks| {
            const built = allocator.alloc(AssetElem, checks.len) catch @panic("out of memory");
            defer allocator.free(built);
            for (checks, 0..) |check, index| {
                built[index] = .{ .name = str(roc_host, check.name), .status = switch (check.status) {
                    .ok => .ok,
                    .missing => .missing,
                    .mismatch => .mismatch,
                } };
            }
            return tryOk(abi.FilesVerify_assetsResult, AssetList.fromSlice(built, roc_host));
        },
        .reject => |reject| return tryErr(abi.FilesVerify_assetsResult, filesErrorFromStub(roc_host, reject.kind, reject.detail)),
        else => unreachable,
    }
}

/// Answers an HTTP request from the declared stubs, matched by URI.
pub fn stubHttpSend(allocator: std.mem.Allocator, stubs: *HttpStubs, roc_host: *abi.RocHost, uri: []const u8) abi.HttpSendResult {
    var taken: ?http_fixtures.Stub = null;
    for (stubs.items, 0..) |stub, index| {
        const matches = switch (stub) {
            .reject => true,
            .response => |response| std.mem.eql(u8, response.uri, uri),
        };
        if (matches) {
            taken = stubs.orderedRemove(index);
            break;
        }
    }
    const stub = taken orelse {
        const message = std.fmt.allocPrint(allocator, "no spec stub for {s}", .{uri}) catch @panic("out of memory");
        defer allocator.free(message);
        return tryErr(abi.HttpSendResult, httpError(roc_host, .Unavailable, message));
    };
    defer stub.deinit(allocator);
    switch (stub) {
        .response => |response| {
            const built = allocator.alloc(HeaderElem, response.headers.len) catch @panic("out of memory");
            defer allocator.free(built);
            for (response.headers, 0..) |header, index| {
                built[index] = .{ ._0 = str(roc_host, header.name), ._1 = str(roc_host, header.value) };
            }
            return tryOk(abi.HttpSendResult, abi.Response{
                .status = response.status,
                .headers = HeaderList.fromSlice(built, roc_host),
                .body = @FieldType(abi.Response, "body").fromSlice(response.body, roc_host),
            });
        },
        .reject => |reject| {
            const tag: abi.HttpErrorTag = switch (reject.kind) {
                .invalid_request => .InvalidRequest,
                .network => .Network,
                .timeout => .Timeout,
                .too_large => .TooLarge,
                .unavailable => .Unavailable,
            };
            return tryErr(abi.HttpSendResult, httpError(roc_host, tag, reject.detail));
        },
    }
}
