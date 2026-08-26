# Domain layer for the Support Inbox example.
#
# Everything here is pure: wire parsing, unread counting, filtering, and the
# optimistic merge that reconciles the polled server snapshot with locally
# queued messages. `main.roc` only wires these functions into signals.
#
# The wire is text, so every string that arrives from the host is parsed into a
# tag union once, at the edge (`Inbox.Author.from_str`, `Inbox.Filter.from_str`,
# the `SendResult` mappers in `main.roc`). Nothing downstream compares strings
# to decide what something is.

Inbox :: [].{

	## Who wrote a message. The wire may name an author this build has never
	## heard of, so unknown values are carried through verbatim rather than
	## collapsed into a catch-all.
	Author := [You, Agent, Customer, Other(Str)].{
		is_eq : Inbox.Author, Inbox.Author -> Bool
		is_eq = |left, right|
			match left {
				You => match right {
					You => True
					_ => False
				}
				Agent => match right {
					Agent => True
					_ => False
				}
				Customer => match right {
					Customer => True
					_ => False
				}
				Other(left_name) => match right {
					Other(right_name) => left_name == right_name
					_ => False
				}
			}

		## Parse boundary: this is the only place author text is interpreted.
		from_str : Str -> Inbox.Author
		from_str = |raw|
			if raw == "you" {
				You
			} else if raw == "agent" {
				Agent
			} else if raw == "customer" {
				Customer
			} else {
				Other(raw)
			}
	}

	## Which rows the conversation list shows.
	Filter := [All, Unread, Mine].{
		is_eq : Inbox.Filter, Inbox.Filter -> Bool
		is_eq = |left, right|
			match left {
				All => match right {
					All => True
					_ => False
				}
				Unread => match right {
					Unread => True
					_ => False
				}
				Mine => match right {
					Mine => True
					_ => False
				}
			}

		## The radio group's values, which are also what the specs type.
		to_str : Inbox.Filter -> Str
		to_str = |filter|
			match filter {
				All => "all"
				Unread => "unread"
				Mine => "mine"
			}

		from_str : Str -> Inbox.Filter
		from_str = |raw|
			if raw == "unread" {
				Unread
			} else if raw == "mine" {
				Mine
			} else {
				All
			}
	}

	## What one rendered thread row is doing. Server rows are `Unread` or
	## `Delivered`; optimistic rows are `Sending` or `Sent`.
	MsgState := [Unread, Delivered, Sending, Sent].{
		is_eq : Inbox.MsgState, Inbox.MsgState -> Bool
		is_eq = |left, right|
			match left {
				Unread => match right {
					Unread => True
					_ => False
				}
				Delivered => match right {
					Delivered => True
					_ => False
				}
				Sending => match right {
					Sending => True
					_ => False
				}
				Sent => match right {
					Sent => True
					_ => False
				}
			}

		## The badge text shown under a message bubble.
		to_str : Inbox.MsgState -> Str
		to_str = |state|
			match state {
				Unread => "unread"
				Delivered => "delivered"
				Sending => "sending"
				Sent => "sent"
			}
	}

	## A request this app sends to the sync endpoint. One encode point, so the
	## request vocabulary is a type rather than a scattering of string literals.
	Request := [Poll, Read(Str)].{
		to_str : Inbox.Request -> Str
		to_str = |request|
			match request {
				Poll => "poll"
				Read(conv_id) => "read:${conv_id}"
			}
	}

	## The request line for the most recently queued message, if there is one.
	SendRequest := [NoSend, Send(Str)].{
		is_eq : Inbox.SendRequest, Inbox.SendRequest -> Bool
		is_eq = |left, right|
			match left {
				NoSend => match right {
					NoSend => True
					_ => False
				}
				Send(left_line) => match right {
					Send(right_line) => left_line == right_line
					_ => False
				}
			}
	}

	## What the send task currently holds. Both payloads are the client id of
	## the message that settled, which is what lets the app tell *which*
	## optimistic message a result belongs to.
	SendResult := [Idle, Sent(Str), Failed(Str)].{
		is_eq : Inbox.SendResult, Inbox.SendResult -> Bool
		is_eq = |left, right|
			match left {
				Idle => match right {
					Idle => True
					_ => False
				}
				Sent(left_cid) => match right {
					Sent(right_cid) => left_cid == right_cid
					_ => False
				}
				Failed(left_cid) => match right {
					Failed(right_cid) => left_cid == right_cid
					_ => False
				}
			}
	}

	## Lifecycle of one optimistic message, derived from three independent
	## inputs. This is the whole optimistic story in one type:
	##
	## - `Synced`     the poll came back carrying our client id; the server row
	##                takes over the same row key, so nothing is recreated.
	## - `Sent`       the send task acknowledged, no poll has caught up yet.
	## - `Failed`     the send task rejected; the message is rolled back out of
	##                the thread and surfaced in the error banner. The composer
	##                stays disabled until the user discards it.
	## - `Discarded`  the user dismissed a failed message.
	PendingState := [Idle, Sending, Sent, Synced, Failed, Discarded].{
		is_eq : Inbox.PendingState, Inbox.PendingState -> Bool
		is_eq = |left, right|
			match left {
				Idle => match right {
					Idle => True
					_ => False
				}
				Sending => match right {
					Sending => True
					_ => False
				}
				Sent => match right {
					Sent => True
					_ => False
				}
				Synced => match right {
					Synced => True
					_ => False
				}
				Failed => match right {
					Failed => True
					_ => False
				}
				Discarded => match right {
					Discarded => True
					_ => False
				}
			}

		## The row a still-unacknowledged message shows in the thread. Only the
		## in-flight states reach the thread at all.
		to_msg_state : Inbox.PendingState -> Inbox.MsgState
		to_msg_state = |state|
			match state {
				Sending => Inbox.MsgState.Sending
				_ => Inbox.MsgState.Sent
			}

		## True while the message is still in the thread as an optimistic row.
		is_inflight : Inbox.PendingState -> Bool
		is_inflight = |state|
			match state {
				Sending => True
				Sent => True
				_ => False
			}
	}

	## One conversation as the server reports it.
	Conversation : {
		id : Str,
		subject : Str,
		customer : Str,
		owner : Str,
	}

	## One message as the server reports it. `cid` is the client-generated
	## idempotency key echoed back by the server ("-" for server-origin
	## messages); it is what makes the optimistic merge safe.
	Message : {
		id : Str,
		conv : Str,
		author : Inbox.Author,
		body : Str,
		unread : Bool,
		cid : Str,
	}

	## A whole polled snapshot.
	Snapshot : {
		convs : List(Inbox.Conversation),
		msgs : List(Inbox.Message),
	}

	## A locally queued, not-yet-server-acknowledged message.
	Pending : {
		cid : Str,
		conv : Str,
		body : Str,
	}

	## Retained session state: the open conversation, its composer draft, and
	## the optimistic outbox. These live in one `Ui.state` because the send
	## transition has to read all three atomically and a reducer can only see
	## its own state handle.
	Session : {
		selected : Str,
		draft : Str,
		seq : U64,
		last_cid : Str,
		pending : List(Inbox.Pending),
		dead : List(Str),
	}

	## A conversation list row after unread counting and selection are applied.
	ConvRow : {
		id : Str,
		subject : Str,
		customer : Str,
		owner : Str,
		unread : U64,
		selected : Bool,
	}

	## A rendered thread row, server-origin or optimistic.
	ThreadRow : {
		key : Str,
		author : Inbox.Author,
		body : Str,
		state : Inbox.MsgState,
	}

	## The inputs the thread pane fans in.
	ViewInput : {
		convs : List(Inbox.Conversation),
		msgs : List(Inbox.Message),
		session : Inbox.Session,
		send : Inbox.SendResult,
	}

	empty_snapshot : Inbox.Snapshot
	empty_snapshot = { convs: [], msgs: [] }

	initial_session : Inbox.Session
	initial_session = { selected: "", draft: "", seq: 0, last_cid: "", pending: [], dead: [] }

	field : List(Str), U64, Str -> Str
	field = |parts, index, fallback| parts.get(index).ok_or(fallback)

	## `id|subject|customer|owner`
	parse_conversation : Str -> Inbox.Conversation
	parse_conversation = |raw| {
		parts = raw.split_on("|")
		{
			id: Inbox.field(parts, 0, ""),
			subject: Inbox.field(parts, 1, "(no subject)"),
			customer: Inbox.field(parts, 2, "unknown"),
			owner: Inbox.field(parts, 3, "unassigned"),
		}
	}

	## `id|conv|author|body|read-flag|client-id`
	parse_message : Str -> Inbox.Message
	parse_message = |raw| {
		parts = raw.split_on("|")
		{
			id: Inbox.field(parts, 0, ""),
			conv: Inbox.field(parts, 1, ""),
			author: Inbox.Author.from_str(Inbox.field(parts, 2, "unknown")),
			body: Inbox.field(parts, 3, ""),
			unread: Inbox.field(parts, 4, "read") == "new",
			cid: Inbox.field(parts, 5, "-"),
		}
	}

	split_records : Str -> List(Str)
	split_records = |raw| {
		trimmed = raw.trim()
		if trimmed.is_empty() {
			[]
		} else {
			trimmed.split_on(";").keep_if(|item| !item.trim().is_empty())
		}
	}

	## Wire format: `conversations # messages`, records separated by `;`.
	parse_snapshot : Str -> Inbox.Snapshot
	parse_snapshot = |raw| {
		sections = raw.split_on("#")
		{
			convs: Inbox.split_records(Inbox.field(sections, 0, "")).map(Inbox.parse_conversation),
			msgs: Inbox.split_records(Inbox.field(sections, 1, "")).map(Inbox.parse_message),
		}
	}

	## Unread count per conversation, straight from the server read flags.
	unread_count : List(Inbox.Message), Str -> U64
	unread_count = |msgs, conv_id| msgs.keep_if(|m| m.conv == conv_id and m.unread).len()

	## Fan-in: conversations x messages -> per-conversation unread counts.
	count_rows : List(Inbox.Conversation), List(Inbox.Message) -> List(Inbox.ConvRow)
	count_rows = |convs, msgs|
		convs.map(
			|c| {
				id: c.id,
				subject: c.subject,
				customer: c.customer,
				owner: c.owner,
				unread: Inbox.unread_count(msgs, c.id),
				selected: False,
			},
		)

	row_matches_filter : Inbox.ConvRow, Inbox.Filter -> Bool
	row_matches_filter = |row, filter|
		match filter {
			All => True
			Unread => row.unread > 0
			Mine => row.owner == "me"
		}

	## Fan-in: counted rows x filter x selection -> the visible list.
	visible_rows : List(Inbox.ConvRow), Inbox.Filter, Str -> List(Inbox.ConvRow)
	visible_rows = |rows, filter, selected|
		rows
			.keep_if(|row| Inbox.row_matches_filter(row, filter))
			.map(|row| { ..row, selected: row.id == selected })

	## True when the open conversation exists but the filter hides its row.
	## The app deliberately keeps the thread open in that case.
	selection_hidden : List(Inbox.ConvRow), Str -> Bool
	selection_hidden = |visible, selected|
		if selected == "" {
			False
		} else {
			!visible.any(|row| row.id == selected)
		}

	server_has_cid : List(Inbox.Message), Str -> Bool
	server_has_cid = |msgs, cid| msgs.any(|m| m.cid == cid)

	## Lifecycle of one optimistic message, derived from three independent
	## inputs: the outbox, the polled snapshot, and the send task's result.
	pending_state : Inbox.ViewInput, Str -> Inbox.PendingState
	pending_state = |input, cid|
		if cid == "" {
			Idle
		} else if input.session.dead.contains(cid) {
			Discarded
		} else if Inbox.server_has_cid(input.msgs, cid) {
			Synced
		} else if cid != input.session.last_cid {
			# Only one send is ever in flight (the composer is disabled while one
			# is pending or failed), so an older queued message that is neither on
			# the server nor discarded was already acknowledged.
			Sent
		} else {
			match input.send {
				Inbox.SendResult.Idle => Sending
				Inbox.SendResult.Sent(settled) => if settled == cid { Sent } else { Sending }
				Inbox.SendResult.Failed(settled) => if settled == cid { Failed } else { Sending }
			}
		}

	## Row identity. A message the client originated keeps its client id as its
	## row key for its whole life, so the moment the server acknowledges it the
	## row is *reused* rather than removed and recreated.
	message_key : Inbox.Message -> Str
	message_key = |m|
		if m.cid == "-" {
			m.id
		} else {
			m.cid
		}

	## The merge. Server rows first, then the optimistic rows the server has not
	## taken over and that have not been rolled back. Because both sides key by
	## the client id, an acknowledged message never changes row identity.
	thread_rows : Inbox.ViewInput -> List(Inbox.ThreadRow)
	thread_rows = |input| {
		selected = input.session.selected
		known = input.convs.any(|c| c.id == selected)
		server_rows =
			input.msgs
				.keep_if(|m| m.conv == selected)
				.map(
					|m| {
						key: Inbox.message_key(m),
						author: m.author,
						body: m.body,
						state: if m.unread { Inbox.MsgState.Unread } else { Inbox.MsgState.Delivered },
					},
				)
		local_rows =
			input.session.pending
				.keep_if(
					|p|
						p.conv == selected
						and Inbox.pending_state(input, p.cid).is_inflight()
						and !Inbox.server_has_cid(input.msgs, p.cid),
				)
				.map(
					|p| {
						key: p.cid,
						author: Inbox.Author.You,
						body: p.body,
						state: Inbox.pending_state(input, p.cid).to_msg_state(),
					},
				)
		if known {
			server_rows.concat(local_rows)
		} else {
			# A conversation the inbox no longer lists has no thread to show.
			[]
		}
	}

	## Any optimistic message currently rolled back by a failed send.
	failed_body : Inbox.ViewInput -> Str
	failed_body = |input|
		match input.session.pending.find_first(|p| Inbox.pending_state(input, p.cid).is_eq(Inbox.PendingState.Failed)) {
			Ok(p) => p.body
			Err(_) => ""
		}

	## Count of optimistic messages still waiting for the server.
	inflight_count : Inbox.ViewInput -> U64
	inflight_count = |input|
		input.session.pending.keep_if(|p| Inbox.pending_state(input, p.cid).is_eq(Inbox.PendingState.Sending)).len()

	## Queue a draft. No-op when there is nothing to send.
	submit_draft : Inbox.Session -> Inbox.Session
	submit_draft = |session| {
		body = session.draft.trim()
		if session.selected == "" or body.is_empty() {
			session
		} else {
			next = session.seq + 1
			cid = "p${next.to_str()}"
			{
				..session,
				seq: next,
				draft: "",
				last_cid: cid,
				pending: session.pending.append({ cid, conv: session.selected, body }),
			}
		}
	}

	## Roll the most recent failed send out of the outbox for good.
	discard_failed : Inbox.Session -> Inbox.Session
	discard_failed = |session|
		if session.last_cid == "" {
			session
		} else {
			{ ..session, dead: session.dead.append(session.last_cid) }
		}

	select_conversation : Inbox.Session, Str -> Inbox.Session
	select_conversation = |session, conv_id| { ..session, selected: conv_id, draft: "" }

	## The request line for the most recently queued message, if the outbox
	## still holds one. `cid|conv|body` is the send endpoint's wire format.
	send_request : Inbox.Session -> Inbox.SendRequest
	send_request = |session|
		match session.pending.find_first(|p| p.cid == session.last_cid) {
			Ok(p) => Send("${p.cid}|${p.conv}|${p.body}")
			Err(_) => NoSend
		}
}

