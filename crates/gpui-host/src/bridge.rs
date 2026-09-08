//! Single-threaded owner of the experimental native ABI. No Roc layout enters Rust.
use crate::shortcut::{MAX_PER_ELEMENT, Shortcut};
use std::{marker::PhantomData, rc::Rc};

#[derive(Clone, Debug, Default)]
pub struct Node {
    pub id: u64,
    pub active: bool,
    pub tag: String,
    pub text: String,
    pub value: String,
    pub label: String,
    pub role: String,
    pub test_id: String,
    pub style: Option<Style>,
    pub child_count: usize,
    pub row_height: u32,
    pub follow_tail: bool,
    pub click: u64,
    pub input: u64,
    pub check: u64,
    pub checked: bool,
    pub selected: bool,
    pub disabled: bool,
    pub shortcuts: Vec<Shortcut>,
}
/// Validated native presentation v1, copied from the committed C boundary.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Style {
    pub direction: u32,
    pub gap: u32,
    pub padding: u32,
    pub width_kind: u32,
    pub width: u32,
    pub height_kind: u32,
    pub height: u32,
    pub grow: u32,
    pub background: u32,
    pub foreground: u32,
    pub border_color: u32,
    pub border_width: u32,
    pub radius: u32,
    pub font_size: u32,
    pub overflow_x: u32,
    pub overflow_y: u32,
}

#[derive(Clone, Copy)]
pub enum Payload<'a> {
    Unit,
    Text(&'a str),
    Bool(bool),
}
impl Node {
    pub fn event_for(&self, payload: Payload<'_>) -> u64 {
        match payload {
            Payload::Unit => self.click,
            Payload::Text(_) => self.input,
            Payload::Bool(_) => self.check,
        }
    }
}

