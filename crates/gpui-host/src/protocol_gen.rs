//! Native GUI protocol tables generated from protocol/native-protocol.json.
//!
//! GENERATED FILE - do not edit by hand. Update the manifest and run
//! `python3 scripts/generate_protocol.py`; `scripts/test.py zig` verifies
//! that this committed artifact matches the manifest.

use crate::bridge::{Slice, Style};

/// Version of the statically linked native GUI presentation boundary.
pub const PROTOCOL_VERSION: u32 = 9;

/// Version of the separate native effects (task transport) boundary.
pub const EFFECT_VERSION: u32 = 2;

/// Version of the separate native timer boundary.
pub const TIMER_VERSION: u32 = 1;

/// Closed task service routes carried in native effect messages.
#[allow(dead_code)]
pub mod task_kind {
    /// App-declared external task; the only route the browser host accepts.
    pub const EXTERNAL: u32 = 0;
    /// Native file chooser dialog.
    pub const CHOOSE_FILE: u32 = 1;
    /// Native directory chooser dialog.
    pub const CHOOSE_DIRECTORY: u32 = 2;
    /// Native save-path chooser with location kind, directory, and suggested name.
    pub const CHOOSE_SAVE_PATH: u32 = 3;
    /// Bounded UTF-8 text read of one absolute path.
    pub const READ_TEXT: u32 = 4;
    /// Atomic bounded UTF-8 text write of one absolute path.
    pub const WRITE_TEXT: u32 = 5;
    /// Bounded recursive directory metadata scan.
    pub const SCAN_DIRECTORY: u32 = 6;
    /// Bounded direct-children directory listing.
    pub const LIST_DIRECTORY: u32 = 7;
    /// Hand one regular file to its associated application.
    pub const OPEN_PATH: u32 = 8;
    /// Bounded UTF-8 prefix read with an explicit truncation marker.
    pub const READ_PREVIEW: u32 = 9;
    /// Cursor-driven bounded log chunk read with rotation detection.
    pub const READ_LOG: u32 = 10;
    /// Hash a bounded manifest of relative assets against expected SHA-256 digests.
    pub const VERIFY_ASSETS: u32 = 11;
}

/// The extern node record read through `signals_read_changed`. Zig and Rust
/// declare this layout from the same manifest order, so the field order is ABI;
/// the `signals_node_size` assertion in `bridge::Engine::open` pins the layout.
#[repr(C)]
pub struct RawNode {
    /// Committed element id.
    pub id: u64,
    /// Nonzero while the element is mounted.
    pub active: u64,
    /// Committed parent element id, zero for the root.
    pub parent: u64,
    /// Element tag string.
    pub tag: Slice,
    /// Text content (text field 1).
    pub text: Slice,
    /// Controlled input value (text field 5).
    pub value: Slice,
    /// Caption and semantic name (text field 3).
    pub label: Slice,
    /// Semantic role (text field 2).
    pub role: Slice,
    /// Test selector identity (text field 4).
    pub test_id: Slice,
    /// Class list (text field 6).
    pub class: Slice,
    /// Empty-field hint (text field 12).
    pub placeholder: Slice,
    /// Relative image source (text field 13).
    pub image_source: Slice,
    /// Inherited font family (text field 14).
    pub font_family: Slice,
    /// Embedded font declaration (text field 15).
    pub fonts: Slice,
    /// Committed child count; children are read through signals_child_at.
    pub child_count: usize,
    /// Bound click event id, zero when unbound.
    pub click: u64,
    /// Bound input event id, zero when unbound.
    pub input: u64,
    /// Bound check event id, zero when unbound.
    pub check: u64,
    /// Checked state word (bool field 1).
    pub checked: u64,
    /// Disabled state word (bool field 2).
    pub disabled: u64,
    /// Selected presentation word (bool field 4).
    pub selected: u64,
    /// Nonzero when the style record is populated (text field 8).
    pub style_present: u64,
    /// Validated native presentation record (text field 8).
    pub style: Style,
    /// Validated virtual-list record (text field 9), zeroed when absent.
    pub viewport: [u32; 2],
    /// Checked lifetime counter advanced on descriptor retirement.
    pub lifetime: u64,
    /// Internal drag source key (text field 10).
    pub drag_key: Slice,
    /// Bound drop event id for an active drop target, zero otherwise (bool field 5).
    pub drop: u64,
    /// Bound close-requested event id for a registered window (text field 11).
    pub close_requested: u64,
    /// Close-decision word: 0 unregistered, KeepOpen=1, AwaitDecision=2, Close=3.
    pub close_policy: u64,
}
