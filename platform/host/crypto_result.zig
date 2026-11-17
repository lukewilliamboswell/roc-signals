//! The native crypto hosted result, checked field by field against roc glue.
//! Regenerate crypto_abi.zig from platform/crypto-abi.roc after changing Cli's
//! seam; contributing.md gives the command. Never infer a record's order from
//! its source spelling: the compiler places random_used before both lists.
const std = @import("std");
const abi = @import("crypto_abi.zig");

/// Bind the host's owned-list representation to the compiler's committed
/// crypto return layout. Both returned lists transfer one reference to Roc.
pub fn Result(comptime List: type) type {
    const Answer = extern struct {
        random_used: u64,
        keys: List,
        payload: List,
    };
    comptime {
        const Generated = abi.CliCryptoRetRecord;
        if (@sizeOf(Answer) != @sizeOf(Generated) or @alignOf(Answer) != @alignOf(Generated)) @compileError("crypto return record layout differs from roc glue");
        const actual = @typeInfo(Answer).@"struct";
        const expected = @typeInfo(Generated).@"struct";
        if (actual.field_names.len != expected.field_names.len) @compileError("crypto return fields differ from roc glue");
        for (actual.field_names, expected.field_names, actual.field_types, expected.field_types) |field, generated, Field, Expected| {
            if (!std.mem.eql(u8, field, generated)) @compileError("crypto return field order differs from roc glue");
            if (@offsetOf(Answer, field) != @offsetOf(Generated, generated)) @compileError("crypto return field offset differs from roc glue");
            if (@sizeOf(Field) != @sizeOf(Expected) or @alignOf(Field) != @alignOf(Expected)) @compileError("crypto return field type layout differs from roc glue");
        }
        if (@FieldType(Answer, "random_used") != @FieldType(Generated, "random_used")) @compileError("crypto entropy count type differs from roc glue");
    }
    return Answer;
}

// Instantiate the check at either pointer width even when this file is built
// alone, so the freestanding compile probe needs no native operating system.
comptime {
    const ProbeList = extern struct { elements: ?*anyopaque, length: usize, capacity_or_alloc_ptr: usize };
    _ = @sizeOf(Result(ProbeList));
}
