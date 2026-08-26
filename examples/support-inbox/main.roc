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
# summary line, the send-button disabled state - is derived.

import Inbox
import pf.Elem exposing [Elem]
import pf.Html
import pf.Signal
import pf.Ui

page_class = "grid gap-5"

hero_class = "panel grid gap-2 p-5"

panel_class = "panel grid gap-4 p-4"

row_class = "grid gap-1 rounded border border-zinc-200 p-3"

input_class = "w-full max-w-md rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm"

poll_period_ms : U64
poll_period_ms = 4000

count_at : List(U64), U64 -> U64
count_at = |values, index|
	match values.get(index) {
		Ok(value) => value
		Err(_) => 0
	}

## Fan-in over three same-shaped counters via `Signal.combine`.
summary_text : List(U64) -> Str
summary_text = |counts| {
	total = count_at(counts, 0)
	unread = count_at(counts, 1)
	inflight = count_at(counts, 2)
	"${total.to_str()} conversations, ${unread.to_str()} unread, ${inflight.to_str()} sending"
}

unread_label : Inbox.ConvRow -> Str
unread_label = |row|
	if row.unread == 0 {
		"no unread"
	} else {
		"${row.unread.to_str()} unread"
	}

row_state_label : Inbox.ConvRow -> Str
row_state_label = |row|
	if row.selected {
		"open"
	} else {
		"closed"
	}

row_meta_label : Inbox.ConvRow -> Str
row_meta_label = |row| "${row.customer} / ${row.owner}"

open_label : Inbox.ConvRow -> Str
open_label = |row| "Open ${row.subject}"

thread_title_text : List(Inbox.ConvRow), Str -> Str
thread_title_text = |rows, selected|
	if selected == "" {
		"Thread: no conversation selected"
	} else {
		match rows.find_first(|row| row.id == selected) {
			Ok(row) => "Thread: ${row.subject}"
			Err(_) => "Thread: ${selected} (not in inbox)"
		}
	}

filter_notice_text : Bool -> Str
filter_notice_text = |hidden|
	if hidden {
		"The open conversation is hidden by the current filter."
	} else {
		"All open conversations are listed."
	}

poll_state_text : Bool -> Str
poll_state_text = |on|
	if on {
		"Polling: every 4s"
	} else {
		"Polling: paused"
	}

send_state_text : Inbox.ViewInput -> Str
send_state_text = |input| "Send state: ${Inbox.pending_state(input, input.session.last_cid)}"

send_error_text : Inbox.ViewInput -> Str
send_error_text = |input| {
	body = Inbox.failed_body(input)
	if body.is_empty() {
		"No send errors"
	} else {
		"Send failed: ${body}"
	}
}

send_disabled_value : Inbox.ViewInput -> Bool
send_disabled_value = |input| {
	state = Inbox.pending_state(input, input.session.last_cid)
	input.session.selected == ""
	or input.session.draft.trim().is_empty()
	or state == "sending"
	or state == "failed"
}

thread_count_text : List(Inbox.ThreadRow) -> Str
thread_count_text = |rows| "Messages: ${rows.len().to_str()}"

message_line : Inbox.ThreadRow -> Str
message_line = |row| "${row.author}: ${row.body}"

conversation_row : Ui.State(Inbox.Session), Str, Signal.Signal(Inbox.ConvRow) -> Elem
conversation_row = |session, key, row|
	Html.section(
		"Conversation ${key}",
		[Html.class_attr(row_class), Html.test_id("conv-${key}")],
		[
			Html.button_s_attrs(
				row.map(open_label),
				[Html.attr("type", "button"), Html.test_id("open-${key}"), Html.class_attr("button-secondary justify-self-start")],
				session.on_unit(|current| Inbox.select_conversation(current, key)),
			),
			Html.paragraph_s_attrs(row.map(row_meta_label), [Html.test_id("meta-${key}"), Html.class_attr("text-sm text-zinc-700")]),
			Html.paragraph_s_attrs(row.map(unread_label), [Html.test_id("unread-${key}"), Html.class_attr("text-sm font-medium text-zinc-900")]),
			Html.paragraph_s_attrs(row.map(row_state_label), [Html.test_id("state-${key}"), Html.class_attr("text-sm text-zinc-600")]),
		],
	)

