// Adapted from GPUI 0.2.2 examples/input.rs, Copyright Zed Industries.
// Apache-2.0; see LICENSE-GPUI. Changes connect edits to the Signals ingress.
#![allow(unused_imports, dead_code)]
use std::{ops::Range, rc::Rc};

use gpui::{
    App, Application, Bounds, ClipboardItem, Context, CursorStyle, ElementId, ElementInputHandler,
    Entity, EntityInputHandler, FocusHandle, Focusable, GlobalElementId, KeyBinding, Keystroke,
    LayoutId, MouseButton, MouseDownEvent, MouseMoveEvent, MouseUpEvent, PaintQuad, Pixels, Point,
    ScrollHandle, ShapedLine, SharedString, Style, TextRun, UTF16Selection, UnderlineStyle, Window,
    WindowBounds, WindowOptions, actions, black, div, fill, hsla, opaque_grey, point, prelude::*,
    px, relative, rgb, rgba, size, white, yellow,
};
use unicode_segmentation::*;

actions!(
    text_input,
    [
        Backspace,
        Delete,
        Left,
        Right,
        SelectLeft,
        SelectRight,
        Up,
        Down,
        SelectUp,
        SelectDown,
        Newline,
        SelectAll,
        Home,
        End,
        SelectHome,
        SelectEnd,
        DocumentHome,
        DocumentEnd,
        ShowCharacterPalette,
        Paste,
        Cut,
        Copy,
        Quit,
    ]
);

const MAX_TEXT_BYTES: usize = 1024 * 1024;

pub struct TextInput {
    on_change: std::rc::Rc<dyn Fn(String, &mut App)>,
    pending_edit: std::rc::Rc<std::cell::Cell<bool>>,
    focus_handle: FocusHandle,
    content: SharedString,
    engine_value: SharedString,
    placeholder: SharedString,
    selected_range: Range<usize>,
    selection_reversed: bool,
    marked_range: Option<Range<usize>>,
    multiline: bool,
    disabled: bool,
    last_layout: Option<TextLayout>,
    last_bounds: Option<Bounds<Pixels>>,
    is_selecting: bool,
    scroll: ScrollHandle,
    reveal_cursor: bool,
    preferred_x: Option<Pixels>,
}

impl TextInput {
    /// Creates an editor for a single text field. Committed edits enter the
    /// shared engine through the supplied callback after the entity borrow ends.
    pub fn new(
        value: String,
        on_change: std::rc::Rc<dyn Fn(String, &mut App)>,
        cx: &mut Context<Self>,
    ) -> Self {
        assert!(value.len() <= MAX_TEXT_BYTES, "GUI text limit exceeded");
        Self {
            on_change,
            pending_edit: Default::default(),
            focus_handle: cx.focus_handle(),
            content: value.clone().into(),
            engine_value: value.into(),
            placeholder: "Type a draft…".into(),
            selected_range: 0..0,
            selection_reversed: false,
            marked_range: None,
            multiline: false,
            disabled: false,
            last_layout: None,
            last_bounds: None,
            is_selecting: false,
            scroll: ScrollHandle::new(),
            reveal_cursor: false,
            preferred_x: None,
        }
    }
    /// Creates an editor that preserves hard line breaks, including pasted text.
    /// Its scrollable viewport retains the same focus and selection identity as
    /// the single-line editor; soft wrapping is not part of this control.
    pub fn new_multiline(
        value: String,
        on_change: Rc<dyn Fn(String, &mut App)>,
        cx: &mut Context<Self>,
    ) -> Self {
        let mut input = Self::new(value, on_change, cx);
        input.multiline = true;
        input.placeholder = "Start writing…".into();
        input
    }

    /// Prevents user edits while retaining this editor's identity and selection.
    /// Reading, selecting, and copying remain available; authoritative engine
    /// values can still replace the document while native work is in progress.
    pub fn set_disabled(&mut self, disabled: bool, cx: &mut Context<Self>) {
        if self.disabled != disabled {
            self.disabled = disabled;
            cx.notify();
        }
    }

    /// Applies an authoritative engine value. Repeated snapshots and equal
    /// echoes preserve selection and composition; a changed engine value
    /// replaces the draft and ends preedit.
    pub fn set_value(&mut self, value: &str, cx: &mut Context<Self>) {
        assert!(value.len() <= MAX_TEXT_BYTES, "GUI text limit exceeded");
        if self.engine_value.as_ref() == value {
            return;
        }
        self.engine_value = value.to_owned().into();
        if self.content.as_ref() != value {
            self.content = value.to_owned().into();
            self.selected_range = value.len()..value.len();
            self.selection_reversed = false;
            self.marked_range = None;
            self.preferred_x = None;
            self.reveal_cursor = true;
            cx.notify();
        }
    }
    fn emit_change(&self, cx: &mut Context<Self>) {
        assert!(
            !self.pending_edit.replace(true),
            "GPUI spike editor ingress saturated"
        );
        let pending = self.pending_edit.clone();
        let callback = self.on_change.clone();
        let value = self.content.to_string();
        // Defer until the borrowed input entity has been released. The
        // callback submits one ordered engine turn and applies its whole batch.
        cx.defer(move |cx| {
            pending.set(false);
            callback(value, cx);
        });
    }

    fn left(&mut self, _: &Left, _: &mut Window, cx: &mut Context<Self>) {
        if self.selected_range.is_empty() {
            self.move_to(self.previous_boundary(self.cursor_offset()), cx);
        } else {
            self.move_to(self.selected_range.start, cx)
        }
    }

