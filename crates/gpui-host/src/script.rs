//! Scripted interaction checks against a running GUI example.
//!
//! The maintained semantic specs run the engine without a presentation layer, so
//! they cannot see a control that GPUI laid out beyond the window, a dialog that
//! does not fit, or a native editor that kept the previous document's history.
//! `--smoke` covered the opposite extreme: one window, one click, one assertion.
//!
//! A script sits between them. It names controls the way the application names
//! them — by `test_id`, or by the label a person would read — and never by pixel
//! coordinates, so the checks survive layout work. Each step runs against the
//! real window with the real key dispatch, engine propagation and dialog
//! admission rules, and every observation is written to a JSON report so a
//! failure leaves evidence behind instead of only an exit code.
//!
//! Presentation assertions (`expect-onscreen`) are deliberately a different
//! vocabulary from the native semantic assertions in `examples-gui/*/specs`:
//! this file must not grow into a second, weaker copy of the spec language.

use crate::probe;
use std::fmt::Write as _;

/// How a step names the control it acts on.
#[derive(Clone, Debug, PartialEq)]
pub(crate) enum Locator {
    /// The application's own `test_id`, written `#identifier`.
    TestId(String),
    /// Visible text, on the control itself or on one of its children.
    Text(String),
}

impl Locator {
    fn parse(word: &str) -> Self {
        match word.strip_prefix('#') {
            Some(id) => Locator::TestId(id.to_string()),
            None => Locator::Text(word.to_string()),
        }
    }

