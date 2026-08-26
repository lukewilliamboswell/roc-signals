app [main] { pf: platform "https://github.com/lukewilliamboswell/roc-signals/releases/download/0.1/3eLQGNMDG9RuL9sn1A7ep1Rtq7QGmemE89y141WSv1XG.tar.zst" }

import pf.Elem exposing [Elem]
import pf.Html
import pf.Signal
import pf.Ui

page_class = "grid gap-5"

hero_class = "panel grid gap-2 p-5"

panel_class = "panel grid gap-4 p-4"

controls_class = "flex flex-wrap items-end gap-3"

select_class = "rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm"

row_class = "rounded-md border border-zinc-200 px-3 py-2 text-sm"

strong_class = "text-sm font-medium text-zinc-900"

muted_class = "text-sm text-zinc-700"

error_class = "text-sm text-red-950"

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

## The four values that make up a search *request*. Changing any of them must
## refetch. `sort_by` is deliberately NOT part of this record.
Criteria : {
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

matches : Criteria, Flight -> Bool
matches = |criteria, flight|
	(flight.stops <= limit_of(criteria.max_stops))
	and (flight.price <= limit_of(criteria.max_price))
	and ((criteria.airline == "any") or (criteria.airline == flight.airline))

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

# --- text derivations --------------------------------------------------------

request_of : Criteria -> Str
request_of = |criteria|
	"${criteria.depart_date}|${criteria.max_stops}|${criteria.max_price}|${criteria.airline}"

request_text : Criteria -> Str
request_text = |criteria| "Request: ${request_of(criteria)}"

filters_text : Criteria -> Str
filters_text = |criteria| {
	stops =
		if criteria.max_stops == "any" {
			"any stops"
		} else {
			"max ${criteria.max_stops} stops"
		}
	price =
		if criteria.max_price == "any" {
			"any price"
		} else {
			"max $${criteria.max_price}"
		}
	airline =
		if criteria.airline == "any" {
			"any airline"
		} else {
			criteria.airline
		}

	"Filters: ${criteria.depart_date}, ${stops}, ${price}, ${airline}"
}

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
		Loading => "Search status: loading"
		Ready(_) => "Search status: results ready"
		Failed(_) => "Search status: failed"
	}

error_text : Outcome -> Str
error_text = |outcome|
	match outcome {
		Failed(err) => "Search error: ${err}"
		_ => "No search error"
	}

returned_count : Outcome -> U64
returned_count = |outcome|
	match outcome {
		Ready(rows) => rows.len()
		_ => 0
	}

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

row_text : Flight -> Str
row_text = |flight|
	"${flight.id} - ${flight.airline} - departs ${flight.depart} - $${flight.price.to_str()} - ${flight.stops.to_str()} stops - ${flight.minutes.to_str()} min"

# --- view --------------------------------------------------------------------

render_row : Str, Signal.Signal(Flight) -> Elem
render_row = |_key, flight| Html.div_c(row_class, [Html.text_s(flight.map(row_text))])

filter_select : Str, Signal.Signal(Str), List(Elem), _ -> Elem
filter_select = |label, value, options, msg| Html.select_c(label, value, select_class, options, msg)

main : () -> Elem
main = ||
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
										|sort_by| {
											task = Signal.fake_task("flight-search", |value| value, |err| err)

											# Fan-in 1: four independent filter states become one request key.
											criteria : Signal.Signal(Criteria)
											criteria =
												{
													depart_date: depart_date.signal(),
													max_stops: max_stops.signal(),
													max_price: max_price.signal(),
													airline: airline.signal(),
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
											rows = Signal.map2(matched, sort_by.signal(), sort_flights)

											summary = Signal.map2(outcome, rows, summary_text)

											Html.div_c(
												page_class,
												[
													Html.section_c(
														"Flight Search",
														hero_class,
														[
															Html.heading_c("Flight Search", "text-3xl font-semibold text-zinc-950"),
															Html.paragraph_c("Filters are part of the search request and refetch. Sorting is a derived view of the results already held and never refetches.", "max-w-3xl text-sm text-zinc-700"),
														],
													),
													Html.section_c(
														"Search filters",
														panel_class,
														[
															Html.div_c(
																controls_class,
																[
																	filter_select(
																		"Departure date",
																		depart_date.signal(),
																		[
																			Html.option("2026-09-01", "Tue 1 Sep"),
																			Html.option("2026-09-02", "Wed 2 Sep"),
																			Html.option("2026-09-03", "Thu 3 Sep"),
																		],
																		depart_date.on_str(|_, value| value),
																	),
																	filter_select(
																		"Max stops",
																		max_stops.signal(),
																		[
																			Html.option("any", "Any"),
																			Html.option("0", "Nonstop"),
																			Html.option("1", "1 stop"),
																		],
																		max_stops.on_str(|_, value| value),
																	),
																	filter_select(
																		"Max price",
																		max_price.signal(),
																		[
																			Html.option("any", "Any"),
																			Html.option("200", "$200"),
																			Html.option("300", "$300"),
																			Html.option("400", "$400"),
																		],
																		max_price.on_str(|_, value| value),
																	),
																	filter_select(
																		"Airline",
																		airline.signal(),
																		[
																			Html.option("any", "Any"),
																			Html.option("Aurora", "Aurora"),
																			Html.option("Borealis", "Borealis"),
																			Html.option("Cirrus", "Cirrus"),
																		],
																		airline.on_str(|_, value| value),
																	),
																],
															),
															Html.paragraph_s_c(criteria.map(filters_text), strong_class),
															Html.paragraph_s_c(criteria.map(request_text), muted_class),
														],
													),
													Html.section_c(
														"Sort controls",
														panel_class,
														[
															filter_select(
																"Sort by",
																sort_by.signal(),
																[
																	Html.option("price", "Price"),
																	Html.option("duration", "Duration"),
																	Html.option("departure", "Departure time"),
																],
																sort_by.on_str(|_, value| value),
															),
															Html.paragraph_s_c(sort_by.signal().map(sort_text), strong_class),
															Html.paragraph_c("Sorting reorders the flights already returned. It does not issue a new search.", muted_class),
														],
													),
													Html.section_c(
														"Results",
														panel_class,
														[
															Html.paragraph_s_c(outcome.map(status_text), strong_class),
															Html.paragraph_s_c(summary, strong_class),
															Html.paragraph_s_c(outcome.map(|value| "Flights returned: ${returned_count(value).to_str()}"), muted_class),
															Html.paragraph_s_c(rows.map(order_text), muted_class),
															Html.paragraph_s_c(rows.map(top_text), muted_class),
															Html.paragraph_s_c(outcome.map(error_text), error_class),
															Html.div_c("grid gap-2", [Ui.each_str(rows, |flight| flight.id, render_row)]),
														],
													),
													Ui.on_change_initial(request, |value| Signal.start_str(task, value)),
													Ui.on_cleanup(Signal.cleanup("flight search cleanup")),
												],
											)
										},
									),
							),
					),
			),
	)
