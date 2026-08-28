//! Simulated DOM tree used by native specs and benchmark execution.

const std = @import("std");

const signals = @import("signals");
const boundary = signals.boundary;
const render = signals.render;
const render_sink = signals.render_sink;
const ids = signals.ids;
const spec_parser = @import("spec/spec_parser.zig");

pub const EventBinding = render_sink.EventBinding;

pub const FixedEventBindings = struct {
    click: ?EventBinding = null,
    input: ?EventBinding = null,
    check: ?EventBinding = null,
    pointer_down: ?EventBinding = null,
    pointer_up: ?EventBinding = null,
    pointer_enter: ?EventBinding = null,
    pointer_leave: ?EventBinding = null,
};

pub const Element = struct {
    id: u64,
    tag: []const u8,
    role: ?[]const u8,
    label: ?[]const u8,
    test_id: ?[]const u8,
    class: ?[]const u8,
    text: ?[]const u8,
    value: ?[]const u8,
    pending_value: ?[]const u8,
    focused: bool,
    composing: bool,
    checked: bool,
    disabled: bool,
    parent_id: ?u64,
    children: std.ArrayListUnmanaged(u64),
    event_bindings: FixedEventBindings,
    active: bool,
    text_update_count: u64,
    value_update_count: u64,
    checked_update_count: u64,
    disabled_update_count: u64,
    attrs: std.ArrayListUnmanaged(TextAttr),
    named_events: std.ArrayListUnmanaged(NamedEvent),

    /// Creates an initialized value with the ownership and capacity invariants required by this module.
    pub fn init(id: u64, tag: []const u8) Element {
        return .{
            .id = id,
            .tag = tag,
            .role = null,
            .label = null,
            .test_id = null,
            .class = null,
            .text = null,
            .value = null,
            .pending_value = null,
            .focused = false,
            .composing = false,
            .checked = false,
            .disabled = false,
            .parent_id = null,
            .children = .empty,
            .event_bindings = .{},
            .active = true,
            .text_update_count = 0,
            .value_update_count = 0,
            .checked_update_count = 0,
            .disabled_update_count = 0,
            .attrs = .empty,
            .named_events = .empty,
        };
    }

    /// Releases every resource owned by this value and leaves no retained host or Roc ownership behind.
    pub fn deinit(self: *Element, allocator: std.mem.Allocator) void {
        allocator.free(self.tag);
        if (self.role) |role| allocator.free(role);
        if (self.label) |label| allocator.free(label);
        if (self.test_id) |test_id| allocator.free(test_id);
        if (self.class) |class| allocator.free(class);
        if (self.text) |text| allocator.free(text);
        if (self.value) |value| allocator.free(value);
        if (self.pending_value) |pending_value| allocator.free(pending_value);
        for (self.attrs.items) |attr| {
            attr.deinit(allocator);
        }
        self.attrs.deinit(allocator);
        for (self.named_events.items) |event| {
            event.deinit(allocator);
        }
        self.named_events.deinit(allocator);
        self.children.deinit(allocator);
    }

    /// Creates a fully independent element snapshot for transactional host publication.
    pub fn cloneOwned(self: *const Element, allocator: std.mem.Allocator) std.mem.Allocator.Error!Element {
        const tag = try allocator.dupe(u8, self.tag);
        var cloned = Element.init(self.id, tag);
        errdefer cloned.deinit(allocator);
        cloned.active = self.active;
        cloned.focused = self.focused;
        cloned.composing = self.composing;
        cloned.checked = self.checked;
        cloned.disabled = self.disabled;
        cloned.parent_id = self.parent_id;
        cloned.event_bindings = self.event_bindings;
        cloned.text_update_count = self.text_update_count;
        cloned.value_update_count = self.value_update_count;
        cloned.checked_update_count = self.checked_update_count;
        cloned.disabled_update_count = self.disabled_update_count;
        inline for (.{ "role", "label", "test_id", "class", "text", "value", "pending_value" }) |field_name| {
            if (@field(self, field_name)) |value| @field(cloned, field_name) = try allocator.dupe(u8, value);
        }
        try cloned.children.appendSlice(allocator, self.children.items);
        try cloned.attrs.ensureTotalCapacity(allocator, self.attrs.items.len);
        for (self.attrs.items) |attr| {
            const name = try allocator.dupe(u8, attr.name);
            errdefer allocator.free(name);
            const value = try allocator.dupe(u8, attr.value);
            cloned.attrs.appendAssumeCapacity(.{ .name = name, .value = value });
        }
        try cloned.named_events.ensureTotalCapacity(allocator, self.named_events.items.len);
        for (self.named_events.items) |event| {
            const name = try allocator.dupe(u8, event.name);
            cloned.named_events.appendAssumeCapacity(.{ .name = name, .binding = event.binding });
        }
        return cloned;
    }

    /// Resolves a text attribute by name in the simulated DOM element.
    pub fn textAttrIndex(self: *const Element, name: []const u8) ?usize {
        for (self.attrs.items, 0..) |attr, index| {
            if (std.mem.eql(u8, attr.name, name)) return index;
        }
        return null;
    }

    /// Resolves a named event to its cache entry without scanning unrelated bindings.
    pub fn namedEventIndex(self: *const Element, name: []const u8) ?usize {
        for (self.named_events.items, 0..) |event, index| {
            if (std.mem.eql(u8, event.name, name)) return index;
        }
        return null;
    }
};

pub const TextAttr = struct {
    name: []const u8,
    value: []const u8,

    /// Releases every resource owned by this value and leaves no retained host or Roc ownership behind.
    pub fn deinit(self: TextAttr, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.value);
    }
};

pub const NamedEvent = struct {
    name: []const u8,
    binding: EventBinding,

    /// Releases every resource owned by this value and leaves no retained host or Roc ownership behind.
    pub fn deinit(self: NamedEvent, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
    }
};

