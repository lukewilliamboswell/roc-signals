//! Single-threaded owner of the experimental native ABI. No Roc layout enters Rust.
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
    pub children: Vec<u64>,
    pub click: u64,
    pub input: u64,
    pub check: u64,
    pub checked: bool,
    pub selected: bool,
    pub disabled: bool,
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
    children: *const u64,
    child_count: usize,
    click: u64,
    input: u64,
    check: u64,
    checked: u64,
    disabled: u64,
    selected: u64,
    style_present: u64,
    style: Style,
}
pub struct Engine {
    unmount: unsafe extern "C" fn(),
    dispatch: unsafe extern "C" fn(u64, u32, *const u8, usize, u32),
    count: unsafe extern "C" fn() -> usize,
    read: unsafe extern "C" fn(usize, *mut RawNode),
    metrics: unsafe extern "C" fn(*mut u64),
    tick: unsafe extern "C" fn(),
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
                metrics: signals_metrics,
                tick: signals_tick,
                _main_thread: PhantomData,
            };
            assert_eq!(
                signals_protocol_version(),
                2,
                "native GUI protocol mismatch"
            );
            assert_eq!(
                signals_node_size(),
                std::mem::size_of::<RawNode>(),
                "spike bridge ABI size mismatch; rebuild with build.py"
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
                        children: if r.child_count == 0 {
                            vec![]
                        } else {
                            std::slice::from_raw_parts(r.children, r.child_count).to_vec()
                        },
                        click: r.click,
                        input: r.input,
                        check: r.check,
                        checked: r.checked != 0,
                        selected: r.selected != 0,
                        disabled: r.disabled != 0,
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
    pub fn tick(&mut self) -> Vec<Node> {
        unsafe { (self.tick)() };
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
    fn signals_metrics(out: *mut u64);
    fn signals_tick();
}

#[cfg(test)]
thread_local! {
    static TEST_EVENT: std::cell::RefCell<Option<(u64, u32, String, u32)>> = const { std::cell::RefCell::new(None) };
}

#[cfg(test)]
impl Engine {
    pub fn test_boundary() -> Self {
        unsafe extern "C" fn noop() {}
        unsafe extern "C" fn count() -> usize {
            0
        }
        unsafe extern "C" fn read(_: usize, _: *mut RawNode) {
            panic!("unexpected test node read")
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
            metrics,
            tick: noop,
            _main_thread: PhantomData,
        }
    }

    pub fn take_test_event() -> Option<(u64, u32, String, u32)> {
        TEST_EVENT.with(|slot| slot.borrow_mut().take())
    }
}
