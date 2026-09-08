//! Modal presentation and focus owned by explicit rendered dialog lifetimes.
//! Reactive updates change only registrations. Bounded tree walks happen only
//! when opening/restoring a dialog or on explicit Tab navigation.
use crate::{Node, NodeView, Payload, Runtime};
use gpui::{
    App, Context, EntityId, FocusHandle, Focusable, KeyDownEvent, WeakEntity, WeakFocusHandle,
    Window,
};

pub const MAX_DIALOGS: usize = 8;
pub const MAX_NODES: usize = 1024;
pub const MAX_TARGETS: usize = 256;

#[derive(Clone)]
pub struct SavedFocus {
    pub owner: WeakEntity<NodeView>,
    pub lifetime: u64,
    pub handle: WeakFocusHandle,
}
pub struct Dialog {
    pub id: u64,
    lifetime: u64,
    initialized: bool,
    restore: Option<SavedFocus>,
}
#[derive(Default)]
pub struct Dialogs {
    pub active: Vec<Dialog>,
    pub focused: Option<SavedFocus>,
    restore_pending: Option<Option<SavedFocus>>,
}

impl NodeView {
    pub(crate) fn focus_target(&self, cx: &App) -> Option<FocusHandle> {
        if self.node.disabled {
            return None;
        }
        if let Some(input) = &self.input {
            return Some(input.focus_handle(cx));
        }
        if self.node.tag == "button"
            || self.node.role == "checkbox"
            || !self.node.shortcuts.is_empty()
        {
            return Some(self.focus.clone());
        }
        None
    }
}

impl Runtime {
    pub(crate) fn activate_if_live(
        &mut self,
        id: u64,
        view_id: EntityId,
        lifetime: u64,
        binding: u64,
        cx: &mut Context<Self>,
    ) -> bool {
        let Some(view) = self.nodes.get(&id) else {
            return false;
        };
        if view.entity_id() != view_id || !self.dialog_allows(id, cx) {
            return false;
        }
        let control = view.read(cx);
        if control.node.disabled || control.node.lifetime != lifetime {
            return false;
        }
        let (event, payload) = if control.node.role == "checkbox" {
            (control.node.check, Payload::Bool(!control.node.checked))
        } else if control.node.tag == "button" {
            (control.node.click, Payload::Unit)
        } else {
            return false;
        };
        if event == 0 || event != binding {
            return false;
        }
        self.dialogs.focused = Some(SavedFocus {
            owner: view.downgrade(),
            lifetime,
            handle: control.focus.downgrade(),
        });
        self.event(event, payload, cx);
        true
    }

    fn within(&self, mut id: u64, ancestor: u64, cx: &App) -> bool {
        for _ in 0..MAX_NODES {
            if id == ancestor {
                return true;
            }
            let Some(node) = self.nodes.get(&id) else {
                return false;
            };
            let Some(parent) = node.read(cx).node.parent else {
                return false;
            };
            id = parent;
        }
        panic!("native dialog ancestry exceeds 1024 nodes");
    }

    pub(crate) fn dialog_allows(&self, id: u64, cx: &App) -> bool {
        self.dialogs
            .active
            .last()
            .is_none_or(|dialog| self.within(id, dialog.id, cx))
    }

    fn dialog_depth(&self, mut id: u64, cx: &App) -> usize {
        let mut depth = 0;
        for _ in 0..MAX_NODES {
            let node = &self.nodes[&id].read(cx).node;
            if node.tag == "dialog" {
                depth += 1;
            }
            let Some(parent) = node.parent else {
                return depth;
            };
            id = parent;
        }
        panic!("native dialog ancestry exceeds 1024 nodes");
    }