/// Owns only the native DOM slots touched by one render transaction.
pub const PreparedPublication = struct {
    const Slot = union(enum) { existing: usize, appended: usize };

    allocator: std.mem.Allocator,
    original_len: usize,
    existing: std.ArrayListUnmanaged(Element) = .empty,
    existing_ids: std.ArrayListUnmanaged(u64) = .empty,
    appended: std.ArrayListUnmanaged(Element) = .empty,
    indexes: std.AutoHashMapUnmanaged(u64, Slot) = .empty,
    committed: bool = false,

    /// Clones touched active slots and prepares owned inactive sparse slots.
    pub fn init(allocator: std.mem.Allocator, elements: *std.ArrayListUnmanaged(Element), touched_ids: []const u64, max_elem_id: u64) (std.mem.Allocator.Error || error{ DuplicateNode, ResourceLimit })!PreparedPublication {
        var self = PreparedPublication{ .allocator = allocator, .original_len = elements.items.len };
        errdefer self.deinit();
        try elements.ensureTotalCapacity(allocator, std.math.add(usize, std.math.cast(usize, max_elem_id) orelse return error.ResourceLimit, 1) catch return error.ResourceLimit);
        try self.existing.ensureTotalCapacity(allocator, touched_ids.len);
        try self.existing_ids.ensureTotalCapacity(allocator, touched_ids.len);
        try self.indexes.ensureUnusedCapacity(allocator, std.math.cast(u32, touched_ids.len) orelse return error.ResourceLimit);
        const required_len = std.math.add(usize, std.math.cast(usize, max_elem_id) orelse return error.ResourceLimit, 1) catch return error.ResourceLimit;
        const append_count = required_len -| elements.items.len;
        try self.appended.ensureTotalCapacity(allocator, append_count);
        for (elements.items.len..elements.items.len + append_count) |index| {
            var inactive = Element.init(index, try allocator.dupe(u8, ""));
            inactive.active = false;
            self.appended.appendAssumeCapacity(inactive);
        }
        for (touched_ids) |elem_id| {
            if (self.indexes.contains(elem_id)) return error.DuplicateNode;
            const index = std.math.cast(usize, elem_id) orelse return error.ResourceLimit;
            if (index >= required_len) return error.ResourceLimit;
            const slot: Slot = if (index < elements.items.len) blk: {
                const owned = try elements.items[index].cloneOwned(allocator);
                self.existing.appendAssumeCapacity(owned);
                self.existing_ids.appendAssumeCapacity(elem_id);
                break :blk .{ .existing = self.existing.items.len - 1 };
            } else .{ .appended = index - elements.items.len };
            self.indexes.putAssumeCapacity(elem_id, slot);
        }
        return self;
    }

    /// Returns the owned provisional slot for an active or fresh sparse id.
    pub fn node(self: *PreparedPublication, elem_id: u64) ?*Element {
        const slot = self.indexes.get(elem_id) orelse return null;
        return switch (slot) {
            .existing => |index| &self.existing.items[index],
            .appended => |index| &self.appended.items[index],
        };
    }

    /// Atomically swaps existing slots and appends every prebuilt sparse slot.
    pub fn apply(self: *PreparedPublication, elements: *std.ArrayListUnmanaged(Element)) void {
        if (self.committed or elements.items.len != self.original_len) @panic("native DOM publication contract violated");
        for (self.existing.items, self.existing_ids.items) |*next, elem_id| std.mem.swap(Element, next, &elements.items[@intCast(elem_id)]);
        for (self.appended.items) |next| elements.appendAssumeCapacity(next);
        self.appended.items.len = 0;
        self.committed = true;
    }

    /// Releases provisional slots on abort or displaced slots after commit.
    pub fn deinit(self: *PreparedPublication) void {
        for (self.existing.items) |*elem| elem.deinit(self.allocator);
        self.existing.deinit(self.allocator);
        self.existing_ids.deinit(self.allocator);
        for (self.appended.items) |*elem| elem.deinit(self.allocator);
        self.appended.deinit(self.allocator);
        self.indexes.deinit(self.allocator);
        self.* = undefined;
    }
};

/// Derives the limited implicit ARIA role vocabulary supported by semantic specs.
pub fn implicitRole(elem: *const Element) ?[]const u8 {
    if (elem.role) |role| return role;
    if (std.mem.eql(u8, elem.tag, "button")) return "button";
    if (std.mem.eql(u8, elem.tag, "a")) return "link";
    if (std.mem.eql(u8, elem.tag, "h1") or
        std.mem.eql(u8, elem.tag, "h2") or
        std.mem.eql(u8, elem.tag, "h3") or
        std.mem.eql(u8, elem.tag, "h4") or
        std.mem.eql(u8, elem.tag, "h5") or
        std.mem.eql(u8, elem.tag, "h6")) return "heading";
    if (std.mem.eql(u8, elem.tag, "section")) return "region";
    return null;
}

/// Computes the semantic accessible name used by stable spec locators.
pub fn accessibleName(elem: *const Element) []const u8 {
    if (elem.label) |label| return label;
    if (elem.text) |text| return text;
    if (elem.value) |value| return value;
    return "";
}

/// Matches an element against a semantic locator rather than a positional DOM index.
pub fn matchesLocator(elem: *const Element, locator: spec_parser.Locator) bool {
    return matchesLocatorWithAccessibleName(elem, locator, accessibleName(elem));
}

/// Matches an element against a semantic locator rather than a positional DOM index.
pub fn matchesLocatorWithAccessibleName(elem: *const Element, locator: spec_parser.Locator, accessible_name: []const u8) bool {
    return switch (locator.kind) {
        .none => false,
        .role_name => blk: {
            const role = implicitRole(elem) orelse break :blk false;
            const expected_role = locator.role orelse break :blk false;
            const expected_name = locator.name orelse break :blk false;
            break :blk std.mem.eql(u8, role, expected_role) and std.mem.eql(u8, accessible_name, expected_name);
        },
        .label => blk: {
            const expected = locator.label orelse break :blk false;
            const label = elem.label orelse break :blk false;
            break :blk std.mem.eql(u8, label, expected);
        },
        .text => blk: {
            const expected = locator.text orelse break :blk false;
            const text = elem.text orelse break :blk false;
            break :blk std.mem.eql(u8, text, expected);
        },
        .test_id => blk: {
            const expected = locator.test_id orelse break :blk false;
            const test_id = elem.test_id orelse break :blk false;
            break :blk std.mem.eql(u8, test_id, expected);
        },
    };
}