    fn right(&mut self, _: &Right, _: &mut Window, cx: &mut Context<Self>) {
        if self.selected_range.is_empty() {
            self.move_to(self.next_boundary(self.selected_range.end), cx);
        } else {
            self.move_to(self.selected_range.end, cx)
        }
    }

    fn select_left(&mut self, _: &SelectLeft, _: &mut Window, cx: &mut Context<Self>) {
        self.select_to(self.previous_boundary(self.cursor_offset()), cx);
    }

    fn select_right(&mut self, _: &SelectRight, _: &mut Window, cx: &mut Context<Self>) {
        self.select_to(self.next_boundary(self.cursor_offset()), cx);
    }

    fn up(&mut self, _: &Up, window: &mut Window, cx: &mut Context<Self>) {
        self.move_vertical(-1, false, window, cx);
    }

    fn down(&mut self, _: &Down, window: &mut Window, cx: &mut Context<Self>) {
        self.move_vertical(1, false, window, cx);
    }

    fn select_up(&mut self, _: &SelectUp, window: &mut Window, cx: &mut Context<Self>) {
        self.move_vertical(-1, true, window, cx);
    }

    fn select_down(&mut self, _: &SelectDown, window: &mut Window, cx: &mut Context<Self>) {
        self.move_vertical(1, true, window, cx);
    }

    fn move_vertical(
        &mut self,
        direction: isize,
        selecting: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        // Input can arrive faster than frames. Shape the two current logical
        // lines instead of interpreting new text with the previous frame's map.
        let ranges = line_ranges(&self.content, self.multiline);
        let current = ranges
            .partition_point(|range| range.start <= self.cursor_offset())
            .saturating_sub(1);
        let target = current
            .saturating_add_signed(direction)
            .min(ranges.len() - 1);
        let text_style = window.text_style();
        let font = self
            .last_layout
            .as_ref()
            .map_or_else(|| text_style.font(), |layout| layout.font.clone());
        let font_size = self
            .last_layout
            .as_ref()
            .map_or(px(18.), |layout| layout.font_size);
        let shape = |range: &Range<usize>| {
            let text: SharedString = self.content[range.clone()].to_owned().into();
            let run = TextRun {
                len: text.len(),
                font: font.clone(),
                color: text_style.color,
                background_color: None,
                underline: None,
                strikethrough: None,
            };
            window
                .text_system()
                .shape_line(text, font_size, &[run], None)
        };
        let current_line = shape(&ranges[current]);
        let target_line = shape(&ranges[target]);
        let x = self.preferred_x.unwrap_or_else(|| {
            current_line.x_for_index(self.cursor_offset() - ranges[current].start)
        });
        let offset =
            ranges[target].start + target_line.closest_index_for_x(x).min(ranges[target].len());
        if selecting {
            self.select_to(offset, cx)
        } else {
            self.move_to(offset, cx)
        }
        self.preferred_x = Some(x);
    }

    fn newline(&mut self, _: &Newline, window: &mut Window, cx: &mut Context<Self>) {
        if self.disabled {
            return;
        }
        self.replace_text_in_range(None, "\n", window, cx);
    }

    fn select_all(&mut self, _: &SelectAll, _: &mut Window, cx: &mut Context<Self>) {
        self.move_to(0, cx);
        self.select_to(self.content.len(), cx)
    }

    fn home(&mut self, _: &Home, _: &mut Window, cx: &mut Context<Self>) {
        self.move_to(self.line_range().start, cx);
    }

    fn end(&mut self, _: &End, _: &mut Window, cx: &mut Context<Self>) {
        self.move_to(self.line_range().end, cx);
    }

    fn select_home(&mut self, _: &SelectHome, _: &mut Window, cx: &mut Context<Self>) {
        self.select_to(self.line_range().start, cx);
    }

    fn select_end(&mut self, _: &SelectEnd, _: &mut Window, cx: &mut Context<Self>) {
        self.select_to(self.line_range().end, cx);
    }

    fn document_home(&mut self, _: &DocumentHome, _: &mut Window, cx: &mut Context<Self>) {
        self.move_to(0, cx);
    }

    fn document_end(&mut self, _: &DocumentEnd, _: &mut Window, cx: &mut Context<Self>) {
        self.move_to(self.content.len(), cx);
    }

    fn line_range(&self) -> Range<usize> {
        if !self.multiline {
            return 0..self.content.len();
        }
        let cursor = self.cursor_offset();
        let start = self.content[..cursor]
            .rfind('\n')
            .map_or(0, |index| index + 1);
        let end = self.content[cursor..]
            .find('\n')
            .map_or(self.content.len(), |index| cursor + index);
        start..end
    }

    fn backspace(&mut self, _: &Backspace, window: &mut Window, cx: &mut Context<Self>) {
        if self.disabled {
            return;
        }
        if self.selected_range.is_empty() {
            self.select_to(self.previous_boundary(self.cursor_offset()), cx)
        }
        self.replace_text_in_range(None, "", window, cx)
    }

    fn delete(&mut self, _: &Delete, window: &mut Window, cx: &mut Context<Self>) {
        if self.disabled {
            return;
        }
        if self.selected_range.is_empty() {
            self.select_to(self.next_boundary(self.cursor_offset()), cx)
        }
        self.replace_text_in_range(None, "", window, cx)
    }

    fn on_mouse_down(
        &mut self,
        event: &MouseDownEvent,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.is_selecting = true;
        self.focus_handle.focus(window);

        if event.modifiers.shift {
            self.select_to(self.index_for_mouse_position(event.position), cx);
        } else {
            self.move_to(self.index_for_mouse_position(event.position), cx)
        }
    }

    fn on_mouse_up(&mut self, _: &MouseUpEvent, _window: &mut Window, _: &mut Context<Self>) {
        self.is_selecting = false;
    }

