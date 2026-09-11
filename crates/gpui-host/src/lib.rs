mod assets;
mod bridge;
mod protocol_gen;
mod controls;
mod dialog;
mod drag;
mod effects;
mod http;
mod workers;
mod file_io;
mod input;
mod probe;
mod script;
mod scrollbars;
mod shortcut;
mod fonts;
mod timers;
mod window_frame;
mod window_lifecycle;
use bridge::{ControlKind, Engine, Node, Payload, Role};
use gpui::{div, prelude::*, px, rgb, *};
#[cfg(not(test))]
use std::time::Duration;
use std::{cell::Cell, collections::HashMap, rc::Rc};

struct NodeView {
    node: Node,
    scroll: UniformListScrollHandle,
    scrollbars: scrollbars::State,
    input: Option<Entity<input::TextInput>>,
    focus: FocusHandle,
    focus_subscription: Option<Subscription>,
    runtime: WeakEntity<Runtime>,
    renders: Rc<Cell<u64>>,
    child_visits: Rc<Cell<u64>>,
}
impl NodeView {
    // A retained wrapper may represent a new engine lifetime in a later
    // publication. Each editor callback owns that lifetime and binding snapshot.
    fn make_input(
        node: &Node,
        runtime: WeakEntity<Runtime>,
        cx: &mut App,
    ) -> Option<Entity<input::TextInput>> {
        if node.input == 0 {
            return None;
        }
        let event = node.input;
        let id = node.id;
        let lifetime = node.lifetime;
        Some(cx.new(|cx| {
            let callback: Rc<dyn Fn(String, &mut App)> = Rc::new(move |value, cx| {
                let _ = runtime.update(cx, |runtime, cx| {
                    runtime.event_if_live(id, lifetime, event, Payload::InputValue(&value), cx)
                });
            });
            let mut input = if node.kind == ControlKind::Textarea {
                input::TextInput::new_multiline(node.value.clone(), callback, cx)
            } else {
                input::TextInput::new(node.value.clone(), callback, cx)
            };
            input.set_placeholder(&node.placeholder, cx);
            input.set_style_foreground(editor_style_foreground(node.style), cx);
            input
        }))
    }
}
impl Render for NodeView {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        self.renders.set(self.renders.get() + 1);
        // Bounds recording is opt-in so that an ordinary run installs no
        // listener at all. The identities are filled in below, once the child
        // views for this frame are known; prepaint runs after render returns.
        let probed = probe::enabled().then(|| Rc::new(std::cell::RefCell::new(Vec::new())));
        let mut base = div();
        if let Some(probed) = &probed {
            let probed: Rc<std::cell::RefCell<Vec<String>>> = probed.clone();
            base = base.on_children_prepainted(move |bounds, window, _| {
                probe::record_viewport(window.viewport_size());
                let identities = probed.borrow();
                let start = bounds.len().saturating_sub(identities.len());
                for (identity, bounds) in identities.iter().zip(&bounds[start..]) {
                    probe::record(identity, *bounds);
                }
            });
        }
        let mut element = base
            .id(("node", self.node.id))
            .flex()
            .flex_col()
            .gap_2()
            .debug_selector(|| self.node.test_id.clone());
        if self.node.kind == ControlKind::Root {
            element = element.min_w_full().min_h_full().flex_shrink_0();
        }
        element = drag::install(element, &self.node, cx.entity_id(), self.runtime.clone());
        if self.focus_subscription.is_none() && self.focus_target(cx).is_some() {
            let focus = self.focus_target(cx).unwrap();
            self.focus_subscription = Some(cx.on_focus(&focus, window, |view, window, cx| {
                if let Some(focus) = view.focus_target(cx) {
                    if focus.is_focused(window) {
                        let owner = cx.entity().downgrade();
                        let _ = view.runtime.update(cx, |runtime, _| {
                            runtime.dialogs.focused = Some(dialog::SavedFocus {
                                owner,
                                lifetime: view.node.lifetime,
                                handle: focus.downgrade(),
                            });
                        });
                    }
                }
            }));
        }
        if self.node.kind == ControlKind::Button || self.node.role == Role::Checkbox {
            let runtime = self.runtime.clone();
            let id = self.node.id;
            let view_id = cx.entity_id();
            let lifetime = self.node.lifetime;
            let binding = if self.node.role == Role::Checkbox {
                self.node.check
            } else {
                self.node.click
            };
            element = controls::install(
                element,
                &self.focus,
                self.node.role == Role::Checkbox,
                self.node.disabled,
                move |cx| {
                    runtime
                        .update(cx, |runtime, cx| {
                            runtime.activate_if_live(id, view_id, lifetime, binding, cx)
                        })
                        .unwrap_or(false)
                },
            );
        }
        if !self.node.shortcuts.is_empty() && !self.node.disabled {
            let runtime = self.runtime.clone();
            let node_id = self.node.id;
            let view_id = cx.entity_id();
            let lifetime = self.node.lifetime;
            element =
                shortcut::install(element, self.node.shortcuts.clone(), move |binding, cx| {
                    runtime
                        .update(cx, |runtime, cx| {
                            runtime.shortcut_if_live(node_id, view_id, lifetime, binding, cx)
                        })
                        .unwrap_or(false)
                });
            if self.input.is_none() {
                let focus = self.focus.clone();
                element = element.track_focus(&self.focus).on_mouse_down(
                    MouseButton::Left,
                    move |_, window, cx| {
                        if !focus.contains_focused(window, cx) {
                            focus.focus(window);
                        }
                    },
                );
            }
        }
        if self.node.kind == ControlKind::Button {
            element = element.px_3().py_1().rounded_md().bg(rgb(0x335061));
            if !self.node.disabled {
                let (hover, active) = button_state_backgrounds(self.node.style);
                if let Some(color) = hover {
                    element = element.hover(move |style| style.bg(rgb(color)));
                }
                if let Some(color) = active {
                    element = element.active(move |style| style.bg(rgb(color)));
                }
                let runtime = self.runtime.clone();
                let node_id = self.node.id;
                let view_id = cx.entity_id();
                let lifetime = self.node.lifetime;
                let binding = if self.node.role == Role::Checkbox {
                    self.node.check
                } else {
                    self.node.click
                };
                element = element.cursor_pointer().on_click(move |_, _, cx| {
                    let _ = runtime.update(cx, |runtime, cx| {
                        runtime.activate_if_live(node_id, view_id, lifetime, binding, cx)
                    });
                });
            }
        }
        if self.node.role == Role::Checkbox {
            element = element
                .flex_row()
                .items_center()
                .child(if self.node.checked { "☑" } else { "☐" })
                .child(self.node.label.clone());
            if !self.node.disabled {
                let runtime = self.runtime.clone();
                let node_id = self.node.id;
                let view_id = cx.entity_id();
                let lifetime = self.node.lifetime;
                let binding = if self.node.role == Role::Checkbox {
                    self.node.check
                } else {
                    self.node.click
                };
                element = element.cursor_pointer().on_click(move |_, _, cx| {
                    let _ = runtime.update(cx, |runtime, cx| {
                        runtime.activate_if_live(node_id, view_id, lifetime, binding, cx)
                    });
                });
            }
        }
        if self.node.kind.is_heading() {
            element = element.text_2xl().font_weight(FontWeight::SEMIBOLD);
        }
        // An explicit family joins GPUI's inherited text style, so descendants
        // without their own family render with this one.
        if !self.node.font_family.is_empty() {
            element = element.font_family(self.node.font_family.clone());
        }
        if let Some(style) = self.node.style {
            element = apply_style(element, style, self.parent_direction(cx));
        }
        if self.node.selected {
            element = element.border_2().border_color(rgb(0x70c5e8));
        }
        if self.node.disabled {
            element = element.opacity(0.45);
        }

        if self.node.kind == ControlKind::Image {
            let radius = self.node.style.map_or(0, |style| style.radius);
            element = element.flex_shrink_0().overflow_hidden();
            element = match assets::resolve(&self.node.image_source) {
                Some(path) => element.child(
                    img(path)
                        .size_full()
                        .rounded(px(radius as f32))
                        .object_fit(ObjectFit::Cover)
                        .with_fallback(move || missing_image(radius).into_any_element()),
                ),
                // An invalid or unresolvable source renders a neutral surface
                // sized by the element's style, never a filesystem access.
                None => element.child(missing_image(radius)),
            };
        }
        if !self.node.text.is_empty() {
            element = element.child(self.node.text.clone());
        }
        if let Some(input) = &self.input {
            let constrained = self.node.kind == ControlKind::Textarea
                && self.node.style.is_some_and(|style| style.height_kind != 0);
            if constrained {
                element = element.min_h_0();
            }
            // Multiline editors keep a visible caption above the text; the
            // empty-field hint is the app-declared placeholder on every field.
            if self.node.kind == ControlKind::Textarea {
                element = element.child(
                    div()
                        .text_sm()
                        .text_color(rgb(0xa9bfcc))
                        .child(self.node.label.clone()),
                );
            }
            let chrome = editor_field_chrome(self.node.style);
            element = element.child(
                div()
                    .bg(rgb(chrome.background))
                    .text_color(rgb(chrome.foreground))
                    .text_size(px(chrome.font_size))
                    .line_height(px(chrome.font_size * 1.875))
                    .border_1()
                    .border_color(rgb(chrome.border))
                    .map(|element| match chrome.radius {
                        Some(radius) => element.rounded(px(radius)),
                        None => element.rounded_md(),
                    })
                    .p_2()
                    .when(constrained, |element| {
                        element.flex().flex_col().flex_1().min_h_0()
                    })
                    .child(input.clone()),
            );
        }
        let parent = self.node.id;
        if self.node.row_height != 0 {
            let runtime = self.runtime.clone();
            let height = px(self.node.row_height as f32);
            let visits = self.child_visits.clone();
            let list = uniform_list(
                ("viewport", parent),
                self.node.child_count,
                move |range, _, cx| {
                    visits.set(visits.get() + range.len() as u64);
                    let runtime = runtime.upgrade().expect("viewport outlived runtime");
                    let runtime = runtime.read(cx);
                    range
                        .map(|rank| {
                            let id = runtime.engine.child_at(parent, rank);
                            let child = runtime
                                .nodes
                                .get(&id)
                                .expect("missing viewport child identity")
                                .clone();
                            let mut style = StyleRefinement::default();
                            style.size.width = Some(relative(1.).into());
                            style.size.height = Some(height.into());
                            // A column context, like the viewport element the
                            // rows belong to, so a Fill row resolves its axes
                            // exactly as it would outside the virtual list.
                            let row = div()
                                .id(("row", id))
                                .flex()
                                .flex_col()
                                .h(height)
                                .w_full()
                                .overflow_hidden();
                            if child.read(cx).node.kind == ControlKind::Dialog {
                                row
                            } else {
                                row.child(AnyView::from(child).cached(style))
                            }
                        })
                        .collect::<Vec<_>>()
                },
            )
            .track_scroll(self.scroll.clone())
            .size_full();
            return scrollbars::wrap_axes(
                element.child(list),
                self.scroll.0.borrow().base_handle.clone(),
                self.scrollbars.clone(),
                self.node.style.is_some_and(|style| style.overflow_x == 2),
                true,
            )
            .into_any_element();
        }
        self.child_visits
            .set(self.child_visits.get() + self.node.child_count as u64);
        let runtime = self.runtime.upgrade().expect("view outlived runtime");
        let runtime = runtime.read(cx);
        let children = (0..self.node.child_count)
            .filter_map(|rank| {
                let id = runtime.engine.child_at(parent, rank);
                let child = runtime.nodes.get(&id).expect("missing child identity");
                (child.read(cx).node.kind != ControlKind::Dialog).then(|| AnyView::from(child.clone()))
            })
            .collect::<Vec<_>>();
        if let Some(probed) = &probed {
            *probed.borrow_mut() = (0..self.node.child_count)
                .filter_map(|rank| {
                    let id = runtime.engine.child_at(parent, rank);
                    let child = runtime.nodes.get(&id)?.read(cx);
                    (child.node.kind != ControlKind::Dialog)
                        .then(|| child.node.test_id.clone())
                })
                .collect();
        }
        let element = element.children(children);
        if self
            .node
            .style
            .is_some_and(|style| style.overflow_x == 2 || style.overflow_y == 2)
        {
            let handle = self.scroll.0.borrow().base_handle.clone();
            scrollbars::wrap_axes(
                element.track_scroll(&handle),
                handle,
                self.scrollbars.clone(),
                self.node.style.unwrap().overflow_x == 2,
                self.node.style.unwrap().overflow_y == 2,
            )
            .into_any_element()
        } else {
            element.into_any_element()
        }
    }
}
/// Neutral stand-in for a missing or undecodable image, on theme surfaces.
fn missing_image(radius: u32) -> Div {
    div()
        .size_full()
        .bg(rgb(0x1b2a33))
        .border_1()
        .border_color(rgb(0x3a4f5c))
        .rounded(px(radius as f32))
}

impl NodeView {
    /// The committed parent's layout direction (row=0, column=1) decides which
    /// of this element's axes is the parent's main axis. An absent parent or
    /// style is the column default: the host lays out the root column-wise.
    fn parent_direction(&self, cx: &App) -> u32 {
        self.node
            .parent
            .and_then(|id| {
                let runtime = self.runtime.upgrade()?;
                let runtime = runtime.read(cx);
                let parent = runtime.nodes.get(&id)?;
                parent.read(cx).node.style.map(|style| style.direction)
            })
            .unwrap_or(1)
    }
}

