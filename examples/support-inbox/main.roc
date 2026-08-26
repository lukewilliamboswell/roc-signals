app [main] { pf: platform "../../platform/main.roc" }

# Support Inbox
#
# Two panes derived from one store: a filtered conversation list with unread
# counts, and the open thread. The thread is the merge of the polled server
# snapshot with a local optimistic outbox, keyed by a client-generated id the
# server echoes back. A poll landing while a send is in flight therefore
# neither duplicates the message (the server row wins by client id) nor drops
# it (the optimistic row survives until the server takes it over).
#
# State is deliberately small and split:
#
#   filter   : Ui.State(Str)             which rows the list shows
#   polling  : Ui.State(Bool)            whether the 4s poll scope is mounted
#   session  : Ui.State(Inbox.Session)   selection + draft + optimistic outbox
#
# Everything else - unread counts, the visible list, the merged thread, the
# summary counters, the send-button disabled state - is derived.

import Inbox
import pf.Elem exposing [Elem]
import pf.Html
import pf.Signal
import pf.Ui

page_class = "app-shell app-shell-wide"

## The two panes. One column below `lg`, list plus thread above it.
panes_class = "grid items-start gap-5 lg:grid-cols-[20rem_minmax(0,1fr)]"

panel_class = "panel grid gap-4 p-4"

column_class = "grid min-w-0 gap-5"

textarea_class = "input textarea"

poll_period_ms : U64
poll_period_ms = 4000

count_at : List(U64), U64 -> U64
count_at = |values, index|
	match values.get(index) {
		Ok(value) => value
		Err(_) => 0
	}

# --- inbox summary -----------------------------------------------------------

## The three counters are one `Signal.combine` fan-in, read back by position so
## the stat tiles can never disagree with each other about which poll they came
## from.
conversations_text : List(U64) -> Str
conversations_text = |counts| count_at(counts, 0).to_str()

unread_text : List(U64) -> Str
unread_text = |counts| count_at(counts, 1).to_str()

sending_text : List(U64) -> Str
sending_text = |counts| count_at(counts, 2).to_str()

sync_badge_class : Str -> Str
sync_badge_class = |text|
	if text.starts_with("Failed") {
		"badge badge-danger"
	} else if text == "Up to date" {
		"badge badge-ok"
	} else {
		"badge badge-neutral"
	}

filter_label : Str -> Str
filter_label = |value|
	if value == "unread" {
		"Unread"
	} else if value == "mine" {
		"Assigned to me"
	} else {
		"All"
	}

poll_state_text : Bool -> Str
poll_state_text = |on|
	if on {
		"Polling every 4s"
	} else {
		"Paused"
	}

poll_state_class : Bool -> Str
poll_state_class = |on|
	if on {
		"badge badge-ok"
	} else {
		"badge badge-neutral"
	}

filter_notice_text : Bool -> Str
filter_notice_text = |hidden|
	if hidden {
		"The open conversation is hidden by the current filter."
	} else {
		"All open conversations are listed."
	}

## Neutral caption while the list and the selection agree; a warning only once
## the filter is actually hiding the thread the user is reading.
filter_notice_class : Bool -> Str
filter_notice_class = |hidden|
	if hidden {
		"notice notice-warn"
	} else {
		"hint"
	}

# --- conversation rows -------------------------------------------------------

## The selected row's ring is derived from the same row signal that feeds its
## text, so the highlight can never point at a conversation the thread is not
## showing.
conv_card_class : Inbox.ConvRow -> Str
conv_card_class = |row|
	if row.selected {
		"card grid gap-2 bg-emerald-50 ring-2 ring-emerald-500"
	} else {
		"card grid gap-2"
	}

unread_label : Inbox.ConvRow -> Str
unread_label = |row|
	if row.unread == 0 {
		"No unread"
	} else {
		"${row.unread.to_str()} unread"
	}

