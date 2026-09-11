//! Window scenarios: spec steps executed against a running GUI example.
//!
//! The maintained semantic specs run the engine without a presentation layer, so
//! they cannot see a control that GPUI laid out beyond the window, a dialog that
//! does not fit, or a native editor that kept the previous document's history.
//! `--host-smoke` covered the opposite extreme: one window, one click, one assertion.
//!
//! A `(scenario ...)` sits between them. It is written in the same spec language
//! as every `(test ...)`, parsed by the same engine parser, and names controls
//! the way the application names them — by `test_id`, or by the label a person
//! would read — never by pixel coordinates, so the checks survive layout work.
//! Each step runs against the real window with the real key dispatch, engine
//! propagation and dialog admission rules, and every observation is written to
//! a JSON report so a failure leaves evidence behind instead of only an exit code.
//!
//! This module owns no grammar. It decodes the engine's parsed commands into
//! window actions, refuses the ones a window cannot honour, and keeps the
//! presentation-only vocabulary (`expect-onscreen`, `expect-history`, `close`)
//! that the display-free runner refuses in turn.

use crate::bridge::{Arg, Command, Scenario};
use crate::probe;
use std::fmt::Write as _;

/// How a step names the control it acts on.
///
/// The spec language's four locator forms collapse to two questions a rendered
/// frame can answer: a `(test-id ...)` names one control exactly, and a
/// `(role ... :name ...)`, `(label ...)` or `(text ...)` names it by the text a
/// person reads — which the resolver then narrows by what the step is about.
#[derive(Clone, Debug, PartialEq)]
pub(crate) enum Locator {
    /// The application's own `test_id`.
    TestId(String),
    /// Visible text, on the control itself or on one of its children.
    Text(String),
}

impl Locator {
    /// How this locator should be named in a failure message.
    pub(crate) fn describe(&self) -> String {
        match self {
            Locator::TestId(id) => format!("(test-id {id:?})"),
            Locator::Text(text) => format!("{text:?}"),
        }
    }

    fn decode(command: &Command) -> Result<Self, String> {
        match command.locator_kind.as_str() {
            "test_id" => Ok(Locator::TestId(command.test_id.clone())),
            "role_name" => Ok(Locator::Text(command.name.clone())),
            "label" => Ok(Locator::Text(command.label.clone())),
            "text" => Ok(Locator::Text(command.text.clone())),
            other => Err(format!("{} needs a locator, got {other}", command.kind)),
        }
    }
}

/// One scripted action or assertion.
#[derive(Clone, Debug, PartialEq)]
pub(crate) enum Action {
    /// Let timers, tasks and propagation settle for a number of milliseconds.
    Wait(u64),
    /// Activate a control through the same admission rules a real click uses.
    Click(Locator),
    /// Move keyboard focus to a control's focus target.
    Focus(Locator),
    /// Focus an editor and type text through the real key dispatch path.
    Type(Locator, String),
    /// Dispatch one keystroke, written the way GPUI writes bindings.
    Key(String),
    /// Require a control to be rendered.
    ExpectVisible(Locator),
    /// Require no rendered control to answer to a locator.
    ExpectAbsent(Locator),
    /// Require a control to carry exactly this text.
    ExpectText(Locator, String),
    /// Require an editor's current value.
    ExpectValue(Locator, String),
    /// Require a control to be present and disabled, or present and enabled.
    ExpectDisabled(Locator, bool),
    /// Require a control to be present and selected, or present and unselected.
    ExpectSelected(Locator, bool),
    /// Require a control to hold keyboard focus.
    ExpectFocused(Locator),
    /// Require exactly this many rendered controls whose test id has a prefix.
    ExpectCount(String, usize),
    /// Require a control to be laid out wholly inside the window.
    ExpectOnscreen(Locator),
    /// Require an editor to be holding exactly this many native undo entries.
    ExpectHistory(Locator, usize),
    /// Record the rendered tree under a name, for evidence rather than assertion.
    Snapshot(String),
    /// Close the window through the platform's ordinary close path.
    Close,
}

/// A decoded step, keeping its source line so a failure can be located.
#[derive(Clone, Debug)]
pub(crate) struct Step {
    pub(crate) line: usize,
    pub(crate) action: Action,
}

