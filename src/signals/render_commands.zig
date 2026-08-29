//! Host-independent render command protocol and command-buffer encoders.

const std = @import("std");
const boundary = @import("boundary.zig");
const ids = @import("ids.zig");

pub const protocol_version: u32 = 11;
pub const protocol_feature_dynamic_attrs: u32 = 1 << 0;
pub const protocol_feature_dynamic_events: u32 = 1 << 1;
pub const protocol_features: u32 = protocol_feature_dynamic_attrs | protocol_feature_dynamic_events;

pub const listener_option_prevent_default: u32 = 1 << 0;
pub const listener_option_stop_propagation: u32 = 1 << 1;
pub const listener_option_capture: u32 = 1 << 2;
pub const listener_option_passive: u32 = 1 << 3;
pub const listener_option_once: u32 = 1 << 4;
pub const listener_option_stop_immediate: u32 = 1 << 5;
pub const listener_option_self: u32 = 1 << 6;
pub const listener_option_trusted: u32 = 1 << 7;
pub const listener_option_mask: u32 =
    listener_option_prevent_default |
    listener_option_stop_propagation |
    listener_option_capture |
    listener_option_passive |
    listener_option_once |
    listener_option_stop_immediate |
    listener_option_self |
    listener_option_trusted;

pub const EventPolicy = struct {
    prevent_default: bool = false,
    stop_propagation: bool = false,
    stop_immediate: bool = false,
    capture: bool = false,
    passive: bool = false,
    once: bool = false,
    self: bool = false,
    trusted: bool = false,

    pub const none: EventPolicy = .{};

    /// Validates command flags from their integer wire representation.
    pub fn fromBits(bits: u64) EventPolicy {
        const bits_u32 = std.math.cast(u32, bits) orelse std.debug.panic(
            "event listener options exceeded u32 range: {}",
            .{bits},
        );
        return fromWireBits(bits_u32);
    }

    /// Validates command flags from their integer wire representation.
    pub fn fromWireBits(bits: u32) EventPolicy {
        if ((bits & ~listener_option_mask) != 0) {
            std.debug.panic("event listener options used unsupported bits: 0x{x}", .{bits});
        }
        return .{
            .prevent_default = (bits & listener_option_prevent_default) != 0,
            .stop_propagation = (bits & listener_option_stop_propagation) != 0,
            .stop_immediate = (bits & listener_option_stop_immediate) != 0,
            .capture = (bits & listener_option_capture) != 0,
            .passive = (bits & listener_option_passive) != 0,
            .once = (bits & listener_option_once) != 0,
            .self = (bits & listener_option_self) != 0,
            .trusted = (bits & listener_option_trusted) != 0,
        };
    }

    /// Encodes validated command flags for the versioned browser protocol.
    pub fn toWireBits(self: EventPolicy) u32 {
        return (if (self.prevent_default) listener_option_prevent_default else 0) |
            (if (self.stop_propagation) listener_option_stop_propagation else 0) |
            (if (self.stop_immediate) listener_option_stop_immediate else 0) |
            (if (self.capture) listener_option_capture else 0) |
            (if (self.passive) listener_option_passive else 0) |
            (if (self.once) listener_option_once else 0) |
            (if (self.self) listener_option_self else 0) |
            (if (self.trusted) listener_option_trusted else 0);
    }

    /// Compares values through their owning capability rather than inspecting erased bytes.
    pub fn eql(self: EventPolicy, other: EventPolicy) bool {
        return self.prevent_default == other.prevent_default and
            self.stop_propagation == other.stop_propagation and
            self.stop_immediate == other.stop_immediate and
            self.capture == other.capture and
            self.passive == other.passive and
            self.once == other.once and
            self.self == other.self and
            self.trusted == other.trusted;
    }

    /// Reports whether none holds without mutating runtime state.
    pub fn isNone(self: EventPolicy) bool {
        return self.eql(EventPolicy.none);
    }
};

pub const Op = enum(u32) {
    reset_dom = 1,
    create_element = 2,
    create_text = 3,
    append_child = 4,
    remove_node = 5,
    move_before = 6,
    set_text = 7,
    set_value = 8,
    set_checked = 9,
    set_disabled = 10,
    set_role = 11,
    set_label = 12,
    set_test_id = 13,
    bind_click = 14,
    bind_input = 15,
    bind_check = 16,
    clear_event = 17,
    start_interval = 18,
    cancel_interval = 19,
    start_task = 20,
    cancel_task = 21,
    set_class = 22,
    bind_pointer_down = 23,
    bind_pointer_up = 24,
    bind_pointer_enter = 25,
    bind_pointer_leave = 26,
    extended = 27,
    push_state = 28,
    replace_state = 29,
    set_storage_text = 30,
    remove_storage = 31,
    set_document_title = 32,
};

pub const DynamicOp = enum(u16) {
    set_attr_text = 1,
    remove_attr = 2,
    bind_event = 3,
    clear_event = 4,
};

pub const EventDeliveryRequestWire = enum(u32) {
    auto = 1,
    native = 2,
};

pub const EventDeliveryEffectiveWire = enum(u32) {
    native = 1,
    delegated = 2,
};

pub const EventDeliveryReasonWire = enum(u32) {
    requested_native = 1,
    capture_policy = 2,
    stop_immediate_policy = 3,
    stop_propagation_policy = 4,
    pointer_drag = 5,
    prevent_default_policy = 6,
    once_policy = 7,
    passive_policy = 8,
    self_filter = 9,
    native_runtime_default = 10,
};

pub const EventDeliveryWire = struct {
    requested: EventDeliveryRequestWire,
    effective: EventDeliveryEffectiveWire,
    reason: EventDeliveryReasonWire,
};

pub const Record = extern struct {
    op: u32,
    a: u32 = 0,
    b: u32 = 0,
    c: u32 = 0,
    d: u32 = 0,
    e: u32 = 0,

    pub const word_count = @divExact(@sizeOf(Record), @sizeOf(u32));

    /// Creates an initialized value with the ownership and capacity invariants required by this module.
    fn initRaw(op: Op, a: u32, b: u32, c: u32, d: u32, e: u32) Record {
        return .{
            .op = @intFromEnum(op),
            .a = a,
            .b = b,
            .c = c,
            .d = d,
            .e = e,
        };
    }
};

comptime {
    if (@sizeOf(Record) != 6 * @sizeOf(u32)) @compileError("wire command record must remain six u32 words");
    if (@alignOf(Record) != @alignOf(u32)) @compileError("wire command record alignment changed");
    for (.{ "op", "a", "b", "c", "d", "e" }, 0..) |field_name, word_index| {
        if (@offsetOf(Record, field_name) != word_index * @sizeOf(u32)) @compileError("wire command record field layout changed");
    }
}

pub const Buffer = struct {
    records: std.ArrayListUnmanaged(Record) = .empty,

    /// Releases every resource owned by this value and leaves no retained host or Roc ownership behind.
    pub fn deinit(self: *Buffer, allocator: std.mem.Allocator) void {
        self.records.deinit(allocator);
        self.* = .{};
    }

    /// Drops live entries while retaining allocated capacity for bounded reuse.
    pub fn clearRetainingCapacity(self: *Buffer) void {
        self.records.clearRetainingCapacity();
    }

    /// Returns the number of live entries without scanning unrelated runtime state.
    pub fn len(self: *const Buffer) usize {
        return self.records.items.len;
    }

    /// Returns an address for host-private identity lookup, never for application-visible identity.
    pub fn ptrAddress(self: *const Buffer) usize {
        if (self.records.items.len == 0) return 0;
        return @intFromPtr(self.records.items.ptr);
    }

    /// Appends  using capacity that must already satisfy the caller's transaction contract.
    pub fn appendRaw(self: *Buffer, allocator: std.mem.Allocator, op: Op, a: u32, b: u32, c: u32, d: u32, e: u32) std.mem.Allocator.Error!void {
        try self.records.append(allocator, Record.initRaw(op, a, b, c, d, e));
    }

    /// Ensures total capacity capacity or state before publication can begin.
    pub fn ensureTotalCapacity(self: *Buffer, allocator: std.mem.Allocator, capacity: usize) std.mem.Allocator.Error!void {
        try self.records.ensureTotalCapacity(allocator, capacity);
    }
};

/// Byte offset into one protocol-owned side buffer.
pub const WireOffset = enum(u32) {
    _,

    /// Exposes the offset only while constructing the final raw wire record.
    pub fn raw(self: WireOffset) u32 {
        return @intFromEnum(self);
    }
};

/// Byte length in one protocol-owned side buffer.
pub const WireLength = enum(u32) {
    _,

    /// Exposes the length only while constructing the final raw wire record.
    pub fn raw(self: WireLength) u32 {
        return @intFromEnum(self);
    }
};

/// Narrow browser-wire representation of an engine element identity.
pub const WireElemId = enum(u32) {
    _,

    /// Narrows an engine element identity at the versioned browser boundary.
    pub fn fromEngine(value: ids.ElemId) error{ResourceLimit}!WireElemId {
        return @enumFromInt(std.math.cast(u32, value.raw()) orelse return error.ResourceLimit);
    }

    /// Exposes the identity only while constructing the final raw wire record.
    pub fn raw(self: WireElemId) u32 {
        return @intFromEnum(self);
    }
};

/// Narrow browser-wire representation of an engine event identity.
pub const WireEventId = enum(u32) {
    _,

    /// Narrows an engine event identity at the versioned browser boundary.
    pub fn fromEngine(value: ids.EventId) error{ResourceLimit}!WireEventId {
        return @enumFromInt(std.math.cast(u32, value.raw()) orelse return error.ResourceLimit);
    }

    /// Exposes the identity only while constructing the final raw wire record.
    pub fn raw(self: WireEventId) u32 {
        return @intFromEnum(self);
    }
};

