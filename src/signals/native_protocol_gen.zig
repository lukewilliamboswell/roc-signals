//! Scalar field tables generated from protocol/native-protocol.json.
//!
//! GENERATED FILE - do not edit by hand. Update the manifest and run
//! `python3 scripts/generate_protocol.py`; `scripts/test.py zig` verifies
//! that this committed artifact matches the manifest.

/// Field id reserved for named custom text attributes; never a typed slot.
pub const custom_text_field_id: u64 = 7;

/// Field id reserved for named custom boolean attributes; never a typed slot.
pub const custom_bool_field_id: u64 = 3;

/// Scalar text fields carried by the shared descriptor machinery.
pub const TextField = enum(u64) {
    /// Element text content.
    text = 1,
    /// Semantic role string.
    role = 2,
    /// Visible caption and semantic name.
    label = 3,
    /// Stable test selector identity.
    test_id = 4,
    /// Controlled input value.
    value = 5,
    /// CSS class list for browser presentation.
    class = 6,

    /// Returns the name of the browser opcode that sets this field.
    pub fn browserOpName(self: TextField) []const u8 {
        return switch (self) {
            .text => "set_text",
            .role => "set_role",
            .label => "set_label",
            .test_id => "set_test_id",
            .value => "set_value",
            .class => "set_class",
        };
    }
};

/// Scalar boolean fields carried by the shared descriptor machinery.
pub const BoolField = enum(u64) {
    /// Checkbox checked state.
    checked = 1,
    /// Disables input while keeping the element and its identity.
    disabled = 2,

    /// Returns the name of the browser opcode that sets this field.
    pub fn browserOpName(self: BoolField) []const u8 {
        return switch (self) {
            .checked => "set_checked",
            .disabled => "set_disabled",
        };
    }
};

/// Total declared scalar text fields.
pub const text_field_count: usize = 6;

/// Total declared scalar boolean fields.
pub const bool_field_count: usize = 2;
