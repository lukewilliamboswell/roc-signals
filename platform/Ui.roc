import Elem exposing [Elem]
import HostValue exposing [HostValue]
import Capability exposing [Capability]
import EventExtraction
import EachSink
import Node
import Rows exposing [Rows]
import Signal exposing [Signal]

state_event_msg : Node.BinderRef, Node.BinderRef, Node.EventExtractionPlan, HostValue.EventReducerHandle -> Node.Msg
state_event_msg = |binder, read_binder, event_extraction_plan, payload_reducer| {
	{
		binder,
		read_binder,
		event_extraction_plan,
		payload_reducer,
	}
}

read_byte : List(U8) -> { byte : U8, rest : List(U8) }
read_byte = |bytes|
	match bytes.first() {
		Ok(byte) => { byte, rest: bytes.drop_first(1) }
		Err(_) => {
			crash "malformed key event payload: missing byte"
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

decode_key_payload : List(U8) -> { key : Str, shift_key : Bool }
decode_key_payload = |bytes| {
	key_len = read_u32_le(bytes)
	key_bytes = take_bytes(key_len.rest, key_len.value)
	shift = read_byte(key_bytes.rest)

	if !shift.rest.is_empty() {
		crash "malformed key event payload: trailing bytes"
	}

	key =
		match Str.from_utf8(key_bytes.value) {
			Ok(text) => text
			Err(_) => {
				crash "malformed key event payload: key was not UTF-8"
			}
		}

	if shift.byte == 0 {
		{ key, shift_key: False }
	} else if shift.byte == 1 {
		{ key, shift_key: True }
	} else {
		crash "malformed key event payload: invalid shift flag"
	}
}

## Dynamic structure and local state. State is introduced through an explicit
## closure binder (`Ui.state`): the binder is the construction site, which is the
## only way to give per-instance state a stable identity in pure Roc. The host
## assigns construction-order identity by walking the descriptor tree; binders are
## referenced by their scoped token, so the same helper composes correctly
## wherever it is mounted.
Ui := [].{

	## Keyboard event payload for `State.on_key`.
	KeyPayload : { key : Str, shift_key : Bool }

	## Stable keyed-row handle. A captured row remains valid for the lifetime of
	## its row scope, including when a delayed structural builder first reads it.
	Row(a) := { handle_value : U64, key_value : Str, source : Signal(a) }.{

		## Return the exact UTF-8 key supplied by the keyed collection.
		key : Row(a) -> Str
		key = |row| row.key_value

		## Return the one stable item source shared by every read of this row.
		signal : Row(a) -> Signal(a)
		signal = |row| row.source

		## Build an ordinary equality-pruned graph projection from the row source.
		map : Row(a), (a -> value) -> Signal(value)
			where [
				value.is_eq : value, value -> Bool,
			]
		map = |row, project| row.source.map(project)

		## Select this exact row key from one site-shared keyed signal.
		select : Row(a), Signal.Keyed(value) -> Signal(value)
		select = |row, keyed| keyed.for_row(row.handle_value, row.key_value)
	}

	## A handle to a state binder, given to the `Ui.state` body. `signal` reads the
	## current value; event methods build `Node.Msg` reducers for DOM payloads.
	State(a) := { ref : Node.BinderRef, cap : Capability(a) }.{

		## Read this state as a signal.
		signal : State(a) -> Signal(a)
		signal = |st| Signal.from_expr(Node.SignalExpr.Ref(st.ref), st.cap)

		## Build a unit-triggered reducer message: `f` maps the current value to the
		## next value, ignoring the unit payload.
		on_unit : State(a), (a -> a) -> Node.Msg
		on_unit = |st, f| {
			current_cap = st.cap

			## Keep the host's unit extraction payload inhabited across the erased ABI.
			payload_cap : Capability({})
			payload_cap = Capability.new()
			wrapped : HostValue, HostValue, HostValue -> HostValue
			wrapped = |current_hv, _read_hv, _payload_hv| {
				current : a
				current = Box.unbox(Capability.get(current_hv, current_cap))
				next : a
				next = f(current)
				Capability.store(Box.box(next), current_cap)
			}
			state_event_msg(
				st.ref,
				st.ref,
				EventExtraction.unit,
				{ capability: Capability.handle(payload_cap), read_capability: Capability.handle(current_cap), transform: Box.box(wrapped) },
			)
		}

		## Build a text-input reducer message using the event target value.
		on_str : State(a), (a, Str -> a) -> Node.Msg
		on_str = |st, f| {
			current_cap = st.cap
			payload_cap = Capability.new()
			wrapped : HostValue, HostValue, HostValue -> HostValue
			wrapped = |current_hv, _read_hv, payload_hv| {
				current : a
				current = Box.unbox(Capability.get(current_hv, current_cap))
				payload : Str
				payload = Box.unbox(Capability.get(payload_hv, payload_cap))
				next : a
				next = f(current, payload)
				Capability.store(Box.box(next), current_cap)
			}
			state_event_msg(
				st.ref,
				st.ref,
				EventExtraction.target_value,
				{ capability: Capability.handle(payload_cap), read_capability: Capability.handle(current_cap), transform: Box.box(wrapped) },
			)
		}

		## Build a checkbox reducer message using the event target checked state.
		on_bool : State(a), (a, Bool -> a) -> Node.Msg
		on_bool = |st, f| {
			current_cap = st.cap
			payload_cap = Capability.new()
			wrapped : HostValue, HostValue, HostValue -> HostValue
			wrapped = |current_hv, _read_hv, payload_hv| {
				current : a
				current = Box.unbox(Capability.get(current_hv, current_cap))
				payload : Bool
				payload = Box.unbox(Capability.get(payload_hv, payload_cap))
				next : a
				next = f(current, payload)
				Capability.store(Box.box(next), current_cap)
			}
			state_event_msg(
				st.ref,
				st.ref,
				EventExtraction.target_checked,
				{ capability: Capability.handle(payload_cap), read_capability: Capability.handle(current_cap), transform: Box.box(wrapped) },
			)
		}

		## Build a custom-event reducer message using `event.detail` serialized as text.
		on_detail : State(a), (a, Str -> a) -> Node.Msg
		on_detail = |st, f| {
			current_cap = st.cap
			payload_cap = Capability.new()
			wrapped : HostValue, HostValue, HostValue -> HostValue
			wrapped = |current_hv, _read_hv, payload_hv| {
				current : a
				current = Box.unbox(Capability.get(current_hv, current_cap))
				payload : Str
				payload = Box.unbox(Capability.get(payload_hv, payload_cap))
				next : a
				next = f(current, payload)
				Capability.store(Box.box(next), current_cap)
			}
			state_event_msg(
				st.ref,
				st.ref,
				EventExtraction.detail,
				{ capability: Capability.handle(payload_cap), read_capability: Capability.handle(current_cap), transform: Box.box(wrapped) },
			)
		}

		## Build a keyboard reducer message with key text and shift-key state.
		on_key : State(a), (a, KeyPayload -> a) -> Node.Msg
		on_key = |st, f| {
			current_cap = st.cap
			payload_cap = Capability.new()
			wrapped : HostValue, HostValue, HostValue -> HostValue
			wrapped = |current_hv, _read_hv, payload_hv| {
				current : a
				current = Box.unbox(Capability.get(current_hv, current_cap))
				payload_bytes : List(U8)
				payload_bytes = Box.unbox(Capability.get(payload_hv, payload_cap))
				next : a
				next = f(current, decode_key_payload(payload_bytes))
				Capability.store(Box.box(next), current_cap)
			}
			state_event_msg(
				st.ref,
				st.ref,
				EventExtraction.key_shift,
				{ capability: Capability.handle(payload_cap), read_capability: Capability.handle(current_cap), transform: Box.box(wrapped) },
			)
		}

		## Build a unit-triggered reducer that atomically snapshots `read` while
		## writing only `st`.
		on_unit_with : State(a), State(b), (a, b -> a) -> Node.Msg
		on_unit_with = |st, read, f| {
			payload_cap : Capability({})
			payload_cap = Capability.new()
			wrapped : HostValue, HostValue, HostValue -> HostValue
			wrapped = |current_hv, read_hv, _payload_hv| {
				current = Box.unbox(Capability.get(current_hv, st.cap))
				read_value = Box.unbox(Capability.get(read_hv, read.cap))
				Capability.store(Box.box(f(current, read_value)), st.cap)
			}
			state_event_msg(st.ref, read.ref, EventExtraction.unit, { capability: Capability.handle(payload_cap), read_capability: Capability.handle(read.cap), transform: Box.box(wrapped) })
		}

		## Build a text reducer that atomically snapshots `read`.
		on_str_with : State(a), State(b), (a, b, Str -> a) -> Node.Msg
		on_str_with = |st, read, f| {
			payload_cap = Capability.new()
			wrapped : HostValue, HostValue, HostValue -> HostValue
			wrapped = |current_hv, read_hv, payload_hv| {
				current = Box.unbox(Capability.get(current_hv, st.cap))
				read_value = Box.unbox(Capability.get(read_hv, read.cap))
				payload : Str
				payload = Box.unbox(Capability.get(payload_hv, payload_cap))
				Capability.store(Box.box(f(current, read_value, payload)), st.cap)
			}
			state_event_msg(st.ref, read.ref, EventExtraction.target_value, { capability: Capability.handle(payload_cap), read_capability: Capability.handle(read.cap), transform: Box.box(wrapped) })
		}

		## Build a checkbox reducer that atomically snapshots `read`.
		on_bool_with : State(a), State(b), (a, b, Bool -> a) -> Node.Msg
		on_bool_with = |st, read, f| {
			payload_cap = Capability.new()
			wrapped : HostValue, HostValue, HostValue -> HostValue
			wrapped = |current_hv, read_hv, payload_hv| {
				current = Box.unbox(Capability.get(current_hv, st.cap))
				read_value = Box.unbox(Capability.get(read_hv, read.cap))
				payload : Bool
				payload = Box.unbox(Capability.get(payload_hv, payload_cap))
				Capability.store(Box.box(f(current, read_value, payload)), st.cap)
			}
			state_event_msg(st.ref, read.ref, EventExtraction.target_checked, { capability: Capability.handle(payload_cap), read_capability: Capability.handle(read.cap), transform: Box.box(wrapped) })
		}

		## Build a custom-detail reducer that atomically snapshots `read`.
		on_detail_with : State(a), State(b), (a, b, Str -> a) -> Node.Msg
		on_detail_with = |st, read, f| {
			payload_cap = Capability.new()
			wrapped : HostValue, HostValue, HostValue -> HostValue
			wrapped = |current_hv, read_hv, payload_hv| {
				current = Box.unbox(Capability.get(current_hv, st.cap))
				read_value = Box.unbox(Capability.get(read_hv, read.cap))
				payload : Str
				payload = Box.unbox(Capability.get(payload_hv, payload_cap))
				Capability.store(Box.box(f(current, read_value, payload)), st.cap)
			}
			state_event_msg(st.ref, read.ref, EventExtraction.detail, { capability: Capability.handle(payload_cap), read_capability: Capability.handle(read.cap), transform: Box.box(wrapped) })
		}

		## Build a key reducer that atomically snapshots `read`.
		on_key_with : State(a), State(b), (a, b, KeyPayload -> a) -> Node.Msg
		on_key_with = |st, read, f| {
			payload_cap = Capability.new()
			wrapped : HostValue, HostValue, HostValue -> HostValue
			wrapped = |current_hv, read_hv, payload_hv| {
				current = Box.unbox(Capability.get(current_hv, st.cap))
				read_value = Box.unbox(Capability.get(read_hv, read.cap))
				payload_bytes : List(U8)
				payload_bytes = Box.unbox(Capability.get(payload_hv, payload_cap))
				Capability.store(Box.box(f(current, read_value, decode_key_payload(payload_bytes))), st.cap)
			}
			state_event_msg(st.ref, read.ref, EventExtraction.key_shift, { capability: Capability.handle(payload_cap), read_capability: Capability.handle(read.cap), transform: Box.box(wrapped) })
		}

		## Build a command that replaces this state. Unlike event messages, state
		## commands can be returned from `Ui.on_change`, `Ui.on_mount`, and other
		## command-producing hooks.
		set_cmd : State(a), a -> Node.Cmd
		set_cmd = |st, next| {
			Node.Cmd.UpdateState({
				binder: st.ref,
				update: { capability: Capability.handle(st.cap), value: Capability.store(Box.box(next), st.cap) },
			})
		}
	}

	## Introduce a state binder. `init` is the initial value; `body` receives a
	## `State(a)` handle and returns the subtree built with that state in scope.
	## The host mints this binder's identity by its construction-order position.
	state : a, (State(a) -> Elem) -> Elem
		where [
			a.is_eq : a, a -> Bool,
		]
	state = |init, body| {
		cap = Capability.new()
		initial : () -> HostValue
		initial = || Capability.store(Box.box(init), cap)
		initial_box = Box.box(initial)
		handle : State(a)
		handle = { ref: Node.BinderRef.BinderRef(initial_box), cap }
		child = body(handle)
		Elem.State({
			binder: handle.ref,
			initial: initial_box,
			cap: Capability.handle(cap),
			child: Box.box(child),
		})
	}

	## Introduce a reusable local scope. State/when/each ordinals inside the body
	## are local to this component instance instead of consuming the caller's
	## identity sequence.
	component : (() -> Elem) -> Elem
	component = |body| Elem.Component({ child: Box.box(body()) })

	## Run a command whenever the signal publishes a changed value.
	on_change : Signal(a), (a -> Node.Cmd) -> Elem
	on_change = |signal, to_cmd| {
		cap = signal.cap
		wrapped : HostValue -> Node.Cmd
		wrapped = |value| {
			typed : a
			typed = Box.unbox(Capability.get(value, cap))
			to_cmd(typed)
		}
		Elem.OnChange({ signal: Signal.to_expr(signal), to_cmd: Box.box(wrapped) })
	}

	## Run a command with the first mounted signal value and later changed values.
	on_change_initial : Signal(a), (a -> Node.Cmd) -> Elem
	on_change_initial = |signal, to_cmd| {
		cap = signal.cap
		wrapped : HostValue -> Node.Cmd
		wrapped = |value| {
			typed : a
			typed = Box.unbox(Capability.get(value, cap))
			to_cmd(typed)
		}
		Elem.OnChangeInitial({ signal: Signal.to_expr(signal), to_cmd: Box.box(wrapped) })
	}

	## Run a command when the owning scope first mounts.
	on_mount : (() -> Node.Cmd) -> Elem
	on_mount = |to_cmd| Elem.OnMount({ to_cmd: Box.box(to_cmd) })

	## Register cleanup work for when the owning scope is disposed.
	on_cleanup : Node.Cleanup -> Elem
	on_cleanup = |cleanup| Elem.Cleanup({ cleanup: cleanup })

	## Select one lazy branch from a signal value. The host retains `build`, runs it
	## only for the live case, and replaces the owned branch scope when the case
	## changes.
	switch : Signal(case), (case -> Elem) -> Elem
		where [
			case.is_eq : case, case -> Bool,
		]
	switch = |condition, build| {
		case_cap = condition.cap
		build_hv : HostValue -> Elem
		build_hv = |value| {
			case_value : case
			case_value = Box.unbox(Capability.take(value, case_cap))
			build(case_value)
		}
		Elem.When({
			condition: Signal.to_expr(condition),
			ops: {
				case_capability: Capability.handle(case_cap),
				build: Box.box(build_hv),
			},
		})
	}

	## Boolean specialization of `Ui.switch`. Neither branch builder runs until
	## the host selects it.
	when : Signal(Bool), (() -> Elem), (() -> Elem) -> Elem
	when = |condition, when_true, when_false|
		Ui.switch(
			condition,
			|selected| if selected {
				when_true()
			} else {
				when_false()
			},
		)

	## Keyed rows with exact UTF-8 identity. App-compiled adapters consume an
	## independently owned generation clone and write authenticated metadata,
	## snapshots, deltas, and selected comparisons into preallocated host sinks.
	each : Signal(Rows(item)), (Row(item) -> Elem) -> Elem
		where [
			item.is_eq : item, item -> Bool,
		]
	each = |rows, row| {
		rows_cap = rows.cap
		item_cap = Capability.new()
		read_rows : HostValue -> Rows(item)
		read_rows = |rows_hv| {
			typed_rows : Rows(item)
			typed_rows = Box.unbox(Capability.take(rows_hv, rows_cap))
			typed_rows
		}
		describe_hv : HostValue, U64 -> U64
		describe_hv = |owner, initial_token| {
			description = Rows.platform_description(read_rows(owner))
			match description.kind {
				Snapshot => EachSink.push_snapshot_description!(initial_token, description.generation, description.item_count, description.snapshot_key_bytes)
				Delta => {
					parent =
						match description.parent {
							NoParent => crash "Rows delta generation did not retain its parent identity"
							Parent(parent_token) => parent_token
						}
					EachSink.push_delta_description!(initial_token, description.generation, parent, description.item_count, description.snapshot_key_bytes, description.op_count, description.delta_key_count, description.delta_key_bytes)
				}
			}
		}
		copy_snapshot_hv : HostValue, U64 -> U64
		copy_snapshot_hv = |owner, initial_token|
			Rows.platform_copy_snapshot(
				read_rows(owner),
				initial_token,
				|token, index, slot, key| EachSink.push_snapshot!(token, index, slot, key),
			)
		copy_delta_hv : HostValue, U64 -> U64
		copy_delta_hv = |owner, initial_token| {
			typed_rows = read_rows(owner)
			Rows.platform_copy_delta(
				typed_rows,
				initial_token,
				|token, transition|
					match transition {
						ClearRows => EachSink.push_delta_clear!(token, 0)
						InsertRow({ op_index, before_slot, slot, key }) => EachSink.push_delta_insert!(token, op_index, before_slot, slot, key)
						MoveRows({ op_index, first_slot, count, before_slot }) => EachSink.push_delta_move_range!(token, op_index, first_slot, count, before_slot)
						RemoveRows({ op_index, first_slot, count }) => EachSink.push_delta_remove_range!(token, op_index, first_slot, count)
						UpdateRow({ op_index, slot, key }) => EachSink.push_delta_update!(token, op_index, slot, key)
					},
			)
		}
		compare_slots_hv : HostValue, HostValue, List(U64), U64 -> U64
		compare_slots_hv = |old_owner, new_owner, pairs, initial_token| {
			old_rows = read_rows(old_owner)
			new_rows = read_rows(new_owner)
			if pairs.len() % 2 != 0 {
				crash "Rows comparison pairs must be interleaved"
			}
			var $pair_index = 0
			var $result_index = 0
			var $token = initial_token
			while $pair_index < pairs.len() {
				old_slot = pairs.get($pair_index) ?? crash "missing old Rows slot"
				new_slot = pairs.get($pair_index + 1) ?? crash "missing new Rows slot"
				old_item = Rows.platform_item_for_slot(old_rows, old_slot) ?? crash "old Rows slot was not live"
				new_item = Rows.platform_item_for_slot(new_rows, new_slot) ?? crash "new Rows slot was not live"
				$token = EachSink.push_bool!($token, $result_index, old_item.is_eq(new_item))
				$pair_index = $pair_index + 2
				$result_index = $result_index + 1
			}
			$token
		}
		clone_item_hv : HostValue, U64 -> HostValue
		clone_item_hv = |owner, slot| {
			item = Rows.platform_item_for_slot(read_rows(owner), slot) ?? crash "Rows item slot was not live"
			Capability.store(Box.box(item), item_cap)
		}
		row_hv : Str, U64 -> Elem
		row_hv = |key, row_handle| {
			row_source = || crash "row source identity callable must never be evaluated"
			row_source_box = Box.box(row_source)
			source =
				Signal.from_expr(
					Node.SignalExpr.RowSource(row_handle, row_source_box, row_source_box, Capability.handle(item_cap)),
					item_cap,
				)
			row({ handle_value: row_handle, key_value: key, source })
		}
		Elem.Each({
			rows: Signal.to_expr(rows),
			ops: {
				rows_capability: Capability.handle(rows_cap),
				item_capability: Capability.handle(item_cap),
				describe: Box.box(describe_hv),
				copy_snapshot: Box.box(copy_snapshot_hv),
				copy_delta: Box.box(copy_delta_hv),
				compare_slots: Box.box(compare_slots_hv),
				clone_item: Box.box(clone_item_hv),
				row: Box.box(row_hv),
			},
		})
	}
}
