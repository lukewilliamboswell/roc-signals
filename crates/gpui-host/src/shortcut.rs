//! Native key adapters for engine-owned, scope-bound unit events.
use gpui::{App, Div, InteractiveElement, KeyDownEvent, Stateful, Window};

pub const MAX_PER_ELEMENT: usize = 32;

/// One copied committed registration; no Roc value or native focus handle crosses
/// this ABI. Key codes and modifier bits follow the native keyboard protocol.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Shortcut {
    pub event: u64,
    pub key: u32,
    pub modifiers: u32,
}

fn key_code(key: &str) -> Option<u32> {
    if key.len() == 1 {
        let byte = key.as_bytes()[0];
        if byte.is_ascii_lowercase() || byte.is_ascii_digit() {
            return Some(u32::from(byte));
        }
    }
    const NAMES: [&str; 26] = [
        "enter",
        "escape",
        "tab",
        "space",
        "left",
        "right",
        "up",
        "down",
        "home",
        "end",
        "pageup",
        "pagedown",
        "backspace",
        "delete",
        "f1",
        "f2",
        "f3",
        "f4",
        "f5",
        "f6",
        "f7",
        "f8",
        "f9",
        "f10",
        "f11",
        "f12",
    ];
    NAMES
        .iter()
        .position(|name| *name == key)
        .map(|index| index as u32 + 256)
}

impl Shortcut {
    fn matches(&self, event: &KeyDownEvent) -> bool {
        let keys = &event.keystroke;
        let modifiers = u32::from(keys.modifiers.control)
            | (u32::from(keys.modifiers.shift) << 1)
            | (u32::from(keys.modifiers.alt) << 2)
            | (u32::from(keys.modifiers.platform) << 3);
        !keys.modifiers.function
            && key_code(&keys.key) == Some(self.key)
            && modifiers == self.modifiers
    }
}

/// Adds a bubbling keyboard listener to one rendered region. GPUI's focused
/// control actions run first; a matching region consumes only an accepted live
/// registration. Disposed or replaced bindings leave the keystroke untouched.
pub fn install(
    element: Stateful<Div>,
    bindings: Vec<Shortcut>,
    dispatch: impl Fn(Shortcut, &mut App) -> bool + 'static,
) -> Stateful<Div> {
    assert!(
        bindings.len() <= MAX_PER_ELEMENT,
        "native shortcut limit exceeded"
    );
    element.on_key_down(move |event, window: &mut Window, cx| {
        if let Some(binding) = bindings.iter().find(|binding| binding.matches(event)) {
            if dispatch(*binding, cx) {
                window.prevent_default();
                cx.stop_propagation();
            }
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use gpui::{
        AppContext, Context, Entity, FocusHandle, Focusable, IntoElement, ParentElement, Render,
        TestAppContext, div,
    };
    use std::{cell::RefCell, rc::Rc};

    struct Region {
        focus: FocusHandle,
        bindings: Vec<Shortcut>,
        received: Rc<RefCell<Vec<u64>>>,
        child: Option<Entity<Region>>,
        editor: Option<Entity<crate::input::TextInput>>,
    }

    impl Render for Region {
        fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
            let received = self.received.clone();
            install(
                div().id("region").track_focus(&self.focus),
                self.bindings.clone(),
                move |binding, _| {
                    received.borrow_mut().push(binding.event);
                    true
                },
            )
            .children(self.child.clone())
            .children(self.editor.clone())
        }
    }

    #[gpui::test]
    fn focused_nearest_region_matches_all_modifiers_and_bubbles_nonmatches(
        cx: &mut TestAppContext,
    ) {
        let received = Rc::new(RefCell::new(Vec::new()));
        let capture = received.clone();
        let (root, cx) = cx.add_window_view(|window, cx| {
            let child = cx.new(|cx| {
                let focus = cx.focus_handle();
                focus.focus(window);
                Region {
                    focus,
                    bindings: vec![Shortcut {
                        event: 2,
                        key: u32::from(b's'),
                        modifiers: 1,
                    }],
                    received: capture.clone(),
                    child: None,
                    editor: None,
                }
            });
            Region {
                focus: cx.focus_handle(),
                bindings: vec![
                    Shortcut {
                        event: 1,
                        key: u32::from(b's'),
                        modifiers: 1,
                    },
                    Shortcut {
                        event: 3,
                        key: u32::from(b's'),
                        modifiers: 3,
                    },
                ],
                received: capture,
                child: Some(child),
                editor: None,
            }
        });
        cx.simulate_keystrokes("ctrl-s ctrl-shift-s alt-s s");
        assert_eq!(*received.borrow(), vec![2, 3]);
        cx.update(|_, cx| {
            root.update(cx, |root, cx| {
                root.child.as_ref().unwrap().update(cx, |child, cx| {
                    child.bindings.clear();
                    cx.notify();
                });
            })
        });
        cx.simulate_keystrokes("ctrl-s");
        assert_eq!(*received.borrow(), vec![2, 3, 1]);
    }

    #[gpui::test]
    fn focused_editor_actions_precede_region_shortcuts(cx: &mut TestAppContext) {
        cx.update(crate::input::bind_keys);
        let received = Rc::new(RefCell::new(Vec::new()));
        let capture = received.clone();
        let (_, cx) = cx.add_window_view(|window, cx| {
            let editor = cx.new(|cx| {
                let input = crate::input::TextInput::new("text".into(), Rc::new(|_, _| {}), cx);
                input.focus_handle(cx).focus(window);
                input
            });
            Region {
                focus: cx.focus_handle(),
                bindings: vec![
                    Shortcut {
                        event: 4,
                        key: u32::from(b'a'),
                        modifiers: 1,
                    },
                    Shortcut {
                        event: 5,
                        key: u32::from(b's'),
                        modifiers: 1,
                    },
                ],
                received: capture,
                child: None,
                editor: Some(editor),
            }
        });
        cx.simulate_keystrokes("ctrl-a ctrl-s");
        assert_eq!(*received.borrow(), vec![5]);
    }

    #[test]
    fn key_vocabulary_has_no_label_or_display_text_inference() {
        assert_eq!(key_code("s"), Some(115));
        assert_eq!(key_code("escape"), Some(257));
        assert_eq!(key_code("f12"), Some(281));
        assert_eq!(key_code("Save"), None);
        assert_eq!(key_code("S"), None);
        assert_eq!(key_code("ctrl-s"), None);
    }
}