    /// How this locator should be named in a failure message.
    pub(crate) fn describe(&self) -> String {
        match self {
            Locator::TestId(id) => format!("#{id}"),
            Locator::Text(text) => format!("{text:?}"),
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
    /// Require some rendered control to carry exactly this text.
    ExpectText(String),
    /// Require no rendered control to carry this text.
    ExpectMissing(String),
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
}

/// A parsed step, keeping its source line so a failure can be located.
#[derive(Clone, Debug)]
pub(crate) struct Step {
    pub(crate) line: usize,
    pub(crate) action: Action,
}

/// Parses a script: one step per line, `#` comments and blank lines ignored.
///
/// Arguments are separated by whitespace except for the trailing text of `type`,
/// `expect-text`, `expect-missing` and `expect-value`, which is taken verbatim to
/// the end of the line so that labels containing spaces need no quoting.
pub(crate) fn parse(source: &str) -> Result<Vec<Step>, String> {
    let mut steps = Vec::new();
    for (index, raw) in source.lines().enumerate() {
        let line = index + 1;
        let text = raw.trim();
        if text.is_empty() || text.starts_with('#') {
            continue;
        }
        let (verb, rest) = match text.split_once(char::is_whitespace) {
            Some((verb, rest)) => (verb, rest.trim()),
            None => (text, ""),
        };
        let action = parse_action(verb, rest).map_err(|error| format!("line {line}: {error}"))?;
        steps.push(Step { line, action });
    }
    if steps.is_empty() {
        return Err("a script must contain at least one step".into());
    }
    Ok(steps)
}

/// Splits a locator off the front of a step's arguments.
///
/// A visible label is usually several words ("Move to In progress"), so a
/// locator may be quoted. Unquoted locators stop at the first space, which
/// keeps the common `#test-id` case free of punctuation.
fn split_locator(rest: &str) -> Result<(Locator, &str), String> {
    if let Some(quoted) = rest.strip_prefix('"') {
        let (label, tail) = quoted
            .split_once('"')
            .ok_or("a quoted locator needs a closing quote")?;
        if label.is_empty() {
            return Err("expected a #test-id or a visible label".into());
        }
        return Ok((Locator::Text(label.to_string()), tail.trim()));
    }
    let (word, tail) = match rest.split_once(char::is_whitespace) {
        Some((word, tail)) => (word, tail.trim()),
        None => (rest, ""),
    };
    if word.is_empty() {
        return Err("expected a #test-id or a visible label".into());
    }
    Ok((Locator::parse(word), tail))
}

fn parse_action(verb: &str, rest: &str) -> Result<Action, String> {
    match verb {
        "wait" => rest
            .parse()
            .map(Action::Wait)
            .map_err(|_| format!("wait expects milliseconds, got {rest:?}")),
        "click" => Ok(Action::Click(split_locator(rest)?.0)),
        "focus" => Ok(Action::Focus(split_locator(rest)?.0)),
        "key" => (!rest.is_empty())
            .then(|| Action::Key(rest.to_string()))
            .ok_or_else(|| "key expects a keystroke".into()),
        "type" => {
            let (locator, text) = split_locator(rest)?;
            Ok(Action::Type(locator, text.to_string()))
        }
        "expect-text" => Ok(Action::ExpectText(rest.to_string())),
        "expect-missing" => Ok(Action::ExpectMissing(rest.to_string())),
        "expect-value" => {
            let (locator, value) = split_locator(rest)?;
            Ok(Action::ExpectValue(locator, value.to_string()))
        }
        "expect-disabled" => Ok(Action::ExpectDisabled(split_locator(rest)?.0, true)),
        "expect-enabled" => Ok(Action::ExpectDisabled(split_locator(rest)?.0, false)),
        "expect-selected" => Ok(Action::ExpectSelected(split_locator(rest)?.0, true)),
        "expect-unselected" => Ok(Action::ExpectSelected(split_locator(rest)?.0, false)),
        "expect-focused" => Ok(Action::ExpectFocused(split_locator(rest)?.0)),
        "expect-count" => {
            let (prefix, count) = rest
                .rsplit_once(char::is_whitespace)
                .ok_or("expect-count expects a test-id prefix and a count")?;
            let count = count
                .trim()
                .parse()
                .map_err(|_| format!("expect-count expects a count, got {count:?}"))?;
            Ok(Action::ExpectCount(
                prefix.trim().trim_start_matches('#').to_string(),
                count,
            ))
        }
        "expect-onscreen" => Ok(Action::ExpectOnscreen(split_locator(rest)?.0)),
        "expect-history" => {
            let (locator, depth) = split_locator(rest)?;
            let depth = depth
                .parse()
                .map_err(|_| format!("expect-history expects a count, got {depth:?}"))?;
            Ok(Action::ExpectHistory(locator, depth))
        }
        "snapshot" => (!rest.is_empty())
            .then(|| Action::Snapshot(rest.to_string()))
            .ok_or_else(|| "snapshot expects a name".into()),
        other => Err(format!("unknown step {other:?}")),
    }
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
            "{} matches {} rendered controls; name one with a #test-id",
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
        Action::ExpectText(text) => frame
            .iter()
            .any(|control| control.text == *text || control.label == *text)
            .then_some(())
            .ok_or_else(|| format!("no rendered control shows {text:?}")),
        Action::ExpectMissing(text) => frame
            .iter()
            .all(|control| control.text != *text && control.label != *text)
            .then_some(())
            .ok_or_else(|| format!("{text:?} is still rendered")),
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
pub(crate) fn report_json(
    name: &str,
    size: (f32, f32),
    snapshots: &[(String, String)],
    failure: Option<&str>,
) -> String {
    let mut out = String::from("{\"script\":");
    escape(name, &mut out);
    let _ = write!(
        out,
        ",\"window\":[{:.0},{:.0}],\"passed\":{}",
        size.0,
        size.1,
        failure.is_none()
    );
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

    #[test]
    fn a_script_parses_actions_assertions_and_comments() {
        let steps = parse(
            "# open the board\nclick #add-task\nwait 200\ntype #task-title A new task\n\
             expect-value #task-title A new task\nexpect-count card- 4\nsnapshot populated\n",
        )
        .expect("valid script");
        let actions: Vec<_> = steps.into_iter().map(|step| step.action).collect();
        assert_eq!(
            actions,
            vec![
                Action::Click(Locator::TestId("add-task".into())),
                Action::Wait(200),
                Action::Type(Locator::TestId("task-title".into()), "A new task".into()),
                Action::ExpectValue(Locator::TestId("task-title".into()), "A new task".into()),
                Action::ExpectCount("card-".into(), 4),
                Action::Snapshot("populated".into()),
            ]
        );
    }

    #[test]
    fn a_quoted_locator_carries_a_label_containing_spaces() {
        let steps = parse("click \"Move to In progress\"\nexpect-value \"Task notes\" a b\n")
            .expect("valid script");
        assert_eq!(
            steps[0].action,
            Action::Click(Locator::Text("Move to In progress".into()))
        );
        assert_eq!(
            steps[1].action,
            Action::ExpectValue(Locator::Text("Task notes".into()), "a b".into())
        );
        assert!(parse("click \"unterminated").unwrap_err().contains("closing quote"));
    }

    #[test]
    fn an_unusable_script_is_rejected_with_its_line() {
        assert!(parse("click #ok\nwiggle #ok\n").unwrap_err().contains("line 2"));
        assert!(parse("wait soon").unwrap_err().contains("milliseconds"));
        assert!(parse("# only a comment\n").is_err());
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
        assert!(check(&frame, &Action::ExpectText("Save".into())).is_ok());
        assert!(check(&frame, &Action::ExpectMissing("Save".into())).is_err());
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
        let report = report_json("notes", (360., 240.), &[("initial".into(), json)], Some("boom"));
        assert!(report.contains(r#""passed":false"#), "{report}");
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