fn replaceOwnedString(allocator: std.mem.Allocator, field: *?[]const u8, value: []const u8) bool {
    if (field.*) |existing| {
        if (std.mem.eql(u8, existing, value)) return false;
        allocator.free(existing);
    }
    field.* = allocator.dupe(u8, value) catch std.process.exit(1);
    return true;
}

/// Sets owned string at the narrow host or engine boundary that owns the mutation.
pub fn setOwnedString(allocator: std.mem.Allocator, field: *?[]const u8, value: []const u8) void {
    if (field.*) |existing| {
        allocator.free(existing);
    }
    field.* = allocator.dupe(u8, value) catch std.process.exit(1);
}

/// Clears owned string while retaining bounded storage where the type promises reuse.
pub fn clearOwnedString(allocator: std.mem.Allocator, field: *?[]const u8) void {
    if (field.*) |existing| {
        allocator.free(existing);
    }
    field.* = null;
}

/// Sets text at the narrow host or engine boundary that owns the mutation.
pub fn setText(allocator: std.mem.Allocator, elem: *Element, text: []const u8) void {
    setOwnedString(allocator, &elem.text, text);
    elem.text_update_count += 1;
}

/// Sets value if changed at the narrow host or engine boundary that owns the mutation.
pub fn setValueIfChanged(allocator: std.mem.Allocator, elem: *Element, value: []const u8) bool {
    if (replaceOwnedString(allocator, &elem.value, value)) {
        elem.value_update_count += 1;
        return true;
    }
    return false;
}

/// Sets value at the narrow host or engine boundary that owns the mutation.
pub fn setValue(allocator: std.mem.Allocator, elem: *Element, value: []const u8) void {
    setOwnedString(allocator, &elem.value, value);
    elem.value_update_count += 1;
}

fn clearPendingValue(allocator: std.mem.Allocator, elem: *Element) void {
    if (elem.pending_value) |pending| {
        allocator.free(pending);
        elem.pending_value = null;
    }
}

fn replacePendingValue(allocator: std.mem.Allocator, elem: *Element, value: []const u8) void {
    clearPendingValue(allocator, elem);
    elem.pending_value = allocator.dupe(u8, value) catch std.process.exit(1);
}

/// Sets user value if changed at the narrow host or engine boundary that owns the mutation.
pub fn setUserValueIfChanged(allocator: std.mem.Allocator, elem: *Element, value: []const u8) bool {
    const changed = setValueIfChanged(allocator, elem, value);
    if (elem.pending_value) |pending| {
        if (std.mem.eql(u8, pending, elem.value orelse "")) {
            clearPendingValue(allocator, elem);
        }
    }
    return changed;
}

/// Sets controlled value at the narrow host or engine boundary that owns the mutation.
pub fn setControlledValue(allocator: std.mem.Allocator, elem: *Element, value: []const u8) bool {
    if (elem.value) |existing| {
        if (std.mem.eql(u8, existing, value)) {
            clearPendingValue(allocator, elem);
            return false;
        }
    }

    if (elem.composing or elem.focused) {
        replacePendingValue(allocator, elem, value);
        return false;
    }

    clearPendingValue(allocator, elem);
    setValue(allocator, elem, value);
    return true;
}

/// Marks the controlled element focused so conflicting value writes can be deferred safely.
pub fn focusElement(elem: *Element) void {
    elem.focused = true;
}

/// Ends controlled-element focus and applies any still-relevant deferred value.
pub fn blurElement(allocator: std.mem.Allocator, elem: *Element) bool {
    elem.focused = false;
    return flushPendingControlledValue(allocator, elem);
}

/// Marks the controlled input as composing so engine writes do not disrupt IME text.
pub fn beginComposition(elem: *Element) void {
    elem.composing = true;
}

/// Ends IME composition and reconciles the latest engine-selected value.
pub fn endComposition(allocator: std.mem.Allocator, elem: *Element) bool {
    elem.composing = false;
    return flushPendingControlledValue(allocator, elem);
}

/// Applies the latest deferred controlled value after focus or composition no longer blocks it.
pub fn flushPendingControlledValue(allocator: std.mem.Allocator, elem: *Element) bool {
    const pending = elem.pending_value orelse return false;

    if (elem.value) |existing| {
        if (std.mem.eql(u8, existing, pending)) {
            clearPendingValue(allocator, elem);
            return false;
        }
    }

    if (elem.composing or elem.focused) {
        return false;
    }

    const pending_copy = allocator.dupe(u8, pending) catch std.process.exit(1);
    defer allocator.free(pending_copy);
    clearPendingValue(allocator, elem);
    setValue(allocator, elem, pending_copy);
    return true;
}

/// Clears text while retaining bounded storage where the type promises reuse.
pub fn clearText(allocator: std.mem.Allocator, elem: *Element) void {
    clearOwnedString(allocator, &elem.text);
    elem.text_update_count += 1;
}

/// Clears value while retaining bounded storage where the type promises reuse.
pub fn clearValue(allocator: std.mem.Allocator, elem: *Element) void {
    clearOwnedString(allocator, &elem.value);
    elem.value_update_count += 1;
}

/// Sets text attr at the narrow host or engine boundary that owns the mutation.
pub fn setTextAttr(allocator: std.mem.Allocator, elem: *Element, name: []const u8, value: []const u8) void {
    if (elem.textAttrIndex(name)) |index| {
        const attr = &elem.attrs.items[index];
        allocator.free(attr.value);
        attr.value = allocator.dupe(u8, value) catch std.process.exit(1);
        return;
    }

    const name_copy = allocator.dupe(u8, name) catch std.process.exit(1);
    const value_copy = allocator.dupe(u8, value) catch {
        allocator.free(name_copy);
        std.process.exit(1);
    };
    elem.attrs.append(allocator, .{
        .name = name_copy,
        .value = value_copy,
    }) catch {
        allocator.free(name_copy);
        allocator.free(value_copy);
        std.process.exit(1);
    };
}

/// Clears an engine-decided custom text attribute from one render node.
pub fn clearTextAttr(allocator: std.mem.Allocator, elem: *Element, name: []const u8) void {
    const index = elem.textAttrIndex(name) orelse return;
    const removed = elem.attrs.orderedRemove(index);
    removed.deinit(allocator);
}

