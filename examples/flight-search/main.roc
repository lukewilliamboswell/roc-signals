app [main] { pf: platform "https://github.com/lukewilliamboswell/roc-signals/releases/download/0.1/3eLQGNMDG9RuL9sn1A7ep1Rtq7QGmemE89y141WSv1XG.tar.zst" }

import pf.Elem exposing [Elem]
import pf.Html
import pf.Signal
import pf.Ui

## One flight in the result set the search request returned.
Flight : {
	id : Str,
	airline : Str,
	depart : Str,
	depart_min : U64,
	price : U64,
	stops : U64,
	minutes : U64,
}

## The six values that make up a search *request*. Changing any of them must
## refetch. `sort_by` is deliberately NOT part of this record.
Criteria : {
	origin : Str,
	destination : Str,
	depart_date : Str,
	max_stops : Str,
	max_price : Str,
	airline : Str,
}

## What the host-backed search task currently holds.
Outcome := [Loading, Ready(List(Flight)), Failed(Str)].{
	is_eq : Outcome, Outcome -> Bool
	is_eq = |left, right|
		match left {
			Loading => match right {
				Loading => True
				_ => False
			}
			Ready(left_rows) => match right {
				Ready(right_rows) => left_rows == right_rows
				_ => False
			}
			Failed(left_err) => match right {
				Failed(right_err) => left_err == right_err
				_ => False
			}
		}
}

# --- parsing -----------------------------------------------------------------

digits_to_u64 : Str -> U64
digits_to_u64 = |text|
	text.to_utf8().fold(
		0,
		|acc, byte|
			if byte >= 48 and byte <= 57 {
				acc * 10 + (U8.to_u64(byte) - 48)
			} else {
				acc
			},
	)

field_at : List(Str), U64 -> Str
field_at = |parts, index|
	match parts.get(index) {
		Ok(value) => value
		Err(_) => ""
	}

parse_flight : Str -> Flight
parse_flight = |line| {
	parts = line.split_on(",")
	depart = field_at(parts, 2)

	{
		id: field_at(parts, 0),
		airline: field_at(parts, 1),
		depart,
		depart_min: digits_to_u64(depart),
		price: digits_to_u64(field_at(parts, 3)),
		stops: digits_to_u64(field_at(parts, 4)),
		minutes: digits_to_u64(field_at(parts, 5)),
	}
}

## The wire payload is `id,airline,HH:MM,price,stops,minutes` records joined by
## `;`. An empty payload is a legitimate empty result set.
parse_flights : Str -> List(Flight)
parse_flights = |payload|
	if payload == "" {
		[]
	} else {
		payload.split_on(";").keep_if(|line| line != "").map(parse_flight)
	}

# --- filtering (local, applied to the result set already held) ---------------

limit_of : Str -> U64
limit_of = |value|
	if value == "any" {
		18446744073709551615
	} else {
		digits_to_u64(value)
	}

stops_ok : Criteria, Flight -> Bool
stops_ok = |criteria, flight| flight.stops <= limit_of(criteria.max_stops)

price_ok : Criteria, Flight -> Bool
price_ok = |criteria, flight| flight.price <= limit_of(criteria.max_price)

airline_ok : Criteria, Flight -> Bool
airline_ok = |criteria, flight| (criteria.airline == "any") or (criteria.airline == flight.airline)

matches : Criteria, Flight -> Bool
matches = |criteria, flight|
	stops_ok(criteria, flight) and price_ok(criteria, flight) and airline_ok(criteria, flight)

# --- sorting (local, never refetches) ----------------------------------------

compare_u64 : U64, U64 -> [LT, EQ, GT]
compare_u64 = |left, right|
	if left < right {
		LT
	} else if left > right {
		GT
	} else {
		EQ
	}

sort_flights : List(Flight), Str -> List(Flight)
sort_flights = |flights, key|
	if key == "duration" {
		flights.sort_with(|left, right| compare_u64(left.minutes, right.minutes))
	} else if key == "departure" {
		flights.sort_with(|left, right| compare_u64(left.depart_min, right.depart_min))
	} else {
		flights.sort_with(|left, right| compare_u64(left.price, right.price))
	}

# --- flight formatting -------------------------------------------------------