expect Inbox.Author.from_str("you").is_eq(Inbox.Author.You)
expect Inbox.Author.from_str("bot").is_eq(Inbox.Author.Other("bot"))

## Every filter round-trips through the radio group's string values.
expect Inbox.Filter.from_str(Inbox.Filter.to_str(Inbox.Filter.Mine)).is_eq(Inbox.Filter.Mine)
expect Inbox.Filter.from_str("nonsense").is_eq(Inbox.Filter.All)

expect Inbox.Request.to_str(Inbox.Request.Read("c1")) == "read:c1"

expect Inbox.MsgState.to_str(Inbox.MsgState.Delivered) == "delivered"

expect Inbox.parse_message("m9|c1|agent|Refund issued|read|p1").author.is_eq(Inbox.Author.Agent)
expect Inbox.parse_message("m9|c1|agent|Refund issued|read|p1").cid == "p1"
expect Inbox.parse_message("m3|c2|customer|Login loop|new|-").unread

## A send result naming a *different* client id must not settle this one.
expect
	Inbox.pending_state(
		{
			convs: [],
			msgs: [],
			session: { ..Inbox.initial_session, selected: "c1", last_cid: "p2", pending: [{ cid: "p2", conv: "c1", body: "hi" }] },
			send: Inbox.SendResult.Failed("p1"),
		},
		"p2",
	).is_eq(Inbox.PendingState.Sending)