/// Decodes every step of a parsed scenario, refusing any the window cannot honour.
///
/// The parser has already kept fixtures and pre-mount setup out of a scenario.
/// What is refused here is the display-free vocabulary that has no window
/// meaning — `fill` sets a value without the keyboard, pointer phases and
/// composition are simulated-DOM events — with the window step to use instead.
pub(crate) fn steps(scenario: &Scenario) -> Result<Vec<Step>, String> {
    scenario
        .commands
        .iter()
        .map(|command| {
            decode(command)
                .map(|action| Step {
                    line: command.line as usize,
                    action,
                })
                .map_err(|error| format!("line {}: {error}", command.line))
        })
        .collect()
}

fn decode(command: &Command) -> Result<Action, String> {
    let locator = || Locator::decode(command);
    let text = |name: &str| match command.arg(name) {
        Some(Arg::Text(value)) => Ok(value.clone()),
        _ => Err(format!("{} needs a text argument {name}", command.kind)),
    };
    let count = |name: &str| match command.arg(name) {
        Some(Arg::Unsigned(value)) => Ok(*value as usize),
        _ => Err(format!("{} needs a count argument {name}", command.kind)),
    };
    let flag = |name: &str| match command.arg(name) {
        Some(Arg::Boolean(value)) => Ok(*value),
        _ => Err(format!("{} needs true or false for {name}", command.kind)),
    };
    Ok(match command.kind.as_str() {
        "wait" => Action::Wait(count("value")? as u64),
        "click" => Action::Click(locator()?),
        "focus" => Action::Focus(locator()?),
        "type_text" => Action::Type(locator()?, text("text")?),
        "key" => Action::Key(text("value")?),
        "shortcut" => Action::Key(chord_keystroke((
            count("key")? as u32,
            count("modifiers")? as u32,
        ))?),
        "expect_visible" => Action::ExpectVisible(locator()?),
        "expect_absent" => Action::ExpectAbsent(locator()?),
        "expect_text" => Action::ExpectText(locator()?, text("text")?),
        "expect_value" => Action::ExpectValue(locator()?, text("text")?),
        "expect_disabled" => Action::ExpectDisabled(locator()?, flag("expected")?),
        "expect_selected" => Action::ExpectSelected(locator()?, flag("expected")?),
        "expect_focused" => Action::ExpectFocused(locator()?),
        "expect_count" => Action::ExpectCount(text("prefix")?, count("count")?),
        "expect_onscreen" => Action::ExpectOnscreen(locator()?),
        "expect_history" => Action::ExpectHistory(locator()?, count("count")?),
        "snapshot" => Action::Snapshot(text("value")?),
        "close" => Action::Close,
        "fill" => return Err("fill sets a value without the keyboard; a window scenario types with (type ...)".into()),
        "real_click" => return Err("real_click is the simulated pointer; a window scenario uses (click ...)".into()),
        other => {
            return Err(format!(
                "{other} has no meaning against a real window; it belongs in a (test ...)"
            ))
        }
    })
}

/// Spells an engine key chord the way GPUI writes a binding, so a spec's
/// `(shortcut ...)` dispatches the same keystroke a person's chord would.
fn chord_keystroke((key, modifiers): (u32, u32)) -> Result<String, String> {
    const NAMED: [&str; 26] = [
        "enter", "escape", "tab", "space", "left", "right", "up", "down", "home", "end",
        "pageup", "pagedown", "backspace", "delete", "f1", "f2", "f3", "f4", "f5", "f6", "f7",
        "f8", "f9", "f10", "f11", "f12",
    ];
    let key = if key >= 256 {
        NAMED
            .get((key - 256) as usize)
            .map(|name| name.to_string())
            .ok_or_else(|| format!("unknown named key {key}"))?
    } else {
        char::from_u32(key)
            .filter(|c| c.is_ascii_lowercase() || c.is_ascii_digit())
            .map(|c| c.to_string())
            .ok_or_else(|| format!("unknown key {key}"))?
    };
    let mut spelled = String::new();
    for (bit, name) in [(1, "ctrl-"), (2, "shift-"), (4, "alt-"), (8, "cmd-")] {
        if modifiers & bit != 0 {
            spelled.push_str(name);
        }
    }
    spelled.push_str(&key);
    Ok(spelled)
}