pad2 : U64 -> Str
pad2 = |value|
	if value < 10 {
		"0${value.to_str()}"
	} else {
		value.to_str()
	}

## `depart_min` is the departure clock with the colon dropped (`09:30` -> 930),
## which is enough to sort by but not to add to. Split it back into hours and
## minutes before doing arithmetic on it.
clock_minutes : Flight -> U64
clock_minutes = |flight| ((flight.depart_min / 100) * 60) + (flight.depart_min % 100)

arrive_text : Flight -> Str
arrive_text = |flight| {
	total = (clock_minutes(flight) + flight.minutes) % 1440
	"${pad2(total / 60)}:${pad2(total % 60)}"
}

duration_text : U64 -> Str
duration_text = |minutes| "${(minutes / 60).to_str()}h ${pad2(minutes % 60)}m"

price_text : U64 -> Str
price_text = |price| "$${price.to_str()}"

stops_text : U64 -> Str
stops_text = |stops|
	if stops == 0 {
		"Nonstop"
	} else if stops == 1 {
		"1 stop"
	} else {
		"${stops.to_str()} stops"
	}

## Green for nonstop, neutral for one stop, amber once a fare needs two.
stops_badge_class : U64 -> Str
stops_badge_class = |stops|
	if stops == 0 {
		"badge badge-ok w-fit"
	} else if stops == 1 {
		"badge badge-neutral w-fit"
	} else {
		"badge badge-warn w-fit"
	}

times_text : Flight -> Str
times_text = |flight| "${flight.depart} → ${arrive_text(flight)}"

carrier_text : Flight -> Str
carrier_text = |flight| "${flight.airline} · ${flight.id} · ${duration_text(flight.minutes)}"

# --- text derivations --------------------------------------------------------

request_of : Criteria -> Str
request_of = |criteria|
	"${criteria.origin}-${criteria.destination}|${criteria.depart_date}|${criteria.max_stops}|${criteria.max_price}|${criteria.airline}"

request_text : Criteria -> Str
request_text = |criteria| "Request: ${request_of(criteria)}"

route_text : Criteria -> Str
route_text = |criteria| "${criteria.origin} → ${criteria.destination}"

stops_filter_text : Str -> Str
stops_filter_text = |value|
	if value == "any" {
		"Any stops"
	} else if value == "0" {
		"Nonstop only"
	} else {
		"Max ${value} stop"
	}

price_filter_text : Str -> Str
price_filter_text = |value|
	if value == "any" {
		"Any price"
	} else {
		"Under $${value}"
	}

airline_filter_text : Str -> Str
airline_filter_text = |value|
	if value == "any" {
		"All airlines"
	} else {
		value
	}

## The whole request in one readable line, the way a booking site echoes the
## search back above the results.
filters_text : Criteria -> Str
filters_text = |criteria|
	"${route_text(criteria)} · ${criteria.depart_date} · ${stops_filter_text(criteria.max_stops)} · ${price_filter_text(criteria.max_price)} · ${airline_filter_text(criteria.airline)}"

sort_text : Str -> Str
sort_text = |key|
	if key == "duration" {
		"Sorted by: duration"
	} else if key == "departure" {
		"Sorted by: departure time"
	} else {
		"Sorted by: price"
	}

status_text : Outcome -> Str
status_text = |outcome|
	match outcome {
		Loading => "Searching"
		Ready(_) => "Results ready"
		Failed(_) => "Search failed"
	}

status_badge_class : Outcome -> Str
status_badge_class = |outcome|
	match outcome {
		Loading => "badge badge-info"
		Ready(_) => "badge badge-ok"
		Failed(_) => "badge badge-danger"
	}

error_text : Outcome -> Str
error_text = |outcome|
	match outcome {
		Failed(err) => "Search error: ${err}"
		_ => ""
	}

is_failed : Outcome -> Bool
is_failed = |outcome|
	match outcome {
		Failed(_) => True
		_ => False
	}

returned_count : Outcome -> U64
returned_count = |outcome|
	match outcome {
		Ready(rows) => rows.len()
		_ => 0
	}

count_text : U64 -> Str
count_text = |count| count.to_str()

