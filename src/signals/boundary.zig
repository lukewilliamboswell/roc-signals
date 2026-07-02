//! Shared host-boundary payload schemas and event extraction descriptors.

const std = @import("std");

/// Host boundary payload kind ids. These are the ABI-level containers that cross
/// from JS/native into the retained Roc reducer; richer schemas may still encode
/// through bytes when Roc owns the final typed decoding.
pub const PayloadKind = enum(u64) {
    unit = 1,
    str = 2,
    bool = 3,
    bytes = 4,
};

/// Shared boundary payload schema tags. These bytes describe the value shape
/// that crosses a host boundary; individual producers such as DOM events add
/// their own extraction data after scalar schema tags.
pub const SchemaTag = struct {
    pub const unit: u8 = 1;
    pub const text: u8 = 2;
    pub const bool_: u8 = 3;
    pub const record: u8 = 4;

    pub const unit_schema = [_]u8{unit};
    pub const text_schema = [_]u8{text};
    pub const bool_schema = [_]u8{bool_};
    pub const key_shift_schema = [_]u8{
        record,
        2,
        3,
        'k',
        'e',
        'y',
        text,
        9,
        's',
        'h',
        'i',
        'f',
        't',
        '_',
        'k',
        'e',
        'y',
        bool_,
    };
};

/// DOM-specific extraction plan leaves. A scalar payload-shape node is followed
/// by one source byte and one leaf byte telling JS what to read from the browser
/// event before encoding the resulting boundary payload.
pub const DomEventExtractionPlan = struct {
    pub const source_event: u8 = 1;
    pub const source_target: u8 = 2;
    pub const source_current_target: u8 = 3;

    pub const leaf_key: u8 = 1;
    pub const leaf_value: u8 = 2;
    pub const leaf_checked: u8 = 3;
    pub const leaf_shift_key: u8 = 4;

    pub const target_value = [_]u8{
        SchemaTag.text,
        source_current_target,
        leaf_value,
    };

    pub const target_checked = [_]u8{
        SchemaTag.bool_,
        source_current_target,
        leaf_checked,
    };

    pub const key_shift = [_]u8{
        SchemaTag.record,
        2,
        3,
        'k',
        'e',
        'y',
        SchemaTag.text,
        source_event,
        leaf_key,
        9,
        's',
        'h',
        'i',
        'f',
        't',
        '_',
        'k',
        'e',
        'y',
        SchemaTag.bool_,
        source_event,
        leaf_shift_key,
    };
};

/// Compact ids used by the current Roc ABI. They name a DOM extraction plan,
/// while the actual command wire carries the expanded extraction plan bytes above.
pub const EventExtractionPlanKind = enum(u64) {
    none = 1,
    target_value = 2,
    target_checked = 3,
    record_key_shift = 4,

    pub fn payloadKind(self: EventExtractionPlanKind) PayloadKind {
        return switch (self) {
            .none => .unit,
            .target_value => .str,
            .target_checked => .bool,
            .record_key_shift => .bytes,
        };
    }

    pub fn bytes(self: EventExtractionPlanKind) []const u8 {
        return switch (self) {
            .none => &SchemaTag.unit_schema,
            .target_value => &DomEventExtractionPlan.target_value,
            .target_checked => &DomEventExtractionPlan.target_checked,
            .record_key_shift => &DomEventExtractionPlan.key_shift,
        };
    }

    pub fn schemaBytes(self: EventExtractionPlanKind) []const u8 {
        return switch (self) {
            .none => &SchemaTag.unit_schema,
            .target_value => &SchemaTag.text_schema,
            .target_checked => &SchemaTag.bool_schema,
            .record_key_shift => &SchemaTag.key_shift_schema,
        };
    }
};

