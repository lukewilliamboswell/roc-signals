app [main] { roc: "nightly-2026-09-04-c125b82", pf: platform "../../platform-gui/main.roc" }

import pf.Elem exposing [Elem]
import pf.Gui
import pf.Signal
import pf.Ui
import Feed
import Session
import Workflow

entry_view : Ui.Row(Feed.Entry), Ui.State(Str) -> Elem
entry_view = |row, selected| {
	key = row.key()
	Gui.row(
		[Gui.style({ ..Gui.style_default, height: Px(44), overflow_x: Clip, overflow_y: Clip }), Gui.test_id("event-${key}"), Gui.selected_s(Signal.select(selected.signal(), key))],
		[
			Gui.button("Inspect ${key}", selected.on_unit(|_| key)),
			Gui.text_s(row.signal().map(|entry| entry.severity.to_str())),
			Gui.text_s(row.signal().map(|entry| entry.component)),
			Gui.column([Gui.style({ ..Gui.style_default, grow: True, height: Fill, overflow_x: Clip, overflow_y: Clip })], [Gui.text_s(row.signal().map(|entry| entry.message))]),
		],
	)
}

## File position, partial line and accepted history commit as one app state.
## Search, selection and following remain independent interaction state.
main : () -> Elem
main = || Ui.state(
	{ session: Session.initial, history: Feed.empty },
	|model| Ui.state(False, |running| Ui.state("", |query| Ui.state(False, |errors_only| Ui.state("", |selected| Ui.state(True, |follow_tail| view(model, running, query, errors_only, selected, follow_tail)))))),
)