message_row : Str, Signal.Signal(Inbox.ThreadRow) -> Elem
message_row = |key, row|
	Html.section(
		"Message ${key}",
		[Html.class_attr(row_class), Html.test_id("msg-${key}")],
		[
			Html.paragraph_s_attrs(row.map(message_line), [Html.test_id("body-${key}"), Html.class_attr("text-sm text-zinc-900")]),
			Html.paragraph_s_attrs(row.map(|item| item.state), [Html.test_id("mstate-${key}"), Html.class_attr("text-sm text-zinc-600")]),
		],
	)

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
				[Html.test_id("poll-count"), Html.class_attr("text-sm text-zinc-600")],
			),
			Ui.on_change(ticks, |_| Signal.start_str(inbox_task, "poll")),
			Ui.on_cleanup(Signal.cleanup("inbox polling cleanup")),
		],
	)
}

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
									"Sync: loading",
									|_| "Sync: up to date",
									|err| "Sync: failed - ${err}",
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
							summary = Signal.combine([conv_count, unread_total, inflight_count]).map(summary_text)

							Html.div_c(
								page_class,
								[
									Html.section_c(
										"Support Inbox",
										hero_class,
										[
											Html.heading_c("Support Inbox", "text-3xl font-semibold text-zinc-950"),
											Html.paragraph_c(
												"A polled support inbox: two panes derived from one store, unread counts that never touch the open thread, and optimistic sends merged with server polls by client id.",
												"max-w-3xl text-sm text-zinc-700",
											),
										],
									),
									Html.section_c(
										"Inbox summary",
										panel_class,
										[
											Html.paragraph_s_attrs(summary, [Html.test_id("inbox-summary"), Html.class_attr("text-sm font-medium text-zinc-900")]),
											Html.paragraph_s_attrs(sync_status, [Html.test_id("sync-status"), Html.class_attr("text-sm text-zinc-700")]),
											Html.paragraph_s_attrs(filter_sig.map(|value| "Filter: ${value}"), [Html.test_id("filter-state"), Html.class_attr("text-sm text-zinc-700")]),
											Html.radio("All", "inbox-filter", "all", filter_sig, filter.on_str(|_, value| value)),
											Html.radio("Unread", "inbox-filter", "unread", filter_sig, filter.on_str(|_, value| value)),
											Html.radio("Assigned to me", "inbox-filter", "mine", filter_sig, filter.on_str(|_, value| value)),
											Html.checkbox("Poll for updates", polling.signal(), polling.on_bool(|_, value| value)),
											Html.paragraph_s_attrs(polling.signal().map(poll_state_text), [Html.test_id("poll-state"), Html.class_attr("text-sm text-zinc-700")]),
										],
									),
									Html.section_c(
										"Conversations",
										panel_class,
										[
											Html.paragraph_s_attrs(hidden_sig.map(filter_notice_text), [Html.test_id("filter-notice"), Html.class_attr("text-sm text-zinc-700")]),
											# Same shape as the thread pane: the keyed list is always
											# mounted and only the empty note is conditional.
											Ui.each_str(visible, |row| row.id, |key, row| conversation_row(session, key, row)),
											Ui.when(
												has_rows,
												|| Html.div([Html.test_id("conv-nonempty")], []),
												|| Html.paragraph_attrs("No conversations to show.", [Html.test_id("conv-empty"), Html.class_attr("text-sm text-zinc-700")]),
											),
										],
									),
									Html.section_c(
										"Thread",
										panel_class,
										[
											Html.paragraph_s_attrs(thread_title, [Html.test_id("thread-title"), Html.class_attr("text-sm font-medium text-zinc-900")]),
											# The keyed list is rendered unconditionally and the empty
											# note lives in its own `Ui.when`: a `Ui.when` whose true arm
											# is an `each_str` leaves its rows in the DOM when it flips
											# false on this platform build.
											Ui.each_str(thread, |row| row.key, message_row),
											Ui.when(
												has_thread,
												|| Html.div([Html.test_id("thread-nonempty")], []),
												|| Html.paragraph_attrs("No messages yet.", [Html.test_id("thread-empty"), Html.class_attr("text-sm text-zinc-700")]),
											),
											Html.paragraph_s_attrs(thread.map(thread_count_text), [Html.test_id("thread-count"), Html.class_attr("text-sm text-zinc-600")]),

											Html.paragraph_s_attrs(view_input.map(send_state_text), [Html.test_id("send-state"), Html.class_attr("text-sm text-zinc-700")]),
											Html.paragraph_s_attrs(view_input.map(send_error_text), [Html.test_id("send-error"), Html.class_attr("text-sm text-red-950")]),
											Html.form_label(
												"Composer",
												[Html.on_submit_prevent_default(session.on_unit(Inbox.submit_draft))],
												[
													Html.text_input_c("Message", draft_sig, input_class, session.on_str(|current, value| { ..current, draft: value })),
													Html.action_button_attrs(
														Signal.const("Send message"),
														view_input.map(send_disabled_value),
														[Html.attr("type", "button"), Html.class_attr("button-primary justify-self-start")],
														session.on_unit(Inbox.submit_draft),
													),
													Html.button_attrs(
														"Discard failed message",
														[Html.attr("type", "button"), Html.class_attr("button-secondary justify-self-start")],
														session.on_unit(Inbox.discard_failed),
													),
												],
											),
										],
									),
									Ui.when(
										polling.signal(),
										|| poller(inbox_task),
										|| Html.paragraph_attrs("Polling is paused.", [Html.test_id("poll-paused"), Html.class_attr("text-sm text-zinc-700")]),
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