    pub(crate) fn sync_dialogs(&mut self, changes: &[Node], cx: &App) -> bool {
        let removed = self.dialogs.active.iter().position(|dialog| {
            self.nodes.get(&dialog.id).is_none_or(|view| {
                let node = &view.read(cx).node;
                node.tag != "dialog" || node.lifetime != dialog.lifetime
            })
        });
        if let Some(index) = removed {
            if self.dialogs.active[index].initialized {
                self.dialogs.restore_pending = Some(self.dialogs.active[index].restore.clone());
            }
        }
        self.dialogs.active.retain(|dialog| {
            self.nodes.get(&dialog.id).is_some_and(|view| {
                let node = &view.read(cx).node;
                node.tag == "dialog" && node.lifetime == dialog.lifetime
            })
        });
        let mut changed = removed.is_some();
        for node in changes
            .iter()
            .filter(|node| node.active && node.tag == "dialog")
        {
            if !self
                .dialogs
                .active
                .iter()
                .any(|dialog| dialog.id == node.id)
            {
                assert!(
                    self.dialogs.active.len() < MAX_DIALOGS,
                    "native dialog nesting exceeds eight"
                );
                self.dialogs.active.push(Dialog {
                    id: node.id,
                    lifetime: node.lifetime,
                    initialized: false,
                    restore: None,
                });
                changed = true;
            }
        }
        if changed {
            let mut active = std::mem::take(&mut self.dialogs.active);
            active.sort_by_key(|dialog| self.dialog_depth(dialog.id, cx));
            for pair in active.windows(2) {
                assert!(
                    self.within(pair[1].id, pair[0].id, cx),
                    "simultaneous native dialogs must be nested"
                );
            }
            self.dialogs.active = active;
        }
        changed
    }

    fn live_saved_focus(&self, saved: &SavedFocus, cx: &App) -> Option<(u64, FocusHandle)> {
        let owner = saved.owner.upgrade()?;
        let view = owner.read(cx);
        let current = self.nodes.get(&view.node.id)?;
        if current.entity_id() != owner.entity_id()
            || view.node.lifetime != saved.lifetime
            || view.node.disabled
            || !self.dialog_allows(view.node.id, cx)
        {
            return None;
        }
        let handle = saved.handle.upgrade()?;
        Some((view.node.id, handle))
    }

    fn set_dialog_focus(&mut self, id: u64, handle: FocusHandle, window: &mut Window, cx: &App) {
        self.dialogs.focused = Some(SavedFocus {
            owner: self.nodes[&id].downgrade(),
            lifetime: self.nodes[&id].read(cx).node.lifetime,
            handle: handle.downgrade(),
        });
        handle.focus(window);
    }

    fn dialog_targets(&self, root: u64, cx: &App) -> Vec<(u64, FocusHandle)> {
        let mut pending = vec![root];
        let mut visited = 0;
        let mut targets = Vec::new();
        while let Some(id) = pending.pop() {
            visited += 1;
            assert!(
                visited <= MAX_NODES,
                "native dialog contains more than 1024 nodes"
            );
            let view = self.nodes[&id].read(cx);
            let node = &view.node;
            if id != root && node.tag == "dialog" {
                continue;
            }
            if !node.disabled
                && (view.input.is_some() || node.tag == "button" || node.role == "checkbox")
            {
                assert!(
                    targets.len() < MAX_TARGETS,
                    "native dialog contains more than 256 focus targets"
                );
                targets.push((id, view.focus_target(cx).unwrap()));
            }
            assert!(
                visited + pending.len() + node.child_count <= MAX_NODES,
                "native dialog contains more than 1024 nodes"
            );
            for rank in (0..node.child_count).rev() {
                pending.push(self.engine.child_at(id, rank));
            }
        }
        targets
    }

    fn focus_first(&mut self, id: u64, window: &mut Window, cx: &App) {
        let (target, handle) = self
            .dialog_targets(id, cx)
            .into_iter()
            .next()
            .unwrap_or_else(|| (id, self.nodes[&id].read(cx).focus.clone()));
        self.set_dialog_focus(target, handle, window, cx);
    }

    pub(crate) fn prepare_dialog_focus(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if let Some(restore) = self.dialogs.restore_pending.take() {
            let restored = restore.and_then(|saved| self.live_saved_focus(&saved, cx));
            if let Some((id, handle)) = restored {
                self.set_dialog_focus(id, handle, window, cx);
            } else if let Some(dialog) = self.dialogs.active.last() {
                self.focus_first(dialog.id, window, cx);
            } else {
                self.dialogs.focused = None;
                window.blur();
            }
        }
        for index in 0..self.dialogs.active.len() {
            if self.dialogs.active[index].initialized {
                continue;
            }
            let saved = self.dialogs.focused.clone().filter(|saved| {
                saved
                    .handle
                    .upgrade()
                    .is_some_and(|handle| handle.is_focused(window))
            });
            self.dialogs.active[index].restore = saved;
            self.dialogs.active[index].initialized = true;
            self.focus_first(self.dialogs.active[index].id, window, cx);
        }
    }

