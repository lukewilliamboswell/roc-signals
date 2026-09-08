mod bridge;
mod input;
use bridge::{Engine, Node};
use gpui::{div, prelude::*, px, rgb, *};
use std::{cell::Cell, collections::HashMap, rc::Rc, time::Duration};

struct NodeView {
    node: Node,
    children: Vec<Entity<NodeView>>,
    input: Option<Entity<input::TextInput>>,
    runtime: WeakEntity<Runtime>,
    renders: Rc<Cell<u64>>,
    child_visits: Rc<Cell<u64>>,
}
impl Render for NodeView {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        self.renders.set(self.renders.get() + 1);
        self.child_visits
            .set(self.child_visits.get() + self.children.len() as u64);
        let mut element = div().id(("node", self.node.id)).flex().flex_col().gap_2();
        if self.node.tag == "button" {
            element = element
                .px_3()
                .py_1()
                .rounded_md()
                .bg(rgb(0x315469))
                .cursor_pointer();
            if !self.node.disabled {
                let runtime = self.runtime.clone();
                let event = self.node.click;
                let node_id = self.node.id;
                element = element.on_click(move |_, _, cx| {
                    let _ = runtime.update(cx, |runtime, cx| {
                        runtime.event_if_live(node_id, event, None, cx)
                    });
                });
            }
        }
        if matches!(self.node.tag.as_str(), "h1" | "h2") {
            element = element.text_2xl();
        }
        if self.node.class == "gpui-row" {
            element = element
                .p_3()
                .border_1()
                .border_color(rgb(0x48606b))
                .rounded_md();
        }
        if !self.node.text.is_empty() {
            element = element.child(self.node.text.clone());
        }
        if let Some(input) = &self.input {
            element = element.child(
                div()
                    .bg(rgb(0xf4f4f0))
                    .text_color(rgb(0x151515))
                    .p_2()
                    .child(input.clone()),
            );
        }
        element.children(self.children.iter().map(|child| {
            let view = AnyView::from(child.clone());
            if child.read(cx).node.class == "gpui-row" {
                let mut style = StyleRefinement::default();
                style.size.width = Some(relative(1.).into());
                style.size.height = Some(px(170.).into());
                view.cached(style)
            } else {
                view
            }
        }))
    }
}
struct Runtime {
    engine: Engine,
    nodes: HashMap<u64, Entity<NodeView>>,
    roots: Vec<Entity<NodeView>>,
    renders: Rc<Cell<u64>>,
    child_visits: Rc<Cell<u64>>,
    _clock: Option<Task<()>>,
}
impl Runtime {
    fn new(clock: bool, cx: &mut Context<Self>) -> Self {
        let engine = Engine::open();
        let initial = engine.changes();
        let mut runtime = Self {
            engine,
            nodes: HashMap::new(),
            roots: vec![],
            renders: Rc::new(Cell::new(0)),
            child_visits: Rc::new(Cell::new(0)),
            _clock: None,
        };
        runtime.apply(initial, cx);
        if clock {
            runtime._clock = Some(cx.spawn(async move |this, cx| {
                loop {
                    cx.background_executor().timer(Duration::from_secs(1)).await;
                    if this
                        .update(cx, |this, cx| {
                            let changes = this.engine.tick();
                            this.apply(changes, cx);
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
    fn event_if_live(&mut self, id: u64, event: u64, text: Option<&str>, cx: &mut Context<Self>) {
        // A deferred editor callback may outlive disposal. Match both node and
        // binding identity so a reused slot cannot receive an old edit.
        let Some(view) = self.nodes.get(&id) else {
            return;
        };
        let node = &view.read(cx).node;
        if (if text.is_some() {
            node.input
        } else {
            node.click
        }) != event
        {
            return;
        }
        self.event(event, text, cx);
    }
    fn event(&mut self, event: u64, text: Option<&str>, cx: &mut Context<Self>) {
        let changes = self.engine.event(event, text);
        eprintln!(
            "engine turn: {} touched render slots; metrics {:?}",
            changes.len(),
            self.engine.metrics()
        );
        self.apply(changes, cx);
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
                    "root" | "div" | "h1" | "h2" | "p" | "button" | "input" | "text"
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
                            input::TextInput::new(
                                node.value.clone(),
                                Rc::new(move |value, cx| {
                                    let _ = runtime.update(cx, |runtime, cx| {
                                        runtime.event_if_live(node_id, event, Some(&value), cx)
                                    });
                                }),
                                cx,
                            )
                        }))
                    } else {
                        None
                    };
                    NodeView {
                        node: node.clone(),
                        children: vec![],
                        input,
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
            let children: Vec<_> = node
                .children
                .iter()
                .map(|id| self.nodes.get(id).expect("missing child identity").clone())
                .collect();
            let view = self.nodes[&node.id].clone();
            if node.tag == "root" && !self.roots.iter().any(|r| r.entity_id() == view.entity_id()) {
                self.roots.push(view.clone());
                roots_changed = true;
            }
            view.update(cx, |view, cx| {
                if let Some(input) = &view.input {
                    input.update(cx, |input, cx| input.set_value(&node.value, cx));
                }
                view.node = node.clone();
                view.children = children;
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
                                            || n.children.iter().any(|id| {
                                                runtime.nodes[id].read(cx).node.text == label
                                            }))
                                })
                                .expect("smoke button missing")
                                .read(cx)
                                .node
                                .clone();
                            runtime.event_if_live(node.id, node.click, None, cx);
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
