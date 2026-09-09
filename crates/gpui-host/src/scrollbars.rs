//! Scrollbar presentation uses GPUI's existing scroll offsets, without graph work.
use gpui::{prelude::*, *};
use std::{cell::Cell, rc::Rc};

#[derive(Clone, Default)]
pub(crate) struct State(Rc<Cell<Option<(Axis, f32)>>>);

#[derive(Clone, Copy)]
struct Bar {
    axis: Axis,
    track: Bounds<Pixels>,
    thumb: Bounds<Pixels>,
    max: Pixels,
}

fn geometry(bounds: Bounds<Pixels>, max: Size<Pixels>, offset: Point<Pixels>) -> Vec<Bar> {
    let mut bars = Vec::with_capacity(2);
    for axis in [Axis::Vertical, Axis::Horizontal] {
        let (extent, limit, position, other) = match axis {
            Axis::Vertical => (bounds.size.height, max.height, offset.y, max.width),
            Axis::Horizontal => (bounds.size.width, max.width, offset.x, max.height),
        };
        if limit <= px(0.) || extent <= px(0.) {
            continue;
        }
        let length = (extent - if other > px(0.) { px(12.) } else { px(0.) }).max(px(0.));
        if length <= px(0.) {
            continue;
        }
        let thumb_length = (length * (extent / (extent + limit)))
            .max(px(24.))
            .min(length);
        let start = (length - thumb_length) * (-position / limit).clamp(0., 1.);
        let (track, thumb) = match axis {
            Axis::Vertical => (
                Bounds::new(
                    point(bounds.right() - px(12.), bounds.top()),
                    size(px(12.), length),
                ),
                Bounds::new(
                    point(bounds.right() - px(12.), bounds.top() + start),
                    size(px(12.), thumb_length),
                ),
            ),
            Axis::Horizontal => (
                Bounds::new(
                    point(bounds.left(), bounds.bottom() - px(12.)),
                    size(length, px(12.)),
                ),
                Bounds::new(
                    point(bounds.left() + start, bounds.bottom() - px(12.)),
                    size(thumb_length, px(12.)),
                ),
            ),
        };
        bars.push(Bar {
            axis,
            track,
            thumb,
            max: limit,
        });
    }
    bars
}

impl Bar {
    fn coordinate(self, point: Point<Pixels>) -> Pixels {
        match self.axis {
            Axis::Vertical => point.y,
            Axis::Horizontal => point.x,
        }
    }
    fn length(self, bounds: Bounds<Pixels>) -> Pixels {
        match self.axis {
            Axis::Vertical => bounds.size.height,
            Axis::Horizontal => bounds.size.width,
        }
    }
    fn scroll(self, position: Point<Pixels>, grab: f32, handle: &ScrollHandle) {
        let travel = self.length(self.track) - self.length(self.thumb);
        if travel <= px(0.) {
            return;
        }
        let fraction = ((self.coordinate(position)
            - self.coordinate(self.track.origin)
            - self.length(self.thumb) * grab)
            / travel)
            .clamp(0., 1.);
        let mut offset = handle.offset();
        match self.axis {
            Axis::Vertical => offset.y = -self.max * fraction,
            Axis::Horizontal => offset.x = -self.max * fraction,
        }
        handle.set_offset(offset);
    }
}

/// Overlays controls after the content paints, using its measured viewport and
/// retained GPUI offset. No extra layout container or app event is introduced.
pub(crate) fn wrap(
    content: impl IntoElement,
    handle: ScrollHandle,
    state: State,
) -> impl IntoElement {
    wrap_axes(content, handle, state, true, true)
}

/// Restricts controls to explicitly scrollable axes; clipped overflow stays
/// clipped even when GPUI reports content beyond the viewport on that axis.
pub(crate) fn wrap_axes(
    content: impl IntoElement,
    handle: ScrollHandle,
    state: State,
    horizontal: bool,
    vertical: bool,
) -> impl IntoElement {
    Surface {
        axes: [horizontal, vertical],
        content: content.into_any_element(),
        handle,
        state,
    }
}

fn limits(handle: &ScrollHandle, axes: [bool; 2]) -> Size<Pixels> {
    let max = handle.max_offset();
    size(
        if axes[0] { max.width } else { px(0.) },
        if axes[1] { max.height } else { px(0.) },
    )
}