    pub(crate) fn dialog_key(
        &mut self,
        id: u64,
        event: &KeyDownEvent,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> bool {
        if self
            .dialogs
            .active
            .last()
            .is_none_or(|dialog| dialog.id != id)
        {
            return false;
        }
        let modifiers = event.keystroke.modifiers;
        if modifiers.control || modifiers.alt || modifiers.platform || modifiers.function {
            return false;
        }
        match event.keystroke.key.as_str() {
            "tab" => {
                let targets = self.dialog_targets(id, cx);
                if targets.is_empty() {
                    self.focus_first(id, window, cx);
                    return true;
                }
                let current = window
                    .focused(cx)
                    .and_then(|focused| targets.iter().position(|(_, handle)| *handle == focused));
                let index = match current {
                    Some(index) if modifiers.shift => (index + targets.len() - 1) % targets.len(),
                    Some(index) => (index + 1) % targets.len(),
                    None if modifiers.shift => targets.len() - 1,
                    None => 0,
                };
                let (target, handle) = targets[index].clone();
                self.set_dialog_focus(target, handle, window, cx);
                true
            }
            "escape" if !modifiers.shift => {
                let view = &self.nodes[&id];
                let view_id = view.entity_id();
                let lifetime = view.read(cx).node.lifetime;
                let binding = view
                    .read(cx)
                    .node
                    .shortcuts
                    .iter()
                    .find(|binding| binding.key == 257 && binding.modifiers == 0)
                    .copied();
                binding.is_some_and(|binding| {
                    self.shortcut_if_live(id, view_id, lifetime, binding, cx)
                })
            }
            _ => false,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{Engine, shortcut::Shortcut};
    use gpui::{AppContext, Modifiers, TestAppContext};
    use std::{cell::Cell, collections::HashMap, rc::Rc};

    fn runtime() -> Runtime {
        Runtime {
            unfocused_keys: None,
            engine: Engine::test_boundary(),
            effects: crate::effects::Manager::default(),
            dialogs: Dialogs::default(),
            nodes: HashMap::new(),
            roots: vec![],
            renders: Rc::new(Cell::new(0)),
            child_visits: Rc::new(Cell::new(0)),
            timers: crate::timers::Manager::new(false),
        }
    }
    fn node(id: u64, parent: Option<u64>, tag: &str, children: &[u64]) -> Node {
        Engine::set_test_children(id, children.into());
        Node {
            id,
            parent,
            active: true,
            tag: tag.into(),
            child_count: children.len(),
            test_id: format!("node-{id}"),
            ..Default::default()
        }
    }
    fn button(id: u64, parent: u64, disabled: bool) -> Node {
        Node {
            click: id + 100,
            text: format!("Button {id}"),
            disabled,
            ..node(id, Some(parent), "button", &[])
        }
    }
    fn editor(id: u64, parent: u64) -> Node {
        Node {
            input: id + 100,
            value: "draft".into(),
            label: "Editor".into(),
            ..node(id, Some(parent), "textarea", &[])
        }
    }
    fn modal(id: u64, parent: u64, children: &[u64]) -> Node {
        Node {
            shortcuts: vec![Shortcut {
                event: id + 1000,
                key: 257,
                modifiers: 0,
            }],
            ..node(id, Some(parent), "dialog", children)
        }
    }
    fn focused(runtime: &Runtime, id: u64, window: &Window, cx: &App) -> bool {
        runtime.nodes[&id]
            .read(cx)
            .focus_target(cx)
            .is_some_and(|focus| focus.is_focused(window))
    }

    #[gpui::test]
    fn modal_traps_tab_skips_disabled_activates_buttons_and_restores_editor(
        cx: &mut TestAppContext,
    ) {
        cx.update(crate::input::bind_keys);
        cx.update(crate::controls::bind_keys);
        let (view, cx) = cx.add_window_view(|_, cx| {
            let mut runtime = runtime();
            runtime.apply(
                vec![
                    node(0, None, "root", &[1, 2]),
                    editor(1, 0),
                    button(2, 0, false),
                ],
                cx,
            );
            runtime
        });
        cx.run_until_parked();
        cx.update(|window, cx| {
            window.activate_window();
            view.update(cx, |runtime, cx| {
                runtime.nodes[&1]
                    .read(cx)
                    .focus_target(cx)
                    .unwrap()
                    .focus(window)
            })
        });
        cx.run_until_parked();
        cx.update(|window, cx| {
            let runtime = view.read(cx);
            assert!(focused(runtime, 1, window, cx));
            assert!(
                runtime.dialogs.focused.is_some(),
                "editor focus must be recorded"
            );
        });
        cx.update(|_, cx| {
            view.update(cx, |runtime, cx| {
                runtime.apply(
                    vec![
                        node(0, None, "root", &[1, 2, 10]),
                        modal(10, 0, &[11, 12, 13, 14]),
                        button(11, 10, true),
                        button(12, 10, false),
                        editor(13, 10),
                        button(14, 10, false),
                    ],
                    cx,
                );
            })
        });
        cx.run_until_parked();
        cx.update(|window, cx| assert!(focused(view.read(cx), 12, window, cx)));
        cx.simulate_keystrokes("tab");
        cx.update(|window, cx| assert!(focused(view.read(cx), 13, window, cx)));
        cx.simulate_keystrokes("tab tab shift-tab");
        cx.update(|window, cx| assert!(focused(view.read(cx), 14, window, cx)));
        cx.update(|_, cx| {
            view.update(cx, |runtime, cx| {
                runtime.apply(vec![button(14, 10, true)], cx);
                let background = runtime.nodes[&2].entity_id();
                assert!(!runtime.activate_if_live(2, background, 0, 102, cx));
                runtime.event_if_live(1, 0, 101, Payload::Text("blocked"), cx);
                assert!(Engine::take_test_event().is_none());
            })
        });
        cx.simulate_keystrokes("tab enter");
        assert_eq!(Engine::take_test_event(), Some((112, 0, String::new(), 0)));
        cx.simulate_keystrokes("space");
        assert_eq!(Engine::take_test_event(), Some((112, 0, String::new(), 0)));
        cx.simulate_keystrokes("ctrl-escape");
        assert!(Engine::take_test_event().is_none());
        cx.simulate_keystrokes("escape");
        assert_eq!(Engine::take_test_event(), Some((1010, 0, String::new(), 0)));
        cx.update(|_, cx| {
            view.update(cx, |runtime, cx| {
                let mut removed: Vec<_> = (10..=14)
                    .map(|id| {
                        let mut node = runtime.nodes[&id].read(cx).node.clone();
                        node.active = false;
                        node
                    })
                    .collect();
                removed.push(node(0, None, "root", &[1, 2]));
                runtime.apply(removed, cx);
            })
        });
        cx.run_until_parked();
        cx.update(|window, cx| assert!(focused(view.read(cx), 1, window, cx)));
    }

    #[gpui::test]
    fn nested_modal_restores_parent_and_recycled_opener_is_not_refocused(cx: &mut TestAppContext) {
        cx.update(crate::controls::bind_keys);
        let (view, cx) = cx.add_window_view(|_, cx| {
            let mut runtime = runtime();
            runtime.apply(vec![node(0, None, "root", &[1]), button(1, 0, false)], cx);
            runtime
        });
        cx.run_until_parked();
        cx.update(|window, cx| {
            window.activate_window();
            view.update(cx, |runtime, cx| {
                runtime.nodes[&1]
                    .read(cx)
                    .focus_target(cx)
                    .unwrap()
                    .focus(window)
            })
        });
        cx.run_until_parked();
        cx.update(|_, cx| {
            view.update(cx, |runtime, cx| {
                runtime.apply(
                    vec![
                        node(0, None, "root", &[1, 10]),
                        modal(10, 0, &[11]),
                        button(11, 10, false),
                    ],
                    cx,
                )
            })
        });
        cx.run_until_parked();
        cx.update(|_, cx| {
            view.update(cx, |runtime, cx| {
                runtime.apply(
                    vec![
                        modal(10, 0, &[11, 20]),
                        modal(20, 10, &[21]),
                        button(21, 20, false),
                    ],
                    cx,
                )
            })
        });
        cx.run_until_parked();
        cx.update(|window, cx| assert!(focused(view.read(cx), 21, window, cx)));
        cx.simulate_keystrokes("escape");
        assert_eq!(Engine::take_test_event(), Some((1020, 0, String::new(), 0)));
        cx.update(|_, cx| {
            view.update(cx, |runtime, cx| {
                let mut removed = vec![modal(10, 0, &[11])];
                for id in [20, 21] {
                    let mut node = runtime.nodes[&id].read(cx).node.clone();
                    node.active = false;
                    removed.push(node);
                }
                runtime.apply(removed, cx);
            })
        });
        cx.run_until_parked();
        cx.update(|window, cx| assert!(focused(view.read(cx), 11, window, cx)));
        cx.update(|_, cx| {
            view.update(cx, |runtime, cx| {
                let mut old = runtime.nodes[&1].read(cx).node.clone();
                old.active = false;
                runtime.apply(vec![node(0, None, "root", &[10]), old], cx);
                runtime.apply(
                    vec![node(0, None, "root", &[1, 10]), button(1, 0, false)],
                    cx,
                );
                let mut removed = vec![node(0, None, "root", &[1])];
                for id in [10, 11] {
                    let mut node = runtime.nodes[&id].read(cx).node.clone();
                    node.active = false;
                    removed.push(node);
                }
                runtime.apply(removed, cx);
            })
        });
        cx.run_until_parked();
        cx.update(|window, cx| {
            assert!(!focused(view.read(cx), 1, window, cx));
            assert!(window.focused(cx).is_none());
        });
    }

    #[gpui::test]
    fn modal_navigation_uses_current_child_order_without_reactive_tree_walks(
        cx: &mut TestAppContext,
    ) {
        let (view, cx) = cx.add_window_view(|_, cx| {
            let mut runtime = runtime();
            runtime.apply(
                vec![
                    node(0, None, "root", &[10]),
                    modal(10, 0, &[11, 12]),
                    button(11, 10, false),
                    button(12, 10, false),
                ],
                cx,
            );
            runtime
        });
        cx.update(|window, cx| assert!(focused(view.read(cx), 11, window, cx)));
        cx.update(|_, cx| {
            view.update(cx, |runtime, cx| {
                runtime.apply(vec![modal(10, 0, &[12, 11, 13]), button(13, 10, false)], cx)
            })
        });
        cx.simulate_keystrokes("tab");
        cx.update(|window, cx| assert!(focused(view.read(cx), 13, window, cx)));
        cx.simulate_keystrokes("tab");
        cx.update(|window, cx| assert!(focused(view.read(cx), 12, window, cx)));
    }

    #[gpui::test]
    fn modal_occludes_background_clicks_and_checkbox_reads_current_state(cx: &mut TestAppContext) {
        cx.update(crate::controls::bind_keys);
        let (view, cx) = cx.add_window_view(|_, cx| {
            let mut runtime = runtime();
            runtime.apply(vec![node(0, None, "root", &[1]), button(1, 0, false)], cx);
            runtime
        });
        let background = cx.debug_bounds("node-1").unwrap().center();
        cx.update(|_, cx| {
            view.update(cx, |runtime, cx| {
                runtime.apply(
                    vec![
                        node(0, None, "root", &[1, 10]),
                        modal(10, 0, &[11]),
                        Node {
                            role: "checkbox".into(),
                            check: 111,
                            label: "Choice".into(),
                            ..node(11, Some(10), "div", &[])
                        },
                    ],
                    cx,
                )
            })
        });
        cx.simulate_click(background, Modifiers::none());
        assert!(Engine::take_test_event().is_none());
        cx.simulate_keystrokes("space");
        assert_eq!(Engine::take_test_event(), Some((111, 2, String::new(), 1)));
        cx.update(|_, cx| {
            view.update(cx, |runtime, cx| {
                let mut checked = runtime.nodes[&11].read(cx).node.clone();
                checked.checked = true;
                runtime.apply(vec![checked], cx)
            })
        });
        cx.simulate_keystrokes("space");
        assert_eq!(Engine::take_test_event(), Some((111, 2, String::new(), 0)));
        cx.update(|_, cx| {
            view.update(cx, |runtime, cx| {
                let mut disabled = runtime.nodes[&11].read(cx).node.clone();
                disabled.disabled = true;
                runtime.apply(vec![disabled], cx)
            })
        });
        cx.simulate_keystrokes("space tab escape");
        assert_eq!(Engine::take_test_event(), Some((1010, 0, String::new(), 0)));
    }

    #[gpui::test]
    fn modal_empty_focus_and_disabled_opener_restore_are_explicit(cx: &mut TestAppContext) {
        let (view, cx) = cx.add_window_view(|_, cx| {
            let mut runtime = runtime();
            runtime.apply(vec![node(0, None, "root", &[1]), button(1, 0, false)], cx);
            runtime
        });
        cx.update(|window, cx| {
            window.activate_window();
            view.update(cx, |runtime, cx| {
                runtime.set_dialog_focus(1, runtime.nodes[&1].read(cx).focus.clone(), window, cx)
            });
        });
        cx.update(|_, cx| {
            view.update(cx, |runtime, cx| {
                runtime.apply(vec![node(0, None, "root", &[1, 10]), modal(10, 0, &[])], cx)
            })
        });
        cx.simulate_keystrokes("tab shift-tab");
        cx.update(|window, cx| assert!(focused(view.read(cx), 10, window, cx)));
        cx.update(|_, cx| {
            view.update(cx, |runtime, cx| {
                let mut removed = modal(10, 0, &[]);
                removed.active = false;
                runtime.apply(
                    vec![node(0, None, "root", &[1]), button(1, 0, true), removed],
                    cx,
                )
            })
        });
        cx.update(|window, cx| assert!(window.focused(cx).is_none()));
    }

    #[gpui::test]
    fn modal_bounds_reject_oversized_navigation_without_partial_target_results(
        cx: &mut TestAppContext,
    ) {
        cx.new(|cx| {
            let mut runtime = runtime();
            let children: Vec<u64> = (20..20 + MAX_NODES as u64 - 1).collect();
            let mut nodes = vec![node(0, None, "root", &[10]), modal(10, 0, &children)];
            nodes.extend(children.iter().map(|id| node(*id, Some(10), "text", &[])));
            runtime.apply(nodes, cx);
            assert!(runtime.dialog_targets(10, cx).is_empty());
            let oversized: Vec<_> = (20..20 + MAX_NODES as u64).collect();
            runtime.apply(
                vec![modal(10, 0, &oversized), node(1043, Some(10), "text", &[])],
                cx,
            );
            assert!(
                std::panic::catch_unwind(std::panic::AssertUnwindSafe(
                    || runtime.dialog_targets(10, cx)
                ))
                .is_err()
            );
            let targets: Vec<_> = (20..20 + MAX_TARGETS as u64).collect();
            let mut changes = vec![modal(10, 0, &targets)];
            changes.extend(targets.iter().map(|id| button(*id, 10, false)));
            runtime.apply(changes, cx);
            assert_eq!(runtime.dialog_targets(10, cx).len(), MAX_TARGETS);
            let oversized: Vec<_> = (20..21 + MAX_TARGETS as u64).collect();
            runtime.apply(vec![modal(10, 0, &oversized), button(276, 10, false)], cx);
            assert!(
                std::panic::catch_unwind(std::panic::AssertUnwindSafe(
                    || runtime.dialog_targets(10, cx)
                ))
                .is_err()
            );
            runtime
        });
    }

    #[gpui::test]
    fn modal_nesting_accepts_eight_and_rejects_a_ninth(cx: &mut TestAppContext) {
        cx.new(|cx| {
            let mut runtime = runtime();
            let mut changes = vec![node(0, None, "root", &[10])];
            for id in 10..18 {
                let children = if id == 17 { vec![] } else { vec![id + 1] };
                changes.push(modal(id, if id == 10 { 0 } else { id - 1 }, &children));
            }
            runtime.apply(changes, cx);
            assert_eq!(runtime.dialogs.active.len(), MAX_DIALOGS);
            assert!(
                std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                    runtime.apply(vec![modal(17, 16, &[18]), modal(18, 17, &[])], cx);
                }))
                .is_err()
            );
            runtime
        });
    }