/// Chrome for the retained editor field inside an input or textarea element.
struct EditorFieldChrome {
    background: u32,
    foreground: u32,
    border: u32,
    /// None keeps the host's standard medium rounding; a zero radius is not
    /// expressible, exactly as font size zero means inherit.
    radius: Option<f32>,
    font_size: f32,
}

/// Resolves the element's style record into the editor field. Explicit
/// background, foreground, and border colors replace the host's dark
/// defaults; a nonzero radius and font size replace the standard rounding
/// and 16-pixel editor text (line height stays proportional at 1.875x).
/// Every field at its sentinel keeps today's exact chrome. The foreground
/// also drives the placeholder at reduced alpha and the cursor and
/// selection tint, so a light-background editor stays legible throughout.
fn editor_field_chrome(style: Option<bridge::Style>) -> EditorFieldChrome {
    let color = |explicit: Option<u32>, default: u32| {
        explicit
            .filter(|color| *color <= 0xffffff)
            .unwrap_or(default)
    };
    EditorFieldChrome {
        background: color(style.map(|style| style.background), 0x0f1b21),
        foreground: color(style.map(|style| style.foreground), 0xeaf0f3),
        border: color(style.map(|style| style.border_color), 0x3a4f5c),
        radius: style
            .filter(|style| style.radius != 0)
            .map(|style| style.radius as f32),
        font_size: style
            .filter(|style| style.font_size != 0)
            .map_or(16., |style| style.font_size as f32),
    }
}

/// The explicit style foreground, if any, for the editor's cursor and
/// selection tint; the inherit sentinel keeps the host's accent constants.
fn editor_style_foreground(style: Option<bridge::Style>) -> Option<u32> {
    style
        .map(|style| style.foreground)
        .filter(|color| *color <= 0xffffff)
}

/// Resolves an enabled button's hover and active backgrounds. An explicit
/// style-v2 state color always wins. With both state fields at their inherit
/// sentinel, a default-background button keeps the host's standard feedback,
/// and an explicitly colored button changes nothing on hover or press -
/// exactly the pre-v2 behavior. Checkboxes deliberately take no state
/// backgrounds: their feedback is the glyph and cursor, and a row-wide
/// highlight would misstate their hit area.
fn button_state_backgrounds(style: Option<bridge::Style>) -> (Option<u32>, Option<u32>) {
    let default_background = style.is_none_or(|style| style.background > 0xffffff);
    let resolve = |explicit: Option<u32>, host_default: u32| {
        explicit
            .filter(|color| *color <= 0xffffff)
            .or_else(|| default_background.then_some(host_default))
    };
    (
        resolve(style.map(|style| style.hover_background), 0x3f6175),
        resolve(style.map(|style| style.active_background), 0x2b4452),
    )
}

fn apply_style(
    mut element: Stateful<Div>,
    style: bridge::Style,
    parent_direction: u32,
) -> Stateful<Div> {
    element = if style.direction == 0 {
        element.flex_row()
    } else {
        element.flex_col()
    };
    element = element
        .gap(px(style.gap as f32))
        .p(px(style.padding as f32));
    // Fill means the parent's content box. On the parent's main axis a
    // percentage would resolve against the border box (overshooting padded
    // parents) and degenerate to the content size under the auto-height root,
    // so Fill becomes flex distribution of the free space instead: a zero
    // preferred size with grow and a zero minimum, so the element's own
    // content never inflates the allocation. A Fill region owns its own
    // overflow - it clips or scrolls rather than pushing past the padding.
    // On the cross axis, taffy resolves the percentage against the parent's
    // content box, which is exactly the contract.
    element = match style.width_kind {
        1 if parent_direction == 0 => element.w(px(0.)).flex_grow().min_w_0(),
        1 => element.w_full(),
        2 => element.w(px(style.width as f32)),
        _ => element,
    };
    element = match style.height_kind {
        1 if parent_direction == 1 => element.h(px(0.)).flex_grow().min_h_0(),
        1 => element.h_full(),
        2 => element.h(px(style.height as f32)),
        _ => element,
    };
    if style.grow != 0 {
        element = element.flex_grow();
    }
    if style.background <= 0xffffff {
        element = element.bg(rgb(style.background));
    }
    if style.foreground <= 0xffffff {
        element = element.text_color(rgb(style.foreground));
    }
    if style.border_color <= 0xffffff {
        element = element.border_color(rgb(style.border_color));
    }
    element = element
        .border(px(style.border_width as f32))
        .rounded(px(style.radius as f32));
    if style.font_size != 0 {
        element = element.text_size(px(style.font_size as f32));
    }
    // A clipped or scrollable region must be able to shrink below its
    // content's intrinsic size, or the viewport can never bind it.
    element = match style.overflow_x {
        1 => element.overflow_x_hidden().min_w_0(),
        2 => element.overflow_x_scroll().min_w_0(),
        _ => element,
    };
    match style.overflow_y {
        1 => element.overflow_y_hidden().min_h_0(),
        2 => element.overflow_y_scroll().min_h_0(),
        _ => element,
    }
}

struct Runtime {
    content_scroll: ScrollHandle,
    content_scrollbars: scrollbars::State,
    trace_engine: bool,
    unfocused_keys: Option<Subscription>,
    engine: Engine,
    dialogs: dialog::Dialogs,
    window_lifecycle: window_lifecycle::Lifecycle,
    /// Window identity decided by the graph but not yet handed to the platform
    /// window. `Runtime::new` runs before a window exists and a title-only turn
    /// touches no render slot, so the decision is carried to the next frame
    /// rather than applied from inside the engine turn.
    pending_title: Option<String>,
    nodes: HashMap<u64, Entity<NodeView>>,
    roots: Vec<Entity<NodeView>>,
    renders: Rc<Cell<u64>>,
    child_visits: Rc<Cell<u64>>,
    timers: timers::Manager,
    fonts: fonts::Registry,
}
impl Runtime {
    fn shortcut_if_live(
        &mut self,
        id: u64,
        view_id: EntityId,
        lifetime: u64,
        binding: shortcut::Shortcut,
        cx: &mut Context<Self>,
    ) -> bool {
        let Some(view) = self.nodes.get(&id) else {
            return false;
        };
        if view.entity_id() != view_id {
            return false;
        }
        let node = &view.read(cx).node;
        if node.disabled
            || node.lifetime != lifetime
            || binding.event == 0
            || !node.shortcuts.contains(&binding)
            || !self.dialog_allows(id, cx)
        {
            return false;
        }
        self.event(binding.event, Payload::Unit, cx);
        true
    }
    /// Collects the window identity the engine decided in this turn. Returns
    /// whether a redraw is owed: a title-only turn touches no render slot, so
    /// without this the frame that applies the title would never be scheduled.
    fn take_document_title(&mut self) -> bool {
        let Some(title) = self.engine.changed_document_title() else {
            return false;
        };
        self.pending_title = Some(title);
        true
    }
    /// Hands a decided window identity to the platform window exactly once.
    /// The engine has already pruned an unchanged title, so this never re-enters
    /// the native windowing system for a repeated value.
    fn apply_document_title(&mut self, window: &mut Window) {
        if let Some(title) = self.pending_title.take() {
            window.set_window_title(&title);
        }
    }
    fn new(clock: bool, cx: &mut Context<Self>) -> Self {
        let engine = Engine::open();
        let initial = engine.changes();
        let mut runtime = Self {
            content_scroll: gpui::ScrollHandle::new(),
            content_scrollbars: crate::scrollbars::State::default(),
            trace_engine: false,
            unfocused_keys: None,
            engine,
            dialogs: crate::dialog::Dialogs::default(),
            window_lifecycle: crate::window_lifecycle::Lifecycle::default(),
            pending_title: None,
            nodes: HashMap::new(),
            roots: vec![],
            renders: Rc::new(Cell::new(0)),
            child_visits: Rc::new(Cell::new(0)),
            timers: timers::Manager::new(clock),
            fonts: fonts::Registry::default(),
        };
        runtime.apply(initial, cx);
        crate::workers::listen(cx);
        runtime.drain_effects(cx);
        runtime
    }
    fn valid_drop(&self, target: drag::Target, item: &drag::Item, cx: &App) -> bool {
        if item.runtime != target.runtime
            || item.key.is_empty()
            || item.key.len() > 256
            || !self.dialog_allows(item.source, cx)
            || !self.dialog_allows(target.node, cx)
        {
            return false;
        }
        let Some(source) = self.nodes.get(&item.source) else {
            return false;
        };
        let source_node = &source.read(cx).node;
        if source.entity_id() != item.view
            || source_node.disabled
            || source_node.lifetime != item.lifetime
            || source_node.drag_key != item.key
        {
            return false;
        }
        let Some(destination) = self.nodes.get(&target.node) else {
            return false;
        };
        let destination_node = &destination.read(cx).node;
        destination.entity_id() == target.view
            && !destination_node.disabled
            && destination_node.lifetime == target.lifetime
            && destination_node.drop == target.event
            && target.event != 0
    }
    fn accept_drop(
        &mut self,
        target: drag::Target,
        item: &drag::Item,
        cx: &mut Context<Self>,
    ) -> bool {
        if !self.valid_drop(target, item, cx) {
            return false;
        }
        self.event(target.event, Payload::Detail(&item.key), cx);
        true
    }
    fn event_if_live(
        &mut self,
        id: u64,
        lifetime: u64,
        event: u64,
        payload: Payload<'_>,
        cx: &mut Context<Self>,
    ) {
        // A deferred editor callback may outlive disposal. Match both node and
        // binding identity so a reused slot cannot receive an old edit.
        let Some(view) = self.nodes.get(&id) else {
            return;
        };
        let node = &view.read(cx).node;
        if node.disabled
            || node.lifetime != lifetime
            || event == 0
            || node.event_for(payload) != event
            || !self.dialog_allows(id, cx)
        {
            return;
        }
        self.event(event, payload, cx);
    }
    fn event(&mut self, event: u64, payload: Payload<'_>, cx: &mut Context<Self>) {
        let changes = self.engine.event(event, payload);
        if self.trace_engine {
            eprintln!(
                "engine turn: {} touched render slots; metrics {:?}",
                changes.len(),
                self.engine.metrics()
            );
        }
        self.apply(changes, cx);
        self.drain_effects(cx);
    }
    fn timer_tick(&mut self, token: u64, cx: &mut Context<Self>) -> bool {
        let Some(changes) = self.engine.tick_timer(token) else {
            return false;
        };
        self.apply(changes, cx);
        self.drain_effects(cx);
        true
    }
    fn drain_effects(&mut self, cx: &mut Context<Self>) {
        while let Some(message) = self.engine.next_timer() {
            self.timers.accept(message, cx);
        }
        // Every prepared effect gets its own worker; the listener started in
        // `new` applies each result on the UI thread as it completes.
        while let Some(job) = self.engine.next_roc_effect() {
            crate::workers::run(self.engine.roc_effect_runner(), job);
        }
    }
    fn complete_roc_effect(&mut self, job: u64, cx: &mut Context<Self>) {
        let changes = self.engine.roc_effect_done(job);
        self.apply(changes, cx);
        self.drain_effects(cx);
    }
    /// Registers a published embedded-font declaration with the text system.
    /// Identity pruning and every bound violation live in the registry; a
    /// violation is a visible host error and never a panic.
    fn register_fonts(&mut self, declaration: &str, cx: &mut Context<Self>) {
        let pending = self.fonts.ingest(declaration);
        if pending.is_empty() {
            return;
        }
        if let Err(error) = cx.text_system().add_fonts(pending) {
            self.fonts
                .record_error(format!("embedded font registration failed: {error:#}"));
        }
    }
    #[cfg(test)]
    fn registered_font_families_for_test(&self) -> Vec<String> {
        self.fonts.registered_families()
    }
    #[cfg(test)]
    fn font_errors_for_test(&self) -> &[String] {
        self.fonts.errors()
    }
    fn apply(&mut self, changes: Vec<Node>, cx: &mut Context<Self>) {
        if changes.is_empty() {
            return;
        }
        // All native reads have completed. Materialize new entity identities
        // before wiring the engine-selected child lists, regardless of batch order.
        self.nodes.reserve(changes.len());
        for node in changes.iter().filter(|n| n.active) {
            if !node.fonts.is_empty() {
                self.register_fonts(&node.fonts, cx);
            }
            assert!(
                node.kind != ControlKind::Unknown,
                "unsupported spike element: {}",
                node.tag
            );
            if !self.nodes.contains_key(&node.id) {
                let weak = cx.entity().downgrade();
                let renders = self.renders.clone();
                let child_visits = self.child_visits.clone();
                let view = cx.new(|cx| {
                    let input = NodeView::make_input(node, weak.clone(), cx);
                    NodeView {
                        node: node.clone(),
                        scroll: UniformListScrollHandle::default(),
                        scrollbars: scrollbars::State::default(),
                        input,
                        focus: cx.focus_handle(),
                        focus_subscription: None,
                        runtime: weak,
                        renders,
                        child_visits,
                    }
                });
                self.nodes.insert(node.id, view);
            }
        }
        let mut roots_changed = false;
        for node in changes.iter().filter(|n| n.active) {
            let view = self.nodes[&node.id].clone();
            if node.kind == ControlKind::Root && !self.roots.iter().any(|r| r.entity_id() == view.entity_id()) {
                self.roots.push(view.clone());
                roots_changed = true;
            }
            view.update(cx, |view, cx| {
                if view.node.lifetime != node.lifetime
                    || view.node.input != node.input
                    || view.node.tag != node.tag
                {
                    view.input = NodeView::make_input(node, view.runtime.clone(), cx);
                    view.focus_subscription = None;
                }
                if let Some(input) = &view.input {
                    input.update(cx, |input, cx| {
                        input.set_value(&node.value, cx);
                        input.set_placeholder(&node.placeholder, cx);
                        input.set_style_foreground(editor_style_foreground(node.style), cx);
                        input.set_disabled(node.disabled, cx);
                        input.set_read_only(node.read_only, cx);
                        input.set_fill_height(
                            node.kind == ControlKind::Textarea
                                && node.style.is_some_and(|style| style.height_kind != 0),
                            cx,
                        );
                    });
                }
                view.node = node.clone();
                if node.follow_tail && node.child_count != 0 {
                    view.scroll
                        .scroll_to_item_strict(node.child_count - 1, ScrollStrategy::Bottom);
                }
                cx.notify();
            });
        }
        for node in changes.iter().filter(|n| !n.active) {
            if let Some(view) = self.nodes.remove(&node.id) {
                let before = self.roots.len();
                self.roots.retain(|r| r.entity_id() != view.entity_id());
                roots_changed |= before != self.roots.len();
            }
        }
        self.sync_window_lifecycle(&changes, cx);
        let title_changed = self.take_document_title();
        if self.sync_dialogs(&changes, cx) || roots_changed || title_changed {
            cx.notify();
        }
    }
}
impl Drop for Runtime {
    fn drop(&mut self) {
        // Invalidate timer callbacks before Engine releases its values.
        self.timers.shutdown();
    }
}