pub const DynamicSlice = struct {
    offset: WireOffset,
    len: WireLength,
};

pub const DynamicBuffer = struct {
    bytes: std.ArrayListUnmanaged(u8) = .empty,

    /// Releases every resource owned by this value and leaves no retained host or Roc ownership behind.
    pub fn deinit(self: *DynamicBuffer, allocator: std.mem.Allocator) void {
        self.bytes.deinit(allocator);
        self.* = .{};
    }

    /// Drops live entries while retaining allocated capacity for bounded reuse.
    pub fn clearRetainingCapacity(self: *DynamicBuffer) void {
        self.bytes.clearRetainingCapacity();
    }

    /// Returns the number of live entries without scanning unrelated runtime state.
    pub fn len(self: *const DynamicBuffer) usize {
        return self.bytes.items.len;
    }

    /// Returns an address for host-private identity lookup, never for application-visible identity.
    pub fn ptrAddress(self: *const DynamicBuffer) usize {
        if (self.bytes.items.len == 0) return 0;
        return @intFromPtr(self.bytes.items.ptr);
    }

    /// Ensures total capacity capacity or state before publication can begin.
    pub fn ensureTotalCapacity(self: *DynamicBuffer, allocator: std.mem.Allocator, capacity: usize) std.mem.Allocator.Error!void {
        try self.bytes.ensureTotalCapacity(allocator, capacity);
    }

    /// Appends set attr text using capacity that must already satisfy the caller's transaction contract.
    pub fn appendSetAttrText(self: *DynamicBuffer, allocator: std.mem.Allocator, elem_id: WireElemId, name: []const u8, value: []const u8) PreflightError!DynamicSlice {
        var payload_len = std.math.add(usize, 3 * @sizeOf(u32), name.len) catch return error.ResourceLimit;
        payload_len = std.math.add(usize, payload_len, value.len) catch return error.ResourceLimit;
        const record = try self.appendRecord(allocator, .set_attr_text, payload_len);
        var cursor = record.payload_start;
        writeU32(self.bytes.items, &cursor, elem_id.raw());
        writeU32(self.bytes.items, &cursor, @intCast(name.len));
        writeBytes(self.bytes.items, &cursor, name);
        writeU32(self.bytes.items, &cursor, @intCast(value.len));
        writeBytes(self.bytes.items, &cursor, value);
        return record.slice;
    }

    /// Appends remove attr using capacity that must already satisfy the caller's transaction contract.
    pub fn appendRemoveAttr(self: *DynamicBuffer, allocator: std.mem.Allocator, elem_id: WireElemId, name: []const u8) PreflightError!DynamicSlice {
        const payload_len = std.math.add(usize, 2 * @sizeOf(u32), name.len) catch return error.ResourceLimit;
        const record = try self.appendRecord(allocator, .remove_attr, payload_len);
        var cursor = record.payload_start;
        writeU32(self.bytes.items, &cursor, elem_id.raw());
        writeU32(self.bytes.items, &cursor, @intCast(name.len));
        writeBytes(self.bytes.items, &cursor, name);
        return record.slice;
    }

    /// Appends bind event using capacity that must already satisfy the caller's transaction contract.
    pub fn appendBindEvent(
        self: *DynamicBuffer,
        allocator: std.mem.Allocator,
        elem_id: WireElemId,
        event_id: WireEventId,
        event_name: []const u8,
        options: u32,
        delivery: EventDeliveryWire,
        payload_descriptor: boundary.BoundaryPayloadDescriptor,
    ) PreflightError!DynamicSlice {
        const event_extraction_plan = payload_descriptor.extractionBytes();
        var payload_len = std.math.add(usize, 8 * @sizeOf(u32), event_name.len) catch return error.ResourceLimit;
        payload_len = std.math.add(usize, payload_len, event_extraction_plan.len) catch return error.ResourceLimit;
        const record = try self.appendRecord(allocator, .bind_event, payload_len);
        var cursor = record.payload_start;
        writeU32(self.bytes.items, &cursor, elem_id.raw());
        writeU32(self.bytes.items, &cursor, event_id.raw());
        writeU32(self.bytes.items, &cursor, @intCast(event_name.len));
        writeBytes(self.bytes.items, &cursor, event_name);
        writeU32(self.bytes.items, &cursor, options);
        writeU32(self.bytes.items, &cursor, @intFromEnum(delivery.requested));
        writeU32(self.bytes.items, &cursor, @intFromEnum(delivery.effective));
        writeU32(self.bytes.items, &cursor, @intFromEnum(delivery.reason));
        writeU32(self.bytes.items, &cursor, @intCast(event_extraction_plan.len));
        writeBytes(self.bytes.items, &cursor, event_extraction_plan);
        return record.slice;
    }

    /// Appends clear event using capacity that must already satisfy the caller's transaction contract.
    pub fn appendClearEvent(self: *DynamicBuffer, allocator: std.mem.Allocator, elem_id: WireElemId, event_name: []const u8) PreflightError!DynamicSlice {
        const payload_len = std.math.add(usize, 2 * @sizeOf(u32), event_name.len) catch return error.ResourceLimit;
        const record = try self.appendRecord(allocator, .clear_event, payload_len);
        var cursor = record.payload_start;
        writeU32(self.bytes.items, &cursor, elem_id.raw());
        writeU32(self.bytes.items, &cursor, @intCast(event_name.len));
        writeBytes(self.bytes.items, &cursor, event_name);
        return record.slice;
    }

    const AppendedRecord = struct {
        slice: DynamicSlice,
        payload_start: usize,
    };

    fn appendRecord(self: *DynamicBuffer, allocator: std.mem.Allocator, op: DynamicOp, payload_len: usize) PreflightError!AppendedRecord {
        const offset = self.bytes.items.len;
        const aligned_payload_len = try checkedAlign4(payload_len);
        const header_len = @sizeOf(u16) + @sizeOf(u16) + @sizeOf(u32);
        const total_len = std.math.add(usize, header_len, aligned_payload_len) catch return error.ResourceLimit;
        const final_len = std.math.add(usize, offset, total_len) catch return error.ResourceLimit;
        if (offset > std.math.maxInt(u32) or total_len > std.math.maxInt(u32)) return error.ResourceLimit;
        try self.bytes.resize(allocator, final_len);
        @memset(self.bytes.items[offset..][0..total_len], 0);

        var cursor = offset;
        writeU16(self.bytes.items, &cursor, @intFromEnum(op));
        writeU16(self.bytes.items, &cursor, 0);
        writeU32(self.bytes.items, &cursor, @intCast(payload_len));

        return .{
            .slice = .{
                .offset = @enumFromInt(@as(u32, @intCast(offset))),
                .len = @enumFromInt(@as(u32, @intCast(total_len))),
            },
            .payload_start = cursor,
        };
    }
};

pub const BatchCapacity = struct {
    commands: usize = 0,
    strings: usize = 0,
    dynamic: usize = 0,

    /// Adds another command requirement with overflow-safe resource accounting.
    pub fn add(self: *BatchCapacity, additional: BatchCapacity) error{ResourceLimit}!void {
        const commands = std.math.add(usize, self.commands, additional.commands) catch return error.ResourceLimit;
        const strings = std.math.add(usize, self.strings, additional.strings) catch return error.ResourceLimit;
        const dynamic = std.math.add(usize, self.dynamic, additional.dynamic) catch return error.ResourceLimit;
        self.* = .{ .commands = commands, .strings = strings, .dynamic = dynamic };
    }

    /// Charges one fixed command and optional bytes stored in the string side buffer.
    pub fn addFixed(self: *BatchCapacity, string_bytes: usize) error{ResourceLimit}!void {
        try self.add(.{ .commands = 1, .strings = string_bytes });
    }

    fn addDynamicPayload(self: *BatchCapacity, payload_len: usize) error{ResourceLimit}!void {
        const header = @sizeOf(u16) + @sizeOf(u16) + @sizeOf(u32);
        const record_len = std.math.add(usize, header, try checkedAlign4(payload_len)) catch return error.ResourceLimit;
        try self.add(.{ .commands = 1, .dynamic = record_len });
    }

    /// Charges one dynamic custom-attribute set command.
    pub fn addSetAttrText(self: *BatchCapacity, name_len: usize, value_len: usize) error{ResourceLimit}!void {
        var payload = std.math.add(usize, 3 * @sizeOf(u32), name_len) catch return error.ResourceLimit;
        payload = std.math.add(usize, payload, value_len) catch return error.ResourceLimit;
        try self.addDynamicPayload(payload);
    }

    /// Charges one dynamic custom-attribute removal command.
    pub fn addRemoveAttr(self: *BatchCapacity, name_len: usize) error{ResourceLimit}!void {
        const payload = std.math.add(usize, 2 * @sizeOf(u32), name_len) catch return error.ResourceLimit;
        try self.addDynamicPayload(payload);
    }

    /// Charges one dynamic event binding command, including extraction bytes.
    pub fn addBindEvent(self: *BatchCapacity, event_name_len: usize, extraction_len: usize) error{ResourceLimit}!void {
        var payload = std.math.add(usize, 8 * @sizeOf(u32), event_name_len) catch return error.ResourceLimit;
        payload = std.math.add(usize, payload, extraction_len) catch return error.ResourceLimit;
        try self.addDynamicPayload(payload);
    }

    /// Charges one dynamic event-clear command.
    pub fn addClearEvent(self: *BatchCapacity, event_name_len: usize) error{ResourceLimit}!void {
        const payload = std.math.add(usize, 2 * @sizeOf(u32), event_name_len) catch return error.ResourceLimit;
        try self.addDynamicPayload(payload);
    }
};