/// Returns a simulated element's text attribute by name.
pub fn textAttr(elem: *const Element, name: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, name, "class")) return elem.class;
    if (std.mem.eql(u8, name, "role")) return elem.role;
    if (std.mem.eql(u8, name, "aria-label")) return elem.label;
    if (std.mem.eql(u8, name, "data-testid")) return elem.test_id;
    const index = elem.textAttrIndex(name) orelse return null;
    return elem.attrs.items[index].value;
}

/// Sets checked if changed at the narrow host or engine boundary that owns the mutation.
pub fn setCheckedIfChanged(elem: *Element, checked: bool) bool {
    if (elem.checked != checked) {
        elem.checked = checked;
        elem.checked_update_count += 1;
        return true;
    }
    return false;
}

/// Sets checked at the narrow host or engine boundary that owns the mutation.
pub fn setChecked(elem: *Element, checked: bool) void {
    elem.checked = checked;
    elem.checked_update_count += 1;
}

/// Sets disabled at the narrow host or engine boundary that owns the mutation.
pub fn setDisabled(elem: *Element, disabled: bool) void {
    elem.disabled = disabled;
    elem.disabled_update_count += 1;
}

/// Returns a child's local index under its parent in the simulated DOM.
pub fn childIndex(elem: *const Element, child_id: u64) ?usize {
    for (elem.children.items, 0..) |id, index| {
        if (id == child_id) return index;
    }
    return null;
}

/// Returns the canonical named-event binding used by the spec or simulated DOM.
pub fn namedEvent(elem: *const Element, name: []const u8) ?NamedEvent {
    const index = elem.namedEventIndex(name) orelse return null;
    return elem.named_events.items[index];
}

/// Returns the canonical fixed-event binding stored in the simulated element.
pub fn fixedEventBindingSlot(bindings: *FixedEventBindings, kind: render.EventKind) *?EventBinding {
    return switch (kind) {
        .click => &bindings.click,
        .input => &bindings.input,
        .check => &bindings.check,
        .pointer_down => &bindings.pointer_down,
        .pointer_up => &bindings.pointer_up,
        .pointer_enter => &bindings.pointer_enter,
        .pointer_leave => &bindings.pointer_leave,
    };
}

/// Returns the canonical fixed-event binding stored in the simulated element.
pub fn fixedEventBinding(elem: *const Element, kind: render.EventKind) ?EventBinding {
    return switch (kind) {
        .click => elem.event_bindings.click,
        .input => elem.event_bindings.input,
        .check => elem.event_bindings.check,
        .pointer_down => elem.event_bindings.pointer_down,
        .pointer_up => elem.event_bindings.pointer_up,
        .pointer_enter => elem.event_bindings.pointer_enter,
        .pointer_leave => elem.event_bindings.pointer_leave,
    };
}

/// Returns the dense id of the selected fixed event binding for spec dispatch.
pub fn fixedEventId(elem: *const Element, kind: render.EventKind) ?u64 {
    const binding = fixedEventBinding(elem, kind) orelse return null;
    return binding.event_id.raw();
}

/// Installs a canonical event binding in the simulated DOM without owning dispatch semantics.
pub fn bindEventKind(elem: *Element, kind: render.EventKind, binding: EventBinding) void {
    if (!binding.policy.isNone()) @panic("fixed simulated DOM event binding carried listener policy");
    fixedEventBindingSlot(&elem.event_bindings, kind).* = binding;
}

/// Clears event kind while retaining bounded storage where the type promises reuse.
pub fn clearEventKind(elem: *Element, kind: render.EventKind) void {
    fixedEventBindingSlot(&elem.event_bindings, kind).* = null;
}

/// Publishes a validated canonical event binding selected by the engine.
pub fn bindEvent(allocator: std.mem.Allocator, elem: *Element, key: render_sink.EventBindingKey, binding: EventBinding) void {
    switch (key) {
        .fixed => |kind| bindEventKind(elem, kind, binding),
        .named => |name| bindEventNameBinding(allocator, elem, name, binding),
    }
}

/// Removes a host event registration whose engine-owned binding is no longer active.
pub fn clearEvent(allocator: std.mem.Allocator, elem: *Element, key: render_sink.EventBindingKey) void {
    switch (key) {
        .fixed => |kind| clearEventKind(elem, kind),
        .named => |name| clearEventName(allocator, elem, name),
    }
}

/// Installs a canonical event binding in the simulated DOM without owning dispatch semantics.
pub fn bindEventName(allocator: std.mem.Allocator, elem: *Element, name: []const u8, event_id: u64, policy: render.EventPolicy, payload_descriptor: boundary.BoundaryPayloadDescriptor) void {
    var binding: EventBinding = .{
        .event_id = ids.EventId.fromRaw(event_id),
        .policy = policy,
        .payload_descriptor = payload_descriptor,
    };
    binding = binding.withDeliveryFor(.{ .named = name });
    bindEventNameBinding(allocator, elem, name, binding);
}

fn bindEventNameBinding(allocator: std.mem.Allocator, elem: *Element, name: []const u8, binding: EventBinding) void {
    if (elem.namedEventIndex(name)) |index| {
        const event = &elem.named_events.items[index];
        event.binding = binding;
        return;
    }

    const name_copy = allocator.dupe(u8, name) catch std.process.exit(1);
    elem.named_events.append(allocator, .{
        .name = name_copy,
        .binding = binding,
    }) catch {
        allocator.free(name_copy);
        std.process.exit(1);
    };
}

/// Clears event name while retaining bounded storage where the type promises reuse.
pub fn clearEventName(allocator: std.mem.Allocator, elem: *Element, name: []const u8) void {
    const index = elem.namedEventIndex(name) orelse return;
    const removed = elem.named_events.orderedRemove(index);
    removed.deinit(allocator);
}

/// Stages a complete render-surface reset in the host command sink.
pub fn reset(allocator: std.mem.Allocator, elements: *std.ArrayListUnmanaged(Element)) void {
    for (elements.items) |*elem| {
        elem.deinit(allocator);
    }
    elements.items.len = 0;

    const root_tag = allocator.dupe(u8, "root") catch std.process.exit(1);
    elements.append(allocator, Element.init(0, root_tag)) catch {
        allocator.free(root_tag);
        std.process.exit(1);
    };
}

