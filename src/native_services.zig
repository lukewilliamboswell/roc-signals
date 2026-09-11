//! The typed native services behind the hosted `Files` and `Http` functions.
//! Each primitive builds its Roc result directly from plain slices: the Rust
//! host returns C structs for the work that needs its filesystem, dialog, or
//! TLS code, and the spec host answers from declared stubs.
const std = @import("std");
const signals = @import("signals");
const abi = signals.abi;
const file_fixtures = @import("spec/file_fixtures.zig");
const http_fixtures = @import("spec/http_fixtures.zig");

pub const FileStubs = std.ArrayListUnmanaged(file_fixtures.Stub);
pub const HttpStubs = std.ArrayListUnmanaged(http_fixtures.Stub);

/// The assets root the spec host reports; specs key asset stubs under it.
pub const spec_assets_root = "/assets";

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
pub const StatOut = extern struct { kind: u32 = 0, size: u64 = 0, device: u64 = 0, inode: u64 = 0 };
pub const FileEntryOut = extern struct { path: Bytes, bytes: u64, kind: u32 };
pub const FileEntriesOut = extern struct { ptr: ?[*]FileEntryOut = null, len: usize = 0, cap: usize = 0 };
pub const HeaderIn = extern struct { name_ptr: [*]const u8, name_len: usize, value_ptr: [*]const u8, value_len: usize };
pub const HeaderOut = extern struct { name: Bytes, value: Bytes };
pub const HeadersOut = extern struct { ptr: ?[*]HeaderOut = null, len: usize = 0, cap: usize = 0 };
pub const HttpErrorOut = extern struct { kind: u32 = 0, detail: Bytes = .{} };

extern fn signals_bytes_release(bytes: Bytes) callconv(.c) void;
extern fn signals_file_entries_release(entries: FileEntriesOut) callconv(.c) void;
extern fn signals_headers_release(headers: HeadersOut) callconv(.c) void;
extern fn signals_files_stat(path: [*]const u8, path_len: usize, out: *StatOut, err: *FilesErrorOut) callconv(.c) u32;
extern fn signals_files_read_bytes(path: [*]const u8, path_len: usize, offset: u64, max_bytes: u64, out_bytes: *Bytes, out_size: *u64, err: *FilesErrorOut) callconv(.c) u32;
extern fn signals_files_write_bytes(path: [*]const u8, path_len: usize, bytes: [*]const u8, bytes_len: usize, err: *FilesErrorOut) callconv(.c) u32;
extern fn signals_files_rename(from: [*]const u8, from_len: usize, to: [*]const u8, to_len: usize, err: *FilesErrorOut) callconv(.c) u32;
extern fn signals_files_remove(path: [*]const u8, path_len: usize, err: *FilesErrorOut) callconv(.c) u32;
extern fn signals_files_sync(path: [*]const u8, path_len: usize, err: *FilesErrorOut) callconv(.c) u32;
extern fn signals_files_list_directory(path: [*]const u8, path_len: usize, out_path: *Bytes, out_entries: *FileEntriesOut, err: *FilesErrorOut) callconv(.c) u32;
extern fn signals_files_open_path(path: [*]const u8, path_len: usize, err: *FilesErrorOut) callconv(.c) u32;
extern fn signals_files_assets_root(out: *Bytes) callconv(.c) void;
extern fn signals_files_choose(kind: u32, directory: [*]const u8, directory_len: usize, home: u32, name: [*]const u8, name_len: usize, out_path: *Bytes, out_canceled: *u32, err: *FilesErrorOut) callconv(.c) u32;
extern fn signals_http_send(method: [*]const u8, method_len: usize, uri: [*]const u8, uri_len: usize, timeout_ms: u64, headers: [*]const HeaderIn, header_count: usize, body: [*]const u8, body_len: usize, out_status: *u16, out_headers: *HeadersOut, out_body: *Bytes, err: *HttpErrorOut) callconv(.c) u32;