pub const PreflightError = std.mem.Allocator.Error || error{ResourceLimit};

pub const hard_max_command_records: usize = std.math.maxInt(u32);
pub const hard_max_string_bytes: usize = std.math.maxInt(u32);
pub const hard_max_dynamic_bytes: usize = std.math.maxInt(u32);

pub const BatchLimits = struct {
    command_records: usize = hard_max_command_records,
    string_bytes: usize = hard_max_string_bytes,
    dynamic_bytes: usize = hard_max_dynamic_bytes,

    /// Rejects malformed boundary data before it can enter committed engine state.
    pub fn validate(self: BatchLimits) error{ResourceLimit}!void {
        if (self.command_records > hard_max_command_records or
            self.string_bytes > hard_max_string_bytes or
            self.dynamic_bytes > hard_max_dynamic_bytes)
        {
            return error.ResourceLimit;
        }
    }
};

pub const BatchBuffers = struct {
    commands: Buffer = .{},
    strings: std.ArrayListUnmanaged(u8) = .empty,
    dynamic: DynamicBuffer = .{},

    fn deinit(self: *BatchBuffers, allocator: std.mem.Allocator) void {
        self.commands.deinit(allocator);
        self.strings.deinit(allocator);
        self.dynamic.deinit(allocator);
        self.* = .{};
    }

    fn clearRetainingCapacity(self: *BatchBuffers) void {
        self.commands.clearRetainingCapacity();
        self.strings.clearRetainingCapacity();
        self.dynamic.clearRetainingCapacity();
    }

    fn ensureTotalCapacity(self: *BatchBuffers, allocator: std.mem.Allocator, capacity: BatchCapacity) std.mem.Allocator.Error!void {
        try self.commands.ensureTotalCapacity(allocator, capacity.commands);
        try self.strings.ensureTotalCapacity(allocator, capacity.strings);
        try self.dynamic.ensureTotalCapacity(allocator, capacity.dynamic);
    }
};

/// Double-buffered command publication. Sinks write only to `staged`; readers
/// see only `published`, which changes after the whole host call succeeds.
pub const TransactionalBatch = struct {
    published: BatchBuffers = .{},
    staged: BatchBuffers = .{},
    limits: BatchLimits = .{},

    /// Sets limits at the narrow host or engine boundary that owns the mutation.
    pub fn setLimits(self: *TransactionalBatch, limits: BatchLimits) error{ResourceLimit}!void {
        try limits.validate();
        self.limits = limits;
    }

    /// Releases every resource owned by this value and leaves no retained host or Roc ownership behind.
    pub fn deinit(self: *TransactionalBatch, allocator: std.mem.Allocator) void {
        self.published.deinit(allocator);
        self.staged.deinit(allocator);
        self.* = .{};
    }

    /// Begins a fresh unpublished command batch while retaining reusable bounded storage.
    pub fn begin(self: *TransactionalBatch) void {
        self.published.clearRetainingCapacity();
        self.staged.clearRetainingCapacity();
    }

    /// Reserves all bytes and records required before command publication can begin.
    pub fn preflight(self: *TransactionalBatch, allocator: std.mem.Allocator, capacity: BatchCapacity) PreflightError!void {
        if (capacity.commands > self.limits.command_records or
            capacity.strings > self.limits.string_bytes or
            capacity.dynamic > self.limits.dynamic_bytes)
        {
            return error.ResourceLimit;
        }
        try self.staged.ensureTotalCapacity(allocator, capacity);
    }

    /// Reserves all bytes and records required before command publication can begin.
    pub fn preflightAdditional(self: *TransactionalBatch, allocator: std.mem.Allocator, additional: BatchCapacity) PreflightError!void {
        const capacity = BatchCapacity{
            .commands = std.math.add(usize, self.staged.commands.len(), additional.commands) catch return error.ResourceLimit,
            .strings = std.math.add(usize, self.staged.strings.items.len, additional.strings) catch return error.ResourceLimit,
            .dynamic = std.math.add(usize, self.staged.dynamic.len(), additional.dynamic) catch return error.ResourceLimit,
        };
        try self.preflight(allocator, capacity);
    }

    /// Publishes all prepared changes atomically and transfers their provisional ownership.
    pub fn commit(self: *TransactionalBatch) void {
        std.mem.swap(BatchBuffers, &self.published, &self.staged);
        self.staged.clearRetainingCapacity();
    }

    /// Drops provisional resources and restores the plan to an unpublished state.
    pub fn abort(self: *TransactionalBatch) void {
        self.published.clearRetainingCapacity();
        self.staged.clearRetainingCapacity();
    }

    /// Clears published while retaining bounded storage where the type promises reuse.
    pub fn clearPublished(self: *TransactionalBatch) void {
        self.published.clearRetainingCapacity();
    }

    /// Returns whether the consumer has drained the prior publication and no
    /// unpublished transaction is still staged.
    pub fn isDrained(self: *const TransactionalBatch) bool {
        return self.published.commands.len() == 0 and
            self.published.strings.items.len == 0 and
            self.published.dynamic.len() == 0 and
            self.staged.commands.len() == 0 and
            self.staged.strings.items.len == 0 and
            self.staged.dynamic.len() == 0;
    }
};

/// One canonical dynamic event binding prepared for wire encoding.
pub const PreparedBindEventCommand = struct { elem_id: WireElemId, event_id: WireEventId, name: []const u8, policy: EventPolicy, delivery: EventDeliveryWire, payload_descriptor: boundary.BoundaryPayloadDescriptor };
const PreparedTextCommand = struct { elem_id: WireElemId, bytes: []const u8 };
const PreparedBoolCommand = struct { elem_id: WireElemId, value: bool };

/// Semantic fixed-record command whose variant determines every wire operand.
pub const PreparedSemanticCommand = union(enum) {
    reset_dom,
    create_element: struct { elem_id: WireElemId, tag: []const u8 },
    create_text: WireElemId,
    append_child: struct { parent: WireElemId, child: WireElemId },
    remove_node: WireElemId,
    move_before: struct { parent: WireElemId, child: WireElemId, before: ?WireElemId },
    set_text: PreparedTextCommand,
    set_value: PreparedTextCommand,
    set_checked: PreparedBoolCommand,
    set_disabled: PreparedBoolCommand,
    bind_fixed: struct { elem_id: WireElemId, event_id: WireEventId, kind: EventKind },
    clear_fixed: struct { elem_id: WireElemId, kind: EventKind },
};

const PreparedCommand = union(enum) {
    reset_dom,
    create_element: struct { elem_id: WireElemId, tag: []const u8 },
    create_text: WireElemId,
    append_child: struct { parent: WireElemId, child: WireElemId },
    remove_node: WireElemId,
    move_before: struct { parent: WireElemId, child: WireElemId, before: ?WireElemId },
    set_text: PreparedTextCommand,
    set_value: PreparedTextCommand,
    set_checked: PreparedBoolCommand,
    set_disabled: PreparedBoolCommand,
    bind_fixed: struct { elem_id: WireElemId, event_id: WireEventId, kind: EventKind },
    clear_fixed: struct { elem_id: WireElemId, kind: EventKind },
    set_attr_text: struct { elem_id: WireElemId, name: []const u8, value: []const u8 },
    remove_attr: struct { elem_id: WireElemId, name: []const u8 },
    bind_event: PreparedBindEventCommand,
    clear_event: struct { elem_id: WireElemId, name: []const u8 },
};

