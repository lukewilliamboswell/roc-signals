app [main] { pf: platform "../../platform/main.roc" }

import pf.Elem exposing [Elem]
import pf.Html
import pf.Signal
import pf.Ui

page_class = "app-shell app-shell-wide"

panel_class = "panel"

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

## A day column of the week. The form's `<select>` is bound to `to_str`, so the
## wire value the browser hands back is parsed into a tag at that one edge and
## every column decision inside the app is a `match`, never a string compare.
Day := [Mon, Tue, Wed, Thu, Fri, Sat, Sun].{
	is_eq : Day, Day -> Bool
	is_eq = |left, right|
		match (left, right) {
			(Mon, Mon) => True
			(Tue, Tue) => True
			(Wed, Wed) => True
			(Thu, Thu) => True
			(Fri, Fri) => True
			(Sat, Sat) => True
			(Sun, Sun) => True
			_ => False
		}

	to_str : Day -> Str
	to_str = |day|
		match day {
			Mon => "Mon"
			Tue => "Tue"
			Wed => "Wed"
			Thu => "Thu"
			Fri => "Fri"
			Sat => "Sat"
			Sun => "Sun"
		}

	## Which of the seven columns this day is, counting from Monday.
	index : Day -> U64
	index = |day|
		match day {
			Mon => 0
			Tue => 1
			Wed => 2
			Thu => 3
			Fri => 4
			Sat => 5
			Sun => 6
		}

	from_index : U64 -> Try(Day, [NotADay])
	from_index = |column|
		match column {
			0 => Ok(Mon)
			1 => Ok(Tue)
			2 => Ok(Wed)
			3 => Ok(Thu)
			4 => Ok(Fri)
			5 => Ok(Sat)
			6 => Ok(Sun)
			_ => Err(NotADay)
		}

	## Parse once, at the edge where the `<select>` hands us its wire value.
	from_str : Str -> Try(Day, [NotADay])
	from_str = |text|
		match text {
			"Mon" => Ok(Mon)
			"Tue" => Ok(Tue)
			"Wed" => Ok(Wed)
			"Thu" => Ok(Thu)
			"Fri" => Ok(Fri)
			"Sat" => Ok(Sat)
			"Sun" => Ok(Sun)
			_ => Err(NotADay)
		}
}

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

## Whether a rendered block is in a clash, and with what. The note's text and
## the note's class both come off this one tag, so a block can never be tinted
## for a clash it is not in, or announce a clash with nobody.
Clash := [NoClash, ClashesWith(List(Str))].{
	is_eq : Clash, Clash -> Bool
	is_eq = |left, right|
		match (left, right) {
			(NoClash, NoClash) => True
			(ClashesWith(left_names), ClashesWith(right_names)) => left_names == right_names
			_ => False
		}

	to_str : Clash -> Str
	to_str = |clash|
		match clash {
			NoClash => ""
			ClashesWith(names) => "Clashes with ${Str.join_with(names, ", ")}"
		}
}

## The banner above the grid: either nothing to say, or every commitment
## currently in a clash.
Banner := [Settled, Overlapping(List(Str))].{
	is_eq : Banner, Banner -> Bool
	is_eq = |left, right|
		match (left, right) {
			(Settled, Settled) => True
			(Overlapping(left_titles), Overlapping(right_titles)) => left_titles == right_titles
			_ => False
		}

	to_str : Banner -> Str
	to_str = |banner|
		match banner {
			Settled => ""
			Overlapping(titles) => "${titles.len().to_str()} overlapping commitments: ${Str.join_with(titles, ", ")}"
		}
}

## One commitment on the week. `abs_start` is UTC minutes-from-Monday-00:00, so
## it is timezone independent; only its *rendering* depends on the chosen zone.
Slot : { id : Str, title : Str, abs_start : U64, duration : U64, status : Status }

## A timezone the picker can display. `shift` is biased (see `offset_base`).
Zone : { id : Str, label : Str, shift : U64 }