unread_class : Inbox.ConvRow -> Str
unread_class = |row|
	if row.unread == 0 {
		"hint"
	} else {
		"badge badge-info numeric"
	}

row_state_label : Inbox.ConvRow -> Str
row_state_label = |row|
	if row.selected {
		"Open"
	} else {
		"Closed"
	}

row_meta_label : Inbox.ConvRow -> Str
row_meta_label = |row| "${row.customer} · assigned to ${row.owner}"

## The snapshot wire format carries no timestamps, so the list shows a stable
## stub derived from the conversation id rather than inventing a clock. It is a
## pure function of the id, which means it never re-renders on a poll.
id_bucket : Str, U64 -> U64
id_bucket = |text, modulus| Str.to_utf8(text).fold(0, |acc, byte| acc + byte.to_u64()) % modulus

row_time_label : Inbox.ConvRow -> Str
row_time_label = |row|
	match id_bucket(row.id, 5) {
		0 => "2m ago"
		1 => "18m ago"
		2 => "1h ago"
		3 => "3h ago"
		_ => "yesterday"
	}

open_label : Inbox.ConvRow -> Str
open_label = |row| "Open ${row.subject}"

# --- thread ------------------------------------------------------------------

thread_title_text : List(Inbox.ConvRow), Str -> Str
thread_title_text = |rows, selected|
	if selected == "" {
		"No conversation selected"
	} else {
		match rows.find_first(|row| row.id == selected) {
			Ok(row) => row.subject
			Err(_) => "${selected} is no longer in the inbox"
		}
	}

thread_count_text : List(Inbox.ThreadRow) -> Str
thread_count_text = |rows| "${rows.len().to_str()} messages"

## Outbound is anything this workspace wrote: the optimistic rows the composer
## queued, and the agent replies the server has already accepted.
outbound : Str -> Bool
outbound = |author| author == "you" or author == "agent"

author_label : Inbox.ThreadRow -> Str
author_label = |row|
	if row.author == "you" {
		"You"
	} else if row.author == "agent" {
		"Agent"
	} else if row.author == "customer" {
		"Customer"
	} else {
		row.author
	}

bubble_row_class : Inbox.ThreadRow -> Str
bubble_row_class = |row|
	if outbound(row.author) {
		"grid justify-items-end gap-1"
	} else {
		"grid justify-items-start gap-1"
	}

bubble_class : Inbox.ThreadRow -> Str
bubble_class = |row|
	if outbound(row.author) {
		"max-w-[38rem] rounded-2xl rounded-br-sm bg-emerald-600 px-3 py-2 text-sm text-white"
	} else {
		"max-w-[38rem] rounded-2xl rounded-bl-sm border border-zinc-200 bg-zinc-100 px-3 py-2 text-sm text-zinc-900"
	}

## Per-message sync state is a badge, never body text, so a message still on
## its way is distinguishable from one the server has taken over.
message_state_class : Str -> Str
message_state_class = |state|
	if state == "sending" {
		"badge badge-warn"
	} else if state == "failed" {
		"badge badge-danger"
	} else if state == "unread" {
		"badge badge-info"
	} else {
		"badge badge-neutral"
	}

# --- composer ----------------------------------------------------------------

send_state_label : Str -> Str
send_state_label = |state|
	if state == "sending" {
		"Sending…"
	} else if state == "sent" {
		"Sent"
	} else if state == "synced" {
		"Delivered"
	} else if state == "failed" {
		"Failed"
	} else if state == "discarded" {
		"Discarded"
	} else {
		"Ready"
	}

send_state_text : Inbox.ViewInput -> Str
send_state_text = |input| send_state_label(Inbox.pending_state(input, input.session.last_cid))

send_state_class : Inbox.ViewInput -> Str
send_state_class = |input| {
	state = Inbox.pending_state(input, input.session.last_cid)
	if state == "failed" {
		"badge badge-danger"
	} else if state == "sending" {
		"badge badge-warn"
	} else if state == "sent" or state == "synced" {
		"badge badge-ok"
	} else {
		"badge badge-neutral"
	}
}

