app [main] { pf: platform "../../platform/main.roc" }

import pf.Elem exposing [Elem]
import pf.Html
import pf.Signal
import pf.Ui

page_class = "grid gap-5"

hero_class = "panel grid gap-2 p-5"

panel_class = "panel grid gap-3 p-4"

row_class = "flex flex-wrap items-center gap-2 rounded border border-zinc-200 p-2"

input_class = "rounded-md border border-zinc-300 bg-white px-2 py-1 text-sm"

## Minutes in one week. Every instant in this app is an offset from Monday
## 00:00 UTC, as an integer number of minutes. No floats, no date library.
week_minutes : U64
week_minutes = 10080

## Timezone offsets are stored biased by `offset_base` so that every arithmetic
## step stays inside `U64`. A zone's real offset is `shift - offset_base`
## minutes; this Roc build has no `U64 -> I64` conversion, so the bias is how a
## negative UTC offset is represented without signed arithmetic.
offset_base : U64
offset_base = 1440

Parsed := [Bad, Minutes(U64)]

Status := [Unmarked, Available, Busy].{
	is_eq : Status, Status -> Bool
	is_eq = |left, right|
		match left {
			Unmarked => match right {
				Unmarked => True
				_ => False
			}
			Available => match right {
				Available => True
				_ => False
			}
			Busy => match right {
				Busy => True
				_ => False
			}
		}
}

## One commitment on the week. `abs_start` is UTC minutes-from-Monday-00:00, so
## it is timezone independent; only its *rendering* depends on the chosen zone.
Slot : { id : Str, title : Str, abs_start : U64, duration : U64, status : Status }

## A timezone the picker can display. `shift` is biased (see `offset_base`).
Zone : { id : Str, label : Str, shift : U64 }

## The add-a-slot form. `abs_start` is recomputed on every field edit from the
## day, the typed local time, and the *currently selected zone*, which is why
## its reducers read the zone handle atomically with `on_str_with`.
Draft : { title : Str, day : Str, start_text : Str, duration : Str, abs_start : U64, valid : Bool }

## What one rendered row shows. Everything here is derived; nothing is stored.
RowView : { id : Str, title : Str, when : Str, status : Str, conflict : Str }

zones : List(Zone)
zones = [
	{ id: "utc", label: "UTC+00:00", shift: offset_base },
	{ id: "nyc", label: "New York UTC-05:00", shift: 1140 },
	{ id: "berlin", label: "Berlin UTC+01:00", shift: 1500 },
	{ id: "kolkata", label: "Kolkata UTC+05:30", shift: 1770 },
	{ id: "auckland", label: "Auckland UTC+13:00", shift: 2220 },
]

zone_by_id : Str -> Zone
zone_by_id = |id|
	match zones.find_first(|zone| zone.id == id) {
		Ok(zone) => zone
		Err(_) => { id: "utc", label: "UTC+00:00", shift: offset_base }
	}

day_names : List(Str)
day_names = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

day_name : U64 -> Str
day_name = |index|
	match day_names.get(index) {
		Ok(name) => name
		Err(_) => "???"
	}

day_index : Str -> U64
day_index = |name| {
	var $index = 0
	var $found = 0
	while $index < day_names.len() {
		if day_name($index) == name {
			$found = $index
		} else {
		}
		$index = $index + 1
	}
	$found
}

pad2 : U64 -> Str
pad2 = |value| if value < 10 { "0${value.to_str()}" } else { value.to_str() }

clock : U64 -> Str
clock = |minute_of_day| "${pad2(minute_of_day // 60)}:${pad2(minute_of_day % 60)}"

## Convert a UTC week-minute into the same instant expressed in `zone`.
## `offset_base` is subtracted after adding a whole week so the sum never goes
## below zero, which is what keeps the whole pipeline in `U64`.
local_of : U64, Zone -> U64
local_of = |abs_start, zone| (abs_start + zone.shift + week_minutes - offset_base) % week_minutes

## "Tue 12:30-13:30". A slot whose end crosses local midnight simply shows the
## wrapped end time; the stored instant is unchanged.
span_text : Slot, Zone -> Str
span_text = |slot, zone| {
	local = local_of(slot.abs_start, zone)
	finish = (local + slot.duration) % week_minutes
	"${day_name(local // 1440)} ${clock(local % 1440)}-${clock(finish % 1440)}"
}

status_text : Status -> Str
status_text = |status|
	match status {
		Unmarked => "Unmarked"
		Available => "Available"
		Busy => "Busy"
	}

is_busy : Status -> Bool
is_busy = |status|
	match status {
		Busy => True
		_ => False
	}

is_available : Status -> Bool
is_available = |status|
	match status {
		Available => True
		_ => False
	}

