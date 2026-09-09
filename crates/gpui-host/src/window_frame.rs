//! Compositor decoration negotiation determines whether the host supplies chrome.
use crate::Runtime;
use gpui::{prelude::*, *};

impl Runtime {
    /// Supplies native movement, sizing and guarded closure when the compositor
    /// delegates decorations to the client. Application content keeps its own layout.
    pub(crate) fn window_frame(
        &self,
        content: impl IntoElement,
        decorations: Decorations,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        if window.is_fullscreen() {
            window.set_client_inset(px(0.));
            return content.into_any_element();
        }
        let Decorations::Client { tiling } = decorations else {
            window.set_client_inset(px(0.));
            return content.into_any_element();
        };
        let inset = px(6.);
        window.set_client_inset(inset);
        let title = window.window_title();
        let titlebar = div()
            .id("window-titlebar")
            .h(px(36.))
            .flex_shrink_0()
            .flex()
            .items_center()
            .bg(rgb(0x243842))
            .text_color(rgb(0xeeeeea))
            .child(
                div()
                    .id("window-drag-region")
                    .flex_1()
                    .h_full()
                    .px_3()
                    .flex()
                    .items_center()
                    .on_mouse_down(MouseButton::Left, |event, window, cx| {
                        if event.click_count == 2 {
                            window.titlebar_double_click();
                        } else {
                            window.start_window_move();
                        }
                        cx.stop_propagation();
                    })
                    .on_mouse_down(MouseButton::Right, |event, window, cx| {
                        window.show_window_menu(event.position);
                        cx.stop_propagation();
                    })
                    .child(title),
            )
            .child(
                frame_button("window-minimize", "−")
                    .on_click(|_, window, _| window.minimize_window()),
            )
            .child(
                frame_button("window-maximize", "□").on_click(|_, window, _| window.zoom_window()),
            )
            .child(frame_button("window-close", "×").on_click(cx.listener(
                |runtime, _, window, cx| {
                    if runtime.native_close_requested(cx) {
                        window.remove_window();
                    }
                },
            )));
        let mut frame = div()
            .id("window-frame")
            .size_full()
            .relative()
            .bg(rgb(0x526874))
            .when(!tiling.top, |el| el.pt(inset))
            .when(!tiling.bottom, |el| el.pb(inset))
            .when(!tiling.left, |el| el.pl(inset))
            .when(!tiling.right, |el| el.pr(inset))
            .child(
                div()
                    .size_full()
                    .min_h_0()
                    .flex()
                    .flex_col()
                    .child(titlebar)
                    .child(
                        div()
                            .flex_1()
                            .min_h_0()
                            .w_full()
                            .overflow_hidden()
                            .child(content),
                    ),
            );
        for (name, edge, cursor, enabled) in [
            (
                "top",
                ResizeEdge::Top,
                CursorStyle::ResizeUpDown,
                !tiling.top,
            ),
            (
                "bottom",
                ResizeEdge::Bottom,
                CursorStyle::ResizeUpDown,
                !tiling.bottom,
            ),
            (
                "left",
                ResizeEdge::Left,
                CursorStyle::ResizeLeftRight,
                !tiling.left,
            ),
            (
                "right",
                ResizeEdge::Right,
                CursorStyle::ResizeLeftRight,
                !tiling.right,
            ),
            (
                "top-left",
                ResizeEdge::TopLeft,
                CursorStyle::ResizeUpLeftDownRight,
                !tiling.top && !tiling.left,
            ),
            (
                "top-right",
                ResizeEdge::TopRight,
                CursorStyle::ResizeUpRightDownLeft,
                !tiling.top && !tiling.right,
            ),
            (
                "bottom-left",
                ResizeEdge::BottomLeft,
                CursorStyle::ResizeUpRightDownLeft,
                !tiling.bottom && !tiling.left,
            ),
            (
                "bottom-right",
                ResizeEdge::BottomRight,
                CursorStyle::ResizeUpLeftDownRight,
                !tiling.bottom && !tiling.right,
            ),
        ] {
            if !enabled {
                continue;
            }
            let grip = div().id(name).absolute().cursor(cursor);
            let grip = match edge {
                ResizeEdge::Top => grip.top_0().left_0().w_full().h(inset),
                ResizeEdge::Bottom => grip.bottom_0().left_0().w_full().h(inset),
                ResizeEdge::Left => grip.top_0().left_0().h_full().w(inset),
                ResizeEdge::Right => grip.top_0().right_0().h_full().w(inset),
                ResizeEdge::TopLeft => grip.top_0().left_0().size(inset * 2.),
                ResizeEdge::TopRight => grip.top_0().right_0().size(inset * 2.),
                ResizeEdge::BottomLeft => grip.bottom_0().left_0().size(inset * 2.),
                ResizeEdge::BottomRight => grip.bottom_0().right_0().size(inset * 2.),
            };
            frame = frame.child(grip.on_mouse_down(MouseButton::Left, move |_, window, cx| {
                window.start_window_resize(edge);
                cx.stop_propagation();
            }));
        }
        frame.into_any_element()
    }
}

fn frame_button(id: &'static str, label: &'static str) -> Stateful<Div> {
    div()
        .id(id)
        .debug_selector(move || id.to_owned())
        .w(px(42.))
        .h_full()
        .flex()
        .items_center()
        .justify_center()
        .cursor_pointer()
        .hover(|el| el.bg(rgb(0x45616f)))
        .child(label)
}
