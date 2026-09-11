//! Single-threaded owner of the experimental native ABI. No Roc layout enters Rust.
use crate::protocol_gen::{EFFECT_VERSION, PROTOCOL_VERSION, RawNode, TIMER_VERSION};
use crate::shortcut::{MAX_PER_ELEMENT, Shortcut};
use std::{marker::PhantomData, rc::Rc};

/// Element kind, derived exactly once from the published tag when a node
/// crosses the bridge boundary. Host code branches on this enum; the raw tag
/// string is retained only for diagnostics.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum ControlKind {
    #[default]
    Unknown,
    Root,
    Div,
    Dialog,
    Window,
    Heading1,
    Heading2,
    Paragraph,
    Button,
    Input,
    Textarea,
    Text,
    Image,
}
impl ControlKind {
    pub fn from_tag(tag: &str) -> Self {
        match tag {
            "root" => Self::Root,
            "div" => Self::Div,
            "dialog" => Self::Dialog,
            "window" => Self::Window,
            "h1" => Self::Heading1,
            "h2" => Self::Heading2,
            "p" => Self::Paragraph,
            "button" => Self::Button,
            "input" => Self::Input,
            "textarea" => Self::Textarea,
            "text" => Self::Text,
            "img" => Self::Image,
            _ => Self::Unknown,
        }
    }
    pub fn is_heading(self) -> bool {
        matches!(self, Self::Heading1 | Self::Heading2)
    }
}

/// Semantic role, derived once from the published role string alongside
/// `ControlKind`. Only the checkbox role changes host behavior.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum Role {
    #[default]
    Generic,
    Checkbox,
}
impl Role {
    pub fn from_role(role: &str) -> Self {
        if role == "checkbox" {
            Self::Checkbox
        } else {
            Self::Generic
        }
    }
}

