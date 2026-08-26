# Domain layer for the Support Inbox example.
#
# Everything here is pure: wire parsing, unread counting, filtering, and the
# optimistic merge that reconciles the polled server snapshot with locally
# queued messages. `app.roc` only wires these functions into signals.

Inbox :: [].{

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
		author : Str,
		body : Str,
		unread : Bool,
		cid : Str,
	}

	## A whole polled snapshot.
	Snapshot : {
		convs : List(Conversation),
		msgs : List(Message),
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
		pending : List(Pending),
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
		author : Str,
		body : Str,
		state : Str,
	}

	## The inputs the thread pane fans in.
	ViewInput : {
		convs : List(Conversation),
		msgs : List(Message),
		session : Session,
		send : Str,
	}

	empty_snapshot : Snapshot
	empty_snapshot = { convs: [], msgs: [] }

	initial_session : Session
	initial_session = { selected: "", draft: "", seq: 0, last_cid: "", pending: [], dead: [] }

	field : List(Str), U64, Str -> Str
	field = |parts, index, fallback|
		match parts.get(index) {
			Ok(value) => value
			Err(_) => fallback
		}

	has_str : List(Str), Str -> Bool
	has_str = |items, needle|
		match items.find_first(|item| item == needle) {
			Ok(_) => True
			Err(_) => False
		}

	## `id|subject|customer|owner`
	parse_conversation : Str -> Conversation
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
	parse_message : Str -> Message
	parse_message = |raw| {
		parts = raw.split_on("|")
		{
			id: Inbox.field(parts, 0, ""),
			conv: Inbox.field(parts, 1, ""),
			author: Inbox.field(parts, 2, "unknown"),
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
	parse_snapshot : Str -> Snapshot
	parse_snapshot = |raw| {
		sections = raw.split_on("#")
		{
			convs: Inbox.split_records(Inbox.field(sections, 0, "")).map(Inbox.parse_conversation),
			msgs: Inbox.split_records(Inbox.field(sections, 1, "")).map(Inbox.parse_message),
		}
	}

	## Unread count per conversation, straight from the server read flags.
	unread_count : List(Message), Str -> U64
	unread_count = |msgs, conv_id| msgs.keep_if(|m| m.conv == conv_id and m.unread).len()

	## Fan-in: conversations x messages -> per-conversation unread counts.
	count_rows : List(Conversation), List(Message) -> List(ConvRow)
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

	row_matches_filter : ConvRow, Str -> Bool
	row_matches_filter = |row, filter|
		if filter == "unread" {
			row.unread > 0
		} else if filter == "mine" {
			row.owner == "me"
		} else {
			True
		}

	## Fan-in: counted rows x filter x selection -> the visible list.
	visible_rows : List(ConvRow), Str, Str -> List(ConvRow)
	visible_rows = |rows, filter, selected|
		rows
			.keep_if(|row| Inbox.row_matches_filter(row, filter))
			.map(|row| { ..row, selected: row.id == selected })

	## True when the open conversation exists but the filter hides its row.
	## The app deliberately keeps the thread open in that case.
	selection_hidden : List(ConvRow), Str -> Bool
	selection_hidden = |visible, selected|
		if selected == "" {
			False
		} else {
			match visible.find_first(|row| row.id == selected) {
				Ok(_) => False
				Err(_) => True
			}
		}

	server_has_cid : List(Message), Str -> Bool
	server_has_cid = |msgs, cid|
		match msgs.find_first(|m| m.cid == cid) {
			Ok(_) => True
			Err(_) => False
		}

	## Lifecycle of one optimistic message, derived from three independent
	## inputs. This is the whole optimistic story in one function:
	##
	## - `synced`     the poll came back carrying our client id; the server row
	##                takes over the same row key, so nothing is recreated.
	## - `sent`       the send task acknowledged, no poll has caught up yet.
	## - `failed`     the send task rejected; the message is rolled back out of
	##                the thread and surfaced in the error banner. The composer
	##                stays disabled until the user discards it.
	## - `discarded`  the user dismissed a failed message.
	pending_state : ViewInput, Str -> Str
	pending_state = |input, cid|
		if cid == "" {
			"idle"
		} else if Inbox.has_str(input.session.dead, cid) {
			"discarded"
		} else if Inbox.server_has_cid(input.msgs, cid) {
			"synced"
		} else if cid != input.session.last_cid {
			# Only one send is ever in flight (the composer is disabled while one
			# is pending or failed), so an older queued message that is neither on
			# the server nor discarded was already acknowledged.
			"sent"
		} else if input.send == "ok:${cid}" {
			"sent"
		} else if input.send == "fail:${cid}" {
			"failed"
		} else {
			"sending"
		}

	## Row identity. A message the client originated keeps its client id as its
	## row key for its whole life, so the moment the server acknowledges it the
	## row is *reused* rather than removed and recreated.
	message_key : Message -> Str
	message_key = |m|
		if m.cid == "-" {
			m.id
		} else {
			m.cid
		}

	## The merge. Server rows first, then the optimistic rows the server has not
	## taken over and that have not been rolled back. Because both sides key by
	## the client id, an acknowledged message never changes row identity.
	thread_rows : ViewInput -> List(ThreadRow)
	thread_rows = |input| {
		selected = input.session.selected
		known =
			match input.convs.find_first(|c| c.id == selected) {
				Ok(_) => True
				Err(_) => False
			}
		server_rows =
			input.msgs
				.keep_if(|m| m.conv == selected)
				.map(
					|m| {
						key: Inbox.message_key(m),
						author: m.author,
						body: m.body,
						state: if m.unread { "unread" } else { "delivered" },
					},
				)
		local_rows =
			input.session.pending
				.keep_if(
					|p| {
						state = Inbox.pending_state(input, p.cid)
						p.conv == selected
						and (state == "sending" or state == "sent")
						and !Inbox.server_has_cid(input.msgs, p.cid)
					},
				)
				.map(
					|p| {
						key: p.cid,
						author: "you",
						body: p.body,
						state: Inbox.pending_state(input, p.cid),
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
	failed_body : ViewInput -> Str
	failed_body = |input|
		match input.session.pending.find_first(|p| Inbox.pending_state(input, p.cid) == "failed") {
			Ok(p) => p.body
			Err(_) => ""
		}

	## Count of optimistic messages still waiting for the server.
	inflight_count : ViewInput -> U64
	inflight_count = |input|
		input.session.pending.keep_if(|p| Inbox.pending_state(input, p.cid) == "sending").len()

	## Queue a draft. No-op when there is nothing to send.
	submit_draft : Session -> Session
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
	discard_failed : Session -> Session
	discard_failed = |session|
		if session.last_cid == "" {
			session
		} else {
			{ ..session, dead: session.dead.append(session.last_cid) }
		}

	select_conversation : Session, Str -> Session
	select_conversation = |session, conv_id| { ..session, selected: conv_id, draft: "" }

	## The request line for the most recently queued message, or "" when there
	## is nothing new to send.
	send_request : Session -> Str
	send_request = |session|
		match session.pending.find_first(|p| p.cid == session.last_cid) {
			Ok(p) => "${p.cid}|${p.conv}|${p.body}"
			Err(_) => ""
		}
}