/// Collects exact command capacity and stages it before atomic publication.
pub const PreparedBatch = struct {
    commands: std.ArrayListUnmanaged(PreparedCommand) = .empty,
    capacity: BatchCapacity = .{},
    command_limit: usize = 0,

    /// Reserves the plan-local command journal.
    pub fn init(allocator: std.mem.Allocator, expected_commands: usize) std.mem.Allocator.Error!PreparedBatch {
        var self: PreparedBatch = .{};
        try self.commands.ensureTotalCapacity(allocator, expected_commands);
        self.command_limit = expected_commands;
        return self;
    }

    /// Cumulatively reserves additional semantic commands during recoverable preparation.
    pub fn reserveAdditional(self: *PreparedBatch, allocator: std.mem.Allocator, additional: usize) (std.mem.Allocator.Error || error{ResourceLimit})!void {
        const next_limit = std.math.add(usize, self.command_limit, additional) catch return error.ResourceLimit;
        try self.commands.ensureTotalCapacity(allocator, next_limit);
        self.command_limit = next_limit;
    }

    /// Appends another prepared journal after reserving its exact command and
    /// byte requirements. Commands borrow payload storage owned by their
    /// enclosing render splice, so the donor journal may be deinitialized
    /// immediately after this transfer.
    pub fn appendPrepared(self: *PreparedBatch, allocator: std.mem.Allocator, other: *PreparedBatch) (std.mem.Allocator.Error || error{ResourceLimit})!void {
        try self.reserveAdditional(allocator, other.commands.items.len);
        try self.capacity.add(other.capacity);
        self.commands.appendSliceAssumeCapacity(other.commands.items);
        other.commands.clearRetainingCapacity();
        other.capacity = .{};
        other.command_limit = 0;
    }

    /// Appends the donor commands that still address a node of the final
    /// tree. A scalar journal is prepared against the committed cache before
    /// the structural part of the same transaction decides which nodes it
    /// retires, so its commands for those nodes describe a node the batch has
    /// already removed; the browser would reject them as unknown ids. Commands
    /// whose target is in `retired_elem_ids` are dropped here, every kept
    /// command is charged exactly as when it was first journaled, and the
    /// donor is emptied only after every reservation succeeded.
    pub fn appendPreparedSurviving(self: *PreparedBatch, allocator: std.mem.Allocator, other: *PreparedBatch, retired_elem_ids: *const std.AutoHashMapUnmanaged(u64, void)) (std.mem.Allocator.Error || error{ResourceLimit})!void {
        var kept: BatchCapacity = .{};
        var kept_count: usize = 0;
        for (other.commands.items) |command| {
            if (commandTargetsRetiredNode(command, retired_elem_ids)) continue;
            try chargeCommand(&kept, command);
            kept_count += 1;
        }
        try self.reserveAdditional(allocator, kept_count);
        try self.capacity.add(kept);
        for (other.commands.items) |command| {
            if (commandTargetsRetiredNode(command, retired_elem_ids)) continue;
            self.commands.appendAssumeCapacity(command);
        }
        other.commands.clearRetainingCapacity();
        other.capacity = .{};
        other.command_limit = 0;
    }

    fn commandTargetsRetiredNode(command: PreparedCommand, retired_elem_ids: *const std.AutoHashMapUnmanaged(u64, void)) bool {
        const elem_id: WireElemId = switch (command) {
            .reset_dom, .create_element, .create_text, .append_child, .remove_node, .move_before => return false,
            .set_text, .set_value => |value| value.elem_id,
            .set_checked, .set_disabled => |value| value.elem_id,
            .bind_fixed => |value| value.elem_id,
            .clear_fixed => |value| value.elem_id,
            .set_attr_text => |value| value.elem_id,
            .remove_attr => |value| value.elem_id,
            .bind_event => |value| value.elem_id,
            .clear_event => |value| value.elem_id,
        };
        return retired_elem_ids.contains(elem_id.raw());
    }

    fn chargeCommand(capacity: *BatchCapacity, command: PreparedCommand) error{ResourceLimit}!void {
        switch (command) {
            .reset_dom, .create_text, .append_child, .remove_node, .move_before, .set_checked, .set_disabled, .bind_fixed, .clear_fixed => try capacity.addFixed(0),
            .create_element => |value| try capacity.addFixed(value.tag.len),
            .set_text, .set_value => |value| try capacity.addFixed(value.bytes.len),
            .set_attr_text => |value| try capacity.addSetAttrText(value.name.len, value.value.len),
            .remove_attr => |value| try capacity.addRemoveAttr(value.name.len),
            .bind_event => |value| try capacity.addBindEvent(value.name.len, value.payload_descriptor.extractionBytes().len),
            .clear_event => |value| try capacity.addClearEvent(value.name.len),
        }
    }

    fn ensureJournalSlot(self: *const PreparedBatch) error{ResourceLimit}!void {
        if (self.commands.items.len >= self.command_limit) return error.ResourceLimit;
    }

    /// Releases the borrowed command journal.
    pub fn deinit(self: *PreparedBatch, allocator: std.mem.Allocator) void {
        self.commands.deinit(allocator);
        self.* = undefined;
    }

    /// Computes the public command counters from the prepared semantic journal.
    pub fn counts(self: *const PreparedBatch) Counts {
        var result: Counts = .{};
        for (self.commands.items) |command| switch (command) {
            .reset_dom => result.addOp(.reset_dom),
            .create_element, .create_text => result.addOp(.create_element),
            .append_child => result.addOp(.append_child),
            .remove_node => result.addOp(.remove_node),
            .move_before => result.addOp(.move_before),
            .set_text => result.addOp(.set_text),
            .set_value => result.addOp(.set_value),
            .set_checked => result.addOp(.set_checked),
            .set_disabled => result.addOp(.set_disabled),
            .bind_fixed => result.addOp(.bind_click),
            .clear_fixed => result.addOp(.clear_event),
            .set_attr_text, .remove_attr => result.addOp(.extended),
            .bind_event => result.addOp(.bind_click),
            .clear_event => result.addOp(.clear_event),
        };
        return result;
    }

    fn addCommand(self: *PreparedBatch, command: PreparedCommand, string_bytes: usize) error{ResourceLimit}!void {
        try self.ensureJournalSlot();
        try self.capacity.addFixed(string_bytes);
        self.commands.appendAssumeCapacity(command);
    }

    /// Adds a semantic fixed or string-backed command whose operands cannot be transposed.
    pub fn addSemantic(self: *PreparedBatch, command: PreparedSemanticCommand) error{ResourceLimit}!void {
        const string_bytes: usize = switch (command) {
            .create_element => |value| value.tag.len,
            .set_text, .set_value => |value| value.bytes.len,
            .reset_dom, .create_text, .append_child, .remove_node, .move_before, .set_checked, .set_disabled, .bind_fixed, .clear_fixed => 0,
        };
        const prepared: PreparedCommand = switch (command) {
            .reset_dom => .reset_dom,
            .create_element => |value| .{ .create_element = .{ .elem_id = value.elem_id, .tag = value.tag } },
            .create_text => |value| .{ .create_text = value },
            .append_child => |value| .{ .append_child = .{ .parent = value.parent, .child = value.child } },
            .remove_node => |value| .{ .remove_node = value },
            .move_before => |value| .{ .move_before = .{ .parent = value.parent, .child = value.child, .before = value.before } },
            .set_text => |value| .{ .set_text = value },
            .set_value => |value| .{ .set_value = value },
            .set_checked => |value| .{ .set_checked = value },
            .set_disabled => |value| .{ .set_disabled = value },
            .bind_fixed => |value| .{ .bind_fixed = .{ .elem_id = value.elem_id, .event_id = value.event_id, .kind = value.kind } },
            .clear_fixed => |value| .{ .clear_fixed = .{ .elem_id = value.elem_id, .kind = value.kind } },
        };
        try self.addCommand(prepared, string_bytes);
    }

    /// Adds one dynamic custom-attribute set.
    pub fn addSetAttrText(self: *PreparedBatch, elem_id: WireElemId, name: []const u8, value: []const u8) error{ResourceLimit}!void {
        try self.ensureJournalSlot();
        try self.capacity.addSetAttrText(name.len, value.len);
        self.commands.appendAssumeCapacity(.{ .set_attr_text = .{ .elem_id = elem_id, .name = name, .value = value } });
    }

    /// Adds one dynamic custom-attribute removal.
    pub fn addRemoveAttr(self: *PreparedBatch, elem_id: WireElemId, name: []const u8) error{ResourceLimit}!void {
        try self.ensureJournalSlot();
        try self.capacity.addRemoveAttr(name.len);
        self.commands.appendAssumeCapacity(.{ .remove_attr = .{ .elem_id = elem_id, .name = name } });
    }

    /// Adds one dynamic event binding.
    pub fn addBindEvent(self: *PreparedBatch, command: PreparedBindEventCommand) error{ResourceLimit}!void {
        try self.ensureJournalSlot();
        try self.capacity.addBindEvent(command.name.len, command.payload_descriptor.extractionBytes().len);
        self.commands.appendAssumeCapacity(.{ .bind_event = command });
    }

    /// Adds one dynamic event clear.
    pub fn addClearEvent(self: *PreparedBatch, elem_id: WireElemId, name: []const u8) error{ResourceLimit}!void {
        try self.ensureJournalSlot();
        try self.capacity.addClearEvent(name.len);
        self.commands.appendAssumeCapacity(.{ .clear_event = .{ .elem_id = elem_id, .name = name } });
    }

    /// Reserves the unpublished destination batch without staging any bytes.
    pub fn preflight(self: *const PreparedBatch, batch: *TransactionalBatch, allocator: std.mem.Allocator) PreflightError!void {
        if (!batch.isDrained()) return error.ResourceLimit;
        batch.begin();
        errdefer batch.abort();
        try batch.preflight(allocator, self.capacity);
    }

    /// Encodes all commands using pre-reserved capacity and no allocation.
    pub fn stageAssumeCapacity(self: *const PreparedBatch, batch: *TransactionalBatch, allocator: std.mem.Allocator) PreflightError!void {
        for (self.commands.items) |command| switch (command) {
            .reset_dom => try batch.staged.commands.appendRaw(allocator, .reset_dom, 0, 0, 0, 0, 0),
            .create_element => |value| {
                const offset = std.math.cast(u32, batch.staged.strings.items.len) orelse return error.ResourceLimit;
                const len = std.math.cast(u32, value.tag.len) orelse return error.ResourceLimit;
                try batch.staged.strings.appendSlice(allocator, value.tag);
                try batch.staged.commands.appendRaw(allocator, .create_element, value.elem_id.raw(), offset, len, 0, 0);
            },
            .create_text => |elem_id| try batch.staged.commands.appendRaw(allocator, .create_text, elem_id.raw(), 0, 0, 0, 0),
            .append_child => |value| try batch.staged.commands.appendRaw(allocator, .append_child, value.parent.raw(), value.child.raw(), 0, 0, 0),
            .remove_node => |elem_id| try batch.staged.commands.appendRaw(allocator, .remove_node, elem_id.raw(), 0, 0, 0, 0),
            .move_before => |value| try batch.staged.commands.appendRaw(allocator, .move_before, value.parent.raw(), value.child.raw(), if (value.before) |before| before.raw() else 0, 0, 0),
            .set_text, .set_value => |value| {
                const offset = std.math.cast(u32, batch.staged.strings.items.len) orelse return error.ResourceLimit;
                const len = std.math.cast(u32, value.bytes.len) orelse return error.ResourceLimit;
                try batch.staged.strings.appendSlice(allocator, value.bytes);
                try batch.staged.commands.appendRaw(allocator, if (command == .set_text) .set_text else .set_value, value.elem_id.raw(), offset, len, 0, 0);
            },
            .set_checked, .set_disabled => |value| try batch.staged.commands.appendRaw(allocator, if (command == .set_checked) .set_checked else .set_disabled, value.elem_id.raw(), @intFromBool(value.value), 0, 0, 0),
            .bind_fixed => |value| try batch.staged.commands.appendRaw(allocator, value.kind.bindOp(), value.elem_id.raw(), value.event_id.raw(), 0, 0, 0),
            .clear_fixed => |value| try batch.staged.commands.appendRaw(allocator, .clear_event, value.elem_id.raw(), @intCast(@intFromEnum(value.kind)), 0, 0, 0),
            .set_attr_text => |value| {
                const slice = try batch.staged.dynamic.appendSetAttrText(allocator, value.elem_id, value.name, value.value);
                try batch.staged.commands.appendRaw(allocator, .extended, slice.offset.raw(), slice.len.raw(), 0, 0, 0);
            },
            .remove_attr => |value| {
                const slice = try batch.staged.dynamic.appendRemoveAttr(allocator, value.elem_id, value.name);
                try batch.staged.commands.appendRaw(allocator, .extended, slice.offset.raw(), slice.len.raw(), 0, 0, 0);
            },
            .bind_event => |value| {
                const slice = try batch.staged.dynamic.appendBindEvent(allocator, value.elem_id, value.event_id, value.name, value.policy.toWireBits(), value.delivery, value.payload_descriptor);
                try batch.staged.commands.appendRaw(allocator, .extended, slice.offset.raw(), slice.len.raw(), 0, 0, 0);
            },
            .clear_event => |value| {
                const slice = try batch.staged.dynamic.appendClearEvent(allocator, value.elem_id, value.name);
                try batch.staged.commands.appendRaw(allocator, .extended, slice.offset.raw(), slice.len.raw(), 0, 0, 0);
            },
        };
    }
};