#[repr(C)]
#[derive(Clone, Copy)]
struct Slice {
    ptr: *const u8,
    len: usize,
}
impl Slice {
    unsafe fn copy(self) -> String {
        if self.len == 0 {
            return String::new();
        }
        String::from_utf8(unsafe { std::slice::from_raw_parts(self.ptr, self.len) }.to_vec())
            .expect("invalid host UTF-8")
    }
}
#[repr(C)]
struct RawNode {
    id: u64,
    active: u64,
    parent: u64,
    tag: Slice,
    text: Slice,
    value: Slice,
    label: Slice,
    role: Slice,
    test_id: Slice,
    class: Slice,
    child_count: usize,
    click: u64,
    input: u64,
    check: u64,
    checked: u64,
    disabled: u64,
    selected: u64,
    style_present: u64,
    style: Style,
    viewport: [u32; 2],
}
#[repr(C)]
struct RawEffect {
    op: u32,
    kind: u32,
    id: u64,
    request: Slice,
}
pub enum Effect {
    Start { id: u64, kind: u32, request: String },
    Cancel(u64),
}
pub struct Engine {
    unmount: unsafe extern "C" fn(),
    dispatch: unsafe extern "C" fn(u64, u32, *const u8, usize, u32),
    count: unsafe extern "C" fn() -> usize,
    read: unsafe extern "C" fn(usize, *mut RawNode),
    read_shortcuts: unsafe extern "C" fn(u64, *mut Shortcut, usize) -> usize,
    metrics: unsafe extern "C" fn(*mut u64),
    tick_timer: unsafe extern "C" fn(u64) -> u32,
    next_timer: unsafe extern "C" fn(*mut crate::timers::Message) -> u32,
    child_at: unsafe extern "C" fn(u64, usize) -> u64,
    next_effect: unsafe extern "C" fn(*mut RawEffect) -> u32,
    task_result: unsafe extern "C" fn(u64, u32, *const u8, usize),
    _main_thread: PhantomData<Rc<()>>,
}
impl Engine {
    pub fn open() -> Self {
        unsafe {
            let engine = Self {
                unmount: signals_unmount,
                dispatch: signals_dispatch,
                count: signals_changed_count,
                read: signals_read_changed,
                read_shortcuts: signals_read_shortcuts,
                metrics: signals_metrics,
                tick_timer: signals_timer_tick,
                next_timer: signals_timer_next,
                child_at: signals_child_at,
                next_effect: signals_effect_next,
                task_result: signals_task_result,
                _main_thread: PhantomData,
            };
            assert_eq!(
                signals_protocol_version(),
                4,
                "native GUI protocol mismatch"
            );
            assert_eq!(
                signals_node_size(),
                std::mem::size_of::<RawNode>(),
                "spike bridge ABI size mismatch; rebuild with build.py"
            );
            assert_eq!(
                signals_effect_version(),
                1,
                "native effect protocol mismatch"
            );
            assert_eq!(signals_effect_size(), std::mem::size_of::<RawEffect>());
            assert_eq!(signals_timer_version(), 1, "native timer protocol mismatch");
            assert_eq!(
                signals_timer_size(),
                std::mem::size_of::<crate::timers::Message>()
            );
            signals_mount();
            engine
        }
    }
    pub fn changes(&self) -> Vec<Node> {
        unsafe {
            let count = (self.count)();
            assert!(count <= 65536);
            (0..count)
                .map(|i| {
                    let mut raw = std::mem::MaybeUninit::<RawNode>::uninit();
                    (self.read)(i, raw.as_mut_ptr());
                    let r = raw.assume_init();
                    let mut shortcuts = [Shortcut::default(); MAX_PER_ELEMENT];
                    let shortcut_count = if r.active != 0 {
                        (self.read_shortcuts)(r.id, shortcuts.as_mut_ptr(), shortcuts.len())
                    } else {
                        0
                    };
                    assert!(
                        shortcut_count <= MAX_PER_ELEMENT,
                        "native shortcut count exceeded its bound"
                    );
                    Node {
                        id: r.id,
                        active: r.active != 0,
                        tag: r.tag.copy(),
                        text: r.text.copy(),
                        value: r.value.copy(),
                        label: r.label.copy(),
                        role: r.role.copy(),
                        test_id: r.test_id.copy(),
                        style: (r.style_present != 0).then_some(r.style),
                        child_count: r.child_count,
                        row_height: r.viewport[0],
                        follow_tail: r.viewport[1] != 0,
                        click: r.click,
                        input: r.input,
                        check: r.check,
                        checked: r.checked != 0,
                        selected: r.selected != 0,
                        disabled: r.disabled != 0,
                        shortcuts: shortcuts[..shortcut_count].to_vec(),
                    }
                })
                .collect()
        }
    }
    pub fn event(&mut self, event: u64, payload: Payload<'_>) -> Vec<Node> {
        let (kind, bytes, boolean) = match payload {
            Payload::Unit => (0, "".as_bytes(), 0),
            Payload::Text(value) => (1, value.as_bytes(), 0),
            Payload::Bool(value) => (2, "".as_bytes(), u32::from(value)),
        };
        unsafe { (self.dispatch)(event, kind, bytes.as_ptr(), bytes.len(), boolean) };
        self.changes()
    }
    pub fn tick_timer(&mut self, token: u64) -> Option<Vec<Node>> {
        match unsafe { (self.tick_timer)(token) } {
            0 => None,
            1 => Some(self.changes()),
            _ => panic!("invalid native timer delivery status"),
        }
    }
    pub fn next_timer(&mut self) -> Option<crate::timers::Message> {
        let mut message = crate::timers::Message::default();
        match unsafe { (self.next_timer)(&mut message) } {
            0 => None,
            1 => Some(message),
            _ => panic!("invalid native timer read status"),
        }
    }
    pub fn child_at(&self, parent: u64, rank: usize) -> u64 {
        unsafe { (self.child_at)(parent, rank) }
    }
    /// Copy one committed primitive message before another engine call can
    /// invalidate its borrowed storage. At most sixteen requests are retained.
    pub fn next_effect(&mut self) -> Option<Effect> {
        let mut raw = std::mem::MaybeUninit::<RawEffect>::uninit();
        match unsafe { (self.next_effect)(raw.as_mut_ptr()) } {
            0 => None,
            1 => {
                let raw = unsafe { raw.assume_init() };
                assert_ne!(raw.id, 0, "invalid native task identity");
                assert!(raw.request.len <= 8 * 1024 * 1024);
                Some(match raw.op {
                    1 => Effect::Start {
                        id: raw.id,
                        kind: raw.kind,
                        request: unsafe { raw.request.copy() },
                    },
                    2 if raw.kind == 0 && raw.request.len == 0 => Effect::Cancel(raw.id),
                    _ => panic!("invalid native effect operation"),
                })
            }
            _ => panic!("invalid native effect availability"),
        }
    }
    pub fn task_result(&mut self, id: u64, failed: bool, payload: &str) -> Vec<Node> {
        assert!(payload.len() <= 8 * 1024 * 1024);
        unsafe { (self.task_result)(id, u32::from(failed), payload.as_ptr(), payload.len()) };
        self.changes()
    }
    pub fn metrics(&self) -> [u64; 3] {
        let mut result = [0; 3];
        unsafe { (self.metrics)(result.as_mut_ptr()) };
        result
    }
}
impl Drop for Engine {
    fn drop(&mut self) {
        unsafe { (self.unmount)() }
    }
}