    fn on_mouse_move(&mut self, event: &MouseMoveEvent, _: &mut Window, cx: &mut Context<Self>) {
        if self.is_selecting {
            self.select_to(self.index_for_mouse_position(event.position), cx);
        }
    }

    fn show_character_palette(
        &mut self,
        _: &ShowCharacterPalette,
        window: &mut Window,
        _: &mut Context<Self>,
    ) {
        window.show_character_palette();
    }

    fn paste(&mut self, _: &Paste, window: &mut Window, cx: &mut Context<Self>) {
        if self.disabled {
            return;
        }
        if let Some(text) = cx.read_from_clipboard().and_then(|item| item.text()) {
            if self.multiline {
                self.replace_text_in_range(None, &text, window, cx);
            } else {
                self.replace_text_in_range(None, &text.replace(['\r', '\n'], " "), window, cx);
            }
        }
    }

    fn copy(&mut self, _: &Copy, _: &mut Window, cx: &mut Context<Self>) {
        if !self.selected_range.is_empty() {
            cx.write_to_clipboard(ClipboardItem::new_string(
                self.content[self.selected_range.clone()].to_string(),
            ));
        }
    }
    fn cut(&mut self, _: &Cut, window: &mut Window, cx: &mut Context<Self>) {
        if self.disabled {
            return;
        }
        if !self.selected_range.is_empty() {
            cx.write_to_clipboard(ClipboardItem::new_string(
                self.content[self.selected_range.clone()].to_string(),
            ));
            self.replace_text_in_range(None, "", window, cx)
        }
    }

    fn move_to(&mut self, offset: usize, cx: &mut Context<Self>) {
        self.selected_range = offset..offset;
        self.selection_reversed = false;
        self.preferred_x = None;
        self.reveal_cursor = true;
        cx.notify()
    }

    fn cursor_offset(&self) -> usize {
        if self.selection_reversed {
            self.selected_range.start
        } else {
            self.selected_range.end
        }
    }

    fn index_for_mouse_position(&self, position: Point<Pixels>) -> usize {
        if self.content.is_empty() {
            return 0;
        }

        let (Some(bounds), Some(layout)) = (self.last_bounds.as_ref(), self.last_layout.as_ref())
        else {
            return 0;
        };
        if position.y < bounds.top() {
            return 0;
        }
        if position.y > bounds.bottom() {
            return self.content.len();
        }
        let row = (((position.y - bounds.top()) / layout.line_height).floor() as usize)
            .min(layout.lines.len() - 1);
        let line = &layout.lines[row];
        line.range.start
            + line
                .shaped
                .closest_index_for_x(position.x - bounds.left())
                .min(line.range.len())
    }

    fn select_to(&mut self, offset: usize, cx: &mut Context<Self>) {
        self.preferred_x = None;
        self.reveal_cursor = true;
        if self.selection_reversed {
            self.selected_range.start = offset
        } else {
            self.selected_range.end = offset
        };
        if self.selected_range.end < self.selected_range.start {
            self.selection_reversed = !self.selection_reversed;
            self.selected_range = self.selected_range.end..self.selected_range.start;
        }
        cx.notify()
    }

    fn offset_from_utf16(&self, offset: usize) -> usize {
        offset_from_utf16(&self.content, offset)
    }

    fn offset_to_utf16(&self, offset: usize) -> usize {
        let mut utf16_offset = 0;
        let mut utf8_count = 0;

        for ch in self.content.chars() {
            if utf8_count >= offset {
                break;
            }
            utf8_count += ch.len_utf8();
            utf16_offset += ch.len_utf16();
        }

        utf16_offset
    }

    fn range_to_utf16(&self, range: &Range<usize>) -> Range<usize> {
        self.offset_to_utf16(range.start)..self.offset_to_utf16(range.end)
    }

    fn range_from_utf16(&self, range_utf16: &Range<usize>) -> Range<usize> {
        self.offset_from_utf16(range_utf16.start)..self.offset_from_utf16(range_utf16.end)
    }

    fn previous_boundary(&self, offset: usize) -> usize {
        self.content
            .grapheme_indices(true)
            .rev()
            .find_map(|(idx, _)| (idx < offset).then_some(idx))
            .unwrap_or(0)
    }

    fn next_boundary(&self, offset: usize) -> usize {
        self.content
            .grapheme_indices(true)
            .find_map(|(idx, _)| (idx > offset).then_some(idx))
            .unwrap_or(self.content.len())
    }

    fn reset(&mut self) {
        self.content = "".into();
        self.engine_value = "".into();
        self.selected_range = 0..0;
        self.selection_reversed = false;
        self.marked_range = None;
        self.last_layout = None;
        self.last_bounds = None;
        self.is_selecting = false;
        self.scroll.set_offset(point(px(0.), px(0.)));
        self.reveal_cursor = false;
        self.preferred_x = None;
    }
}

impl EntityInputHandler for TextInput {
    fn text_for_range(
        &mut self,
        range_utf16: Range<usize>,
        actual_range: &mut Option<Range<usize>>,
        _window: &mut Window,
        _cx: &mut Context<Self>,
    ) -> Option<String> {
        let range = self.range_from_utf16(&range_utf16);
        actual_range.replace(self.range_to_utf16(&range));
        Some(self.content[range].to_string())
    }

    fn selected_text_range(
        &mut self,
        ignore_disabled_input: bool,
        _window: &mut Window,
        _cx: &mut Context<Self>,
    ) -> Option<UTF16Selection> {
        if self.disabled && !ignore_disabled_input {
            return None;
        }
        Some(UTF16Selection {
            range: self.range_to_utf16(&self.selected_range),
            reversed: self.selection_reversed,
        })
    }