/// Rounds a wire offset to the protocol's four-byte record alignment.
pub fn align4(len: usize) usize {
    return (len + 3) & ~@as(usize, 3);
}

/// Rounds a wire length with checked arithmetic at untrusted boundaries.
pub fn checkedAlign4(len: usize) error{ResourceLimit}!usize {
    const with_padding = std.math.add(usize, len, 3) catch return error.ResourceLimit;
    return with_padding & ~@as(usize, 3);
}

fn writeU16(bytes: []u8, cursor: *usize, value: u16) void {
    std.mem.writeInt(u16, bytes[cursor.*..][0..@sizeOf(u16)], value, .little);
    cursor.* += @sizeOf(u16);
}

fn writeU32(bytes: []u8, cursor: *usize, value: u32) void {
    std.mem.writeInt(u32, bytes[cursor.*..][0..@sizeOf(u32)], value, .little);
    cursor.* += @sizeOf(u32);
}

fn writeBytes(bytes: []u8, cursor: *usize, value: []const u8) void {
    @memcpy(bytes[cursor.*..][0..value.len], value);
    cursor.* += value.len;
}

fn exerciseTransactionalBatch(backing_allocator: std.mem.Allocator, preflight_allocator: std.mem.Allocator, expect_failure: bool) !void {
    var batch: TransactionalBatch = .{};
    defer batch.deinit(backing_allocator);

    // Model a previous successful call whose commands have not been drained.
    try batch.published.commands.appendRaw(backing_allocator, .set_text, 99, 0, 0, 0, 0);

    batch.begin();
    batch.preflight(preflight_allocator, .{ .commands = 9, .strings = 257, .dynamic = 513 }) catch |err| {
        batch.abort();
        try std.testing.expectEqual(@as(usize, 0), batch.published.commands.len());
        try std.testing.expectEqual(@as(usize, 0), batch.published.strings.items.len);
        try std.testing.expectEqual(@as(usize, 0), batch.published.dynamic.len());
        if (!expect_failure) return err;

        // Once memory is available, the same transaction object accepts a
        // complete retry and publishes only the retry's commands.
        batch.begin();
        try batch.preflight(backing_allocator, .{ .commands = 9, .strings = 257, .dynamic = 513 });
        try batch.staged.commands.appendRaw(backing_allocator, .set_text, 1, 0, 0, 0, 0);
        try batch.staged.strings.appendSlice(backing_allocator, "retry");
        batch.commit();
        try std.testing.expectEqual(@as(usize, 1), batch.published.commands.len());
        try std.testing.expectEqualStrings("retry", batch.published.strings.items);
        return error.OutOfMemory;
    };

    try batch.staged.commands.appendRaw(backing_allocator, .set_text, 1, 0, 0, 0, 0);
    try batch.staged.strings.appendSlice(backing_allocator, "committed");
    _ = try batch.staged.dynamic.appendRemoveAttr(backing_allocator, @enumFromInt(1), "title");
    batch.commit();

    try std.testing.expectEqual(@as(usize, 1), batch.published.commands.len());
    try std.testing.expectEqualStrings("committed", batch.published.strings.items);
    try std.testing.expect(batch.published.dynamic.len() != 0);
}

test "transaction command preflight sweeps every allocation failure" {
    var count_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    try exerciseTransactionalBatch(std.testing.allocator, count_allocator.allocator(), false);
    const allocation_count = count_allocator.alloc_index;
    try std.testing.expect(allocation_count >= 3);

    // FailingAllocator is zero-based: fail_index 0 is allocation number 1.
    for (0..allocation_count) |fail_index| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        try std.testing.expectError(error.OutOfMemory, exerciseTransactionalBatch(std.testing.allocator, failing.allocator(), true));
        try std.testing.expect(failing.has_induced_failure);
    }
}

test "transaction command preflight rejects wire limits without publication" {
    var batch: TransactionalBatch = .{};
    defer batch.deinit(std.testing.allocator);

    batch.begin();
    try std.testing.expectError(error.ResourceLimit, batch.preflightAdditional(std.testing.allocator, .{
        .strings = hard_max_string_bytes + 1,
    }));
    batch.abort();
    try std.testing.expectEqual(@as(usize, 0), batch.published.commands.len());
    try std.testing.expectEqual(@as(usize, 0), batch.published.strings.items.len);
    try std.testing.expectEqual(@as(usize, 0), batch.published.dynamic.len());
}

test "transaction command preflight enforces configured limits before allocation" {
    var batch: TransactionalBatch = .{};
    defer batch.deinit(std.testing.allocator);
    try batch.setLimits(.{ .command_records = 2, .string_bytes = 4, .dynamic_bytes = 8 });

    var fault = @import("fault_allocator.zig").FaultAllocator.init(std.testing.allocator);
    fault.configure(1);
    batch.begin();
    try std.testing.expectError(error.ResourceLimit, batch.preflight(fault.allocator(), .{ .commands = 3 }));
    try std.testing.expectEqual(@as(usize, 0), fault.attempts);
    try std.testing.expectEqual(@as(usize, 0), batch.published.commands.len());
    try std.testing.expectEqual(@as(usize, 0), batch.staged.commands.len());

    try std.testing.expectError(error.ResourceLimit, batch.setLimits(.{ .dynamic_bytes = hard_max_dynamic_bytes + 1 }));
    try std.testing.expectEqual(@as(usize, 2), batch.limits.command_records);
}

test "command capacity estimation permits armed allocation-free staging" {
    const FaultAllocator = @import("fault_allocator.zig").FaultAllocator;
    var fault = FaultAllocator.init(std.testing.allocator);
    const allocator = fault.allocator();
    var batch: TransactionalBatch = .{};
    defer batch.deinit(allocator);
    var capacity: BatchCapacity = .{};
    try capacity.addFixed("button".len);
    try capacity.addSetAttrText("data-x".len, "ready".len);
    try capacity.addRemoveAttr("title".len);
    const descriptor = boundary.BoundaryPayloadDescriptor.init(.str, .target_value);
    try capacity.addBindEvent("focus".len, descriptor.extractionBytes().len);
    try capacity.addClearEvent("blur".len);

    batch.begin();
    try batch.preflight(allocator, capacity);
    fault.configure(1);
    try batch.staged.strings.appendSlice(allocator, "button");
    try batch.staged.commands.appendRaw(allocator, .create_element, 1, 0, 0, 0, 0);
    const set_attr = try batch.staged.dynamic.appendSetAttrText(allocator, @enumFromInt(1), "data-x", "ready");
    try batch.staged.commands.appendRaw(allocator, .extended, set_attr.offset.raw(), set_attr.len.raw(), 0, 0, 0);
    const remove_attr = try batch.staged.dynamic.appendRemoveAttr(allocator, @enumFromInt(1), "title");
    try batch.staged.commands.appendRaw(allocator, .extended, remove_attr.offset.raw(), remove_attr.len.raw(), 0, 0, 0);
    const bind = try batch.staged.dynamic.appendBindEvent(allocator, @enumFromInt(1), @enumFromInt(7), "focus", 0, .{
        .requested = .auto,
        .effective = .native,
        .reason = .native_runtime_default,
    }, descriptor);
    try batch.staged.commands.appendRaw(allocator, .extended, bind.offset.raw(), bind.len.raw(), 0, 0, 0);
    const clear = try batch.staged.dynamic.appendClearEvent(allocator, @enumFromInt(1), "blur");
    try batch.staged.commands.appendRaw(allocator, .extended, clear.offset.raw(), clear.len.raw(), 0, 0, 0);
    try std.testing.expectEqual(@as(usize, 0), fault.attempts);
    try std.testing.expectEqual(capacity.commands, batch.staged.commands.len());
    try std.testing.expectEqual(capacity.strings, batch.staged.strings.items.len);
    try std.testing.expectEqual(capacity.dynamic, batch.staged.dynamic.len());
    batch.commit();
    try std.testing.expectEqual(capacity.commands, batch.published.commands.len());
    fault.configure(null);
}