pub const BoundaryPayloadDescriptor = struct {
    payload_kind: PayloadKind,
    extraction_plan: EventExtractionPlanKind,

    pub fn init(payload_kind: PayloadKind, extraction_plan: EventExtractionPlanKind) BoundaryPayloadDescriptor {
        validateBoundaryPayloadDescriptor(payload_kind, extraction_plan);
        return .{
            .payload_kind = payload_kind,
            .extraction_plan = extraction_plan,
        };
    }

    pub fn payloadKind(self: BoundaryPayloadDescriptor) PayloadKind {
        return self.payload_kind;
    }

    pub fn extractionPlan(self: BoundaryPayloadDescriptor) EventExtractionPlanKind {
        return self.extraction_plan;
    }

    pub fn schemaBytes(self: BoundaryPayloadDescriptor) []const u8 {
        return self.extraction_plan.schemaBytes();
    }

    pub fn extractionBytes(self: BoundaryPayloadDescriptor) []const u8 {
        return self.extraction_plan.bytes();
    }

    pub fn eql(self: BoundaryPayloadDescriptor, other: BoundaryPayloadDescriptor) bool {
        return self.payload_kind == other.payload_kind and self.extraction_plan == other.extraction_plan;
    }
};

pub fn boundaryPayloadDescriptorEql(left: ?BoundaryPayloadDescriptor, right: ?BoundaryPayloadDescriptor) bool {
    if (left) |left_value| {
        const right_value = right orelse return false;
        return left_value.eql(right_value);
    }
    return right == null;
}

pub const ParseError = error{
    Truncated,
    TrailingBytes,
    UnknownSchemaTag,
    EmptyRecord,
    EmptyRecordFieldName,
    InvalidRecordFieldNameUtf8,
    DuplicateRecordFieldName,
    NestedRecordField,
    UnknownEventExtractionSource,
    IncompatibleEventExtractionLeaf,
    IncompatibleEventExtractionSource,
    UnsupportedEventExtractionPlan,
};

const Cursor = struct {
    bytes: []const u8,
    offset: usize = 0,

    fn readByte(self: *Cursor) ParseError!u8 {
        if (self.offset >= self.bytes.len) return error.Truncated;
        const value = self.bytes[self.offset];
        self.offset += 1;
        return value;
    }

    fn readBytes(self: *Cursor, len: usize) ParseError![]const u8 {
        if (len > self.bytes.len - self.offset) return error.Truncated;
        const start = self.offset;
        self.offset += len;
        return self.bytes[start..self.offset];
    }

    fn requireDone(self: *const Cursor) ParseError!void {
        if (self.offset != self.bytes.len) return error.TrailingBytes;
    }
};

fn parseBoundaryRecord(cursor: *Cursor, comptime parseNode: fn (*Cursor) ParseError!PayloadKind) ParseError!PayloadKind {
    const field_count = try cursor.readByte();
    if (field_count == 0) return error.EmptyRecord;

    var field_names: [256][]const u8 = undefined;
    var parsed_fields: usize = 0;

    while (parsed_fields < field_count) : (parsed_fields += 1) {
        const name_len = try cursor.readByte();
        if (name_len == 0) return error.EmptyRecordFieldName;

        const name = try cursor.readBytes(name_len);
        if (!std.unicode.utf8ValidateSlice(name)) return error.InvalidRecordFieldNameUtf8;
        for (field_names[0..parsed_fields]) |existing| {
            if (std.mem.eql(u8, existing, name)) return error.DuplicateRecordFieldName;
        }
        field_names[parsed_fields] = name;

        const field_kind = try parseNode(cursor);
        if (field_kind == .bytes) return error.NestedRecordField;
    }

    return .bytes;
}

pub fn parseEventExtractionPayloadKind(extraction_bytes: []const u8) ParseError!PayloadKind {
    var cursor = Cursor{ .bytes = extraction_bytes };
    const payload_kind = try parseEventExtractionNode(&cursor);
    try cursor.requireDone();
    return payload_kind;
}

fn parseEventExtractionNode(cursor: *Cursor) ParseError!PayloadKind {
    const tag = try cursor.readByte();
    return switch (tag) {
        SchemaTag.unit => .unit,
        SchemaTag.text => blk: {
            try parseEventScalarExtraction(cursor, .str);
            break :blk .str;
        },
        SchemaTag.bool_ => blk: {
            try parseEventScalarExtraction(cursor, .bool);
            break :blk .bool;
        },
        SchemaTag.record => try parseBoundaryRecord(cursor, parseEventExtractionNode),
        else => error.UnknownSchemaTag,
    };
}