    fn marked_text_range(
        &self,
        _window: &mut Window,
        _cx: &mut Context<Self>,
    ) -> Option<Range<usize>> {
        self.marked_range
            .as_ref()
            .map(|range| self.range_to_utf16(range))
    }

    fn unmark_text(&mut self, _window: &mut Window, cx: &mut Context<Self>) {
        if self.disabled {
            return;
        }
        // Wayland resets composition with unmark_text before mouse dispatch.
        // The displayed preedit becomes committed text before that next action.
        if self.marked_range.take().is_some() {
            self.emit_change(cx);
        }
        cx.notify();
    }

    fn replace_text_in_range(
        &mut self,
        range_utf16: Option<Range<usize>>,
        new_text: &str,
        _: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.disabled {
            return;
        }
        let range = range_utf16
            .as_ref()
            .map(|range_utf16| self.range_from_utf16(range_utf16))
            .or(self.marked_range.clone())
            .unwrap_or(self.selected_range.clone());

        // Refuse the whole user edit before changing text, selection, or IME
        // state. Authoritative engine values remain a strict boundary contract.
        if new_text.len() > MAX_TEXT_BYTES - (self.content.len() - range.len()) {
            return;
        }
        self.content =
            (self.content[0..range.start].to_owned() + new_text + &self.content[range.end..])
                .into();
        self.selected_range = range.start + new_text.len()..range.start + new_text.len();
        self.selection_reversed = false;
        self.marked_range.take();
        self.preferred_x = None;
        self.reveal_cursor = true;
        self.emit_change(cx);
        cx.notify();
    }

    fn replace_and_mark_text_in_range(
        &mut self,
        range_utf16: Option<Range<usize>>,
        new_text: &str,
        new_selected_range_utf16: Option<Range<usize>>,
        _window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.disabled {
            return;
        }
        let range = range_utf16
            .as_ref()
            .map(|range_utf16| self.range_from_utf16(range_utf16))
            .or(self.marked_range.clone())
            .unwrap_or(self.selected_range.clone());

        // Refuse the whole user edit before changing text, selection, or IME
        // state. Authoritative engine values remain a strict boundary contract.
        if new_text.len() > MAX_TEXT_BYTES - (self.content.len() - range.len()) {
            return;
        }
        self.content =
            (self.content[0..range.start].to_owned() + new_text + &self.content[range.end..])
                .into();
        if !new_text.is_empty() {
            self.marked_range = Some(range.start..range.start + new_text.len());
        } else {
            self.marked_range = None;
        }
        self.selected_range = new_selected_range_utf16
            .as_ref()
            .map(|selection| {
                range.start + offset_from_utf16(new_text, selection.start)
                    ..range.start + offset_from_utf16(new_text, selection.end)
            })
            .unwrap_or_else(|| range.start + new_text.len()..range.start + new_text.len());
        self.selection_reversed = false;
        self.preferred_x = None;
        self.reveal_cursor = true;
        cx.notify();
    }

    fn bounds_for_range(
        &mut self,
        range_utf16: Range<usize>,
        bounds: Bounds<Pixels>,
        _window: &mut Window,
        _cx: &mut Context<Self>,
    ) -> Option<Bounds<Pixels>> {
        let layout = self.last_layout.as_ref()?;
        let range = self.range_from_utf16(&range_utf16);
        let row = layout.line_for_offset(range.start);
        let line = &layout.lines[row];
        let origin = point(
            bounds.left(),
            bounds.top() + layout.line_height * row as f32,
        );
        Some(Bounds::from_corners(
            point(
                origin.x + line.shaped.x_for_index(range.start - line.range.start),
                origin.y,
            ),
            point(
                origin.x
                    + line
                        .shaped
                        .x_for_index(range.end.min(line.range.end) - line.range.start),
                origin.y + layout.line_height,
            ),
        ))
    }

    fn character_index_for_point(
        &mut self,
        point: gpui::Point<Pixels>,
        _window: &mut Window,
        _cx: &mut Context<Self>,
    ) -> Option<usize> {
        self.last_bounds?.localize(&point)?;
        Some(self.offset_to_utf16(self.index_for_mouse_position(point)))
    }
}

fn offset_from_utf16(text: &str, offset: usize) -> usize {
    let mut utf8_offset = 0;
    let mut utf16_count = 0;
    for ch in text.chars() {
        if utf16_count >= offset {
            break;
        }
        utf16_count += ch.len_utf16();
        utf8_offset += ch.len_utf8();
    }
    utf8_offset
}

// Newline bytes belong to the document, but not to the shaped line. Preserve an
// empty final line so a caret after a trailing newline has its own visual row.
fn line_ranges(text: &str, multiline: bool) -> Vec<Range<usize>> {
    if !multiline {
        return vec![0..text.len()];
    }
    let mut start = 0;
    let mut ranges = Vec::new();
    for (index, byte) in text.bytes().enumerate() {
        if byte == b'\n' {
            ranges.push(start..index);
            start = index + 1;
        }
    }
    ranges.push(start..text.len());
    ranges
}

struct TextLine {
    range: Range<usize>,
    shaped: ShapedLine,
}

struct TextLayout {
    lines: Vec<TextLine>,
    line_height: Pixels,
    font: gpui::Font,
    font_size: Pixels,
}

impl TextLayout {
    fn line_for_offset(&self, offset: usize) -> usize {
        self.lines
            .partition_point(|line| line.range.start <= offset)
            .saturating_sub(1)
    }
}

struct TextElement {
    input: Entity<TextInput>,
}

struct PrepaintState {
    cursor: Option<PaintQuad>,
    selections: Vec<PaintQuad>,
}