## Fan-in of the raw task outcome and the locally sorted rows, so an empty
## response reads differently from a filter that excluded every returned row.
summary_text : Outcome, List(Flight) -> Str
summary_text = |outcome, rows|
	match outcome {
		Loading => "Fetching flights"
		Failed(_) => "No flights to show"
		Ready(returned) =>
			if returned.is_empty() {
				"No flights returned for these filters."
			} else if rows.is_empty() {
				"0 of ${returned.len().to_str()} flights match the local filters."
			} else {
				"Showing ${rows.len().to_str()} of ${returned.len().to_str()} flights."
			},
	}

cheapest_text : List(Flight) -> Str
cheapest_text = |rows|
	match rows.map(|flight| flight.price).min() {
		Ok(price) => price_text(price)
		Err(_) => "—"
	}

fastest_text : List(Flight) -> Str
fastest_text = |rows|
	match rows.map(|flight| flight.minutes).min() {
		Ok(minutes) => duration_text(minutes)
		Err(_) => "—"
	}

order_text : List(Flight) -> Str
order_text = |rows|
	if rows.is_empty() {
		"Result order: none"
	} else {
		"Result order: ${Str.join_with(rows.map(|flight| flight.id), ", ")}"
	}

top_text : List(Flight) -> Str
top_text = |rows|
	match rows.first() {
		Ok(flight) => "Top result: ${flight.id}"
		Err(_) => "Top result: none"
	}

## An empty list has to say *why* it is empty. When the backend did return
## flights, name the one filter that is doing the excluding, so the fix is a
## single control away.
blocking_filter : Criteria, List(Flight) -> Str
blocking_filter = |criteria, returned|
	if returned.keep_if(|flight| stops_ok(criteria, flight)).is_empty() {
		"Max stops (${stops_filter_text(criteria.max_stops)}) excludes every flight on this route."
	} else if returned.keep_if(|flight| price_ok(criteria, flight)).is_empty() {
		"Max price (${price_filter_text(criteria.max_price)}) excludes every flight on this route."
	} else if returned.keep_if(|flight| airline_ok(criteria, flight)).is_empty() {
		"Airline (${airline_filter_text(criteria.airline)}) excludes every flight on this route."
	} else {
		"No flight clears all of the filters at once. Try relaxing one of them."
	}

empty_note_text : Outcome, Criteria -> Str
empty_note_text = |outcome, criteria|
	match outcome {
		Loading => "Searching ${route_text(criteria)} for ${criteria.depart_date}…"
		Failed(_) => "The search request failed, so there is nothing to show. Change a filter to retry."
		Ready(returned) =>
			if returned.is_empty() {
				"No flights on ${route_text(criteria)} for ${criteria.depart_date}. Try another date."
			} else {
				blocking_filter(criteria, returned)
			},
	}

# --- classes -----------------------------------------------------------------

page_class : Str
page_class = "app-shell grid gap-5"

panel_class : Str
panel_class = "panel grid gap-4 p-5"

input_class : Str
input_class = "input"

# --- view --------------------------------------------------------------------

## A labelled control. Every filter in the toolbar is drawn the same way, so
## the row of controls stays aligned no matter how long the caption is.
field : Str, Elem -> Elem
field = |label, control|
	Html.div_c("field min-w-[9rem]", [Html.paragraph_c(label, "field-label"), control])

filter_field : Str, Signal.Signal(Str), List(Elem), _ -> Elem
filter_field = |label, value, options, msg|
	field(label, Html.select_c(label, value, input_class, options, msg))

stat : Str, Signal.Signal(Str), List(_) -> Elem
stat = |label, value, attrs|
	Html.div_c(
		"stat",
		[
			Html.paragraph_c(label, "stat-label"),
			Html.paragraph_s_attrs(value, attrs.append(Html.class_attr("stat-value numeric"))),
		],
	)

