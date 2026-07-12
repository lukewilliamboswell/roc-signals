import HostValue exposing [HostValue]
import Capability exposing [Capability]
import Node
import Signal exposing [Signal]

read_byte : List(U8) -> { byte : U8, rest : List(U8) }
read_byte = |bytes|
	match bytes.first() {
		Ok(byte) => { byte, rest: bytes.drop_first(1) }
		Err(_) => {
			crash "malformed browser payload: missing byte"
		}
	}

read_u32_le : List(U8) -> { value : U64, rest : List(U8) }
read_u32_le = |bytes| {
	b0 = read_byte(bytes)
	b1 = read_byte(b0.rest)
	b2 = read_byte(b1.rest)
	b3 = read_byte(b2.rest)
	value =
		U8.to_u64(b0.byte)
			+ U8.to_u64(b1.byte) * 256
			+ U8.to_u64(b2.byte) * 65536
			+ U8.to_u64(b3.byte) * 16777216
	{ value, rest: b3.rest }
}

take_bytes : List(U8), U64 -> { value : List(U8), rest : List(U8) }
take_bytes = |bytes, count| {
	var $remaining = bytes
	var $value = []
	var $left = count

	while $left > 0 {
		next = read_byte($remaining)
		$value = $value.append(next.byte)
		$remaining = next.rest
		$left = $left - 1
	}

	{ value: $value, rest: $remaining }
}

read_text : List(U8) -> { value : Str, rest : List(U8) }
read_text = |bytes| {
	len = read_u32_le(bytes)
	text_bytes = take_bytes(len.rest, len.value)
	text =
		match Str.from_utf8(text_bytes.value) {
			Ok(value) => value
			Err(_) => {
				crash "malformed browser payload: field was not UTF-8"
			}
		}
	{ value: text, rest: text_bytes.rest }
}

local_storage_area : U64
local_storage_area = 1

session_storage_area : U64
session_storage_area = 2

