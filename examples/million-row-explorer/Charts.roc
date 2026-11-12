import plume.Axis
import plume.Bar
import plume.Chart
import plume.Color
import plume.Coordinate
import plume.Layout
import plume.Line
import plume.Pie
import plume.Scatter
import plume.Shape
import plume.Size
import plume.Time
import plume.Title
import Orders

## The explorer's four charts, as Plotly figures built with Plume from a
## merged answer: at most 366 points a chart, whatever the number of
## orders. Each is drawn by a `plume-chart` element
## (`examples/shared/plume-chart.mjs`), which hands the figure to
## `Plotly.react`. Every chart keeps the viewer's zoom across updates
## (`ui_revision: Preserve`).
Charts := [].{

	## Orders per day over the year of history, and today's live orders.
	per_day : Orders.Summary -> Str
	per_day = |summary| figure(per_day_chart(summary))

	## The value histogram of the chosen categories, the bins inside the
	## value range in colour and the others grey.
	values : Orders.Summary, Orders.Filter -> Str
	values = |summary, filter| figure(values_chart(summary, filter))

	## Each chosen category's share of the revenue.
	categories : Orders.Summary -> Str
	categories = |summary| figure(categories_chart(summary))

	## The eight regions with the most revenue, the most at the top.
	regions : Orders.Summary -> Str
	regions = |summary| figure(regions_chart(summary))
}

## The first day of the history. Today, the live feed's day, follows the
## last of it.
first_day_millis : I64
first_day_millis = 1762819200000

teal : Color
teal = Color.rgb({ red: 13, green: 148, blue: 136 })

grey : Color
grey = Color.rgb({ red: 212, green: 212, blue: 216 })

amber : Color
amber = Color.rgb({ red: 217, green: 119, blue: 6 })

palette : List(Color)
palette = [
	Color.rgb({ red: 13, green: 148, blue: 136 }),
	Color.rgb({ red: 37, green: 99, blue: 235 }),
	Color.rgb({ red: 217, green: 119, blue: 6 }),
	Color.rgb({ red: 22, green: 163, blue: 74 }),
	Color.rgb({ red: 147, green: 51, blue: 234 }),
	Color.rgb({ red: 220, green: 38, blue: 38 }),
	Color.rgb({ red: 8, green: 145, blue: 178 }),
	Color.rgb({ red: 219, green: 39, blue: 119 }),
]

## A chart's figure. Every number here is a finite count or amount and
## every size a constant, so building a chart cannot fail.
figure : Try(Chart, _) -> Str
figure = |built| match built {
	Ok(chart) => chart.to_json()
	Err(problem) => crash "Charts.figure: a chart of finite counts was refused: ${Str.inspect(problem)}"
}

## The same size and margins for every chart, so the grid lines up.
size : {} -> Try(Size, _)
size = |{}| Size.new({ height: Pixels(300), margin: Pixels({ left: 64, right: 16, top: 40, bottom: 48 }) })

day_coordinate : U64 -> Try(Coordinate, _)
day_coordinate = |day| Ok(Coordinate.from_time(Time.from_epoch_millis(first_day_millis + day.to_i64_wrap() * 86400000)?))

per_day_chart : Orders.Summary -> Try(Chart, _)
per_day_chart = |summary| {
	var $points = []
	var $day = 0
	for count in summary.per_day {
		$points = $points.append({ x: day_coordinate($day)?, y: Coordinate.from_number(count.to_f64())? })
		$day = $day + 1
	}
	today = day_coordinate(Orders.today)?
	Ok(
		Chart.new({
			traces: [Scatter(Scatter.new({ data: $points, name: "Orders", line: Line.new({ color: teal, width: 1.5 })?, fill: ToZeroY }))],
			layout: Layout.new({
				title: Title.new({ text: "Orders per day" }),
				size: size({})?,
				x_axis: Axis.new({ type: Date, tick_format: Pattern("%b %Y") })?,
				y_axis: Axis.new({ range: FromZero })?,
				hover_mode: XUnified,
				ui_revision: Preserve("orders-per-day"),
				shapes: [Shape.new({ placement: VerticalLine(today), line: Line.new({ color: amber, width: 1, dash: Dash })?, label: "Today, live" })],
			}),
		}),
	)
}

values_chart : Orders.Summary, Orders.Filter -> Try(Chart, _)
values_chart = |summary, filter| {
	var $bars = []
	var $bin = 0
	for count in summary.histogram {
		inside = $bin >= filter.lowest and $bin <= filter.highest
		dollars = ($bin * Orders.bin_cents + Orders.bin_cents // 2) // 100
		$bars = $bars.append({ x: Coordinate.from_number(dollars.to_f64())?, y: Coordinate.from_number(count.to_f64())?, color: if (inside) teal else grey })
		$bin = $bin + 1
	}
	Ok(
		Chart.new({
			traces: [Bar(Bar.new({ data: $bars, name: "Orders", width: (Orders.bin_cents // 100).to_f64() * 0.9 })?)],
			layout: Layout.new({
				title: Title.new({ text: "Order values" }),
				size: size({})?,
				x_axis: Axis.new({ tick_format: Pattern("$,.0f") })?,
				y_axis: Axis.new({ range: FromZero })?,
				ui_revision: Preserve("order-values"),
			}),
		}),
	)
}

categories_chart : Orders.Summary -> Try(Chart, _)
categories_chart = |summary| {
	slices = List.map2(Orders.categories, summary.by_category, |category, cents| { label: Orders.category_name(category), value: (cents // 100).to_f64() })
		.keep_if(|slice| slice.value > 0)
	Ok(
		Chart.new({
			traces: [Pie(Pie.new({ data: slices, hole: 0.45, name: "Revenue" })?)],
			layout: Layout.new({
				title: Title.new({ text: "Revenue by category" }),
				size: size({})?,
				legend: Shown,
				ui_revision: Preserve("revenue-by-category"),
			}),
		}),
	)
}

regions_chart : Orders.Summary -> Try(Chart, _)
regions_chart = |summary| {
	ranked = List.map2(Orders.regions, summary.by_region, |name, cents| { name, cents })
		.sort_with(|a, b| if (a.cents > b.cents) Before else if (a.cents < b.cents) After else Same)
		.take_first(8)
		.rev()
	var $bars = []
	var $at = 0
	for region in ranked {
		$bars = $bars.append({ x: Coordinate.from_number((region.cents // 100).to_f64())?, y: Coordinate.from_text(region.name), color: palette.get($at % palette.len()) ?? teal })
		$at = $at + 1
	}
	Ok(
		Chart.new({
			traces: [Bar(Bar.new({ data: $bars, name: "Revenue", orientation: Horizontal })?)],
			layout: Layout.new({
				title: Title.new({ text: "Top regions by revenue" }),
				size: Size.new({ height: Pixels(300), margin: Pixels({ left: 120, right: 16, top: 40, bottom: 48 }) })?,
				x_axis: Axis.new({ tick_format: Pattern("$~s"), range: FromZero })?,
				ui_revision: Preserve("top-regions"),
			}),
		}),
	)
}
