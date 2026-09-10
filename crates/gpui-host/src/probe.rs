//! Laid-out bounds for scripted regression checks, keyed by semantic test id.
//!
//! GPUI only publishes its own `debug_bounds` map to `test-support` builds, so a
//! shipped example binary cannot be asked where a control ended up. Reachability
//! regressions (a detail action pushed below the viewport, a dialog wider than
//! the window) are exactly the class the semantic specs cannot see, so the host
//! records the bounds itself while a script is running.
//!
//! The recording is opt-in: without `--host-script` no listener is installed and the
//! render path is byte-for-byte the shipped one. Recording never influences
//! layout — a prepaint listener observes bounds that have already been decided.

use gpui::{Bounds, Pixels};
use std::cell::RefCell;
use std::collections::HashMap;

/// A control's laid-out rectangle in window coordinates, in logical pixels.
#[derive(Clone, Copy, Debug, PartialEq)]
pub(crate) struct Rect {
    pub left: f32,
    pub top: f32,
    pub right: f32,
    pub bottom: f32,
}

thread_local! {
    static ENABLED: RefCell<bool> = const { RefCell::new(false) };
    static RECORDED: RefCell<HashMap<String, Rect>> = RefCell::new(HashMap::new());
    static VIEWPORT: RefCell<Option<Rect>> = const { RefCell::new(None) };
}

/// Turns bounds recording on for the rest of the process.
///
/// Called once, before the window opens, when the process was started with a
/// script. Leaving it off keeps the prepaint listeners out of the element tree
/// entirely rather than installing an inert one.
pub(crate) fn enable() {
    ENABLED.with(|enabled| *enabled.borrow_mut() = true);
}

/// Whether the render path should install bounds listeners.
pub(crate) fn enabled() -> bool {
    ENABLED.with(|enabled| *enabled.borrow())
}

/// Stores one control's laid-out rectangle, replacing any earlier frame's.
///
/// Nodes without a test id are dropped here rather than at every call site: a
/// control the application never named cannot be the subject of an assertion.
pub(crate) fn record(test_id: &str, bounds: Bounds<Pixels>) {
    if test_id.is_empty() {
        return;
    }
    let rect = Rect {
        left: f32::from(bounds.origin.x),
        top: f32::from(bounds.origin.y),
        right: f32::from(bounds.origin.x + bounds.size.width),
        bottom: f32::from(bounds.origin.y + bounds.size.height),
    };
    RECORDED.with(|recorded| recorded.borrow_mut().insert(test_id.to_string(), rect));
}

/// Stores the window's content rectangle, the frame reachability is judged against.
pub(crate) fn record_viewport(size: gpui::Size<Pixels>) {
    let rect = Rect {
        left: 0.,
        top: 0.,
        right: f32::from(size.width),
        bottom: f32::from(size.height),
    };
    VIEWPORT.with(|viewport| *viewport.borrow_mut() = Some(rect));
}

/// The most recent rectangle recorded for a test id, if it was laid out at all.
pub(crate) fn bounds(test_id: &str) -> Option<Rect> {
    RECORDED.with(|recorded| recorded.borrow().get(test_id).copied())
}

/// The most recent window content rectangle.
pub(crate) fn viewport() -> Option<Rect> {
    VIEWPORT.with(|viewport| *viewport.borrow())
}

/// Drops the rectangles of controls that are no longer mounted.
///
/// A control that has been unmounted would otherwise keep its last rectangle,
/// and a reachability assertion could pass on evidence for something no longer
/// on screen. Dropping *every* rectangle instead does not work: a node that
/// stays mounted and does not re-render is not prepainted again, so its bounds
/// would never come back and the next assertion would read it as missing.
pub(crate) fn retain_mounted(mounted: &std::collections::HashSet<String>) {
    RECORDED.with(|recorded| recorded.borrow_mut().retain(|id, _| mounted.contains(id)));
}

impl Rect {
    /// Whether this rectangle lies wholly inside `outer`.
    ///
    /// Reachability is judged conservatively: a control that is even partly
    /// outside the window is not one a person can reliably click, and the
    /// half-visible case is the one that has repeatedly been missed by eye.
    pub(crate) fn inside(&self, outer: Rect) -> bool {
        self.left >= outer.left - 0.5
            && self.top >= outer.top - 0.5
            && self.right <= outer.right + 0.5
            && self.bottom <= outer.bottom + 0.5
    }

    /// Whether the rectangle encloses any area at all.
    pub(crate) fn is_empty(&self) -> bool {
        self.right - self.left <= 0. || self.bottom - self.top <= 0.
    }
}

#[cfg(test)]
mod tests {
    use super::Rect;

    fn rect(left: f32, top: f32, right: f32, bottom: f32) -> Rect {
        Rect { left, top, right, bottom }
    }

    #[test]
    fn a_control_inside_the_window_is_reachable() {
        let window = rect(0., 0., 1200., 820.);
        assert!(rect(10., 10., 200., 40.).inside(window));
        assert!(rect(0., 0., 1200., 820.).inside(window));
    }

    #[test]
    fn a_control_pushed_past_an_edge_is_not_reachable() {
        let window = rect(0., 0., 1200., 820.);
        assert!(!rect(10., 800., 200., 860.).inside(window));
        assert!(!rect(1100., 10., 1300., 40.).inside(window));
        assert!(!rect(-20., 10., 200., 40.).inside(window));
    }

    #[test]
    fn an_unlaid_out_control_reports_no_area() {
        assert!(rect(10., 10., 10., 40.).is_empty());
        assert!(!rect(10., 10., 40., 40.).is_empty());
    }
}