test "prepared command batch sweeps preflight and stages allocation free" {
    const FaultAllocator = @import("fault_allocator.zig").FaultAllocator;
    const descriptor = boundary.BoundaryPayloadDescriptor.init(.str, .target_value);
    var prepared = try PreparedBatch.init(std.testing.allocator, 6);
    defer prepared.deinit(std.testing.allocator);
    try prepared.addSemantic(.{ .set_checked = .{ .elem_id = @enumFromInt(1), .value = true } });
    try prepared.addSemantic(.{ .create_element = .{ .elem_id = @enumFromInt(2), .tag = "button" } });
    try prepared.addSetAttrText(@enumFromInt(2), "data-x", "ready");
    try prepared.addRemoveAttr(@enumFromInt(2), "title");
    try prepared.addBindEvent(.{
        .elem_id = @enumFromInt(2),
        .event_id = @enumFromInt(7),
        .name = "focus",
        .policy = .none,
        .delivery = .{ .requested = .auto, .effective = .native, .reason = .native_runtime_default },
        .payload_descriptor = descriptor,
    });
    try prepared.addClearEvent(@enumFromInt(2), "blur");
    const command_counts = prepared.counts();
    try std.testing.expectEqual(@as(u64, 6), command_counts.total);
    try std.testing.expectEqual(@as(u64, 1), command_counts.create_element);
    try std.testing.expectEqual(@as(u64, 1), command_counts.set_checked);
    try std.testing.expectEqual(@as(u64, 2), command_counts.set_metadata);
    try std.testing.expectEqual(@as(u64, 2), command_counts.bind_event);

    var counter = FaultAllocator.init(std.testing.allocator);
    var counted: TransactionalBatch = .{};
    defer counted.deinit(counter.allocator());
    try prepared.preflight(&counted, counter.allocator());
    const attempts = counter.attempts;
    try std.testing.expect(attempts != 0);
    for (1..attempts + 1) |failure_number| {
        var fault = FaultAllocator.init(std.testing.allocator);
        var batch: TransactionalBatch = .{};
        defer batch.deinit(fault.allocator());
        fault.configure(failure_number);
        try std.testing.expectError(error.OutOfMemory, prepared.preflight(&batch, fault.allocator()));
        try std.testing.expectEqual(@as(usize, 0), batch.published.commands.len());
        try std.testing.expectEqual(@as(usize, 0), batch.staged.commands.len());
        fault.configure(null);
        try prepared.preflight(&batch, fault.allocator());
        fault.configure(1);
        try prepared.stageAssumeCapacity(&batch, fault.allocator());
        try std.testing.expectEqual(@as(usize, 0), fault.attempts);
        try std.testing.expectEqual(prepared.capacity.commands, batch.staged.commands.len());
        batch.commit();
        try std.testing.expectEqual(prepared.capacity.commands, batch.published.commands.len());
    }
}

test "prepared batch preserves undrained publication and reuses drained capacity" {
    const FaultAllocator = @import("fault_allocator.zig").FaultAllocator;
    var prepared = try PreparedBatch.init(std.testing.allocator, 2);
    defer prepared.deinit(std.testing.allocator);
    try prepared.addSemantic(.{ .create_element = .{ .elem_id = @enumFromInt(1), .tag = "section" } });
    try prepared.addSetAttrText(@enumFromInt(1), "data-state", "ready");

    var fault = FaultAllocator.init(std.testing.allocator);
    var batch: TransactionalBatch = .{};
    defer batch.deinit(fault.allocator());
    try prepared.preflight(&batch, fault.allocator());
    try prepared.stageAssumeCapacity(&batch, fault.allocator());
    batch.commit();
    const first_commands_capacity = batch.published.commands.records.capacity;
    const first_commands_ptr = batch.published.commands.records.items.ptr;
    const first_strings_ptr = batch.published.strings.items.ptr;
    const first_dynamic_capacity = batch.published.dynamic.bytes.capacity;
    const first_dynamic_ptr = batch.published.dynamic.bytes.items.ptr;

    try std.testing.expectError(error.ResourceLimit, prepared.preflight(&batch, fault.allocator()));
    try std.testing.expectEqual(@as(usize, 2), batch.published.commands.len());
    try std.testing.expectEqualStrings("section", batch.published.strings.items);

    batch.clearPublished();
    try prepared.preflight(&batch, fault.allocator());
    try prepared.stageAssumeCapacity(&batch, fault.allocator());
    batch.commit();
    batch.clearPublished();
    fault.configure(1);
    try prepared.preflight(&batch, fault.allocator());
    try prepared.stageAssumeCapacity(&batch, fault.allocator());
    batch.commit();
    try std.testing.expectEqual(@as(usize, 0), fault.attempts);
    try std.testing.expectEqual(first_commands_capacity, batch.published.commands.records.capacity);
    try std.testing.expectEqual(first_commands_ptr, batch.published.commands.records.items.ptr);
    try std.testing.expectEqual(first_strings_ptr, batch.published.strings.items.ptr);
    try std.testing.expectEqual(first_dynamic_capacity, batch.published.dynamic.bytes.capacity);
    try std.testing.expectEqual(first_dynamic_ptr, batch.published.dynamic.bytes.items.ptr);
}

test "prepared command journal rejects an underestimated command count" {
    var prepared = try PreparedBatch.init(std.testing.allocator, 1);
    defer prepared.deinit(std.testing.allocator);
    try prepared.addSemantic(.{ .set_checked = .{ .elem_id = @enumFromInt(1), .value = false } });
    const before = prepared.capacity;
    try std.testing.expectError(error.ResourceLimit, prepared.addSemantic(.{ .set_disabled = .{ .elem_id = @enumFromInt(1), .value = false } }));
    try std.testing.expectEqual(@as(usize, 1), prepared.commands.items.len);
    try std.testing.expectEqualDeep(before, prepared.capacity);
}

test "semantic commands lower typed operands into the stable wire layout" {
    var prepared = try PreparedBatch.init(std.testing.allocator, 4);
    defer prepared.deinit(std.testing.allocator);
    const parent = try WireElemId.fromEngine(ids.ElemId.fromRaw(11));
    const child = try WireElemId.fromEngine(ids.ElemId.fromRaw(12));
    const event_id = try WireEventId.fromEngine(ids.EventId.fromRaw(31));
    try prepared.addSemantic(.{ .append_child = .{ .parent = parent, .child = child } });
    try prepared.addSemantic(.{ .set_checked = .{ .elem_id = child, .value = true } });
    try prepared.addSemantic(.{ .bind_fixed = .{ .elem_id = child, .event_id = event_id, .kind = .click } });
    try prepared.addSemantic(.{ .move_before = .{ .parent = parent, .child = child, .before = null } });

    var batch: TransactionalBatch = .{};
    defer batch.deinit(std.testing.allocator);
    try prepared.preflight(&batch, std.testing.allocator);
    try prepared.stageAssumeCapacity(&batch, std.testing.allocator);
    const records = batch.staged.commands.records.items;
    try std.testing.expectEqual(@intFromEnum(Op.append_child), records[0].op);
    try std.testing.expectEqual(@as(u32, 11), records[0].a);
    try std.testing.expectEqual(@as(u32, 12), records[0].b);
    try std.testing.expectEqual(@intFromEnum(Op.set_checked), records[1].op);
    try std.testing.expectEqual(@as(u32, 1), records[1].b);
    try std.testing.expectEqual(@intFromEnum(Op.bind_click), records[2].op);
    try std.testing.expectEqual(@as(u32, 31), records[2].b);
    try std.testing.expectEqual(@intFromEnum(Op.move_before), records[3].op);
    try std.testing.expectEqual(@as(u32, 0), records[3].c);
}

test "wire identities narrow only at the checked protocol boundary" {
    try std.testing.expect(WireElemId != WireEventId);
    try std.testing.expect(WireOffset != WireLength);
    try std.testing.expectEqual(@sizeOf(u32), @sizeOf(WireElemId));
    try std.testing.expectError(error.ResourceLimit, WireElemId.fromEngine(ids.ElemId.fromRaw(@as(u64, std.math.maxInt(u32)) + 1)));
    try std.testing.expectError(error.ResourceLimit, WireEventId.fromEngine(ids.EventId.fromRaw(@as(u64, std.math.maxInt(u32)) + 1)));
}

test "command capacity estimation rejects overflow before allocation" {
    var capacity = BatchCapacity{ .commands = std.math.maxInt(usize) };
    try std.testing.expectError(error.ResourceLimit, capacity.addFixed(0));
    capacity = .{};
    try std.testing.expectError(error.ResourceLimit, capacity.addSetAttrText(std.math.maxInt(usize), 1));
    try std.testing.expectEqualDeep(BatchCapacity{}, capacity);
    capacity = .{ .commands = 7, .strings = 9, .dynamic = std.math.maxInt(usize) };
    const before = capacity;
    try std.testing.expectError(error.ResourceLimit, capacity.add(.{ .commands = 1, .strings = 1, .dynamic = 1 }));
    try std.testing.expectEqualDeep(before, capacity);
    try std.testing.expectEqual(std.math.maxInt(usize) - 3, try checkedAlign4(std.math.maxInt(usize) - 3));
    try std.testing.expectError(error.ResourceLimit, checkedAlign4(std.math.maxInt(usize) - 2));

    var fault = @import("fault_allocator.zig").FaultAllocator.init(std.testing.allocator);
    var dynamic: DynamicBuffer = .{};
    fault.configure(1);
    try std.testing.expectError(error.ResourceLimit, dynamic.appendRecord(fault.allocator(), .remove_attr, std.math.maxInt(usize) - 3));
    try std.testing.expectEqual(@as(usize, 0), fault.attempts);
}