send_error_text : Inbox.ViewInput -> Str
send_error_text = |input| {
	body = Inbox.failed_body(input)
	if body.is_empty() {
		"No send errors"
	} else {
		"Send failed: ${body}"
	}
}

## The banner is a quiet caption until there is a rolled-back message to
## recover, and then it is unmistakable.
send_error_class : Inbox.ViewInput -> Str
send_error_class = |input|
	if Inbox.failed_body(input).is_empty() {
		"hint"
	} else {
		"notice notice-error"
	}

send_disabled_value : Inbox.ViewInput -> Bool
send_disabled_value = |input| {
	state = Inbox.pending_state(input, input.session.last_cid)
	input.session.selected == ""
	or input.session.draft.trim().is_empty()
	or state == "sending"
	or state == "failed"
}

# --- rows --------------------------------------------------------------------

conversation_row : Ui.State(Inbox.Session), Str, Signal.Signal(Inbox.ConvRow) -> Elem
conversation_row = |session, key, row|
	Html.section(
		"Conversation ${key}",
		[Html.class_attr_s(row.map(conv_card_class)), Html.test_id("conv-${key}")],
		[
			Html.div_c(
				"flex items-start justify-between gap-3",
				[
					Html.div_c(
						"grid min-w-0 gap-0.5",
						[
							# The button carries the subject as its visible text; the
							# longer "Open <subject>" phrasing stays as its accessible
							# name so the row reads as one control to a screen reader.
							Html.button_s_attrs(
								row.map(|item| item.subject),
								[
									Html.attr("type", "button"),
									Html.test_id("open-${key}"),
									Html.attr_s("aria-label", row.map(open_label)),
									Html.class_attr("card-title truncate text-left hover:underline"),
								],
								session.on_unit(|current| Inbox.select_conversation(current, key)),
							),
							Html.paragraph_s_attrs(row.map(row_meta_label), [Html.test_id("meta-${key}"), Html.class_attr("hint truncate")]),
						],
					),
					Html.div_c(
						"grid shrink-0 justify-items-end gap-1",
						[
							Html.paragraph_s_attrs(row.map(row_time_label), [Html.class_attr("hint")]),
							Html.paragraph_s_attrs(row.map(unread_label), [Html.test_id("unread-${key}"), Html.class_attr_s(row.map(unread_class))]),
						],
					),
				],
			),
			Html.paragraph_s_attrs(row.map(row_state_label), [Html.test_id("state-${key}"), Html.class_attr("hint")]),
		],
	)

message_row : Str, Signal.Signal(Inbox.ThreadRow) -> Elem
message_row = |key, row|
	Html.section(
		"Message ${key}",
		[Html.class_attr_s(row.map(bubble_row_class)), Html.test_id("msg-${key}")],
		[
			Html.paragraph_s_attrs(row.map(author_label), [Html.class_attr("hint")]),
			Html.paragraph_s_attrs(row.map(|item| item.body), [Html.test_id("body-${key}"), Html.class_attr_s(row.map(bubble_class))]),
			Html.paragraph_s_attrs(row.map(|item| item.state), [Html.test_id("mstate-${key}"), Html.class_attr_s(row.map(|item| message_state_class(item.state)))]),
		],
	)

## Radios and checkboxes render as bare inputs, so the visible caption is drawn
## beside them here.
check_row : Elem, Str -> Elem
check_row = |control, label| Html.div_c("check-row", [control, Html.text(label)])