impl Render for Runtime {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        if self.unfocused_keys.is_none() {
            // GPUI dispatches an unfocused window through its frame root, outside
            // the rendered div path. This one lifetime-owned subscription only
            // handles that case; focused controls keep ordinary event precedence.
            let handle = window.window_handle();
            let runtime = cx.entity().downgrade();
            self.unfocused_keys = Some(cx.intercept_keystrokes(move |event, window, cx| {
                if window.window_handle() != handle || window.focused(cx).is_some() {
                    return;
                }
                let Some(reverse) = tab_direction(&event.keystroke) else {
                    return;
                };
                let Some(runtime) = runtime.upgrade() else {
                    return;
                };
                if !runtime.read(cx).dialogs.active.is_empty() {
                    return;
                }
                if reverse {
                    window.focus_prev();
                } else {
                    window.focus_next();
                }
                window.prevent_default();
                cx.stop_propagation();
            }));
        }
        self.apply_document_title(window);
        self.prepare_window_lifecycle(window, cx);
        self.prepare_dialog_focus(window, cx);
        let mut root = div()
            .id("signals-root")
            .size_full()
            .relative()
            .bg(rgb(0x16252c))
            .text_color(rgb(0xf2f5f6))
            .on_key_down(cx.listener(|runtime, event: &KeyDownEvent, window, cx| {
                if let Some(reverse) = tab_direction(&event.keystroke)
                    && runtime.dialogs.active.is_empty()
                {
                    if reverse {
                        window.focus_prev();
                    } else {
                        window.focus_next();
                    }
                    window.prevent_default();
                    cx.stop_propagation();
                }
            }))
            .child(scrollbars::wrap(
                // Vertical-only window scrolling keeps the viewport width as
                // real layout pressure: Fill and grow children shrink and wrap
                // instead of panning the whole window sideways. Horizontal
                // scrolling stays an explicit per-element style.
                div()
                    .id("signals-content")
                    .flex()
                    .flex_col()
                    .items_start()
                    .size_full()
                    .overflow_y_scroll()
                    .track_scroll(&self.content_scroll)
                    .children(self.roots.iter().map(|root| AnyView::from(root.clone()))),
                self.content_scroll.clone(),
                self.content_scrollbars.clone(),
            ));
        for dialog in &self.dialogs.active {
            let id = dialog.id;
            let probed = probe::enabled()
                .then(|| self.nodes[&id].read(cx).node.test_id.clone())
                .filter(|test_id| !test_id.is_empty());
            root = root.child(
                div()
                    .when_some(probed, |element, test_id| {
                        element.on_children_prepainted(move |bounds, window, _| {
                            probe::record_viewport(window.viewport_size());
                            if let Some(bounds) = bounds.last() {
                                probe::record(&test_id, *bounds);
                            }
                        })
                    })
                    .id(("dialog-layer", id))
                    .absolute()
                    .inset_0()
                    .size_full()
                    .flex()
                    .items_center()
                    .justify_center()
                    .bg(rgba(0x00000088))
                    .occlude()
                    .capture_key_down(cx.listener(
                        move |runtime, event: &KeyDownEvent, window, cx| {
                            if runtime.dialog_key(id, event, window, cx) {
                                window.prevent_default();
                                cx.stop_propagation();
                            }
                        },
                    ))
                    .p_4()
                    // A dialog declares the width its content wants, but the
                    // window it opens in can be as small as 360x240. Bounding
                    // it here keeps every dialog — the platform default and
                    // any style an application supplies — inside the viewport
                    // it is centred in, instead of laying its heading and its
                    // safe action out past the edges where nothing can reach
                    // them. The application still owns the dialog's colours,
                    // padding and intrinsic size.
                    .child(
                        div()
                            .max_w_full()
                            .max_h_full()
                            .overflow_hidden()
                            .child(self.nodes[&id].clone()),
                    ),
            );
        }
        self.window_frame(root, window.window_decorations(), window, cx)
    }
}

/// Reads a `WIDTHxHEIGHT` content size for the review and regression captures.
///
/// Screenshot evidence has to be reproducible at each supported window size, so
/// the capture harness asks for the size instead of resizing the window through
/// a desktop automation API that is unavailable on some supported systems. The
/// value is rejected rather than clamped: a size below the window minimum would
/// silently produce a capture that does not match the size it claims to show.
fn parse_window_size(value: &str) -> Option<(f32, f32)> {
    let (width, height) = value.split_once(['x', 'X'])?;
    let width: f32 = width.trim().parse().ok()?;
    let height: f32 = height.trim().parse().ok()?;
    (width >= 360. && height >= 240. && width.is_finite() && height.is_finite())
        .then_some((width, height))
}

/// Every command-line option this launcher owns or intercepts.
///
/// Host controls live in the reserved `--host-` namespace so an application can
/// use the plain argument namespace without a host quietly capturing one of its
/// flags (roc-signals#55).
#[derive(Debug, Default, PartialEq)]
struct HostArgs {
    run_spec_json: bool,
    assets_root: Option<String>,
    trace_engine: bool,
    smoke: bool,
    smoke_timers: bool,
    click: Option<String>,
    drop_request: Option<(String, String)>,
    expected: Option<String>,
    scenario: Option<String>,
    scenario_report: Option<String>,
    scenario_hold: bool,
    window_size: Option<(f32, f32)>,
}

/// The host spellings that existed before the `--host-` namespace was reserved.
///
/// They are rejected by name rather than ignored: falling through to the
/// application would silently turn a stale command into a run with the control
/// switched off, so a smoke or capture harness would report a passing run that
/// never exercised what it named.
const RENAMED_HOST_FLAGS: &[(&str, &str)] = &[
    ("--run-spec-json", "--host-run-spec-json"),
    ("--assets-root", "--host-assets-root"),
    ("--smoke", "--host-smoke"),
    ("--smoke-timers", "--host-smoke-timers"),
    ("--smoke-click", "--host-smoke-click"),
    ("--smoke-drop", "--host-smoke-drop"),
    ("--smoke-expect", "--host-smoke-expect"),
    ("--script", "--host-scenario"),
    ("--script-report", "--host-scenario-report"),
    ("--script-hold", "--host-scenario-hold"),
    ("--window-size", "--host-window-size"),
    // The line-per-step scripts became (scenario ...) specs, parsed by the
    // engine; their choosers are answered from the header, not a flag.
    ("--host-script", "--host-scenario"),
    ("--host-script-report", "--host-scenario-report"),
    ("--host-script-hold", "--host-scenario-hold"),
    ("--host-choose", ":choose in the scenario header"),
];

/// Reads the host options out of a command line, left to right.
///
/// The scan consumes each option's values as values. A single pass is what makes
/// `--host-smoke-click --host-verbose` name a click target called
/// `--host-verbose` rather than also switching a second control on: an
/// independent search per flag cannot tell an option from the argument that
/// follows one.
fn parse_host_args(args: &[String]) -> Result<HostArgs, String> {
    fn value<'a>(
        args: &'a [String],
        index: &mut usize,
        flag: &str,
        count: usize,
    ) -> Result<&'a str, String> {
        *index += 1;
        args.get(*index).map(String::as_str).ok_or_else(|| {
            if count == 1 {
                format!("Error: {flag} requires a value")
            } else {
                format!("Error: {flag} requires {count} values")
            }
        })
    }

    let mut parsed = HostArgs::default();
    let mut i = 0;
    while i < args.len() {
        let arg = args[i].clone();
        match arg.as_str() {
            "--host-run-spec-json" => parsed.run_spec_json = true,
            "--host-trace-engine" => parsed.trace_engine = true,
            "--host-smoke" => parsed.smoke = true,
            "--host-smoke-timers" => parsed.smoke_timers = true,
            "--host-scenario-hold" => parsed.scenario_hold = true,
            "--host-assets-root" => {
                parsed.assets_root = Some(value(args, &mut i, &arg, 1)?.to_string());
            }
            "--host-smoke-click" => {
                parsed.click = Some(value(args, &mut i, &arg, 1)?.to_string());
            }
            "--host-smoke-expect" => {
                parsed.expected = Some(value(args, &mut i, &arg, 1)?.to_string());
            }
            "--host-scenario" => {
                parsed.scenario = Some(value(args, &mut i, &arg, 1)?.to_string());
            }
            "--host-scenario-report" => {
                parsed.scenario_report = Some(value(args, &mut i, &arg, 1)?.to_string());
            }
            "--host-smoke-drop" => {
                let source = value(args, &mut i, &arg, 2)?.to_string();
                let target = value(args, &mut i, &arg, 2)?.to_string();
                parsed.drop_request = Some((source, target));
            }
            "--host-window-size" => {
                let raw = value(args, &mut i, &arg, 1)?.to_string();
                parsed.window_size = Some(parse_window_size(&raw).ok_or_else(|| {
                    format!("Error: {arg} expects WIDTHxHEIGHT in pixels, got {raw:?}")
                })?);
            }
            other => {
                if let Some((old, new)) = RENAMED_HOST_FLAGS
                    .iter()
                    .find(|(old, _)| *old == other)
                    .copied()
                {
                    return Err(format!("Error: {old} is now {new}"));
                }
            }
        }
        i += 1;
    }
    Ok(parsed)
}

fn tab_direction(key: &Keystroke) -> Option<bool> {
    (key.key == "tab"
        && !key.modifiers.control
        && !key.modifiers.alt
        && !key.modifiers.platform
        && !key.modifiers.function)
        .then_some(key.modifiers.shift)
}

unsafe extern "C" {
    fn signals_spec_main(argc: i32, argv: *const *const i8) -> i32;
}

/// Snapshots every rendered control the scripted checks can name.
///
/// Iteration is ordered by engine node id so that two runs of the same script
/// produce byte-identical evidence: a report that reshuffles itself between runs
/// cannot be diffed, which is most of what makes it useful after a failure.
#[cfg(not(test))]
fn control_frame(runtime: &Runtime, window: &mut Window, cx: &App) -> Vec<script::Control> {
    let mut ids: Vec<u64> = runtime.nodes.keys().copied().collect();
    ids.sort_unstable();
    ids.iter()
        .map(|id| {
            let view = runtime.nodes[id].read(cx);
            let node = &view.node;
            let child_text = (0..node.child_count)
                .filter_map(|rank| {
                    let child = runtime.engine.child_at(node.id, rank);
                    runtime.nodes.get(&child).map(|c| c.read(cx).node.text.clone())
                })
                .filter(|text| !text.is_empty())
                .collect();
            script::Control {
                id: node.id,
                test_id: node.test_id.clone(),
                kind: format!("{:?}", node.kind),
                text: node.text.clone(),
                label: node.label.clone(),
                value: match &view.input {
                    Some(input) => input.read(cx).draft().to_string(),
                    None => node.value.clone(),
                },
                child_text,
                disabled: node.disabled,
                selected: node.selected,
                focused: view
                    .focus_target(cx)
                    .is_some_and(|focus| focus.contains_focused(window, cx)),
                activatable: node.kind == ControlKind::Button
                    || node.role == Role::Checkbox
                    || node.click != 0,
                history: view.input.as_ref().map(|input| input.read(cx).undo_depth()),
            }
        })
        .collect()
}

/// The keystroke a single typed character produces.
///
/// Typing goes through GPUI's real key dispatch rather than the editor's
/// value setter, because the behaviour under test — grouping, selection, and
/// which document owns the resulting undo entry — only exists on that path.
#[cfg(not(test))]
fn typed_keystroke(character: char) -> Keystroke {
    let key = match character {
        ' ' => "space".to_string(),
        other => other.to_lowercase().to_string(),
    };
    Keystroke {
        modifiers: Modifiers {
            shift: character.is_uppercase(),
            ..Modifiers::default()
        },
        key,
        key_char: Some(character.to_string()),
    }
}

