//! One declared window owner translates committed decisions into native closure.
//! A pending request contains only native registration identity, never app state.
use crate::{
    Runtime,
    bridge::{Node, Payload},
};
use gpui::{Context, EntityId, Window};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct Registration {
    node: u64,
    lifetime: u64,
    view: EntityId,
    event: u64,
}

#[derive(Default)]
pub(crate) struct Lifecycle {
    registration: Option<Registration>,
    pending: Option<Registration>,
    approved: bool,
    decision: u64,
    installed: bool,
}

impl Lifecycle {
    fn update(&mut self, registration: Option<Registration>, decision: u64) {
        if registration != self.registration {
            self.pending = None;
        }
        self.registration = registration;
        self.decision = decision;
        if decision == 3 && self.pending.is_some() && self.pending == registration {
            // Admission validates the pending registration now. Once committed,
            // closure belongs to the window, not a later descriptor lifetime;
            // no subsequent graph update can erase that decided native effect.
            self.approved = true;
        }
        if decision == 1 && !self.approved {
            self.pending = None;
        }
    }
    fn request(&mut self) -> Request {
        let Some(registration) = self.registration else {
            return Request::Unmanaged;
        };
        if self.pending.is_some() {
            return Request::Pending;
        }
        self.pending = Some(registration);
        Request::Dispatch(registration.event)
    }
    fn take_close(&mut self) -> bool {
        if self.approved
            || (self.decision == 3 && self.pending.is_some() && self.pending == self.registration)
        {
            self.pending = None;
            self.approved = false;
            true
        } else {
            false
        }
    }
}

enum Request {
    Unmanaged,
    Pending,
    Dispatch(u64),
}

impl Runtime {
    pub(crate) fn sync_window_lifecycle(&mut self, changes: &[Node], cx: &mut Context<Self>) {
        // Retire the old owner first so same-batch replacements are independent
        // of the engine's descriptor publication order.
        if let Some(owner) = self.window_lifecycle.registration {
            if changes
                .iter()
                .any(|node| node.id == owner.node && (!node.active || node.close_requested == 0))
            {
                self.window_lifecycle.update(None, 0);
            }
        }
        for node in changes
            .iter()
            .filter(|node| node.active && node.close_requested != 0)
        {
            let registration = Registration {
                node: node.id,
                lifetime: node.lifetime,
                view: self.nodes[&node.id].entity_id(),
                event: node.close_requested,
            };
            assert!(
                self.window_lifecycle
                    .registration
                    .is_none_or(|owner| owner.node == node.id),
                "multiple native window lifecycle owners"
            );
            assert!(
                (1..=3).contains(&node.close_policy),
                "invalid native window close decision"
            );
            self.window_lifecycle
                .update(Some(registration), node.close_policy);
        }
        if self.window_lifecycle.pending.is_some() || self.window_lifecycle.approved {
            cx.notify();
        }
    }

    /// Admits both compositor and client-frame close requests through the live
    /// application owner; true permits removal, false preserves the window.
    pub(crate) fn native_close_requested(&mut self, cx: &mut Context<Self>) -> bool {
        if self.window_lifecycle.take_close() {
            return true;
        }
        match self.window_lifecycle.request() {
            Request::Unmanaged => true,
            Request::Pending => false,
            Request::Dispatch(event) => {
                self.event(event, Payload::Unit, cx);
                // Equal KeepOpen does not need a render patch. The request is
                // canceled using the committed policy even when nothing changed.
                if self.window_lifecycle.decision == 1 && !self.window_lifecycle.approved {
                    self.window_lifecycle.pending = None;
                }
                self.window_lifecycle.take_close()
            }
        }
    }

    pub(crate) fn prepare_window_lifecycle(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if !self.window_lifecycle.installed {
            self.window_lifecycle.installed = true;
            let owner = cx.entity().downgrade();
            window.on_window_should_close(cx, move |_, cx| {
                owner
                    .update(cx, |runtime, cx| runtime.native_close_requested(cx))
                    .unwrap_or(true)
            });
        }
        if self.window_lifecycle.take_close() {
            window.remove_window();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use gpui::AppContext;
    #[gpui::test]
    fn committed_close_survives_later_policy_and_owner_retirement(cx: &mut gpui::TestAppContext) {
        let view = cx.new(|_| ());
        let owner = Registration {
            node: 1,
            lifetime: 1,
            view: view.entity_id(),
            event: 8,
        };
        let mut lifecycle = Lifecycle::default();
        lifecycle.update(Some(owner), 2);
        assert!(matches!(lifecycle.request(), Request::Dispatch(8)));
        lifecycle.update(Some(owner), 3);
        lifecycle.update(Some(owner), 1);
        assert!(lifecycle.take_close());
        assert!(!lifecycle.take_close());
        lifecycle.update(Some(owner), 2);
        assert!(matches!(lifecycle.request(), Request::Dispatch(8)));
        lifecycle.update(Some(owner), 3);
        lifecycle.update(
            Some(Registration {
                lifetime: 2,
                ..owner
            }),
            3,
        );
        assert!(lifecycle.take_close());
        assert!(matches!(lifecycle.request(), Request::Dispatch(8)));
        lifecycle.update(lifecycle.registration, 3);
        lifecycle.update(None, 0);
        assert!(lifecycle.take_close());
    }

    #[gpui::test]
    fn decisions_cancel_wait_complete_and_cannot_cross_owner_lifetimes(
        cx: &mut gpui::TestAppContext,
    ) {
        let view = cx.new(|_| ());
        let first = Registration {
            node: 1,
            lifetime: 1,
            view: view.entity_id(),
            event: 8,
        };
        let mut lifecycle = Lifecycle::default();
        lifecycle.update(Some(first), 3);
        assert!(!lifecycle.take_close());
        assert!(matches!(lifecycle.request(), Request::Dispatch(8)));
        lifecycle.update(Some(first), 2);
        assert!(!lifecycle.take_close());
        assert!(matches!(lifecycle.request(), Request::Pending));
        lifecycle.update(Some(first), 1);
        assert!(!lifecycle.take_close());
        assert!(matches!(lifecycle.request(), Request::Dispatch(8)));
        lifecycle.update(Some(first), 2);
        lifecycle.update(Some(first), 3);
        assert!(lifecycle.take_close());
        assert!(!lifecycle.take_close());
        assert!(matches!(lifecycle.request(), Request::Dispatch(8)));
        lifecycle.update(
            Some(Registration {
                lifetime: 2,
                ..first
            }),
            3,
        );
        assert!(!lifecycle.take_close());
        assert!(matches!(lifecycle.request(), Request::Dispatch(8)));
        lifecycle.update(None, 0);
        assert!(!lifecycle.take_close());
        assert!(matches!(lifecycle.request(), Request::Unmanaged));
    }
}