/// Appends detached using capacity that must already satisfy the caller's transaction contract.
pub fn appendDetached(allocator: std.mem.Allocator, elements: *std.ArrayListUnmanaged(Element), elem_id: u64, tag: []const u8) void {
    const tag_copy = allocator.dupe(u8, tag) catch std.process.exit(1);
    if (elem_id < elements.items.len) {
        const elem = &elements.items[@intCast(elem_id)];
        if (elem.active) @panic("sim DOM append attempted to reuse an active element id");
        elem.deinit(allocator);
        elem.* = Element.init(elem_id, tag_copy);
        return;
    }
    while (elem_id > elements.items.len) {
        const inactive_tag = allocator.dupe(u8, "") catch std.process.exit(1);
        var inactive = Element.init(@intCast(elements.items.len), inactive_tag);
        inactive.active = false;
        elements.append(allocator, inactive) catch {
            inactive.deinit(allocator);
            std.process.exit(1);
        };
    }
    elements.append(allocator, Element.init(elem_id, tag_copy)) catch {
        allocator.free(tag_copy);
        std.process.exit(1);
    };
}

/// Appends child using capacity that must already satisfy the caller's transaction contract.
pub fn appendChild(allocator: std.mem.Allocator, parent: *Element, child: *Element) void {
    child.parent_id = parent.id;
    parent.children.append(allocator, child.id) catch std.process.exit(1);
}

/// Removes child at and releases the ownership attached to that live entry.
pub fn removeChildAt(parent: *Element, child_index: usize) void {
    _ = parent.children.orderedRemove(child_index);
}

/// Retires removed node so disposed scope identity cannot be routed again.
pub fn deactivateRemovedNode(allocator: std.mem.Allocator, elem: *Element) void {
    elem.active = false;
    elem.parent_id = null;
    elem.focused = false;
    elem.composing = false;
    clearPendingValue(allocator, elem);
    elem.event_bindings = .{};
    for (elem.named_events.items) |event| {
        event.deinit(allocator);
    }
    elem.named_events.clearRetainingCapacity();
    elem.children.deinit(allocator);
    elem.children = .empty;
}

/// Publishes the engine-selected child order for one parent.
pub fn replaceChildren(allocator: std.mem.Allocator, elements: []Element, parent: *Element, next_child_ids: []const u64) void {
    for (next_child_ids) |child_id| {
        elements[@intCast(child_id)].parent_id = parent.id;
    }
    parent.children.deinit(allocator);
    parent.children = .empty;
    parent.children.appendSlice(allocator, next_child_ids) catch std.process.exit(1);
}

test "simulated DOM append supports sparse element ids" {
    const allocator = std.testing.allocator;
    var elements: std.ArrayListUnmanaged(Element) = .empty;
    defer {
        for (elements.items) |*elem| {
            elem.deinit(allocator);
        }
        elements.deinit(allocator);
    }

    reset(allocator, &elements);
    appendDetached(allocator, &elements, 3, "section");

    try std.testing.expectEqual(@as(usize, 4), elements.items.len);
    try std.testing.expect(!elements.items[1].active);
    try std.testing.expect(!elements.items[2].active);
    try std.testing.expect(elements.items[3].active);
    try std.testing.expectEqualStrings("section", elements.items[3].tag);
}

test "simulated DOM snapshots sweep allocation failures without aliasing" {
    const FaultAllocator = signals.fault_allocator.FaultAllocator;
    var source = Element.init(7, try std.testing.allocator.dupe(u8, "button"));
    defer source.deinit(std.testing.allocator);
    source.role = try std.testing.allocator.dupe(u8, "switch");
    source.text = try std.testing.allocator.dupe(u8, "ready");
    try source.children.append(std.testing.allocator, 9);
    try source.attrs.append(std.testing.allocator, .{
        .name = try std.testing.allocator.dupe(u8, "data-state"),
        .value = try std.testing.allocator.dupe(u8, "ready"),
    });
    try source.named_events.append(std.testing.allocator, .{
        .name = try std.testing.allocator.dupe(u8, "submit"),
        .binding = undefined,
    });

    var counted = FaultAllocator.init(std.testing.allocator);
    var clone = try source.cloneOwned(counted.allocator());
    const attempts = counted.attempts;
    clone.deinit(counted.allocator());
    try std.testing.expect(attempts != 0);
    for (1..attempts + 1) |failure_number| {
        var fault = FaultAllocator.init(std.testing.allocator);
        fault.configure(failure_number);
        try std.testing.expectError(error.OutOfMemory, source.cloneOwned(fault.allocator()));
        try std.testing.expectEqualStrings("button", source.tag);
        try std.testing.expectEqualStrings("ready", source.text.?);
        fault.configure(null);
        var retry = try source.cloneOwned(fault.allocator());
        defer retry.deinit(fault.allocator());
        try std.testing.expectEqualStrings(source.attrs.items[0].value, retry.attrs.items[0].value);
        try std.testing.expect(source.attrs.items[0].value.ptr != retry.attrs.items[0].value.ptr);
    }
}