#[derive(Clone, Debug, Default)]
pub struct Node {
    pub id: u64,
    pub lifetime: u64,
    pub drag_key: String,
    pub drop: u64,
    pub close_requested: u64,
    pub close_policy: u64,
    pub parent: Option<u64>,
    pub active: bool,
    pub tag: String,
    pub kind: ControlKind,
    pub text: String,
    pub value: String,
    pub label: String,
    pub placeholder: String,
    pub image_source: String,
    pub font_family: String,
    pub fonts: String,
    pub role: Role,
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
    /// Refuses edits while the control stays available (bool field 6).
    pub read_only: bool,
    pub shortcuts: Vec<Shortcut>,
}
/// Validated native presentation v2, copied from the committed C boundary.
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
    pub hover_background: u32,
    pub active_background: u32,
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
    InputValue(&'a str),
    Detail(&'a str),
    Checked(bool),
}
impl Node {
    pub fn event_for(&self, payload: Payload<'_>) -> u64 {
        match payload {
            Payload::Unit => self.click,
            Payload::InputValue(_) => self.input,
            Payload::Detail(_) => self.drop,
            Payload::Checked(_) => self.check,
        }
    }
}

#[repr(C)]
#[derive(Clone, Copy)]
pub(crate) struct Slice {
    pub(crate) ptr: *const u8,
    pub(crate) len: usize,
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
    document_title: unsafe extern "C" fn(*mut Slice) -> u64,
    /// Revision of the last window identity handed to the platform window, so a
    /// repeated title never re-enters the native windowing system.
    applied_title: std::cell::Cell<u64>,
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
                document_title: signals_document_title,
                applied_title: std::cell::Cell::new(0),
                _main_thread: PhantomData,
            };
            assert_eq!(
                signals_protocol_version(),
                PROTOCOL_VERSION,
                "native GUI protocol mismatch"
            );
            assert_eq!(
                signals_node_size(),
                std::mem::size_of::<RawNode>(),
                "spike bridge ABI size mismatch; rebuild with build.py"
            );
            assert_eq!(
                signals_effect_version(),
                EFFECT_VERSION,
                "native effect protocol mismatch"
            );
            assert_eq!(signals_effect_size(), std::mem::size_of::<RawEffect>());
            assert_eq!(
                signals_timer_version(),
                TIMER_VERSION,
                "native timer protocol mismatch"
            );
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
                    let tag = r.tag.copy();
                    let role = r.role.copy();
                    Node {
                        id: r.id,
                        lifetime: r.lifetime,
                        drag_key: r.drag_key.copy(),
                        drop: r.drop,
                        close_requested: r.close_requested,
                        close_policy: r.close_policy,
                        parent: (r.parent != u64::MAX).then_some(r.parent),
                        active: r.active != 0,
                        kind: ControlKind::from_tag(&tag),
                        tag,
                        text: r.text.copy(),
                        value: r.value.copy(),
                        label: r.label.copy(),
                        placeholder: r.placeholder.copy(),
                        image_source: r.image_source.copy(),
                        font_family: r.font_family.copy(),
                        fonts: r.fonts.copy(),
                        role: Role::from_role(&role),
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
                        read_only: r.read_only != 0,
                        shortcuts: shortcuts[..shortcut_count].to_vec(),
                    }
                })
                .collect()
        }
    }
    pub fn event(&mut self, event: u64, payload: Payload<'_>) -> Vec<Node> {
        let (kind, bytes, boolean) = match payload {
            Payload::Unit => (0, "".as_bytes(), 0),
            Payload::InputValue(value) => (1, value.as_bytes(), 0),
            Payload::Detail(value) => (3, value.as_bytes(), 0),
            Payload::Checked(value) => (2, "".as_bytes(), u32::from(value)),
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
    /// Reports the window identity the graph decided, but only when it actually
    /// changed since the last report. The engine owns the returned storage until
    /// the next engine call, so the text is copied before returning. A `None`
    /// answer means the host should leave the current window title alone.
    pub fn changed_document_title(&self) -> Option<String> {
        let mut slice = Slice {
            ptr: std::ptr::null(),
            len: 0,
        };
        let revision = unsafe { (self.document_title)(&mut slice) };
        if revision == self.applied_title.get() {
            return None;
        }
        assert!(slice.len <= 4096, "native window title exceeded its bound");
        let title = unsafe { slice.copy() };
        self.applied_title.set(revision);
        Some(title)
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
    fn signals_document_title(out: *mut Slice) -> u64;
    fn signals_scenario_open(path: Slice) -> u32;
    fn signals_scenario_header(out: *mut RawScenario);
    fn signals_scenario_choice(index: usize, out: *mut Slice);
    fn signals_scenario_scope(index: usize, out: *mut Slice);
    fn signals_scenario_count() -> usize;
    fn signals_scenario_command(index: usize, out: *mut RawStep);
    fn signals_scenario_arg(step: usize, index: usize, out: *mut RawArg);
    fn signals_scenario_close();
}

/// The header of a parsed `(scenario ...)`, as the engine hands it over.
#[repr(C)]
#[derive(Clone, Copy)]
struct RawScenario {
    name: Slice,
    window_width: u32,
    window_height: u32,
    assets: Slice,
    choices: usize,
    diagnostic: Slice,
    scopes: usize,
}

/// One parsed step as the engine hands it over. `kind` and `locator_kind`
/// carry the engine's enum tag names, so this reader never depends on the Zig
/// enum's numbering; the locator travels in full because every host resolves
/// one, and every other value is a named argument read separately.
#[repr(C)]
#[derive(Clone, Copy)]
pub(crate) struct RawStep {
    kind: Slice,
    line: u64,
    locator_kind: Slice,
    role: Slice,
    name: Slice,
    label: Slice,
    text: Slice,
    test_id: Slice,
    args: usize,
}

/// One named argument of a step; `kind` says which value field is live.
#[repr(C)]
#[derive(Clone, Copy)]
struct RawArg {
    name: Slice,
    kind: u32,
    text: Slice,
    unsigned: u64,
    signed: i64,
    boolean: u32,
}

/// A step argument, copied out of the engine's storage.
#[derive(Clone, Debug, PartialEq)]
pub(crate) enum Arg {
    Text(String),
    Unsigned(u64),
    Signed(i64),
    Boolean(bool),
}

/// An owned copy of one parsed step, with every string copied out of the
/// engine's storage so the scenario can be closed before the run starts.
#[derive(Clone, Debug, PartialEq)]
pub(crate) struct Command {
    pub(crate) kind: String,
    pub(crate) line: u64,
    pub(crate) locator_kind: String,
    pub(crate) role: String,
    pub(crate) name: String,
    pub(crate) label: String,
    pub(crate) text: String,
    pub(crate) test_id: String,
    /// The payload's named arguments, in the engine's field order.
    pub(crate) args: Vec<(String, Arg)>,
}

impl Command {
    /// The argument the engine published under this name, if any.
    pub(crate) fn arg(&self, name: &str) -> Option<&Arg> {
        self.args
            .iter()
            .find(|(candidate, _)| candidate == name)
            .map(|(_, value)| value)
    }
}

/// A parsed window scenario: its header and its steps, owned by the host.
#[derive(Clone, Debug, PartialEq)]
pub(crate) struct Scenario {
    pub(crate) name: String,
    /// Requested window size, when the header named one.
    pub(crate) window: Option<(f32, f32)>,
    /// Assets root relative to the example directory, when named.
    pub(crate) assets: Option<String>,
    /// Chooser answers relative to the example directory, in order.
    pub(crate) choices: Vec<String>,
    pub(crate) diagnostic: Option<String>,
    pub(crate) scopes: Vec<String>,
    pub(crate) commands: Vec<Command>,
}

/// Parses a scenario file through the engine's spec parser — the same parser
/// that reads every `(test ...)` — and copies the result out, so one grammar
/// and one parser decide what a step means on every host.
pub(crate) fn load_scenario(path: &str) -> Result<Scenario, String> {
    unsafe {
        let status = signals_scenario_open(Slice {
            ptr: path.as_ptr(),
            len: path.len(),
        });
        match status {
            0 => {}
            1 => return Err(format!("{path}: scenario file not found")),
            2 => return Err(format!("{path}: invalid spec format")),
            3 => return Err(format!(
                "{path}: this file is a (test ...); run it with --host-run-spec-json"
            )),
            _ => return Err(format!("{path}: cannot read the scenario")),
        }
        let mut header = std::mem::MaybeUninit::<RawScenario>::uninit();
        signals_scenario_header(header.as_mut_ptr());
        let header = header.assume_init();
        let optional = |slice: Slice| (slice.len > 0).then(|| slice.copy());
        let mut choices = Vec::with_capacity(header.choices);
        for index in 0..header.choices {
            let mut out = Slice { ptr: std::ptr::null(), len: 0 };
            signals_scenario_choice(index, &mut out);
            choices.push(out.copy());
        }
        let mut scopes = Vec::with_capacity(header.scopes);
        for index in 0..header.scopes {
            let mut out = Slice { ptr: std::ptr::null(), len: 0 };
            signals_scenario_scope(index, &mut out);
            scopes.push(out.copy());
        }
        let count = signals_scenario_count();
        let mut commands = Vec::with_capacity(count);
        for index in 0..count {
            let mut raw = std::mem::MaybeUninit::<RawStep>::uninit();
            signals_scenario_command(index, raw.as_mut_ptr());
            let raw = raw.assume_init();
            let mut args = Vec::with_capacity(raw.args);
            for arg_index in 0..raw.args {
                let mut arg = std::mem::MaybeUninit::<RawArg>::uninit();
                signals_scenario_arg(index, arg_index, arg.as_mut_ptr());
                let arg = arg.assume_init();
                let value = match arg.kind {
                    0 => Arg::Text(arg.text.copy()),
                    1 => Arg::Unsigned(arg.unsigned),
                    2 => Arg::Signed(arg.signed),
                    3 => Arg::Boolean(arg.boolean != 0),
                    other => panic!("unknown scenario argument kind {other}"),
                };
                args.push((arg.name.copy(), value));
            }
            commands.push(Command {
                kind: raw.kind.copy(),
                line: raw.line,
                locator_kind: raw.locator_kind.copy(),
                role: raw.role.copy(),
                name: raw.name.copy(),
                label: raw.label.copy(),
                text: raw.text.copy(),
                test_id: raw.test_id.copy(),
                args,
            });
        }
        let scenario = Scenario {
            name: header.name.copy(),
            window: (header.window_width > 0)
                .then_some((header.window_width as f32, header.window_height as f32)),
            assets: optional(header.assets),
            choices,
            diagnostic: optional(header.diagnostic),
            scopes,
            commands,
        };
        signals_scenario_close();
        Ok(scenario)
    }
}

#[cfg(test)]
thread_local! {
    static TEST_CHILDREN: std::cell::RefCell<std::collections::HashMap<u64, Vec<u64>>> = std::cell::RefCell::new(std::collections::HashMap::new());
    static TEST_EVENT: std::cell::RefCell<Option<(u64, u32, String, u32)>> = const { std::cell::RefCell::new(None) };
    static TEST_TITLE: std::cell::RefCell<(u64, String)> = const { std::cell::RefCell::new((0, String::new())) };
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
        unsafe extern "C" fn document_title(out: *mut Slice) -> u64 {
            TEST_TITLE.with(|slot| {
                let slot = slot.borrow();
                // Mirrors the engine contract: the slice borrows storage the
                // engine owns until its next call, and the caller copies it.
                unsafe {
                    *out = Slice {
                        ptr: slot.1.as_ptr(),
                        len: slot.1.len(),
                    }
                };
                slot.0
            })
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
            document_title,
            applied_title: std::cell::Cell::new(0),
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

    /// Scripts the window identity the fake boundary reports, standing in for a
    /// `SetDocumentTitle` command the engine committed at that revision.
    pub fn set_test_document_title(revision: u64, title: &str) {
        TEST_TITLE.with(|slot| *slot.borrow_mut() = (revision, title.to_owned()));
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