/// Runs one script step against the live window.
///
/// Every action resolves its control from the frame that was just observed, so
/// an action and the assertion after it describe the same application state.
/// Refusals are returned rather than panicked: a script that clicks a control
/// the engine has disabled should report that, not abort the process without
/// writing its evidence.
#[cfg(not(test))]
#[derive(Default)]
struct Deferred {
    /// A control to focus before any keystrokes are dispatched.
    focus: Option<FocusHandle>,
    /// Keystrokes to dispatch once the runtime lease has been released.
    keystrokes: Vec<Keystroke>,
    /// Evidence the step produced.
    snapshot: Option<(String, String)>,
    /// Whether the application allowed the window to close; a document that
    /// asked first keeps the window, and its dialog, open.
    close: bool,
}

#[cfg(not(test))]
fn perform(
    runtime: &mut Runtime,
    window: &mut Window,
    cx: &mut Context<Runtime>,
    action: &script::Action,
) -> Result<Deferred, String> {
    let frame = control_frame(runtime, window, cx);
    match action {
        script::Action::Wait(_) => Ok(Deferred::default()),
        script::Action::Snapshot(name) => Ok(Deferred {
            snapshot: Some((name.clone(), script::frame_json(&frame))),
            ..Deferred::default()
        }),
        script::Action::Click(locator) => {
            let control = script::resolve_activatable(&frame, locator)?;
            let view = runtime
                .nodes
                .get(&control.id)
                .ok_or("the control disappeared before it could be clicked")?;
            let view_id = view.entity_id();
            let node = view.read(cx).node.clone();
            let binding = if node.role == Role::Checkbox {
                node.check
            } else {
                node.click
            };
            runtime
                .activate_if_live(node.id, view_id, node.lifetime, binding, cx)
                .then(Deferred::default)
                .ok_or_else(|| {
                    format!(
                        "the host refused to activate {}; it is disabled, retired, \
                         or covered by a modal dialog",
                        locator.describe()
                    )
                })
        }
        script::Action::Focus(locator) => {
            let control = script::resolve_preferring(&frame, locator, |control| {
                control.activatable || control.history.is_some()
            })?;
            let view = runtime
                .nodes
                .get(&control.id)
                .ok_or("the control disappeared before it could be focused")?;
            let focus = view
                .read(cx)
                .focus_target(cx)
                .ok_or_else(|| format!("{} cannot take focus", locator.describe()))?;
            Ok(Deferred {
                focus: Some(focus),
                ..Deferred::default()
            })
        }
        script::Action::Type(locator, text) => {
            let control =
                script::resolve_preferring(&frame, locator, |control| control.history.is_some())?;
            let view = runtime
                .nodes
                .get(&control.id)
                .ok_or("the editor disappeared before it could be typed into")?;
            let input = view
                .read(cx)
                .input
                .clone()
                .ok_or_else(|| format!("{} is not an editor", locator.describe()))?;
            Ok(Deferred {
                focus: Some(input.focus_handle(cx)),
                keystrokes: text.chars().map(typed_keystroke).collect(),
                ..Deferred::default()
            })
        }
        script::Action::Close => Ok(Deferred {
            // The same admission the frame's own close button uses: an
            // application with unsaved work may answer with a dialog instead.
            close: runtime.native_close_requested(cx),
            ..Deferred::default()
        }),
        script::Action::Key(keystroke) => {
            let parsed = Keystroke::parse(keystroke)
                .map_err(|error| format!("{keystroke:?} is not a keystroke: {error:?}"))?;
            Ok(Deferred {
                keystrokes: vec![parsed],
                ..Deferred::default()
            })
        }
        assertion => script::check(&frame, assertion).map(|()| Deferred::default()),
    }
}

/// Starts the GUI, or runs the shared native semantic-spec host without a display.
/// The process entry owns the runtime until all windows have closed.
#[cfg(not(test))]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn main(argc: i32, argv: *const *const i8) -> i32 {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let host = match parse_host_args(&args) {
        Ok(host) => host,
        Err(error) => {
            eprintln!("{error}");
            return 1;
        }
    };
    if host.run_spec_json {
        return unsafe { signals_spec_main(argc, argv) };
    }
    // A scenario is parsed by the engine's spec parser before the window
    // exists, so a malformed file is refused with its reason rather than
    // after a window has opened. Its header names what a run needs relative to
    // the example directory — the parent of the `specs/` directory it lives in.
    let scenario = host.scenario.as_ref().map(|path| {
        let path = std::path::PathBuf::from(path);
        let scenario = bridge::load_scenario(&path.to_string_lossy()).unwrap_or_else(|error| {
            eprintln!("Error: {error}");
            std::process::exit(1);
        });
        let steps = script::steps(&scenario).unwrap_or_else(|error| {
            eprintln!("Error: {}: {error}", path.display());
            std::process::exit(1);
        });
        let example = path
            .parent()
            .and_then(std::path::Path::parent)
            .map(std::path::Path::to_path_buf)
            .unwrap_or_default();
        probe::enable();
        (path, example, scenario, steps)
    });
    let assets_root = host
        .assets_root
        .map(std::path::PathBuf::from)
        .or_else(|| std::env::var_os("ROC_SIGNALS_ASSETS_ROOT").map(std::path::PathBuf::from))
        .or_else(|| {
            // A scenario runs against its example's own assets unless its
            // header prepared another root; the root must exist, because a
            // scenario about damaged assets that silently ran against nothing
            // would prove the wrong thing.
            let (_, example, scenario, _) = scenario.as_ref()?;
            let root = example.join(scenario.assets.as_deref().unwrap_or("assets"));
            if scenario.assets.is_some() && !root.is_dir() {
                eprintln!("Error: :assets names no directory: {}", root.display());
                std::process::exit(1);
            }
            root.is_dir().then_some(root)
        });
    if let Some(root) = assets_root {
        assets::set_root(root);
    }
    let trace_engine = host.trace_engine;
    let smoke = host.smoke;
    let smoke_timers = host.smoke_timers;
    let click = host.click;
    let drop_request = host.drop_request;
    let expected = host.expected;
    let script_report = host.scenario_report.map(std::path::PathBuf::from);
    // A held window stays open after the last step so a capture harness can
    // photograph the state the scenario left behind — including the state a
    // failing assertion stopped at, which is the evidence worth keeping.
    let script_hold = host.scenario_hold;
    // Chooser answers come from the header, resolved against the example
    // directory and required to exist: a scenario that names a fixture which
    // is not there would otherwise open a real dialog nobody can answer.
    let choices: Vec<std::path::PathBuf> = scenario
        .as_ref()
        .map(|(_, example, scenario, _)| {
            scenario
                .choices
                .iter()
                .map(|choice| {
                    let path = example.join(choice);
                    if !path.exists() {
                        eprintln!("Error: :choose names nothing on disk: {}", path.display());
                        std::process::exit(1);
                    }
                    path.canonicalize().unwrap_or(path)
                })
                .collect()
        })
        .unwrap_or_default();
    // An explicit size wins, because a capture harness states the size it
    // then verifies; otherwise the scenario's own header sizes the window.
    let window_size = host
        .window_size
        .or_else(|| scenario.as_ref().and_then(|(_, _, scenario, _)| scenario.window))
        .unwrap_or((1200., 820.));
    let script = scenario.map(|(path, _, scenario, steps)| (path, scenario, steps));
    Application::new().run(move |cx| {
        input::bind_keys(cx);
        controls::bind_keys(cx);
        cx.on_window_closed(|cx| {
            if cx.windows().is_empty() {
                cx.quit();
            }
        })
        .detach();
        let bounds = Bounds::centered(None, size(px(window_size.0), px(window_size.1)), cx);
        let window = cx
            .open_window(
                WindowOptions {
                    window_bounds: Some(WindowBounds::Windowed(bounds)),
                    titlebar: Some(TitlebarOptions {
                        title: Some("Roc Signals".into()),
                        ..Default::default()
                    }),
                    window_min_size: Some(size(px(360.), px(240.))),
                    window_decorations: Some(WindowDecorations::Client),
                    is_movable: true,
                    is_resizable: true,
                    ..Default::default()
                },
                |_, cx| {
                    cx.new(|cx| {
                        let mut runtime = Runtime::new(!smoke || smoke_timers, cx);
                        runtime.trace_engine = trace_engine;
                        effects::answer_choosers(choices);
                        runtime
                    })
                },
            )
            .unwrap();
        cx.activate(true);
        if let Some((path, scenario, steps)) = script {
            let name = path
                .file_stem()
                .map(|stem| stem.to_string_lossy().into_owned())
                .unwrap_or_else(|| path.display().to_string());
            cx.spawn(async move |cx| {
                // The first frame, any startup task, and the initial timer tick
                // all have to land before the opening assertions mean anything.
                cx.background_executor()
                    .timer(Duration::from_millis(900))
                    .await;
                let mut snapshots: Vec<(String, String)> = Vec::new();
                let mut failure: Option<String> = None;
                let mut closing = false;
                for step in &steps {
                    if let script::Action::Wait(milliseconds) = step.action {
                        cx.background_executor()
                            .timer(Duration::from_millis(milliseconds))
                            .await;
                        continue;
                    }
                    let outcome = window
                        .update(cx, |runtime, window, cx| {
                            let outcome = perform(runtime, window, cx, &step.action);
                            // Only a layout-changing step invalidates the
                            // recording, and only for controls that have gone
                            // away: a mounted node that did not re-render is
                            // not prepainted again, so wiping its bounds would
                            // read as "not laid out" on the very next line.
                            if step.action.changes_layout() {
                                let mounted = runtime
                                    .nodes
                                    .values()
                                    .map(|view| view.read(cx).node.test_id.clone())
                                    .filter(|id| !id.is_empty())
                                    .collect();
                                probe::retain_mounted(&mounted);
                                window.refresh();
                            }
                            outcome
                        })
                        .expect("the scripted window closed early");
                    let deferred = match outcome {
                        Ok(deferred) => deferred,
                        Err(error) => {
                            failure = Some(format!("line {}: {error}", step.line));
                            break;
                        }
                    };
                    if let Some(snapshot) = deferred.snapshot {
                        snapshots.push(snapshot);
                    }
                    if deferred.close {
                        // Closing is the last step, and the runtime it would be
                        // observed through goes with the window. Keep the frame
                        // the window showed as it closed, then leave through the
                        // same path a person's close does; the process exit
                        // status is the evidence of what teardown did.
                        closing = true;
                        break;
                    }
                    // Focus changes and keystrokes reach the window without the
                    // runtime lease held: they run the application's own
                    // listeners, which update the runtime themselves.
                    let handle: AnyWindowHandle = window.into();
                    if let Some(focus) = deferred.focus {
                        handle
                            .update(cx, |_, window, _| focus.focus(window))
                            .expect("the scripted window closed early");
                    }
                    // One keystroke per turn. The editor submits each committed
                    // edit as its own ordered engine turn and refuses a second
                    // before the first has been applied, exactly as a person
                    // typing cannot outrun the frame they are typing into.
                    for keystroke in deferred.keystrokes {
                        handle
                            .update(cx, |_, window, cx| {
                                window.dispatch_keystroke(keystroke, cx)
                            })
                            .expect("the scripted window closed early");
                        cx.background_executor()
                            .timer(Duration::from_millis(20))
                            .await;
                    }
                    cx.background_executor()
                        .timer(Duration::from_millis(150))
                        .await;
                }
                let (final_frame, client_frame) = window
                    .update(cx, |runtime, window, cx| {
                        (
                            script::frame_json(&control_frame(runtime, window, cx)),
                            // The frame is drawn only when the compositor
                            // delegated decorations and the window is not
                            // fullscreen, exactly the test window_frame makes.
                            !window.is_fullscreen()
                                && matches!(window.window_decorations(), Decorations::Client { .. }),
                        )
                    })
                    .expect("the scripted window closed early");
                snapshots.push(("final".into(), final_frame));
                let close_window = |cx: &mut gpui::AsyncApp| {
                    let handle: AnyWindowHandle = window.into();
                    handle
                        .update(cx, |_, window, _| window.remove_window())
                        .expect("the scripted window closed early");
                };
                if let Some(report) = &script_report {
                    // The harness owns the artifact directory: creating it here
                    // would add a directory-creation syscall to the macOS link
                    // surface for a path only the harness ever uses.
                    std::fs::write(
                        report,
                        script::report_json(
                            &name,
                            window_size,
                            client_frame,
                            scenario.diagnostic.as_deref(),
                            &scenario.scopes,
                            &snapshots,
                            failure.as_deref(),
                        ),
                    )
                    .unwrap_or_else(|error| {
                        panic!("cannot write {}: {error}", report.display())
                    });
                }
                match &failure {
                    Some(error) => eprintln!("FAIL: {name}: {error}"),
                    None => eprintln!(
                        "PASS: {name} completed {} scripted steps at {}x{}",
                        steps.len(),
                        window_size.0 as u32,
                        window_size.1 as u32
                    ),
                }
                if closing {
                    // Removing the last window quits the application from its
                    // own close handler; the run's exit status then reports
                    // whatever follow-up work outlives the runtime.
                    close_window(cx);
                    return;
                }
                if script_hold {
                    return;
                }
                cx.update(|cx| cx.quit()).unwrap();
                if failure.is_some() {
                    std::process::exit(1);
                }
            })
            .detach();
        }
        if smoke {
            cx.spawn(async move |cx| {
                cx.background_executor().timer(Duration::from_secs(2)).await;
                window
                    .update(cx, |runtime, _, cx| {
                        assert!(runtime.renders.get() > 0, "no GPUI views rendered");
                        if let Some((key, target_id)) = drop_request.as_ref() {
                            let source = runtime
                                .nodes
                                .values()
                                .find(|view| view.read(cx).node.drag_key == *key)
                                .expect("smoke drag source missing");
                            let source_node = &source.read(cx).node;
                            let item = drag::Item {
                                key: key.clone(),
                                source: source_node.id,
                                lifetime: source_node.lifetime,
                                view: source.entity_id(),
                                runtime: cx.entity_id(),
                            };
                            let destination = runtime
                                .nodes
                                .values()
                                .find(|view| view.read(cx).node.test_id == *target_id)
                                .expect("smoke drop target missing");
                            let destination_node = &destination.read(cx).node;
                            let target = drag::Target {
                                node: destination_node.id,
                                event: destination_node.drop,
                                lifetime: destination_node.lifetime,
                                view: destination.entity_id(),
                                runtime: cx.entity_id(),
                            };
                            assert!(runtime.accept_drop(target, &item, cx), "smoke drop refused");
                        }
                        if let Some(label) = click {
                            let node = runtime
                                .nodes
                                .values()
                                .find(|v| {
                                    let n = &v.read(cx).node;
                                    n.kind == bridge::ControlKind::Button
                                        && (n.text == label
                                            || (0..n.child_count).any(|rank| {
                                                let id = runtime.engine.child_at(n.id, rank);
                                                runtime.nodes[&id].read(cx).node.text == label
                                            }))
                                })
                                .expect("smoke button missing")
                                .read(cx)
                                .node
                                .clone();
                            runtime.event_if_live(
                                node.id,
                                node.lifetime,
                                node.click,
                                Payload::Unit,
                                cx,
                            );
                        }
                    })
                    .unwrap();
                cx.background_executor()
                    .timer(Duration::from_millis(if smoke_timers { 1200 } else { 300 }))
                    .await;
                window
                    .update(cx, |runtime, _, cx| {
                        if let Some((key, target_id)) = drop_request.as_ref() {
                            let source = runtime
                                .nodes
                                .values()
                                .find(|view| view.read(cx).node.drag_key == *key)
                                .expect("smoke drag source disappeared")
                                .read(cx)
                                .node
                                .id;
                            let destination = runtime
                                .nodes
                                .values()
                                .find(|view| view.read(cx).node.test_id == *target_id)
                                .expect("smoke drop target disappeared")
                                .read(cx)
                                .node
                                .id;
                            let mut ancestor = Some(source);
                            let mut reached = false;
                            for _ in 0..=runtime.nodes.len() {
                                let Some(id) = ancestor else {
                                    break;
                                };
                                if id == destination {
                                    reached = true;
                                    break;
                                }
                                ancestor = runtime
                                    .nodes
                                    .get(&id)
                                    .expect("smoke parent missing")
                                    .read(cx)
                                    .node
                                    .parent;
                            }
                            assert!(reached, "smoke drop did not move {key} into {target_id}");
                            eprintln!("PASS: dropped {key} into {target_id}");
                        }
                        if let Some(expected) = expected {
                            assert!(
                                runtime
                                    .nodes
                                    .values()
                                    .any(|v| v.read(cx).node.text == expected),
                                "expected smoke text missing: {expected}"
                            );
                        }
                        eprintln!(
                            "PASS: GPUI mounted, rendered, and checked {} retained views",
                            runtime.nodes.len()
                        );
                    })
                    .unwrap();
                cx.update(|cx| cx.quit()).unwrap();
            })
            .detach();
        }
    });
    0
}