fn parseEventScalarExtraction(cursor: *Cursor, payload_kind: PayloadKind) ParseError!void {
    const source = try cursor.readByte();
    const leaf = try cursor.readByte();
    try validateEventExtractionSource(source);
    try validateEventExtractionLeaf(payload_kind, leaf);
    try validateEventExtractionSourceLeaf(source, leaf);
}

fn validateEventExtractionSource(source: u8) ParseError!void {
    switch (source) {
        DomEventExtractionPlan.source_event,
        DomEventExtractionPlan.source_target,
        DomEventExtractionPlan.source_current_target,
        => return,
        else => return error.UnknownEventExtractionSource,
    }
}

fn validateEventExtractionLeaf(payload_kind: PayloadKind, leaf: u8) ParseError!void {
    switch (payload_kind) {
        .str => switch (leaf) {
            DomEventExtractionPlan.leaf_key,
            DomEventExtractionPlan.leaf_value,
            => return,
            else => return error.IncompatibleEventExtractionLeaf,
        },
        .bool => switch (leaf) {
            DomEventExtractionPlan.leaf_checked,
            DomEventExtractionPlan.leaf_shift_key,
            => return,
            else => return error.IncompatibleEventExtractionLeaf,
        },
        else => return error.IncompatibleEventExtractionLeaf,
    }
}

fn validateEventExtractionSourceLeaf(source: u8, leaf: u8) ParseError!void {
    switch (leaf) {
        DomEventExtractionPlan.leaf_key,
        DomEventExtractionPlan.leaf_shift_key,
        => {
            if (source == DomEventExtractionPlan.source_event) return;
        },
        DomEventExtractionPlan.leaf_value,
        DomEventExtractionPlan.leaf_checked,
        => {
            if (source == DomEventExtractionPlan.source_target or source == DomEventExtractionPlan.source_current_target) return;
        },
        else => unreachable,
    }
    return error.IncompatibleEventExtractionSource;
}

fn parseSupportedEventExtractionPlanKind(extraction_bytes: []const u8) ParseError!EventExtractionPlanKind {
    _ = try parseEventExtractionPayloadKind(extraction_bytes);
    if (std.mem.eql(u8, extraction_bytes, &SchemaTag.unit_schema)) return .none;
    if (std.mem.eql(u8, extraction_bytes, &DomEventExtractionPlan.target_value)) return .target_value;
    if (std.mem.eql(u8, extraction_bytes, &DomEventExtractionPlan.target_checked)) return .target_checked;
    if (std.mem.eql(u8, extraction_bytes, &DomEventExtractionPlan.key_shift)) return .record_key_shift;
    return error.UnsupportedEventExtractionPlan;
}

pub fn eventExtractionPlanKindFromBytes(extraction_bytes: []const u8) ?EventExtractionPlanKind {
    return parseSupportedEventExtractionPlanKind(extraction_bytes) catch null;
}

pub fn boundaryPayloadDescriptorFromExtractionBytes(extraction_bytes: []const u8) BoundaryPayloadDescriptor {
    const extraction = parseSupportedEventExtractionPlanKind(extraction_bytes) catch |err| std.debug.panic(
        "Roc event extraction plan bytes were malformed or unsupported: {s} ({d} byte(s))",
        .{ @errorName(err), extraction_bytes.len },
    );
    return BoundaryPayloadDescriptor.init(extraction.payloadKind(), extraction);
}

pub fn validateBoundaryPayloadDescriptor(schema: PayloadKind, extraction: EventExtractionPlanKind) void {
    if (boundaryPayloadDescriptorMatches(schema, extraction)) return;
    std.debug.panic(
        "Roc boundary payload descriptor used mismatched schema {d} and event extraction plan {d}; expected schema {d}",
        .{ @intFromEnum(schema), @intFromEnum(extraction), @intFromEnum(extraction.payloadKind()) },
    );
}

pub fn boundaryPayloadDescriptorMatches(schema: PayloadKind, extraction: EventExtractionPlanKind) bool {
    return schema == extraction.payloadKind();
}

