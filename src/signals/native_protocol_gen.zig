//! Native GUI protocol tables generated from protocol/native-protocol.json.
//!
//! GENERATED FILE - do not edit by hand. Update the manifest and run
//! `python3 scripts/generate_protocol.py`; `scripts/test.py zig` verifies
//! that this committed artifact matches the manifest.

/// Version of the statically linked native GUI presentation boundary.
pub const protocol_version: u32 = 9;

/// Version of the separate native effects (task transport) boundary.
pub const effect_version: u32 = 2;

/// Version of the separate native timer boundary.
pub const timer_version: u32 = 1;

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
    /// Versioned native presentation record; never encoded on the browser wire.
    native_style = 8,
    /// Fixed-row virtual list record `1,row_height,follow_tail`.
    native_viewport = 9,
    /// Bounded application key exposed by an internal drag source.
    native_drag_key = 10,
    /// Window close policy: `keep-open`, `await-decision`, or `close`.
    native_window_close = 11,
    /// Static empty-field hint text shown while a controlled field is empty.
    native_placeholder = 12,
    /// Relative image source resolved against the process-wide assets root.
    native_image_source = 13,
    /// Static font family joined into the element's inherited text style.
    native_font_family = 14,
    /// Versioned embedded-font registration declaration; registered once at startup.
    native_fonts = 15,

    /// Identifies fields consumed only by the native presentation adapter.
    pub fn isNative(self: TextField) bool {
        return switch (self) {
            .native_style, .native_viewport, .native_drag_key, .native_window_close, .native_placeholder, .native_image_source, .native_font_family, .native_fonts => true,
            else => false,
        };
    }

    /// Returns the browser opcode name for a web scalar, or null for native
    /// metadata that must be rejected before browser wire preparation.
    pub fn browserOpName(self: TextField) ?[]const u8 {
        return switch (self) {
            .text => "set_text",
            .role => "set_role",
            .label => "set_label",
            .test_id => "set_test_id",
            .value => "set_value",
            .class => "set_class",
            .native_style, .native_viewport, .native_drag_key, .native_window_close, .native_placeholder, .native_image_source, .native_font_family, .native_fonts => null,
        };
    }
};

/// Scalar boolean fields carried by the shared descriptor machinery.
pub const BoolField = enum(u64) {
    /// Checkbox checked state.
    checked = 1,
    /// Disables input while retaining native identity.
    disabled = 2,
    /// Native selected presentation, independent of checkbox state.
    selected = 4,
    /// Marks an internal drop target that must bind a string-detail drop event.
    native_drop_target = 5,

    /// Identifies fields consumed only by the native presentation adapter.
    pub fn isNative(self: BoolField) bool {
        return switch (self) {
            .selected, .native_drop_target => true,
            else => false,
        };
    }

    /// Returns the browser opcode name for a web scalar, or null for native
    /// metadata that must be rejected before browser wire preparation.
    pub fn browserOpName(self: BoolField) ?[]const u8 {
        return switch (self) {
            .checked => "set_checked",
            .disabled => "set_disabled",
            .selected, .native_drop_target => null,
        };
    }
};

/// Total declared scalar text fields.
pub const text_field_count: usize = 14;

/// Total declared scalar boolean fields.
pub const bool_field_count: usize = 4;

/// Scalar text fields consumed only by the native presentation adapter.
pub const native_text_field_count: usize = 8;

/// Scalar boolean fields consumed only by the native presentation adapter.
pub const native_bool_field_count: usize = 2;

/// Closed task service routes. Names remain diagnostics; native hosts dispatch
/// only this value, and browser hosts reject native service requests.
pub const TaskKind = enum(u32) {
    /// App-declared external task; the only route the browser host accepts.
    external = 0,
    /// Native file chooser dialog.
    choose_file = 1,
    /// Native directory chooser dialog.
    choose_directory = 2,
    /// Native save-path chooser with location kind, directory, and suggested name.
    choose_save_path = 3,
    /// Bounded UTF-8 text read of one absolute path.
    read_text = 4,
    /// Atomic bounded UTF-8 text write of one absolute path.
    write_text = 5,
    /// Bounded recursive directory metadata scan.
    scan_directory = 6,
    /// Bounded direct-children directory listing.
    list_directory = 7,
    /// Hand one regular file to its associated application.
    open_path = 8,
    /// Bounded UTF-8 prefix read with an explicit truncation marker.
    read_preview = 9,
    /// Cursor-driven bounded log chunk read with rotation detection.
    read_log = 10,
    /// Hash a bounded manifest of relative assets against expected SHA-256 digests.
    verify_assets = 11,
};

/// The extern node record served through `signals_read_changed`. Zig and Rust
/// declare this layout from the same manifest order, so the field order is ABI;
/// `signals_node_size` and the host-side size assertion pin the layout.
pub fn RawNode(comptime Slice: type, comptime Style: type, comptime Viewport: type) type {
    return extern struct {
        /// Committed element id.
        id: u64,
        /// Nonzero while the element is mounted.
        active: u64,
        /// Committed parent element id, zero for the root.
        parent: u64,
        /// Element tag string.
        tag: Slice,
        /// Text content (text field 1).
        text: Slice,
        /// Controlled input value (text field 5).
        value: Slice,
        /// Caption and semantic name (text field 3).
        label: Slice,
        /// Semantic role (text field 2).
        role: Slice,
        /// Test selector identity (text field 4).
        test_id: Slice,
        /// Class list (text field 6).
        class: Slice,
        /// Empty-field hint (text field 12).
        placeholder: Slice,
        /// Relative image source (text field 13).
        image_source: Slice,
        /// Inherited font family (text field 14).
        font_family: Slice,
        /// Embedded font declaration (text field 15).
        fonts: Slice,
        /// Committed child count; children are read through signals_child_at.
        child_count: usize,
        /// Bound click event id, zero when unbound.
        click: u64,
        /// Bound input event id, zero when unbound.
        input: u64,
        /// Bound check event id, zero when unbound.
        check: u64,
        /// Checked state word (bool field 1).
        checked: u64,
        /// Disabled state word (bool field 2).
        disabled: u64,
        /// Selected presentation word (bool field 4).
        selected: u64,
        /// Nonzero when the style record is populated (text field 8).
        style_present: u64,
        /// Validated native presentation record (text field 8).
        style: Style,
        /// Validated virtual-list record (text field 9), zeroed when absent.
        viewport: Viewport,
        /// Checked lifetime counter advanced on descriptor retirement.
        lifetime: u64,
        /// Internal drag source key (text field 10).
        drag_key: Slice,
        /// Bound drop event id for an active drop target, zero otherwise (bool field 5).
        drop: u64,
        /// Bound close-requested event id for a registered window (text field 11).
        close_requested: u64,
        /// Close-decision word: 0 unregistered, KeepOpen=1, AwaitDecision=2, Close=3.
        close_policy: u64,
    };
}