#[cfg(test)]
mod tests {
    use super::{Engine, Node, Payload, Runtime, bridge, parse_host_args, parse_window_size};
    use gpui::Focusable;
    use gpui::{AppContext, TestAppContext, point, px, size};
    use std::{cell::Cell, collections::HashMap, rc::Rc};

    #[test]
    fn window_size_accepts_supported_capture_sizes() {
        assert_eq!(parse_window_size("1200x820"), Some((1200., 820.)));
        assert_eq!(parse_window_size("360X240"), Some((360., 240.)));
    }

    #[test]
    fn window_size_rejects_sizes_the_window_cannot_honour() {
        assert_eq!(parse_window_size("359x600"), None);
        assert_eq!(parse_window_size("800x239"), None);
        assert_eq!(parse_window_size("800"), None);
        assert_eq!(parse_window_size("widexhigh"), None);
    }

    fn host_args(args: &[&str]) -> Result<super::HostArgs, String> {
        parse_host_args(&args.iter().map(|a| (*a).to_string()).collect::<Vec<_>>())
    }

    #[test]
    fn host_flags_read_their_values() {
        let parsed = host_args(&[
            "--host-smoke",
            "--host-smoke-timers",
            "--host-smoke-click",
            "Increment",
            "--host-smoke-drop",
            "task-1",
            "column-Done",
            "--host-smoke-expect",
            "Count: 1",
            "--host-assets-root",
            "/assets",
            "--host-scenario",
            "s.scm",
            "--host-scenario-report",
            "r.json",
            "--host-scenario-hold",
            "--host-trace-engine",
            "--host-window-size",
            "800x600",
        ])
        .expect("a complete host command line parses");
        assert!(
            host_args(&["--host-choose", "/project"])
                .unwrap_err()
                .contains(":choose")
        );
        assert!(parsed.smoke && parsed.smoke_timers && parsed.scenario_hold && parsed.trace_engine);
        assert_eq!(parsed.click.as_deref(), Some("Increment"));
        assert_eq!(
            parsed.drop_request,
            Some(("task-1".into(), "column-Done".into()))
        );
        assert_eq!(parsed.expected.as_deref(), Some("Count: 1"));
        assert_eq!(parsed.assets_root.as_deref(), Some("/assets"));
        assert_eq!(parsed.scenario.as_deref(), Some("s.scm"));
        assert_eq!(parsed.scenario_report.as_deref(), Some("r.json"));
        assert_eq!(parsed.window_size, Some((800., 600.)));
    }

    #[test]
    fn application_arguments_are_left_to_the_application() {
        let parsed = host_args(&["--theme", "dark", "input.txt"])
            .expect("arguments the host does not own pass through");
        assert_eq!(parsed, super::HostArgs::default());
    }

    #[test]
    fn a_value_that_looks_like_a_flag_stays_a_value() {
        // An independent search per flag would see `--host-smoke` inside the
        // click target and switch smoke mode on; the left-to-right scan must not.
        let parsed = host_args(&["--host-smoke-click", "--host-smoke"])
            .expect("a flag-shaped value is still a value");
        assert_eq!(parsed.click.as_deref(), Some("--host-smoke"));
        assert!(!parsed.smoke);

        let parsed = host_args(&["--host-smoke-drop", "--host-script-hold", "--host-smoke"])
            .expect("both drop values are still values");
        assert_eq!(
            parsed.drop_request,
            Some(("--host-script-hold".into(), "--host-smoke".into()))
        );
        assert!(!parsed.scenario_hold && !parsed.smoke);
    }

    #[test]
    fn missing_and_invalid_values_are_reported() {
        assert_eq!(
            host_args(&["--host-smoke-click"]).unwrap_err(),
            "Error: --host-smoke-click requires a value"
        );
        assert_eq!(
            host_args(&["--host-smoke-drop", "task-1"]).unwrap_err(),
            "Error: --host-smoke-drop requires 2 values"
        );
        assert_eq!(
            host_args(&["--host-window-size", "10x10"]).unwrap_err(),
            "Error: --host-window-size expects WIDTHxHEIGHT in pixels, got \"10x10\""
        );
        assert!(host_args(&["--host-window-size"]).is_err());
    }

    #[test]
    fn pre_rename_spellings_are_named_rather_than_ignored() {
        for (old, new) in super::RENAMED_HOST_FLAGS {
            assert_eq!(
                host_args(&[old]).unwrap_err(),
                format!("Error: {old} is now {new}")
            );
        }
    }

    fn runtime() -> Runtime {
        Runtime {
            content_scroll: gpui::ScrollHandle::new(),
            content_scrollbars: crate::scrollbars::State::default(),
            trace_engine: false,
            unfocused_keys: None,
            engine: Engine::test_boundary(),
            dialogs: crate::dialog::Dialogs::default(),
            window_lifecycle: crate::window_lifecycle::Lifecycle::default(),
            pending_title: None,
            nodes: HashMap::new(),
            roots: vec![],
            renders: Rc::new(Cell::new(0)),
            child_visits: Rc::new(Cell::new(0)),
            timers: crate::timers::Manager::new(false),
            fonts: crate::fonts::Registry::default(),
        }
    }

    #[test]
    fn document_title_reaches_the_window_once_per_decided_change() {
        let mut runtime = runtime();
        Engine::set_test_document_title(0, "");
        assert!(
            !runtime.take_document_title(),
            "an engine that decided no title must not owe a frame"
        );
        assert_eq!(runtime.pending_title, None);

        Engine::set_test_document_title(1, "Notes");
        assert!(runtime.take_document_title());
        assert_eq!(runtime.pending_title.as_deref(), Some("Notes"));

        // A second turn at the same revision is the engine's equality cutoff:
        // it must not re-enter the native windowing system, and it must not
        // discard a decision the window has not applied yet.
        assert!(!runtime.take_document_title());
        assert_eq!(runtime.pending_title.as_deref(), Some("Notes"));

        Engine::set_test_document_title(2, "* Notes");
        assert!(runtime.take_document_title());
        assert_eq!(runtime.pending_title.as_deref(), Some("* Notes"));
    }

    #[test]
    fn a_remounted_engine_reapplies_its_window_identity() {
        // Close/reopen builds a fresh Engine whose applied revision starts at
        // zero, so the identity of the reopened window is decided again rather
        // than inherited from the process's previous window.
        Engine::set_test_document_title(3, "Task Board");
        let mut first = runtime();
        assert!(first.take_document_title());
        assert_eq!(first.pending_title.as_deref(), Some("Task Board"));
        let mut second = runtime();
        assert!(second.take_document_title());
        assert_eq!(second.pending_title.as_deref(), Some("Task Board"));
    }

    fn node(id: u64, tag: &str, children: &[u64]) -> Node {
        Engine::set_test_children(id, children.into());
        Node {
            id,
            kind: super::ControlKind::from_tag(tag),
            tag: tag.into(),
            active: true,
            child_count: children.len(),
            ..Default::default()
        }
    }

    #[test]
    fn button_state_backgrounds_prefer_explicit_colors_and_preserve_host_defaults() {
        // The inherit sentinel is 0x1000000; the engine never publishes zeros
        // for absent colors, so the record spells every field out.
        let sentinel = 0x1000000;
        let inherit_all = super::bridge::Style {
            background: sentinel,
            hover_background: sentinel,
            active_background: sentinel,
            foreground: sentinel,
            border_color: sentinel,
            ..Default::default()
        };
        // No style, or a style leaving the background default, keeps the
        // host's standard hover and active feedback.
        assert_eq!(
            super::button_state_backgrounds(None),
            (Some(0x3f6175), Some(0x2b4452))
        );
        assert_eq!(
            super::button_state_backgrounds(Some(inherit_all)),
            (Some(0x3f6175), Some(0x2b4452))
        );
        // An explicit background with default state colors changes nothing on
        // hover or press - the pre-v2 behavior.
        let explicit_background = super::bridge::Style {
            background: 0x2e6fa3,
            ..inherit_all
        };
        assert_eq!(
            super::button_state_backgrounds(Some(explicit_background)),
            (None, None)
        );
        // Explicit state colors always win, over both the host defaults and
        // the explicit-background suppression, independently per state.
        let explicit_states = super::bridge::Style {
            hover_background: 0x3a80b8,
            active_background: 0x265d89,
            ..explicit_background
        };
        assert_eq!(
            super::button_state_backgrounds(Some(explicit_states)),
            (Some(0x3a80b8), Some(0x265d89))
        );
        let hover_only = super::bridge::Style {
            hover_background: 0x3a80b8,
            ..explicit_background
        };
        assert_eq!(
            super::button_state_backgrounds(Some(hover_only)),
            (Some(0x3a80b8), None)
        );
        let hover_on_default_background = super::bridge::Style {
            hover_background: 0x3a80b8,
            ..inherit_all
        };
        assert_eq!(
            super::button_state_backgrounds(Some(hover_on_default_background)),
            (Some(0x3a80b8), Some(0x2b4452))
        );
    }

    #[gpui::test]
    fn native_window_close_callback_dispatches_one_live_unit_request(cx: &mut TestAppContext) {
        let mut owner = node(1, "window", &[]);
        owner.parent = Some(0);
        owner.close_requested = 81;
        owner.close_policy = 2;
        let (runtime, cx) = cx.add_window_view(|_, cx| {
            let mut runtime = runtime();
            runtime.apply(vec![node(0, "root", &[1]), owner.clone()], cx);
            runtime
        });
        cx.run_until_parked();
        assert!(!cx.simulate_close());
        assert_eq!(Engine::take_test_event(), Some((81, 0, String::new(), 0)));
        assert!(!cx.simulate_close());
        assert_eq!(Engine::take_test_event(), None);
        owner.close_policy = 1;
        cx.update(|_, cx| runtime.update(cx, |runtime, cx| runtime.apply(vec![owner.clone()], cx)));
        assert!(!cx.simulate_close());
        assert_eq!(Engine::take_test_event(), Some((81, 0, String::new(), 0)));
        // Close is inert before a fresh request; the request then observes its
        // committed immediate decision and returns permission to the OS.
        owner.close_policy = 3;
        cx.update(|_, cx| runtime.update(cx, |runtime, cx| runtime.apply(vec![owner], cx)));
        assert!(cx.simulate_close());
        assert_eq!(Engine::take_test_event(), Some((81, 0, String::new(), 0)));
    }