## The polling scope. Mounting it starts the interval; unmounting it disposes
## the interval, cancels any in-flight poll, and runs the named cleanup.
## `inbox_task` is passed untyped because `Signal.Task` is not an exposed type.
poller = |inbox_task| {
	ticks = Signal.interval(poll_period_ms)

	Html.section(
		"Poll loop",
		[Html.class_attr("grid gap-1")],
		[
			Html.paragraph_s_attrs(
				ticks.map(|n| "Polls issued: ${n.to_str()}"),
				[Html.test_id("poll-count"), Html.class_attr("hint numeric")],
			),
			Ui.on_change(ticks, |_| Signal.start_str(inbox_task, "poll")),
			Ui.on_cleanup(Signal.cleanup("inbox polling cleanup")),
		],
	)
}

## A metric tile. The id goes on the figure, not the tile, so a spec asserts a
## number rather than the tile's concatenated label-and-value text.
stat : Str, Signal.Signal(Str), Str -> Elem
stat = |label, value, id|
	Html.div_c(
		"stat",
		[
			Html.paragraph_c(label, "stat-label"),
			Html.paragraph_s_attrs(value, [Html.test_id(id), Html.class_attr("stat-value numeric")]),
		],
	)

main : () -> Elem
main = || {
	Ui.state(
		"all",
		|filter| {
			Ui.state(
				True,
				|polling| {
					Ui.state(
						Inbox.initial_session,
						|session| {
							# Sync endpoint. `reset_on_start` is False so an in-flight
							# poll does not blank the inbox while it is running.
							inbox_task = Signal.task_source("inbox", Inbox.parse_snapshot, |err| err, False)

							# Send endpoint. Both payloads are the client id, so the app
							# can tell which optimistic message settled. Starting a send
							# publishes Loading while the optimistic row is inserted in
							# the same flush; the spec below guards that structural update.
							send_task = Signal.task_source("send", |value| "ok:${value}", |err| "fail:${err}", True)

							snapshot = Signal.fold_task(inbox_task, Inbox.empty_snapshot, |value| value, |_| Inbox.empty_snapshot)
							sync_status =
								Signal.fold_task(
									inbox_task,
									"Syncing…",
									|_| "Up to date",
									|err| "Failed — ${err}",
								)
							send_status = Signal.fold_task(send_task, "", |value| value, |err| err)

							# chain hop 1: snapshot -> its two projections
							convs = snapshot.map(|value| value.convs)
							msgs = snapshot.map(|value| value.msgs)

							session_sig = session.signal()
							selected_sig = session_sig.map(|value| value.selected)
							draft_sig = session_sig.map(|value| value.draft)
							send_req_sig = session_sig.map(Inbox.send_request)
							filter_sig = filter.signal()

							# fan-in: conversations x messages -> unread counts (hop 2)
							counted = Signal.map2(convs, msgs, Inbox.count_rows)

							# fan-in: counted rows x filter x selection -> visible list (hop 3)
							list_input = { rows: counted, filter: filter_sig, selected: selected_sig }.Signal
							visible = list_input.map(|value| Inbox.visible_rows(value.rows, value.filter, value.selected))

							# fan-in: visible list x selection -> filter/selection interaction
							hidden_sig = Signal.map2(visible, selected_sig, Inbox.selection_hidden)

							# fan-in: server messages x session x send status -> the merge
							view_input = { convs: convs, msgs: msgs, session: session_sig, send: send_status }.Signal
							thread = view_input.map(Inbox.thread_rows)

							thread_title = Signal.map2(counted, selected_sig, thread_title_text)
							has_rows = visible.map(|rows| !rows.is_empty())
							has_thread = thread.map(|rows| !rows.is_empty())

							# wide fan-in over three same-shaped counters
							conv_count = convs.map(|rows| rows.len())
							unread_total = counted.map(|rows| rows.fold(0, |acc, row| acc + row.unread))
							inflight_count = view_input.map(Inbox.inflight_count)
							summary = Signal.combine([conv_count, unread_total, inflight_count])

							Html.div_c(
								page_class,
								[
									Html.section_c(
										"Support Inbox",
										"app-header",
										[
											Html.heading_c("Support Inbox", "app-title"),
											Html.paragraph_c(
												"A polled support inbox: two panes derived from one store, unread counts that never touch the open thread, and optimistic sends merged with server polls by client id.",
												"app-subtitle",
											),
										],
									),
									Html.div_c(
										panes_class,
										[
											Html.div_c(
												column_class,
												[
													Html.section_c(
														"Inbox summary",
														panel_class,
														[
															# The three tiles share one `Signal.combine`. The grid
															# keeps the id the specs use to locate the summary; each
															# figure carries its own so an assertion reads as a
															# number. Three fixed columns, because the shared
															# `stat-grid` breakpoints assume full page width and this
															# sits in a 20rem sidebar.
															Html.div(
																[Html.class_attr("grid grid-cols-3 gap-2"), Html.test_id("inbox-summary")],
																[
																	stat("Threads", summary.map(conversations_text), "summary-conversations"),
																	stat("Unread", summary.map(unread_text), "summary-unread"),
																	stat("Sending", summary.map(sending_text), "summary-sending"),
																],
															),
															Html.div_c(
																"flex flex-wrap items-center gap-2",
																[
																	Html.paragraph_c("Sync", "panel-title"),
																	Html.paragraph_s_attrs(sync_status, [Html.test_id("sync-status"), Html.class_attr_s(sync_status.map(sync_badge_class))]),
																],
															),
															Html.div_c(
																"field",
																[
																	Html.div_c(
																		"flex items-center justify-between gap-2",
																		[
																			Html.paragraph_c("Show", "field-label"),
																			Html.paragraph_s_attrs(filter_sig.map(filter_label), [Html.test_id("filter-state"), Html.class_attr("badge badge-info")]),
																		],
																	),
																	Html.div(
																		[Html.class_attr("grid gap-1"), Html.attr("role", "radiogroup"), Html.attr("aria-label", "Inbox filter")],
																		[
																			check_row(Html.radio_c("All", "inbox-filter", "all", filter_sig, "checkbox", filter.on_str(|_, value| value)), "All"),
																			check_row(Html.radio_c("Unread", "inbox-filter", "unread", filter_sig, "checkbox", filter.on_str(|_, value| value)), "Unread"),
																			check_row(Html.radio_c("Assigned to me", "inbox-filter", "mine", filter_sig, "checkbox", filter.on_str(|_, value| value)), "Assigned to me"),
																		],
																	),
																],
															),
															Html.div_c(
																"grid gap-2 border-t border-zinc-200 pt-3",
																[
																	Html.div_c(
																		"flex flex-wrap items-center justify-between gap-2",
																		[
																			check_row(Html.checkbox_c("Poll for updates", polling.signal(), "checkbox", polling.on_bool(|_, value| value)), "Poll for updates"),
																			Html.paragraph_s_attrs(polling.signal().map(poll_state_text), [Html.test_id("poll-state"), Html.class_attr_s(polling.signal().map(poll_state_class))]),
																		],
																	),
																	Ui.when(
																		polling.signal(),
																		|| poller(inbox_task),
																		|| Html.paragraph_attrs("Polling is paused.", [Html.test_id("poll-paused"), Html.class_attr("hint")]),
																	),
																],
															),
														],
													),
													Html.section_c(
														"Conversations",
														panel_class,
														[
															Html.div_c(
																"grid gap-1",
																[
																	Html.paragraph_c("Conversations", "panel-title"),
																	Html.paragraph_s_attrs(hidden_sig.map(filter_notice_text), [Html.test_id("filter-notice"), Html.class_attr_s(hidden_sig.map(filter_notice_class))]),
																],
															),
															# Same shape as the thread pane: the keyed list is always
															# mounted and only the empty note is conditional.
															Html.div_c(
																"grid gap-2",
																[
																	Ui.each_str(visible, |row| row.id, |key, row| conversation_row(session, key, row)),
																	Ui.when(
																		has_rows,
																		|| Html.div([Html.test_id("conv-nonempty")], []),
																		|| Html.paragraph_attrs("No conversations to show.", [Html.test_id("conv-empty"), Html.class_attr("empty-state")]),
																	),
																],
															),
														],
													),
												],
											),
											Html.section_c(
												"Thread",
												"panel grid min-w-0 gap-4 p-4",
												[
													Html.div_c(
														"flex flex-wrap items-baseline justify-between gap-2",
														[
															Html.paragraph_s_attrs(thread_title, [Html.test_id("thread-title"), Html.class_attr("text-base font-semibold text-zinc-950")]),
															Html.paragraph_s_attrs(thread.map(thread_count_text), [Html.test_id("thread-count"), Html.class_attr("hint numeric")]),
														],
													),
													# The keyed list is rendered unconditionally and the empty
													# note lives in its own `Ui.when`: a `Ui.when` whose true arm
													# is an `each_str` leaves its rows in the DOM when it flips
													# false on this platform build.
													Html.div_c(
														"grid gap-3",
														[
															Ui.each_str(thread, |row| row.key, message_row),
															Ui.when(
																has_thread,
																|| Html.div([Html.test_id("thread-nonempty")], []),
																|| Html.paragraph_attrs("No messages yet.", [Html.test_id("thread-empty"), Html.class_attr("empty-state")]),
															),
														],
													),
													Html.form_label(
														"Composer",
														[
															Html.class_attr("grid gap-3 border-t border-zinc-200 pt-4"),
															Html.on_submit_prevent_default(session.on_unit(Inbox.submit_draft)),
														],
														[
															Html.div_c(
																"field",
																[
																	Html.paragraph_c("Your reply", "field-label"),
																	Html.textarea_attrs(
																		"Message",
																		draft_sig,
																		[
																			Html.class_attr(textarea_class),
																			Html.attr("rows", "3"),
																			Html.attr("placeholder", "Thanks for flagging this — I've issued the refund and it should land in 3–5 days."),
																		],
																		session.on_str(|current, value| { ..current, draft: value }),
																	),
																],
															),
															Html.div_c(
																"flex flex-wrap items-center justify-between gap-3",
																[
																	Html.div_c(
																		"flex min-w-0 flex-wrap items-center gap-2",
																		[
																			Html.paragraph_s_attrs(view_input.map(send_state_text), [Html.test_id("send-state"), Html.class_attr_s(view_input.map(send_state_class))]),
																			Html.paragraph_s_attrs(view_input.map(send_error_text), [Html.test_id("send-error"), Html.class_attr_s(view_input.map(send_error_class))]),
																		],
																	),
																	Html.div_c(
																		"flex items-center gap-2",
																		[
																			# The recovery action for a rolled-back send sits
																			# next to the banner that reports it.
																			Html.button_attrs(
																				"Discard failed message",
																				[Html.attr("type", "button"), Html.class_attr("button-danger button-sm")],
																				session.on_unit(Inbox.discard_failed),
																			),
																			Html.action_button_attrs(
																				Signal.const("Send message"),
																				view_input.map(send_disabled_value),
																				[Html.attr("type", "button"), Html.class_attr("button-primary")],
																				session.on_unit(Inbox.submit_draft),
																			),
																		],
																	),
																],
															),
														],
													),
												],
											),
										],
									),
									# Load once on mount, and re-read a conversation the
									# moment it is opened so its unread flags clear.
									Ui.on_mount(|| Signal.start_str(inbox_task, "poll")),
									Ui.on_change(
										selected_sig,
										|conv_id|
											if conv_id == "" {
												Signal.noop
											} else {
												Signal.start_str(inbox_task, "read:${conv_id}")
											},
									),
									Ui.on_change(
										send_req_sig,
										|request|
											if request == "" {
												Signal.noop
											} else {
												Signal.start_str(send_task, request)
											},
									),
									Ui.on_cleanup(Signal.cleanup("support inbox cleanup")),
								],
							)
						},
					)
				},
			)
		},
	)
}