## Two commitments clash when both are marked busy and their half-open minute
## intervals overlap. Intervals are compared on the linear week line, so a slot
## that runs past Sunday midnight does not wrap around to Monday.
overlaps : Slot, Slot -> Bool
overlaps = |left, right|
	left.abs_start < right.abs_start + right.duration and right.abs_start < left.abs_start + left.duration

## Fan-in over slot pairs: every busy slot is checked against every other busy
## slot. Timezone independent by construction, because it compares instants.
conflict_ids : List(Slot) -> List(Str)
conflict_ids = |slots| {
	busy = slots.keep_if(|slot| is_busy(slot.status))
	busy.keep_if(|left| busy.any(|right| right.id != left.id and overlaps(left, right))).map(|slot| slot.id)
}

available_minutes : List(Slot) -> U64
available_minutes = |slots| slots.keep_if(|slot| is_available(slot.status)).map(|slot| slot.duration).sum()

duration_text : U64 -> Str
duration_text = |minutes| "${(minutes // 60).to_str()}h ${(minutes % 60).to_str()}m"

## Days that have no available slot *in the displayed zone*. This is the second
## place a timezone change is visible: moving a slot across local midnight moves
## which day counts as free.
free_days : List(Slot), Zone -> Str
free_days = |slots, zone| {
	covered = slots.keep_if(|slot| is_available(slot.status)).map(|slot| local_of(slot.abs_start, zone) // 1440)
	names = day_names.keep_if(|name| !covered.contains(day_index(name)))
	if names.is_empty() {
		"Every day has availability"
	} else {
		Str.join_with(names, ", ")
	}
}

row_views : List(Slot), Zone, List(Str) -> List(RowView)
row_views = |slots, zone, conflicts|
	slots.map(
		|slot| {
			id: slot.id,
			title: slot.title,
			when: span_text(slot, zone),
			status: status_text(slot.status),
			conflict: if conflicts.contains(slot.id) { "Conflict" } else { "Clear" },
		},
	)

slot_at : List(Slot), U64 -> Slot
slot_at = |slots, index|
	match slots.get(index) {
		Ok(slot) => slot
		Err(_) => { id: "", title: "", abs_start: 0, duration: 0, status: Status.Unmarked }
	}

index_of_id : List(Slot), Str -> U64
index_of_id = |slots, id| {
	var $index = 0
	var $found = 0
	while $index < slots.len() {
		if slot_at(slots, $index).id == id {
			$found = $index
		} else {
		}
		$index = $index + 1
	}
	$found
}

## Swap a slot with the one before it. Reordering keeps every row key, so the
## reconciler moves rows rather than rebuilding them.
move_earlier : List(Slot), Str -> List(Slot)
move_earlier = |slots, id| {
	index = index_of_id(slots, id)
	if index == 0 {
		slots
	} else {
		var $out = []
		var $cursor = 0
		while $cursor < slots.len() {
			pick =
				if $cursor == index - 1 {
					index
				} else if $cursor == index {
					index - 1
				} else {
					$cursor
				}
			$out = $out.append(slot_at(slots, pick))
			$cursor = $cursor + 1
		}
		$out
	}
}

set_status : List(Slot), Str, Status -> List(Slot)
set_status = |slots, id, status|
	slots.map(|slot| if slot.id == id { { ..slot, status } } else { slot })

digits_value : List(U8) -> U64
digits_value = |bytes| bytes.fold(0, |acc, byte| acc * 10 + U8.to_u64(byte) - 48)

all_digits : List(U8) -> Bool
all_digits = |bytes| !bytes.is_empty() and bytes.all(|byte| byte >= 48 and byte <= 57)

## Parse "HH:MM" into minutes-from-midnight. `Bad` for anything that is not two
## digit groups in range.
parse_clock : Str -> Parsed
parse_clock = |text| {
	parts = text.split_on(":")
	if parts.len() != 2 {
		Parsed.Bad
	} else {
		hours_bytes = match parts.get(0) {
			Ok(value) => value.to_utf8()
			Err(_) => []
		}
		minutes_bytes = match parts.get(1) {
			Ok(value) => value.to_utf8()
			Err(_) => []
		}
		if all_digits(hours_bytes) and all_digits(minutes_bytes) {
			hours = digits_value(hours_bytes)
			minutes = digits_value(minutes_bytes)
			if hours < 24 and minutes < 60 {
				Parsed.Minutes(hours * 60 + minutes)
			} else {
				Parsed.Bad
			}
		} else {
			Parsed.Bad
		}
	}
}

parse_duration : Str -> Parsed
parse_duration = |text| {
	bytes = text.to_utf8()
	if all_digits(bytes) {
		minutes = digits_value(bytes)
		if minutes > 0 and minutes <= 720 {
			Parsed.Minutes(minutes)
		} else {
			Parsed.Bad
		}
	} else {
		Parsed.Bad
	}
}

clock_ok : Str -> Bool
clock_ok = |text|
	match parse_clock(text) {
		Minutes(_) => True
		Bad => False
	}

duration_ok : Str -> Bool
duration_ok = |text|
	match parse_duration(text) {
		Minutes(_) => True
		Bad => False
	}

empty_draft : Draft
empty_draft = { title: "", day: "Mon", start_text: "09:00", duration: "30", abs_start: 540, valid: False }

## Re-derive the draft's stored instant from its local fields plus the zone the
## user is currently looking at. The typed time is a *local* wall clock, so the
## zone has to be read at the moment the field changes.
reprice : Draft, Zone -> Draft
reprice = |draft, zone| {
	valid = !draft.title.is_empty() and clock_ok(draft.start_text) and duration_ok(draft.duration)
	local_minute =
		match parse_clock(draft.start_text) {
			Minutes(minute) => minute
			Bad => 0
		}
	local = day_index(draft.day) * 1440 + local_minute
	# Inverse of `local_of`: go from the displayed local instant back to UTC.
	abs_start = (local + week_minutes + offset_base - zone.shift) % week_minutes
	{ ..draft, abs_start, valid }
}

draft_status : Draft -> Str
draft_status = |draft|
	if draft.title.is_empty() {
		"Enter a name for the new slot"
	} else if !clock_ok(draft.start_text) {
		"Start time must be HH:MM"
	} else if !duration_ok(draft.duration) {
		"Length must be 1-720 minutes"
	} else {
		"Ready to add ${draft.title}"
	}

slot_id_of : List(Slot) -> Str
slot_id_of = |slots| {
	base = "s${(slots.len() + 1).to_str()}"
	if slots.any(|slot| slot.id == base) {
		"${base}x${slots.len().to_str()}"
	} else {
		base
	}
}

add_slot : List(Slot), Draft -> List(Slot)
add_slot = |slots, draft|
	if draft.valid {
		duration =
			match parse_duration(draft.duration) {
				Minutes(value) => value
				Bad => 30
			}
		slots.append({ id: slot_id_of(slots), title: draft.title, abs_start: draft.abs_start, duration, status: Status.Unmarked })
	} else {
		slots
	}

initial_slots : List(Slot)
initial_slots = [
	{ id: "sunrise", title: "Sunrise block", abs_start: 0, duration: 60, status: Status.Available },
	{ id: "standup", title: "Standup", abs_start: 540, duration: 30, status: Status.Busy },
	{ id: "review", title: "Design review", abs_start: 555, duration: 60, status: Status.Unmarked },
	{ id: "midnight", title: "Late shift", abs_start: 1410, duration: 30, status: Status.Unmarked },
	{ id: "focus", title: "Wednesday focus", abs_start: 3600, duration: 120, status: Status.Available },
]

render_row : Ui.State(List(Slot)), Str, Signal.Signal(RowView) -> Elem
render_row = |slots, key, row|
	Html.section(
		"Slot ${key}",
		[Html.class_attr(row_class), Html.test_id("row-${key}")],
		[
			Html.paragraph_s_attrs(Signal.map(row, |view| view.title), [Html.test_id("title-${key}")]),
			Html.paragraph_s_attrs(Signal.map(row, |view| view.when), [Html.test_id("when-${key}")]),
			Html.paragraph_s_attrs(Signal.map(row, |view| view.status), [Html.test_id("status-${key}")]),
			Html.paragraph_s_attrs(Signal.map(row, |view| view.conflict), [Html.test_id("conflict-${key}")]),
			Html.button("Mark ${key} available", slots.on_unit(|list| set_status(list, key, Status.Available))),
			Html.button("Mark ${key} busy", slots.on_unit(|list| set_status(list, key, Status.Busy))),
			Html.button("Move ${key} earlier", slots.on_unit(|list| move_earlier(list, key))),
			Html.button("Remove ${key}", slots.on_unit(|list| list.drop_if(|slot| slot.id == key))),
		],
	)

week_panel : Ui.State(List(Slot)), Signal.Signal(List(RowView)) -> Elem
week_panel = |slots, rows|
	Html.section_c(
		"Week",
		panel_class,
		[
			Html.heading_c("Week", "text-xl font-semibold"),
			Ui.each_str(rows, |view| view.id, |key, row| render_row(slots, key, row)),
		],
	)

add_panel : Ui.State(Draft), Ui.State(Zone), Ui.State(List(Slot)), Signal.Signal(Draft) -> Elem
add_panel = |draft, zone, slots, draft_signal|
	Html.section_c(
		"Add slot",
		panel_class,
		[
			Html.heading_c("Add slot", "text-xl font-semibold"),
			Html.text_input_c(
				"Slot name",
				Signal.map(draft_signal, |value| value.title),
				input_class,
				draft.on_str_with(zone, |value, current_zone, text| reprice({ ..value, title: text }, current_zone)),
			),
			Html.select_c(
				"Day",
				Signal.map(draft_signal, |value| value.day),
				input_class,
				day_names.map(|name| Html.option(name, name)),
				draft.on_str_with(zone, |value, current_zone, text| reprice({ ..value, day: text }, current_zone)),
			),
			Html.text_input_c(
				"Start time",
				Signal.map(draft_signal, |value| value.start_text),
				input_class,
				draft.on_str_with(zone, |value, current_zone, text| reprice({ ..value, start_text: text }, current_zone)),
			),
			Html.text_input_c(
				"Length",
				Signal.map(draft_signal, |value| value.duration),
				input_class,
				draft.on_str_with(zone, |value, current_zone, text| reprice({ ..value, duration: text }, current_zone)),
			),
			Html.paragraph_s_attrs(Signal.map(draft_signal, draft_status), [Html.test_id("draft-status")]),
			Html.action_button(
				Signal.const("Add slot"),
				Signal.map(draft_signal, |value| !value.valid),
				slots.on_unit_with(draft, add_slot),
			),
		],
	)

summary_panel : Signal.Signal(Str), Signal.Signal(Str), Signal.Signal(Str) -> Elem
summary_panel = |zone_label, summary, free|
	Html.section_c(
		"Summary",
		panel_class,
		[
			Html.heading_c("Summary", "text-xl font-semibold"),
			Html.paragraph_s_attrs(zone_label, [Html.test_id("zone-label")]),
			Html.paragraph_s_attrs(summary, [Html.test_id("summary")]),
			Html.paragraph_s_attrs(free, [Html.test_id("free-days")]),
		],
	)

summary_text : List(U64) -> Str
summary_text = |values| {
	minutes = match values.get(0) {
		Ok(value) => value
		Err(_) => 0
	}
	conflicts_found = match values.get(1) {
		Ok(value) => value
		Err(_) => 0
	}
	total = match values.get(2) {
		Ok(value) => value
		Err(_) => 0
	}
	"Available ${duration_text(minutes)} across ${total.to_str()} slots, ${conflicts_found.to_str()} conflicts"
}

main : () -> Elem
main = ||
	Ui.state(
		zone_by_id("utc"),
		|zone|
			Ui.state(
				initial_slots,
				|slots|
					Ui.state(
						empty_draft,
						|draft| {
							zone_signal = zone.signal()
							slots_signal = slots.signal()
							draft_signal = draft.signal()

							# chain: slots -> conflicts -> conflict_count -> combine -> summary
							conflicts = Signal.map(slots_signal, conflict_ids)
							conflict_count = Signal.map(conflicts, |ids| ids.len())
							avail_minutes = Signal.map(slots_signal, available_minutes)
							slot_count = Signal.map(slots_signal, |list| list.len())

							# fan-in A: three same-typed derived signals into one summary line
							summary = Signal.map(Signal.combine([avail_minutes, conflict_count, slot_count]), summary_text)

							# fan-in B: slots x zone x conflicts -> every rendered row
							rows =
								Signal.map(
									{ slots: slots_signal, zone: zone_signal, conflicts: conflicts }.Signal,
									|value| row_views(value.slots, value.zone, value.conflicts),
								)

							# fan-in C: slots x zone -> which local days have no availability
							free = Signal.map2(slots_signal, zone_signal, free_days)

							Html.div_c(
								page_class,
								[
									Html.section_c(
										"Availability Picker",
										hero_class,
										[
											Html.heading_c("Availability Picker", "text-3xl font-semibold"),
											Html.paragraph_c("Mark weekly slots available or busy, spot overlapping commitments, and re-read the whole week in another timezone without rebuilding a single row.", "max-w-3xl text-sm text-zinc-700"),
										],
									),
									Html.select_c(
										"Timezone",
										Signal.map(zone_signal, |value| value.id),
										input_class,
										zones.map(|item| Html.option(item.id, item.label)),
										zone.on_str(|_, text| zone_by_id(text)),
									),
									summary_panel(Signal.map(zone_signal, |value| "Timezone: ${value.label}"), summary, free),
									week_panel(slots, rows),
									add_panel(draft, zone, slots, draft_signal),
									# Clearing the form is a side effect of the slot list changing,
									# not something derivable from the draft, so it is a command.
									Ui.on_change(slot_count, |_| draft.set_cmd(empty_draft)),
								],
							)
						},
					),
			),
	)