struct Surface {
    axes: [bool; 2],
    content: AnyElement,
    handle: ScrollHandle,
    state: State,
}
impl IntoElement for Surface {
    type Element = Self;
    fn into_element(self) -> Self {
        self
    }
}
impl Element for Surface {
    type RequestLayoutState = ();
    type PrepaintState = Vec<(Bar, Hitbox)>;
    fn id(&self) -> Option<ElementId> {
        None
    }
    fn source_location(&self) -> Option<&'static std::panic::Location<'static>> {
        None
    }
    fn request_layout(
        &mut self,
        _: Option<&GlobalElementId>,
        _: Option<&InspectorElementId>,
        window: &mut Window,
        cx: &mut App,
    ) -> (LayoutId, ()) {
        (self.content.request_layout(window, cx), ())
    }
    fn prepaint(
        &mut self,
        _: Option<&GlobalElementId>,
        _: Option<&InspectorElementId>,
        _: Bounds<Pixels>,
        _: &mut (),
        window: &mut Window,
        cx: &mut App,
    ) -> Self::PrepaintState {
        self.content.prepaint(window, cx);
        geometry(
            self.handle.bounds(),
            limits(&self.handle, self.axes),
            self.handle.offset(),
        )
        .into_iter()
        .map(|bar| (bar, window.insert_hitbox(bar.track, HitboxBehavior::Normal)))
        .collect()
    }
    fn paint(
        &mut self,
        _: Option<&GlobalElementId>,
        _: Option<&InspectorElementId>,
        _: Bounds<Pixels>,
        _: &mut (),
        bars: &mut Self::PrepaintState,
        window: &mut Window,
        cx: &mut App,
    ) {
        self.content.paint(window, cx);
        for (bar, hitbox) in bars.iter() {
            window.paint_quad(fill(bar.track, rgb(0x273942)));
            window.paint_quad(fill(bar.thumb, rgb(0x91aab6)));
            window.set_cursor_style(CursorStyle::Arrow, hitbox);
        }
        let bars = bars.clone();
        let state = self.state.clone();
        let handle = self.handle.clone();
        window.on_mouse_event(move |event: &MouseDownEvent, phase, window, cx| {
            if !phase.bubble() || event.button != MouseButton::Left {
                return;
            }
            if let Some((bar, _)) = bars.iter().find(|(_, hitbox)| hitbox.is_hovered(window)) {
                let grab = if bar.thumb.contains(&event.position) {
                    (bar.coordinate(event.position) - bar.coordinate(bar.thumb.origin))
                        / bar.length(bar.thumb)
                } else {
                    0.5
                };
                state.0.set(Some((bar.axis, grab)));
                bar.scroll(event.position, grab, &handle);
                window.prevent_default();
                cx.stop_propagation();
                window.refresh();
            }
        });
        let state = self.state.clone();
        let handle = self.handle.clone();
        let axes = self.axes;
        window.on_mouse_event(move |event: &MouseMoveEvent, phase, window, cx| {
            if !phase.bubble() {
                return;
            }
            if let Some((axis, grab)) = state.0.get() {
                if event.pressed_button != Some(MouseButton::Left) {
                    state.0.set(None);
                    return;
                }
                if let Some(bar) = geometry(handle.bounds(), limits(&handle, axes), handle.offset())
                    .into_iter()
                    .find(|bar| bar.axis == axis)
                {
                    bar.scroll(event.position, grab, &handle);
                    cx.stop_propagation();
                    window.refresh();
                }
            }
        });
        let state = self.state.clone();
        window.on_mouse_event(move |event: &MouseUpEvent, _, _, _| {
            if event.button == MouseButton::Left {
                state.0.set(None);
            }
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[::core::prelude::v1::test]
    fn thumbs_cover_endpoints_and_fit_small_viewports() {
        let bounds = Bounds::new(point(px(20.), px(30.)), size(px(200.), px(100.)));
        assert!(geometry(bounds, size(px(0.), px(0.)), point(px(0.), px(0.))).is_empty());
        let top = geometry(bounds, size(px(0.), px(900.)), point(px(0.), px(0.)))[0];
        let bottom = geometry(bounds, size(px(0.), px(900.)), point(px(0.), px(-900.)))[0];
        assert_eq!(top.thumb.top(), bounds.top());
        assert_eq!(bottom.thumb.bottom(), bounds.bottom());
        assert_eq!(top.thumb.size.height, px(24.));
        let tiny = geometry(
            Bounds::new(bounds.origin, size(px(8.), px(8.))),
            size(px(0.), px(100.)),
            point(px(0.), px(-100.)),
        )[0];
        assert_eq!(tiny.thumb.size.height, px(8.));
    }
}
