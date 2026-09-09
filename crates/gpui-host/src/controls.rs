//! Keyboard activation for focused native controls; events remain engine-owned.
use gpui::Styled;
use gpui::{App, Div, FocusHandle, InteractiveElement, KeyBinding, MouseButton, Stateful, actions};

actions!(native_control, [Activate]);

pub fn bind_keys(cx: &mut App) {
    cx.bind_keys([
        KeyBinding::new("enter", Activate, Some("SignalsButton")),
        KeyBinding::new("space", Activate, Some("SignalsButton")),
        KeyBinding::new("space", Activate, Some("SignalsCheckbox")),
    ]);
}

pub fn install(
    element: Stateful<Div>,
    focus: &FocusHandle,
    checkbox: bool,
    disabled: bool,
    activate: impl Fn(&mut App) -> bool + 'static,
) -> Stateful<Div> {
    let clicked_focus = focus.clone();
    element
        .track_focus(&focus.clone().tab_stop(!disabled))
        .on_mouse_down(MouseButton::Left, move |_, window, _| {
            if !disabled {
                clicked_focus.focus(window);
            }
        })
        .key_context(if checkbox {
            "SignalsCheckbox"
        } else {
            "SignalsButton"
        })
        .on_action(move |_: &Activate, _, cx| {
            if activate(cx) {
                cx.stop_propagation();
            }
        })
        .focus(|style| style.border_2().border_color(gpui::rgb(0x70c5e8)))
}