## Browser-owned environment sources.
Browser := [].{

	## Raw URL pieces. `path` includes its leading slash; `query` omits `?`;
	## `hash` omits `#`. Route parsing is app/package land.
	Location : { path : Str, query : Str, hash : Str }

	## Current page visibility, seeded from the host's startup snapshot and
	## updated when the browser document visibility changes.
	Visibility : [Visible, Hidden]

	## Text value read from browser storage for one declared key.
	StorageText : [StorageMissing, StorageValue(Str), StorageUnavailable(Str)]

	decode_location_payload : List(U8) -> Location
	decode_location_payload = |bytes| {
		path = read_text(bytes)
		query = read_text(path.rest)
		hash = read_text(query.rest)

		if !hash.rest.is_empty() {
			crash "malformed location payload: trailing bytes"
		}

		{ path: path.value, query: query.value, hash: hash.value }
	}

	decode_visibility_payload : List(U8) -> Visibility
	decode_visibility_payload = |bytes| {
		status = read_byte(bytes)

		if !status.rest.is_empty() {
			crash "malformed visibility payload: trailing bytes"
		}

		if status.byte == 0 {
			Hidden
		} else if status.byte == 1 {
			Visible
		} else {
			crash "malformed visibility payload: unknown status"
		}
	}

	decode_online_payload : List(U8) -> Bool
	decode_online_payload = |bytes| {
		status = read_byte(bytes)

		if !status.rest.is_empty() {
			crash "malformed online payload: trailing bytes"
		}

		if status.byte == 0 {
			False
		} else if status.byte == 1 {
			True
		} else {
			crash "malformed online payload: unknown status"
		}
	}

	decode_storage_payload : List(U8) -> StorageText
	decode_storage_payload = |bytes| {
		status = read_byte(bytes)

		if status.byte == 0 {
			if !status.rest.is_empty() {
				crash "malformed storage payload: trailing bytes"
			}

			StorageMissing
		} else if status.byte == 1 {
			value = read_text(status.rest)
			if !value.rest.is_empty() {
				crash "malformed storage payload: trailing bytes"
			}

			StorageValue(value.value)
		} else if status.byte == 2 {
			message = read_text(status.rest)
			if !message.rest.is_empty() {
				crash "malformed storage payload: trailing bytes"
			}

			StorageUnavailable(message.value)
		} else {
			crash "malformed storage payload: unknown status"
		}
	}

	## Current browser location, seeded from the host's startup snapshot.
	location : () -> Signal(Location)
	location = || {
		token : Box(U64)
		token = Node.new_token()
		location_cap = Capability.new()
		payload_cap = Capability.new()

		from_payload : HostValue -> HostValue
		from_payload = |payload_hv| {
			payload_bytes : List(U8)
			payload_bytes = Box.unbox(Capability.take(payload_hv, payload_cap))
			Capability.store(Box.box(decode_location_payload(payload_bytes)), location_cap)
		}

		Signal.from_expr(
			Node.SignalExpr.LocationSource(
				token,
				Box.box(from_payload),
				Capability.handle(location_cap),
				Capability.handle(payload_cap),
			),
			location_cap,
		)
	}

	## Current page visibility, seeded from the host's startup snapshot and
	## refreshed on browser `visibilitychange`.
	visibility : () -> Signal(Visibility)
	visibility = || {
		token : Box(U64)
		token = Node.new_token()
		visibility_cap = Capability.new()
		payload_cap = Capability.new()

		from_payload : HostValue -> HostValue
		from_payload = |payload_hv| {
			payload_bytes : List(U8)
			payload_bytes = Box.unbox(Capability.take(payload_hv, payload_cap))
			Capability.store(Box.box(decode_visibility_payload(payload_bytes)), visibility_cap)
		}

		Signal.from_expr(
			Node.SignalExpr.VisibilitySource(
				token,
				Box.box(from_payload),
				Capability.handle(visibility_cap),
				Capability.handle(payload_cap),
			),
			visibility_cap,
		)
	}

	## Browser online status, seeded from the host's startup snapshot and
	## refreshed on browser `online` / `offline` events.
	online : () -> Signal(Bool)
	online = || {
		token : Box(U64)
		token = Node.new_token()
		online_cap = Capability.new()
		payload_cap = Capability.new()

		from_payload : HostValue -> HostValue
		from_payload = |payload_hv| {
			payload_bytes : List(U8)
			payload_bytes = Box.unbox(Capability.take(payload_hv, payload_cap))
			Capability.store(Box.box(decode_online_payload(payload_bytes)), online_cap)
		}

		Signal.from_expr(
			Node.SignalExpr.OnlineSource(
				token,
				Box.box(from_payload),
				Capability.handle(online_cap),
				Capability.handle(payload_cap),
			),
			online_cap,
		)
	}

	storage_text : U64, Str -> Signal(StorageText)
	storage_text = |area, key| {
		token : Box(U64)
		token = Node.new_token()
		storage_cap = Capability.new()
		payload_cap = Capability.new()

		from_payload : HostValue -> HostValue
		from_payload = |payload_hv| {
			payload_bytes : List(U8)
			payload_bytes = Box.unbox(Capability.take(payload_hv, payload_cap))
			Capability.store(Box.box(decode_storage_payload(payload_bytes)), storage_cap)
		}

		Signal.from_expr(
			Node.SignalExpr.StorageSource(
				token,
				area,
				key,
				Box.box(from_payload),
				Capability.handle(storage_cap),
				Capability.handle(payload_cap),
			),
			storage_cap,
		)
	}

	## Text value for a declared localStorage key, seeded at mount.
	local_storage_text : Str -> Signal(StorageText)
	local_storage_text = |key| storage_text(local_storage_area, key)

	## Text value for a declared sessionStorage key, seeded at mount.
	session_storage_text : Str -> Signal(StorageText)
	session_storage_text = |key| storage_text(session_storage_area, key)

	## Push a new URL into browser history.
	push_state : Location -> Node.Cmd
	push_state = |next| Node.Cmd.PushState(next)

	## Replace the current browser history entry.
	replace_state : Location -> Node.Cmd
	replace_state = |next| Node.Cmd.ReplaceState(next)

	## Set the browser document title.
	set_title : Str -> Node.Cmd
	set_title = |title| Node.Cmd.SetDocumentTitle({ title: title })

	## Write a text value into localStorage.
	set_local_storage_text : Str, Str -> Node.Cmd
	set_local_storage_text = |key, value| Node.Cmd.SetStorageText({ area: local_storage_area, key, value })

	## Write a text value into sessionStorage.
	set_session_storage_text : Str, Str -> Node.Cmd
	set_session_storage_text = |key, value| Node.Cmd.SetStorageText({ area: session_storage_area, key, value })

	## Remove a key from localStorage.
	remove_local_storage : Str -> Node.Cmd
	remove_local_storage = |key| Node.Cmd.RemoveStorage({ area: local_storage_area, key })

	## Remove a key from sessionStorage.
	remove_session_storage : Str -> Node.Cmd
	remove_session_storage = |key| Node.Cmd.RemoveStorage({ area: session_storage_area, key })
}