## What a valid draft resolves to: the instant it would be stored at, and how
## long it runs. Only ever reached through `Draft.plan`, so an unparseable form
## has no readable `abs_start` at all.
Plan : { abs_start : U64, duration : U64 }

## Why the add form is not ready, when it is not. Both the sentence under the
## form and its tone are derived from this tag, so the message and the colour
## cannot disagree.
DraftError := [MissingTitle, BadStart, BadLength].{
	is_eq : DraftError, DraftError -> Bool
	is_eq = |left, right|
		match (left, right) {
			(MissingTitle, MissingTitle) => True
			(BadStart, BadStart) => True
			(BadLength, BadLength) => True
			_ => False
		}
}

## The add-a-slot form. `plan` is recomputed on every field edit from the day,
## the typed local time, and the *currently selected zone*, which is why its
## reducers read the zone handle atomically with `on_str_with`.
Draft : { title : Str, day : Day, start_text : Str, duration : Str, plan : Try(Plan, DraftError) }

## What one rendered slot block shows. Everything here is derived; nothing is
## stored. `day` is the *local* day column the block lands in, so it moves when
## the zone changes; `conflict` names the commitments this one clashes with.
RowView : { id : Str, title : Str, when : Str, day : Day, status : Status, conflict : Clash }

zones : List(Zone)
zones = [
	{ id: "utc", label: "UTC+00:00", shift: offset_base },
	{ id: "nyc", label: "New York UTC-05:00", shift: 1140 },
	{ id: "berlin", label: "Berlin UTC+01:00", shift: 1500 },
	{ id: "kolkata", label: "Kolkata UTC+05:30", shift: 1770 },
	{ id: "auckland", label: "Auckland UTC+13:00", shift: 2220 },
]

zone_by_id : Str -> Zone
zone_by_id = |id| zones.find_first(|zone| zone.id == id) ?? { id: "utc", label: "UTC+00:00", shift: offset_base }

## The seven day columns, in order, so the header strip can be rendered by
## walking the days themselves rather than by index arithmetic over names.
days : List(Day)
days = [Day.Mon, Day.Tue, Day.Wed, Day.Thu, Day.Fri, Day.Sat, Day.Sun]

## The column a week-minute lands in, as a label. Out-of-week indices cannot
## happen once a minute has been reduced modulo the week, but the fallback is
## kept so the renderer is total.
day_label : U64 -> Str
day_label = |index| Try.map_ok(Day.from_index(index), Day.to_str) ?? "???"

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
	"${day_label(local // 1440)} ${clock(local % 1440)}-${clock(finish % 1440)}"
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

## The other commitments this one collides with, by name. The grid shows the
## names instead of a bare "Conflict", so the clash reads without any
## cross-referencing.
conflict_of : List(Slot), List(Str), Slot -> Clash
conflict_of = |slots, ids, slot|
	if !ids.contains(slot.id) {
		Clash.NoClash
	} else {
		Clash.ClashesWith(slots.keep_if(|other| other.id != slot.id and is_busy(other.status) and overlaps(slot, other)).map(|other| other.title))
	}

conflict_banner : List(Slot), List(Str) -> Banner
conflict_banner = |slots, ids| {
	titles = slots.keep_if(|slot| ids.contains(slot.id)).map(|slot| slot.title)
	if titles.is_empty() {
		Banner.Settled
	} else {
		Banner.Overlapping(titles)
	}
}

available_minutes : List(Slot) -> U64
available_minutes = |slots| slots.keep_if(|slot| is_available(slot.status)).map(|slot| slot.duration).sum()

duration_text : U64 -> Str
duration_text = |minutes| "${(minutes // 60).to_str()}h ${(minutes % 60).to_str()}m"