pub const TextField = enum(u64) {
    text = 1,
    role = 2,
    label = 3,
    test_id = 4,
    value = 5,
    class = 6,

    /// Sets op at the narrow host or engine boundary that owns the mutation.
    pub fn setOp(self: TextField) Op {
        return switch (self) {
            .text => .set_text,
            .role => .set_role,
            .label => .set_label,
            .test_id => .set_test_id,
            .value => .set_value,
            .class => .set_class,
        };
    }
};

pub const BoolField = enum(u64) {
    checked = 1,
    disabled = 2,

    /// Sets op at the narrow host or engine boundary that owns the mutation.
    pub fn setOp(self: BoolField) Op {
        return switch (self) {
            .checked => .set_checked,
            .disabled => .set_disabled,
        };
    }
};

pub const EventKind = enum(u64) {
    click = 1,
    input = 2,
    check = 3,
    pointer_down = 4,
    pointer_up = 5,
    pointer_enter = 6,
    pointer_leave = 7,

    /// Selects the canonical bind opcode for a validated event kind.
    pub fn bindOp(self: EventKind) Op {
        return switch (self) {
            .click => .bind_click,
            .input => .bind_input,
            .check => .bind_check,
            .pointer_down => .bind_pointer_down,
            .pointer_up => .bind_pointer_up,
            .pointer_enter => .bind_pointer_enter,
            .pointer_leave => .bind_pointer_leave,
        };
    }

    /// Returns the boundary payload schema encoded by this event command.
    pub fn payloadDescriptor(self: EventKind) boundary.BoundaryPayloadDescriptor {
        return switch (self) {
            .click, .pointer_down, .pointer_up, .pointer_enter, .pointer_leave => boundary.BoundaryPayloadDescriptor.init(.unit, .none),
            .input => boundary.BoundaryPayloadDescriptor.init(.str, .target_value),
            .check => boundary.BoundaryPayloadDescriptor.init(.bool, .target_checked),
        };
    }

    /// Returns the browser event name associated with the canonical binding.
    pub fn domEventName(self: EventKind) []const u8 {
        return switch (self) {
            .click => "click",
            .input => "input",
            .check => "change",
            .pointer_down => "pointerdown",
            .pointer_up => "pointerup",
            .pointer_enter => "pointerenter",
            .pointer_leave => "pointerleave",
        };
    }
};

pub const EventExtractionPlan = boundary.DomEventExtractionPlan;

pub const Counts = struct {
    total: u64 = 0,
    reset_dom: u64 = 0,
    create_element: u64 = 0,
    append_child: u64 = 0,
    remove_node: u64 = 0,
    move_before: u64 = 0,
    set_text: u64 = 0,
    set_value: u64 = 0,
    set_checked: u64 = 0,
    set_disabled: u64 = 0,
    set_metadata: u64 = 0,
    bind_event: u64 = 0,

    /// Appends op to the prepared, unpublished command batch.
    pub fn addOp(self: *Counts, op: Op) void {
        self.total += 1;
        switch (op) {
            .reset_dom => self.reset_dom += 1,
            .create_element, .create_text => self.create_element += 1,
            .append_child => self.append_child += 1,
            .remove_node => self.remove_node += 1,
            .move_before => self.move_before += 1,
            .set_text => self.set_text += 1,
            .set_value => self.set_value += 1,
            .set_checked => self.set_checked += 1,
            .set_disabled => self.set_disabled += 1,
            .set_role, .set_label, .set_test_id, .set_class => self.set_metadata += 1,
            .bind_click, .bind_input, .bind_check, .bind_pointer_down, .bind_pointer_up, .bind_pointer_enter, .bind_pointer_leave => self.bind_event += 1,
            .extended => self.set_metadata += 1,
            // Event-unbinding is counted through `addEventBinding` alongside the
            // bind it supersedes, so the raw wire op never reaches this counter.
            .clear_event => self.bind_event += 1,
            .start_interval, .cancel_interval, .start_task, .cancel_task, .push_state, .replace_state, .set_storage_text, .remove_storage, .set_document_title => {},
        }
    }

    /// Appends host reset to the prepared, unpublished command batch.
    pub fn addHostReset(self: *Counts) void {
        self.addOp(.reset_dom);
    }

    /// Appends create element to the prepared, unpublished command batch.
    pub fn addCreateElement(self: *Counts) void {
        self.addOp(.create_element);
    }

    /// Appends append child to the prepared, unpublished command batch.
    pub fn addAppendChild(self: *Counts) void {
        self.addOp(.append_child);
    }

    /// Appends remove node to the prepared, unpublished command batch.
    pub fn addRemoveNode(self: *Counts) void {
        self.addOp(.remove_node);
    }

    /// Appends move before to the prepared, unpublished command batch.
    pub fn addMoveBefore(self: *Counts) void {
        self.addOp(.move_before);
    }

    /// Appends text field to the prepared, unpublished command batch.
    pub fn addTextField(self: *Counts, field: TextField) void {
        self.addOp(field.setOp());
    }

    /// Appends text attr to the prepared, unpublished command batch.
    pub fn addTextAttr(self: *Counts) void {
        self.addOp(.extended);
    }

    /// Appends bool field to the prepared, unpublished command batch.
    pub fn addBoolField(self: *Counts, field: BoolField) void {
        self.addOp(field.setOp());
    }

    /// Appends event binding to the prepared, unpublished command batch.
    pub fn addEventBinding(self: *Counts) void {
        self.addOp(.bind_click);
    }

    /// Appends event binding kind to the prepared, unpublished command batch.
    pub fn addEventBindingKind(self: *Counts, kind: EventKind) void {
        self.addOp(kind.bindOp());
    }

    /// Appends all to the prepared, unpublished command batch.
    pub fn addAll(self: *Counts, other: Counts) void {
        self.total += other.total;
        self.reset_dom += other.reset_dom;
        self.create_element += other.create_element;
        self.append_child += other.append_child;
        self.remove_node += other.remove_node;
        self.move_before += other.move_before;
        self.set_text += other.set_text;
        self.set_value += other.set_value;
        self.set_checked += other.set_checked;
        self.set_disabled += other.set_disabled;
        self.set_metadata += other.set_metadata;
        self.bind_event += other.bind_event;
    }
};

pub const Metrics = struct {
    patches_emitted: u64 = 0,
    reset_dom: u64 = 0,
    create_element: u64 = 0,
    append_child: u64 = 0,
    remove_node: u64 = 0,
    move_before: u64 = 0,
    set_text: u64 = 0,
    set_value: u64 = 0,
    set_checked: u64 = 0,
    set_disabled: u64 = 0,
    set_metadata: u64 = 0,
    bind_event: u64 = 0,

    /// Appends command counts to the prepared, unpublished command batch.
    pub fn addCommandCounts(self: *Metrics, counts: Counts) void {
        self.patches_emitted += counts.total;
        self.reset_dom += counts.reset_dom;
        self.create_element += counts.create_element;
        self.append_child += counts.append_child;
        self.remove_node += counts.remove_node;
        self.move_before += counts.move_before;
        self.set_text += counts.set_text;
        self.set_value += counts.set_value;
        self.set_checked += counts.set_checked;
        self.set_disabled += counts.set_disabled;
        self.set_metadata += counts.set_metadata;
        self.bind_event += counts.bind_event;
    }
};

test "event policy converts compatibility bits at the wire edge" {
    const bits =
        listener_option_prevent_default |
        listener_option_stop_immediate |
        listener_option_capture |
        listener_option_once |
        listener_option_self |
        listener_option_trusted;
    const policy = EventPolicy.fromBits(bits);

    try std.testing.expect(policy.prevent_default);
    try std.testing.expect(!policy.stop_propagation);
    try std.testing.expect(policy.stop_immediate);
    try std.testing.expect(policy.capture);
    try std.testing.expect(!policy.passive);
    try std.testing.expect(policy.once);
    try std.testing.expect(policy.self);
    try std.testing.expect(policy.trusted);
    try std.testing.expectEqual(@as(u32, bits), policy.toWireBits());
    try std.testing.expect(EventPolicy.none.isNone());
}

test "render command counts group detailed host-independent ops" {
    var counts: Counts = .{};
    counts.addOp(.reset_dom);
    counts.addOp(.create_element);
    counts.addOp(.create_text);
    counts.addOp(.append_child);
    counts.addOp(.remove_node);
    counts.addOp(.move_before);
    counts.addTextField(.text);
    counts.addTextField(.value);
    counts.addTextField(.role);
    counts.addTextField(.label);
    counts.addTextField(.test_id);
    counts.addTextField(.class);
    counts.addBoolField(.checked);
    counts.addBoolField(.disabled);
    counts.addEventBindingKind(.click);
    counts.addEventBindingKind(.input);
    counts.addEventBindingKind(.check);
    counts.addEventBindingKind(.pointer_down);
    counts.addEventBindingKind(.pointer_up);
    counts.addEventBindingKind(.pointer_enter);
    counts.addEventBindingKind(.pointer_leave);
    counts.addOp(.extended);

    try std.testing.expectEqual(@as(u64, 22), counts.total);
    try std.testing.expectEqual(@as(u64, 1), counts.reset_dom);
    try std.testing.expectEqual(@as(u64, 2), counts.create_element);
    try std.testing.expectEqual(@as(u64, 1), counts.append_child);
    try std.testing.expectEqual(@as(u64, 1), counts.remove_node);
    try std.testing.expectEqual(@as(u64, 1), counts.move_before);
    try std.testing.expectEqual(@as(u64, 1), counts.set_text);
    try std.testing.expectEqual(@as(u64, 1), counts.set_value);
    try std.testing.expectEqual(@as(u64, 1), counts.set_checked);
    try std.testing.expectEqual(@as(u64, 1), counts.set_disabled);
    try std.testing.expectEqual(@as(u64, 5), counts.set_metadata);
    try std.testing.expectEqual(@as(u64, 7), counts.bind_event);
}