impl IntoElement for TextElement {
    type Element = Self;

    fn into_element(self) -> Self::Element {
        self
    }
}

impl Element for TextElement {
    type RequestLayoutState = Option<TextLayout>;
    type PrepaintState = PrepaintState;

    fn id(&self) -> Option<ElementId> {
        None
    }

    fn source_location(&self) -> Option<&'static core::panic::Location<'static>> {
        None
    }

    fn request_layout(
        &mut self,
        _id: Option<&GlobalElementId>,
        _inspector_id: Option<&gpui::InspectorElementId>,
        window: &mut Window,
        cx: &mut App,
    ) -> (LayoutId, Self::RequestLayoutState) {
        let input = self.input.read(cx);
        let text_style = window.text_style();
        let font_size = text_style.font_size.to_pixels(window.rem_size());
        let line_height = window.line_height();
        let mut width = px(0.);
        let mut lines = Vec::new();
        for range in line_ranges(&input.content, input.multiline) {
            let placeholder = input.content.is_empty();
            let text: SharedString = if placeholder {
                input.placeholder.clone()
            } else {
                input.content[range.clone()].to_owned().into()
            };
            let run = TextRun {
                len: text.len(),
                font: text_style.font(),
                color: if placeholder {
                    hsla(0., 0., 0., 0.4)
                } else {
                    text_style.color
                },
                background_color: None,
                underline: None,
                strikethrough: None,
            };
            let mut runs = Vec::new();
            if let Some(marked) = input
                .marked_range
                .as_ref()
                .filter(|marked| marked.start < range.end && marked.end > range.start)
            {
                let start = marked.start.max(range.start) - range.start;
                let end = marked.end.min(range.end) - range.start;
                if start > 0 {
                    runs.push(TextRun {
                        len: start,
                        ..run.clone()
                    });
                }
                runs.push(TextRun {
                    len: end - start,
                    underline: Some(UnderlineStyle {
                        color: Some(run.color),
                        thickness: px(1.),
                        wavy: false,
                    }),
                    ..run.clone()
                });
                if end < text.len() {
                    runs.push(TextRun {
                        len: text.len() - end,
                        ..run
                    });
                }
            } else {
                runs.push(run);
            }
            let shaped = window
                .text_system()
                .shape_line(text, font_size, &runs, None);
            width = width.max(shaped.width);
            lines.push(TextLine { range, shaped });
        }
        let layout = TextLayout {
            lines,
            line_height,
            font: text_style.font(),
            font_size,
        };
        if input.reveal_cursor {
            let row = layout.line_for_offset(input.cursor_offset());
            let line = &layout.lines[row];
            let x = line
                .shaped
                .x_for_index(input.cursor_offset() - line.range.start);
            let y = line_height * row as f32;
            let viewport = input.scroll.bounds().size;
            let mut offset = input.scroll.offset();
            if viewport.width > px(0.) {
                if x + offset.x < px(0.) {
                    offset.x = -x;
                }
                if x + px(4.) + offset.x > viewport.width {
                    offset.x = viewport.width - x - px(4.);
                }
            }
            if input.multiline && viewport.height > px(0.) {
                if y + offset.y < px(0.) {
                    offset.y = -y;
                }
                if y + line_height + offset.y > viewport.height {
                    offset.y = viewport.height - y - line_height;
                }
            }
            input
                .scroll
                .set_offset(point(offset.x.min(px(0.)), offset.y.min(px(0.))));
        }
        let mut style = Style::default();
        style.size.width = (width + px(4.)).into();
        style.min_size.width = relative(1.).into();
        style.size.height = (line_height * layout.lines.len() as f32).into();
        style.flex_shrink = 0.;
        self.input
            .update(cx, |input, _| input.reveal_cursor = false);
        (window.request_layout(style, [], cx), Some(layout))
    }

    fn prepaint(
        &mut self,
        _id: Option<&GlobalElementId>,
        _inspector_id: Option<&gpui::InspectorElementId>,
        bounds: Bounds<Pixels>,
        request_layout: &mut Self::RequestLayoutState,
        _window: &mut Window,
        cx: &mut App,
    ) -> Self::PrepaintState {
        let input = self.input.read(cx);
        let layout = request_layout.as_ref().unwrap();
        let selected = &input.selected_range;
        let mut selections = Vec::new();
        let mut cursor = None;
        for (row, line) in layout.lines.iter().enumerate() {
            let top = bounds.top() + layout.line_height * row as f32;
            if selected.is_empty() {
                if layout.line_for_offset(input.cursor_offset()) == row {
                    let x = line
                        .shaped
                        .x_for_index(input.cursor_offset() - line.range.start);
                    cursor = Some(fill(
                        Bounds::new(
                            point(bounds.left() + x, top),
                            size(px(2.), layout.line_height),
                        ),
                        gpui::blue(),
                    ));
                }
            } else if selected.start <= line.range.end && selected.end > line.range.start {
                let start = selected.start.max(line.range.start) - line.range.start;
                let end = selected.end.min(line.range.end) - line.range.start;
                let start_x = line.shaped.x_for_index(start);
                let end_x = line.shaped.x_for_index(end)
                    + if selected.end > line.range.end {
                        px(6.)
                    } else {
                        px(0.)
                    };
                selections.push(fill(
                    Bounds::new(
                        point(bounds.left() + start_x, top),
                        size(end_x - start_x, layout.line_height),
                    ),
                    rgba(0x3311ff30),
                ));
            }
        }
        PrepaintState { cursor, selections }
    }