## One result row: departure and arrival across the middle, carrier and
## duration beneath, fare on the right.
render_row : Str, Signal.Signal(Flight) -> Elem
render_row = |key, flight|
	Html.div(
		[Html.class_attr("card"), Html.test_id("flight-row-${key}")],
		[
			Html.div_c(
				"flex flex-wrap items-start justify-between gap-4",
				[
					Html.div_c(
						"grid min-w-0 gap-1",
						[
							Html.paragraph_s_attrs(
								flight.map(times_text),
								[Html.class_attr("text-base font-semibold text-zinc-950 numeric tabular-nums")],
							),
							Html.paragraph_s_c(flight.map(carrier_text), "muted"),
							Html.paragraph_s_attrs(
								flight.map(|value| stops_text(value.stops)),
								[Html.class_attr_s(flight.map(|value| stops_badge_class(value.stops)))],
							),
						],
					),
					Html.paragraph_s_attrs(
						flight.map(|value| price_text(value.price)),
						[Html.class_attr("text-xl font-semibold text-zinc-950 numeric tabular-nums text-right")],
					),
				],
			),
		],
	)

main : () -> Elem
main = ||
	Ui.state(
		"SYD",
		|origin|
			Ui.state(
				"ADL",
				|destination|
					Ui.state(
						"2026-09-01",
						|depart_date|
							Ui.state(
								"any",
								|max_stops|
									Ui.state(
										"any",
										|max_price|
											Ui.state(
												"any",
												|airline|
													Ui.state(
														"price",
														|sort_by|
															search(
																{
																	origin,
																	destination,
																	depart_date,
																	max_stops,
																	max_price,
																	airline,
																	sort_by,
																},
															),
													),
											),
									),
							),
					),
			),
	)

Handles : {
	origin : Ui.State(Str),
	destination : Ui.State(Str),
	depart_date : Ui.State(Str),
	max_stops : Ui.State(Str),
	max_price : Ui.State(Str),
	airline : Ui.State(Str),
	sort_by : Ui.State(Str),
}