/// The observation a `Locator` needs from the rendered tree.
///
/// The executor collects this once per step so that assertions, reporting and
/// failure evidence all describe the same frame rather than re-reading a tree
/// that a listener may have changed in between.
#[derive(Clone, Debug, Default, PartialEq)]
pub(crate) struct Control {
    pub(crate) id: u64,
    pub(crate) test_id: String,
    pub(crate) kind: String,
    pub(crate) text: String,
    pub(crate) value: String,
    pub(crate) label: String,
    pub(crate) child_text: Vec<String>,
    pub(crate) disabled: bool,
    pub(crate) selected: bool,
    pub(crate) focused: bool,
    /// Whether a click on this control would activate an application binding.
    pub(crate) activatable: bool,
    /// Native undo entries held by this control's editor, if it has one.
    pub(crate) history: Option<usize>,
}

impl Control {
    /// Whether this control carries the name itself, rather than through a child.
    fn matches_directly(&self, text: &str) -> bool {
        self.text == text || self.label == text
    }

    fn matches(&self, locator: &Locator) -> bool {
        match locator {
            Locator::TestId(id) => self.test_id == *id,
            // A control's own text or label names it. A child's text names it
            // only when the control is the thing that acts on a click: that is
            // how a button whose caption is a separate text node gets its
            // readable name, and it keeps a container that merely encloses the
            // button from answering to the button's label.
            Locator::Text(text) => {
                self.matches_directly(text)
                    || (self.activatable && self.child_text.iter().any(|child| child == text))
            }
        }
    }
}

/// Resolves a locator against a frame, refusing an ambiguous match.
///
/// Two controls answering to the same name means the assertion that follows
/// would silently be about whichever one iteration happened to reach first, so
/// this is an error in the script rather than a coin toss at runtime.
pub(crate) fn resolve<'a>(frame: &'a [Control], locator: &Locator) -> Result<&'a Control, String> {
    let candidates: Vec<&Control> = frame.iter().collect();
    resolve_within(&candidates, locator)
        .unwrap_or_else(|| Err(format!("no rendered control matches {}", locator.describe())))
}

/// Resolves a locator for a click, preferring the control that would act on it.
///
/// A button's readable label is usually a child text node, so the label names
/// both. Preferring the activatable control keeps scripts written the way a
/// person describes the interface — "click Save" — without making every button
/// in every example carry a test id purely for the harness.
pub(crate) fn resolve_activatable<'a>(
    frame: &'a [Control],
    locator: &Locator,
) -> Result<&'a Control, String> {
    let activatable: Vec<&Control> = frame
        .iter()
        .filter(|control| control.activatable)
        .collect();
    match resolve_within(&activatable, locator) {
        Some(found) => found,
        None => Err(format!(
            "no activatable control matches {}",
            locator.describe()
        )),
    }
}

/// Resolves a locator among the controls a kind of assertion is really about.
///
/// A button's label names both the button and the text node inside it, and an
/// editor's caption names both the caption and the field. Narrowing to the
/// controls that can answer the assertion resolves that without asking every
/// example to carry a test id for the harness's benefit; when narrowing does
/// not decide it, the whole frame decides, so genuine ambiguity is still an
/// error rather than a preference.
pub(crate) fn resolve_preferring<'a>(
    frame: &'a [Control],
    locator: &Locator,
    interesting: impl Fn(&Control) -> bool,
) -> Result<&'a Control, String> {
    let narrowed: Vec<&Control> = frame.iter().filter(|c| interesting(c)).collect();
    match resolve_within(&narrowed, locator) {
        Some(found) => found,
        None => resolve(frame, locator),
    }
}

