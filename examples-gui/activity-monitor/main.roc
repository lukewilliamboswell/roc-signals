app [main] { roc: "nightly-2026-09-04-c125b82", pf: platform "../../platform-gui/main.roc" }

import pf.Action exposing [Action]
import pf.Elem exposing [Elem]
import pf.Gui exposing [Px]
import pf.Signal
import pf.Ui
import Feed
import Session
import Workflow

# Embedded at compile time; registered with the native text system at startup.
# Licensed under the SIL Open Font License 1.1 — see vendor/fonts/source-code-pro/OFL.txt.
import "../../vendor/fonts/source-code-pro/SourceCodePro-Regular.ttf" as source_code_pro : List(U8)

feed_font : Str
feed_font = "Source Code Pro"

entry_view : Ui.Row(Feed.Entry), Ui.State(Str) -> Elem
entry_view = |row, selected| {
	key = row.key()
	Elem.row(
		{
			font_family: feed_font,
			test_id: "event-${key}",
			selected: Signal.select(selected.signal(), key),
			height: 44.Px,
			gap: 10,
			overflow_x: Clip,
			overflow_y: Clip,
		},
		[
			Elem.button("Inspect ${key}", selected.update(|_| key)),
			Elem.col(
				{
					changes: row.map(
						|entry| Gui.Style.{
							width: 70.Px,
							height: Fill,
							overflow_x: Clip,
							overflow_y: Clip,
							font_size: 13,
							fg: match entry.severity {
								Feed.Severity.Error => Rgb(0xF09A93)
								Feed.Severity.Warning => Rgb(0xE8C27A)
								_ => Rgb(0xA9BFCC)
							},
						},
					),
				},
				[Elem.text_s(row.map(|entry| entry.severity.to_str()))],
			),
			Elem.col(
				{
					width: 110.Px,
					height: Fill,
					overflow_x: Clip,
					overflow_y: Clip,
					font_size: 13,
					fg: Rgb(0xA9BFCC),
				},
				[Elem.text_s(row.map(|entry| entry.component))],
			),
			Elem.col({ grow: True, height: Fill, overflow_x: Clip, overflow_y: Clip }, [Elem.text_s(row.map(|entry| entry.message))]),
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
	history = model.read(|value| value.history)
	session = model.read(|value| value.session)
	replay = session.map(|state| state.source == Session.Source.Replay)
	busy : Signal.Signal(Bool)
	busy = session.map(
		|state| match state.phase {
			Session.Phase.Choosing => True
			Session.Phase.Reading(_) => True
			_ => False
		},
	)
	append = || Action.update([model.write(|value| { ..value, history: Feed.append(value.history) })])
	projection = { history, query: query.signal(), errors: errors_only.signal() }.Signal
	visible = projection.map(|value| Feed.visible(value.history, value.query, value.errors))
	inspection = { history, selected: selected.signal() }.Signal
	Elem.col(
		{
			embedded_fonts: [{ family: feed_font, bytes: source_code_pro }],
			padding: 24,
			gap: 12,
			width: Fill,
			height: Fill,
			overflow_y: Clip,
		},
		[
			Elem.heading("Activity Monitor"),
			Elem.col(
				{ fg: Rgb(0xA9BFCC) },
				["Follow a live log file, or replay a deterministic sample feed."],
			),
			Elem.panel(
				{
					changes: session.map(
						|state| Gui.Style.{
							padding: 8,
							radius: 6,
							bg: Rgb(0x1B2A33),
							font_size: 13,
							fg: match state.source {
								Session.Source.Replay => Rgb(0xE8C27A)
								Session.Source.Log(_) => Rgb(0x7FC9E8)
							},
						},
					),
				},
				[
					Elem.text_s(
						session.map(
							|state| match state.source {
								Session.Source.Replay => "SIMULATED REPLAY · deterministic sample operations, not system telemetry"
								Session.Source.Log(file) => "PLAIN-TEXT LOG · ${file.path}"
							},
						),
					),
				],
			),
			Elem.row(
				{ gap: 8 },
				[
					Elem.action_button(
						{
							caption: Signal.const("Open log…"),
							enabled: busy.map(|value| !value),
							padding: 8,
							radius: 6,
							bg: Rgb(0x2E6FA3),
							hover_bg: Rgb(0x3A80B8),
							active_bg: Rgb(0x265D89),
						},
						Action.run(
							model.signal(),
							|value| Action.update([
								model.set({ ..value, session: Session.choose(value.session) }),
								running.set(False),
								errors_only.set(False),
							]),
						),
					),
					Elem.action_button(
						{
							caption: Signal.const("Use simulated replay"),
							enabled: { busy, replay }.Signal.map(|value| !value.busy and !value.replay),
						},
						Action.run(
							history,
							|current| Action.update([
								model.set({ session: Session.initial, history: Feed.clear(current) }),
								running.set(False),
								errors_only.set(False),
							]),
						),
					),
					Elem.action_button({
						caption: Signal.const("Retry read"),
						enabled: session.map(|state| state.phase == Session.Phase.Paused and state.retry != None),
					}, model.update(|value| { ..value, session: Session.retry_read(value.session) })),
					Elem.action_button({ caption: Signal.const("Cancel operation"), enabled: busy }, Action.run(session, |state| Workflow.cancel(model, state.phase))),
				],
			),
			Elem.col({ test_id: "activity-status", font_size: 13, fg: Rgb(0xA9BFCC) }, [Elem.text_s(session.map(|state| state.notice))]),
			Ui.when(
				replay,
				|| Elem.row(
					{ gap: 8 },
					[
						Elem.action_button(
							{
								caption: running.read(
									|active| if active {
										"Pause replay"
									} else {
										"Start replay"
									},
								),
								enabled: busy.map(|value| !value),
							},
							running.update(|active| !active),
						),
						Elem.action_button({ caption: Signal.const("Step replay"), enabled: busy.map(|value| !value) }, Action.run(Signal.const({}), |_| append())),
						Ui.when(
							running.signal(),
							|| Elem.text(""),
							|| Elem.col(
								{ padding: 8, font_size: 13, fg: Rgb(0xE8C27A) },
								["Replay paused"],
							),
						),
					],
				),
				|| Elem.row(
					{ gap: 8 },
					[
						Elem.action_button(
							{
								caption: session.map(
									|state| if state.phase == Session.Phase.Paused {
										"Resume following"
									} else {
										"Pause following"
									},
								),
							},
							Action.run(
								session,
								|state| if state.phase == Session.Phase.Paused {
									Action.update([model.write(|value| { ..value, session: Session.read_next(value.session) })])
								} else {
									Workflow.cancel(model, state.phase)
								},
							),
						),
					],
				),
			),
			Elem.row(
				{ gap: 12 },
				[
					Elem.button("Clear history", model.update(|value| { ..value, history: Feed.clear(value.history) })),
					Elem.col(
						{ padding: 8, font_size: 13, fg: Rgb(0xA9BFCC) },
						[Elem.text_s(history.map(|value| "Retained: ${value.rows.len().to_str()} / 1000"))],
					),
					Elem.col(
						{ padding: 8, font_size: 13, fg: Rgb(0x93A9B6) },
						[Elem.text_s(history.map(|value| "Text: ${value.bytes.to_str()} / 4194304 bytes · Evicted: ${value.discarded.to_str()}"))],
					),
				],
			),
			Elem.row(
				{ gap: 16 },
				[
					Elem.text_input({
						label: "Filter activity",
						value: query.signal(),
						placeholder: "Filter activity…",
						width: 240.Px,
						gap: 4,
					}, query.update_str(|_, value| value)),
					Elem.checkbox({ label: "Errors only", checked: errors_only.signal(), enabled: replay }, errors_only.update_bool(|_, value| value)),
					Elem.checkbox({ label: "Follow latest", checked: follow_tail.signal() }, follow_tail.update_bool(|_, value| value)),
				],
			),
			Elem.row(
				{ gap: 16, grow: True, width: Fill, height: Fill },
				[
					Elem.col(
						{
							grow: True,
							gap: 0,
							padding: 12,
							radius: 10,
							bg: Rgb(0x1B2A33),
							overflow_y: Clip,
						},
						[
							Ui.when(
								visible.map(|rows| rows.len() == 0),
								|| Elem.col(
									{ font_size: 13, fg: Rgb(0x93A9B6) },
									["No matching events. Start the replay, open a log, or adjust the filter."],
								),
								|| Elem.text(""),
							),
							Elem.virtual_list({
								row_height: 44,
								follow_tail: follow_tail.signal(),
								test_id: "activity-list",
								width: Fill,
								height: Fill,
								grow: True,
							}, [Ui.each(visible, |row| entry_view(row, selected))]),
						],
					),
					Elem.panel(
						{
							width: 340.Px,
							padding: 16,
							gap: 12,
							radius: 8,
							bg: Rgb(0x283A47),
							overflow_x: Scroll,
							overflow_y: Scroll,
						},
						[
							Elem.heading("Event inspector"),
							Elem.col(
								{ font_family: feed_font, test_id: "inspector-detail" },
								[
									Elem.text_s(
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
							Ui.when(
								session.map(|state| !state.lines.partial.is_empty()),
								|| Elem.col(
									{ gap: 4, height: 100.Px, overflow_x: Scroll, overflow_y: Scroll },
									[
										Elem.col(
											{ font_size: 13, fg: Rgb(0xA9BFCC) },
											[Elem.heading("Unterminated line")],
										),
										Elem.col({ font_family: feed_font }, [Elem.text_s(session.map(|state| state.lines.partial))]),
									],
								),
								|| Elem.text(""),
							),
						],
					),
				],
			),
			Ui.when(
				{ running: running.signal(), replay }.Signal.map(|value| value.running and value.replay),
				|| Action.every(500, |_| append()),
				|| Elem.text(""),
			),
		].concat(Workflow.bindings(model)),
	)
}
