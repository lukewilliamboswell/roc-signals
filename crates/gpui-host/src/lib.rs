mod bridge;
mod effects;
mod file_io;
mod input;
mod shortcut;
use bridge::{Engine, Node, Payload};
use gpui::{div, prelude::*, px, rgb, *};
use std::{cell::Cell, collections::HashMap, rc::Rc, time::Duration};

struct NodeView {
    node: Node,
    scroll: UniformListScrollHandle,
    input: Option<Entity<input::TextInput>>,
    focus: FocusHandle,
    runtime: WeakEntity<Runtime>,
    renders: Rc<Cell<u64>>,
    child_visits: Rc<Cell<u64>>,
}
impl Render for NodeView {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        self.renders.set(self.renders.get() + 1);
        let mut element = div()
            .id(("node", self.node.id))
            .flex()
            .flex_col()
            .gap_2()
            .debug_selector(|| self.node.test_id.clone());
        if !self.node.shortcuts.is_empty() && !self.node.disabled {
            let runtime = self.runtime.clone();
            let node_id = self.node.id;
            let view_id = cx.entity_id();
            element =
                shortcut::install(element, self.node.shortcuts.clone(), move |binding, cx| {
                    runtime
                        .update(cx, |runtime, cx| {
                            runtime.shortcut_if_live(node_id, view_id, binding, cx)
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
        if self.node.tag == "button" {
            element = element.px_3().py_1().rounded_md().bg(rgb(0x315469));
            if !self.node.disabled {
                let runtime = self.runtime.clone();
                let event = self.node.click;
                let node_id = self.node.id;
                element = element.cursor_pointer().on_click(move |_, _, cx| {
                    let _ = runtime.update(cx, |runtime, cx| {
                        runtime.event_if_live(node_id, event, Payload::Unit, cx)
                    });
                });
            }
        }
        if self.node.role == "checkbox" {
            element = element
                .flex_row()
                .items_center()
                .child(if self.node.checked { "☑" } else { "☐" })
                .child(self.node.label.clone());
            if !self.node.disabled {
                let runtime = self.runtime.clone();
                let event = self.node.check;
                let node_id = self.node.id;
                let checked = !self.node.checked;
                element = element.cursor_pointer().on_click(move |_, _, cx| {
                    let _ = runtime.update(cx, |runtime, cx| {
                        runtime.event_if_live(node_id, event, Payload::Bool(checked), cx)
                    });
                });
            }
        }
        if matches!(self.node.tag.as_str(), "h1" | "h2") {
            element = element.text_2xl();
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

        if !self.node.text.is_empty() {
            element = element.child(self.node.text.clone());
        }
        if let Some(input) = &self.input {
            element = element.child(self.node.label.clone());
            element = element.child(
                div()
                    .bg(rgb(0xf4f4f0))
                    .text_color(rgb(0x151515))
                    .p_2()
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
                            div()
                                .id(("row", id))
                                .h(height)
                                .w_full()
                                .overflow_hidden()
                                .child(AnyView::from(child).cached(style))
                        })
                        .collect::<Vec<_>>()
                },
            )
            .track_scroll(self.scroll.clone())
            .size_full();
            return element.child(list).into_any_element();
        }
        self.child_visits
            .set(self.child_visits.get() + self.node.child_count as u64);
        let runtime = self.runtime.upgrade().expect("view outlived runtime");
        let runtime = runtime.read(cx);
        let children = (0..self.node.child_count)
            .map(|rank| {
                let id = runtime.engine.child_at(parent, rank);
                AnyView::from(
                    runtime
                        .nodes
                        .get(&id)
                        .expect("missing child identity")
                        .clone(),
                )
            })
            .collect::<Vec<_>>();
        element.children(children).into_any_element()
    }
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
    element = match style.overflow_x {
        1 => element.overflow_x_hidden(),
        2 => element.overflow_x_scroll(),
        _ => element,
    };
    match style.overflow_y {
        1 => element.overflow_y_hidden(),
        2 => element.overflow_y_scroll(),
        _ => element,
    }
}

struct Runtime {
    engine: Engine,
    effects: effects::Manager,
    nodes: HashMap<u64, Entity<NodeView>>,
    roots: Vec<Entity<NodeView>>,
    renders: Rc<Cell<u64>>,
    child_visits: Rc<Cell<u64>>,
    _clock: Option<Task<()>>,
}
impl Runtime {
    fn shortcut_if_live(
        &mut self,
        id: u64,
        view_id: EntityId,
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
        if node.disabled || binding.event == 0 || !node.shortcuts.contains(&binding) {
            return false;
        }
        self.event(binding.event, Payload::Unit, cx);
        true
    }
    fn new(clock: bool, cx: &mut Context<Self>) -> Self {
        let engine = Engine::open();
        let initial = engine.changes();
        let mut runtime = Self {
            engine,
            effects: crate::effects::Manager::default(),
            nodes: HashMap::new(),
            roots: vec![],
            renders: Rc::new(Cell::new(0)),
            child_visits: Rc::new(Cell::new(0)),
            _clock: None,
        };
        runtime.apply(initial, cx);
        runtime.drain_effects(cx);
        if clock {
            runtime._clock = Some(cx.spawn(async move |this, cx| {
                loop {
                    cx.background_executor().timer(Duration::from_secs(1)).await;
                    if this
                        .update(cx, |this, cx| {
                            let changes = this.engine.tick();
                            this.apply(changes, cx);
                            this.drain_effects(cx);
                        })
                        .is_err()
                    {
                        break;
                    }
                }
            }));
        }
        runtime
    }
    fn event_if_live(&mut self, id: u64, event: u64, payload: Payload<'_>, cx: &mut Context<Self>) {
        // A deferred editor callback may outlive disposal. Match both node and
        // binding identity so a reused slot cannot receive an old edit.
        let Some(view) = self.nodes.get(&id) else {
            return;
        };
        let node = &view.read(cx).node;
        if node.disabled || event == 0 || node.event_for(payload) != event {
            return;
        }
        self.event(event, payload, cx);
    }
    fn event(&mut self, event: u64, payload: Payload<'_>, cx: &mut Context<Self>) {
        let changes = self.engine.event(event, payload);
        eprintln!(
            "engine turn: {} touched render slots; metrics {:?}",
            changes.len(),
            self.engine.metrics()
        );
        self.apply(changes, cx);
        self.drain_effects(cx);
    }
    fn drain_effects(&mut self, cx: &mut Context<Self>) {
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
                matches!(
                    node.tag.as_str(),
                    "root" | "div" | "h1" | "h2" | "p" | "button" | "input" | "textarea" | "text"
                ),
                "unsupported spike element: {}",
                node.tag
            );
            if !self.nodes.contains_key(&node.id) {
                let weak = cx.entity().downgrade();
                let renders = self.renders.clone();
                let child_visits = self.child_visits.clone();
                let view = cx.new(|cx| {
                    let input = if node.input != 0 {
                        let runtime = weak.clone();
                        let event = node.input;
                        let node_id = node.id;
                        Some(cx.new(|cx| {
                            let callback: Rc<dyn Fn(String, &mut App)> =
                                Rc::new(move |value, cx| {
                                    let _ = runtime.update(cx, |runtime, cx| {
                                        runtime.event_if_live(
                                            node_id,
                                            event,
                                            Payload::Text(&value),
                                            cx,
                                        )
                                    });
                                });
                            if node.tag == "textarea" {
                                input::TextInput::new_multiline(node.value.clone(), callback, cx)
                            } else {
                                input::TextInput::new(node.value.clone(), callback, cx)
                            }
                        }))
                    } else {
                        None
                    };
                    NodeView {
                        node: node.clone(),
                        scroll: UniformListScrollHandle::default(),
                        input,
                        focus: cx.focus_handle(),
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
            if node.tag == "root" && !self.roots.iter().any(|r| r.entity_id() == view.entity_id()) {
                self.roots.push(view.clone());
                roots_changed = true;
            }
            view.update(cx, |view, cx| {
                if let Some(input) = &view.input {
                    input.update(cx, |input, cx| {
                        input.set_value(&node.value, cx);
                        input.set_disabled(node.disabled, cx);
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
        if roots_changed {
            cx.notify();
        }
    }
}
impl Drop for Runtime {
    fn drop(&mut self) {
        // Invalidate worker callbacks before Engine releases task-owned values.
        self.effects.shutdown();
    }
}

impl Render for Runtime {
    fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
        div()
            .id("signals-root")
            .size_full()
            .overflow_y_scroll()
            .bg(rgb(0x16252c))
            .text_color(rgb(0xeeeeea))
            .p_6()
            .children(self.roots.iter().map(|root| AnyView::from(root.clone())))
    }
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
    let smoke = args.iter().any(|arg| arg == "--smoke");
    let click = args
        .windows(2)
        .find(|a| a[0] == "--smoke-click")
        .map(|a| a[1].clone());
    let expected = args
        .windows(2)
        .find(|a| a[0] == "--smoke-expect")
        .map(|a| a[1].clone());
    Application::new().run(move |cx| {
        input::bind_keys(cx);
        cx.on_window_closed(|cx| {
            if cx.windows().is_empty() {
                cx.quit();
            }
        })
        .detach();
        let bounds = Bounds::centered(None, size(px(740.), px(900.)), cx);
        let window = cx
            .open_window(
                WindowOptions {
                    window_bounds: Some(WindowBounds::Windowed(bounds)),
                    ..Default::default()
                },
                |_, cx| cx.new(|cx| Runtime::new(!smoke, cx)),
            )
            .unwrap();
        cx.activate(true);
        if smoke {
            cx.spawn(async move |cx| {
                cx.background_executor().timer(Duration::from_secs(2)).await;
                window
                    .update(cx, |runtime, _, cx| {
                        assert!(runtime.renders.get() > 0, "no GPUI views rendered");
                        if let Some(label) = click {
                            let node = runtime
                                .nodes
                                .values()
                                .find(|v| {
                                    let n = &v.read(cx).node;
                                    n.tag == "button"
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
                            runtime.event_if_live(node.id, node.click, Payload::Unit, cx);
                        }
                    })
                    .unwrap();
                cx.background_executor()
                    .timer(Duration::from_millis(300))
                    .await;
                window
                    .update(cx, |runtime, _, cx| {
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
    use gpui::{AppContext, TestAppContext, point, px, size};
    use std::{cell::Cell, collections::HashMap, rc::Rc};

    fn runtime() -> Runtime {
        Runtime {
            engine: Engine::test_boundary(),
            effects: crate::effects::Manager::default(),
            nodes: HashMap::new(),
            roots: vec![],
            renders: Rc::new(Cell::new(0)),
            child_visits: Rc::new(Cell::new(0)),
            _clock: None,
        }
    }

    fn node(id: u64, tag: &str, children: &[u64]) -> Node {
        Engine::set_test_children(id, children.into());
        Node {
            id,
            tag: tag.into(),
            active: true,
            child_count: children.len(),
            ..Default::default()
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
                runtime.event_if_live(1, 20, Payload::Unit, cx);
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
                runtime.event_if_live(1, 21, Payload::Unit, cx);
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
                checkbox.role = "checkbox".into();
                checkbox.check = 31;
                checkbox.disabled = true;
                runtime.apply(vec![node(0, "root", &[1]), checkbox.clone()], cx);
                runtime.event_if_live(1, 31, Payload::Bool(true), cx);
                assert!(Engine::take_test_event().is_none());
                checkbox.disabled = false;
                runtime.apply(vec![checkbox], cx);
                runtime.event_if_live(1, 31, Payload::Bool(true), cx);
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
                assert!(runtime.shortcut_if_live(1, view_id, first, cx));
                assert_eq!(Engine::take_test_event(), Some((31, 0, String::new(), 0)));
                region.shortcuts = vec![second];
                runtime.apply(vec![region.clone()], cx);
                assert!(!runtime.shortcut_if_live(1, view_id, first, cx));
                region.disabled = true;
                runtime.apply(vec![region.clone()], cx);
                assert!(!runtime.shortcut_if_live(1, view_id, second, cx));
                region.active = false;
                runtime.apply(vec![node(0, "root", &[]), region.clone()], cx);
                assert!(!runtime.shortcut_if_live(1, view_id, second, cx));
                region.active = true;
                region.disabled = false;
                runtime.apply(vec![node(0, "root", &[1]), region], cx);
                assert_ne!(runtime.nodes[&1].entity_id(), view_id);
                assert!(!runtime.shortcut_if_live(1, view_id, second, cx));
                assert!(Engine::take_test_event().is_none());
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
                runtime.event_if_live(1, 42, Payload::Text("changed"), cx);
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
}