/// Resolves within a candidate set, or `None` when nothing there matched.
fn resolve_within<'a>(
    candidates: &[&'a Control],
    locator: &Locator,
) -> Option<Result<&'a Control, String>> {
    let matched: Vec<&&'a Control> = candidates
        .iter()
        .filter(|control| control.matches(locator))
        .collect();
    if matched.is_empty() {
        return None;
    }
    // A control that carries the name itself outranks a container that only
    // encloses something carrying it. Without that rule every toolbar answers
    // to every button inside it, and a script would have to name a test id for
    // controls that are already unambiguous to a reader.
    let direct: Vec<&&'a Control> = match locator {
        Locator::Text(text) => matched
            .iter()
            .copied()
            .filter(|control| control.matches_directly(text))
            .collect(),
        Locator::TestId(_) => matched.clone(),
    };
    let preferred = if direct.is_empty() { &matched } else { &direct };
    Some(match preferred.as_slice() {
        [only] => Ok(**only),
        several => Err(format!(
            "{} matches {} rendered controls; name one with (test-id ...)",
            locator.describe(),
            several.len()
        )),
    })
}

/// Whether a control can answer a question about state a person can act on.
fn interactive(control: &Control) -> bool {
    control.activatable || control.history.is_some()
}

/// Checks one assertion against a frame, returning the reason it failed.
///
/// Actions that change the application are not handled here: this function is
/// pure so that the assertion vocabulary can be tested without a window.
pub(crate) fn check(frame: &[Control], action: &Action) -> Result<(), String> {
    match action {
        // Visibility asks whether anything answers to the name; two controls
        // answering is still visible, so this is the one locator use that is
        // not an ambiguity error.
        Action::ExpectVisible(locator) => frame
            .iter()
            .any(|control| control.matches(locator))
            .then_some(())
            .ok_or_else(|| format!("no rendered control matches {}", locator.describe())),
        Action::ExpectAbsent(locator) => frame
            .iter()
            .all(|control| !control.matches(locator))
            .then_some(())
            .ok_or_else(|| format!("{} is still rendered", locator.describe())),
        Action::ExpectText(locator, text) => {
            let control = resolve(frame, locator)?;
            let shown = if control.text.is_empty() {
                control.child_text.join("")
            } else {
                control.text.clone()
            };
            (shown == *text || control.label == *text)
                .then_some(())
                .ok_or_else(|| {
                    format!("{} shows {shown:?}, expected {text:?}", locator.describe())
                })
        }
        Action::ExpectValue(locator, value) => {
            let control = resolve_preferring(frame, locator, |c| c.history.is_some())?;
            (control.value == *value).then_some(()).ok_or_else(|| {
                format!(
                    "{} holds {:?}, expected {value:?}",
                    locator.describe(),
                    control.value
                )
            })
        }
        Action::ExpectDisabled(locator, want) => {
            let control = resolve_preferring(frame, locator, interactive)?;
            (control.disabled == *want).then_some(()).ok_or_else(|| {
                format!(
                    "{} is {}",
                    locator.describe(),
                    if control.disabled { "disabled" } else { "enabled" }
                )
            })
        }
        Action::ExpectSelected(locator, want) => {
            let control = resolve_preferring(frame, locator, interactive)?;
            (control.selected == *want).then_some(()).ok_or_else(|| {
                format!(
                    "{} is {}",
                    locator.describe(),
                    if control.selected { "selected" } else { "unselected" }
                )
            })
        }
        Action::ExpectFocused(locator) => {
            let control = resolve_preferring(frame, locator, interactive)?;
            control.focused.then_some(()).ok_or_else(|| {
                let focused = frame
                    .iter()
                    .find(|control| control.focused)
                    .map(|control| control.test_id.clone())
                    .unwrap_or_else(|| "nothing".into());
                format!(
                    "{} does not hold focus; {focused} does",
                    locator.describe()
                )
            })
        }
        Action::ExpectCount(prefix, want) => {
            let found = frame
                .iter()
                .filter(|control| control.test_id.starts_with(prefix.as_str()))
                .count();
            (found == *want).then_some(()).ok_or_else(|| {
                format!("{found} controls have test ids starting {prefix:?}, expected {want}")
            })
        }
        Action::ExpectHistory(locator, want) => {
            let control = resolve_preferring(frame, locator, |c| c.history.is_some())?;
            let held = control
                .history
                .ok_or_else(|| format!("{} is not an editor", locator.describe()))?;
            (held == *want).then_some(()).ok_or_else(|| {
                format!(
                    "{} holds {held} native undo entries, expected {want}",
                    locator.describe()
                )
            })
        }
        Action::ExpectOnscreen(locator) => {
            let control = resolve(frame, locator)?;
            if control.test_id.is_empty() {
                return Err(format!(
                    "{} has no test id, so its bounds are not recorded",
                    locator.describe()
                ));
            }
            let viewport = probe::viewport().ok_or("the window has not been laid out yet")?;
            let bounds = probe::bounds(&control.test_id).ok_or_else(|| {
                format!(
                    "{} was not laid out in the last frame",
                    locator.describe()
                )
            })?;
            if bounds.is_empty() {
                return Err(format!("{} was laid out with no area", locator.describe()));
            }
            bounds.inside(viewport).then_some(()).ok_or_else(|| {
                format!(
                    "{} is laid out at ({:.0},{:.0})-({:.0},{:.0}), outside the \
                     {:.0}x{:.0} window",
                    locator.describe(),
                    bounds.left,
                    bounds.top,
                    bounds.right,
                    bounds.bottom,
                    viewport.right,
                    viewport.bottom,
                )
            })
        }
        _ => Ok(()),
    }
}

