//! Host-independent render command protocol and command-buffer encoders.

const std = @import("std");
const boundary = @import("boundary.zig");

pub const protocol_version: u32 = 7;
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

    pub fn fromBits(bits: u64) EventPolicy {
        const bits_u32 = std.math.cast(u32, bits) orelse std.debug.panic(
            "event listener options exceeded u32 range: {}",
            .{bits},
        );
        return fromWireBits(bits_u32);
    }

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

    pub fn init(op: Op, a: u32, b: u32, c: u32, d: u32, e: u32) Record {
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

pub const Buffer = struct {
    records: std.ArrayListUnmanaged(Record) = .empty,

    pub fn deinit(self: *Buffer, allocator: std.mem.Allocator) void {
        self.records.deinit(allocator);
        self.* = .{};
    }

    pub fn clearRetainingCapacity(self: *Buffer) void {
        self.records.clearRetainingCapacity();
    }

    pub fn len(self: *const Buffer) usize {
        return self.records.items.len;
    }

    pub fn ptrAddress(self: *const Buffer) usize {
        if (self.records.items.len == 0) return 0;
        return @intFromPtr(self.records.items.ptr);
    }

    pub fn append(self: *Buffer, allocator: std.mem.Allocator, op: Op, a: u32, b: u32, c: u32, d: u32, e: u32) std.mem.Allocator.Error!void {
        try self.records.append(allocator, Record.init(op, a, b, c, d, e));
    }
};

pub const DynamicSlice = struct {
    offset: u32,
    len: u32,
};

pub const DynamicBuffer = struct {
    bytes: std.ArrayListUnmanaged(u8) = .empty,

    pub fn deinit(self: *DynamicBuffer, allocator: std.mem.Allocator) void {
        self.bytes.deinit(allocator);
        self.* = .{};
    }

    pub fn clearRetainingCapacity(self: *DynamicBuffer) void {
        self.bytes.clearRetainingCapacity();
    }

    pub fn len(self: *const DynamicBuffer) usize {
        return self.bytes.items.len;
    }

    pub fn ptrAddress(self: *const DynamicBuffer) usize {
        if (self.bytes.items.len == 0) return 0;
        return @intFromPtr(self.bytes.items.ptr);
    }

    pub fn appendSetAttrText(self: *DynamicBuffer, allocator: std.mem.Allocator, elem_id: u32, name: []const u8, value: []const u8) std.mem.Allocator.Error!DynamicSlice {
        const payload_len = @sizeOf(u32) + @sizeOf(u32) + name.len + @sizeOf(u32) + value.len;
        const record = try self.appendRecord(allocator, .set_attr_text, payload_len);
        var cursor = record.payload_start;
        writeU32(self.bytes.items, &cursor, elem_id);
        writeU32(self.bytes.items, &cursor, @intCast(name.len));
        writeBytes(self.bytes.items, &cursor, name);
        writeU32(self.bytes.items, &cursor, @intCast(value.len));
        writeBytes(self.bytes.items, &cursor, value);
        return record.slice;
    }

    pub fn appendRemoveAttr(self: *DynamicBuffer, allocator: std.mem.Allocator, elem_id: u32, name: []const u8) std.mem.Allocator.Error!DynamicSlice {
        const payload_len = @sizeOf(u32) + @sizeOf(u32) + name.len;
        const record = try self.appendRecord(allocator, .remove_attr, payload_len);
        var cursor = record.payload_start;
        writeU32(self.bytes.items, &cursor, elem_id);
        writeU32(self.bytes.items, &cursor, @intCast(name.len));
        writeBytes(self.bytes.items, &cursor, name);
        return record.slice;
    }

    pub fn appendBindEvent(
        self: *DynamicBuffer,
        allocator: std.mem.Allocator,
        elem_id: u32,
        event_id: u32,
        event_name: []const u8,
        options: u32,
        delivery: EventDeliveryWire,
        payload_descriptor: boundary.BoundaryPayloadDescriptor,
    ) std.mem.Allocator.Error!DynamicSlice {
        const event_extraction_plan = payload_descriptor.extractionBytes();
        const payload_len = @sizeOf(u32) + @sizeOf(u32) + @sizeOf(u32) + event_name.len + @sizeOf(u32) + (3 * @sizeOf(u32)) + @sizeOf(u32) + event_extraction_plan.len;
        const record = try self.appendRecord(allocator, .bind_event, payload_len);
        var cursor = record.payload_start;
        writeU32(self.bytes.items, &cursor, elem_id);
        writeU32(self.bytes.items, &cursor, event_id);
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

    pub fn appendClearEvent(self: *DynamicBuffer, allocator: std.mem.Allocator, elem_id: u32, event_name: []const u8) std.mem.Allocator.Error!DynamicSlice {
        const payload_len = @sizeOf(u32) + @sizeOf(u32) + event_name.len;
        const record = try self.appendRecord(allocator, .clear_event, payload_len);
        var cursor = record.payload_start;
        writeU32(self.bytes.items, &cursor, elem_id);
        writeU32(self.bytes.items, &cursor, @intCast(event_name.len));
        writeBytes(self.bytes.items, &cursor, event_name);
        return record.slice;
    }

    const AppendedRecord = struct {
        slice: DynamicSlice,
        payload_start: usize,
    };

    fn appendRecord(self: *DynamicBuffer, allocator: std.mem.Allocator, op: DynamicOp, payload_len: usize) std.mem.Allocator.Error!AppendedRecord {
        const offset = self.bytes.items.len;
        const total_len = @sizeOf(u16) + @sizeOf(u16) + @sizeOf(u32) + align4(payload_len);
        try self.bytes.resize(allocator, offset + total_len);
        @memset(self.bytes.items[offset..][0..total_len], 0);

        var cursor = offset;
        writeU16(self.bytes.items, &cursor, @intFromEnum(op));
        writeU16(self.bytes.items, &cursor, 0);
        writeU32(self.bytes.items, &cursor, @intCast(payload_len));

        return .{
            .slice = .{
                .offset = @intCast(offset),
                .len = @intCast(total_len),
            },
            .payload_start = cursor,
        };
    }
};

pub fn align4(len: usize) usize {
    return (len + 3) & ~@as(usize, 3);
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

pub const TextField = enum(u64) {
    text = 1,
    role = 2,
    label = 3,
    test_id = 4,
    value = 5,
    class = 6,

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

    pub fn payloadDescriptor(self: EventKind) boundary.BoundaryPayloadDescriptor {
        return switch (self) {
            .click, .pointer_down, .pointer_up, .pointer_enter, .pointer_leave => boundary.BoundaryPayloadDescriptor.init(.unit, .none),
            .input => boundary.BoundaryPayloadDescriptor.init(.str, .target_value),
            .check => boundary.BoundaryPayloadDescriptor.init(.bool, .target_checked),
        };
    }

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
            .start_interval, .cancel_interval, .start_task, .cancel_task => {},
        }
    }

    pub fn addHostReset(self: *Counts) void {
        self.addOp(.reset_dom);
    }

    pub fn addCreateElement(self: *Counts) void {
        self.addOp(.create_element);
    }

    pub fn addAppendChild(self: *Counts) void {
        self.addOp(.append_child);
    }

    pub fn addRemoveNode(self: *Counts) void {
        self.addOp(.remove_node);
    }

    pub fn addMoveBefore(self: *Counts) void {
        self.addOp(.move_before);
    }

    pub fn addTextField(self: *Counts, field: TextField) void {
        self.addOp(field.setOp());
    }

    pub fn addTextAttr(self: *Counts) void {
        self.addOp(.extended);
    }

    pub fn addBoolField(self: *Counts, field: BoolField) void {
        self.addOp(field.setOp());
    }

    pub fn addEventBinding(self: *Counts) void {
        self.addOp(.bind_click);
    }

    pub fn addEventBindingKind(self: *Counts, kind: EventKind) void {
        self.addOp(kind.bindOp());
    }

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

    try buffer.append(std.testing.allocator, .create_element, 7, 2, 0, 0, 0);
    try buffer.append(std.testing.allocator, .set_text, 7, 1024, 12, 0, 0);

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

    const set_attr = try buffer.appendSetAttrText(std.testing.allocator, 42, "aria-label", "Save");
    const remove_attr = try buffer.appendRemoveAttr(std.testing.allocator, 42, "aria-label");

    try std.testing.expectEqual(@as(u32, 0), set_attr.offset);
    try std.testing.expectEqual(@as(u32, 36), set_attr.len);
    try std.testing.expectEqual(@as(u32, 36), remove_attr.offset);
    try std.testing.expectEqual(@as(u32, 28), remove_attr.len);
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
        42,
        99,
        "keydown",
        listener_option_prevent_default | listener_option_stop_propagation,
        .{
            .requested = .auto,
            .effective = .native,
            .reason = .stop_propagation_policy,
        },
        descriptor,
    );

    try std.testing.expectEqual(@as(u32, 0), bind_event.offset);
    try std.testing.expectEqual(@as(u32, 72), bind_event.len);
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