    #[gpui::test]
    fn committed_async_close_decision_removes_the_native_window(cx: &mut TestAppContext) {
        let mut owner = node(1, "window", &[]);
        owner.parent = Some(0);
        owner.close_requested = 91;
        owner.close_policy = 2;
        let (runtime, cx) = cx.add_window_view(|_, cx| {
            let mut runtime = runtime();
            runtime.apply(vec![node(0, "root", &[1]), owner.clone()], cx);
            runtime
        });
        cx.run_until_parked();
        assert!(!cx.simulate_close());
        owner.close_policy = 3;
        cx.update(|_, cx| runtime.update(cx, |runtime, cx| runtime.apply(vec![owner], cx)));
        cx.run_until_parked();
        assert!(cx.windows().is_empty());
    }

    #[gpui::test]
    fn committed_close_effect_survives_later_policy_or_retirement(cx: &mut TestAppContext) {
        for retire in [false, true] {
            let mut owner = node(1, "window", &[]);
            owner.parent = Some(0);
            owner.close_requested = 92;
            owner.close_policy = 2;
            let (runtime, window_cx) = cx.add_window_view(|_, cx| {
                let mut runtime = runtime();
                runtime.apply(vec![node(0, "root", &[1]), owner.clone()], cx);
                runtime
            });
            window_cx.run_until_parked();
            assert!(!window_cx.simulate_close());
            window_cx.update(|_, cx| {
                runtime.update(cx, |runtime, cx| {
                    owner.close_policy = 3;
                    runtime.apply(vec![owner.clone()], cx);
                    owner.close_policy = 1;
                    owner.active = !retire;
                    let mut changes = vec![owner];
                    if retire {
                        changes.push(node(0, "root", &[]));
                    }
                    runtime.apply(changes, cx);
                })
            });
            window_cx.run_until_parked();
            assert!(window_cx.windows().is_empty());
        }
    }

    #[gpui::test]
    fn committed_reorder_preserves_entities_and_removal_invalidates_callbacks(
        cx: &mut TestAppContext,
    ) {
        cx.update(|cx| {
            let runtime = cx.new(|_| runtime());
            runtime.update(cx, |runtime, cx| {
                let mut button = node(1, "button", &[]);
                button.click = 21;
                runtime.apply(
                    vec![button, node(2, "text", &[]), node(0, "root", &[1, 2])],
                    cx,
                );
                let original = runtime.nodes[&1].entity_id();
                runtime.apply(vec![node(0, "root", &[2, 1])], cx);
                assert_eq!(runtime.nodes[&1].entity_id(), original);
                assert_eq!(
                    runtime.nodes[&runtime.engine.child_at(0, 1)].entity_id(),
                    original
                );
                runtime.event_if_live(1, 0, 20, Payload::Unit, cx);
                assert!(Engine::take_test_event().is_none());
                runtime.apply(
                    vec![
                        node(0, "root", &[2]),
                        Node {
                            id: 1,
                            active: false,
                            ..Default::default()
                        },
                    ],
                    cx,
                );
                assert!(!runtime.nodes.contains_key(&1));
                runtime.event_if_live(1, 0, 21, Payload::Unit, cx);
                assert!(Engine::take_test_event().is_none());
            });
        });
    }

    #[gpui::test]
    fn checked_ingress_is_typed_and_disabled_controls_refuse_dispatch(cx: &mut TestAppContext) {
        cx.update(|cx| {
            let runtime = cx.new(|_| runtime());
            runtime.update(cx, |runtime, cx| {
                let mut checkbox = node(1, "input", &[]);
                checkbox.role = super::Role::Checkbox;
                checkbox.check = 31;
                checkbox.disabled = true;
                runtime.apply(vec![node(0, "root", &[1]), checkbox.clone()], cx);
                runtime.event_if_live(1, 0, 31, Payload::Checked(true), cx);
                assert!(Engine::take_test_event().is_none());
                checkbox.disabled = false;
                runtime.apply(vec![checkbox], cx);
                runtime.event_if_live(1, 0, 31, Payload::Checked(true), cx);
                assert_eq!(Engine::take_test_event(), Some((31, 2, String::new(), 1)));
            });
        });
    }

    #[gpui::test]
    fn shortcuts_refuse_stale_replaced_disabled_and_disposed_bindings(cx: &mut TestAppContext) {
        cx.update(|cx| {
            let runtime = cx.new(|_| runtime());
            runtime.update(cx, |runtime, cx| {
                let first = super::shortcut::Shortcut {
                    event: 31,
                    key: u32::from(b's'),
                    modifiers: 1,
                };
                let second = super::shortcut::Shortcut { event: 32, ..first };
                let mut region = node(1, "div", &[]);
                region.shortcuts = vec![first];
                runtime.apply(vec![node(0, "root", &[1]), region.clone()], cx);
                let view_id = runtime.nodes[&1].entity_id();
                assert!(runtime.shortcut_if_live(1, view_id, 0, first, cx));
                assert_eq!(Engine::take_test_event(), Some((31, 0, String::new(), 0)));
                region.shortcuts = vec![second];
                runtime.apply(vec![region.clone()], cx);
                assert!(!runtime.shortcut_if_live(1, view_id, 0, first, cx));
                region.disabled = true;
                runtime.apply(vec![region.clone()], cx);
                assert!(!runtime.shortcut_if_live(1, view_id, 0, second, cx));
                region.active = false;
                runtime.apply(vec![node(0, "root", &[]), region.clone()], cx);
                assert!(!runtime.shortcut_if_live(1, view_id, 0, second, cx));
                region.active = true;
                region.disabled = false;
                runtime.apply(vec![node(0, "root", &[1]), region], cx);
                assert_ne!(runtime.nodes[&1].entity_id(), view_id);
                assert!(!runtime.shortcut_if_live(1, view_id, 0, second, cx));
                assert!(Engine::take_test_event().is_none());
            });
        });
    }

    #[gpui::test]
    fn actual_gpui_drag_delivers_source_key_to_the_drop_target(cx: &mut TestAppContext) {
        let (_, cx) = cx.add_window_view(|_, cx| {
            let mut runtime = runtime();
            let mut source = node(1, "div", &[]);
            source.test_id = "source".into();
            source.drag_key = "task-λ".into();
            source.style = Some(super::bridge::Style {
                width_kind: 2,
                width: 200,
                height_kind: 2,
                height: 80,
                ..Default::default()
            });
            let mut destination = source.clone();
            destination.id = 2;
            destination.test_id = "destination".into();
            destination.drag_key.clear();
            destination.drop = 61;
            runtime.apply(vec![node(0, "root", &[1, 2]), source, destination], cx);
            runtime
        });
        cx.run_until_parked();
        let start = cx.debug_bounds("source").unwrap().center();
        let end = cx.debug_bounds("destination").unwrap().center();
        cx.simulate_mouse_move(start, None, gpui::Modifiers::default());
        cx.simulate_mouse_down(start, gpui::MouseButton::Left, gpui::Modifiers::default());
        cx.simulate_mouse_move(
            start + point(px(20.), px(0.)),
            gpui::MouseButton::Left,
            gpui::Modifiers::default(),
        );
        cx.simulate_mouse_move(end, gpui::MouseButton::Left, gpui::Modifiers::default());
        cx.simulate_mouse_up(end, gpui::MouseButton::Left, gpui::Modifiers::default());
        assert_eq!(Engine::take_test_event(), Some((61, 3, "task-λ".into(), 0)));
    }

    #[gpui::test]
    fn drag_rejects_disposed_replaced_disabled_and_rebound_lifetimes(cx: &mut TestAppContext) {
        cx.update(|cx| {
            let owner = cx.new(|_| runtime());
            owner.update(cx, |runtime, cx| {
                let mut source = node(1, "div", &[]);
                source.drag_key = "task-λ".into();
                let mut destination = node(2, "div", &[]);
                destination.drop = 61;
                runtime.apply(
                    vec![
                        node(0, "root", &[1, 2]),
                        source.clone(),
                        destination.clone(),
                    ],
                    cx,
                );
                let item = crate::drag::Item {
                    key: source.drag_key.clone(),
                    source: 1,
                    lifetime: 0,
                    view: runtime.nodes[&1].entity_id(),
                    runtime: cx.entity_id(),
                };
                let target = crate::drag::Target {
                    node: 2,
                    event: 61,
                    lifetime: 0,
                    view: runtime.nodes[&2].entity_id(),
                    runtime: cx.entity_id(),
                };
                assert!(runtime.accept_drop(target, &item, cx));
                assert_eq!(Engine::take_test_event(), Some((61, 3, "task-λ".into(), 0)));
                source.lifetime = 1;
                runtime.apply(vec![source.clone()], cx);
                assert!(!runtime.accept_drop(target, &item, cx));
                let current = crate::drag::Item {
                    lifetime: 1,
                    ..item.clone()
                };
                destination.disabled = true;
                runtime.apply(vec![destination.clone()], cx);
                assert!(!runtime.accept_drop(target, &current, cx));
                destination.disabled = false;
                destination.drop = 62;
                runtime.apply(vec![destination.clone()], cx);
                assert!(!runtime.accept_drop(target, &current, cx));
                destination.drop = 61;
                destination.lifetime = 1;
                runtime.apply(vec![destination], cx);
                assert!(!runtime.accept_drop(target, &current, cx));
                source.active = false;
                runtime.apply(vec![node(0, "root", &[2]), source.clone()], cx);
                assert!(!runtime.accept_drop(target, &current, cx));
                source.active = true;
                runtime.apply(vec![node(0, "root", &[1, 2]), source], cx);
                let current_target = crate::drag::Target {
                    lifetime: 1,
                    ..target
                };
                assert!(!runtime.accept_drop(current_target, &current, cx));
                assert!(Engine::take_test_event().is_none());
            });
        });
    }

    #[gpui::test]
    fn unresolvable_image_sources_render_a_placeholder_box_of_the_styled_size(
        cx: &mut TestAppContext,
    ) {
        let cx = cx.add_empty_window();
        let runtime = cx.new(|cx| {
            let mut runtime = runtime();
            let sources = [
                "avatars/absent.png",
                "../../../etc/passwd",
                "/etc/passwd",
                "https://example.com/x.png",
            ];
            let mut nodes: Vec<_> = sources
                .iter()
                .enumerate()
                .map(|(index, source)| {
                    let id = index as u64 + 1;
                    let mut image = node(id, "img", &[]);
                    image.test_id = format!("image-{id}");
                    image.image_source = (*source).into();
                    image.style = Some(bridge::Style {
                        width_kind: 2,
                        width: 32,
                        height_kind: 2,
                        height: 32,
                        radius: 16,
                        ..Default::default()
                    });
                    image
                })
                .collect();
            nodes.push(node(0, "root", &[1, 2, 3, 4]));
            runtime.apply(nodes, cx);
            runtime
        });
        cx.draw(point(px(0.), px(0.)), size(px(400.), px(240.)), |_, _| {
            runtime.clone()
        });
        for selector in ["image-1", "image-2", "image-3", "image-4"] {
            let bounds = cx
                .debug_bounds(selector)
                .expect("image node must render its placeholder box");
            assert_eq!(bounds.size, size(px(32.), px(32.)));
        }
        assert!(Engine::take_test_event().is_none());
    }

    #[gpui::test]
    fn explicit_placeholder_reaches_editors_and_labels_derive_nothing(cx: &mut TestAppContext) {
        cx.update(|cx| {
            let runtime = cx.new(|_| runtime());
            runtime.update(cx, |runtime, cx| {
                let placeholder = |runtime: &Runtime, id: u64, cx: &gpui::App| {
                    runtime.nodes[&id]
                        .read(cx)
                        .input
                        .as_ref()
                        .unwrap()
                        .read(cx)
                        .placeholder_for_test()
                        .to_owned()
                };
                let mut field = node(1, "input", &[]);
                field.input = 42;
                field.label = "Filter".into();
                field.placeholder = "Filter tasks…".into();
                let mut editor = node(2, "textarea", &[]);
                editor.input = 43;
                editor.label = "Note text".into();
                editor.placeholder = "Start writing…".into();
                let mut unhinted = node(3, "input", &[]);
                unhinted.input = 44;
                unhinted.label = "Quantity".into();
                runtime.apply(
                    vec![
                        node(0, "root", &[1, 2, 3]),
                        field.clone(),
                        editor,
                        unhinted,
                    ],
                    cx,
                );
                assert_eq!(placeholder(runtime, 1, cx), "Filter tasks…");
                assert_eq!(placeholder(runtime, 2, cx), "Start writing…");
                assert_eq!(placeholder(runtime, 3, cx), "");
                field.placeholder = "Search projects…".into();
                runtime.apply(vec![field.clone()], cx);
                assert_eq!(placeholder(runtime, 1, cx), "Search projects…");
                field.placeholder = String::new();
                runtime.apply(vec![field], cx);
                assert_eq!(placeholder(runtime, 1, cx), "");
            });
        });
    }