unsafe extern "C" {
    fn signals_protocol_version() -> u32;
    fn signals_node_size() -> usize;
    fn signals_mount();
    fn signals_unmount();
    fn signals_dispatch(event: u64, kind: u32, ptr: *const u8, len: usize, boolean: u32);
    fn signals_changed_count() -> usize;
    fn signals_read_changed(index: usize, node: *mut RawNode);
    fn signals_read_shortcuts(id: u64, output: *mut Shortcut, capacity: usize) -> usize;
    fn signals_metrics(out: *mut u64);
    fn signals_timer_tick(token: u64) -> u32;
    fn signals_timer_next(out: *mut crate::timers::Message) -> u32;
    fn signals_timer_version() -> u32;
    fn signals_timer_size() -> usize;
    fn signals_child_at(parent: u64, rank: usize) -> u64;
    fn signals_effect_version() -> u32;
    fn signals_effect_size() -> usize;
    fn signals_effect_next(out: *mut RawEffect) -> u32;
    fn signals_task_result(id: u64, failed: u32, ptr: *const u8, len: usize);
}

#[cfg(test)]
thread_local! {
    static TEST_CHILDREN: std::cell::RefCell<std::collections::HashMap<u64, Vec<u64>>> = std::cell::RefCell::new(std::collections::HashMap::new());
    static TEST_EVENT: std::cell::RefCell<Option<(u64, u32, String, u32)>> = const { std::cell::RefCell::new(None) };
}

#[cfg(test)]
impl Engine {
    pub fn test_boundary() -> Self {
        unsafe extern "C" fn noop() {}
        unsafe extern "C" fn tick_timer(_: u64) -> u32 {
            0
        }
        unsafe extern "C" fn next_timer(_: *mut crate::timers::Message) -> u32 {
            0
        }
        unsafe extern "C" fn child_at(parent: u64, rank: usize) -> u64 {
            TEST_CHILDREN.with(|children| children.borrow()[&parent][rank])
        }
        unsafe extern "C" fn count() -> usize {
            0
        }
        unsafe extern "C" fn next_effect(_: *mut RawEffect) -> u32 {
            0
        }
        unsafe extern "C" fn task_result(_: u64, _: u32, _: *const u8, _: usize) {
            panic!("unexpected test task result")
        }
        unsafe extern "C" fn read(_: usize, _: *mut RawNode) {
            panic!("unexpected test node read")
        }
        unsafe extern "C" fn read_shortcuts(_: u64, _: *mut Shortcut, _: usize) -> usize {
            0
        }
        unsafe extern "C" fn metrics(out: *mut u64) {
            unsafe { std::ptr::write_bytes(out, 0, 3) };
        }
        unsafe extern "C" fn dispatch(
            event: u64,
            kind: u32,
            ptr: *const u8,
            len: usize,
            boolean: u32,
        ) {
            let text =
                std::str::from_utf8(unsafe { std::slice::from_raw_parts(ptr, len) }).unwrap();
            TEST_EVENT
                .with(|slot| *slot.borrow_mut() = Some((event, kind, text.to_owned(), boolean)));
        }
        TEST_EVENT.with(|slot| *slot.borrow_mut() = None);
        Self {
            unmount: noop,
            dispatch,
            count,
            read,
            read_shortcuts,
            metrics,
            tick_timer,
            next_timer,
            child_at,
            next_effect,
            task_result,
            _main_thread: PhantomData,
        }
    }

    pub fn set_test_children(parent: u64, children: Vec<u64>) {
        TEST_CHILDREN.with(|table| {
            table.borrow_mut().insert(parent, children);
        });
    }

    pub fn take_test_event() -> Option<(u64, u32, String, u32)> {
        TEST_EVENT.with(|slot| slot.borrow_mut().take())
    }
}