view : Ui.State(Session.Accepted), Ui.State(Bool), Ui.State(Str), Ui.State(Bool), Ui.State(Str), Ui.State(Bool) -> Elem
view = |model, running, query, errors_only, selected, follow_tail| {
	tasks = Workflow.create()
	history = model.signal().map(|value| value.history)
	session = model.signal().map(|value| value.session)
	replay = session.map(|state| state.source == Session.Source.Replay)
	busy : Signal.Signal(Bool)
	busy = session.map(
		|state| match state.phase {
			Session.Phase.Choosing => True
			Session.Phase.Reading(_) => True
			_ => False
		},
	)
	append = model.update_cmd(|value| { ..value, history: Feed.append(value.history) })
	projection = { history, query: query.signal(), errors: errors_only.signal() }.Signal
	visible = projection.map(|value| Feed.visible(value.history, value.query, value.errors))
	inspection = { history, selected: selected.signal() }.Signal
	Gui.column(
		[Gui.style({ ..Gui.style_default, padding: 24, gap: 16, width: Fill, height: Fill })],
		[
			Gui.heading("Activity Monitor"),
			Gui.text_s(
				session.map(
					|state| match state.source {
						Session.Source.Replay => "SIMULATED REPLAY · deterministic sample operations, not system telemetry"
						Session.Source.Log(file) => "PLAIN-TEXT LOG · ${file.path}"
					},
				),
			),
			Gui.row(
				[],
				[
					Gui.action_button(
						{ label: Signal.const("Open log…"), enabled: busy.map(|value| !value) },
						[],
						Ui.action(
							model.signal(),
							|value| Ui.update_states([
								model.write({ ..value, session: Session.choose(value.session) }),
								running.write(False),
								errors_only.write(False),
							]),
						),
					),
					Gui.action_button(
						{ label: Signal.const("Use simulated replay"), enabled: { busy, replay }.Signal.map(|value| !value.busy and !value.replay) },
						[],
						Ui.action(
							history,
							|current| Ui.update_states([
								model.write({ session: Session.initial, history: Feed.clear(current) }),
								running.write(False),
								errors_only.write(False),
							]),
						),
					),
					Gui.action_button({ label: Signal.const("Retry read"), enabled: session.map(|state| state.phase == Session.Phase.Paused and state.retry != None) }, [], model.on_unit(|value| { ..value, session: Session.retry_read(value.session) })),
					Gui.action_button({ label: Signal.const("Cancel operation"), enabled: busy }, [], Ui.action(session, |state| Workflow.cancel(model, tasks, state.phase))),
				],
			),
			Gui.column([Gui.test_id("activity-status")], [Gui.text_s(session.map(|state| state.notice))]),
			Ui.when(
				replay,
				|| Gui.row(
					[],
					[
						Gui.action_button(
							{
								label: running.signal().map(
									|active| if active {
										"Pause replay"
									} else {
										"Start replay"
									},
								),
								enabled: busy.map(|value| !value),
							},
							[],
							running.on_unit(|active| !active),
						),
						Gui.action_button({ label: Signal.const("Step replay"), enabled: busy.map(|value| !value) }, [], Ui.action(Signal.const({}), |_| append)),
					],
				),
				|| Gui.row(
					[],
					[
						Gui.action_button(
							{
								label: session.map(
									|state| if state.phase == Session.Phase.Paused {
										"Resume following"
									} else {
										"Pause following"
									},
								),
								enabled: Signal.const(True),
							},
							[],
							Ui.action(
								session,
								|state| if state.phase == Session.Phase.Paused {
									model.update_cmd(|value| { ..value, session: Session.read_next(value.session) })
								} else {
									Workflow.cancel(model, tasks, state.phase)
								},
							),
						),
					],
				),
			),
			Gui.row(
				[],
				[
					Gui.button("Clear history", model.on_unit(|value| { ..value, history: Feed.clear(value.history) })),
					Gui.text_s(history.map(|value| "Retained: ${value.rows.len().to_str()} / 1000")),
					Gui.text_s(history.map(|value| "Text: ${value.bytes.to_str()} / 4194304 bytes · Evicted: ${value.discarded.to_str()}")),
				],
			),
			Gui.row(
				[],
				[
					Gui.text_input({ label: "Filter activity", value: query.signal() }, [Gui.style({ ..Gui.style_default, width: Px(360) })], query.on_str(|_, value| value)),
					Gui.checkbox({ label: "Errors only", checked: errors_only.signal() }, [Gui.enabled_s(replay)], errors_only.on_bool(|_, value| value)),
					Gui.checkbox({ label: "Follow latest", checked: follow_tail.signal() }, [], follow_tail.on_bool(|_, value| value)),
				],
			),
			Ui.when(
				{ running: running.signal(), replay }.Signal.map(|value| value.running and value.replay),
				|| Ui.on_change(Signal.interval(500), |_| append),
				|| Gui.text_s(
					replay.map(
						|is_replay| if is_replay {
							"Replay paused"
						} else {
							""
						},
					),
				),
			),
			Gui.row(
				[Gui.style({ ..Gui.style_default, grow: True, width: Fill })],
				[
					Gui.column(
						[Gui.style({ ..Gui.style_default, grow: True })],
						[
							Ui.when(visible.map(|rows| rows.len() == 0), || Gui.text("No matching events. Start the replay, open a log, or adjust the filter."), || Gui.text("")),
							Gui.virtual_list({ row_height: 44, follow_tail: follow_tail.signal() }, [Gui.test_id("activity-list")], [Ui.each(visible, |row| entry_view(row, selected))]),
						],
					),
					Gui.panel(
						[Gui.style({ ..Gui.style_default, width: Px(360), padding: 16, height: Fill, overflow_x: Scroll, overflow_y: Scroll })],
						[
							Gui.heading("Event inspector"),
							Ui.when(
								session.map(|state| !state.lines.partial.is_empty()),
								|| Gui.column(
									[Gui.style({ ..Gui.style_default, height: Px(100), overflow_x: Scroll, overflow_y: Scroll })],
									[Gui.heading("Unterminated line"), Gui.text_s(session.map(|state| state.lines.partial))],
								),
								|| Gui.text(""),
							),
							Gui.text_s(
								inspection.map(
									|value| if value.selected.is_empty() {
										"Select an event to inspect its details."
									} else {
										match value.history.rows.get_key(value.selected) {
											Ok(entry) => "Event ${entry.id.to_str()} · ${entry.severity.to_str()} · ${entry.component} · ${entry.message}"
											Err(_) => "This event is no longer in retained history."
										}
									},
								),
							),
						],
					),
				],
			),
		].concat(Workflow.bindings(model, tasks)),
	)
}