test "fixed event opcodes declare canonical payload descriptors" {
    try std.testing.expect(EventKind.click.payloadDescriptor().eql(boundary.BoundaryPayloadDescriptor.init(.unit, .none)));
    try std.testing.expect(EventKind.pointer_down.payloadDescriptor().eql(boundary.BoundaryPayloadDescriptor.init(.unit, .none)));
    try std.testing.expect(EventKind.pointer_up.payloadDescriptor().eql(boundary.BoundaryPayloadDescriptor.init(.unit, .none)));
    try std.testing.expect(EventKind.pointer_enter.payloadDescriptor().eql(boundary.BoundaryPayloadDescriptor.init(.unit, .none)));
    try std.testing.expect(EventKind.pointer_leave.payloadDescriptor().eql(boundary.BoundaryPayloadDescriptor.init(.unit, .none)));
    try std.testing.expect(EventKind.input.payloadDescriptor().eql(boundary.BoundaryPayloadDescriptor.init(.str, .target_value)));
    try std.testing.expect(EventKind.check.payloadDescriptor().eql(boundary.BoundaryPayloadDescriptor.init(.bool, .target_checked)));
}

test "fixed event kinds expose browser DOM event names" {
    try std.testing.expectEqualStrings("click", EventKind.click.domEventName());
    try std.testing.expectEqualStrings("input", EventKind.input.domEventName());
    try std.testing.expectEqualStrings("change", EventKind.check.domEventName());
    try std.testing.expectEqualStrings("pointerdown", EventKind.pointer_down.domEventName());
    try std.testing.expectEqualStrings("pointerup", EventKind.pointer_up.domEventName());
    try std.testing.expectEqualStrings("pointerenter", EventKind.pointer_enter.domEventName());
    try std.testing.expectEqualStrings("pointerleave", EventKind.pointer_leave.domEventName());
}

test "render command buffer stores fixed-width records" {
    var buffer: Buffer = .{};
    defer buffer.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), buffer.len());
    try std.testing.expectEqual(@as(usize, 0), buffer.ptrAddress());

    try buffer.appendRaw(std.testing.allocator, .create_element, 7, 2, 0, 0, 0);
    try buffer.appendRaw(std.testing.allocator, .set_text, 7, 1024, 12, 0, 0);

    try std.testing.expectEqual(@as(usize, 2), buffer.len());
    try std.testing.expect(buffer.ptrAddress() != 0);
    try std.testing.expectEqual(@as(usize, 6), Record.word_count);
    try std.testing.expectEqual(@intFromEnum(Op.create_element), buffer.records.items[0].op);
    try std.testing.expectEqual(@as(u32, 7), buffer.records.items[0].a);
    try std.testing.expectEqual(@as(u32, 2), buffer.records.items[0].b);
    try std.testing.expectEqual(@intFromEnum(Op.set_text), buffer.records.items[1].op);
    try std.testing.expectEqual(@as(u32, 1024), buffer.records.items[1].b);
    try std.testing.expectEqual(@as(u32, 12), buffer.records.items[1].c);

    buffer.clearRetainingCapacity();
    try std.testing.expectEqual(@as(usize, 0), buffer.len());
    try std.testing.expectEqual(@as(usize, 0), buffer.ptrAddress());
}

test "dynamic command buffer stores aligned attribute records" {
    var buffer: DynamicBuffer = .{};
    defer buffer.deinit(std.testing.allocator);

    const set_attr = try buffer.appendSetAttrText(std.testing.allocator, @enumFromInt(42), "aria-label", "Save");
    const remove_attr = try buffer.appendRemoveAttr(std.testing.allocator, @enumFromInt(42), "aria-label");

    try std.testing.expectEqual(@as(u32, 0), set_attr.offset.raw());
    try std.testing.expectEqual(@as(u32, 36), set_attr.len.raw());
    try std.testing.expectEqual(@as(u32, 36), remove_attr.offset.raw());
    try std.testing.expectEqual(@as(u32, 28), remove_attr.len.raw());
    try std.testing.expectEqual(@as(usize, 64), buffer.len());
    try std.testing.expect(buffer.ptrAddress() != 0);

    try std.testing.expectEqual(@as(u16, @intFromEnum(DynamicOp.set_attr_text)), std.mem.readInt(u16, buffer.bytes.items[0..2], .little));
    try std.testing.expectEqual(@as(u16, 0), std.mem.readInt(u16, buffer.bytes.items[2..4], .little));
    try std.testing.expectEqual(@as(u32, 26), std.mem.readInt(u32, buffer.bytes.items[4..8], .little));
    try std.testing.expectEqual(@as(u32, 42), std.mem.readInt(u32, buffer.bytes.items[8..12], .little));
    try std.testing.expectEqual(@as(u32, 10), std.mem.readInt(u32, buffer.bytes.items[12..16], .little));
    try std.testing.expectEqualStrings("aria-label", buffer.bytes.items[16..26]);
    try std.testing.expectEqual(@as(u32, 4), std.mem.readInt(u32, buffer.bytes.items[26..30], .little));
    try std.testing.expectEqualStrings("Save", buffer.bytes.items[30..34]);

    buffer.clearRetainingCapacity();
    try std.testing.expectEqual(@as(usize, 0), buffer.len());
    try std.testing.expectEqual(@as(usize, 0), buffer.ptrAddress());
}

test "dynamic command buffer stores event extraction plan" {
    var buffer: DynamicBuffer = .{};
    defer buffer.deinit(std.testing.allocator);

    const descriptor = boundary.BoundaryPayloadDescriptor.init(.bytes, .record_key_shift);
    const bind_event = try buffer.appendBindEvent(
        std.testing.allocator,
        @enumFromInt(42),
        @enumFromInt(99),
        "keydown",
        listener_option_prevent_default | listener_option_stop_propagation,
        .{
            .requested = .auto,
            .effective = .native,
            .reason = .stop_propagation_policy,
        },
        descriptor,
    );

    try std.testing.expectEqual(@as(u32, 0), bind_event.offset.raw());
    try std.testing.expectEqual(@as(u32, 72), bind_event.len.raw());
    try std.testing.expectEqual(@as(usize, 72), buffer.len());
    try std.testing.expectEqual(@as(u16, @intFromEnum(DynamicOp.bind_event)), std.mem.readInt(u16, buffer.bytes.items[0..2], .little));
    try std.testing.expectEqual(@as(u16, 0), std.mem.readInt(u16, buffer.bytes.items[2..4], .little));
    try std.testing.expectEqual(@as(u32, 61), std.mem.readInt(u32, buffer.bytes.items[4..8], .little));

    var cursor: usize = 8;
    try std.testing.expectEqual(@as(u32, 42), readTestU32(buffer.bytes.items, &cursor));
    try std.testing.expectEqual(@as(u32, 99), readTestU32(buffer.bytes.items, &cursor));

    const name_len = readTestU32(buffer.bytes.items, &cursor);
    const name_len_usize: usize = @intCast(name_len);
    try std.testing.expectEqual(@as(u32, 7), name_len);
    try std.testing.expectEqualStrings("keydown", buffer.bytes.items[cursor..][0..name_len_usize]);
    cursor += name_len_usize;

    try std.testing.expectEqual(@as(u32, listener_option_prevent_default | listener_option_stop_propagation), readTestU32(buffer.bytes.items, &cursor));
    try std.testing.expectEqual(@as(u32, @intFromEnum(EventDeliveryRequestWire.auto)), readTestU32(buffer.bytes.items, &cursor));
    try std.testing.expectEqual(@as(u32, @intFromEnum(EventDeliveryEffectiveWire.native)), readTestU32(buffer.bytes.items, &cursor));
    try std.testing.expectEqual(@as(u32, @intFromEnum(EventDeliveryReasonWire.stop_propagation_policy)), readTestU32(buffer.bytes.items, &cursor));

    const extraction_len = readTestU32(buffer.bytes.items, &cursor);
    const extraction_len_usize: usize = @intCast(extraction_len);
    try std.testing.expectEqual(@as(u32, @intCast(descriptor.extractionBytes().len)), extraction_len);
    try std.testing.expectEqualSlices(u8, descriptor.extractionBytes(), buffer.bytes.items[cursor..][0..extraction_len_usize]);
    cursor += extraction_len_usize;

    try std.testing.expectEqual(@as(usize, 69), cursor);
    try std.testing.expectEqual(@as(u8, 0), buffer.bytes.items[cursor]);
}

test "render metrics accumulate command counts" {
    var metrics: Metrics = .{};
    var counts: Counts = .{};
    counts.addOp(.append_child);
    counts.addOp(.move_before);
    counts.addOp(.set_label);
    counts.addOp(.bind_input);

    metrics.addCommandCounts(counts);

    try std.testing.expectEqual(@as(u64, 4), metrics.patches_emitted);
    try std.testing.expectEqual(@as(u64, 1), metrics.append_child);
    try std.testing.expectEqual(@as(u64, 1), metrics.move_before);
    try std.testing.expectEqual(@as(u64, 1), metrics.set_metadata);
    try std.testing.expectEqual(@as(u64, 1), metrics.bind_event);
}

fn readTestU32(bytes: []const u8, cursor: *usize) u32 {
    const value = std.mem.readInt(u32, bytes[cursor.*..][0..@sizeOf(u32)], .little);
    cursor.* += @sizeOf(u32);
    return value;
}
