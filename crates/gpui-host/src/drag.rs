//! Internal drags carry bounded primitive data plus independent lifetime guards.
use crate::{Runtime, bridge::Node};
use gpui::{prelude::*, *};

#[derive(Clone)]
pub(crate) struct Item {
    pub key: String,
    pub source: u64,
    pub lifetime: u64,
    pub view: EntityId,
    pub runtime: EntityId,
}
#[derive(Clone, Copy)]
pub(crate) struct Target {
    pub node: u64,
    pub event: u64,
    pub lifetime: u64,
    pub view: EntityId,
    pub runtime: EntityId,
}

struct Preview(String);
impl Render for Preview {
    fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
        div()
            .p_2()
            .rounded_md()
            .bg(rgb(0x315b85))
            .text_color(rgb(0xffffff))
            .child(self.0.clone())
    }
}

pub(crate) fn install(
    mut element: Stateful<Div>,
    node: &Node,
    view: EntityId,
    runtime: WeakEntity<Runtime>,
) -> Stateful<Div> {
    if node.disabled {
        return element;
    }
    if !node.drag_key.is_empty() {
        let item = Item {
            key: node.drag_key.clone(),
            source: node.id,
            lifetime: node.lifetime,
            view,
            runtime: runtime.entity_id(),
        };
        element = element
            .cursor_move()
            .on_drag(item, |item, _, _, cx| cx.new(|_| Preview(item.key.clone())));
    }
    if node.drop != 0 {
        let target = Target {
            node: node.id,
            event: node.drop,
            lifetime: node.lifetime,
            view,
            runtime: runtime.entity_id(),
        };
        let predicate_runtime = runtime.clone();
        element = element
            .can_drop(move |value, _, cx| {
                let Some(item) = value.downcast_ref::<Item>() else {
                    return false;
                };
                predicate_runtime
                    .update(cx, |runtime, cx| runtime.valid_drop(target, item, cx))
                    .unwrap_or(false)
            })
            .drag_over::<Item>(|style, _, _, _| style.bg(rgb(0x294962)))
            .on_drop(move |item: &Item, window, cx| {
                if runtime
                    .update(cx, |runtime, cx| runtime.accept_drop(target, item, cx))
                    .unwrap_or(false)
                {
                    window.prevent_default();
                    cx.stop_propagation();
                }
            });
    }
    element
}