fn escape(value: &str, into: &mut String) {
    into.push('"');
    for character in value.chars() {
        match character {
            '"' => into.push_str("\\\""),
            '\\' => into.push_str("\\\\"),
            '\n' => into.push_str("\\n"),
            '\r' => into.push_str("\\r"),
            '\t' => into.push_str("\\t"),
            control if (control as u32) < 0x20 => {
                let _ = write!(into, "\\u{:04x}", control as u32);
            }
            other => into.push(other),
        }
    }
    into.push('"');
}

/// Renders a frame as the JSON evidence a failing run leaves behind.
///
/// The report is written whether the run passed or failed, because the frame a
/// passing run observed is what makes a later regression legible.
pub(crate) fn frame_json(frame: &[Control]) -> String {
    let mut out = String::from("[");
    for (index, control) in frame.iter().enumerate() {
        if index > 0 {
            out.push(',');
        }
        out.push_str("{\"id\":");
        let _ = write!(out, "{}", control.id);
        out.push_str(",\"test_id\":");
        escape(&control.test_id, &mut out);
        out.push_str(",\"kind\":");
        escape(&control.kind, &mut out);
        out.push_str(",\"text\":");
        escape(&control.text, &mut out);
        out.push_str(",\"label\":");
        escape(&control.label, &mut out);
        out.push_str(",\"value\":");
        escape(&control.value, &mut out);
        out.push_str(",\"child_text\":[");
        for (rank, child) in control.child_text.iter().enumerate() {
            if rank > 0 {
                out.push(',');
            }
            escape(child, &mut out);
        }
        out.push(']');
        let _ = write!(
            out,
            ",\"disabled\":{},\"selected\":{},\"focused\":{}",
            control.disabled, control.selected, control.focused
        );
        if let Some(history) = control.history {
            let _ = write!(out, ",\"history\":{history}");
        }
        if let Some(bounds) = probe::bounds(&control.test_id) {
            let _ = write!(
                out,
                ",\"bounds\":[{:.1},{:.1},{:.1},{:.1}]",
                bounds.left, bounds.top, bounds.right, bounds.bottom
            );
        }
        out.push('}');
    }
    out.push(']');
    out
}

