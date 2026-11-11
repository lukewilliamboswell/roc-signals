import plume.Axis
import plume.Chart
import plume.Color
import plume.Coordinate
import plume.Layout
import plume.Line
import plume.Scatter
import plume.Size
import plume.Title
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
}

services : List(Status.Service)
services = [Api, Web, Database, Notifications]

## One service's points across the history: x is how many rounds before
## the newest, y its uptime in percent.
uptime_points : List(Status.Round), Status.Service -> Try(List(Scatter.Point), _)
uptime_points = |history, service| {
	newest = history.len().to_f64() - 1
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
				$points = $points.append({ x: Coordinate.from_number($index - newest)?, y: Coordinate.from_number(bps.to_f64() / 100)?, from_previous })
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