    #[gpui::test]
    fn retained_view_lifetime_guards_focus_controls_shortcuts_and_modal_replacement(
        cx: &mut TestAppContext,
    ) {
        cx.new(|cx| {
            let mut runtime = runtime();
            let binding = Shortcut {
                event: 201,
                key: 257,
                modifiers: 0,
            };
            let mut opener = button(1, 0, false);
            opener.shortcuts = vec![binding];
            runtime.apply(vec![node(0, None, "root", &[1]), opener.clone()], cx);
            let old_view = runtime.nodes[&1].entity_id();
            let saved = SavedFocus {
                owner: runtime.nodes[&1].downgrade(),
                lifetime: 0,
                handle: runtime.nodes[&1].read(cx).focus.downgrade(),
            };
            assert!(runtime.live_saved_focus(&saved, cx).is_some());
            opener.lifetime = 1;
            runtime.apply(vec![opener.clone()], cx);
            assert_eq!(runtime.nodes[&1].entity_id(), old_view);
            assert!(runtime.live_saved_focus(&saved, cx).is_none());
            assert!(!runtime.activate_if_live(1, old_view, 0, 101, cx));
            assert!(!runtime.shortcut_if_live(1, old_view, 0, binding, cx));
            opener.click = 301;
            runtime.apply(vec![opener], cx);
            assert!(!runtime.activate_if_live(1, old_view, 1, 101, cx));
            assert!(runtime.activate_if_live(1, old_view, 1, 301, cx));
            assert_eq!(Engine::take_test_event(), Some((301, 0, String::new(), 0)));
            runtime.apply(vec![node(0, None, "root", &[1, 10]), modal(10, 0, &[])], cx);
            runtime.dialogs.active[0].initialized = true;
            runtime.dialogs.active[0].restore = Some(saved);
            let mut replacement = modal(10, 0, &[]);
            replacement.lifetime = 1;
            runtime.apply(vec![replacement], cx);
            assert_eq!(runtime.dialogs.active.len(), 1);
            assert_eq!(runtime.dialogs.active[0].lifetime, 1);
            assert!(!runtime.dialogs.active[0].initialized);
            assert!(runtime.dialogs.restore_pending.is_some());
            runtime
        });
    }