const EntryList = @FieldType(abi.FilesList_directoryOk, "entries");
const EntryElem = abi.FilesList_directoryOkEntries;
const HeaderList = @FieldType(abi.Response, "headers");
const HeaderElem = @typeInfo(@typeInfo(@FieldType(HeaderList, "elements_ptr")).optional.child).pointer.child;
const ByteList = @FieldType(abi.Response, "body");
/// The shared `Try({}, Error)` result of every primitive without a value.
pub const UnitResult = abi.FilesWrite_bytesResult;

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

fn unitOk() UnitResult {
    return .{ .payload = undefined, .tag = .Ok };
}

fn str(roc_host: *abi.RocHost, text: []const u8) abi.RocStr {
    return abi.RocStr.fromSlice(text, roc_host);
}

fn filesError(roc_host: *abi.RocHost, tag: abi.FilesErrorTag, detail: []const u8) abi.FilesError {
    var err: abi.FilesError = .{ .payload = undefined, .tag = tag };
    payloadPtr(abi.RocStr, &err).* = str(roc_host, detail);
    return err;
}

fn filesErrorFromHost(roc_host: *abi.RocHost, err: FilesErrorOut) abi.FilesError {
    defer signals_bytes_release(err.detail);
    const tag: abi.FilesErrorTag = switch (err.kind) {
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

fn kindFromHost(kind: u32) abi.FilesKind {
    return switch (kind) {
        0 => .file,
        1 => .directory,
        2 => .symbolic_link,
        else => .other,
    };
}

fn kindFromStub(kind: file_fixtures.Kind) abi.FilesKind {
    return switch (kind) {
        .file => .file,
        .directory => .directory,
        .symbolic_link => .symbolic_link,
        .other => .other,
    };
}

fn choice(roc_host: *abi.RocHost, path: ?[]const u8) abi.FilesChoice {
    var value: abi.FilesChoice = .{ .payload = undefined, .tag = .Canceled };
    if (path) |chosen| {
        value.tag = .Chosen;
        payloadPtr(abi.RocStr, &value).* = str(roc_host, chosen);
    }
    return value;
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

/// Reads an entry's metadata without following a symbolic link.
pub fn stat(roc_host: *abi.RocHost, path: []const u8) abi.FilesStatResult {
    var out: StatOut = .{};
    var err: FilesErrorOut = .{};
    if (signals_files_stat(path.ptr, path.len, &out, &err) != 0) return tryErr(abi.FilesStatResult, filesErrorFromHost(roc_host, err));
    return tryOk(abi.FilesStatResult, abi.FilesStatOk{ .kind = kindFromHost(out.kind), .bytes = out.size, .device = out.device, .inode = out.inode });
}

/// Reads a bounded byte range of a regular file.
pub fn readBytes(roc_host: *abi.RocHost, path: []const u8, offset: u64, max_bytes: u64) abi.FilesRead_bytesResult {
    var out_bytes: Bytes = .{};
    var size: u64 = 0;
    var err: FilesErrorOut = .{};
    if (signals_files_read_bytes(path.ptr, path.len, offset, max_bytes, &out_bytes, &size, &err) != 0) return tryErr(abi.FilesRead_bytesResult, filesErrorFromHost(roc_host, err));
    defer signals_bytes_release(out_bytes);
    return tryOk(abi.FilesRead_bytesResult, abi.FilesRead_bytesOk{ .bytes = ByteList.fromSlice(out_bytes.slice(), roc_host), .size = size });
}

/// Creates or replaces a regular file.
pub fn writeBytes(roc_host: *abi.RocHost, path: []const u8, bytes: []const u8) UnitResult {
    var err: FilesErrorOut = .{};
    if (signals_files_write_bytes(path.ptr, path.len, bytes.ptr, bytes.len, &err) != 0) return tryErr(UnitResult, filesErrorFromHost(roc_host, err));
    return unitOk();
}

/// Renames an entry, replacing a regular file at the destination.
pub fn rename(roc_host: *abi.RocHost, from: []const u8, to: []const u8) UnitResult {
    var err: FilesErrorOut = .{};
    if (signals_files_rename(from.ptr, from.len, to.ptr, to.len, &err) != 0) return tryErr(UnitResult, filesErrorFromHost(roc_host, err));
    return unitOk();
}

/// Removes a regular file or an empty directory.
pub fn remove(roc_host: *abi.RocHost, path: []const u8) UnitResult {
    var err: FilesErrorOut = .{};
    if (signals_files_remove(path.ptr, path.len, &err) != 0) return tryErr(UnitResult, filesErrorFromHost(roc_host, err));
    return unitOk();
}

/// Flushes a regular file to durable storage.
pub fn sync(roc_host: *abi.RocHost, path: []const u8) UnitResult {
    var err: FilesErrorOut = .{};
    if (signals_files_sync(path.ptr, path.len, &err) != 0) return tryErr(UnitResult, filesErrorFromHost(roc_host, err));
    return unitOk();
}

/// Lists a folder's direct children through the Rust host.
pub fn listDirectory(roc_host: *abi.RocHost, allocator: std.mem.Allocator, path: []const u8) abi.FilesList_directoryResult {
    var out_path: Bytes = .{};
    var entries: FileEntriesOut = .{};
    var err: FilesErrorOut = .{};
    if (signals_files_list_directory(path.ptr, path.len, &out_path, &entries, &err) != 0) return tryErr(abi.FilesList_directoryResult, filesErrorFromHost(roc_host, err));
    defer signals_bytes_release(out_path);
    defer signals_file_entries_release(entries);
    const items = if (entries.ptr) |ptr| ptr[0..entries.len] else &[_]FileEntryOut{};
    const built = allocator.alloc(EntryElem, items.len) catch @panic("out of memory");
    defer allocator.free(built);
    for (items, 0..) |item, index| {
        built[index] = .{ .path = str(roc_host, item.path.slice()), .bytes = item.bytes, .kind = kindFromHost(item.kind) };
    }
    return tryOk(abi.FilesList_directoryResult, abi.FilesList_directoryOk{ .path = str(roc_host, out_path.slice()), .entries = EntryList.fromSlice(built, roc_host) });
}

/// Hands a file to its associated application through the Rust host.
pub fn openPath(roc_host: *abi.RocHost, path: []const u8) UnitResult {
    var err: FilesErrorOut = .{};
    if (signals_files_open_path(path.ptr, path.len, &err) != 0) return tryErr(UnitResult, filesErrorFromHost(roc_host, err));
    return unitOk();
}

/// The folder the Rust host resolves relative asset sources against.
pub fn assetsRoot(roc_host: *abi.RocHost) abi.RocStr {
    var out: Bytes = .{};
    signals_files_assets_root(&out);
    defer signals_bytes_release(out);
    return str(roc_host, out.slice());
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
        .body = ByteList.fromSlice(body.slice(), roc_host),
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

/// Writes succeed by default in the spec host; only a reject stub declared as
/// the next stub fails one.
fn takeLeadingReject(stubs: *FileStubs) ?file_fixtures.Stub {
    if (stubs.items.len == 0 or std.meta.activeTag(stubs.items[0]) != .reject) return null;
    return stubs.orderedRemove(0);
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

/// Answers a metadata lookup from the declared stubs.
pub fn stubStat(allocator: std.mem.Allocator, stubs: *FileStubs, roc_host: *abi.RocHost, path: []const u8) abi.FilesStatResult {
    const stub = takeFileStub(stubs, .stat, path) orelse return missingFileStub(abi.FilesStatResult, roc_host, allocator, "stat", path);
    defer stub.deinit(allocator);
    return switch (stub) {
        .stat => |meta| tryOk(abi.FilesStatResult, abi.FilesStatOk{ .kind = kindFromStub(meta.kind), .bytes = meta.bytes, .device = meta.device, .inode = meta.inode }),
        .reject => |reject| tryErr(abi.FilesStatResult, filesErrorFromStub(roc_host, reject.kind, reject.detail)),
        else => unreachable,
    };
}

/// Answers a byte read from the declared stubs: the bytes a read stub holds
/// from `offset`, bounded by `max_bytes`, and the size it declares.
pub fn stubReadBytes(allocator: std.mem.Allocator, stubs: *FileStubs, roc_host: *abi.RocHost, path: []const u8, offset: u64, max_bytes: u64) abi.FilesRead_bytesResult {
    const stub = takeFileStub(stubs, .read, path) orelse return missingFileStub(abi.FilesRead_bytesResult, roc_host, allocator, "read_bytes", path);
    defer stub.deinit(allocator);
    switch (stub) {
        .read => |read| {
            // A stub declared at an offset holds the bytes from that offset;
            // one declared without holds the whole file.
            const base: u64 = read.offset orelse 0;
            const size: u64 = read.size orelse base + read.bytes.len;
            const skip: usize = @intCast(if (offset > base) offset - base else 0);
            const available = if (skip < read.bytes.len) read.bytes[skip..] else "";
            const taken = available[0..@min(available.len, @as(usize, @intCast(@min(max_bytes, std.math.maxInt(usize)))))];
            return tryOk(abi.FilesRead_bytesResult, abi.FilesRead_bytesOk{ .bytes = ByteList.fromSlice(taken, roc_host), .size = size });
        },
        .reject => |reject| return tryErr(abi.FilesRead_bytesResult, filesErrorFromStub(roc_host, reject.kind, reject.detail)),
        else => unreachable,
    }
}

/// Answers a write, rename, removal, flush, or launch: success unless a
/// reject stub is declared next.
pub fn stubUnit(allocator: std.mem.Allocator, stubs: *FileStubs, roc_host: *abi.RocHost) UnitResult {
    const stub = takeLeadingReject(stubs) orelse return unitOk();
    defer stub.deinit(allocator);
    return switch (stub) {
        .reject => |reject| tryErr(UnitResult, filesErrorFromStub(roc_host, reject.kind, reject.detail)),
        else => unreachable,
    };
}

/// Answers a directory listing from the declared stubs.
pub fn stubListDirectory(allocator: std.mem.Allocator, stubs: *FileStubs, roc_host: *abi.RocHost, path: []const u8) abi.FilesList_directoryResult {
    const stub = takeFileStub(stubs, .directory, path) orelse return missingFileStub(abi.FilesList_directoryResult, roc_host, allocator, "list_directory", path);
    defer stub.deinit(allocator);
    switch (stub) {
        .directory => |directory| {
            const built = allocator.alloc(EntryElem, directory.entries.len) catch @panic("out of memory");
            defer allocator.free(built);
            for (directory.entries, 0..) |entry, index| {
                built[index] = .{ .path = str(roc_host, entry.path), .bytes = entry.bytes, .kind = kindFromStub(entry.kind) };
            }
            return tryOk(abi.FilesList_directoryResult, abi.FilesList_directoryOk{ .path = str(roc_host, directory.path), .entries = EntryList.fromSlice(built, roc_host) });
        },
        .reject => |reject| return tryErr(abi.FilesList_directoryResult, filesErrorFromStub(roc_host, reject.kind, reject.detail)),
        else => unreachable,
    }
}

/// Answers an associated-application launch from the declared stubs.
pub fn stubOpenPath(allocator: std.mem.Allocator, stubs: *FileStubs, roc_host: *abi.RocHost, path: []const u8) UnitResult {
    const stub = takeFileStub(stubs, .open, path) orelse return missingFileStub(UnitResult, roc_host, allocator, "open_path", path);
    defer stub.deinit(allocator);
    return switch (stub) {
        .open => unitOk(),
        .reject => |reject| tryErr(UnitResult, filesErrorFromStub(roc_host, reject.kind, reject.detail)),
        else => unreachable,
    };
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
                .body = ByteList.fromSlice(response.body, roc_host),
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