    #[gpui::test]
    fn published_font_declarations_register_once_and_family_reaches_nodes(
        cx: &mut TestAppContext,
    ) {
        cx.update(|cx| {
            let runtime = cx.new(|_| runtime());
            runtime.update(cx, |runtime, cx| {
                let ttf: &[u8] =
                    include_bytes!("../../../vendor/fonts/source-code-pro/SourceCodePro-Regular.ttf");
                let declaration =
                    format!("1\nSource Code Pro\n{}", crate::fonts::encode_base64(ttf));
                let mut root = node(0, "root", &[1]);
                root.fonts = declaration.clone();
                let mut row = node(1, "div", &[]);
                row.font_family = "Source Code Pro".into();
                runtime.apply(vec![root.clone(), row], cx);
                assert_eq!(
                    runtime.registered_font_families_for_test(),
                    vec!["Source Code Pro".to_owned()]
                );
                assert!(runtime.font_errors_for_test().is_empty());
                assert_eq!(
                    runtime.nodes[&1].read(cx).node.font_family,
                    "Source Code Pro"
                );
                assert_eq!(runtime.nodes[&0].read(cx).node.font_family, "");
                // Re-publication of the identical declaration is pruned.
                runtime.apply(vec![root], cx);
                assert_eq!(runtime.registered_font_families_for_test().len(), 1);
                assert!(runtime.font_errors_for_test().is_empty());
            });
        });
    }

    #[gpui::test]
    fn font_declarations_outside_host_bounds_are_visible_errors_not_crashes(
        cx: &mut TestAppContext,
    ) {
        cx.update(|cx| {
            let runtime = cx.new(|_| runtime());
            runtime.update(cx, |runtime, cx| {
                // Nine fonts exceed the bound of eight.
                let mut declaration = String::from("1");
                for index in 0..9 {
                    declaration.push_str(&format!("\nFamily {index}\nAAAA"));
                }
                let mut root = node(0, "root", &[]);
                root.fonts = declaration;
                runtime.apply(vec![root], cx);
                assert!(runtime.registered_font_families_for_test().is_empty());
                assert_eq!(runtime.font_errors_for_test().len(), 1);
                // An oversized payload is refused before any registration.
                let oversized = crate::fonts::encode_base64(&vec![0u8; 8 * 1024 * 1024 + 3]);
                let mut root = node(0, "root", &[]);
                root.fonts = format!("1\nBig\n{oversized}");
                runtime.apply(vec![root], cx);
                assert!(runtime.registered_font_families_for_test().is_empty());
                assert_eq!(runtime.font_errors_for_test().len(), 2);
            });
        });
    }

    #[gpui::test]
    fn disabling_multiline_editor_retains_its_entity(cx: &mut TestAppContext) {
        cx.update(|cx| {
            let runtime = cx.new(|_| runtime());
            runtime.update(cx, |runtime, cx| {
                let mut editor = node(1, "textarea", &[]);
                editor.input = 42;
                editor.value = "first\nsecond".into();
                runtime.apply(vec![node(0, "root", &[1]), editor.clone()], cx);
                let original = runtime.nodes[&1]
                    .read(cx)
                    .input
                    .as_ref()
                    .unwrap()
                    .entity_id();
                editor.disabled = true;
                runtime.apply(vec![editor.clone()], cx);
                assert_eq!(
                    runtime.nodes[&1]
                        .read(cx)
                        .input
                        .as_ref()
                        .unwrap()
                        .entity_id(),
                    original
                );
                runtime.event_if_live(1, 0, 42, Payload::InputValue("changed"), cx);
                assert!(Engine::take_test_event().is_none());
                editor.disabled = false;
                runtime.apply(vec![editor], cx);
                assert_eq!(
                    runtime.nodes[&1]
                        .read(cx)
                        .input
                        .as_ref()
                        .unwrap()
                        .entity_id(),
                    original
                );
            });
        });
    }

    #[gpui::test]
    fn ordinary_tab_traversal_skips_disabled_and_defers_to_focused_shortcuts(
        cx: &mut TestAppContext,
    ) {
        cx.update(super::input::bind_keys);
        cx.update(super::controls::bind_keys);
        let (runtime, cx) = cx.add_window_view(|_, cx| {
            let mut runtime = runtime();
            let mut first = node(1, "button", &[]);
            first.text = "First".into();
            first.click = 21;
            let mut disabled = node(2, "button", &[]);
            disabled.text = "Disabled".into();
            disabled.click = 22;
            disabled.disabled = true;
            let mut editor = node(3, "input", &[]);
            editor.input = 23;
            editor.value = "draft".into();
            let mut last = node(4, "button", &[]);
            last.text = "Last".into();
            last.click = 24;
            runtime.apply(
                vec![
                    node(0, "root", &[1, 2, 3, 4]),
                    first,
                    disabled,
                    editor,
                    last,
                ],
                cx,
            );
            runtime
        });
        cx.simulate_keystrokes("tab");
        cx.update(|window, cx| {
            assert!(runtime.read(cx).nodes[&1].read(cx).focus.is_focused(window));
        });
        cx.simulate_keystrokes("tab");
        cx.update(|window, cx| {
            let editor = runtime.read(cx).nodes[&3]
                .read(cx)
                .input
                .as_ref()
                .unwrap()
                .read(cx);
            assert!(editor.focus_handle(cx).is_focused(window));
        });
        cx.simulate_keystrokes("ctrl-a");
        assert!(Engine::take_test_event().is_none());
        cx.simulate_keystrokes("shift-tab enter");
        assert_eq!(Engine::take_test_event(), Some((21, 0, String::new(), 0)));
        runtime.update(cx, |runtime, cx| {
            let mut first = runtime.nodes[&1].read(cx).node.clone();
            first.shortcuts = vec![super::shortcut::Shortcut {
                event: 31,
                key: 258,
                modifiers: 0,
            }];
            runtime.apply(vec![first], cx);
        });
        cx.simulate_keystrokes("tab");
        assert_eq!(Engine::take_test_event(), Some((31, 0, String::new(), 0)));
        cx.update(|window, cx| {
            assert!(runtime.read(cx).nodes[&1].read(cx).focus.is_focused(window));
        });
        cx.simulate_keystrokes("ctrl-tab");
        cx.update(|window, cx| {
            assert!(runtime.read(cx).nodes[&1].read(cx).focus.is_focused(window));
        });
        cx.simulate_keystrokes("shift-tab");
        cx.update(|window, cx| {
            assert!(runtime.read(cx).nodes[&4].read(cx).focus.is_focused(window));
        });
        runtime.update(cx, |runtime, cx| {
            let mut removed = runtime.nodes[&4].read(cx).node.clone();
            removed.active = false;
            runtime.apply(vec![node(0, "root", &[1, 2, 3]), removed], cx);
        });
        cx.simulate_keystrokes("tab");
        cx.update(|window, cx| {
            assert!(runtime.read(cx).nodes[&1].read(cx).focus.is_focused(window));
        });
    }

    #[gpui::test]
    fn client_frame_close_uses_the_same_unsaved_guard_as_os_close(cx: &mut TestAppContext) {
        struct ClientFrame(gpui::Entity<Runtime>);
        impl gpui::Render for ClientFrame {
            fn render(
                &mut self,
                window: &mut gpui::Window,
                cx: &mut gpui::Context<Self>,
            ) -> impl gpui::IntoElement {
                self.0.update(cx, |runtime, cx| {
                    runtime.window_frame(
                        gpui::div(),
                        gpui::Decorations::Client {
                            tiling: gpui::Tiling::default(),
                        },
                        window,
                        cx,
                    )
                })
            }
        }
        let runtime = cx.new(|cx| {
            let mut runtime = runtime();
            let mut owner = node(1, "window", &[]);
            owner.parent = Some(0);
            owner.close_requested = 95;
            owner.close_policy = 1;
            runtime.apply(vec![node(0, "root", &[1]), owner], cx);
            runtime
        });
        let (_, cx) = cx.add_window_view(|_, _| ClientFrame(runtime.clone()));
        cx.run_until_parked();
        let position = cx.debug_bounds("window-close").unwrap().center();
        cx.simulate_mouse_move(position, None, gpui::Modifiers::default());
        cx.simulate_mouse_down(
            position,
            gpui::MouseButton::Left,
            gpui::Modifiers::default(),
        );
        cx.simulate_mouse_up(
            position,
            gpui::MouseButton::Left,
            gpui::Modifiers::default(),
        );
        assert_eq!(Engine::take_test_event(), Some((95, 0, String::new(), 0)));
        assert_eq!(cx.windows().len(), 1, "KeepOpen must preserve the window");
        runtime.update(cx, |runtime, cx| {
            let mut owner = runtime.nodes[&1].read(cx).node.clone();
            owner.close_policy = 3;
            runtime.apply(vec![owner], cx);
        });
        cx.simulate_mouse_down(
            position,
            gpui::MouseButton::Left,
            gpui::Modifiers::default(),
        );
        cx.simulate_mouse_up(
            position,
            gpui::MouseButton::Left,
            gpui::Modifiers::default(),
        );
        cx.run_until_parked();
        assert!(
            cx.windows().is_empty(),
            "Close must remove the window after admission"
        );
    }

    #[gpui::test]
    fn window_overflow_is_reachable_with_scrollbar_drag_and_resize(cx: &mut TestAppContext) {
        let (runtime, cx) = cx.add_window_view(|_, cx| {
            let mut runtime = runtime();
            let mut content = node(2, "div", &[]);
            content.test_id = "oversized-content".into();
            content.style = Some(bridge::Style {
                direction: 1,
                width_kind: 2,
                width: 900,
                height_kind: 2,
                height: 1200,
                ..Default::default()
            });
            let mut app = node(1, "div", &[2]);
            app.style = Some(bridge::Style {
                direction: 1,
                width_kind: 1,
                ..Default::default()
            });
            runtime.apply(vec![node(0, "root", &[1]), app, content], cx);
            runtime
        });
        cx.simulate_resize(size(px(400.), px(300.)));
        cx.run_until_parked();
        let handle = runtime.read_with(cx, |runtime, _| runtime.content_scroll.clone());
        assert!(
            handle.max_offset().height >= px(900.),
            "vertical overflow: {:?}",
            handle.max_offset()
        );
        assert!(
            handle.max_offset().width >= px(500.),
            "horizontal overflow: {:?}",
            handle.max_offset()
        );
        let bounds = handle.bounds();
        let start = point(bounds.right() - px(6.), bounds.top() + px(8.));
        let end = point(start.x, bounds.bottom() - px(15.));
        cx.simulate_mouse_move(start, None, gpui::Modifiers::default());
        cx.simulate_mouse_down(start, gpui::MouseButton::Left, gpui::Modifiers::default());
        cx.simulate_mouse_move(end, gpui::MouseButton::Left, gpui::Modifiers::default());
        cx.simulate_mouse_up(end, gpui::MouseButton::Left, gpui::Modifiers::default());
        assert!(
            handle.offset().y < px(-800.),
            "thumb drag: {:?}",
            handle.offset()
        );
        assert!(
            Engine::take_test_event().is_none(),
            "scrolling must not dispatch an app event"
        );
        cx.simulate_resize(size(px(1000.), px(1400.)));
        cx.run_until_parked();
        assert_eq!(handle.max_offset().height, px(0.));
        assert_eq!(handle.offset().y, px(0.));
    }

    #[gpui::test]
    fn textarea_dimensions_constrain_the_retained_editing_viewport(cx: &mut TestAppContext) {
        let cx = cx.add_empty_window();
        let runtime = cx.new(|cx| {
            let mut runtime = runtime();
            let mut editor = node(1, "textarea", &[]);
            editor.test_id = "sized-editor".into();
            editor.label = "Note text".into();
            editor.input = 42;
            editor.value = "first\nsecond".into();
            editor.style = Some(bridge::Style {
                direction: 1,
                gap: 8,
                width_kind: 1,
                height_kind: 2,
                height: 160,
                ..Default::default()
            });
            let mut footer = node(2, "button", &[]);
            footer.test_id = "after-editor".into();
            footer.text = "Save".into();
            let mut root = node(0, "root", &[1, 2]);
            root.style = Some(bridge::Style {
                direction: 1,
                gap: 8,
                width_kind: 1,
                height_kind: 1,
                ..Default::default()
            });
            runtime.apply(vec![root, editor, footer], cx);
            runtime
        });
        let original = runtime.read_with(cx, |runtime, cx| {
            runtime.nodes[&1].read(cx).input.clone().unwrap()
        });
        let draw = |cx: &mut gpui::VisualTestContext, height| {
            cx.draw(point(px(0.), px(0.)), size(px(400.), px(height)), |_, _| {
                runtime.clone()
            });
        };
        draw(cx, 400.);
        let outer = cx.debug_bounds("sized-editor").unwrap();
        let footer = cx.debug_bounds("after-editor").unwrap();
        let viewport = original.read_with(cx, |input, _| input.viewport_bounds_for_test());
        assert_eq!(outer.size.height, px(160.));
        assert!(viewport.size.height > px(80.) && viewport.size.height < px(160.));
        assert!(viewport.bottom() <= outer.bottom());
        assert!(footer.top() >= outer.bottom());

        runtime.update(cx, |runtime, cx| {
            let mut editor = runtime.nodes[&1].read(cx).node.clone();
            editor.style.as_mut().unwrap().height_kind = 1;
            runtime.apply(vec![editor], cx);
        });
        draw(cx, 400.);
        let large = original.read_with(cx, |input, _| input.viewport_bounds_for_test());
        draw(cx, 260.);
        let small = original.read_with(cx, |input, _| input.viewport_bounds_for_test());
        assert!(small.size.height > px(80.));
        assert!(large.size.height > small.size.height + px(100.));
        let footer = cx.debug_bounds("after-editor").unwrap();
        assert!(footer.bottom() <= px(260.));

        runtime.update(cx, |runtime, cx| {
            let mut editor = runtime.nodes[&1].read(cx).node.clone();
            editor.style.as_mut().unwrap().height_kind = 0;
            runtime.apply(vec![editor], cx);
            assert_eq!(
                runtime.nodes[&1]
                    .read(cx)
                    .input
                    .as_ref()
                    .unwrap()
                    .entity_id(),
                original.entity_id()
            );
        });
        draw(cx, 600.);
        let auto = original.read_with(cx, |input, _| input.viewport_bounds_for_test());
        assert_eq!(auto.size.height, px(320.));
        assert!(Engine::take_test_event().is_none());
    }