    #[gpui::test]
    fn modal_refuses_drags_from_or_to_background_controls(cx: &mut TestAppContext) {
        cx.new(|cx| {
            let mut runtime = runtime();
            let mut nodes = vec![node(0, None, "root", &[1, 2, 10]), modal(10, 0, &[11, 12])];
            for (source, target, parent) in [(1, 2, 0), (11, 12, 10)] {
                nodes.push(Node {
                    drag_key: "card".into(),
                    ..node(source, Some(parent), "div", &[])
                });
                nodes.push(Node {
                    drop: target + 100,
                    ..node(target, Some(parent), "div", &[])
                });
            }
            runtime.apply(nodes, cx);
            let item = |id| crate::drag::Item {
                source: id,
                lifetime: 0,
                key: "card".into(),
                view: runtime.nodes[&id].entity_id(),
                runtime: cx.entity_id(),
            };
            let target = |id| crate::drag::Target {
                node: id,
                lifetime: 0,
                event: id + 100,
                view: runtime.nodes[&id].entity_id(),
                runtime: cx.entity_id(),
            };
            assert!(!runtime.valid_drop(target(12), &item(1), cx));
            assert!(!runtime.valid_drop(target(2), &item(11), cx));
            assert!(runtime.valid_drop(target(12), &item(11), cx));
            runtime
        });
    }
}