## Days that have no available slot *in the displayed zone*. This is the second
## place a timezone change is visible: moving a slot across local midnight moves
## which day counts as free.
free_days : List(Slot), Zone -> List(Day)
free_days = |slots, zone| {
	covered = slots.keep_if(|slot| is_available(slot.status)).map(|slot| local_of(slot.abs_start, zone) // 1440)
	days.keep_if(|day| !covered.contains(Day.index(day)))
}

free_text : List(Day) -> Str
free_text = |free|
	if free.is_empty() {
		"None"
	} else {
		Str.join_with(free.map(Day.to_str), ", ")
	}

row_views : List(Slot), Zone, List(Str) -> List(RowView)
row_views = |slots, zone, conflicts|
	slots.map(
		|slot| {
			local = local_of(slot.abs_start, zone)
			{
				id: slot.id,
				title: slot.title,
				when: span_text(slot, zone),
				day: Day.from_index(local // 1440) ?? Day.Mon,
				status: slot.status,
				conflict: conflict_of(slots, conflicts, slot),
			}
		},
	)

# --- presentation -------------------------------------------------------------

## Which of the seven day columns a block sits in. Spelled out one class per day
## so Tailwind's source scan finds every literal.
day_column_class : Day -> Str
day_column_class = |day|
	match day {
		Mon => "sm:col-start-1"
		Tue => "sm:col-start-2"
		Wed => "sm:col-start-3"
		Thu => "sm:col-start-4"
		Fri => "sm:col-start-5"
		Sat => "sm:col-start-6"
		Sun => "sm:col-start-7"
	}

## The block's colour and its column both come off the same row signal, so a
## block can never be tinted for a status it no longer has, or sit under the
## wrong day after a timezone change.
slot_class : RowView -> Str
slot_class = |view| {
	base = "card gap-1.5 p-3 ${day_column_class(view.day)}"
	match view.conflict {
		ClashesWith(_) => "${base} border-red-300 bg-red-50"
		NoClash =>
			match view.status {
				Available => "${base} border-emerald-200 bg-emerald-50"
				Busy => "${base} border-amber-200 bg-amber-50"
				Unmarked => base
			}
	}
}

status_badge_class : RowView -> Str
status_badge_class = |view|
	match view.status {
		Available => "badge badge-ok shrink-0"
		Busy => "badge badge-warn shrink-0"
		Unmarked => "badge badge-neutral shrink-0"
	}

## A block with no clash draws no note at all, rather than a blank banner.
conflict_class : RowView -> Str
conflict_class = |view|
	match view.conflict {
		NoClash => "hidden"
		ClashesWith(_) => "notice notice-error px-2 py-1 text-xs"
	}

banner_class : Banner -> Str
banner_class = |banner|
	match banner {
		Settled => "hidden"
		Overlapping(_) => "notice notice-error"
	}

## A day column whose header carries the free-day marker. The marker's text is
## constant and only its class changes, so a timezone change repaints the marker
## without any DOM text write.
day_header : Signal.Signal(List(Day)), Day -> Elem
day_header = |free_names, day| {
	name = Day.to_str(day)
	Html.div_c(
		"grid gap-1",
		[
			Html.paragraph_c(name, "panel-title"),
			Html.paragraph_attrs(
				"No availability",
				[
					Html.test_id("free-${name}"),
					Html.class_attr_s(Signal.map(free_names, |free| if free.any(|other| Day.is_eq(other, day)) { "hint italic" } else { "hidden" })),
				],
			),
		],
	)
}

## A validation note reads as a neutral requirement until the field has been
## touched, and only turns green or red once there is something to say.
draft_tone : Draft -> Str
draft_tone = |draft|
	match draft.plan {
		Ok(_) => "notice notice-ok"
		Err(error) =>
			match error {
				MissingTitle => "hint"
				_ => "notice notice-error"
			}
	}

empty_slot : Slot
empty_slot = { id: "", title: "", abs_start: 0, duration: 0, status: Status.Unmarked }

slot_at : List(Slot), U64 -> Slot
slot_at = |slots, index| slots.get(index) ?? empty_slot

index_of_id : List(Slot), Str -> U64
index_of_id = |slots, id|
	Try.map_ok(slots.map_with_index(|slot, index| { id: slot.id, index }).find_first(|entry| entry.id == id), |entry| entry.index) ?? 0

## Swap a slot with the one before it. Reordering keeps every row key, so the
## reconciler moves rows rather than rebuilding them.
move_earlier : List(Slot), Str -> List(Slot)
move_earlier = |slots, id| {
	index = index_of_id(slots, id)
	if index == 0 {
		slots
	} else {
		slots.map_with_index(
			|_, cursor|
				if cursor == index - 1 {
					slot_at(slots, index)
				} else if cursor == index {
					slot_at(slots, index - 1)
				} else {
					slot_at(slots, cursor)
				},
		)
	}
}

set_status : List(Slot), Str, Status -> List(Slot)
set_status = |slots, id, status|
	slots.map(|slot| if slot.id == id { { ..slot, status } } else { slot })

## A non-empty run of ASCII digits. The guard is what rejects "8h", "+9" and
## "", and the builtin does the actual arithmetic.
digits_only : Str -> Try(U64, [NotDigits])
digits_only = |text| {
	bytes = text.to_utf8()
	if !bytes.is_empty() and bytes.all(|byte| byte >= 48 and byte <= 57) {
		Try.map_err(U64.from_str(text), |_| NotDigits)
	} else {
		Err(NotDigits)
	}
}

## Parse "HH:MM" into minutes-from-midnight. Anything that is not two digit
## groups in range is an error, never a silently zeroed time.
parse_clock : Str -> Try(U64, [BadClock])
parse_clock = |text| {
	parts = text.split_on(":")
	if parts.len() != 2 {
		Err(BadClock)
	} else {
		hours = digits_only(parts.get(0) ?? "") ? |_| BadClock
		minutes = digits_only(parts.get(1) ?? "") ? |_| BadClock
		if hours < 24 and minutes < 60 {
			Ok(hours * 60 + minutes)
		} else {
			Err(BadClock)
		}
	}
}

parse_duration : Str -> Try(U64, [BadDuration])
parse_duration = |text| {
	minutes = digits_only(text) ? |_| BadDuration
	if minutes > 0 and minutes <= 720 {
		Ok(minutes)
	} else {
		Err(BadDuration)
	}
}

empty_draft : Draft
empty_draft = { title: "", day: Day.Mon, start_text: "09:00", duration: "30", plan: Err(DraftError.MissingTitle) }

## Re-derive what the draft would store, from its local fields plus the zone the
## user is currently looking at. The typed time is a *local* wall clock, so the
## zone has to be read at the moment the field changes. The three failure tags
## are checked in the order the form reads, top to bottom.
plan_of : Draft, Zone -> Try(Plan, DraftError)
plan_of = |draft, zone|
	if draft.title.is_empty() {
		Err(DraftError.MissingTitle)
	} else {
		local_minute = parse_clock(draft.start_text) ? |_| DraftError.BadStart
		duration = parse_duration(draft.duration) ? |_| DraftError.BadLength
		local = Day.index(draft.day) * 1440 + local_minute
		# Inverse of `local_of`: go from the displayed local instant back to UTC.
		Ok({ abs_start: (local + week_minutes + offset_base - zone.shift) % week_minutes, duration })
	}

reprice : Draft, Zone -> Draft
reprice = |draft, zone| { ..draft, plan: plan_of(draft, zone) }

draft_status : Draft -> Str
draft_status = |draft|
	match draft.plan {
		Ok(_) => "Ready to add ${draft.title}"
		Err(error) =>
			match error {
				MissingTitle => "Enter a name for the new slot"
				BadStart => "Start time must be HH:MM"
				BadLength => "Length must be 1-720 minutes"
			}
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
	match draft.plan {
		Ok(plan) => slots.append({ id: slot_id_of(slots), title: draft.title, abs_start: plan.abs_start, duration: plan.duration, status: Status.Unmarked })
		Err(_) => slots
	}

initial_slots : List(Slot)
initial_slots = [
	{ id: "sunrise", title: "Sunrise block", abs_start: 0, duration: 60, status: Status.Available },
	{ id: "standup", title: "Standup", abs_start: 540, duration: 30, status: Status.Busy },
	{ id: "review", title: "Design review", abs_start: 555, duration: 60, status: Status.Unmarked },
	{ id: "midnight", title: "Late shift", abs_start: 1410, duration: 30, status: Status.Unmarked },
	{ id: "focus", title: "Wednesday focus", abs_start: 3600, duration: 120, status: Status.Available },
]

## One block in the week grid. The visible button captions are short enough to
## fit a day column, so each one carries its full accessible name explicitly.
render_row : Ui.State(List(Slot)), Str, Signal.Signal(RowView) -> Elem
render_row = |slots, key, row|
	Html.section(
		"Slot ${key}",
		[Html.class_attr_s(Signal.map(row, slot_class)), Html.test_id("slot-${key}")],
		[
			Html.div_c(
				"flex items-start justify-between gap-2",
				[
					Html.paragraph_s_attrs(Signal.map(row, |view| view.title), [Html.test_id("title-${key}"), Html.class_attr("card-title min-w-0")]),
					Html.paragraph_s_attrs(Signal.map(row, |view| status_text(view.status)), [Html.test_id("status-${key}"), Html.class_attr_s(Signal.map(row, status_badge_class))]),
				],
			),
			Html.paragraph_s_attrs(Signal.map(row, |view| view.when), [Html.test_id("when-${key}"), Html.class_attr("numeric text-xs font-medium text-zinc-700")]),
			Html.paragraph_s_attrs(Signal.map(row, |view| Clash.to_str(view.conflict)), [Html.test_id("conflict-${key}"), Html.class_attr_s(Signal.map(row, conflict_class))]),
			Html.div_c(
				"grid grid-cols-2 gap-1 pt-1",
				[
					Html.button_attrs("Available", [Html.aria_label("Mark ${key} available"), Html.class_attr("button button-sm")], slots.on_unit(|list| set_status(list, key, Status.Available))),
					Html.button_attrs("Busy", [Html.aria_label("Mark ${key} busy"), Html.class_attr("button button-sm")], slots.on_unit(|list| set_status(list, key, Status.Busy))),
					Html.button_attrs("Earlier", [Html.aria_label("Move ${key} earlier"), Html.class_attr("button-ghost button-sm")], slots.on_unit(|list| move_earlier(list, key))),
					Html.button_attrs("Remove", [Html.aria_label("Remove ${key}"), Html.class_attr("button-danger button-sm")], slots.on_unit(|list| list.drop_if(|slot| slot.id == key))),
				],
			),
		],
	)

## The four signals the week grid reads, named rather than positional: `rows`
## and `free` are both lists off the same fan-in, and nothing but the field name
## would stop a call site swapping them.
WeekView : {
	rows : Signal.Signal(List(RowView)),
	free : Signal.Signal(List(Day)),
	banner : Signal.Signal(Banner),
	empty : Signal.Signal(Bool),
}

week_panel : Ui.State(List(Slot)), WeekView -> Elem
week_panel = |slots, view|
	Html.section_c(
		"Week",
		panel_class,
		[
			Html.div_c(
				"panel-head",
				[
					Html.heading_c("Week", "panel-title"),
					Html.paragraph_c("Monday to Sunday, in the selected timezone. Every block sits in its local day.", "hint"),
				],
			),
			Html.div_c(
				"panel-body",
				[
					Html.paragraph_s_attrs(Signal.map(view.banner, Banner.to_str), [Html.test_id("conflict-banner"), Html.class_attr_s(Signal.map(view.banner, banner_class))]),
					Html.div_c("hidden gap-2 sm:grid sm:grid-cols-7", days.map(|day| day_header(view.free, day))),
					# One `Ui.each` over the whole week: the day columns are a CSS
					# placement of the same rows, so a timezone change moves a block
					# between columns without the reconciler creating a new row.
					# `grid-flow-dense` lets a block fill the first free cell in its
					# own column instead of leaving a hole above it, which is what a
					# single keyed list placed by `col-start` would otherwise do.
					Html.div_c(
						"grid items-start gap-2 sm:grid-cols-7 sm:[grid-auto-flow:row_dense]",
						[Ui.each(view.rows, |row| row.id, |each_row| render_row(slots, each_row.key(), each_row.signal()))],
					),
					Ui.when(
						view.empty,
						|| Html.paragraph_c("No slots yet. Add the first commitment below.", "empty-state"),
						|| Html.text(""),
					),
				],
			),
		],
	)

## A labelled control. Every input in the form is drawn the same way.
field : Str, Elem, Str -> Elem
field = |label, control, note|
	Html.div_c(
		"field",
		[
			Html.paragraph_c(label, "field-label"),
			control,
			Html.paragraph_c(note, "hint"),
		],
	)

add_panel : Ui.State(Draft), Ui.State(Zone), Ui.State(List(Slot)), Signal.Signal(Draft) -> Elem
add_panel = |draft, zone, slots, draft_signal|
	Html.section_c(
		"Add slot",
		panel_class,
		[
			Html.div_c(
				"panel-head",
				[
					Html.heading_c("Add slot", "panel-title"),
					Html.paragraph_c("Times are read as wall clock in the zone above.", "hint"),
				],
			),
			Html.div_c(
				"panel-body",
				[
					Html.div_c(
						"grid gap-3 sm:grid-cols-2 lg:grid-cols-4",
						[
							field(
								"Slot name",
								Html.text_input_attrs(
									"Slot name",
									Signal.map(draft_signal, |value| value.title),
									[Html.class_attr("input"), Html.attr("placeholder", "Client call")],
									draft.on_str_with(zone, |value, current_zone, text| reprice({ ..value, title: text }, current_zone)),
								),
								"Shown on the block.",
							),
							field(
								"Day",
								Html.select_c(
									"Day",
									Signal.map(draft_signal, |value| Day.to_str(value.day)),
									"input",
									days.map(|day| Html.option(Day.to_str(day), Day.to_str(day))),
									# The one place a day arrives as text: parse it here and
									# the rest of the app only ever sees the tag.
									draft.on_str_with(zone, |value, current_zone, text| reprice({ ..value, day: Day.from_str(text).ok_or(Day.Mon) }, current_zone)),
								),
								"Local day in the selected zone.",
							),
							field(
								"Start time",
								Html.text_input_attrs(
									"Start time",
									Signal.map(draft_signal, |value| value.start_text),
									[Html.class_attr("input numeric"), Html.attr("placeholder", "08:30")],
									draft.on_str_with(zone, |value, current_zone, text| reprice({ ..value, start_text: text }, current_zone)),
								),
								"24-hour HH:MM.",
							),
							field(
								"Length",
								Html.text_input_attrs(
									"Length",
									Signal.map(draft_signal, |value| value.duration),
									[Html.class_attr("input numeric"), Html.attr("placeholder", "45")],
									draft.on_str_with(zone, |value, current_zone, text| reprice({ ..value, duration: text }, current_zone)),
								),
								"Minutes, 1 to 720.",
							),
						],
					),
					Html.div_c(
						"flex flex-wrap items-center justify-between gap-3 border-t border-zinc-200 pt-4",
						[
							Html.paragraph_s_attrs(
								Signal.map(draft_signal, draft_status),
								[Html.test_id("draft-status"), Html.class_attr_s(Signal.map(draft_signal, draft_tone))],
							),
							Html.action_button_attrs(
								Signal.const("Add slot"),
								Signal.map(draft_signal, |value| Try.is_err(value.plan)),
								[Html.attr("type", "button"), Html.class_attr("button-primary")],
								slots.on_unit_with(draft, add_slot),
							),
						],
					),
				],
			),
		],
	)

## One metric tile. A number with a caption, never a sentence. The three strings
## that describe the tile travel together so they cannot be transposed.
Tile : { label : Str, test_id : Str, value_class : Str }

stat : Tile, Signal.Signal(Str) -> Elem
stat = |tile, value|
	Html.div_c(
		"stat",
		[
			Html.paragraph_c(tile.label, "stat-label"),
			Html.paragraph_s_attrs(value, [Html.test_id(tile.test_id), Html.class_attr(tile.value_class)]),
		],
	)

## Four same-typed `Signal(Str)` tiles: named fields, not four positions.
Totals : {
	hours : Signal.Signal(Str),
	slots : Signal.Signal(Str),
	conflicts : Signal.Signal(Str),
	free : Signal.Signal(Str),
}

summary_panel : Totals -> Elem
summary_panel = |totals|
	Html.section_c(
		"Summary",
		"panel p-4",
		[
			Html.div_c(
				"stat-grid",
				[
					stat({ label: "Hours available", test_id: "summary", value_class: "stat-value" }, totals.hours),
					stat({ label: "Slots", test_id: "stat-slots", value_class: "stat-value" }, totals.slots),
					stat({ label: "Conflicts", test_id: "stat-conflicts", value_class: "stat-value" }, totals.conflicts),
					stat({ label: "Days with no availability", test_id: "free-days", value_class: "value numeric" }, totals.free),
				],
			),
		],
	)

## The zone picker is the headline control: one change here reprojects every
## block in the grid, so it gets its own panel and shows the offset it applies.
zone_panel : Ui.State(Zone), Signal.Signal(Zone) -> Elem
zone_panel = |zone, zone_signal|
	Html.section_c(
		"Timezone picker",
		"panel flex flex-wrap items-end justify-between gap-4 p-5",
		[
			Html.div_c(
				"field w-full sm:w-80",
				[
					Html.paragraph_c("Show the week in", "field-label"),
					Html.select_c(
						"Timezone",
						Signal.map(zone_signal, |value| value.id),
						"input",
						zones.map(|item| Html.option(item.id, item.label)),
						zone.on_str(|_, text| zone_by_id(text)),
					),
					Html.paragraph_c("Slots are stored as UTC instants and reprojected on read.", "hint"),
				],
			),
			Html.div_c(
				"grid gap-1 sm:text-right",
				[
					Html.paragraph_c("Displaying", "stat-label"),
					Html.paragraph_s_attrs(
						Signal.map(zone_signal, |value| value.label),
						[Html.test_id("zone-label"), Html.class_attr("numeric text-lg font-semibold text-zinc-950")],
					),
				],
			),
		],
	)

metric_at : List(U64), U64 -> U64
metric_at = |values, index| values.get(index) ?? 0

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

							# chain: slots -> conflicts -> conflict_count -> combine -> stats
							conflicts = Signal.map(slots_signal, conflict_ids)
							conflict_count = Signal.map(conflicts, |ids| ids.len())
							avail_minutes = Signal.map(slots_signal, available_minutes)
							slot_count = Signal.map(slots_signal, |list| list.len())

							# fan-in A: three same-typed derived signals combined once, then
							# split into the three metric tiles that read off them.
							totals = Signal.combine([avail_minutes, conflict_count, slot_count])
							hours_text = Signal.map(totals, |values| duration_text(metric_at(values, 0)))
							conflicts_text = Signal.map(totals, |values| metric_at(values, 1).to_str())
							slots_text = Signal.map(totals, |values| metric_at(values, 2).to_str())

							# fan-in B: slots x zone x conflicts -> every rendered block
							rows =
								Signal.map(
									{ slots: slots_signal, zone: zone_signal, conflicts: conflicts }.Signal,
									|value| row_views(value.slots, value.zone, value.conflicts),
								)

							# fan-in C: slots x zone -> which local days have no availability
							free_names = Signal.map2(slots_signal, zone_signal, free_days)
							free = Signal.map(free_names, free_text)

							banner = Signal.map2(slots_signal, conflicts, conflict_banner)

							Html.div_c(
								page_class,
								[
									Html.section_c(
										"Availability Picker",
										"app-header",
										[
											Html.heading_c("Availability Picker", "app-title"),
											Html.paragraph_c("Mark weekly slots available or busy, spot overlapping commitments, and re-read the whole week in another timezone without rebuilding a single row.", "app-subtitle"),
										],
									),
									zone_panel(zone, zone_signal),
									summary_panel({ hours: hours_text, slots: slots_text, conflicts: conflicts_text, free }),
									week_panel(slots, { rows, free: free_names, banner, empty: Signal.map(slot_count, |count| count == 0) }),
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

## A known day wire value round-trips through the tag back to its own label.
expect Day.from_str("Fri").ok_or(Day.Mon) |> Day.to_str() == "Fri"

## An unrecognised day wire value falls back to Monday rather than failing.
expect Day.from_str("Nope").ok_or(Day.Mon) |> Day.to_str() == "Mon"

## A day's column index maps back to the same day.
expect Day.from_index(Day.index(Day.Sun)).ok_or(Day.Mon) |> Day.is_eq(Day.Sun)

## A well-formed 24-hour time parses to minutes from midnight.
expect parse_clock("08:30") == Ok(510)

## An hour of 25 is out of range and is rejected, not wrapped.
expect parse_clock("25:00") == Err(BadClock)

## A time with no colon is rejected rather than read as a bare number.
expect parse_clock("0830") == Err(BadClock)

## A minute of 60 is out of range and is rejected.
expect parse_clock("08:60") == Err(BadClock)

## A plain minute count inside the allowed range parses.
expect parse_duration("45") == Ok(45)

## A zero-length slot is rejected.
expect parse_duration("0") == Err(BadDuration)

## Non-digit text is rejected rather than silently read as zero.
expect parse_duration("abc") == Err(BadDuration)

## A length above the 720-minute ceiling is rejected.
expect parse_duration("721") == Err(BadDuration)

## A fully filled draft reports itself ready and names the slot being added.
expect {
	draft = reprice({ ..empty_draft, title: "Client call", day: Day.Fri, start_text: "08:30", duration: "45" }, zone_by_id("nyc"))
	draft_status(draft) == "Ready to add Client call"
}

## A local time typed in New York reads back as the same wall clock in New York.
expect {
	nyc = zone_by_id("nyc")
	draft = reprice({ ..empty_draft, title: "Client call", day: Day.Fri, start_text: "08:30", duration: "45" }, nyc)
	slot = slot_at(add_slot([], draft), 0)
	span_text(slot, nyc) == "Fri 08:30-09:15"
}

## A missing title is reported before any complaint about the other fields.
expect draft_status({ ..empty_draft, start_text: "25:00" }) == "Enter a name for the new slot"

## An out-of-range start time is reported as a start-time problem.
expect draft_status(reprice({ ..empty_draft, title: "X", start_text: "25:00" }, zone_by_id("utc"))) == "Start time must be HH:MM"

## An out-of-range length is reported as a length problem.
expect draft_status(reprice({ ..empty_draft, title: "X", duration: "0" }, zone_by_id("utc"))) == "Length must be 1-720 minutes"

## A block in a clash names the commitment it overlaps, not a bare "Conflict".
expect {
	slots = [
		{ id: "a", title: "Standup", abs_start: 540, duration: 30, status: Status.Busy },
		{ id: "b", title: "Design review", abs_start: 555, duration: 60, status: Status.Busy },
	]
	ids = conflict_ids(slots)
	Clash.to_str(conflict_of(slots, ids, slot_at(slots, 0))) == "Clashes with Design review"
}

## The banner counts and lists every commitment currently in a clash.
expect {
	slots = [
		{ id: "a", title: "Standup", abs_start: 540, duration: 30, status: Status.Busy },
		{ id: "b", title: "Design review", abs_start: 555, duration: 60, status: Status.Busy },
	]
	ids = conflict_ids(slots)
	Banner.to_str(conflict_banner(slots, ids)) == "2 overlapping commitments: Standup, Design review"
}

## Overlapping slots that are not both busy raise no banner at all.
expect conflict_banner(initial_slots, conflict_ids(initial_slots)) |> Banner.is_eq(Banner.Settled)

## Moving a slot earlier swaps it with the one before it.
expect move_earlier(initial_slots, "review").map(|slot| slot.id) == ["sunrise", "review", "standup", "midnight", "focus"]

## Moving the first slot earlier leaves the order untouched.
expect move_earlier(initial_slots, "sunrise").map(|slot| slot.id) == ["sunrise", "standup", "review", "midnight", "focus"]
