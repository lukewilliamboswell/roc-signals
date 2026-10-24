//! The native semantic host's answer to the hosted `Http.send!`: the
//! display-free host never touches the network, so every request is answered
//! from the stubs a spec declared, and the Roc result is built directly from
//! those plain slices.
const std = @import("std");
const signals = @import("signals");
const abi = signals.abi;
const http_fixtures = @import("spec/http_fixtures.zig");

pub const HttpStubs = std.ArrayListUnmanaged(http_fixtures.Stub);

const HeaderList = @FieldType(abi.Response, "headers");
const HeaderElem = @typeInfo(@typeInfo(@FieldType(HeaderList, "elements_ptr")).optional.child).pointer.child;
const ByteList = @FieldType(abi.Response, "body");

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

fn httpError(roc_host: *abi.RocHost, tag: abi.HttpErrorTag, detail: []const u8) abi.HttpError {
    var err: abi.HttpError = .{ .payload = undefined, .tag = tag };
    switch (tag) {
        .InvalidRequest, .Network, .TooLarge, .Unavailable => payloadPtr(abi.RocStr, &err).* = str(roc_host, detail),
        .Status => payloadPtr(u16, &err).* = 0,
        .Timeout, .InvalidUtf8 => {},
    }
    return err;
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