/// Renders the whole run — steps, snapshots and any failure — as one report.
/// Serializes a run's evidence. `client_frame` records whether the host drew
/// its own window frame inside the window: a compositor that delegates
/// decorations leaves the application less room than one that does not, so a
/// layout finding can depend on it, and the driver needs to know which it saw.
pub(crate) fn report_json(
    name: &str,
    size: (f32, f32),
    client_frame: bool,
    diagnostic: Option<&str>,
    scopes: &[String],
    snapshots: &[(String, String)],
    failure: Option<&str>,
) -> String {
    let mut out = String::from("{\"scenario\":");
    escape(name, &mut out);
    let _ = write!(
        out,
        ",\"window\":[{:.0},{:.0}],\"frame\":\"{}\",\"passed\":{}",
        size.0,
        size.1,
        if client_frame { "client" } else { "server" },
        failure.is_none()
    );
    // The header's own words travel with the evidence, so the driver judges a
    // documented defect from the report alone rather than by parsing the spec
    // a second time.
    if let Some(diagnostic) = diagnostic {
        out.push_str(",\"diagnostic\":");
        escape(diagnostic, &mut out);
        out.push_str(",\"diagnostic_on\":[");
        for (index, scope) in scopes.iter().enumerate() {
            if index > 0 {
                out.push(',');
            }
            escape(scope, &mut out);
        }
        out.push(']');
    }
    if let Some(failure) = failure {
        out.push_str(",\"failure\":");
        escape(failure, &mut out);
    }
    out.push_str(",\"snapshots\":{");
    for (index, (snapshot, frame)) in snapshots.iter().enumerate() {
        if index > 0 {
            out.push(',');
        }
        escape(snapshot, &mut out);
        out.push(':');
        out.push_str(frame);
    }
    out.push_str("}}");
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn control(test_id: &str, text: &str) -> Control {
        Control {
            test_id: test_id.into(),
            text: text.into(),
            kind: "button".into(),
            activatable: true,
            ..Control::default()
        }
    }

    fn command(kind: &str) -> Command {
        Command {
            kind: kind.into(),
            line: 7,
            locator_kind: "none".into(),
            role: String::new(),
            name: String::new(),
            label: String::new(),
            text: String::new(),
            test_id: String::new(),
            args: Vec::new(),
        }
    }

    fn with(mut command: Command, name: &str, value: Arg) -> Command {
        command.args.push((name.into(), value));
        command
    }

    #[test]
    fn engine_commands_decode_into_window_actions_by_name() {
        let mut click = command("click");
        click.locator_kind = "role_name".into();
        click.role = "button".into();
        click.name = "Add task".into();
        assert_eq!(decode(&click).unwrap(), Action::Click(Locator::Text("Add task".into())));
        let mut typed = command("type_text");
        typed.locator_kind = "label".into();
        typed.label = "Task title".into();
        let typed = with(typed, "text", Arg::Text("A new task".into()));
        assert_eq!(
            decode(&typed).unwrap(),
            Action::Type(Locator::Text("Task title".into()), "A new task".into())
        );
        let wait = with(command("wait"), "value", Arg::Unsigned(200));
        assert_eq!(decode(&wait).unwrap(), Action::Wait(200));
        let count = with(
            with(command("expect_count"), "prefix", Arg::Text("card-".into())),
            "count",
            Arg::Unsigned(4),
        );
        assert_eq!(decode(&count).unwrap(), Action::ExpectCount("card-".into(), 4));
        let mut onscreen = command("expect_onscreen");
        onscreen.locator_kind = "test_id".into();
        onscreen.test_id = "task-detail".into();
        assert_eq!(
            decode(&onscreen).unwrap(),
            Action::ExpectOnscreen(Locator::TestId("task-detail".into()))
        );
        assert_eq!(decode(&command("close")).unwrap(), Action::Close);
    }

    /// The window-step vocabulary and arguments the engine publishes, as
    /// `test/spec-steps.json` records them from the Zig union by reflection.
    /// Reading the file here ties the argument names this decoder asks for to
    /// the names the engine emits: a renamed tag or payload field fails here
    /// rather than at run time as a step with no meaning.
    fn published_steps() -> Vec<(String, Vec<(String, String)>)> {
        let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../test/spec-steps.json");
        let text = std::fs::read_to_string(&path)
            .unwrap_or_else(|error| panic!("cannot read {}: {error}", path.display()));
        // One line per step: `kind name:type name:type ...`.
        text.lines()
            .filter(|line| !line.is_empty())
            .map(|line| {
                let mut words = line.split(' ');
                let kind = words.next().unwrap().to_string();
                let args = words
                    .map(|word| {
                        let (name, arg_type) = word.split_once(':').unwrap();
                        (name.to_string(), arg_type.to_string())
                    })
                    .collect();
                (kind, args)
            })
            .collect()
    }

    #[test]
    fn every_published_window_step_decodes_with_the_arguments_the_engine_emits() {
        let steps = published_steps();
        assert!(steps.len() >= 18, "{steps:?}");
        for (kind, args) in steps {
            let mut generic = command(&kind);
            generic.locator_kind = "test_id".into();
            generic.test_id = "x".into();
            for (name, arg_type) in args {
                let value = match arg_type.as_str() {
                    "text" => Arg::Text("x".into()),
                    "unsigned" => Arg::Unsigned(115),
                    "signed" => Arg::Signed(1),
                    "boolean" => Arg::Boolean(true),
                    other => panic!("unknown argument type {other}"),
                };
                generic = with(generic, &name, value);
            }
            let outcome = decode(&generic);
            assert!(outcome.is_ok(), "{kind} is published by the engine but does not decode here: {outcome:?}");
        }
    }

    #[test]
    fn a_spec_shortcut_becomes_the_keystroke_a_person_would_press() {
        let shortcut = with(
            with(command("shortcut"), "key", Arg::Unsigned('s' as u64)),
            "modifiers",
            Arg::Unsigned(1 | 2),
        );
        assert_eq!(decode(&shortcut).unwrap(), Action::Key("ctrl-shift-s".into()));
        assert_eq!(chord_keystroke((256, 0)).unwrap(), "enter");
        assert_eq!(chord_keystroke((256 + 4, 8)).unwrap(), "cmd-left");
        assert!(chord_keystroke((999, 0)).is_err());
    }

    #[test]
    fn display_free_steps_are_refused_with_the_window_step_to_use() {
        let mut fill = command("fill");
        fill.locator_kind = "label".into();
        let error = decode(&fill).unwrap_err();
        assert!(error.contains("(type ...)"), "{error}");
        assert!(decode(&command("tick_interval")).unwrap_err().contains("(test ...)"));
        assert!(decode(&command("wait")).is_err());
        let scenario = Scenario {
            name: "s".into(),
            window: None,
            assets: None,
            choices: vec![],
            diagnostic: None,
            scopes: vec![],
            commands: vec![command("mark_metrics")],
        };
        let error = steps(&scenario).unwrap_err();
        assert!(error.starts_with("line 7:"), "{error}");
    }

    #[test]
    fn a_locator_naming_two_controls_is_an_error_not_a_guess() {
        let frame = vec![control("first", "Delete"), control("second", "Delete")];
        let error = resolve(&frame, &Locator::Text("Delete".into())).unwrap_err();
        assert!(error.contains("2 rendered controls"), "{error}");
        assert_eq!(
            resolve(&frame, &Locator::TestId("second".into())).unwrap().test_id,
            "second"
        );
    }

    #[test]
    fn assertions_fail_with_what_was_observed() {
        let mut frame = vec![control("save", "Save"), control("delete", "Delete")];
        frame[0].disabled = true;
        assert!(check(&frame, &Action::ExpectVisible(Locator::Text("Save".into()))).is_ok());
        assert!(check(&frame, &Action::ExpectAbsent(Locator::Text("Save".into()))).is_err());
        assert!(check(&frame, &Action::ExpectAbsent(Locator::Text("Gone".into()))).is_ok());
        assert!(check(&frame, &Action::ExpectText(Locator::TestId("save".into()), "Save".into())).is_ok());
        let error = check(&frame, &Action::ExpectText(Locator::TestId("save".into()), "Saved".into()))
            .unwrap_err();
        assert!(error.contains("shows \"Save\""), "{error}");
        assert!(check(&frame, &Action::ExpectDisabled(Locator::TestId("save".into()), true)).is_ok());
        let error =
            check(&frame, &Action::ExpectDisabled(Locator::TestId("delete".into()), true))
                .unwrap_err();
        assert!(error.contains("enabled"), "{error}");
        let error = check(&frame, &Action::ExpectCount("card-".into(), 2)).unwrap_err();
        assert!(error.contains("expected 2"), "{error}");
    }

    #[test]
    fn a_focus_failure_names_what_holds_focus_instead() {
        let mut frame = vec![control("save", "Save"), control("delete", "Delete")];
        frame[1].focused = true;
        let error = check(&frame, &Action::ExpectFocused(Locator::TestId("save".into())))
            .unwrap_err();
        assert!(error.contains("delete does"), "{error}");
    }

    #[test]
    fn a_click_locator_prefers_the_button_over_its_own_label() {
        let mut label = control("save-label", "Save");
        label.activatable = false;
        let frame = vec![control("save", "Save"), label];
        assert!(resolve(&frame, &Locator::Text("Save".into())).is_err());
        assert_eq!(
            resolve_activatable(&frame, &Locator::Text("Save".into()))
                .unwrap()
                .test_id,
            "save"
        );
        let error = resolve_activatable(&frame, &Locator::Text("Delete".into())).unwrap_err();
        assert!(error.contains("no activatable control"), "{error}");
    }

    #[test]
    fn a_container_does_not_answer_to_the_label_of_a_button_inside_it() {
        let mut toolbar = control("toolbar", "");
        toolbar.child_text = vec!["Back".into(), "Forward".into()];
        let frame = vec![toolbar, control("back", "Back")];
        assert_eq!(
            resolve(&frame, &Locator::Text("Back".into())).unwrap().test_id,
            "back"
        );
    }

    #[test]
    fn a_state_assertion_prefers_the_control_the_state_belongs_to() {
        let mut label = control("save-label", "Save");
        label.activatable = false;
        let mut button = control("save", "Save");
        button.disabled = true;
        let frame = vec![button, label];
        assert!(check(&frame, &Action::ExpectDisabled(Locator::Text("Save".into()), true)).is_ok());
        let mut caption = control("body-caption", "Note text");
        caption.activatable = false;
        let mut field = control("body", "Note text");
        field.activatable = false;
        field.history = Some(2);
        field.value = "typed".into();
        let frame = vec![caption, field];
        assert!(
            check(&frame, &Action::ExpectValue(Locator::Text("Note text".into()), "typed".into()))
                .is_ok()
        );
        assert!(check(&frame, &Action::ExpectHistory(Locator::Text("Note text".into()), 2)).is_ok());
    }

    #[test]
    fn native_history_depth_is_asserted_per_editor() {
        let mut frame = vec![control("body", ""), control("title", "")];
        frame[0].history = Some(0);
        let body = Locator::TestId("body".into());
        assert!(check(&frame, &Action::ExpectHistory(body.clone(), 0)).is_ok());
        let error = check(&frame, &Action::ExpectHistory(body, 3)).unwrap_err();
        assert!(error.contains("holds 0 native undo"), "{error}");
        let error = check(&frame, &Action::ExpectHistory(Locator::TestId("title".into()), 0))
            .unwrap_err();
        assert!(error.contains("not an editor"), "{error}");
    }

    #[test]
    fn a_report_escapes_the_text_an_application_rendered() {
        let frame = vec![control("quote", "a \"quoted\" \\ line\n")];
        let json = frame_json(&frame);
        assert!(json.contains(r#""a \"quoted\" \\ line\n""#), "{json}");
        let report = report_json(
            "notes",
            (360., 240.),
            true,
            Some("GUI-35."),
            &["client-frame".into()],
            &[("initial".into(), json)],
            Some("boom"),
        );
        assert!(report.contains(r#""passed":false"#), "{report}");
        assert!(report.contains(r#""frame":"client""#), "{report}");
        assert!(report.contains(r#""diagnostic":"GUI-35.","diagnostic_on":["client-frame"]"#), "{report}");
        assert!(report.contains(r#""failure":"boom""#), "{report}");
        assert!(report.contains(r#""window":[360,240]"#), "{report}");
    }
}

impl Action {
    /// Whether performing this step can change what the next step observes.
    ///
    /// Recorded bounds are invalidated after a step so a reachability assertion
    /// is never answered by a layout that no longer exists. Only a step that can
    /// actually change the layout needs that: invalidating after an assertion
    /// too would leave the following assertion with nothing to read until a
    /// frame happened to arrive, so two `expect-onscreen` lines in a row could
    /// never both be answered.
    pub(crate) fn changes_layout(&self) -> bool {
        matches!(
            self,
            Action::Click(_) | Action::Focus(_) | Action::Type(..) | Action::Key(_)
        )
    }
}