test "prepared native DOM publication aborts or swaps allocation free" {
    const FaultAllocator = signals.fault_allocator.FaultAllocator;
    var fault = FaultAllocator.init(std.testing.allocator);
    var elements: std.ArrayListUnmanaged(Element) = .empty;
    defer {
        for (elements.items) |*elem| elem.deinit(fault.allocator());
        elements.deinit(fault.allocator());
    }
    reset(fault.allocator(), &elements);
    appendDetached(fault.allocator(), &elements, 1, "old");

    var aborted = try PreparedPublication.init(fault.allocator(), &elements, &.{ 1, 3 }, 3);
    try std.testing.expectEqualStrings("old", aborted.node(1).?.tag);
    aborted.node(3).?.active = true;
    aborted.deinit();
    try std.testing.expectEqual(@as(usize, 2), elements.items.len);
    try std.testing.expectEqualStrings("old", elements.items[1].tag);

    var plan = try PreparedPublication.init(fault.allocator(), &elements, &.{ 1, 3 }, 3);
    const next = plan.node(1).?;
    fault.allocator().free(next.tag);
    next.tag = try fault.allocator().dupe(u8, "new");
    plan.node(3).?.active = true;
    fault.configure(1);
    plan.apply(&elements);
    try std.testing.expectEqual(@as(usize, 0), fault.attempts);
    try std.testing.expectEqual(@as(usize, 4), elements.items.len);
    try std.testing.expectEqualStrings("new", elements.items[1].tag);
    try std.testing.expect(elements.items[3].active);
    plan.deinit();
    fault.configure(null);

    try std.testing.expectError(error.DuplicateNode, PreparedPublication.init(fault.allocator(), &elements, &.{ 1, 1 }, 3));
    try std.testing.expectError(error.ResourceLimit, PreparedPublication.init(fault.allocator(), &elements, &.{4}, 3));

    var counted = FaultAllocator.init(std.testing.allocator);
    var counted_elements: std.ArrayListUnmanaged(Element) = .empty;
    defer {
        for (counted_elements.items) |*elem| elem.deinit(counted.allocator());
        counted_elements.deinit(counted.allocator());
    }
    reset(counted.allocator(), &counted_elements);
    appendDetached(counted.allocator(), &counted_elements, 1, "active");
    counted_elements.items[1].active = false;
    counted.configure(null);
    var counted_plan = try PreparedPublication.init(counted.allocator(), &counted_elements, &.{ 1, 3 }, 3);
    const prepare_attempts = counted.attempts;
    counted_plan.deinit();
    for (1..prepare_attempts + 1) |failure_number| {
        var failing = FaultAllocator.init(std.testing.allocator);
        var failing_elements: std.ArrayListUnmanaged(Element) = .empty;
        defer {
            for (failing_elements.items) |*elem| elem.deinit(failing.allocator());
            failing_elements.deinit(failing.allocator());
        }
        reset(failing.allocator(), &failing_elements);
        appendDetached(failing.allocator(), &failing_elements, 1, "active");
        failing_elements.items[1].active = false;
        failing.configure(failure_number);
        try std.testing.expectError(error.OutOfMemory, PreparedPublication.init(failing.allocator(), &failing_elements, &.{ 1, 3 }, 3));
        try std.testing.expectEqual(@as(usize, 1), failing.induced_failures);
        try std.testing.expectEqual(@as(usize, 2), failing_elements.items.len);
        try std.testing.expectEqualStrings("active", failing_elements.items[1].tag);
        try std.testing.expect(!failing_elements.items[1].active);
        failing.configure(null);
        var retry = try PreparedPublication.init(failing.allocator(), &failing_elements, &.{ 1, 3 }, 3);
        retry.deinit();
    }
}

test "simulated DOM element indexes attrs and named events" {
    const allocator = std.testing.allocator;
    const tag = try allocator.dupe(u8, "button");
    var elem = Element.init(7, tag);
    defer elem.deinit(allocator);

    try elem.attrs.append(allocator, .{
        .name = try allocator.dupe(u8, "data-state"),
        .value = try allocator.dupe(u8, "ready"),
    });
    try elem.named_events.append(allocator, .{
        .name = try allocator.dupe(u8, "submit"),
        .binding = .{
            .event_id = ids.EventId.fromRaw(42),
            .payload_descriptor = boundary.BoundaryPayloadDescriptor.init(.unit, .none),
        },
    });

    try std.testing.expectEqual(@as(?usize, 0), elem.textAttrIndex("data-state"));
    try std.testing.expectEqual(@as(?usize, null), elem.textAttrIndex("missing"));
    try std.testing.expectEqual(@as(?usize, 0), elem.namedEventIndex("submit"));
    try std.testing.expectEqual(@as(?usize, null), elem.namedEventIndex("click"));
}

test "simulated DOM matches spec locators" {
    const allocator = std.testing.allocator;
    const tag = try allocator.dupe(u8, "button");
    var elem = Element.init(1, tag);
    defer elem.deinit(allocator);

    elem.text = try allocator.dupe(u8, "Save");
    elem.test_id = try allocator.dupe(u8, "save-button");

    try std.testing.expect(matchesLocator(&elem, .{
        .kind = .role_name,
        .role = "button",
        .name = "Save",
    }));
    try std.testing.expect(matchesLocator(&elem, .{
        .kind = .test_id,
        .test_id = "save-button",
    }));
    try std.testing.expect(!matchesLocator(&elem, .{
        .kind = .text,
        .text = "Cancel",
    }));
}

test "simulated DOM locator helpers cover implicit roles and name fallbacks" {
    const allocator = std.testing.allocator;

    const heading_tag = try allocator.dupe(u8, "h2");
    var heading = Element.init(4, heading_tag);
    defer heading.deinit(allocator);
    heading.text = try allocator.dupe(u8, "Overview");

    try std.testing.expectEqualStrings("heading", implicitRole(&heading).?);
    try std.testing.expect(matchesLocator(&heading, .{
        .kind = .role_name,
        .role = "heading",
        .name = "Overview",
    }));
    allocator.free(heading.text.?);
    heading.text = null;
    try std.testing.expect(matchesLocatorWithAccessibleName(&heading, .{
        .kind = .role_name,
        .role = "heading",
        .name = "Overview",
    }, "Overview"));

    const section_tag = try allocator.dupe(u8, "section");
    var section = Element.init(5, section_tag);
    defer section.deinit(allocator);
    section.label = try allocator.dupe(u8, "Settings");

    try std.testing.expectEqualStrings("region", implicitRole(&section).?);
    try std.testing.expect(matchesLocator(&section, .{
        .kind = .label,
        .label = "Settings",
    }));

    const input_tag = try allocator.dupe(u8, "input");
    var input = Element.init(6, input_tag);
    defer input.deinit(allocator);
    input.value = try allocator.dupe(u8, "draft");

    try std.testing.expect(implicitRole(&input) == null);
    try std.testing.expectEqualStrings("draft", accessibleName(&input));

    const div_tag = try allocator.dupe(u8, "div");
    var empty = Element.init(7, div_tag);
    defer empty.deinit(allocator);

    try std.testing.expectEqualStrings("", accessibleName(&empty));
}