search : Handles -> Elem
search = |h| {
	task = Signal.fake_task("flight-search", |value| value, |err| err)

	# Fan-in 1: six independent filter states become one request key.
	criteria : Signal.Signal(Criteria)
	criteria =
		{
			origin: h.origin.signal(),
			destination: h.destination.signal(),
			depart_date: h.depart_date.signal(),
			max_stops: h.max_stops.signal(),
			max_price: h.max_price.signal(),
			airline: h.airline.signal(),
		}.Signal

	request = criteria.map(request_of)

	outcome : Signal.Signal(Outcome)
	outcome =
		Signal.fold_task(
			task,
			Loading,
			|payload| Ready(parse_flights(payload)),
			|err| Failed(err),
		)

	# Fan-in 2: result set + criteria -> the matching subset.
	matched =
		Signal.map2(
			outcome,
			criteria,
			|value, current|
				match value {
					Ready(rows) => rows.keep_if(|flight| matches(current, flight))
					_ => []
				},
		)

	# Fan-in 3: matching subset + sort key -> the rendered order.
	# `sort_by` is not part of `criteria`, so this never refetches.
	rows = Signal.map2(matched, h.sort_by.signal(), sort_flights)

	summary = Signal.map2(outcome, rows, summary_text)
	empty_note = Signal.map2(outcome, criteria, empty_note_text)

	Html.div_c(
		page_class,
		[
			Html.section_c(
				"Flight Search",
				"app-header",
				[
					Html.heading_c("Flight Search", "app-title"),
					Html.paragraph_c(
						"Filters are part of the search request and refetch. Sorting is a derived view of the results already held and never refetches.",
						"app-subtitle",
					),
				],
			),
			Html.section_c(
				"Search filters",
				panel_class,
				[
					Html.div_c(
						"toolbar",
						[
							filter_field(
								"From",
								h.origin.signal(),
								[
									Html.option("SYD", "SYD — Sydney"),
									Html.option("MEL", "MEL — Melbourne"),
									Html.option("BNE", "BNE — Brisbane"),
								],
								h.origin.on_str(|_, value| value),
							),
							filter_field(
								"To",
								h.destination.signal(),
								[
									Html.option("ADL", "ADL — Adelaide"),
									Html.option("PER", "PER — Perth"),
									Html.option("MEL", "MEL — Melbourne"),
								],
								h.destination.on_str(|_, value| value),
							),
							filter_field(
								"Departure date",
								h.depart_date.signal(),
								[
									Html.option("2026-09-01", "Tue 1 Sep"),
									Html.option("2026-09-02", "Wed 2 Sep"),
									Html.option("2026-09-03", "Thu 3 Sep"),
								],
								h.depart_date.on_str(|_, value| value),
							),
							filter_field(
								"Max stops",
								h.max_stops.signal(),
								[
									Html.option("any", "Any"),
									Html.option("0", "Nonstop"),
									Html.option("1", "1 stop"),
								],
								h.max_stops.on_str(|_, value| value),
							),
							filter_field(
								"Max price",
								h.max_price.signal(),
								[
									Html.option("any", "Any"),
									Html.option("200", "$200"),
									Html.option("300", "$300"),
									Html.option("400", "$400"),
								],
								h.max_price.on_str(|_, value| value),
							),
							filter_field(
								"Airline",
								h.airline.signal(),
								[
									Html.option("any", "Any"),
									Html.option("Qantas", "Qantas"),
									Html.option("Virgin Australia", "Virgin Australia"),
									Html.option("Jetstar", "Jetstar"),
								],
								h.airline.on_str(|_, value| value),
							),
							# Sorting sits beside the filters because that is where a
							# traveller looks for it, but it is its own region: nothing
							# in here is part of the request key.
							Html.section_c(
								"Sort controls",
								"field min-w-[9rem]",
								[
									Html.paragraph_c("Sort by", "field-label"),
									Html.select_c(
										"Sort by",
										h.sort_by.signal(),
										input_class,
										[
											Html.option("price", "Price"),
											Html.option("duration", "Duration"),
											Html.option("departure", "Departure time"),
										],
										h.sort_by.on_str(|_, value| value),
									),
									Html.paragraph_s_attrs(
										h.sort_by.signal().map(sort_text),
										[Html.class_attr("hint"), Html.test_id("sort-summary")],
									),
								],
							),
						],
					),
					Html.paragraph_s_attrs(
						criteria.map(filters_text),
						[Html.class_attr("value"), Html.test_id("filters-summary")],
					),
				],
			),
			Html.section_c(
				"Results",
				panel_class,
				[
					Html.div_c(
						"flex flex-wrap items-center justify-between gap-3",
						[
							Html.heading_c("Flights", "panel-title"),
							Html.paragraph_s_attrs(
								outcome.map(status_text),
								[Html.class_attr_s(outcome.map(status_badge_class)), Html.test_id("search-status")],
							),
						],
					),
					Html.div_c(
						"stat-grid",
						[
							stat("Flights returned", outcome.map(|value| count_text(returned_count(value))), [Html.test_id("flights-returned")]),
							stat("Matching filters", rows.map(|value| count_text(value.len())), []),
							stat("Cheapest", rows.map(cheapest_text), []),
							stat("Fastest", rows.map(fastest_text), []),
						],
					),
					Html.paragraph_s_attrs(summary, [Html.class_attr("muted"), Html.test_id("result-summary")]),
					# The error banner only exists while the search has actually
					# failed; there is no "no error" line sitting in the page.
					Ui.when(
						outcome.map(is_failed),
						|| Html.paragraph_s_attrs(
							outcome.map(error_text),
							[Html.class_attr("notice notice-error"), Html.test_id("search-error")],
						),
						|| Html.text(""),
					),
					# The empty state is a sibling of the list rather than a branch
					# around it, so the keyed row block is never torn down and
					# rebuilt just because a filter emptied it.
					Ui.when(
						rows.map(|value| value.is_empty()),
						|| Html.paragraph_s_c(empty_note, "empty-state"),
						|| Html.text(""),
					),
					Html.div_c("grid gap-2", [Ui.each_str(rows, |flight| flight.id, render_row)]),
					# The request key and the derived order, kept visible because
					# the point of the example is which of them refetches.
					Html.div_c(
						"grid gap-1 border-t border-zinc-200 pt-3",
						[
							Html.heading_c("Search trace", "panel-title"),
							Html.paragraph_s_attrs(criteria.map(request_text), [Html.class_attr("hint numeric"), Html.test_id("request-key")]),
							Html.paragraph_s_attrs(rows.map(order_text), [Html.class_attr("hint"), Html.test_id("result-order")]),
							Html.paragraph_s_attrs(rows.map(top_text), [Html.class_attr("hint"), Html.test_id("top-result")]),
						],
					),
				],
			),
			Ui.on_change_initial(request, |value| Signal.start_str(task, value)),
			Ui.on_cleanup(Signal.cleanup("flight search cleanup")),
		],
	)
}
