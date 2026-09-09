mod assets;
mod bridge;
mod controls;
mod dialog;
mod drag;
mod effects;
mod file_io;
mod input;
mod scrollbars;
mod shortcut;
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
            input
        }))
    }
}
impl Render for NodeView {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        self.renders.set(self.renders.get() + 1);
        let mut element = div()
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
                let default_background = self
                    .node
                    .style
                    .is_none_or(|style| style.background > 0xffffff);
                if default_background {
                    element = element
                        .hover(|style| style.bg(rgb(0x3f6175)))
                        .active(|style| style.bg(rgb(0x2b4452)));
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
        if let Some(style) = self.node.style {
            element = apply_style(element, style);
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
            element = element.child(
                div()
                    .bg(rgb(0x0f1b21))
                    .text_color(rgb(0xeaf0f3))
                    .border_1()
                    .border_color(rgb(0x3a4f5c))
                    .rounded_md()
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
                            let row = div().id(("row", id)).h(height).w_full().overflow_hidden();
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

fn apply_style(mut element: Stateful<Div>, style: bridge::Style) -> Stateful<Div> {
    element = if style.direction == 0 {
        element.flex_row()
    } else {
        element.flex_col()
    };
    element = element
        .gap(px(style.gap as f32))
        .p(px(style.padding as f32));
    element = match style.width_kind {
        1 => element.w_full(),
        2 => element.w(px(style.width as f32)),
        _ => element,
    };
    element = match style.height_kind {
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
    effects: effects::Manager,
    dialogs: dialog::Dialogs,
    window_lifecycle: window_lifecycle::Lifecycle,
    nodes: HashMap<u64, Entity<NodeView>>,
    roots: Vec<Entity<NodeView>>,
    renders: Rc<Cell<u64>>,
    child_visits: Rc<Cell<u64>>,
    timers: timers::Manager,
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
    fn new(clock: bool, cx: &mut Context<Self>) -> Self {
        let engine = Engine::open();
        let initial = engine.changes();
        let mut runtime = Self {
            content_scroll: gpui::ScrollHandle::new(),
            content_scrollbars: crate::scrollbars::State::default(),
            trace_engine: false,
            unfocused_keys: None,
            engine,
            effects: crate::effects::Manager::default(),
            dialogs: crate::dialog::Dialogs::default(),
            window_lifecycle: crate::window_lifecycle::Lifecycle::default(),
            nodes: HashMap::new(),
            roots: vec![],
            renders: Rc::new(Cell::new(0)),
            child_visits: Rc::new(Cell::new(0)),
            timers: timers::Manager::new(clock),
        };
        runtime.apply(initial, cx);
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
        while let Some(message) = self.engine.next_effect() {
            self.effects.accept(message, cx);
        }
    }
    fn complete_task(&mut self, id: u64, failed: bool, payload: &str, cx: &mut Context<Self>) {
        self.effects.complete(id);
        let changes = self.engine.task_result(id, failed, payload);
        self.apply(changes, cx);
        self.drain_effects(cx);
    }
    fn apply(&mut self, changes: Vec<Node>, cx: &mut Context<Self>) {
        if changes.is_empty() {
            return;
        }
        // All native reads have completed. Materialize new entity identities
        // before wiring the engine-selected child lists, regardless of batch order.
        self.nodes.reserve(changes.len());
        for node in changes.iter().filter(|n| n.active) {
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
                        input.set_disabled(node.disabled, cx);
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
        if self.sync_dialogs(&changes, cx) || roots_changed {
            cx.notify();
        }
    }
}
impl Drop for Runtime {
    fn drop(&mut self) {
        // Invalidate worker callbacks before Engine releases task-owned values.
        self.timers.shutdown();
        self.effects.shutdown();
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
            root = root.child(
                div()
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
                    .child(self.nodes[&id].clone()),
            );
        }
        self.window_frame(root, window.window_decorations(), window, cx)
    }
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

/// Starts the GUI, or runs the shared native semantic-spec host without a display.
/// The process entry owns the runtime until all windows have closed.
#[cfg(not(test))]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn main(argc: i32, argv: *const *const i8) -> i32 {
    let args: Vec<String> = std::env::args().collect();
    if args.iter().any(|arg| arg == "--run-spec-json") {
        return unsafe { signals_spec_main(argc, argv) };
    }
    let assets_root = args
        .windows(2)
        .find(|pair| pair[0] == "--assets-root")
        .map(|pair| std::path::PathBuf::from(&pair[1]))
        .or_else(|| std::env::var_os("ROC_SIGNALS_ASSETS_ROOT").map(std::path::PathBuf::from));
    if let Some(root) = assets_root {
        assets::set_root(root);
    }
    let trace_engine = args.iter().any(|arg| arg == "--host-trace-engine");
    let smoke = args.iter().any(|arg| arg == "--smoke");
    let smoke_timers = args.iter().any(|arg| arg == "--smoke-timers");
    let click = args
        .windows(2)
        .find(|a| a[0] == "--smoke-click")
        .map(|a| a[1].clone());
    let drop_request = args
        .windows(3)
        .find(|a| a[0] == "--smoke-drop")
        .map(|a| (a[1].clone(), a[2].clone()));
    let expected = args
        .windows(2)
        .find(|a| a[0] == "--smoke-expect")
        .map(|a| a[1].clone());
    Application::new().run(move |cx| {
        input::bind_keys(cx);
        controls::bind_keys(cx);
        cx.on_window_closed(|cx| {
            if cx.windows().is_empty() {
                cx.quit();
            }
        })
        .detach();
        let bounds = Bounds::centered(None, size(px(1200.), px(820.)), cx);
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
                        runtime
                    })
                },
            )
            .unwrap();
        cx.activate(true);
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
    use super::{Engine, Node, Payload, Runtime, bridge};
    use gpui::Focusable;
    use gpui::{AppContext, TestAppContext, point, px, size};
    use std::{cell::Cell, collections::HashMap, rc::Rc};

    fn runtime() -> Runtime {
        Runtime {
            content_scroll: gpui::ScrollHandle::new(),
            content_scrollbars: crate::scrollbars::State::default(),
            trace_engine: false,
            unfocused_keys: None,
            engine: Engine::test_boundary(),
            effects: crate::effects::Manager::default(),
            dialogs: crate::dialog::Dialogs::default(),
            window_lifecycle: crate::window_lifecycle::Lifecycle::default(),
            nodes: HashMap::new(),
            roots: vec![],
            renders: Rc::new(Cell::new(0)),
            child_visits: Rc::new(Cell::new(0)),
            timers: crate::timers::Manager::new(false),
        }
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