test "simulated DOM mutation helpers update owned fields and counters" {
    const allocator = std.testing.allocator;
    const tag = try allocator.dupe(u8, "input");
    var elem = Element.init(2, tag);
    defer elem.deinit(allocator);

    setText(allocator, &elem, "Name");
    setValue(allocator, &elem, "Ada");
    try std.testing.expectEqualStrings("Name", elem.text.?);
    try std.testing.expectEqualStrings("Ada", elem.value.?);
    try std.testing.expectEqual(@as(u64, 1), elem.text_update_count);
    try std.testing.expectEqual(@as(u64, 1), elem.value_update_count);

    try std.testing.expect(!setValueIfChanged(allocator, &elem, "Ada"));
    try std.testing.expect(setValueIfChanged(allocator, &elem, "Grace"));
    try std.testing.expectEqual(@as(u64, 2), elem.value_update_count);

    setTextAttr(allocator, &elem, "data-state", "ready");
    try std.testing.expectEqualStrings("ready", textAttr(&elem, "data-state").?);
    setTextAttr(allocator, &elem, "data-state", "done");
    try std.testing.expectEqualStrings("done", textAttr(&elem, "data-state").?);
    clearTextAttr(allocator, &elem, "data-state");
    try std.testing.expect(textAttr(&elem, "data-state") == null);

    try std.testing.expect(setCheckedIfChanged(&elem, true));
    try std.testing.expect(!setCheckedIfChanged(&elem, true));
    setChecked(&elem, false);
    setDisabled(&elem, true);
    try std.testing.expect(!elem.checked);
    try std.testing.expect(elem.disabled);

    clearText(allocator, &elem);
    clearValue(allocator, &elem);
    try std.testing.expect(elem.text == null);
    try std.testing.expect(elem.value == null);
    try std.testing.expectEqual(@as(u64, 2), elem.text_update_count);
    try std.testing.expectEqual(@as(u64, 3), elem.value_update_count);
}

test "simulated DOM controlled values defer while focused and flush on blur" {
    const allocator = std.testing.allocator;
    const tag = try allocator.dupe(u8, "input");
    var elem = Element.init(20, tag);
    defer elem.deinit(allocator);

    try std.testing.expect(setControlledValue(allocator, &elem, "old"));
    try std.testing.expectEqualStrings("old", elem.value.?);
    try std.testing.expectEqual(@as(u64, 1), elem.value_update_count);

    focusElement(&elem);
    try std.testing.expect(setUserValueIfChanged(allocator, &elem, "draft"));
    try std.testing.expect(!setControlledValue(allocator, &elem, "canonical-a"));
    try std.testing.expectEqualStrings("draft", elem.value.?);
    try std.testing.expectEqualStrings("canonical-a", elem.pending_value.?);

    try std.testing.expect(!setControlledValue(allocator, &elem, "canonical-b"));
    try std.testing.expectEqualStrings("draft", elem.value.?);
    try std.testing.expectEqualStrings("canonical-b", elem.pending_value.?);

    try std.testing.expect(blurElement(allocator, &elem));
    try std.testing.expectEqualStrings("canonical-b", elem.value.?);
    try std.testing.expect(elem.pending_value == null);
    try std.testing.expectEqual(@as(u64, 3), elem.value_update_count);
}

test "simulated DOM controlled values clear stale pending equality" {
    const allocator = std.testing.allocator;
    const tag = try allocator.dupe(u8, "input");
    var elem = Element.init(23, tag);
    defer elem.deinit(allocator);

    try std.testing.expect(setControlledValue(allocator, &elem, "stable"));
    focusElement(&elem);
    try std.testing.expect(!setControlledValue(allocator, &elem, "pending"));
    try std.testing.expectEqualStrings("pending", elem.pending_value.?);

    try std.testing.expect(!setControlledValue(allocator, &elem, "stable"));
    try std.testing.expect(elem.pending_value == null);

    replacePendingValue(allocator, &elem, "stable");
    try std.testing.expect(!blurElement(allocator, &elem));
    try std.testing.expect(elem.pending_value == null);
    try std.testing.expectEqualStrings("stable", elem.value.?);
}

test "simulated DOM controlled values no-op when user draft matches pending" {
    const allocator = std.testing.allocator;
    const tag = try allocator.dupe(u8, "input");
    var elem = Element.init(21, tag);
    defer elem.deinit(allocator);

    try std.testing.expect(setControlledValue(allocator, &elem, "a"));
    focusElement(&elem);
    try std.testing.expect(!setControlledValue(allocator, &elem, "abc"));
    try std.testing.expectEqualStrings("abc", elem.pending_value.?);

    try std.testing.expect(setUserValueIfChanged(allocator, &elem, "abc"));
    try std.testing.expect(elem.pending_value == null);
    try std.testing.expect(!blurElement(allocator, &elem));
    try std.testing.expectEqualStrings("abc", elem.value.?);
    try std.testing.expectEqual(@as(u64, 2), elem.value_update_count);
}

test "simulated DOM controlled values stay deferred through composition end while focused" {
    const allocator = std.testing.allocator;
    const tag = try allocator.dupe(u8, "input");
    var elem = Element.init(22, tag);
    defer elem.deinit(allocator);

    try std.testing.expect(setControlledValue(allocator, &elem, ""));
    focusElement(&elem);
    beginComposition(&elem);
    try std.testing.expect(setUserValueIfChanged(allocator, &elem, "ime"));
    try std.testing.expect(!setControlledValue(allocator, &elem, "canonical-ime"));
    try std.testing.expectEqualStrings("ime", elem.value.?);

    try std.testing.expect(!endComposition(allocator, &elem));
    try std.testing.expectEqualStrings("ime", elem.value.?);
    try std.testing.expectEqualStrings("canonical-ime", elem.pending_value.?);

    try std.testing.expect(blurElement(allocator, &elem));
    try std.testing.expectEqualStrings("canonical-ime", elem.value.?);
    try std.testing.expect(elem.pending_value == null);
}

