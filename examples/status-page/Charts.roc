import plume.Axis
import plume.Chart
import plume.Color
import plume.Coordinate
import plume.Layout
import plume.Line
import plume.Marker
import plume.Scatter
import plume.Shape
import plume.Size
import plume.Title
import Latency
import Status

## The Status Page's charts, built with Plume as Plotly figure JSON for the
## page's `plume-chart` elements (`examples/shared/plume-chart.mjs`). Each
## figure is drawn from page state the app keeps bounded, so its size does
## not grow with how long the page is open, and each keeps the viewer's
## zoom across redraws (`ui_revision: Preserve(...)`).
Charts := [].{

	## Each service's line colour, the same in every chart. The status
	## tones (green, amber, red) are left to the badges, so a line's colour
	## names a service and never a health.
	service_color : Status.Service -> Color
	service_color = |service|
		match service {
			Api => Color.rgb({ red: 37, green: 99, blue: 235 })
			Web => Color.rgb({ red: 124, green: 58, blue: 237 })
			Database => Color.rgb({ red: 13, green: 148, blue: 136 })
			Notifications => Color.rgb({ red: 219, green: 39, blue: 119 })
		}

	## A service's name in a legend.
	service_name : Status.Service -> Str
	service_name = |service|
		match service {
			Api => "API"
			Web => "Web app"
			Database => "Database"
			Notifications => "Notifications"
		}

	## The uptime history as a figure: one line per service across the
	## rounds the page keeps, the newest at 0 and older ones to its left
	## ("checks ago"). A round with no figure for a service (its check
	## failed, said nothing usable, or was superseded before it answered)
	## draws no point, and the line breaks there rather than joining across
	## it.
	uptime_history : List(Status.Round) -> Str
	uptime_history = |history|
		match uptime_chart(history) {
			Ok(chart) => chart.to_json()
			Err(problem) => crash "Charts.uptime_history: Plume refused a figure built from validated parts: ${Str.inspect(problem)}"
		}

	## The live latency window as a figure: one line per service on a time
	## axis (UTC), a dashed line at the API's objective, and a shaded band
	## over each stretch where the API's p95 was above it. A missing reading
	## breaks every line.
	latency : List(Latency.Point) -> Str
	latency = |window|
		match latency_chart(window) {
			Ok(chart) => chart.to_json()
			Err(problem) => crash "Charts.latency: Plume refused a figure built from validated parts: ${Str.inspect(problem)}"
		}
}

p95_of : Latency.P95, Status.Service -> U32
p95_of = |p95, service|
	match service {
		Api => p95.api
		Web => p95.web
		Database => p95.database
		Notifications => p95.notifications
	}

latency_chart : List(Latency.Point) -> Try(Chart, _)
latency_chart = |window| {
	var $traces = []
	for service in services {
		points = window.map_try(|point| Ok({ x: Coordinate.from_time(point.at), y: Coordinate.from_number(p95_of(point.p95_ms, service).to_f64())?, from_previous: point.from_previous }))?
		width = match service {
			Api => 2.5
			_ => 1.5
		}
		line = Line.new({ color: Charts.service_color(service), width })?
		$traces = $traces.append(Scatter(Scatter.new({ data: points, name: Charts.service_name(service), line })))
	}
	objective = Shape.new({
		placement: HorizontalLine(Coordinate.from_number(Latency.slo_ms.to_f64())?),
		line: Line.new({ color: Color.rgb({ red: 113, green: 113, blue: 122 }), width: 1, dash: Dash })?,
		label: "API objective ${Latency.slo_ms.to_str()} ms",
	})
	bands = Latency.breaches(window).map(
		|band| Shape.new({
			placement: VerticalBand({ start: Coordinate.from_time(band.start), end: Coordinate.from_time(band.end) }),
			fill: Color.rgba({ red: 220, green: 38, blue: 38, alpha: 38 }),
			label: "API over objective",
			layer: Below,
		}),
	)
	Ok(
		Chart.new({
			traces: $traces,
			layout: Layout.new({
				size: Size.new({ height: Pixels(320), margin: Pixels({ left: 64, right: 16, top: 48, bottom: 48 }) })?,
				x_axis: Axis.new({ title: Title.new({ text: "Time (UTC)" }), type: Date, tick_format: Pattern("%H:%M:%S") })?,
				y_axis: Axis.new({ title: Title.new({ text: "p95 latency" }), range: FromZero, tick_suffix: " ms" })?,
				legend: Shown,
				legend_position: Above,
				hover_mode: XUnified,
				ui_revision: Preserve("live-latency"),
				shapes: [objective].concat(bands),
			}),
		}),
	)
}

services : List(Status.Service)
services = [Api, Web, Database, Notifications]

## One service's points across the history: x is how many rounds before
## the newest, y its uptime in percent.
uptime_points : List(Status.Round), Status.Service -> Try(List(Scatter.Point), _)
uptime_points = |history, service| {
	newest = history.len().to_f64() - 1
	# Plume gives every marker its own default colour, not the line's.
	marker = Marker.new({ color: Charts.service_color(service), size: 6 })?
	var $points = []
	var $previous = Awaiting
	var $index = 0.F64
	for round in history {
		uptime = Status.uptime_in(round, service)
		match uptime {
			Measured(bps) => {
				from_previous =
					match $previous {
						Measured(_) => Connected
						_ => Gap
					}
				$points = $points.append({ x: Coordinate.from_number($index - newest)?, y: Coordinate.from_number(bps.to_f64() / 100)?, marker, from_previous })
			}
			_ => {}
		}
		$previous = uptime
		$index = $index + 1
	}
	Ok($points)
}

uptime_chart : List(Status.Round) -> Try(Chart, _)
uptime_chart = |history| {
	var $traces = []
	for service in services {
		line = Line.new({ color: Charts.service_color(service), width: 2 })?
		$traces = $traces.append(Scatter(Scatter.new({ data: uptime_points(history, service)?, name: Charts.service_name(service), line, mode: LinesMarkers })))
	}
	oldest = 1.F64 - Status.history_limit.to_f64()
	Ok(
		Chart.new({
			traces: $traces,
			layout: Layout.new({
				size: Size.new({ height: Pixels(280), margin: Pixels({ left: 56, right: 16, top: 48, bottom: 48 }) })?,
				x_axis: Axis.new({ title: Title.new({ text: "Checks before the latest" }), type: Linear, range: Bounds({ min: oldest, max: 0 }) })?,
				y_axis: Axis.new({ title: Title.new({ text: "Uptime" }), type: Linear, tick_suffix: "%" })?,
				legend: Shown,
				legend_position: Above,
				hover_mode: XUnified,
				ui_revision: Preserve("uptime-history"),
			}),
		}),
	)
}

## A failed check breaks the line: the next figure starts a new segment.
expect {
	history = [
		{ api: Measured(9998), web: Awaiting, database: Awaiting, notifications: Awaiting },
		{ api: Unmeasured, web: Awaiting, database: Awaiting, notifications: Awaiting },
		{ api: Measured(9740), web: Awaiting, database: Awaiting, notifications: Awaiting },
	]
	json = Charts.uptime_history(history)
	json.contains("\"x\":[-2,0,0],\"y\":[99.98,null,97.4]")
}