    fn paint(
        &mut self,
        _id: Option<&GlobalElementId>,
        _inspector_id: Option<&gpui::InspectorElementId>,
        bounds: Bounds<Pixels>,
        request_layout: &mut Self::RequestLayoutState,
        prepaint: &mut Self::PrepaintState,
        window: &mut Window,
        cx: &mut App,
    ) {
        let focus_handle = self.input.read(cx).focus_handle.clone();
        window.handle_input(
            &focus_handle,
            ElementInputHandler::new(bounds, self.input.clone()),
            cx,
        );
        for selection in prepaint.selections.drain(..) {
            window.paint_quad(selection)
        }
        let layout = request_layout.take().unwrap();
        let mask = window.content_mask().bounds;
        for (row, line) in layout.lines.iter().enumerate() {
            let top = bounds.top() + layout.line_height * row as f32;
            if top + layout.line_height >= mask.top() && top <= mask.bottom() {
                line.shaped
                    .paint(point(bounds.left(), top), layout.line_height, window, cx)
                    .unwrap();
            }
        }

        if focus_handle.is_focused(window)
            && let Some(cursor) = prepaint.cursor.take()
        {
            window.paint_quad(cursor);
        }

        self.input.update(cx, |input, _cx| {
            input.last_layout = Some(layout);
            input.last_bounds = Some(bounds);
        });
    }
}

impl Render for TextInput {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        div()
            .id("text-editor")
            .flex()
            .flex_col()
            .w_full()
            .min_w_0()
            .h(if self.multiline { px(320.) } else { px(38.) })
            .overflow_scroll()
            .track_scroll(&self.scroll)
            .p(px(4.))
            .key_context(if self.multiline {
                "MultilineInput"
            } else {
                "TextInput"
            })
            .track_focus(&self.focus_handle(cx))
            .cursor(CursorStyle::IBeam)
            .on_action(cx.listener(Self::backspace))
            .on_action(cx.listener(Self::delete))
            .on_action(cx.listener(Self::left))
            .on_action(cx.listener(Self::right))
            .on_action(cx.listener(Self::select_left))
            .on_action(cx.listener(Self::select_right))
            .on_action(cx.listener(Self::up))
            .on_action(cx.listener(Self::down))
            .on_action(cx.listener(Self::select_up))
            .on_action(cx.listener(Self::select_down))
            .on_action(cx.listener(Self::newline))
            .on_action(cx.listener(Self::select_all))
            .on_action(cx.listener(Self::home))
            .on_action(cx.listener(Self::end))
            .on_action(cx.listener(Self::select_home))
            .on_action(cx.listener(Self::select_end))
            .on_action(cx.listener(Self::document_home))
            .on_action(cx.listener(Self::document_end))
            .on_action(cx.listener(Self::show_character_palette))
            .on_action(cx.listener(Self::paste))
            .on_action(cx.listener(Self::cut))
            .on_action(cx.listener(Self::copy))
            .on_mouse_down(MouseButton::Left, cx.listener(Self::on_mouse_down))
            .on_mouse_up(MouseButton::Left, cx.listener(Self::on_mouse_up))
            .on_mouse_up_out(MouseButton::Left, cx.listener(Self::on_mouse_up))
            .on_mouse_move(cx.listener(Self::on_mouse_move))
            .bg(rgb(0xeeeeee))
            .line_height(px(30.))
            .text_size(px(18.))
            .text_color(rgb(0x151515))
            .child(TextElement { input: cx.entity() })
    }
}

impl Focusable for TextInput {
    fn focus_handle(&self, _: &App) -> FocusHandle {
        self.focus_handle.clone()
    }
}