test "event extraction plans use shared boundary schema tags" {
    try std.testing.expectEqualSlices(u8, &[_]u8{SchemaTag.unit}, &SchemaTag.unit_schema);
    try std.testing.expectEqualSlices(u8, &[_]u8{SchemaTag.text}, &SchemaTag.text_schema);
    try std.testing.expectEqualSlices(u8, &[_]u8{SchemaTag.bool_}, &SchemaTag.bool_schema);
    try std.testing.expectEqual(SchemaTag.text, DomEventExtractionPlan.target_value[0]);
    try std.testing.expectEqual(DomEventExtractionPlan.source_current_target, DomEventExtractionPlan.target_value[1]);
    try std.testing.expectEqual(DomEventExtractionPlan.leaf_value, DomEventExtractionPlan.target_value[2]);
    try std.testing.expectEqual(SchemaTag.bool_, DomEventExtractionPlan.target_checked[0]);
    try std.testing.expectEqual(SchemaTag.record, DomEventExtractionPlan.key_shift[0]);
}

test "compact event extraction plan ids declare their payload container" {
    try std.testing.expectEqual(PayloadKind.unit, EventExtractionPlanKind.none.payloadKind());
    try std.testing.expectEqual(PayloadKind.str, EventExtractionPlanKind.target_value.payloadKind());
    try std.testing.expectEqual(PayloadKind.bool, EventExtractionPlanKind.target_checked.payloadKind());
    try std.testing.expectEqual(PayloadKind.bytes, EventExtractionPlanKind.record_key_shift.payloadKind());
}

test "payload shape ids must match extraction plan payload containers" {
    try std.testing.expect(boundaryPayloadDescriptorMatches(.unit, .none));
    try std.testing.expect(boundaryPayloadDescriptorMatches(.str, .target_value));
    try std.testing.expect(boundaryPayloadDescriptorMatches(.bool, .target_checked));
    try std.testing.expect(boundaryPayloadDescriptorMatches(.bytes, .record_key_shift));
    try std.testing.expect(!boundaryPayloadDescriptorMatches(.unit, .target_value));
    try std.testing.expect(!boundaryPayloadDescriptorMatches(.bytes, .none));
}

test "supported event extraction plan ids declare derived payload shape bytes" {
    try std.testing.expectEqualSlices(u8, &SchemaTag.unit_schema, EventExtractionPlanKind.none.schemaBytes());
    try std.testing.expectEqualSlices(u8, &SchemaTag.text_schema, EventExtractionPlanKind.target_value.schemaBytes());
    try std.testing.expectEqualSlices(u8, &SchemaTag.bool_schema, EventExtractionPlanKind.target_checked.schemaBytes());
    try std.testing.expectEqualSlices(u8, &SchemaTag.key_shift_schema, EventExtractionPlanKind.record_key_shift.schemaBytes());

    try std.testing.expectEqualSlices(
        u8,
        &SchemaTag.key_shift_schema,
        BoundaryPayloadDescriptor.init(.bytes, .record_key_shift).schemaBytes(),
    );
}

test "boundary payload descriptors derive dispatch containers from extraction plan bytes" {
    try std.testing.expectEqual(EventExtractionPlanKind.none, eventExtractionPlanKindFromBytes(&SchemaTag.unit_schema).?);
    try std.testing.expectEqual(EventExtractionPlanKind.target_value, eventExtractionPlanKindFromBytes(&DomEventExtractionPlan.target_value).?);
    try std.testing.expectEqual(EventExtractionPlanKind.target_checked, eventExtractionPlanKindFromBytes(&DomEventExtractionPlan.target_checked).?);
    try std.testing.expectEqual(EventExtractionPlanKind.record_key_shift, eventExtractionPlanKindFromBytes(&DomEventExtractionPlan.key_shift).?);
    try std.testing.expectEqual(@as(?EventExtractionPlanKind, null), eventExtractionPlanKindFromBytes(&[_]u8{98}));

    const descriptor = boundaryPayloadDescriptorFromExtractionBytes(&DomEventExtractionPlan.key_shift);
    try std.testing.expectEqual(PayloadKind.bytes, descriptor.payload_kind);
    try std.testing.expectEqual(EventExtractionPlanKind.record_key_shift, descriptor.extraction_plan);
}

