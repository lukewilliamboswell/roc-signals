app [main] { pf: platform "../../platform-gui/main.roc" }

import pf.Elem exposing [Elem]
import pf.Gui
import pf.Signal
import pf.Ui
import Feed

entry_view : Ui.Row(Feed.Entry), Ui.State(Str) -> Elem
entry_view = |row, selected| {
	key = row.key()
	Gui.row(
		[
			Gui.test_id("event-${key}"),
			Gui.selected_s(Signal.select(selected.signal(), key)),
		],
		[
			Gui.button("Inspect ${key}", selected.on_unit(|_| key)),
			Gui.text_s(row.signal().map(|entry| entry.severity.to_str())),
			Gui.text_s(row.signal().map(|entry| entry.component)),
		],
	)
}

main : () -> Elem
main = || Ui.state(
	Feed.empty,
	|history| Ui.state(
		False,
		|running| Ui.state(
			"",
			|query| Ui.state(
				False,
				|errors_only| Ui.state(
					"",
					|selected| Ui.state(
						True,
						|follow_tail| {
							append = history.update_cmd(Feed.append)
							projection = { history: history.signal(), query: query.signal(), errors: errors_only.signal() }.Signal
							visible = projection.map(|value| Feed.visible(value.history, value.query, value.errors))
							inspection = { history: history.signal(), selected: selected.signal() }.Signal
							Gui.column(
								[Gui.style({ ..Gui.style_default, padding: 24, gap: 16, width: Fill, height: Fill })],
								[
									Gui.heading("Activity Monitor"),
									Gui.text("SIMULATED REPLAY · deterministic sample operations, not system telemetry"),
									Gui.row(
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
													enabled: Signal.const(True),
												},
												[],
												running.on_unit(|active| !active),
											),
											Gui.button("Step replay", Ui.action(Signal.const({}), |_| append)),
											Gui.button("Clear history", history.on_unit(Feed.clear)),
											Gui.text_s(history.signal().map(|value| "Retained: ${value.rows.len().to_str()} / 1000")),
										],
									),
									Gui.row(
										[],
										[
											Gui.text_input({ label: "Filter activity", value: query.signal() }, [Gui.style({ ..Gui.style_default, width: Px(360) })], query.on_str(|_, value| value)),
											Gui.checkbox({ label: "Errors only", checked: errors_only.signal() }, [], errors_only.on_bool(|_, value| value)),
											Gui.checkbox({ label: "Follow latest", checked: follow_tail.signal() }, [], follow_tail.on_bool(|_, value| value)),
										],
									),
									Ui.when(running.signal(), || Ui.on_change(Signal.interval(500), |_| append), || Gui.text("Replay paused")),
									Gui.row(
										[Gui.style({ ..Gui.style_default, grow: True, width: Fill })],
										[
											Gui.column(
												[Gui.style({ ..Gui.style_default, grow: True })],
												[
													Ui.when(visible.map(|rows| rows.len() == 0), || Gui.text("No matching events. Start the replay or adjust the filter."), || Gui.text("")),
													Gui.virtual_list(
														{ row_height: 44, follow_tail: follow_tail.signal() },
														[Gui.test_id("activity-list")],
														[
															Ui.each(visible, |row| entry_view(row, selected)),
														],
													),
												],
											),
											Gui.panel(
												[Gui.style({ ..Gui.style_default, width: Px(300), padding: 16 })],
												[
													Gui.heading("Event inspector"),
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
								],
							)
						},
					),
				),
			),
		),
	),
)