/// Installs editing shortcuts only within editor focus contexts. Enter and
/// vertical movement belong to multiline editors, leaving ordinary fields free
/// to participate in their surrounding form's actions.
pub fn bind_keys(cx: &mut App) {
    for context in ["TextInput", "MultilineInput"] {
        cx.bind_keys([
            KeyBinding::new("backspace", Backspace, Some(context)),
            KeyBinding::new("delete", Delete, Some(context)),
            KeyBinding::new("left", Left, Some(context)),
            KeyBinding::new("right", Right, Some(context)),
            KeyBinding::new("shift-left", SelectLeft, Some(context)),
            KeyBinding::new("shift-right", SelectRight, Some(context)),
            KeyBinding::new("ctrl-a", SelectAll, Some(context)),
            KeyBinding::new("ctrl-v", Paste, Some(context)),
            KeyBinding::new("ctrl-c", Copy, Some(context)),
            KeyBinding::new("ctrl-x", Cut, Some(context)),
            KeyBinding::new("home", Home, Some(context)),
            KeyBinding::new("end", End, Some(context)),
            KeyBinding::new("shift-home", SelectHome, Some(context)),
            KeyBinding::new("shift-end", SelectEnd, Some(context)),
            KeyBinding::new("ctrl-home", DocumentHome, Some(context)),
            KeyBinding::new("ctrl-end", DocumentEnd, Some(context)),
        ]);
    }
    cx.bind_keys([
        KeyBinding::new("enter", Newline, Some("MultilineInput")),
        KeyBinding::new("up", Up, Some("MultilineInput")),
        KeyBinding::new("down", Down, Some("MultilineInput")),
        KeyBinding::new("shift-up", SelectUp, Some("MultilineInput")),
        KeyBinding::new("shift-down", SelectDown, Some("MultilineInput")),
    ]);
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::RefCell;

    #[test]
    fn hard_lines_keep_empty_final_rows_and_unicode_byte_positions() {
        assert_eq!(line_ranges("é\n\n🙂\n", true), vec![0..2, 3..3, 4..8, 9..9]);
        assert_eq!(line_ranges("", true), vec![0..0]);
        assert_eq!(line_ranges("é\n🙂", false), vec![0..7]);
    }

    #[gpui::test]
    fn oversized_edits_paste_and_ime_preserve_state_and_allow_recovery(
        cx: &mut gpui::TestAppContext,
    ) {
        let edits = Rc::new(RefCell::new(Vec::new()));
        let captured = edits.clone();
        // Exercise the actual handler and GPUI clipboard with an unrendered
        // entity so this bound test does not shape a million-glyph line.
        let (_, cx) = cx.add_window_view(|_, cx| TextInput::new("".into(), Rc::new(|_, _| {}), cx));
        let input = cx.update(|_, cx| {
            cx.new(|cx| {
                TextInput::new_multiline(
                    "a".repeat(MAX_TEXT_BYTES - 4) + "🙂",
                    Rc::new(move |text, _| captured.borrow_mut().push(text)),
                    cx,
                )
            })
        });
        cx.update(|window, cx| {
            input.update(cx, |input, cx| {
                input.selected_range = MAX_TEXT_BYTES..MAX_TEXT_BYTES;
                input.replace_text_in_range(None, "é", window, cx);
                cx.write_to_clipboard(ClipboardItem::new_string("paste".into()));
                input.paste(&Paste, window, cx);
                input.replace_and_mark_text_in_range(None, "é", None, window, cx);
                assert_eq!(input.content.len(), MAX_TEXT_BYTES);
                assert!(input.content.ends_with("🙂"));
                assert_eq!(input.selected_range, MAX_TEXT_BYTES..MAX_TEXT_BYTES);
                assert!(input.marked_range.is_none());
                input.selected_range = MAX_TEXT_BYTES - 4..MAX_TEXT_BYTES;
                input.selection_reversed = true;
                input.replace_text_in_range(None, "12345", window, cx);
                assert_eq!(input.selected_range, MAX_TEXT_BYTES - 4..MAX_TEXT_BYTES);
                assert!(input.selection_reversed);
                input.replace_and_mark_text_in_range(None, "é", Some(0..1), window, cx);
                let selection = input.selected_range.clone();
                let marked = input.marked_range.clone();
                input.replace_and_mark_text_in_range(None, "12345", None, window, cx);
                input.replace_text_in_range(None, "12345", window, cx);
                assert_eq!(input.content.len(), MAX_TEXT_BYTES - 2);
                assert!(input.content.ends_with('é'));
                assert_eq!(input.selected_range, selection);
                assert_eq!(input.marked_range, marked);
            })
        });
        assert!(edits.borrow().is_empty());
        cx.update(|window, cx| {
            input.update(cx, |input, cx| {
                input.replace_text_in_range(None, "é", window, cx);
                assert!(input.marked_range.is_none());
            })
        });
        assert_eq!(edits.borrow().len(), 1);
        assert_eq!(edits.borrow()[0].len(), MAX_TEXT_BYTES - 2);
        cx.update(|window, cx| {
            input.update(cx, |input, cx| {
                input.replace_text_in_range(None, "ok", window, cx);
            })
        });
        assert_eq!(edits.borrow().len(), 2);
        assert_eq!(edits.borrow()[1].len(), MAX_TEXT_BYTES);
        assert!(edits.borrow()[1].ends_with("éok"));
    }

    #[test]
    fn ime_utf16_offsets_are_relative_to_the_inserted_text() {
        assert_eq!(offset_from_utf16("é🙂", 1), 2);
        assert_eq!(offset_from_utf16("é🙂", 3), 6);
    }

    #[gpui::test]
    fn multiline_keyboard_and_clipboard_preserve_newlines(cx: &mut gpui::TestAppContext) {
        cx.update(bind_keys);
        let edits = Rc::new(RefCell::new(Vec::new()));
        let captured = edits.clone();
        let (input, cx) = cx.add_window_view(|window, cx| {
            let input = TextInput::new_multiline(
                "Hello".into(),
                Rc::new(move |text, _| captured.borrow_mut().push(text)),
                cx,
            );
            input.focus_handle.focus(window);
            input
        });
        cx.simulate_keystrokes("end enter");
        cx.simulate_input("world");
        cx.update(|_, cx| assert_eq!(input.read(cx).content.as_ref(), "Hello\nworld"));
        cx.simulate_keystrokes("home shift-end ctrl-c ctrl-end enter ctrl-v");
        cx.update(|_, cx| assert_eq!(input.read(cx).content.as_ref(), "Hello\nworld\nworld"));
        assert_eq!(
            edits.borrow().last().map(String::as_str),
            Some("Hello\nworld\nworld")
        );
    }

    #[gpui::test]
    fn preedit_stays_local_and_commit_routes_one_complete_text_value(
        cx: &mut gpui::TestAppContext,
    ) {
        let edits = Rc::new(RefCell::new(Vec::new()));
        let captured = edits.clone();
        let (input, cx) = cx.add_window_view(|_, cx| {
            TextInput::new_multiline(
                "prefix ".into(),
                Rc::new(move |text, _| captured.borrow_mut().push(text)),
                cx,
            )
        });
        cx.update(|window, cx| {
            input.update(cx, |input, cx| {
                input.move_to(input.content.len(), cx);
                input.replace_and_mark_text_in_range(None, "é🙂", Some(1..3), window, cx);
                // An unrelated style publication includes the same engine
                // value; it must not overwrite uncommitted composition.
                input.set_value("prefix ", cx);
                assert_eq!(input.content.as_ref(), "prefix é🙂");
                assert_eq!(input.selected_range, 9..13);
                assert_eq!(input.marked_range, Some(7..13));
            })
        });
        assert!(edits.borrow().is_empty());
        cx.update(|window, cx| {
            input.update(cx, |input, cx| {
                input.replace_text_in_range(None, "é🙂", window, cx);
                assert_eq!(input.selected_range, 13..13);
                assert!(input.marked_range.is_none());
            })
        });
        cx.run_until_parked();
        assert_eq!(*edits.borrow(), vec!["prefix é🙂"]);
    }

    #[gpui::test]
    fn equal_echo_keeps_selection_and_new_movement_resets_its_anchor(
        cx: &mut gpui::TestAppContext,
    ) {
        let (input, cx) = cx.add_window_view(|_, cx| {
            TextInput::new_multiline("one\ntwo".into(), Rc::new(|_, _| {}), cx)
        });
        cx.update(|_, cx| {
            input.update(cx, |input, cx| {
                input.move_to(7, cx);
                input.select_to(4, cx);
                input.set_value("one\ntwo", cx);
                assert_eq!(input.selected_range, 4..7);
                assert!(input.selection_reversed);
                input.move_to(0, cx);
                input.select_to(3, cx);
                assert_eq!(input.selected_range, 0..3);
                assert!(!input.selection_reversed);
            })
        });
    }

    #[gpui::test]
    fn ending_preedit_before_a_pointer_action_commits_the_visible_text(
        cx: &mut gpui::TestAppContext,
    ) {
        let edits = Rc::new(RefCell::new(Vec::new()));
        let captured = edits.clone();
        let (input, cx) = cx.add_window_view(|_, cx| {
            TextInput::new_multiline(
                "".into(),
                Rc::new(move |text, _| captured.borrow_mut().push(text)),
                cx,
            )
        });
        cx.update(|window, cx| {
            input.update(cx, |input, cx| {
                input.replace_and_mark_text_in_range(None, "café", None, window, cx);
                input.unmark_text(window, cx);
            })
        });
        cx.run_until_parked();
        assert_eq!(*edits.borrow(), vec!["café"]);
        cx.update(|window, cx| input.update(cx, |input, cx| input.unmark_text(window, cx)));
        assert_eq!(edits.borrow().len(), 1);
    }

    #[gpui::test]
    fn disabled_editor_preserves_identity_and_selection_while_refusing_edits(
        cx: &mut gpui::TestAppContext,
    ) {
        cx.update(bind_keys);
        let edits = Rc::new(RefCell::new(Vec::new()));
        let captured = edits.clone();
        let (input, cx) = cx.add_window_view(|window, cx| {
            let input = TextInput::new_multiline(
                "Keep this".into(),
                Rc::new(move |text, _| captured.borrow_mut().push(text)),
                cx,
            );
            input.focus_handle.focus(window);
            input
        });
        cx.update(|_, cx| {
            input.update(cx, |input, cx| {
                input.move_to(0, cx);
                input.select_to(4, cx);
                input.set_disabled(true, cx);
            })
        });
        cx.simulate_keystrokes("backspace delete enter ctrl-x ctrl-v");
        cx.update(|window, cx| {
            input.update(cx, |input, cx| {
                input.replace_text_in_range(None, "changed", window, cx);
                input.replace_and_mark_text_in_range(None, "preedit", None, window, cx);
                assert_eq!(input.content.as_ref(), "Keep this");
                assert_eq!(input.selected_range, 0..4);
                assert!(input.marked_range.is_none());
                assert!(input.focus_handle.is_focused(window));
                input.copy(&Copy, window, cx);
                input.set_disabled(false, cx);
            })
        });
        assert!(edits.borrow().is_empty());
        cx.simulate_keystrokes("ctrl-v");
        cx.update(|_, cx| assert_eq!(input.read(cx).content.as_ref(), "Keep this"));
    }

    #[gpui::test]
    fn clicking_second_line_focuses_the_editor_and_vertical_keys_keep_column(
        cx: &mut gpui::TestAppContext,
    ) {
        cx.update(bind_keys);
        let (input, cx) = cx.add_window_view(|_, cx| {
            TextInput::new_multiline("first\nsecond\nthird".into(), Rc::new(|_, _| {}), cx)
        });
        let target = cx.update(|_, cx| {
            let input = input.read(cx);
            let layout = input.last_layout.as_ref().unwrap();
            let bounds = input.last_bounds.unwrap();
            point(bounds.left(), bounds.top() + layout.line_height + px(1.))
        });
        cx.simulate_click(target, gpui::Modifiers::default());
        cx.update(|window, cx| {
            let input = input.read(cx);
            assert!(input.focus_handle.is_focused(window));
            assert_eq!(input.cursor_offset(), 6);
        });
        cx.simulate_keystrokes("down");
        cx.update(|_, cx| assert_eq!(input.read(cx).cursor_offset(), 13));
        cx.simulate_keystrokes("up");
        cx.update(|_, cx| assert_eq!(input.read(cx).cursor_offset(), 6));
    }

    #[gpui::test]
    fn keyboard_reveals_distant_lines_and_backspace_removes_a_whole_grapheme(
        cx: &mut gpui::TestAppContext,
    ) {
        cx.update(bind_keys);
        let text = "line\n".repeat(80) + "A👩‍💻";
        let (input, cx) = cx.add_window_view(|window, cx| {
            let input = TextInput::new_multiline(text, Rc::new(|_, _| {}), cx);
            input.focus_handle.focus(window);
            input
        });
        cx.simulate_keystrokes("ctrl-end backspace");
        cx.run_until_parked();
        cx.update(|_, cx| {
            let input = input.read(cx);
            assert_eq!(input.content.as_ref(), "line\n".repeat(80) + "A");
            assert!(input.scroll.offset().y < px(0.));
            assert_eq!(input.cursor_offset(), input.content.len());
        });
    }
}