test "event extraction parser validates DOM-specific scalar leaves" {
    const empty_record = [_]u8{ SchemaTag.record, 0 };
    const empty_field_name = [_]u8{ SchemaTag.record, 1, 0, SchemaTag.text, DomEventExtractionPlan.source_event, DomEventExtractionPlan.leaf_key };
    const duplicate_fields = [_]u8{
        SchemaTag.record,
        2,
        3,
        'k',
        'e',
        'y',
        SchemaTag.text,
        DomEventExtractionPlan.source_event,
        DomEventExtractionPlan.leaf_key,
        3,
        'k',
        'e',
        'y',
        SchemaTag.bool_,
        DomEventExtractionPlan.source_event,
        DomEventExtractionPlan.leaf_shift_key,
    };
    const invalid_utf8_field = [_]u8{ SchemaTag.record, 1, 1, 0xff, SchemaTag.text, DomEventExtractionPlan.source_event, DomEventExtractionPlan.leaf_key };
    const trailing_bytes = [_]u8{ SchemaTag.text, DomEventExtractionPlan.source_event, DomEventExtractionPlan.leaf_key, 0 };
    const event_key = [_]u8{
        SchemaTag.text,
        DomEventExtractionPlan.source_event,
        DomEventExtractionPlan.leaf_key,
    };
    const invalid_source = [_]u8{
        SchemaTag.text,
        99,
        DomEventExtractionPlan.leaf_key,
    };
    const invalid_leaf = [_]u8{
        SchemaTag.bool_,
        DomEventExtractionPlan.source_event,
        DomEventExtractionPlan.leaf_value,
    };
    const invalid_event_property_source = [_]u8{
        SchemaTag.text,
        DomEventExtractionPlan.source_current_target,
        DomEventExtractionPlan.leaf_key,
    };
    const invalid_target_property_source = [_]u8{
        SchemaTag.bool_,
        DomEventExtractionPlan.source_event,
        DomEventExtractionPlan.leaf_checked,
    };
    const nested_record = [_]u8{
        SchemaTag.record,
        1,
        5,
        'o',
        'u',
        't',
        'e',
        'r',
        SchemaTag.record,
        1,
        5,
        'i',
        'n',
        'n',
        'e',
        'r',
        SchemaTag.text,
        DomEventExtractionPlan.source_event,
        DomEventExtractionPlan.leaf_key,
    };

    try std.testing.expectError(error.EmptyRecord, parseEventExtractionPayloadKind(&empty_record));
    try std.testing.expectError(error.EmptyRecordFieldName, parseEventExtractionPayloadKind(&empty_field_name));
    try std.testing.expectError(error.DuplicateRecordFieldName, parseEventExtractionPayloadKind(&duplicate_fields));
    try std.testing.expectError(error.InvalidRecordFieldNameUtf8, parseEventExtractionPayloadKind(&invalid_utf8_field));
    try std.testing.expectError(error.TrailingBytes, parseEventExtractionPayloadKind(&trailing_bytes));
    try std.testing.expectEqual(PayloadKind.str, parseEventExtractionPayloadKind(&event_key));
    try std.testing.expectEqual(@as(?EventExtractionPlanKind, null), eventExtractionPlanKindFromBytes(&event_key));
    try std.testing.expectError(error.UnknownEventExtractionSource, parseEventExtractionPayloadKind(&invalid_source));
    try std.testing.expectError(error.IncompatibleEventExtractionLeaf, parseEventExtractionPayloadKind(&invalid_leaf));
    try std.testing.expectError(error.IncompatibleEventExtractionSource, parseEventExtractionPayloadKind(&invalid_event_property_source));
    try std.testing.expectError(error.IncompatibleEventExtractionSource, parseEventExtractionPayloadKind(&invalid_target_property_source));
    try std.testing.expectError(error.NestedRecordField, parseEventExtractionPayloadKind(&nested_record));
}