test "simulated DOM binds and clears events" {
    const allocator = std.testing.allocator;
    const tag = try allocator.dupe(u8, "form");
    var elem = Element.init(3, tag);
    defer elem.deinit(allocator);

    bindEventKind(&elem, .click, .{
        .event_id = ids.EventId.fromRaw(11),
        .payload_descriptor = boundary.BoundaryPayloadDescriptor.init(.unit, .none),
    });
    try std.testing.expectEqual(@as(?u64, 11), fixedEventId(&elem, .click));
    clearEventKind(&elem, .click);
    try std.testing.expectEqual(@as(?u64, null), fixedEventId(&elem, .click));

    bindEventName(allocator, &elem, "submit", 21, render.EventPolicy.fromBits(7), boundary.BoundaryPayloadDescriptor.init(.unit, .none));
    try std.testing.expectEqual(@as(u64, 21), namedEvent(&elem, "submit").?.binding.event_id.raw());
    bindEventName(allocator, &elem, "submit", 22, render.EventPolicy.fromBits(9), boundary.BoundaryPayloadDescriptor.init(.bytes, .record_key_shift));
    const updated = namedEvent(&elem, "submit").?;
    try std.testing.expectEqual(@as(u64, 22), updated.binding.event_id.raw());
    try std.testing.expect(updated.binding.policy.eql(render.EventPolicy.fromBits(9)));
    try std.testing.expectEqual(boundary.BoundaryPayloadDescriptor.init(.bytes, .record_key_shift), updated.binding.payload_descriptor);
    clearEventName(allocator, &elem, "submit");
    try std.testing.expect(namedEvent(&elem, "submit") == null);
}

test "simulated DOM binds all fixed event variants through generic helpers" {
    const allocator = std.testing.allocator;
    const tag = try allocator.dupe(u8, "form");
    var elem = Element.init(8, tag);
    defer elem.deinit(allocator);

    const payload = boundary.BoundaryPayloadDescriptor.init(.unit, .none);
    const kinds = [_]render.EventKind{
        .input,
        .check,
        .pointer_down,
        .pointer_up,
        .pointer_enter,
        .pointer_leave,
    };

    for (kinds, 0..) |kind, index| {
        const event_id: u64 = @intCast(index + 30);
        bindEvent(allocator, &elem, .{ .fixed = kind }, .{
            .event_id = ids.EventId.fromRaw(event_id),
            .payload_descriptor = payload,
        });
        try std.testing.expectEqual(@as(?u64, event_id), fixedEventId(&elem, kind));
    }

    for (kinds) |kind| {
        clearEvent(allocator, &elem, .{ .fixed = kind });
        try std.testing.expectEqual(@as(?u64, null), fixedEventId(&elem, kind));
    }

    bindEvent(allocator, &elem, .{ .named = "custom-submit" }, .{
        .event_id = ids.EventId.fromRaw(99),
        .payload_descriptor = payload,
    });
    try std.testing.expectEqual(@as(u64, 99), namedEvent(&elem, "custom-submit").?.binding.event_id.raw());
    clearEvent(allocator, &elem, .{ .named = "custom-submit" });
    try std.testing.expect(namedEvent(&elem, "custom-submit") == null);
}

test "simulated DOM resets and appends children" {
    const allocator = std.testing.allocator;
    var elements: std.ArrayListUnmanaged(Element) = .empty;
    defer {
        for (elements.items) |*elem| {
            elem.deinit(allocator);
        }
        elements.deinit(allocator);
    }

    reset(allocator, &elements);
    try std.testing.expectEqual(@as(usize, 1), elements.items.len);
    try std.testing.expectEqualStrings("root", elements.items[0].tag);

    appendDetached(allocator, &elements, 1, "section");
    appendChild(allocator, &elements.items[0], &elements.items[1]);
    try std.testing.expectEqual(@as(?u64, 0), elements.items[1].parent_id);
    try std.testing.expectEqualSlices(u64, &.{1}, elements.items[0].children.items);
    try std.testing.expectEqual(@as(?usize, 0), childIndex(&elements.items[0], 1));
    try std.testing.expectEqual(@as(?usize, null), childIndex(&elements.items[0], 2));

    reset(allocator, &elements);
    try std.testing.expectEqual(@as(usize, 1), elements.items.len);
    try std.testing.expectEqualStrings("root", elements.items[0].tag);
}

test "simulated DOM reuses inactive element ids" {
    const allocator = std.testing.allocator;
    var elements: std.ArrayListUnmanaged(Element) = .empty;
    defer {
        for (elements.items) |*elem| {
            elem.deinit(allocator);
        }
        elements.deinit(allocator);
    }

    reset(allocator, &elements);
    appendDetached(allocator, &elements, 1, "p");
    deactivateRemovedNode(allocator, &elements.items[1]);
    appendDetached(allocator, &elements, 1, "button");

    try std.testing.expect(elements.items[1].active);
    try std.testing.expectEqualStrings("button", elements.items[1].tag);
    try std.testing.expectEqual(@as(?u64, null), elements.items[1].parent_id);
}

test "simulated DOM replaces children and deactivates removed nodes" {
    const allocator = std.testing.allocator;
    var elements: std.ArrayListUnmanaged(Element) = .empty;
    defer {
        for (elements.items) |*elem| {
            elem.deinit(allocator);
        }
        elements.deinit(allocator);
    }

    reset(allocator, &elements);
    appendDetached(allocator, &elements, 1, "section");
    appendDetached(allocator, &elements, 2, "p");
    appendDetached(allocator, &elements, 3, "button");
    appendChild(allocator, &elements.items[0], &elements.items[1]);
    appendChild(allocator, &elements.items[1], &elements.items[2]);

    replaceChildren(allocator, elements.items, &elements.items[0], &.{3});
    try std.testing.expectEqual(@as(?u64, 0), elements.items[3].parent_id);
    try std.testing.expectEqualSlices(u64, &.{3}, elements.items[0].children.items);

    removeChildAt(&elements.items[0], 0);
    try std.testing.expectEqual(@as(usize, 0), elements.items[0].children.items.len);
    bindEventName(allocator, &elements.items[3], "click", 9, render.EventPolicy.none, boundary.BoundaryPayloadDescriptor.init(.unit, .none));
    deactivateRemovedNode(allocator, &elements.items[3]);
    try std.testing.expect(!elements.items[3].active);
    try std.testing.expectEqual(@as(?u64, null), elements.items[3].parent_id);
    try std.testing.expectEqual(@as(usize, 0), elements.items[3].named_events.items.len);
}