    #[gpui::test]
    fn styled_editor_field_reflects_the_elements_style_record(cx: &mut TestAppContext) {
        cx.update(|cx| {
            let runtime = cx.new(|_| runtime());
            runtime.update(cx, |runtime, cx| {
                // A light theme: dark text on a white field.
                let style = bridge::Style {
                    background: 0xffffff,
                    foreground: 0x1b2d36,
                    border_color: 0xc3ced4,
                    radius: 10,
                    font_size: 18,
                    hover_background: 0x1000000,
                    active_background: 0x1000000,
                    ..Default::default()
                };
                let mut editor = node(1, "textarea", &[]);
                editor.input = 42;
                editor.style = Some(style);
                runtime.apply(vec![node(0, "root", &[1]), editor], cx);
                let chrome = super::editor_field_chrome(Some(style));
                assert_eq!(chrome.background, 0xffffff);
                assert_eq!(chrome.foreground, 0x1b2d36);
                assert_eq!(chrome.border, 0xc3ced4);
                assert_eq!(chrome.radius, Some(10.));
                assert_eq!(chrome.font_size, 18.);
                // The retained editor tints its cursor and selection from the
                // explicit foreground, and the placeholder derives from the
                // effective text color at reduced alpha in shape_layout.
                let input = runtime.nodes[&1].read(cx).input.clone().unwrap();
                assert_eq!(input.read(cx).style_foreground_for_test(), Some(0x1b2d36));
                // Restyling the same element re-resolves without recreating it.
                let mut restyled = runtime.nodes[&1].read(cx).node.clone();
                restyled.style.as_mut().unwrap().foreground = 0x1000000;
                runtime.apply(vec![restyled], cx);
                let unchanged = runtime.nodes[&1].read(cx).input.clone().unwrap();
                assert_eq!(unchanged.entity_id(), input.entity_id());
                assert_eq!(unchanged.read(cx).style_foreground_for_test(), None);
            });
        });
    }

    #[gpui::test]
    fn unstyled_editor_field_keeps_the_host_default_chrome(cx: &mut TestAppContext) {
        cx.update(|cx| {
            let runtime = cx.new(|_| runtime());
            runtime.update(cx, |runtime, cx| {
                let mut field = node(1, "input", &[]);
                field.input = 42;
                // A style whose editor-relevant fields all sit at their
                // sentinels resolves identically to no style at all.
                let mut sized = node(2, "textarea", &[]);
                sized.input = 43;
                sized.style = Some(bridge::Style {
                    height_kind: 2,
                    height: 160,
                    background: 0x1000000,
                    hover_background: 0x1000000,
                    active_background: 0x1000000,
                    foreground: 0x1000000,
                    border_color: 0x1000000,
                    ..Default::default()
                });
                runtime.apply(vec![node(0, "root", &[1, 2]), field, sized.clone()], cx);
                for style in [None, sized.style] {
                    let chrome = super::editor_field_chrome(style);
                    assert_eq!(chrome.background, 0x0f1b21);
                    assert_eq!(chrome.foreground, 0xeaf0f3);
                    assert_eq!(chrome.border, 0x3a4f5c);
                    assert_eq!(chrome.radius, None);
                    assert_eq!(chrome.font_size, 16.);
                }
                for id in [1, 2] {
                    let input = runtime.nodes[&id].read(cx).input.clone().unwrap();
                    assert_eq!(input.read(cx).style_foreground_for_test(), None);
                }
            });
        });
    }

    #[gpui::test]
    fn fill_children_stay_inside_their_padded_parents_content_box(cx: &mut TestAppContext) {
        let sentinel = 0x1000000;
        let colors = bridge::Style {
            background: sentinel,
            hover_background: sentinel,
            active_background: sentinel,
            foreground: sentinel,
            border_color: sentinel,
            ..Default::default()
        };
        let fill = bridge::Style {
            direction: 1,
            width_kind: 1,
            height_kind: 1,
            ..colors
        };
        let cx = cx.add_empty_window();
        let runtime = cx.new(|cx| {
            let mut runtime = runtime();
            // The app shape every example uses: a Fill/Fill window wrapper, a
            // padded Fill/Fill column, a fixed header, and a Fill panel.
            let mut window = node(1, "window", &[2]);
            window.style = Some(fill);
            let mut parent = node(2, "div", &[3, 4]);
            parent.test_id = "padded-parent".into();
            parent.style = Some(bridge::Style {
                gap: 8,
                padding: 24,
                ..fill
            });
            let mut header = node(3, "text", &[]);
            header.test_id = "fill-header".into();
            header.text = "Header".into();
            header.style = Some(bridge::Style {
                direction: 1,
                height_kind: 2,
                height: 40,
                ..colors
            });
            let mut panel = node(4, "div", &[]);
            panel.test_id = "fill-panel".into();
            panel.style = Some(fill);
            runtime.apply(vec![node(0, "root", &[1]), window, parent, header, panel], cx);
            runtime
        });
        cx.draw(point(px(0.), px(0.)), size(px(500.), px(400.)), |_, _| {
            runtime.clone()
        });
        let parent = cx.debug_bounds("padded-parent").unwrap();
        let header = cx.debug_bounds("fill-header").unwrap();
        let panel = cx.debug_bounds("fill-panel").unwrap();
        eprintln!("parent={parent:?} header={header:?} panel={panel:?}");
        assert_eq!(parent.size, size(px(500.), px(400.)));
        // Fill means the parent's content box: inside the padding on every
        // side, and after the fixed sibling plus the gap on the main axis.
        assert_eq!(panel.left(), parent.left() + px(24.));
        assert_eq!(panel.right(), parent.right() - px(24.));
        assert_eq!(panel.top(), header.bottom() + px(8.));
        assert_eq!(
            panel.bottom(),
            parent.bottom() - px(24.),
            "Fill height must stop at the content box, not the border box"
        );

        // A Fill panel with oversized content keeps its allocation instead of
        // growing past the padding: the region owns its overflow. Before the
        // flex mapping this exact shape pushed the panel to the window edge.
        runtime.update(cx, |runtime, cx| {
            let mut oversized = node(5, "div", &[]);
            oversized.test_id = "oversized".into();
            oversized.style = Some(bridge::Style {
                direction: 1,
                height_kind: 2,
                height: 900,
                width_kind: 2,
                width: 100,
                ..colors
            });
            let mut panel = runtime.nodes[&4].read(cx).node.clone();
            panel.child_count = 1;
            Engine::set_test_children(4, vec![5]);
            runtime.apply(vec![panel, oversized], cx);
        });
        cx.draw(point(px(0.), px(0.)), size(px(500.), px(400.)), |_, _| {
            runtime.clone()
        });
        let parent = cx.debug_bounds("padded-parent").unwrap();
        let panel = cx.debug_bounds("fill-panel").unwrap();
        assert_eq!(parent.size, size(px(500.), px(400.)));
        assert_eq!(
            panel.bottom(),
            parent.bottom() - px(24.),
            "oversized content must not push a Fill panel past the padding"
        );
    }

    #[gpui::test]
    fn native_row_style_changes_real_gpui_layout(cx: &mut TestAppContext) {
        let cx = cx.add_empty_window();
        cx.draw(point(px(0.), px(0.)), size(px(320.), px(120.)), |_, cx| {
            cx.new(|cx| {
                let mut runtime = runtime();
                let style = bridge::Style {
                    width_kind: 2,
                    width: 40,
                    height_kind: 2,
                    height: 20,
                    background: 0x1000000,
                    foreground: 0x1000000,
                    border_color: 0x1000000,
                    ..Default::default()
                };
                let mut first = node(1, "div", &[]);
                first.test_id = "first".into();
                first.style = Some(style);
                let mut second = node(2, "div", &[]);
                second.test_id = "second".into();
                second.style = Some(style);
                let mut root = node(0, "root", &[1, 2]);
                root.style = Some(bridge::Style {
                    direction: 0,
                    gap: 12,
                    ..style
                });
                runtime.apply(vec![root, first, second], cx);
                runtime
            })
        });
        let first = cx.debug_bounds("first").expect("first child rendered");
        let second = cx.debug_bounds("second").expect("second child rendered");
        assert_eq!(first.origin.y, second.origin.y);
        assert!(second.origin.x > first.origin.x);
    }

    #[gpui::test]
    fn viewport_work_is_bounded_and_follow_tail_reveals_the_final_identity(
        cx: &mut TestAppContext,
    ) {
        for count in [100, 10_000] {
            let cx = cx.add_empty_window();
            let runtime = cx.new(|cx| {
                let mut runtime = runtime();
                let children: Vec<_> = (2..count + 2).collect();
                let mut rows: Vec<_> = children
                    .iter()
                    .map(|id| {
                        let mut value = node(*id, "text", &[]);
                        value.text = format!("Event {id}");
                        value.test_id = format!("event-{id}");
                        value
                    })
                    .collect();
                let mut viewport = node(1, "div", &children);
                viewport.row_height = 24;
                viewport.style = Some(bridge::Style {
                    height_kind: 2,
                    height: 120,
                    width_kind: 2,
                    width: 300,
                    ..Default::default()
                });
                rows.push(viewport);
                rows.push(node(0, "root", &[1]));
                runtime.apply(rows, cx);
                runtime
            });
            cx.draw(point(px(0.), px(0.)), size(px(400.), px(240.)), |_, _| {
                runtime.clone()
            });
            runtime.read_with(cx, |runtime, _| {
                assert!(
                    runtime.renders.get() < 24,
                    "rendered {} views for {count} rows",
                    runtime.renders.get()
                );
                assert!(
                    runtime.child_visits.get() < 24,
                    "visited {} children for {count} rows",
                    runtime.child_visits.get()
                );
            });
            assert!(cx.debug_bounds("event-2").is_some());
            assert!(
                cx.debug_bounds(if count == 100 {
                    "event-101"
                } else {
                    "event-10001"
                })
                .is_none()
            );
            runtime.update(cx, |runtime, cx| {
                let mut viewport = runtime.nodes[&1].read(cx).node.clone();
                viewport.follow_tail = true;
                runtime.apply(vec![viewport], cx);
                runtime.renders.set(0);
                runtime.child_visits.set(0);
            });
            cx.draw(point(px(0.), px(0.)), size(px(400.), px(240.)), |_, _| {
                runtime.clone()
            });
            assert!(
                cx.debug_bounds(if count == 100 {
                    "event-101"
                } else {
                    "event-10001"
                })
                .is_some()
            );
            runtime.read_with(cx, |runtime, _| {
                assert!(runtime.renders.get() < 24);
                assert!(runtime.child_visits.get() < 24);
            });
        }
    }

    #[gpui::test]
    fn editor_replacement_refuses_old_callbacks_and_accepts_the_new_lifetime_and_binding(
        cx: &mut TestAppContext,
    ) {
        use gpui::EntityInputHandler;
        let (view, cx) = cx.add_window_view(|_, cx| {
            let mut runtime = runtime();
            let mut editor = node(1, "textarea", &[]);
            editor.input = 42;
            runtime.apply(vec![node(0, "root", &[1]), editor], cx);
            runtime
        });
        for (lifetime, event) in [(1, 42), (1, 43)] {
            let previous =
                cx.update(|_, cx| view.read(cx).nodes[&1].read(cx).input.clone().unwrap());
            cx.update(|_, cx| {
                view.update(cx, |runtime, cx| {
                    let mut changed = runtime.nodes[&1].read(cx).node.clone();
                    changed.lifetime = lifetime;
                    changed.input = event;
                    changed.value = String::new();
                    runtime.apply(vec![changed], cx);
                })
            });
            let current =
                cx.update(|_, cx| view.read(cx).nodes[&1].read(cx).input.clone().unwrap());
            assert_ne!(previous.entity_id(), current.entity_id());
            cx.update(|window, cx| {
                previous.update(cx, |input, cx| {
                    input.replace_text_in_range(None, "old", window, cx)
                })
            });
            assert!(Engine::take_test_event().is_none());
            cx.update(|window, cx| {
                current.update(cx, |input, cx| {
                    input.replace_text_in_range(None, "new", window, cx)
                })
            });
            assert_eq!(Engine::take_test_event(), Some((event, 1, "new".into(), 0)));
        }
    }
}
