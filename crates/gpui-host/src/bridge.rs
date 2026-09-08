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
    pub class: String,
    pub children: Vec<u64>,
    pub click: u64,
    pub input: u64,
    pub disabled: bool,
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
    test_id: Slice,
    class: Slice,
    children: *const u64,
    child_count: usize,
    click: u64,
    input: u64,
    checked: u64,
    disabled: u64,
}
pub struct Engine {
    unmount: unsafe extern "C" fn(),
    dispatch: unsafe extern "C" fn(u64, u32, *const u8, usize),
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
                        class: r.class.copy(),
                        children: if r.child_count == 0 {
                            vec![]
                        } else {
                            std::slice::from_raw_parts(r.children, r.child_count).to_vec()
                        },
                        click: r.click,
                        input: r.input,
                        disabled: r.disabled != 0,
                    }
                })
                .collect()
        }
    }
    pub fn event(&mut self, event: u64, text: Option<&str>) -> Vec<Node> {
        let bytes = text.unwrap_or("").as_bytes();
        unsafe {
            (self.dispatch)(
                event,
                u32::from(text.is_some()),
                bytes.as_ptr(),
                bytes.len(),
            )
        };
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
    fn signals_node_size() -> usize;
    fn signals_mount();
    fn signals_unmount();
    fn signals_dispatch(event: u64, kind: u32, ptr: *const u8, len: usize);
    fn signals_changed_count() -> usize;
    fn signals_read_changed(index: usize, node: *mut RawNode);
    fn signals_metrics(out: *mut u64);
    fn signals_tick();
}
